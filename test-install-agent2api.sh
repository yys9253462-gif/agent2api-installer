#!/usr/bin/env bash
#
# install-agent2api.sh 的自动化回归套件
# ============================================================================
# 目的：把「改脚本 → 手工点一遍」变成「改脚本 → 一键跑 20 个用例」。
# 它自己会起真实的容器、改真实的反代配置，跑完自动清理。
#
# 为什么必须有这个：出现过「所有测试都显式传了 --expose，于是交互分支的 bug
# 长期没被发现」这种事。用例要覆盖**默认值路径**与**异常路径**，不只是「正确用法」。
#
# 用法（在目标机器上以 root 运行）：
#   bash test-install-agent2api.sh
#   TEST_DOMAIN=a2atest.example.com bash test-install-agent2api.sh   # 额外跑域名用例
#   INSTALLER=/path/to/install-agent2api.sh bash test-install-agent2api.sh
#   KEEP=1 ...    # 保留现场，便于失败后排查
#
# 退出码 = 失败用例数（0 = 全过）
#
set -uo pipefail      # 刻意不用 -e：单个用例失败要继续跑完

INSTALLER="${INSTALLER:-/root/install-agent2api.sh}"
TEST_ROOT="${TEST_ROOT:-/opt/a2a-regress}"
TEST_DOMAIN="${TEST_DOMAIN:-}"
EXISTING_DOMAINS="${EXISTING_DOMAINS:-}"     # 空格分隔，用于复检「原有站点未被影响」
KEEP="${KEEP:-0}"
P_PORT="${P_PORT:-3210}"                     # 面板端口基准
G_PORT="${G_PORT:-3211}"                     # 网关端口基准

PASS=0; FAIL=0; SKIP=0; FAILED=()

# 颜色变量必须与业务变量分namespace —— 早前用 D 当「暗色」，
# 结果被用例里的安装目录变量 $D 覆盖，输出直接错乱（踩过）
if [ -t 1 ]; then FG_G=$'\033[32m'; FG_R=$'\033[31m'; FG_D=$'\033[2m'; FG_B=$'\033[1m'; FG_O=$'\033[0m'
else FG_G=""; FG_R=""; FG_D=""; FG_B=""; FG_O=""; fi

CUR=""; OUT=""; RC=0
begin()  { CUR="$1"; printf '\n%s── %s%s\n' "$FG_B" "$CUR" "$FG_O"; }
verdict(){ if [ "$1" = 0 ]; then PASS=$((PASS+1)); printf '   %s✓%s\n' "$FG_G" "$FG_O"
           else FAIL=$((FAIL+1)); FAILED+=("$CUR"); printf '   %s×%s %s\n' "$FG_R" "$FG_O" "${2:-}"; fi }
note()   { printf '     %s%s%s\n' "$FG_D" "$1" "$FG_O"; }
skip()   { SKIP=$((SKIP+1)); printf '   %s- 跳过：%s%s\n' "$FG_D" "${1:-}" "$FG_O"; }

run_installer() { OUT=$("$INSTALLER" "$@" 2>&1); RC=$?; }
# 用 -e 传模式：模式以 - 开头时（如 has "--domain"）不带 -e 会被 grep 当成选项
has()            { printf '%s' "$OUT" | grep -qF -e "$1"; }
has_re()         { printf '%s' "$OUT" | grep -qE -e "$1"; }
ctr()            { docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$1"; }
healthy()        { [ "$(docker inspect -f '{{.State.Health.Status}}' "$1" 2>/dev/null)" = "healthy" ]; }
port_up()        { ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1$"; }
http_code()      { curl -s -o /dev/null -w '%{http_code}' --max-time "${2:-10}" "$1" 2>/dev/null || echo 000; }
# 自助注册端点返回码：默认应为「非 403」（403 = 被反代封掉）
setup_code()     { curl -s -o /dev/null -w '%{http_code}' --max-time 15 -X POST \
                     -H 'Content-Type: application/json' -d '{}' \
                     "https://${TEST_DOMAIN}/api/panel/setup" 2>/dev/null || echo 000; }

# 每个用例用独立目录，跑完（或失败后）都清理，避免互相干扰
inst()  { printf '%s' "${TEST_ROOT}/$1"; }
cleanup_instance() {
  local d="$1" c="$2"
  [ "$KEEP" = 1 ] && { note "KEEP=1，保留 $d"; return; }
  [ -d "$d" ] && "$INSTALLER" --uninstall --yes --dir "$d" >/dev/null 2>&1
  docker rm -f "$c" "${c}-caddy" >/dev/null 2>&1
  rm -rf "$d"
}

# ── 前置 ────────────────────────────────────────────────────────────────────
preflight() {
  printf '%s=== install-agent2api.sh 回归套件 ===%s\n' "$FG_B" "$FG_O"
  if [ "$(id -u)" != 0 ]; then printf '需要 root 运行\n' >&2; exit 2; fi
  if [ ! -f "$INSTALLER" ]; then printf '找不到安装脚本：%s\n' "$INSTALLER" >&2; exit 2; fi
  bash -n "$INSTALLER" || { printf '安装脚本语法不通过\n' >&2; exit 2; }
  note "被测脚本：$INSTALLER"
  note "用例目录：$TEST_ROOT"
  ls -d /opt/a2a* "${TEST_ROOT}" >/dev/null 2>&1 && note "检测到历史残留目录，本套件会覆盖同名前缀目录"
  mkdir -p "$TEST_ROOT"
}

# ── A. 参数校验（零副作用路径）──────────────────────────────────────────────
case_help() {
  begin "--help 列出关键参数"
  run_installer --help
  [ "$RC" = 0 ] && has "--domain" && has "--expose" && has "--uninstall" && has "--no-domain" && has "--dry-run"
  verdict $? "rc=$RC"
}
case_unknown_arg() {
  begin "未知参数被拒绝"
  run_installer --bogus
  { [ "$RC" != 0 ] && has_re "未知参数"; }
  verdict $? "rc=$RC"
}
case_bad_port_alpha() {
  begin "--panel-port abc 被拦下"
  run_installer --dry-run -y --dir "$(inst x)" --panel-port abc
  { [ "$RC" != 0 ] && has_re "必须是数字"; }
  verdict $? "rc=$RC"
}
case_bad_port_range() {
  begin "--panel-port 99999 / 0 被拦下"
  run_installer --dry-run -y --dir "$(inst x)" --panel-port 99999
  local r1=$RC; local o1=$OUT
  run_installer --dry-run -y --dir "$(inst x)" --panel-port 0
  { [ "$r1" != 0 ] && [ "$RC" != 0 ] && printf '%s' "$o1" | grep -qE "超出范围"; }
  verdict $? "rc=$r1/$RC"
}
case_same_ports() {
  begin "面板与网关端口相同被拦下"
  run_installer --dry-run -y --dir "$(inst x)" --panel-port 1234 --gateway-port 1234
  { [ "$RC" != 0 ] && has_re "不能相同"; }
  verdict $? "rc=$RC"
}
case_bad_expose() {
  begin "--expose foo 被拦下（否则会生成空 route）"
  run_installer --dry-run -y --dir "$(inst x)" --domain x.example.com --expose foo
  { [ "$RC" != 0 ] && has_re "只能"; }
  verdict $? "rc=$RC"
}
case_bad_mem() {
  begin "--mem 384mb 被拦下"
  run_installer --dry-run -y --dir "$(inst x)" --mem 384mb
  { [ "$RC" != 0 ] && has_re "格式"; }
  verdict $? "rc=$RC"
}
case_bad_container() {
  begin "--container -bad 被拦下"
  run_installer --dry-run -y --dir "$(inst x)" --container -bad
  { [ "$RC" != 0 ] && has_re "容器名"; }
  verdict $? "rc=$RC"
}
case_rel_dir() {
  begin "相对路径 --dir 归一化为绝对路径"
  run_installer --dry-run -y --dir relpath-xyz
  has "安装目录：/" && ! has "安装目录：relpath"
  verdict $? "rc=$RC"
}
case_dryrun_no_side_effect() {
  begin "--dry-run 不落任何文件"
  local d; d="$(inst dryrun)"
  rm -rf "$d"
  run_installer --dry-run -y --dir "$d" --panel-port "$P_PORT" --gateway-port "$G_PORT"
  { [ ! -e "$d" ] && [ "$RC" = 0 ]; }
  verdict $? "目录是否被创建=$([ -e "$d" ] && echo 是 || echo 否) rc=$RC"
}

# ── B. 默认值路径（无域名安装）──────────────────────────────────────────────
C="reg-nodom"; D=""
case_bad_expose_no_domain() {
  begin "--expose 非法值【不带域名】时也要拦（以前会被静默吞掉）"
  # 不带 --domain 时 gather_config 会把 EXPOSE_MODE 强制覆盖成 none，
  # 于是非法值被无声吃掉、一个错都不报 —— 实测踩到
  run_installer --dry-run -y --dir "$(inst bx)" --expose foo
  { [ "$RC" != 0 ] && has_re "只能"; }
  verdict $? "rc=$RC"
}
case_conflict_no_domain_and_domain() {
  begin "--no-domain 与 --domain 同时给 → 直接报错（语义矛盾）"
  run_installer --dry-run -y --dir "$(inst bc)" --no-domain --domain x.example.com
  { [ "$RC" != 0 ] && has_re "不能同时"; }
  verdict $? "rc=$RC"
}
case_mem_too_small() {
  begin "--mem 0m / 1k 被拦下（低于 docker 的 6m 下限）"
  run_installer --dry-run -y --dir "$(inst bm)" --mem 0m
  local r1=$RC
  run_installer --dry-run -y --dir "$(inst bm)" --mem 1k
  local r2=$RC
  { [ "$r1" != 0 ] && [ "$r2" != 0 ]; }
  verdict $? "0m→rc=$r1  1k→rc=$r2"
}
case_bad_caddy_mode() {
  begin "--caddy-mode 非法值被拦下（以前会被静默忽略）"
  run_installer --dry-run -y --dir "$(inst bd)" --caddy-mode bogus
  { [ "$RC" != 0 ] && has_re "caddy-mode"; }
  verdict $? "rc=$RC"
}
case_corrupt_state_file() {
  begin "状态文件被写坏 → 明确提示，且【不执行】里面的内容"
  [ -f "$D/install.conf" ] || { skip "无实例"; return; }
  local bak; bak="$(mktemp)"; cp "$D/install.conf" "$bak"
  printf 'garbage line
EVIL=$(touch /tmp/.a2a-pwned)
' > "$D/install.conf"
  rm -f /tmp/.a2a-pwned
  run_installer --dry-run -y --dir "$D"
  local warned=0 pwned=0
  has "可识别" && warned=1
  [ -f /tmp/.a2a-pwned ] && pwned=1
  cp "$bak" "$D/install.conf"; rm -f "$bak" /tmp/.a2a-pwned
  { [ "$warned" = 1 ] && [ "$pwned" = 0 ]; }
  verdict $? "有提示=$warned 被注入=$pwned"
}

case_install_nodomain() {
  begin "无域名安装：容器 healthy、面板/网关在容器内均可达"
  D="$(inst $C)"; rm -rf "$D"
  run_installer --yes --dir "$D" --container "$C" --panel-port "$P_PORT" --gateway-port "$G_PORT"
  local rc1=$RC
  if [ "$rc1" != 0 ]; then verdict 1 "安装失败 rc=$rc1"; note "$(printf '%s' "$OUT" | tail -3)"; return; fi
  { ctr "$C" && healthy "$C" \
      && docker exec "$C" curl -sf --max-time 5 "http://127.0.0.1:${G_PORT}/health" >/dev/null 2>&1 \
      && docker exec "$C" curl -sf --max-time 5 "http://127.0.0.1:${P_PORT}/" >/dev/null 2>&1 \
      && [ -f "$D/install.conf" ]; }
  verdict $? "healthy=$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)"
}
case_rerun_idempotent() {
  begin "重跑（不带参数）保持可用且配置不漂移"
  [ -f "$D/install.conf" ] || { skip "上一个用例未成功"; return; }
  run_installer --yes --dir "$D"
  { [ "$RC" = 0 ] && healthy "$C" && has "读回" \
      && [ "$(grep -c 'PANEL_PORT=' "$D/install.conf")" = 1 ]; }
  verdict $? "rc=$RC"
}
case_domains_absent_without_flag() {
  begin "不传 --domain 时状态里不应有域名"
  [ -f "$D/install.conf" ] || { skip "无实例"; return; }
  ! grep -qE '^DOMAIN=.+' "$D/install.conf"
  verdict $?
}

# ── B2. 状态与版本管理 ──────────────────────────────────────────────────────
case_status() {
  begin "--status 报告容器/端口/健康"
  [ -f "$D/install.conf" ] || { skip "无实例"; return; }
  run_installer --status --dir "$D"
  { [ "$RC" = 0 ] && has "容器运行中" && has "网关" && has "面板" && has "安装目录"; }
  verdict $? "rc=$RC"
}
case_check_update() {
  begin "--check-update 给出当前与最新版本"
  [ -f "$D/install.conf" ] || { skip "无实例"; return; }
  run_installer --check-update --dir "$D"
  { [ "$RC" = 0 ] && has "当前版本" && { has "最新版本" || has "查询不到"; }; }
  verdict $? "rc=$RC"
}
case_upgrade_same() {
  begin "--upgrade 到当前版本 → 提示无需升级"
  [ -f "$D/install.conf" ] || { skip "无实例"; return; }
  local cur; cur=$(awk -F= '/^IMAGE_TAG=/{print $2}' "$D/install.conf")
  [ -n "$cur" ] || { skip "读不到当前 tag"; return; }
  run_installer --upgrade --tag "$cur" --dir "$D"
  { [ "$RC" = 0 ] && has_re "无需升级|已是指定版本"; }
  verdict $? "rc=$RC tag=$cur"
}
case_upgrade_rollback() {
  begin "--upgrade 到不存在的版本 → 回滚且服务仍健康、状态文件不被污染"
  [ -f "$D/install.conf" ] || { skip "无实例"; return; }
  local cur now; cur=$(awk -F= '/^IMAGE_TAG=/{print $2}' "$D/install.conf")
  run_installer --upgrade --tag 9.9.9-nonexistent --dir "$D"
  local r=$RC
  now=$(awk -F= '/^IMAGE_TAG=/{print $2}' "$D/install.conf")
  { [ "$r" != 0 ] && has_re "回滚|拉取失败" && [ "$now" = "$cur" ] && healthy "$C"; }
  verdict $? "rc=$r tag=$cur→$now health=$(docker inspect -f '{{.State.Health.Status}}' "$C" 2>/dev/null)"
}
case_streaming() {
  begin "SSE 流式未被反代缓冲（首字节 << 总耗时）"
  # 用 TEST_STREAM_URL 可独立指向「已有真实账号」的端点；不设则由 TEST_DOMAIN 推导
  local url="${TEST_STREAM_URL:-}"
  [ -n "$url" ] || [ -z "${TEST_DOMAIN:-}" ] || url="https://${TEST_DOMAIN}/v1"
  if [ -z "$url" ] || [ -z "${TEST_API_KEY:-}" ] || [ -z "${TEST_MODEL:-}" ]; then
    skip "需 TEST_API_KEY + TEST_MODEL + (TEST_STREAM_URL 或 TEST_DOMAIN)；要有真实账号才测得出流式"
    return
  fi
  local f=/tmp/.a2a-sse.$$ m ttfb total frames done
  m=$(curl -sN -o "$f" -w '%{time_starttransfer} %{time_total}' --max-time 120 \
        -H "Authorization: Bearer ${TEST_API_KEY}" -H 'Content-Type: application/json' \
        -d "{\"model\":\"${TEST_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"从1数到30，每行一个数字\"}],\"max_tokens\":400,\"stream\":true}" \
        "${url}/chat/completions" 2>/dev/null)
  ttfb=$(printf '%s' "$m" | awk '{print $1}'); total=$(printf '%s' "$m" | awk '{print $2}')
  ttfb=${ttfb:-0}; total=${total:-0}
  frames=$(grep -c '^data:' "$f" 2>/dev/null); frames=${frames:-0}
  done=$(grep -c '\[DONE\]' "$f" 2>/dev/null); done=${done:-0}
  # 没拿到 SSE 帧时把响应体前 120 字符回显出来 —— 否则「帧数=0」这种提示
  # 根本看不出是密钥错、模型名错还是被缓冲（实测踩过：把 manager 的 wbk_ 密钥
  # 打到了 agent2api 直连端点，报 invalid_api_key，但断言只显示帧数 0）
  local why=""
  [ "$frames" = 0 ] && why="响应体前 120 字：$(head -c 120 "$f" 2>/dev/null | tr '\n' ' ')"
  rm -f "$f"
  # 判据：总耗时够长（>1s）且首字节明显早于总耗时 —— 否则说明被整段缓冲了
  local okbuf=1
  awk -v a="$ttfb" -v b="$total" 'BEGIN{exit !(b>1.0 && a<b*0.5)}' && okbuf=0
  { [ "$okbuf" = 0 ] && [ "$frames" -ge 3 ] && [ "$done" -ge 1 ]; }
  verdict $? "端点=$url 首字节=${ttfb}s 总耗时=${total}s 帧数=$frames DONE=$done${why:+ | $why}"
}

# 交互式菜单：菜单只在 stdin 是终端时出现，所以要用 script(1) 造一个 pty 来喂选项。
# 这一组是补漏：之前只测了 --uninstall / --upgrade 这两个命令行入口，
# 没测"重跑后从菜单选"，结果菜单选了「卸载」却继续安装（标记设得太晚、没人看）——
# 实测踩到，用户报上来的。
menu_pick() {   # menu_pick <安装目录> <要喂的输入...>
  local d="$1"; shift
  local input=""
  for x in "$@"; do input="${input}${x}
"; done
  if command -v script >/dev/null 2>&1; then
    printf "$input" | timeout 180 script -qec "$INSTALLER --dir $d" /dev/null 2>&1
  else
    printf "$input" | timeout 180 "$INSTALLER" --dir "$d" 2>&1
  fi
}
case_menu_uninstall() {
  begin "重跑菜单选「3) 卸载」→ 真的卸载（以前会继续安装！）"
  local md mc; md="$(inst mn)"; mc="reg-menu"
  rm -rf "$md"
  run_installer --yes --dir "$md" --container "$mc"                 --panel-port "$((P_PORT+40))" --gateway-port "$((G_PORT+40))"
  [ "$RC" = 0 ] || { verdict 1 "前置安装失败 rc=$RC"; return; }
  local out; out="$(menu_pick "$md" 3 n)"
  local gone=0; ctr "$mc" || gone=1
  { [ "$gone" = 1 ] && printf '%s' "$out" | grep -qF "卸载完成"; }
  verdict $? "容器已移除=$gone"
  cleanup_instance "$md" "$mc"
}
case_menu_upgrade() {
  begin "重跑菜单选「2) 升级」→ 走升级流程，不是重装"
  local md mc; md="$(inst mu)"; mc="reg-menuu"
  rm -rf "$md"
  run_installer --yes --dir "$md" --container "$mc"                 --panel-port "$((P_PORT+42))" --gateway-port "$((G_PORT+42))"
  [ "$RC" = 0 ] || { verdict 1 "前置安装失败 rc=$RC"; return; }
  local out; out="$(menu_pick "$md" 2 2.8.0)"
  local okup=0 okno=0
  printf '%s' "$out" | grep -qF "当前版本" && okup=1
  printf '%s' "$out" | grep -qF "确认开始安装" || okno=1
  { [ "$okup" = 1 ] && [ "$okno" = 1 ]; }
  verdict $? "走了升级路径=$okup 没走安装路径=$okno"
  cleanup_instance "$md" "$mc"
}

case_no_deps_flag() {
  begin "--no-deps：缺 docker 时只给命令、不擅自装（保护用户系统）"
  # 用 PATH 把 docker 藏起来，模拟"机器上没有 docker"
  local fake; fake="$(mktemp -d)"
  local i
  for i in /usr/bin/* /bin/* /usr/local/bin/*; do
    b=$(basename "$i"); [ "$b" = "docker" ] && continue
    ln -sf "$i" "$fake/$b" 2>/dev/null
  done
  local out rc
  out=$(env PATH="$fake" "$INSTALLER" --dry-run --yes --no-deps --dir "$(inst nd)" 2>&1); rc=$?
  rm -rf "$fake"
  local told=0 notinst=0
  printf '%s' "$out" | grep -qF "get.docker.com" && told=1
  printf '%s' "$out" | grep -qF "自动帮你装" && notinst=1
  { [ "$rc" != 0 ] && [ "$told" = 1 ] && [ "$notinst" = 1 ]; }
  verdict $? "rc=$rc 给了命令=$told 提示可自动装=$notinst"
}

# ── C. 端口冲突与自动避让 ───────────────────────────────────────────────────
case_port_conflict_auto() {
  begin "端口被占（当前实例占着 $P_PORT/$G_PORT）→ 自动换端口成功"
  [ -f "$D/install.conf" ] || { skip "无实例占位"; return; }
  local d2 c2; d2="$(inst c1)"; c2="reg-conflict"; rm -rf "$d2"
  run_installer --yes --dir "$d2" --container "$c2" --panel-port "$P_PORT" --gateway-port "$G_PORT"
  local r=$RC
  { [ "$r" = 0 ] && has_re "改用端口" && healthy "$c2"; }
  verdict $? "rc=$r"
  cleanup_instance "$d2" "$c2"
}
case_container_name_conflict() {
  begin "容器名冲突 → 定向报错且不做无用的换端口重试"
  [ -f "$D/install.conf" ] || { skip "无实例占位"; return; }
  local d3; d3="$(inst c2)"; rm -rf "$d3"
  # 刻意换端口：要隔离出「容器名冲突」这一个变量，否则会先撞上端口占用
  run_installer --yes --dir "$d3" --container "$C" \
                --panel-port "$((P_PORT+40))" --gateway-port "$((G_PORT+40))"
  local r=$RC
  { [ "$r" != 0 ] && has_re "容器名" && ! has_re "改用端口"; }
  verdict $? "rc=$r"
  rm -rf "$d3"
}

# ── D. 域名相关（需 TEST_DOMAIN）────────────────────────────────────────────
DC="reg-dom"; DD=""; DOMAIN_INSTALLED=0
domain_ready() {
  [ -n "$TEST_DOMAIN" ] || return 1
  local pip res
  pip=$(curl -s --max-time 8 https://api.ipify.org 2>/dev/null | tr -d '[:space:]')
  res=$(getent hosts "$TEST_DOMAIN" 2>/dev/null | awk '{print $1}' | head -1)
  [ -n "$pip" ] && [ "$res" = "$pip" ]
}
case_domain_install() {
  begin "域名安装：TLS 就绪 + /v1 可达 + 注册端点开放（默认不封）"
  DD="$(inst $DC)"; rm -rf "$DD"
  run_installer --yes --dir "$DD" --container "$DC" --domain "$TEST_DOMAIN" --expose both --cf=n \
                --panel-port "$((P_PORT+20))" --gateway-port "$((G_PORT+20))"
  local r=$RC
  if [ "$r" != 0 ]; then verdict 1 "安装失败 rc=$r"; note "$(printf '%s' "$OUT" | tail -4)"; return; fi
  DOMAIN_INSTALLED=1
  local panel gw setup
  panel=$(http_code "https://${TEST_DOMAIN}/" 15)
  gw=$(http_code "https://${TEST_DOMAIN}/v1/models" 15)
  setup=$(setup_code)
  # 默认**不封**注册：端点必须可达（agent2api 自己可能因缺参数/人机验证返回 4xx，但绝不能是 403）
  { [ "$panel" = 200 ] && [ "$gw" = 200 ] && [ "$setup" != 403 ]; }
  verdict $? "面板=$panel 网关=$gw setup=$setup（403 才算被封）"
}
case_lock_register() {
  begin "--lock-register 能封掉注册端点，--open-register 能恢复"
  [ "$DOMAIN_INSTALLED" = 1 ] || { skip "域名用例未成功"; return; }
  local on off
  run_installer --yes --dir "$DD" --lock-register
  [ "$RC" = 0 ] || { verdict 1 "加 --lock-register 重跑失败 rc=$RC"; return; }
  sleep 2; on=$(setup_code)
  run_installer --yes --dir "$DD" --open-register
  [ "$RC" = 0 ] || { verdict 1 "加 --open-register 重跑失败 rc=$RC"; return; }
  sleep 2; off=$(setup_code)
  { [ "$on" = 403 ] && [ "$off" != 403 ]; }
  verdict $? "封时=$on 开时=$off"
}
case_domain_marker_once() {
  begin "域名模式下托管块恰好一对标记（幂等）"
  [ "$DOMAIN_INSTALLED" = 1 ] || { skip "域名用例未成功"; return; }
  run_installer --yes --dir "$DD"
  local f; f="$(awk -F= '/^CADDY_FILE=/{print $2}' "$DD/install.conf")"
  [ -n "$f" ] && [ -f "$f" ] || { skip "读不到 CADDY_FILE"; return; }
  { [ "$(grep -cF '>>> agent2api managed block' "$f")" = 1 ] \
      && [ "$(grep -cF '<<< agent2api managed block' "$f")" = 1 ]; }
  verdict $? "文件=$f"
}
case_domain_prefill() {
  begin "重跑不带 --domain 时沿用上次域名"
  [ "$DOMAIN_INSTALLED" = 1 ] || { skip "域名用例未成功"; return; }
  run_installer --yes --dir "$DD"
  { [ "$RC" = 0 ] && has "读回" && has "$TEST_DOMAIN"; }
  verdict $? "rc=$RC"
}
case_domain_conflict_fastfail() {
  begin "目标域名已被别的块占用 → 动手之前就失败"
  [ "$DOMAIN_INSTALLED" = 1 ] || { skip "域名用例未成功"; return; }
  local f bak d9 c9; f="$(awk -F= '/^CADDY_FILE=/{print $2}' "$DD/install.conf")"
  [ -n "$f" ] && [ -f "$f" ] || { skip "读不到 CADDY_FILE"; return; }
  bak="$(mktemp)"; cp "$f" "$bak"
  printf '\n%s {\n\trespond "x"\n}\n' "$TEST_DOMAIN" >> "$f"
  d9="$(inst c9)"; c9="reg-conflict-dom"; rm -rf "$d9"
  run_installer --yes --dir "$d9" --container "$c9" --domain "$TEST_DOMAIN"
  local r=$RC
  { [ "$r" != 0 ] && has_re "已经存在" && ! ctr "$c9"; }
  verdict $? "rc=$r 容器是否被创建=$([ "$(ctr "$c9")" = 0 ] && echo 是 || echo 否)"
  cp "$bak" "$f"; rm -f "$bak" "$d9"
}
case_no_domain_removes_block() {
  begin "--no-domain 摘掉站点块且不影响容器"
  [ "$DOMAIN_INSTALLED" = 1 ] || { skip "域名用例未成功"; return; }
  local f; f="$(awk -F= '/^CADDY_FILE=/{print $2}' "$DD/install.conf")"
  run_installer --yes --dir "$DD" --no-domain
  { [ "$RC" = 0 ] && ! grep -qF '>>> agent2api managed block' "$f" && healthy "$DC"; }
  verdict $? "rc=$RC"
}

# ── E. 卸载 ─────────────────────────────────────────────────────────────────
case_uninstall() {
  begin "卸载：容器与站点块都被清掉"
  [ -n "$D" ] || { skip "无实例"; return; }
  local f=""
  [ -f "$DD/install.conf" ] && f="$(awk -F= '/^CADDY_FILE=/{print $2}' "$DD/install.conf")"
  cleanup_instance "$DD" "$DC"
  cleanup_instance "$D" "$C"
  local blockok=1
  [ -n "$f" ] && [ -f "$f" ] && grep -qF '>>> agent2api managed block' "$f" && blockok=0
  { ! ctr "$C" && [ "$blockok" = 1 ]; }
  verdict $? "容器残留=$(ctr "$C" && echo 是 || echo 否) 站点块残留=$([ "$blockok" = 1 ] && echo 否 || echo 是)"
}
case_uninstall_without_state() {
  begin "从未安装时 --uninstall 不报错"
  local d10; d10="$(inst never)"; rm -rf "$d10"
  run_installer --uninstall --yes --dir "$d10"
  { [ "$RC" = 0 ]; }
  verdict $? "rc=$RC"
}

# ── F. 回检：原有站点未被影响 ───────────────────────────────────────────────
case_existing_sites() {
  begin "原有生产站点未被影响"
  [ -n "$EXISTING_DOMAINS" ] || { skip "未提供 EXISTING_DOMAINS"; return; }
  local bad=""
  for d in $EXISTING_DOMAINS; do
    local c; c=$(http_code "https://$d/" 20)
    case "$c" in 2*|3*) ;; *) bad="$bad $d($c)" ;; esac
  done
  [ -z "$bad" ]
  verdict $? "异常站点：${bad:-无}"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
preflight

printf '\n%s[A] 参数校验%s\n' "$FG_B" "$FG_O"
case_help; case_unknown_arg; case_bad_port_alpha; case_bad_port_range
case_same_ports; case_bad_expose; case_bad_mem; case_bad_container
case_rel_dir; case_dryrun_no_side_effect

printf '
%s[A2] 边界与异常（防退化）%s
' "$FG_B" "$FG_O"
case_bad_expose_no_domain; case_conflict_no_domain_and_domain
case_no_deps_flag
case_mem_too_small; case_bad_caddy_mode

printf '\n%s[B] 默认值路径与幂等%s\n' "$FG_B" "$FG_O"
case_install_nodomain; case_rerun_idempotent; case_domains_absent_without_flag; case_corrupt_state_file

printf '\n%s[B2] 状态与版本管理%s\n' "$FG_B" "$FG_O"
case_status; case_check_update; case_upgrade_same; case_upgrade_rollback

printf '
%s[B3] 重跑菜单（交互路径）%s
' "$FG_B" "$FG_O"
case_menu_uninstall; case_menu_upgrade

printf '\n%s[C] 端口与容器名冲突%s\n' "$FG_B" "$FG_O"
case_port_conflict_auto; case_container_name_conflict

printf '\n%s[D] 域名与 TLS%s\n' "$FG_B" "$FG_O"
if domain_ready; then
  note "TEST_DOMAIN=$TEST_DOMAIN 已解析到本机，执行域名用例"
  case_domain_install; case_lock_register; case_domain_marker_once; case_domain_prefill
  case_domain_conflict_fastfail; case_no_domain_removes_block
else
  for n in "域名安装" "注册开关（--lock-register/--open-register）" "托管块幂等" "状态复用" "域名冲突 fail-fast" "--no-domain 摘除"; do
    begin "$n"; skip "需要 TEST_DOMAIN 且必须解析到本机公网 IP"
  done
fi

printf '\n%s[D2] 流式（SSE 是否被缓冲）%s\n' "$FG_B" "$FG_O"
case_streaming

printf '\n%s[E] 卸载%s\n' "$FG_B" "$FG_O"
case_uninstall; case_uninstall_without_state

printf '\n%s[F] 回检%s\n' "$FG_B" "$FG_O"
case_existing_sites

# 兜底清理
cleanup_instance "$D" "$C"
cleanup_instance "$DD" "$DC"

printf '\n%s=== 结果 ===%s\n' "$FG_B" "$FG_O"
printf '  通过 %s%d%s   失败 %s%d%s   跳过 %s%d%s\n' \
  "$FG_G" "$PASS" "$FG_O" "$FG_R" "$FAIL" "$FG_O" "$FG_D" "$SKIP" "$FG_O"
if [ "$FAIL" -gt 0 ]; then
  printf '  失败用例：\n'
  for f in "${FAILED[@]}"; do printf '    · %s\n' "$f"; done
fi
[ "$KEEP" = 1 ] || rm -rf "$TEST_ROOT"
exit "$FAIL"
