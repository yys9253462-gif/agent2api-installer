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
#   RUN_GROUPS=A,A2  # 只跑指定分组（默认 all）。CI 用它跑**零副作用**的那几组：
#                 #   A   参数校验 —— 全部 --dry-run，不落任何文件
#                 #   A2  边界与异常 —— 同上
#                 # 其余分组会起真实容器、改真实反代，只适合在专用机器上跑。
#
# 退出码 = 失败用例数（0 = 全过）
#
set -uo pipefail      # 刻意不用 -e：单个用例失败要继续跑完

INSTALLER="${INSTALLER:-/root/install-agent2api.sh}"
TEST_ROOT="${TEST_ROOT:-/opt/a2a-regress}"
TEST_DOMAIN="${TEST_DOMAIN:-}"
EXISTING_DOMAINS="${EXISTING_DOMAINS:-}"     # 空格分隔，用于复检「原有站点未被影响」
KEEP="${KEEP:-0}"
# ⚠️ 变量名**不能叫 GROUPS** —— 那是 bash 的只读内建数组（当前用户的组 ID 列表）。
#    给它赋值会被静默忽略，`${GROUPS:-all}` 取到的是 gid 0，
#    于是「一个组都匹配不上」→ 一个用例都不跑 → 输出「通过 0 失败 0」而退出码仍是 0。
#    实测踩过：CI 一片绿，实际上一条都没测。所以叫 RUN_GROUPS。
RUN_GROUPS="${RUN_GROUPS:-all}"
P_PORT="${P_PORT:-3210}"                     # 面板端口基准
G_PORT="${G_PORT:-3211}"                     # 网关端口基准

# 分组开关：RUN_GROUPS 里含 all 就全跑；否则只跑列出的分组
want() {
  case ",${RUN_GROUPS}," in *,all,*) return 0 ;; esac
  case ",${RUN_GROUPS}," in *,"$1",*) return 0 ;; esac
  return 1
}

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
  # 🔴 被测脚本没有 +x 时，每个用例都会以 rc=126（无法执行）失败。
  #   危险的是：那些「只断言 rc≠0」的用例在这种失败下反而**假通过** ——
  #   实测踩过：一次 15 个用例全 rc=126，其中 3 个显示 ✓，退出码却是 15。
  #   所以这里把执行权限补上，并在补不上时直接中止，别让环境问题混进用例结果。
  chmod +x "$INSTALLER" 2>/dev/null || true
  if [ ! -x "$INSTALLER" ]; then
    printf '被测脚本没有执行权限且无法 chmod：%s\n' "$INSTALLER" >&2; exit 2
  fi
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
  local r1=$RC o1="$OUT"
  run_installer --dry-run -y --dir "$(inst bm)" --mem 1k
  { [ "$r1" != 0 ] && [ "$RC" != 0 ] \
    && printf '%s' "$o1" | grep -qF "太小" && printf '%s' "$OUT" | grep -qF "太小"; }
  verdict $? "0m→rc=$r1  1k→rc=$RC"
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
# 🔴 这一组的 4 个用例（status / check-update / upgrade-same / upgrade-rollback）
#   全都要求 $D 里有一个装好的实例。以前它们硬依赖 B 组（default）先跑过并留下 $D，
#   一旦单跑 `RUN_GROUPS=state` 就变成「通过 2 失败 0 跳过 4」——
#   跳过的那 4 个恰好是状态/升级这类最容易出错的逻辑，等于**一行没测**。
#   （和 conflict 组当年一模一样的病：组间隐式顺序依赖 → 单跑静默清空。）
#   修法：本组自带一个实例，不依赖任何其他组。
STATE_OWN_D=""
ensure_state_instance() {
  [ -n "$D" ] && [ -f "$D/install.conf" ] && return 0
  if [ -n "$STATE_OWN_D" ] && [ -f "$STATE_OWN_D/install.conf" ]; then D="$STATE_OWN_D"; return 0; fi
  local d c; d="$(inst s0)"; c="reg-state-base"; rm -rf "$d"
  run_installer --yes --dir "$d" --container "$c" \
                --panel-port "$((P_PORT+60))" --gateway-port "$((G_PORT+60))" >/dev/null 2>&1
  if [ "$RC" != 0 ] || [ ! -f "$d/install.conf" ]; then rm -rf "$d"; return 1; fi
  STATE_OWN_D="$d"; C="$c"; D="$d"
  return 0
}

case_status() {
  begin "--status 报告容器/端口/健康"
  ensure_state_instance && [ -f "$D/install.conf" ] || { skip "无法准备实例（安装失败）"; return; }
  run_installer --status --dir "$D"
  { [ "$RC" = 0 ] && has "容器运行中" && has "网关" && has "面板" && has "安装目录"; }
  verdict $? "rc=$RC"
}
case_check_update() {
  begin "--check-update 给出当前与最新版本"
  ensure_state_instance && [ -f "$D/install.conf" ] || { skip "无法准备实例（安装失败）"; return; }
  run_installer --check-update --dir "$D"
  { [ "$RC" = 0 ] && has "当前版本" && { has "最新版本" || has "查询不到"; }; }
  verdict $? "rc=$RC"
}
case_upgrade_same() {
  begin "--upgrade 到当前版本 → 提示无需升级"
  ensure_state_instance && [ -f "$D/install.conf" ] || { skip "无法准备实例（安装失败）"; return; }
  local cur; cur=$(awk -F= '/^IMAGE_TAG=/{print $2}' "$D/install.conf")
  [ -n "$cur" ] || { skip "读不到当前 tag"; return; }
  run_installer --upgrade --tag "$cur" --dir "$D"
  { [ "$RC" = 0 ] && has_re "无需升级|已是指定版本"; }
  verdict $? "rc=$RC tag=$cur"
}
case_upgrade_rollback() {
  begin "--upgrade 到不存在的版本 → 回滚且服务仍健康、状态文件不被污染"
  ensure_state_instance && [ -f "$D/install.conf" ] || { skip "无法准备实例（安装失败）"; return; }
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
  begin "--no-deps + --dry-run：缺 docker 时只检测、不安装、不起服务"
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
  local said=0 installing=0
  printf '%s' "$out" | grep -qF "本次不做任何改动" && said=1
  # 🔴 关键断言：dry-run 里出现任何「正在装」的迹象都算失败。
  #   这条直接钉住 v1.7.1 修的那个问题 —— 原来 --dry-run 走的是安装路径，
  #   机器上没 docker 时**真的会装上一整套 Docker**，装完还打印「不实际改动」。
  #   注意：提示里出现 get.docker.com 是**给人建议**，不等于真的去装了，不算违规。
  printf '%s' "$out" | grep -qE "我来装|方式 [0-9]/4|正在安装|先装个下载工具|apt purge" && installing=1
  { [ "$rc" != 0 ] && [ "$said" = 1 ] && [ "$installing" = 0 ]; }
  verdict $? "rc=$rc 明说未改动=$said 出现安装迹象=$installing"
}

case_upgrade_no_autodeps() {
  begin "--upgrade 缺 docker 时**不**擅自安装（只看/升，不动系统）"
  # 与 --status/--uninstall 同理：用户跑 --upgrade 不是请你去装一整套 Docker。
  # v1.7.0 的 AUTO_DEPS 白名单漏了 DO_UPGRADE，这里钉住。
  local fake; fake="$(mktemp -d)"
  local i
  for i in /usr/bin/* /bin/* /usr/local/bin/*; do
    b=$(basename "$i"); [ "$b" = "docker" ] && continue
    ln -sf "$i" "$fake/$b" 2>/dev/null
  done
  local out rc installing=0 said=0
  out=$(env PATH="$fake" "$INSTALLER" --upgrade --yes --dir "$(inst nu)" 2>&1); rc=$?
  rm -rf "$fake"
  # 同上：判断「有没有真的动手装」，而不是「有没有提到 get.docker.com」
  printf '%s' "$out" | grep -qE "我来装|方式 [0-9]/4|正在安装|先装个下载工具|apt purge" && installing=1
  printf '%s' "$out" | grep -qF "没有对系统做任何改动" && said=1
  # 必须同时断 rc≠0 和「说了没做」—— 只断 rc≠0 的话，
  # 环境问题（脚本没有 +x → rc=126）也会被当成通过。
  { [ "$rc" != 0 ] && [ "$installing" = 0 ] && [ "$said" = 1 ]; }
  verdict $? "rc=$rc 擅自安装迹象=$installing 明说未改动=$said"
}

case_arg_missing_value() {
  begin "参数缺值时给人话，而不是 bash 的 shift 越界报错"
  run_installer --dry-run -y --domain
  local r1=$RC o1="$OUT"
  run_installer --dry-run -y --mem
  { [ "$r1" != 0 ] && [ "$RC" != 0 ] \
    && printf '%s' "$o1" | grep -qF "需要一个值" \
    && printf '%s' "$OUT" | grep -qF "需要一个值"; }
  verdict $? "rc=$r1/$RC"
}

case_huge_numbers() {
  begin "超长数字（端口/内存）被拦下，不会触发算术溢出"
  run_installer --dry-run -y --dir "$(inst hn)" --panel-port 99999999999999999999
  local r1=$RC o1="$OUT"
  run_installer --dry-run -y --dir "$(inst hn)" --mem 99999999999999g
  # 三重断言：rc≠0 + 说的是人话 + bash 没有吐 "value too great for base"
  # ⚠️ 「没有溢出」这一条要用 if 写，不能写成 `! a | grep` ——
  #   `!` 的优先级高于管道，那样解析成 `(!a) | grep`，恒为假（实测踩过）。
  overflow=0
  if printf '%s' "$o1$OUT" | grep -qi "value too great"; then overflow=1; fi
  { [ "$r1" != 0 ] && [ "$RC" != 0 ] \
    && printf '%s' "$o1" | grep -qF "范围" \
    && printf '%s' "$OUT" | grep -qF "过大" \
    && [ "$overflow" = 0 ]; }
  verdict $? "端口rc=$r1 内存rc=$RC 溢出迹象=$overflow"
}

# ── C. 端口冲突与自动避让 ───────────────────────────────────────────────────
# 🔴 这一组以前硬依赖「B 组已经建好的实例 $D」——单独跑 `RUN_GROUPS=conflict`
#    时两个用例全部 skip，于是**端口避让代码一行都没被测到**，而汇总只显示
#    「通过 0 失败 0 跳过 2」；PASS+FAIL==0 的兜底恰好抓到了，
#    但只要有别组同时跑、PASS 非 0，这种「整组静默跳过」就会伪装成绿灯。
#    修法：本组自带一个占位实例（ensure_conflict_instance），不依赖组间顺序。
CONFLICT_OWN_D=""
ensure_conflict_instance() {
  [ -f "$D/install.conf" ] && return 0          # 已有共享实例，直接用
  if [ -n "$CONFLICT_OWN_D" ] && [ -f "$CONFLICT_OWN_D/install.conf" ]; then return 0; fi
  local d c; d="$(inst c0)"; c="reg-conflict-base"; rm -rf "$d"
  run_installer --yes --dir "$d" --container "$c" \
                --panel-port "$P_PORT" --gateway-port "$G_PORT" >/dev/null 2>&1
  if [ "$RC" != 0 ] || [ ! -f "$d/install.conf" ]; then
    rm -rf "$d"; return 1
  fi
  CONFLICT_OWN_D="$d"; C="$c"; D="$d"           # 供本组其它用例复用
  return 0
}
case_port_conflict_auto() {
  begin "端口被占（已有实例占着 $P_PORT/$G_PORT）→ 自动换端口成功"
  if ! ensure_conflict_instance; then skip "无法准备占位实例（安装失败）"; return; fi
  local d2 c2; d2="$(inst c1)"; c2="reg-conflict"; rm -rf "$d2"
  run_installer --yes --dir "$d2" --container "$c2" --panel-port "$P_PORT" --gateway-port "$G_PORT"
  local r=$RC
  { [ "$r" = 0 ] && has_re "改用端口" && healthy "$c2"; }
  verdict $? "rc=$r"
  cleanup_instance "$d2" "$c2"
  # 本组自建的占位实例用完即清，避免污染其它组
  if [ -n "$CONFLICT_OWN_D" ] && [ "$CONFLICT_OWN_D" = "$D" ]; then
    cleanup_instance "$CONFLICT_OWN_D" "$C"
    CONFLICT_OWN_D=""; D=""; C=""
  fi
}
case_container_name_conflict() {
  begin "容器名冲突 → 定向报错且不做无用的换端口重试"
  if ! ensure_conflict_instance; then skip "无法准备占位实例（安装失败）"; return; fi
  local d3; d3="$(inst c2)"; rm -rf "$d3"
  # 刻意换端口：要隔离出「容器名冲突」这一个变量，否则会先撞上端口占用。
  # 注意：$C 的容器此刻正在运行，且它带的是**同一个安装目录 label**，
  # 所以新版脚本会把它判定为「本项目残骸」自动清理 —— 这属于**正确的自愈**，
  # 不再是「定向报错」。要测「报错」路径，得用一个**非本项目**的同名容器。
  # 造一个「不是本项目镜像」的同名容器来制造真冲突
  docker rm -f "$C" >/dev/null 2>&1 || true
  docker run -d --name "$C" --label install-agent2api.dir=/somewhere/else \
      alpine:3 sleep 600 >/dev/null 2>&1 || true
  run_installer --yes --dir "$d3" --container "$C" \
                --panel-port "$((P_PORT+40))" --gateway-port "$((G_PORT+40))"
  local r=$RC
  { [ "$r" != 0 ] && has_re "容器名" && ! has_re "改用端口"; }
  verdict $? "rc=$r"
  docker rm -f "$C" >/dev/null 2>&1
  rm -rf "$d3"
  if [ -n "$CONFLICT_OWN_D" ]; then cleanup_instance "$CONFLICT_OWN_D" "$C"; CONFLICT_OWN_D=""; D=""; C=""; fi
}

# 新增回归：上一次安装失败留下的残骸容器，不能挡住本次重试。
# 直接钉住已修的坑：
#   ① 同名残骸（本项目镜像/label）应被 reclaim_stale_container 自动清理，而不是 die；
#   ② 非本项目的同名容器**绝不能**被误删（防误伤别人的服务）；
#   ③ used_ports 必须把**运行中**容器的宿主端口算进来（不能只看 ss）。
# 注：Docker 会把 Created/Exited 容器的 `.Ports` 显示为空，其宿主端口此刻确实空闲，
#     故「已退出容器的端口」不作为占用来源断言（那是 docker 的语义，不是我们能改的）。
case_stale_container_not_blocking() {
  begin "上次失败的残留容器不挡路：同名残骸可自愈 + 不误删他人容器 + 运行中容器端口算占用"
  command -v docker >/dev/null 2>&1 || { skip "无 docker"; return; }

  local fn=/tmp/.a2a-fn-c-$$.sh
  awk '/^main\(\) \{/{exit} {print}' "$INSTALLER" > "$fn"

  # —— 断言 ①：运行中容器的宿主端口必须被 used_ports 看见（ss + docker 双保险）——
  local tc="a2a-dockport-$$" seen=0
  docker rm -f "$tc" >/dev/null 2>&1
  if docker run -d --name "$tc" -p 127.0.0.1:3496:80 nginx:alpine >/dev/null 2>&1; then
    sleep 2
    ( . "$fn"; used_ports | grep -qx 3496 ) && seen=1
    docker rm -f "$tc" >/dev/null 2>&1
  else
    note "拉不到 nginx 镜像，跳过断言①"
    seen=1
  fi

  # —— 断言 ②：本项目镜像/同 label 的同名残骸应被判为可自愈并清掉 ——
  local tc2="reg-stale-$$" reclaimed=0 gone=0
  docker rm -f "$tc2" >/dev/null 2>&1
  if docker run -d --name "$tc2" --label install-agent2api.dir="$(inst stale)" \
        nginx:alpine >/dev/null 2>&1; then
    sleep 1
    ( . "$fn"
      INSTALL_DIR="$(inst stale)"; DEFAULT_IMAGE_REPO="aimodcc/agent2api"
      CONTAINER="$tc2"; CADDY_SELF_CONTAINER=""
      reclaim_stale_container "$tc2" && exit 7 ) ; [ $? = 7 ] && reclaimed=1
    ctr "$tc2" || gone=1
    docker rm -f "$tc2" >/dev/null 2>&1
  else
    note "拉不到 nginx 镜像，跳过断言②"
    reclaimed=1; gone=1
  fi

  # —— 断言 ③：非本项目的同名容器**不能**被误删 ——
  local tc3="reg-other-$$" kept=1
  docker rm -f "$tc3" >/dev/null 2>&1
  if docker run -d --name "$tc3" alpine:3 sleep 300 >/dev/null 2>&1; then
    sleep 1
    local fn2=/tmp/.a2a-fn2-c-$$.sh
    awk '/^main\(\) \{/{exit} {print}' "$INSTALLER" > "$fn2"
    ( . "$fn2"
      INSTALL_DIR=/opt/agent2api; DEFAULT_IMAGE_REPO="aimodcc/agent2api"
      CONTAINER="$tc3"; CADDY_SELF_CONTAINER=""
      reclaim_stale_container "$tc3" ) && kept=0
    docker rm -f "$tc3" >/dev/null 2>&1
    rm -f "$fn2"
  fi

  rm -f "$fn"
  { [ "$seen" = 1 ] && [ "$reclaimed" = 1 ] && [ "$gone" = 1 ] && [ "$kept" = 1 ]; }
  verdict $? "运行中容器端口算占用=$seen 残骸可自愈=$reclaimed 已清掉=$gone 未误删他人容器=$kept"
}

# 新增回归（BUG #6）：**域名绑定失败**这一条路径不能留下孤儿。
# 背景（实测踩到，正是用户报的「端口被占」的现实来源）：
#   `apply_domain` 在 compose 已经 up、容器已经 healthy 之后才跑。它一旦 die
#   （域名被别的站点块占着 / DNS 没就绪），install.conf 还没写（save_state 在它之后），
#   于是：容器还在跑、宿主端口还被它占着 —— 用户看到「没装成」，可端口却"被占用"了。
# 修法：die / ERR / EXIT 统一走 rollback_started_container()，
#   凡「起过容器 + 没写成 install.conf」就把本次起的服务收干净。
case_domain_fail_no_orphan() {
  begin "域名绑定失败（冲突）→ 不留孤儿容器、不留未登记端口"
  command -v docker >/dev/null 2>&1 || { skip "无 docker"; return; }

  # 需要有一个「已被占用的域名块」来稳定复现 die。
  # 优先用 TEST_DOMAIN（真域名）；没有就造一个本地假域名塞进一个临时 Caddyfile，
  # 用 --caddy-mode self 让脚本去改那份文件 —— 不碰系统反代。
  local td; td="$(mktemp -d)"
  local dom="${TEST_DOMAIN:-a2a-orphan.test}"
  printf '# managed by install-agent2api.sh\n\n%s {\n\trespond "x"\n}\n' "$dom" > "$td/Caddyfile"

  local d c; d="$(inst orphan)"; c="reg-orphan"; rm -rf "$d"
  # --caddy-mode self：让脚本用自建 Caddy 分支，直接改我们的临时文件；
  # --skip-dns-check：跳过 DNS，确保失败点是「域名冲突」而不是网络。
  run_installer --yes --dir "$d" --container "$c" \
                --panel-port "$((P_PORT+80))" --gateway-port "$((G_PORT+80))" \
                --domain "$dom" --caddy-mode self --skip-dns-check
  local r=$RC

  # 断言：失败(rc≠0) + 没有留下同名容器在跑 + 目录里没写成 install.conf
  #      （成功路径一定会有 install.conf；失败路径不该有，且容器应被回收）
  local leftover=0 conf_ok=0
  ctr "$c" || leftover=1                       # 1 = 容器已不在（好）
  [ -f "$d/install.conf" ] && conf_ok=1        # 1 = 有状态文件（说明其实装成了）

  { [ "$r" != 0 ] && [ "$leftover" = 1 ] && [ "$conf_ok" = 0 ]; }
  verdict $? "rc=$r 无残留容器=$leftover 无状态文件=$([ "$conf_ok" = 1 ] && echo 否 || echo 是)"

  # 收尾：无论断言结果如何都要清干净
  docker rm -f "$c" "${c}-caddy" >/dev/null 2>&1 || true
  rm -rf "$d" "$td"
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

case_inode_trap_guard() {
  begin "容器内看不到站点块（inode 陷阱）能被自动检测并自愈"
  # 背景：脚本先建只有注释头的空 Caddyfile，中间隔着「拉起 Caddy 容器」，
  #       最后才追加站点块；容器启动时绑定的是「空文件」的 inode，
  #       之后脚本用 mv 替换文件（原子写法）产生新 inode，容器仍盯着旧的。
  #       结果：宿主上文件完整，容器里只有一行注释头 → 不签证书 → 公网 503。
  #       实测踩过，故此处固化为回归用例。
  #
  # 判据：构造同样的时序，然后调用脚本里的
  #       verify_caddyfile_visible_in_container()，应能检测到并自愈（返回 0）。
  command -v docker >/dev/null 2>&1 || { skip "无 docker"; return; }

  local td cn cn_name="a2a-inode-$$"
  td="$(mktemp -d)"
  cn="$cn_name"

  # 步骤 1：初始化态文件（只有注释头）
  printf '# managed by install-agent2api.sh\n' > "$td/Caddyfile"

  # 步骤 2：起容器并挂载这个空文件
  docker run -d --name "$cn" \
    -v "$td/Caddyfile:/etc/caddy/Caddyfile:ro" \
    --entrypoint sleep caddy:2-alpine infinity >/dev/null 2>&1 \
    || { rm -rf "$td"; skip "无法启动测试容器（可能拉不到 caddy 镜像）"; return; }
  sleep 3

  # 步骤 3：用 mv 替换写入完整内容（与脚本 strip+append 的写法一致）
  cat > "$td/new" <<'CEOF'
# managed by install-agent2api.sh
agent.regress.test {
	reverse_proxy 127.0.0.1:3065
}
CEOF
  mv "$td/new" "$td/Caddyfile"

  # 确认故障确实注入了（否则用例没验证到任何东西）
  local h_md5 c_md5
  h_md5=$(md5sum "$td/Caddyfile" | awk '{print $1}')
  c_md5=$(docker exec "$cn" md5sum /etc/caddy/Caddyfile 2>/dev/null | awk '{print $1}')
  if [ "$h_md5" = "$c_md5" ]; then
    docker rm -f "$cn" >/dev/null 2>&1; rm -rf "$td"
    skip "未复现不一致（inode 被复用），本机不适用"
    return
  fi

  # 调用脚本里的函数（提取函数定义，避开 main）
  local fn=/tmp/.a2a-funcs-$$.sh drv=/tmp/.a2a-drv-$$.sh
  awk '/^main\(\) \{/{exit} {print}' "$INSTALLER" > "$fn"

  cat > "$drv" <<DE0F
#!/usr/bin/env bash
source "$fn"
CADDY_MODE="docker"
CADDY_CONTAINER="$cn"
CADDY_SELF_CONTAINER=""
CADDY_FILE="$td/Caddyfile"
CADDY_INNER="/etc/caddy/Caddyfile"
DRY_RUN=0
verify_caddyfile_visible_in_container
exit \$?
DE0F

  local out rc
  out=$(bash "$drv" 2>&1); rc=$?
  local after_h after_c
  after_h=$(md5sum "$td/Caddyfile" | awk '{print $1}')
  after_c=$(docker exec "$cn" md5sum /etc/caddy/Caddyfile 2>/dev/null | awk '{print $1}')

  docker rm -f "$cn" >/dev/null 2>&1
  rm -rf "$td"; rm -f "$fn" "$drv"

  { [ "$rc" = 0 ] && [ "$after_h" = "$after_c" ] \
      && printf '%s' "$out" | grep -qE 'inode 陷阱|已重新绑定'; }
  verdict $? "rc=$rc 自愈后一致=$([ "$after_h" = "$after_c" ] && echo 是 || echo 否)"
}

case_inode_trap_prefly() {
  begin "inode 校验只在容器 Caddy 模式生效（宿主模式不误报）"
  # 宿主模式的 Caddyfile 没有 bind mount，不该做这项校验，也不该报错。
  local fn=/tmp/.a2a-fn2-$$.sh drv=/tmp/.a2a-dr2-$$.sh
  awk '/^main\(\) \{/{exit} {print}' "$INSTALLER" > "$fn"
  cat > "$drv" <<DE0F
#!/usr/bin/env bash
source "$fn"
CADDY_MODE="host"
CADDY_CONTAINER=""
CADDY_SELF_CONTAINER=""
CADDY_FILE="/etc/caddy/Caddyfile"
CADDY_INNER="/etc/caddy/Caddyfile"
DRY_RUN=0
verify_caddyfile_visible_in_container
exit \$?
DE0F
  local out rc
  out=$(bash "$drv" 2>&1); rc=$?
  rm -f "$fn" "$drv"
  { [ "$rc" = 0 ] && ! printf '%s' "$out" | grep -q 'inode 陷阱'; }
  verdict $? "rc=$rc（宿主模式应静默放行）"
}

case_register_notice_branches() {
  begin "管理员注册告警：四种状态各说各话，且不谎报"
  # 背景：agent2api 是「首个访问者注册管理员」。装完不注册 = 面板裸奔。
  # 原来只在「绑了域名」的分支给一句普通提示，没域名时完全不提。
  # 这里验证四分支：已注册 / 未注册+公网 / 未注册+已封 / 探测不到。
  # 用函数打桩验证分支逻辑（不绕过真实 captcha，只测告警文案走向）。
  local fn=/tmp/.a2a-rn-$$.sh
  awk '/^main\(\) \{/{exit} {print}' "$INSTALLER" > "$fn"
  [ -s "$fn" ] || { skip "无法提取函数定义"; return; }

  local out_stub drv_ok=0
  # 场景 1：已注册 → 应含「已注册」且不含「抢」
  cat > /tmp/.a2a-d1-$$.sh <<D1
#!/usr/bin/env bash
source "$fn"
admin_registered_state() { return 0; }
CONTAINER=x; PANEL_PORT=1; LOCK_REGISTER=n; DOMAIN=test.example
print_register_notice "https://test.example/"
D1
  out_stub=$(bash /tmp/.a2a-d1-$$.sh 2>&1)
  { printf '%s' "$out_stub" | grep -q '已注册' \
      && ! printf '%s' "$out_stub" | grep -q '抢注\|抢先注册'; } && drv_ok=$((drv_ok+1))

  # 场景 2：未注册 + 公网 → 必须醒目警告「抢先」
  cat > /tmp/.a2a-d2-$$.sh <<D2
#!/usr/bin/env bash
source "$fn"
admin_registered_state() { return 1; }
CONTAINER=x; PANEL_PORT=1; LOCK_REGISTER=n; DOMAIN=test.example
print_register_notice "https://test.example/"
D2
  out_stub=$(bash /tmp/.a2a-d2-$$.sh 2>&1)
  { printf '%s' "$out_stub" | grep -q '抢先注册' \
      && printf '%s' "$out_stub" | grep -q '立刻去注册管理员'; } && drv_ok=$((drv_ok+1))

  # 场景 3：未注册 + 已封注册端点 → 应提示走隧道，而不是报警
  cat > /tmp/.a2a-d3-$$.sh <<D3
#!/usr/bin/env bash
source "$fn"
admin_registered_state() { return 1; }
CONTAINER=x; PANEL_PORT=1; LOCK_REGISTER=y; DOMAIN=test.example
print_register_notice "https://test.example/"
D3
  out_stub=$(bash /tmp/.a2a-d3-$$.sh 2>&1)
  { printf '%s' "$out_stub" | grep -q 'ssh -N -L' \
      && ! printf '%s' "$out_stub" | grep -q '抢先注册'; } && drv_ok=$((drv_ok+1))

  # 场景 4：探测不到 → 不许谎报「已注册」，要给可复核判据
  cat > /tmp/.a2a-d4-$$.sh <<D4
#!/usr/bin/env bash
source "$fn"
admin_registered_state() { return 2; }
CONTAINER=x; PANEL_PORT=1; LOCK_REGISTER=n; DOMAIN=test.example
print_register_notice "https://test.example/"
D4
  out_stub=$(bash /tmp/.a2a-d4-$$.sh 2>&1)
  { printf '%s' "$out_stub" | grep -q '读不到' \
      && ! printf '%s' "$out_stub" | grep -q '已注册，面板'; } && drv_ok=$((drv_ok+1))

  rm -f /tmp/.a2a-d1-$$.sh /tmp/.a2a-d2-$$.sh /tmp/.a2a-d3-$$.sh /tmp/.a2a-d4-$$.sh "$fn"
  [ "$drv_ok" = 4 ]
  verdict $? "通过分支 $drv_ok/4"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
preflight

if want A; then
  printf '\n%s[A] 参数校验%s\n' "$FG_B" "$FG_O"
  case_help; case_unknown_arg; case_bad_port_alpha; case_bad_port_range
  case_same_ports; case_bad_expose; case_bad_mem; case_bad_container
  case_rel_dir; case_dryrun_no_side_effect
fi

if want A2; then
  printf '
  %s[A2] 边界与异常（防退化）%s
  ' "$FG_B" "$FG_O"
  case_bad_expose_no_domain; case_conflict_no_domain_and_domain
  case_no_deps_flag; case_upgrade_no_autodeps
  case_arg_missing_value; case_huge_numbers
  case_mem_too_small; case_bad_caddy_mode
  case_inode_trap_prefly
  case_register_notice_branches
fi

if want default; then
  printf '\n%s[B] 默认值路径与幂等%s\n' "$FG_B" "$FG_O"
  case_install_nodomain; case_rerun_idempotent; case_domains_absent_without_flag; case_corrupt_state_file
fi

if want default; then
  printf '\n%s[B4] 反代文件可见性（inode 陷阱回归）%s\n' "$FG_B" "$FG_O"
  case_inode_trap_guard
fi

if want state; then
  printf '\n%s[B2] 状态与版本管理%s\n' "$FG_B" "$FG_O"
  case_status; case_check_update; case_upgrade_same; case_upgrade_rollback

  printf '
  %s[B3] 重跑菜单（交互路径）%s
  ' "$FG_B" "$FG_O"
  case_menu_uninstall; case_menu_upgrade
fi

if want conflict; then
  printf '\n%s[C] 端口与容器名冲突%s\n' "$FG_B" "$FG_O"
  case_port_conflict_auto; case_container_name_conflict
  case_stale_container_not_blocking; case_domain_fail_no_orphan
fi

if want domain; then
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
fi

if want stream; then
  printf '\n%s[D2] 流式（SSE 是否被缓冲）%s\n' "$FG_B" "$FG_O"
  case_streaming
fi

if want uninstall; then
  printf '\n%s[E] 卸载%s\n' "$FG_B" "$FG_O"
  case_uninstall; case_uninstall_without_state
fi

if want recheck; then
  printf '\n%s[F] 回检%s\n' "$FG_B" "$FG_O"
  case_existing_sites
fi

# 兜底清理
cleanup_instance "$D" "$C"
cleanup_instance "$DD" "$DC"
[ -n "${STATE_OWN_D:-}" ] && [ "$STATE_OWN_D" != "$D" ] && cleanup_instance "$STATE_OWN_D" "reg-state-base"
[ -n "${CONFLICT_OWN_D:-}" ] && [ "$CONFLICT_OWN_D" != "$D" ] && cleanup_instance "$CONFLICT_OWN_D" "reg-conflict-base"

printf '\n%s=== 结果 ===%s\n' "$FG_B" "$FG_O"
printf '  通过 %s%d%s   失败 %s%d%s   跳过 %s%d%s\n' \
  "$FG_G" "$PASS" "$FG_O" "$FG_R" "$FAIL" "$FG_O" "$FG_D" "$SKIP" "$FG_O"

# 🔴 「一个用例都没执行」绝不能算通过。
#   实测踩过（两个 bug 叠在一起，只跑一次真机才发现）：
#     ① 文档写 GROUPS=A,A2，代码里判的是 `want args` —— 组名对不上，整块被跳过；
#     ② 更隐蔽：变量名本来叫 GROUPS，而 **GROUPS 是 bash 的只读内建数组**
#        （当前用户的组 ID），赋值被静默忽略，`${GROUPS:-all}` 取到的是 gid 0。
#   两者叠加的结果是「通过 0 失败 0 跳过 0」、退出码 0、CI 一片绿，
#   实际上一条都没测。这种假绿比红灯危险得多。
if [ $((PASS + FAIL)) -eq 0 ]; then
  printf '  %s× 本次没有任何用例被执行%s\n' "$FG_R" "$FG_O"
  printf '    RUN_GROUPS=%s 与实际组名不符。可用组名：\n' "$RUN_GROUPS"
  printf '    A A2 B B2 B3 C D stream uninstall recheck（默认 all）\n'
  FAIL=$((FAIL + 1))
  FAILED+=("（零执行：RUN_GROUPS 拼写有误？）")
fi

if [ "$FAIL" -gt 0 ]; then
  printf '  失败用例：\n'
  for f in "${FAILED[@]}"; do printf '    · %s\n' "$f"; done
fi
[ "$KEEP" = 1 ] || rm -rf "$TEST_ROOT"
exit "$FAIL"
