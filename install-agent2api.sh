#!/usr/bin/env bash
#
# agent2api 一键安装器（交互式）
# ============================================================================
# 把 agent2api（多提供商 OpenAI 兼容网关 + 管理面板）部署到本机，并可选地
# 绑域名、自动申请 SSL 证书、登记为已有 workbuddy-manager 的上游。
#
# 设计要点（都是踩过坑换来的，改动前请先读）：
#   1. 端口自动避让：同时查宿主监听端口与 docker 已发布端口，自动挑空闲的；
#      起容器后再复核一次，若仍冲突就自动换端口重试。
#   2. 反代自动识别：宿主的 Caddy/Nginx 进程、或容器里的 Caddy，都能识别；
#      容器 Caddy 走「加入同一网络 + 按容器名反代」，宿主 Caddy 走 127.0.0.1。
#   3. 改 Caddyfile 固定四步：备份 → 追加（带标记）→ validate → reload；
#      任一步失败自动回滚，绝不让生产反代带病运行。
#   4. 生成的站点块把「公网禁止自助注册」写在 route{} 内 —— 直接写 respond 会被
#      Caddy 按全局指令序排到 handle 之后而永不生效（实测踩过）。
#   5. 幂等：装过再跑会读回状态文件，可重新配置 / 换镜像 tag / 卸载。
#
# 用法：
#   bash install-agent2api.sh                    # 全交互
#   bash install-agent2api.sh --dry-run          # 只打印计划，不动手
#   bash install-agent2api.sh --yes --domain a.example.com --expose both
#   bash install-agent2api.sh --uninstall
#
set -Eeuo pipefail

SCRIPT_VERSION="1.2.0"
DEFAULT_IMAGE_REPO="aimodcc/agent2api"
DEFAULT_TAG="2.7.10"          # 已知可用版本；--tag latest 可跟最新
DEFAULT_DIR="/opt/agent2api"
DEFAULT_CONTAINER="agent2api"
CADDY_IMAGE="caddy:2-alpine"   # self 模式下自建反代用的镜像
DEFAULT_PANEL_PORT="3066"
DEFAULT_GW_PORT="3065"
DEFAULT_MEM="384m"
SETUP_PATH="/api/panel/setup"  # agent2api 的自助注册端点（公网要封掉）
MARK_BEGIN="# >>> agent2api managed block —— 由 install-agent2api.sh 维护，请勿手改 >>>"
MARK_END="# <<< agent2api managed block <<<"
CF_RANGES="173.245.48.0/20 103.21.244.0/22 103.22.200.0/22 103.31.4.0/22 141.101.64.0/18 108.162.192.0/18 190.93.240.0/20 188.114.96.0/20 197.234.240.0/22 198.41.128.0/17 162.158.0.0/15 104.16.0.0/13 104.24.0.0/14 172.64.0.0/13 131.0.72.0/22"

# ── 运行期状态 ──────────────────────────────────────────────────────────────
INSTALL_DIR=""
IMAGE_TAG=""
CONTAINER=""
PANEL_PORT=""
GW_PORT=""
MEM_LIMIT=""
TZ_NAME=""
DOMAIN=""
EXPOSE_MODE=""          # both | panel | gateway | none
LOCK_REGISTER=""
BEHIND_CF=""
MANAGER_INTEGRATE=""
DRY_RUN=0
ASSUME_YES=0
DO_UNINSTALL=0
SKIP_DNS_CHECK=0
DO_UPGRADE=0             # --upgrade
DO_CHECK_UPDATE=0        # --check-update
DO_STATUS=0              # --status
IMAGE_TAG_OVERRIDE=""    # --tag 显式指定的目标版本（升级时用它，别被状态文件覆盖）
NO_DOMAIN=0              # 本次明确不要域名（会摘掉上次写入的站点块）
ADV_GIVEN=0              # 命令行是否显式给过「高级选项」（目录/容器名/端口/内存/时区/镜像版本）
CADDY_MODE_FORCE=""      # --caddy-mode 强制指定的反代形态
CADDY_MODE=""           # docker | host | self | nginx | other | none
CADDY_CONTAINER=""
CADDY_SELF_CONTAINER="" # self 模式下本脚本自建的 Caddy 容器名
CADDY_FILE=""           # 宿主可见路径
CADDY_INNER=""          # 容器内路径（宿主模式同 CAADDY_FILE）
CADDY_NET=""
UPSTREAM_STYLE=""       # container | loopback
CADDY_BACKED_UP=0
BACKUP_FILE=""
LAST_FAIL_KIND=""       # start_container 设置的失败类型：port | name | health | other

# ── 中断保护 ────────────────────────────────────────────────────────────────
# 改共享反代配置的过程中被打断（Ctrl-C / 被 kill），把配置还原回去。
# 不管的话会留下半截无效配置 —— 它当下不发作（运行中的 Caddy 还用着旧配置），
# 等到下次 reload 或重启才炸，是最难排查的那类故障。
on_signal() {
  if [ "$CADDY_BACKED_UP" = 1 ] && [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ]; then
    printf '\n' >&2
    printf '  %s!%s 收到中断信号，正在还原 Caddyfile：%s\n' "$C_YEL" "$C_OFF" "$BACKUP_FILE" >&2
    cp "$BACKUP_FILE" "$CADDY_FILE" 2>/dev/null || true
    if caddy_validate >/dev/null 2>&1 && caddy_reload >/dev/null 2>&1; then
      printf '  %s✓%s 已还原并重载\n' "$C_GRN" "$C_OFF" >&2
    else
      printf '  %s×%s 还原后校验/重载未通过，请手工检查 %s\n' "$C_RED" "$C_OFF" "$CADDY_FILE" >&2
    fi
  fi
  printf '  已中止。容器若已创建，可用 --uninstall 清理。\n' >&2
  exit 130
}
trap on_signal INT TERM

# ── 输出工具 ────────────────────────────────────────────────────────────────
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[36m'; C_DIM=$'\033[2m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_DIM=""; C_BLD=""; C_OFF=""
fi
hr()      { printf '%s\n' "────────────────────────────────────────────────────────────"; }
title()   { printf '\n%s%s%s\n' "$C_BLD$C_BLU" "$1" "$C_OFF"; hr; }
info()    { printf '  %s\n' "$1"; }
ok()      { printf '  %s✓%s %s\n' "$C_GRN" "$C_OFF" "$1"; }
warn()    { printf '  %s!%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
problem() { printf '  %s×%s %s\n' "$C_RED" "$C_OFF" "$1"; }
step()    { printf '\n%s[%s]%s %s\n' "$C_BLD" "$1" "$C_OFF" "$2"; }
die()     { printf '\n%s错误：%s%s\n' "$C_RED" "$1" "$C_OFF" >&2; exit 1; }
run()     { if [ "$DRY_RUN" = 1 ]; then printf '  %s[dry-run]%s %s\n' "$C_DIM" "$C_OFF" "$*"; else "$@"; fi; }

# 交互读取；非 TTY 或 --yes 时直接用默认值（便于自动化/测试）
# ⚠️ 这三个函数的「提示与菜单」必须写 stderr：它们的 stdout 会被 $( ) 捕获，
#    写到 stdout 会把菜单文本混进结果里 —— choose() 曾因此永远匹配不上 case。
ask() {  # ask <提示> <默认值> -> 打印结果
  local prompt="$1" def="$2" ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  printf '  %s [%s]: ' "$prompt" "$def" >&2
  read -r ans || true
  printf '%s' "${ans:-$def}"
}
ask_yn() {  # ask_yn <提示> <y|n> -> 返回 0=是
  local prompt="$1" def="$2" ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then [ "$def" = "y" ]; return; fi
  printf '  %s [%s]: ' "$prompt" "$def" >&2
  read -r ans || true
  ans="${ans:-$def}"
  case "$ans" in y|Y|yes|YES) return 0 ;; *) return 1 ;; esac
}
choose() {  # choose <提示> <默认序号> <选项...> -> 只把序号打到 stdout，菜单走 stderr
  local prompt="$1" def="$2"; shift 2
  local opts=("$@") i=1 ans=""
  for o in "${opts[@]}"; do printf '    %d) %s\n' "$i" "$o" >&2; i=$((i+1)); done
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  printf '  %s [%s]: ' "$prompt" "$def" >&2
  read -r ans || true
  ans="${ans:-$def}"
  case "$ans" in ''|*[!0-9]*) printf '%s' "$def" ;; *)
    if [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then printf '%s' "$ans"; else printf '%s' "$def"; fi ;;
  esac
}

# ── 参数解析 ────────────────────────────────────────────────────────────────
parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)          INSTALL_DIR="$2"; ADV_GIVEN=1; shift 2 ;;
      --tag)          IMAGE_TAG="$2"; IMAGE_TAG_OVERRIDE="$2"; ADV_GIVEN=1; shift 2 ;;
      --container)    CONTAINER="$2"; ADV_GIVEN=1; shift 2 ;;
      --domain)       DOMAIN="$2"; shift 2 ;;
      --expose)       EXPOSE_MODE="$2"; shift 2 ;;
      --panel-port)   PANEL_PORT="$2"; ADV_GIVEN=1; shift 2 ;;
      --gateway-port) GW_PORT="$2"; ADV_GIVEN=1; shift 2 ;;
      --mem)          MEM_LIMIT="$2"; ADV_GIVEN=1; shift 2 ;;
      --tz)           TZ_NAME="$2"; ADV_GIVEN=1; shift 2 ;;
      --cf=*)
        case "${1#--cf=}" in
          y|Y|yes|YES|true|1) BEHIND_CF="y" ;; *) BEHIND_CF="n" ;;
        esac; shift ;;
      --cf)
        # 支持 --cf（=是）、--cf y|n|yes|no|true|false|1|0
        case "${2:-}" in
          y|Y|yes|YES|true|1)   BEHIND_CF="y"; shift 2 ;;
          n|N|no|NO|false|0)    BEHIND_CF="n"; shift 2 ;;
          *)                    BEHIND_CF="y"; shift ;;
        esac ;;
      --no-cf)        BEHIND_CF="n"; shift ;;
      --open-register)   LOCK_REGISTER="n"; shift ;;
      --lock-register)   LOCK_REGISTER="y"; shift ;;
      --with-manager)    MANAGER_INTEGRATE="y"; shift ;;
      --no-manager)      MANAGER_INTEGRATE="n"; shift ;;
      --caddy-mode)   CADDY_MODE_FORCE="$2"; shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --upgrade)      DO_UPGRADE=1; shift ;;
      --check-update) DO_CHECK_UPDATE=1; shift ;;
      --status)       DO_STATUS=1; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      -y|--yes)       ASSUME_YES=1; shift ;;
      --uninstall)    DO_UNINSTALL=1; shift ;;
      --no-domain)    NO_DOMAIN=1; DOMAIN=""; shift ;;
      -h|--help)      usage; exit 0 ;;
      *) die "未知参数：$1（用 --help 看用法）" ;;
    esac
  done
}

usage() {
  cat <<EOF
agent2api 一键安装器 v$SCRIPT_VERSION

用法：bash $0 [选项]

  --dir <路径>            安装目录（默认 $DEFAULT_DIR）
  --tag <版本|latest>     镜像 tag（默认自动查 Docker Hub 最新版；查不到则用内置的 $DEFAULT_TAG）
  --container <名字>      容器名（默认 $DEFAULT_CONTAINER）
  --domain <域名>         绑定域名并自动申请 SSL（不带则沿用上次的；从未装过则不绑）
  --no-domain             明确不要域名：移除上次写入的反代站点块
  --caddy-mode <形态>     强制反代形态：docker（用已有 Caddy 容器）/ host（用宿主 Caddy）/
                          self（自建 Caddy 容器，需 80/443 空闲）。默认自动探测
  --expose <模式>         域名下暴露什么：both|panel|gateway（默认 both）
  --panel-port <端口>     面板端口（默认自动挑：从 $DEFAULT_PANEL_PORT 起找空闲）
  --gateway-port <端口>   网关端口（默认自动挑：从 $DEFAULT_GW_PORT 起找空闲）
  --mem <大小>            容器内存上限（默认 $DEFAULT_MEM）
  --tz <时区>             容器时区（默认 Asia/Shanghai）
  --cf [y|n]              域名是否走 Cloudflare 代理（橙云）。--cf=n 或 --no-cf 表示不走
  --lock-register         公网禁止自助注册（默认开）
  --open-register         不封注册端点（不推荐：首个访客即可注册成管理员）
  --with-manager          把本服务登记为已有 workbuddy-manager 的上游
  --no-manager            不登记（默认交互询问）
  --dry-run               只打印将要做什么，不实际改动
  --status                查看运行状态（容器/端口/域名/证书到期/最近日志）
  --check-update          查询 Docker Hub 上是否有新版本
  --upgrade               升级到最新版（可配合 --tag 指定版本）；健康复检不过自动回滚
  --skip-dns-check        跳过「域名是否解析到本机」的校验（走 CDN 回源时需要）
  -y, --yes               全部用默认值，不交互
  --uninstall             卸载（停容器、可选删目录、移除站点块）
  -h, --help              显示本帮助
EOF
}

# ── 环境探测 ────────────────────────────────────────────────────────────────
# 提示要跟着环境走：很多精简镜像（尤其登录就是 root 的）**根本没装 sudo**，
# 无脑让人「加 sudo」会得到 `sudo: command not found`（真实用户踩过）。
need_root() {
  [ "$(id -u)" = 0 ] && return 0
  if command -v sudo >/dev/null 2>&1; then
    die "需要 root 权限运行。请改用：sudo bash $0 $*"
  else
    die "需要 root 权限运行，但这台机器上没有 sudo。请先 su - 切到 root，再执行：bash $0 $*"
  fi
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker。请先安装 Docker 再运行本脚本。"
  docker info >/dev/null 2>&1 || die "docker 无法连接（守护进程没起？当前用户无权限？）"
  if docker compose version >/dev/null 2>&1; then DC=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
  else die "未找到 docker compose 插件，也没有 docker-compose。"; fi
  ok "docker 就绪（${DC[*]}）"
}

# 宿主上所有被占用的端口（监听 + docker 已发布）
used_ports() {
  { ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://' ;
    docker ps --format '{{.Ports}}' 2>/dev/null | tr ',' '\n' \
      | sed -n 's/.*:\([0-9][0-9]*\)->.*/\1/p' ; } | grep -E '^[0-9]+$' | sort -nu
}
port_free() {
  local p="$1" used
  used=$(used_ports || true)
  if printf '%s\n' "$used" | grep -qx "$p"; then return 1; fi
  return 0
}
# 从 base 起找一个空闲端口（跳过已被本脚本占用的另一个端口）
pick_port() {
  local base="$1" avoid="$2" p used
  used=$(used_ports || true)
  p=$base
  while [ "$p" -lt $((base + 400)) ]; do
    if [ "$p" != "$avoid" ] && ! printf '%s\n' "$used" | grep -qx "$p"; then printf '%s' "$p"; return 0; fi
    p=$((p + 1))
  done
  return 1
}

# 探测已有 Web 反代：返回 docker / host / none
detect_web_server() {
  local c
  # 1) 容器里的 caddy/nginx（按镜像名或容器名判断，再确认它确实发布了 80/443）
  for c in $(docker ps --format '{{.Names}}'); do
    local img; img=$(docker inspect "$c" --format '{{.Config.Image}}' 2>/dev/null || echo "")
    local cmd; cmd=$(docker inspect "$c" --format '{{join .Config.Cmd " "}}' 2>/dev/null || echo "")
    if printf '%s%s%s' "$c" "$img" "$cmd" | grep -qiE 'caddy'; then
      if docker port "$c" 2>/dev/null | grep -qE ':(80|443)$'; then
        CADDY_MODE="docker"; CADDY_CONTAINER="$c"; return 0
      fi
    fi
  done
  # 2) 宿主进程
  local line
  line=$(ss -ltnp 2>/dev/null | grep -E ':(80|443)\s' | head -1 || true)
  if printf '%s' "$line" | grep -qiE 'caddy'; then CADDY_MODE="host"; return 0; fi
  if printf '%s' "$line" | grep -qiE 'nginx'; then
    CADDY_MODE="nginx"; return 0
  fi
  if [ -n "$line" ]; then CADDY_MODE="other"; return 0; fi
  CADDY_MODE="none"
}

# 定位 Caddyfile 与容器内路径
locate_caddyfile() {
  if [ "$CADDY_MODE" = "docker" ]; then
    local mounts src dst
    while IFS= read -r m; do
      [ -z "$m" ] && continue
      src="${m%%|*}"; dst="${m##*|}"
      case "$dst" in
        /etc/caddy/Caddyfile) CADDY_FILE="$src"; CADDY_INNER="$dst"; return 0 ;;
        /etc/caddy)           CADDY_FILE="$src/Caddyfile"; CADDY_INNER="$dst/Caddyfile" ;;
      esac
    done < <(docker inspect "$CADDY_CONTAINER" --format '{{range .Mounts}}{{.Source}}|{{.Destination}}{{println}}{{end}}' 2>/dev/null)
    [ -n "$CADDY_FILE" ] && [ -f "$CADDY_FILE" ] && return 0
    return 1
  fi
  if [ "$CADDY_MODE" = "host" ]; then
    local cfg="/etc/caddy/Caddyfile" unit
    unit=$(systemctl cat caddy 2>/dev/null | sed -n 's/.*--config[= ]\([^ ]*\).*/\1/p' | head -1 || true)
    [ -n "$unit" ] && cfg="$unit"
    if [ -f "$cfg" ]; then CADDY_FILE="$cfg"; CADDY_INNER="$cfg"; return 0; fi
  fi
  return 1
}

# 容器 Caddy 用来访问新容器的网络（优先与反代同网络，其次取反代任意一个网络）
resolve_caddy_net() {
  [ "$CADDY_MODE" = "docker" ] || return 0
  local n
  n=$(docker inspect "$CADDY_CONTAINER" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}}{{"\n"}}{{end}}' 2>/dev/null | grep -v '^$' | head -1 || true)
  CADDY_NET="$n"
}

host_public_ip() {
  local ip=""
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -s --max-time 8 "$u" 2>/dev/null | tr -d '[:space:]' || true)
    case "$ip" in *[!0-9.]*|"") ip="" ;; *) break ;; esac
  done
  printf '%s' "$ip"
}

# 端口是否空闲（80/443 这类必须独占的端口，起容器前先问清楚）
check_ports_free() {
  local p busy=""
  for p in "$@"; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}$"; then busy="${busy} ${p}"; fi
  done
  if [ -n "$busy" ]; then
    problem "端口${busy} 已被占用，无法由本脚本自建反代申请证书"
    info "方案：① 停掉占用者；② 改用 --no-domain（走 SSH 隧道访问面板）；"
    info "      ③ 自己把域名反代到 127.0.0.1:${PANEL_PORT} 与 127.0.0.1:${GW_PORT}。"
    return 1
  fi
  return 0
}

# 决定用哪种反代形态。裸机（没有现成反代）时自建一个 Caddy 容器。
decide_caddy_mode() {
  # 手动强制（也可用于自动探测不准的场合）
  case "${CADDY_MODE_FORCE:-}" in
    docker|host|self)
      CADDY_MODE="$CADDY_MODE_FORCE"
      info "按 --caddy-mode 指定反代形态：${CADDY_MODE}" ;;
  esac

  # 自建 Caddy 的公共设置
  setup_self_caddy() {
    CADDY_MODE="self"
    CADDY_SELF_CONTAINER="${CONTAINER}-caddy"
    CADDY_FILE="${INSTALL_DIR}/Caddyfile"
    CADDY_INNER="/etc/caddy/Caddyfile"
    UPSTREAM_STYLE="container"
  }

  if [ "$CADDY_MODE" = "self" ]; then
    if [ -z "$DOMAIN" ]; then
      warn "自建 Caddy 但没有域名 —— 没有站点要服务，按「不用反代」处理"
      CADDY_MODE="none"; UPSTREAM_STYLE="loopback"
      return 0
    fi
    setup_self_caddy
    info "将由本脚本自建 Caddy 容器签发证书（容器名 ${CADDY_SELF_CONTAINER}）"
    check_ports_free 80 443 || die "端口占用，已中止（未做任何改动）。"
    return 0
  fi

  [ -n "$DOMAIN" ] || return 0
  case "$CADDY_MODE" in
    docker|host) return 0 ;;
    none)
      info "未发现反向代理 —— 将由本脚本自建 Caddy 容器来签发证书（需 80/443 空闲）"
      setup_self_caddy
      check_ports_free 80 443 || die "端口占用，已中止（未做任何改动）。"
      ;;
    *)
      problem "80/443 被 ${CADDY_MODE} 占用，本脚本只自动写 Caddy 配置"
      print_nginx_hint
      die "已中止（未做任何改动）。"
      ;;
  esac
  return 0
}

# ── Caddy 操作封装（宿主 / 容器两种形态）────────────────────────────────────
caddy_validate() {
  case "$CADDY_MODE" in
    docker)
      run docker exec "$CADDY_CONTAINER" caddy validate --config "$CADDY_INNER" >/tmp/.a2a-validate 2>&1 ;;
    self)
      # 容器还没起，用一次性容器校验（宿主上不一定有 caddy 二进制）
      run docker run --rm -v "${CADDY_FILE}:/etc/caddy/Caddyfile:ro" \
          "${CADDY_IMAGE}" caddy validate --config /etc/caddy/Caddyfile >/tmp/.a2a-validate 2>&1 ;;
    *)
      run caddy validate --config "$CADDY_FILE" >/tmp/.a2a-validate 2>&1 ;;
  esac
  grep -q "Valid configuration" /tmp/.a2a-validate
}
caddy_reload() {
  local out rc
  case "$CADDY_MODE" in
    docker|self)
      local target_c="$CADDY_CONTAINER"
      [ "$CADDY_MODE" = "self" ] && target_c="$CADDY_SELF_CONTAINER"
      if [ "$CADDY_MODE" = "self" ] && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$target_c"; then
        run compose up -d --remove-orphans    # 容器还没起：up 即生效
        return $?
      fi
      if [ "$DRY_RUN" = 1 ]; then
        run docker exec "$target_c" caddy reload --config "$CADDY_INNER"
        return 0
      fi
      # Caddy 的 reload 会往 stdout 打一串 JSON 日志，混进脚本输出很难看 —— 收起来，
      # 只在失败时回显尾部，既不吵又不丢诊断信息
      set +e
      out=$(docker exec "$target_c" caddy reload --config "$CADDY_INNER" --force 2>&1); rc=$?
      set -e
      if [ "$rc" != 0 ]; then
        problem "Caddy 重载失败，原始输出："
        printf '%s\n' "$out" | tail -6 | sed 's/^/    /'
        return 1
      fi
      return 0 ;;
    *)
      if systemctl is-active --quiet caddy 2>/dev/null; then
        run systemctl reload caddy
      else
        run caddy reload --config "$CADDY_FILE"
      fi ;;
  esac
}

# 从 Caddyfile 摘掉本脚本的托管块（靠标记）
strip_managed_block() {
  local f="$1" tmp
  tmp=$(mktemp)
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1}
    skip != 1 {print}
    $0 == e {skip=0}
  ' "$f" > "$tmp"
  cat "$tmp" > "$f"
  rm -f "$tmp"
}

# ── 状态文件 ────────────────────────────────────────────────────────────────
state_file() { printf '%s/install.conf' "$INSTALL_DIR"; }
save_state() {
  [ "$DRY_RUN" = 1 ] && return 0
  install -d -m 700 "$INSTALL_DIR"
  cat > "$(state_file)" <<EOF
# agent2api 安装状态（install-agent2api.sh v$SCRIPT_VERSION 生成）
INSTALL_DIR=$INSTALL_DIR
IMAGE_TAG=$IMAGE_TAG
CONTAINER=$CONTAINER
PANEL_PORT=$PANEL_PORT
GW_PORT=$GW_PORT
MEM_LIMIT=$MEM_LIMIT
TZ_NAME=$TZ_NAME
DOMAIN=$DOMAIN
EXPOSE_MODE=$EXPOSE_MODE
LOCK_REGISTER=$LOCK_REGISTER
BEHIND_CF=$BEHIND_CF
CADDY_MODE=$CADDY_MODE
CADDY_CONTAINER=$CADDY_CONTAINER
CADDY_FILE=$CADDY_FILE
CADDY_INNER=$CADDY_INNER
CADDY_NET=$CADDY_NET
UPSTREAM_STYLE=$UPSTREAM_STYLE
EOF
  chmod 600 "$(state_file)"
}
load_state() { [ -f "$(state_file)" ] && . "$(state_file)" && return 0 || return 1; }

# ── 交互采集配置 ────────────────────────────────────────────────────────────
gather_config() {
  local existing=0
  if [ -n "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/install.conf" ]; then existing=1; fi
  if [ "$existing" = 1 ] && [ "$DO_UNINSTALL" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    title "检测到已安装"
    info "目录：$INSTALL_DIR"
    info "容器：$CONTAINER    面板端口：$PANEL_PORT    网关端口：$GW_PORT"
    info "域名：${DOMAIN:-（无）}"
    local c; c=$(choose "要做什么？" 1 "重新配置并重启容器" "只升级镜像到新 tag" "卸载" "退出")
    case "$c" in
      1) : ;;
      2) local t; t=$(ask "新的镜像 tag" "latest"); IMAGE_TAG="$t"; return 0 ;;
      3) DO_UNINSTALL=1; return 0 ;;
      4) exit 0 ;;
    esac
  fi

  title "agent2api 安装配置"
  info "直接回车 = 用括号里的默认值"
  if [ "$ASSUME_YES" = 1 ]; then
    info "${C_DIM}（--yes 模式：全部使用默认值）${C_OFF}"
  elif [ ! -t 0 ]; then
    # 🔴 不能静默！stdin 不是终端时 ask() 会直接返回默认值 —— 用户会以为"脚本坏了、一个问题都不问"。
    warn "当前不是交互终端（stdin 不是 tty）：所有问题将自动采用默认值。"
    info "${C_DIM}想逐项选择，请在终端里直接执行：bash $0${C_OFF}"
  fi

  # ── 第 1 步：域名。它决定你后面**怎么访问**，是最关键的决策，所以放最前 ──
  if [ -z "$DOMAIN" ] && [ "$NO_DOMAIN" != 1 ]; then
    printf '\n' >&2
    info "【第 1 步】要不要绑域名？"
    printf '        %s绑  → 自动申请 HTTPS 证书，客户端用 https://你的域名/v1（推荐）%s\n' "$C_DIM" "$C_OFF"
    printf '        %s不绑 → 只能走 SSH 隧道，客户端用 http://127.0.0.1:<网关端口>/v1%s\n' "$C_DIM" "$C_OFF"
    printf '        %s（不绑的话，域名解析这一步和证书都不用管）%s\n' "$C_DIM" "$C_OFF"
    DOMAIN=$(ask "域名（没有就直接回车）" "")
  fi
  if [ -n "$DOMAIN" ]; then
    DOMAIN=$(printf '%s' "$DOMAIN" | sed -E 's#^[a-zA-Z]+://##; s#/.*$##; s/\.$//')
    if [ -z "$EXPOSE_MODE" ]; then
      local m; m=$(choose "域名下暴露哪些路径？" 1 \
        "面板 + 网关（/v1* 走网关，其余走面板）" "只暴露面板" "只暴露网关 /v1")
      case "$m" in 1) EXPOSE_MODE=both ;; 2) EXPOSE_MODE=panel ;; 3) EXPOSE_MODE=gateway ;; esac
    fi
    if [ -z "$LOCK_REGISTER" ]; then
      printf '\n' >&2
      info "${C_DIM}agent2api 默认「首个访问者注册管理员」。域名签证书后主机名会进 CT 日志被公开索引，${C_OFF}"
      info "${C_DIM}不封注册等于把这台管理台交给陌生人。注册可改走 SSH 隧道。${C_OFF}"
      if ask_yn "从公网禁止自助注册？（强烈建议 y）" "y"; then LOCK_REGISTER="y"; else LOCK_REGISTER="n"; fi
    fi
    if [ -z "$BEHIND_CF" ]; then
      if ask_yn "该域名是否走 Cloudflare 代理（橙云）？" "n"; then BEHIND_CF="y"; else BEHIND_CF="n"; fi
    fi
  else
    EXPOSE_MODE="none"; LOCK_REGISTER="${LOCK_REGISTER:-y}"; BEHIND_CF="n"
  fi

  # ── 第 2 步：高级选项。默认**一个都不问** —— 小白不该被问容器名/时区/内存 ──
  local adv=1
  # 只在「交互 + 用户没在命令行给过高级参数」时才问这个开关。
  # ⚠️ 不能用「变量是否为空」判断 —— --dir/状态文件预填都会让它们非空，开关就永远不生效了。
  if [ "$ASSUME_YES" = 0 ] && [ -t 0 ] && [ "$ADV_GIVEN" = 0 ]; then
    printf '\n' >&2
    info "【第 2 步】高级选项：安装目录 / 容器名 / 端口 / 内存 / 时区 / 镜像版本"
    info "${C_DIM}  这些默认值都挑好了，一般不用改${C_OFF}"
    ask_yn "需要改吗？" "n" || adv=0
  fi

  if [ "$adv" = 0 ]; then
    # 不问，但值仍要定下来（端口照样自动避让，只是不打扰用户）
    : "${INSTALL_DIR:=$DEFAULT_DIR}"
    : "${CONTAINER:=$DEFAULT_CONTAINER}"
    : "${TZ_NAME:=Asia/Shanghai}"
    : "${MEM_LIMIT:=$DEFAULT_MEM}"
    if [ -z "$IMAGE_TAG" ]; then
      IMAGE_TAG=$(docker_hub_latest_tag || true)
      [ -n "$IMAGE_TAG" ] || IMAGE_TAG="$DEFAULT_TAG"
    fi
    [ -n "$PANEL_PORT" ] || PANEL_PORT=$(pick_port "$DEFAULT_PANEL_PORT" "" || echo "$DEFAULT_PANEL_PORT")
    [ -n "$GW_PORT" ]    || GW_PORT=$(pick_port "$DEFAULT_GW_PORT" "$PANEL_PORT" || echo "$DEFAULT_GW_PORT")
    [ "$PANEL_PORT" != "$GW_PORT" ] || die "面板端口与网关端口不能相同（都是 $PANEL_PORT）"
  else
    [ -n "$INSTALL_DIR" ] || INSTALL_DIR=$(ask "安装目录" "$DEFAULT_DIR")
    [ -n "$CONTAINER" ]   || CONTAINER=$(ask "容器名" "$DEFAULT_CONTAINER")
    [ -n "$TZ_NAME" ]     || TZ_NAME=$(ask "容器时区" "Asia/Shanghai")

    if [ -z "$IMAGE_TAG" ]; then
      local latest; latest=$(docker_hub_latest_tag || true)
      if [ -n "$latest" ]; then
        IMAGE_TAG=$(ask "镜像版本（Docker Hub 最新为 $latest）" "$latest")
      else
        IMAGE_TAG=$(ask "镜像版本" "$DEFAULT_TAG")
      fi
    fi

    # 端口：自动避让
    if [ -z "$PANEL_PORT" ]; then
      local auto_panel; auto_panel=$(pick_port "$DEFAULT_PANEL_PORT" "" || echo "$DEFAULT_PANEL_PORT")
      local ans; ans=$(ask "面板端口（$DEFAULT_PANEL_PORT 被占用时自动从它起找空闲）" "$auto_panel")
      PANEL_PORT="$ans"
    fi
    if [ -z "$GW_PORT" ]; then
      local auto_gw; auto_gw=$(pick_port "$DEFAULT_GW_PORT" "$PANEL_PORT" || echo "$DEFAULT_GW_PORT")
      local ans2; ans2=$(ask "网关端口" "$auto_gw")
      GW_PORT="$ans2"
    fi
    [ "$PANEL_PORT" != "$GW_PORT" ] || die "面板端口与网关端口不能相同（都是 $PANEL_PORT）"

    # 端口占用明确告警（用户手动指定的情况）
    if ! port_free "$PANEL_PORT"; then warn "端口 $PANEL_PORT 已被占用，启动失败时脚本会自动换端口重试"; fi
    if ! port_free "$GW_PORT";    then warn "端口 $GW_PORT 已被占用，启动失败时脚本会自动换端口重试"; fi

    [ -n "$MEM_LIMIT" ] || MEM_LIMIT=$(ask "容器内存上限" "$DEFAULT_MEM")
  fi

  # workbuddy-manager 集成（只在交互 + 高级选项开启时问）
  if [ -z "$MANAGER_INTEGRATE" ]; then
    if [ "$adv" = 1 ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'workbuddy-manager'; then
      printf '\n' >&2
      if ask_yn "检测到 workbuddy-manager，要把本服务登记为它的上游吗？" "n"; then
        MANAGER_INTEGRATE="y"; else MANAGER_INTEGRATE="n"; fi
    else
      MANAGER_INTEGRATE="n"
    fi
  fi
}

docker_hub_latest_tag() {
  curl -s --max-time 10 "https://hub.docker.com/v2/repositories/${DEFAULT_IMAGE_REPO}/tags?page_size=25" 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*"name":"\([^"]*\)".*/\1/p' \
    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' \
    | sort -t. -k1,1n -k2,2n -k3,3n | tail -1
}

# 只读预检：目标域名是否已被「非本脚本托管」的站点块占用。
# 放在起容器之前 —— 冲突是「还没动手就该知道」的事，不该等容器都拉起来了才失败。
precheck_domain_conflict() {
  [ -n "$DOMAIN" ] || return 1
  [ -n "$CADDY_FILE" ] && [ -f "$CADDY_FILE" ] || return 1
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" -v dom="$DOMAIN" '
    $0 == b {skip=1; next}
    $0 == e {skip=0; next}
    skip {next}
    $0 ~ "^[ \t]*" dom "([ \t,]|\\{|$)" {found=1}
    END {exit(found ? 0 : 1)}
  ' "$CADDY_FILE"
}

# 把上次的选择当作本次的默认值 —— 只填「本次命令行没显式给出」的项。
# 没有这一步的话，`--yes` 重跑会把上次的域名/端口全丢回默认值，
# 而磁盘上还留着旧站点块指着旧端口 —— 静默产出一个 502 的域名。
prefill_from_saved() {
  local sf="${INSTALL_DIR}/install.conf"
  [ -f "$sf" ] || return 0
  local line k v reused=0
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      IMAGE_TAG)     if [ -z "$IMAGE_TAG" ];   then IMAGE_TAG="$v";   reused=1; fi ;;
      CONTAINER)     if [ -z "$CONTAINER" ];   then CONTAINER="$v";   reused=1; fi ;;
      PANEL_PORT)    if [ -z "$PANEL_PORT" ];  then PANEL_PORT="$v";  reused=1; fi ;;
      GW_PORT)       if [ -z "$GW_PORT" ];     then GW_PORT="$v";     reused=1; fi ;;
      MEM_LIMIT)     if [ -z "$MEM_LIMIT" ];   then MEM_LIMIT="$v";   reused=1; fi ;;
      TZ_NAME)       if [ -z "$TZ_NAME" ];     then TZ_NAME="$v";     reused=1; fi ;;
      DOMAIN)        if [ "$NO_DOMAIN" != 1 ] && [ -z "$DOMAIN" ]; then DOMAIN="$v"; reused=1; fi ;;
      EXPOSE_MODE)   if [ -z "$EXPOSE_MODE" ];  then EXPOSE_MODE="$v"; reused=1; fi ;;
      LOCK_REGISTER) if [ -z "$LOCK_REGISTER" ];then LOCK_REGISTER="$v"; reused=1; fi ;;
      BEHIND_CF)     if [ -z "$BEHIND_CF" ];   then BEHIND_CF="$v";   reused=1; fi ;;
    esac
  done < "$sf"
  [ "$reused" = 1 ] && info "已读回上次的配置作为默认值（命令行显式给出的以命令行为准）"
  return 0
}

# 本次明确不要域名（--no-domain）时，把上次写进反代的托管块摘掉 ——
# 否则它会指着旧端口变成一份没人察觉的死配置。
maybe_remove_site_block() {
  [ "$NO_DOMAIN" = 1 ] || return 0
  # 没绑域名时 CADDY_FILE 不会被探测赋值；自建模式下的路径是固定的
  [ -n "$CADDY_FILE" ] || CADDY_FILE="${INSTALL_DIR}/Caddyfile"
  if [ ! -f "$CADDY_FILE" ] || ! grep -qF "$MARK_BEGIN" "$CADDY_FILE"; then
    info "本次不绑域名，也没有残留站点块"
    return 0
  fi
  info "本次明确不绑域名（--no-domain），移除上次写入的站点块"
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 将移除托管块并重载"
    return 0
  fi
  cp "$CADDY_FILE" "${CADDY_FILE}.bak-$(date +%Y%m%d-%H%M%S)-preRemoveAgent2API"
  strip_managed_block "$CADDY_FILE"

  local self_c="${CADDY_SELF_CONTAINER:-${CONTAINER}-caddy}"
  if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$self_c"; then
    # 自建 Caddy：容器已不在 compose 文件里，会随 up --remove-orphans 收走，
    # 不必（也无法）reload 一个即将消失的容器
    ok "站点块已移除（自建 Caddy 容器随 compose 一并收走）"
    return 0
  fi
  if caddy_validate; then
    caddy_reload && ok "站点块已移除并重载"
  else
    problem "移除后校验失败，已回滚"
    cp "$(ls -t "${CADDY_FILE}".bak-*-preRemoveAgent2API | head -1)" "$CADDY_FILE"
  fi
}

# ── 输入校验 ────────────────────────────────────────────────────────────────
# 参数可以来自命令行，必须自己兜住。否则非法值会一路带到 docker / Caddy 才炸，
# 而且往往是「静默生成了一份坏配置」这种最难排查的形态（例如 --expose foo
# 会生成一个空 route，域名直接整体不通）。
validate_inputs() {
  local bad=0

  # 安装目录：必须绝对路径（相对路径会解析到不可预期的位置），并去掉末尾斜杠
  case "$INSTALL_DIR" in
    /*) : ;;
    *)  INSTALL_DIR="${PWD%/}/${INSTALL_DIR}" ;;
  esac
  INSTALL_DIR="${INSTALL_DIR%/}"
  [ -n "$INSTALL_DIR" ] || INSTALL_DIR="$DEFAULT_DIR"
  case "$INSTALL_DIR" in
    *[[:space:]]*) warn "安装目录含空格：$INSTALL_DIR（docker 卷挂载可能出问题，建议换一个）" ;;
  esac

  # 端口：1-65535 的整数，且两者不同
  local p
  for p in "$PANEL_PORT" "$GW_PORT"; do
    if ! printf '%s' "$p" | grep -qE '^[0-9]+$'; then
      problem "端口必须是数字：'$p'"; bad=1; continue
    fi
    if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then
      problem "端口超出范围（1-65535）：$p"; bad=1
    fi
    if [ "$p" -lt 1024 ]; then
      warn "端口 $p 是特权端口（<1024），可能与其他系统服务冲突"
    fi
  done
  [ "$PANEL_PORT" != "$GW_PORT" ] || { problem "面板端口与网关端口不能相同（都是 $PANEL_PORT）"; bad=1; }

  # 暴露模式：只接受三个合法值
  case "$EXPOSE_MODE" in
    both|panel|gateway|none) : ;;
    '') EXPOSE_MODE="none" ;;
    *)  problem "--expose 只能是 both / panel / gateway，收到：'$EXPOSE_MODE'"; bad=1 ;;
  esac
  # 有域名却没暴露任何东西（例如交互菜单选择没生效）→ 兜回 both，避免生成空 route
  if [ -n "$DOMAIN" ] && [ "$EXPOSE_MODE" = "none" ]; then
    warn "已绑定域名但暴露模式为空，按 both（面板 + 网关）处理"
    EXPOSE_MODE="both"
  fi

  # 内存上限：形如 256m / 512m / 1g
  if ! printf '%s' "$MEM_LIMIT" | grep -qE '^[0-9]+[bkmgBKMG]?$'; then
    problem "内存上限格式不对（示例 256m / 512m / 1g）：'$MEM_LIMIT'"; bad=1
  fi

  # 镜像 tag / 容器名：按 docker 的字符集
  if ! printf '%s' "$IMAGE_TAG" | grep -qE '^[A-Za-z0-9_][A-Za-z0-9._-]*$'; then
    problem "镜像 tag 含非法字符：'$IMAGE_TAG'"; bad=1
  fi
  if ! printf '%s' "$CONTAINER" | grep -qE '^[A-Za-z0-9][A-Za-z0-9_.-]*$'; then
    problem "容器名不合法（须字母数字开头，只含字母数字 _ . -）：'$CONTAINER'"; bad=1
  fi

  # 域名：统一小写、去末尾点，再做基本形态校验
  if [ -n "$DOMAIN" ]; then
    DOMAIN=$(printf '%s' "$DOMAIN" | tr 'A-Z' 'a-z' | sed -E 's/\.$//')
    if ! printf '%s' "$DOMAIN" | grep -qE '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$'; then
      problem "域名格式看着不对：'$DOMAIN'"; bad=1
    fi
  fi

  # 暴露网关但不暴露面板时，面板就没入口了 —— 注册管理员得靠隧道，明确告知
  if [ -n "$DOMAIN" ] && [ "$EXPOSE_MODE" = "gateway" ]; then
    warn "只暴露了 /v1 网关，面板不在域名上。注册管理员/加账号请用 SSH 隧道："
    info "    ssh -N -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} <本机>  → http://127.0.0.1:${PANEL_PORT}"
  fi

  [ "$bad" = 0 ] || die "上面几项参数不合法，已中止（未做任何改动）。"
}

# ── 生成与启动 ──────────────────────────────────────────────────────────────
gen_compose() {
  local nets_block="" net_decl="" caddy_service=""
  case "$CADDY_MODE" in
    docker)
      if [ -n "$CADDY_NET" ]; then
        # 与已有 Caddy 容器同网络，按容器名反代
        UPSTREAM_STYLE="container"
        nets_block="    networks:
      - ${CADDY_NET}
"
        net_decl="
networks:
  ${CADDY_NET}:
    external: true
"
      else
        UPSTREAM_STYLE="loopback"
      fi ;;
    self)
      # 自建 Caddy：与 agent2api 同属这个 compose 项目，默认网络内按容器名互访
      UPSTREAM_STYLE="container"
      caddy_service="
  ${CADDY_SELF_CONTAINER}:
    image: ${CADDY_IMAGE}
    container_name: ${CADDY_SELF_CONTAINER}
    restart: unless-stopped
    ports:
      - \"80:80\"
      - \"443:443\"
      - \"443:443/udp\"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./caddy-data:/data
      - ./caddy-config:/config
" ;;
    *) UPSTREAM_STYLE="loopback" ;;
  esac

  # 面板与网关都在回环上留口：面板供本机/SSH 隧道注册管理员，网关供本机客户端或宿主反代
  local ports_block="      - \"127.0.0.1:${PANEL_PORT}:${PANEL_PORT}\"
      - \"127.0.0.1:${GW_PORT}:${GW_PORT}\"
"

  run install -d -m 755 "$INSTALL_DIR"
  if [ "$CADDY_MODE" = "self" ]; then
    # 必须先让 Caddyfile 存在：compose 的 bind mount 指向不存在的文件时，
    # docker 会悄悄创建一个**同名目录**，之后 Caddy 起不来且原因极难看出。
    if [ ! -f "$CADDY_FILE" ]; then
      run sh -c "printf '# managed by install-agent2api.sh\n' > '$CADDY_FILE'"
    fi
    run install -d -m 755 "$INSTALL_DIR/caddy-data" "$INSTALL_DIR/caddy-config"
  fi
  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 将写入 $INSTALL_DIR/docker-compose.yml（镜像 ${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}，面板 $PANEL_PORT，网关 $GW_PORT）"
    [ "$CADDY_MODE" = "self" ] && info "[dry-run] 并追加自建 Caddy 服务 ${CADDY_SELF_CONTAINER}（占 80/443）"
    info "[dry-run] 反代后端形态：${UPSTREAM_STYLE}"
    return 0
  fi
  cat > "$INSTALL_DIR/docker-compose.yml" <<EOF
# 由 install-agent2api.sh v$SCRIPT_VERSION 生成（$(date +%F' '%T)）
# 手工改动会被下次运行覆盖；要改请改 install.conf 再重跑脚本。
services:
  ${CONTAINER}:
    image: ${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}
    container_name: ${CONTAINER}
    restart: unless-stopped
    mem_limit: ${MEM_LIMIT}
    memswap_limit: ${MEM_LIMIT}
    environment:
      TZ: ${TZ_NAME}
      AGENT2API_PANEL_PORT: "${PANEL_PORT}"
      AGENT2API_PROXY_PORT: "${GW_PORT}"
      AGENT2API_CAPTCHA_ENABLED: "1"
    ports:
${ports_block}    volumes:
      - ./data:/data
${nets_block}${caddy_service}${net_decl}
EOF
  ok "已生成 $INSTALL_DIR/docker-compose.yml"
}

compose() { ( cd "$INSTALL_DIR" && "${DC[@]}" "$@" ); }

start_container() {
  step "3/6" "拉取镜像并启动容器"
  LAST_FAIL_KIND=""
  run compose pull --quiet || warn "拉取镜像出错，尝试继续"
  if [ "$DRY_RUN" = 1 ]; then
    run compose up -d --remove-orphans
    info "[dry-run] 跳过健康检查"
    return 0
  fi

  local out rc
  set +e
  # --remove-orphans：上次跑过带域名的安装、这次 --no-domain 时，
  # 自建 Caddy 已不在 compose 文件里，靠它把孤儿容器收走
  out=$(compose up -d --remove-orphans 2>&1); rc=$?
  set -e
  if [ "$rc" != 0 ]; then
    problem "compose up 失败，docker 原始输出："
    printf '%s\n' "$out" | grep -v '^$' | tail -6 | sed 's/^/    /'
    # 如实分型：别再让使用者去猜原因
    case "$out" in
      *"is already in use"*|*"Conflict. The container name"*)
        LAST_FAIL_KIND="name"
        warn "原因：容器名 ${CONTAINER} 已被占用（同机装了第二份，或上次没清干净）"
        info "处置：加 --container <别的名字>，或先执行 docker rm -f ${CONTAINER}"
        ;;
      *"address already in use"*|*"port is already allocated"*|*"bind"*)
        LAST_FAIL_KIND="port"
        warn "原因：端口被占用（接下来会自动换端口重试）"
        ;;
      *) LAST_FAIL_KIND="other" ;;
    esac
    return 1
  fi

  local i
  for i in $(seq 1 30); do
    local st; st=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "")
    [ "$st" = "healthy" ] && { ok "容器已就绪（healthy）"; return 0; }
    sleep 2
  done
  LAST_FAIL_KIND="health"
  warn "30 次探测后仍未 healthy，最后日志："
  docker logs --tail 15 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
  return 1
}

verify_ports_bound() {
  [ "$DRY_RUN" = 1 ] && return 0
  # 关键：必须从**容器内部**验证，不能只看宿主监听。
  # docker-proxy 会把宿主端口绑上（哪怕容器里根本没有进程在听），
  # 只看宿主端口会出现「校验通过但一访问就 502」的假通过 —— 实测踩过。
  docker exec "$CONTAINER" curl -sf --max-time 6 "http://127.0.0.1:${GW_PORT}/health" >/dev/null 2>&1 || return 1
  docker exec "$CONTAINER" curl -sf --max-time 6 "http://127.0.0.1:${PANEL_PORT}/"      >/dev/null 2>&1 || return 1
  return 0
}

# 启动失败或端口没绑上时自动换端口重试
# （用户手填的端口可能刚好被别的服务占走；也让上面的告警文案说话算数）
retry_with_free_ports() {
  local attempt np ng
  for attempt in 1 2 3; do
    np=$(pick_port $((PANEL_PORT + 1)) "" || true)
    ng=$(pick_port $((GW_PORT + 1)) "${np:-}" || true)
    if [ -z "$np" ] || [ -z "$ng" ]; then
      problem "从 $((PANEL_PORT + 1)) 起找不到两个空闲端口，放弃自动重试"
      return 1
    fi
    warn "改用端口：面板 $np / 网关 $ng（第 $attempt 次重试）"
    PANEL_PORT="$np"; GW_PORT="$ng"
    run compose down >/dev/null 2>&1 || true
    gen_compose
    if start_container && verify_ports_bound; then
      ok "换端口后启动成功"
      return 0
    fi
  done
  return 1
}

# ── 站点块生成 ──────────────────────────────────────────────────────────────
gen_site_block() {
  local tgt_panel tgt_gw proxy_extra=""
  if [ "$UPSTREAM_STYLE" = "container" ]; then
    tgt_panel="${CONTAINER}:${PANEL_PORT}"
    tgt_gw="${CONTAINER}:${GW_PORT}"
  else
    tgt_panel="127.0.0.1:${PANEL_PORT}"
    tgt_gw="127.0.0.1:${GW_PORT}"
  fi
  if [ "$BEHIND_CF" = "y" ]; then
    proxy_extra="		trusted_proxies static ${CF_RANGES}
"
  fi

  local routes=""
  # 注册封锁 —— 必须放在 route{} 内，否则会被 Caddy 排到 handle 之后而失效
  if [ "$LOCK_REGISTER" = "y" ]; then
    routes="${routes}		# 公网禁止自助注册：不封的话首个扫到本域名的访客就能注册成管理员
		@setup {
			method POST
			path ${SETUP_PATH}
		}
		respond @setup 403

"
  fi
  case "$EXPOSE_MODE" in
    both)
      routes="${routes}		@v1 path /v1 /v1/*

		handle @v1 {
			reverse_proxy ${tgt_gw} {
${proxy_extra}				header_up X-Forwarded-Proto https
			}
		}
		handle {
			reverse_proxy ${tgt_panel} {
${proxy_extra}				header_up X-Forwarded-Proto https
			}
		}"
      ;;
    panel)
      routes="${routes}		handle {
			reverse_proxy ${tgt_panel} {
${proxy_extra}				header_up X-Forwarded-Proto https
			}
		}"
      ;;
    gateway)
      routes="${routes}		handle {
			reverse_proxy ${tgt_gw} {
${proxy_extra}				header_up X-Forwarded-Proto https
			}
		}"
      ;;
  esac

  cat <<EOF

${MARK_BEGIN}
# 站点：${DOMAIN}（agent2api；暴露模式=${EXPOSE_MODE}；注册封锁=${LOCK_REGISTER}；CF 代理=${BEHIND_CF}）
# 生成时间：$(date +%F' '%T)
# 注意：拦截规则必须写在 route 内 —— 直接写 respond 会被 Caddy 按全局指令序排到
#       handle 块之后，而 handle 是终结性的，规则等于永远不生效（实测踩过）。
${DOMAIN} {
	encode zstd gzip

	header {
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		X-Content-Type-Options "nosniff"
		X-Frame-Options "DENY"
		Referrer-Policy "no-referrer"
		-Server
	}

	route {
${routes}
	}

	log {
		output stdout
		format filter {
			wrap console
			fields {
				request>headers>Authorization delete
				request>headers>Cookie delete
				request>headers>Set-Cookie delete
			}
		}
		level INFO
	}
}
${MARK_END}
EOF
}

apply_domain() {
  [ -n "$DOMAIN" ] || return 0
  step "5/6" "绑定域名 ${DOMAIN} 并申请证书"

  [ "$CADDY_MODE" = "docker" ] || [ "$CADDY_MODE" = "host" ] || [ "$CADDY_MODE" = "self" ] \
    || die "当前反代形态（$CADDY_MODE）无法自动配置域名。用 --no-domain 走隧道，或自行反代到 127.0.0.1:${PANEL_PORT}（面板）/ :${GW_PORT}（网关）。"
  if [ "$CADDY_MODE" = "self" ]; then
    install -d -m 755 "$INSTALL_DIR"
    [ -f "$CADDY_FILE" ] || printf '# managed by install-agent2api.sh\n' > "$CADDY_FILE"
  else
    locate_caddyfile || die "找到了 Caddy，但没定位到 Caddyfile，请手动配置后再试。"
  fi

  # DNS 提醒（CDN/代理场景解析到边缘 IP 是正常的，所以允许 --skip-dns-check 强制继续）
  local pip; pip=$(host_public_ip || true)
  if [ "$SKIP_DNS_CHECK" = 1 ]; then
    info "已按 --skip-dns-check 跳过 DNS 校验"
    pip=""
  fi
  if [ -n "$pip" ]; then
    local resolved
    resolved=$(getent hosts "$DOMAIN" 2>/dev/null | awk '{print $1}' | head -1 || true)
    if [ -z "$resolved" ]; then
      warn "$DOMAIN 当前解析不到地址 —— 证书签发会失败（Let's Encrypt 需从公网访问本机 80/443）"
      if [ "$ASSUME_YES" = 1 ]; then
        die "DNS 未就绪。确认无误（或用 CDN 回源）可加 --skip-dns-check 强制继续。"
      fi
      ask_yn "仍要继续吗？" "n" || die "已中止（域名解析未就绪）"
    elif [ "$resolved" != "$pip" ] && [ "$BEHIND_CF" != "y" ]; then
      warn "$DOMAIN 解析到 $resolved，本机公网 IP 是 $pip —— 若不一致，证书签发会失败"
      if [ "$ASSUME_YES" = 1 ]; then
        die "DNS 与本机 IP 不一致。确认无误（例如走 CDN 回源）可加 --skip-dns-check 强制继续。"
      fi
      ask_yn "仍要继续吗？" "n" || die "已中止（DNS 与本机 IP 不一致）"
    else
      ok "$DOMAIN → $resolved"
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 将追加以下站点块到 $CADDY_FILE："
    gen_site_block | sed 's/^/    /'
    return 0
  fi

  # 备份 → 追加 → 校验 → 重载；任一步失败回滚
  BACKUP_FILE="${CADDY_FILE}.bak-$(date +%Y%m%d-%H%M%S)-preAgent2API"
  cp "$CADDY_FILE" "$BACKUP_FILE"; CADDY_BACKED_UP=1
  ok "已备份 Caddyfile → $(basename "$BACKUP_FILE")"

  strip_managed_block "$CADDY_FILE"          # 幂等：先摘掉旧的本脚本托管块

  # 摘掉自己的块之后，如果这个域名还被别的地方定义着，追加会得到「站点定义重复」
  # 的加载错误。与其等 validate 报一句难懂的话，不如现在就明确说清。
  if grep -qE "^[[:space:]]*${DOMAIN}([[:space:],{]|$)" "$CADDY_FILE"; then
    problem "Caddyfile 里已经存在 ${DOMAIN} 的站点块（不在本脚本的托管块内）"
    info "请先手工处理该冲突（合并或删除旧块）再重跑本脚本。"
    cp "$BACKUP_FILE" "$CADDY_FILE"
    die "已回滚，未做改动。"
  fi

  gen_site_block >> "$CADDY_FILE"

  if ! caddy_validate; then
    problem "Caddyfile 校验失败，正在回滚"
    sed -n '1,6p' /tmp/.a2a-validate | sed 's/^/    /'
    cp "$BACKUP_FILE" "$CADDY_FILE"
    die "已回滚，生产反代未受影响。"
  fi
  ok "Caddyfile 校验通过"

  if ! caddy_reload; then
    problem "Caddy 重载失败，正在回滚"
    cp "$BACKUP_FILE" "$CADDY_FILE"; caddy_reload || true
    die "已回滚。"
  fi
  ok "Caddy 已重载（未重启容器、未断现有连接）"
  CADDY_BACKED_UP=0        # 走到这里说明改动已完成，撤掉中断回滚的保护

  verify_tls
}

verify_tls() {
  local i code
  info "等待证书签发（最长 60 秒）…"
  for i in $(seq 1 20); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" 2>/dev/null || echo "000")
    case "$code" in
      2*|3*) ok "HTTPS 就绪（HTTP $code）"; break ;;
      *)     code="000" ;;
    esac
    sleep 3
  done
  case "$code" in
    2*|3*) ;;
    *)
      warn "证书尚未就绪（最后状态 $code）。常见原因："
      info "  · 域名没解析到本机（Let's Encrypt 需从公网访问 80/443）"
      info "  · 云安全组 / 防火墙没放通 80、443"
      info "  · 域名刚改解析，还在传播"
      info "  稍后自查：docker logs <caddy容器> 或 journalctl -u caddy | tail -20"
      return 1 ;;
  esac

  # 顺带验一下 /v1 网关路径 —— 端口没接对时这里会 502，早发现比用户报障好
  if [ "$EXPOSE_MODE" != "panel" ]; then
    local v1code
    v1code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
              --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/v1/models" 2>/dev/null || echo "000")
    case "$v1code" in
      2*) ok "/v1 网关可达（HTTP $v1code）" ;;
      *)  warn "/v1 网关返回 $v1code（预期 2xx）—— 检查网关端口是否与容器内一致" ;;
    esac
  fi
  return 0
}

# ── workbuddy-manager 集成 ──────────────────────────────────────────────────
integrate_manager() {
  [ "$MANAGER_INTEGRATE" = "y" ] || return 0
  step "6/6" "登记为 workbuddy-manager 的上游"

  local cname url_base
  cname=$(docker ps --format '{{.Names}}' | grep -m1 'workbuddy-manager' || true)
  [ -n "$cname" ] || { warn "没找到 workbuddy-manager 容器，跳过"; return 0; }

  local base=""
  base=$(docker port "$cname" 2>/dev/null | sed -n 's/.*-> [^:]*:\([0-9]*\)$/\1/p' | head -1 || true)
  [ -n "$base" ] || { warn "读不到 workbuddy-manager 的映射端口，跳过"; return 0; }
  url_base="http://127.0.0.1:${base}"

  local pw user
  user=$(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^WB_ADMIN_USER=//p')
  pw=$(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null | sed -n 's/^WB_ADMIN_PASSWORD=//p')
  user="${user:-admin}"
  if [ -z "$pw" ]; then
    warn "容器里没有 WB_ADMIN_PASSWORD，无法自动登录。"
    info "请到 manager 面板「设置 → 上游」手动新增："
    info "  地址 http://${CONTAINER}:${GW_PORT}    密钥 = 面板里创建的网关 Key"
    return 0
  fi

  # 网关 Key：先尝试从本机库里直接读（免粘贴），读不到才问
  local a2akey=""
  a2akey=$(read_gateway_key_from_db || true)
  if [ -n "$a2akey" ]; then
    info "已从 ${INSTALL_DIR}/data/agent2api.db 读到网关 Key（明文不显示、不落日志）"
  else
    info "${C_DIM}需要 agent2api 的网关 Key（面板「网关 Key」页创建；只显示一次）。${C_OFF}"
    a2akey=$(ask "agent2api 网关 Key（留空 = 跳过，稍后手动配）" "")
  fi
  if [ -z "$a2akey" ]; then
    warn "已跳过。手动配置时地址填 http://${CONTAINER}:${GW_PORT}（不带 /v1）"
    return 0
  fi

  if [ "$DRY_RUN" = 1 ]; then info "[dry-run] 将调用 ${url_base}/api/upstreams 登记上游"; return 0; fi

  MGR_BASE="$url_base" MGR_USER="$user" MGR_PW="$pw" MGR_KEY="$a2akey" \
  MGR_UP_URL="http://${CONTAINER}:${GW_PORT}" MGR_UP_NAME="${CONTAINER}(Qoder)" \
  python3 - <<'PY' || warn "manager 登记未完成，请到面板手动新增上游"
import os, json, urllib.request, urllib.error, http.cookiejar
base=os.environ["MGR_BASE"]
cj=http.cookiejar.CookieJar()
op=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
def call(path, data=None):
    req=urllib.request.Request(base+path,
        data=(json.dumps(data).encode() if data is not None else None),
        headers={"Content-Type":"application/json"})
    try:
        r=op.open(req, timeout=20); t=r.read().decode()
        return r.status, (json.loads(t) if t.strip().startswith(("{","[")) else t)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]
st,_=call("/api/login", {"username":os.environ["MGR_USER"], "password":os.environ["MGR_PW"]})
if st!=200:
    print("  登录失败（%s），跳过" % st); raise SystemExit(1)
print("  已登录 manager")
st,up=call("/api/upstreams")
if st!=200:
    print("  读取上游失败（%s）" % st); raise SystemExit(1)
target=os.environ["MGR_UP_URL"]
if any(u.get("base_url")==target for u in (up.get("items") or [])):
    print("  上游已存在，无需重复添加")
else:
    st,res=call("/api/upstreams", {"name":os.environ["MGR_UP_NAME"], "base_url":target,
        "api_key":os.environ["MGR_KEY"], "note":"由 install-agent2api.sh 自动登记",
        "enabled":True, "auth_dir":"", "container":os.environ.get("MGR_UP_CONTAINER","")})
    print("  新增上游：%s" % ("成功" if st in (200,201) else "失败 %s %s" % (st,res)))
PY
}

# 给 Nginx / 其他反代用户一份可直接粘贴的配置。
# 刻意不自动改 Nginx：各家 server_name 组织方式差异太大，自动改的风险高于收益；
# 但把「该粘什么」准备好，用户 2 分钟就能搞定。
print_nginx_hint() {
  printf '\n'
  info "本脚本只自动改 Caddy。你的 80/443 被别的程序占着，这里给你一份现成片段："
  printf '\n'
  printf '    %s# 1) 取证书（需 certbot 与 nginx 插件）%s\n' "$C_DIM" "$C_OFF"
  printf '    %sapt install -y certbot python3-certbot-nginx%s\n' "$C_DIM" "$C_OFF"
  printf '    %scertbot certonly --nginx -d %s%s\n' "$C_DIM" "$DOMAIN" "$C_OFF"
  printf '\n'
  printf '    %s# 2) 写到 /etc/nginx/conf.d/%s.conf%s\n' "$C_DIM" "$DOMAIN" "$C_OFF"
  cat <<NGINX
    server {
        listen 80;
        server_name ${DOMAIN};
        location /.well-known/acme-challenge/ { root /var/www/certbot; }
        location / { return 301 https://\$host\$request_uri; }
    }
    server {
        listen 443 ssl;
        http2 on;
        server_name ${DOMAIN};
        ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
        ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;

        # 公网禁止自助注册（agent2api 默认「首个访问者注册管理员」）
        location = /api/panel/setup { return 403; }

        # 网关：/v1 必须关 buffering，否则流式（SSE）会被整段缓冲，首字延迟爆炸
        location /v1 {
            proxy_pass http://127.0.0.1:${GW_PORT};
            proxy_http_version 1.1;
            proxy_set_header Connection "";
            proxy_buffering off;
            proxy_read_timeout 600s;
            proxy_send_timeout 600s;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
        # 面板
        location / {
            proxy_pass http://127.0.0.1:${PANEL_PORT};
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
        }
    }
NGINX
  printf '\n'
  printf '    %s# 3) 校验并重载%s\n' "$C_DIM" "$C_OFF"
  printf '    %snginx -t && systemctl reload nginx%s\n' "$C_DIM" "$C_OFF"
  printf '\n'
  info "配好之后：客户端 base_url = https://${DOMAIN}/v1，面板 https://${DOMAIN}/"
  info "这份 Nginx 配置由你自己维护，本脚本不会接管（--domain 的自动能力对它不适用）。"
}

# ── 版本管理：查更新 / 升级 / 状态 ──────────────────────────────────────────
do_check_update() {
  load_state || die "读不到 $INSTALL_DIR/install.conf（用 --dir 指定安装目录）"
  title "检查更新"
  info "当前版本：${IMAGE_TAG}"
  local latest; latest=$(docker_hub_latest_tag || true)
  if [ -z "$latest" ]; then
    warn "查询不到 Docker Hub（网络不通或被墙）"
    info "可手动指定：--tag <版本> --upgrade"
    return 1
  fi
  info "最新版本：${latest}"
  if [ "$latest" = "$IMAGE_TAG" ]; then ok "已是最新，无需升级"
  else
    printf '\n  可升级：%s → %s\n' "$IMAGE_TAG" "$latest"
    info "执行：bash $0 --dir $INSTALL_DIR --upgrade"
  fi
}

do_upgrade() {
  load_state || die "读不到 $INSTALL_DIR/install.conf（用 --dir 指定安装目录）"
  title "升级 agent2api"
  local target="$IMAGE_TAG_OVERRIDE"
  if [ -z "$target" ]; then
    target=$(docker_hub_latest_tag || true)
    [ -n "$target" ] || die "查询不到 Docker Hub；可用 --tag <版本> 指定目标版本"
  fi
  info "当前版本：${IMAGE_TAG}"
  info "目标版本：${target}"
  if [ "$target" = "$IMAGE_TAG" ]; then ok "已是指定版本，无需升级"; return 0; fi
  command -v python3 >/dev/null 2>&1 || warn "没有 python3，将用 sed 改写 compose 里的镜像行"

  local cmp="${INSTALL_DIR}/docker-compose.yml"
  [ -f "$cmp" ] || die "找不到 $cmp"
  local old_tag="$IMAGE_TAG"

  if [ "$DRY_RUN" = 1 ]; then
    info "[dry-run] 将把 compose 里的镜像改为 ${DEFAULT_IMAGE_REPO}:${target}，并 compose pull && up -d"
    return 0
  fi

  cp "$cmp" "${cmp}.bak-$(date +%Y%m%d-%H%M%S)-preUpgrade"
  # 只改 agent2api 那一行的镜像；自建 Caddy 的 caddy 镜像不动
  sed -i "s#^\( *image: *${DEFAULT_IMAGE_REPO}\):.*#\1:${target}#" "$cmp"
  grep -q "image: ${DEFAULT_IMAGE_REPO}:${target}" "$cmp" || die "改写 compose 失败（未找到镜像行）"

  info "拉取新镜像…"
  if ! compose pull --quiet; then
    warn "拉取失败，回滚配置"
    sed -i "s#^\( *image: *${DEFAULT_IMAGE_REPO}\):.*#\1:${old_tag}#" "$cmp"
    die "镜像拉取失败（版本号写错？网络不通？）"
  fi

  info "重建容器…"
  if ! compose up -d --remove-orphans; then
    warn "重建失败，回滚到 ${old_tag}"
    sed -i "s#^\( *image: *${DEFAULT_IMAGE_REPO}\):.*#\1:${old_tag}#" "$cmp"
    compose up -d --remove-orphans || true
    die "升级失败，已回滚到 ${old_tag}"
  fi

  # 健康复检：别只看容器起来了，要两个端口真的在服务
  local i st ok_health=1
  for i in $(seq 1 30); do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null || echo "")
    [ "$st" = "healthy" ] && { ok_health=0; break; }
    sleep 2
  done
  if [ "$ok_health" = 0 ] \
     && docker exec "$CONTAINER" curl -sf --max-time 6 "http://127.0.0.1:${GW_PORT}/health" >/dev/null 2>&1 \
     && docker exec "$CONTAINER" curl -sf --max-time 6 "http://127.0.0.1:${PANEL_PORT}/" >/dev/null 2>&1; then
    IMAGE_TAG="$target"; save_state
    ok "升级完成：${old_tag} → ${target}"
  else
    warn "新版本未通过健康复检，回滚到 ${old_tag}"
    sed -i "s#^\( *image: *${DEFAULT_IMAGE_REPO}\):.*#\1:${old_tag}#" "$cmp"
    compose up -d --remove-orphans || true
    docker logs --tail 12 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
    die "已回滚到 ${old_tag}（旧镜像仍在本地，服务可用）"
  fi
}

do_status() {
  load_state || die "读不到 $INSTALL_DIR/install.conf（用 --dir 指定安装目录）"
  title "运行状态"
  info "安装目录：$INSTALL_DIR"
  info "镜像：${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}"
  info "容器：${CONTAINER}"
  info "端口：面板 ${PANEL_PORT} / 网关 ${GW_PORT}"
  info "反代形态：${CADDY_MODE}${CADDY_NET:+（网络 $CADDY_NET）}"
  [ -n "$DOMAIN" ] && info "域名：${DOMAIN}（暴露 ${EXPOSE_MODE}，注册封锁 ${LOCK_REGISTER}，CF 代理 ${BEHIND_CF}）"

  printf '\n'
  if [ "$(docker inspect -f '{{.State.Status}}' "$CONTAINER" 2>/dev/null)" = "running" ]; then
    ok "容器运行中（health: $(docker inspect -f '{{.State.Health.Status}}' "$CONTAINER" 2>/dev/null)）"
  else
    problem "容器未在运行（docker ps -a 可见）"
  fi

  if docker exec "$CONTAINER" curl -sf --max-time 6 "http://127.0.0.1:${GW_PORT}/health" >/dev/null 2>&1; then
    ok "网关 ${GW_PORT} 健康"
  else
    problem "网关 ${GW_PORT} 无响应"
  fi
  if docker exec "$CONTAINER" curl -sf --max-time 6 "http://127.0.0.1:${PANEL_PORT}/" >/dev/null 2>&1; then
    ok "面板 ${PANEL_PORT} 可达"
  else
    problem "面板 ${PANEL_PORT} 无响应"
  fi

  if [ -n "$DOMAIN" ]; then
    local code
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "https://${DOMAIN}/" 2>/dev/null || echo 000)
    case "$code" in 2*|3*) ok "域名 HTTPS 正常（HTTP $code）" ;; *) problem "域名 HTTPS 异常（HTTP $code）" ;; esac
    local exp
    exp=$(echo | openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    [ -n "$exp" ] && info "证书到期：$exp"
  fi

  if [ "$CADDY_MODE" = "self" ]; then
    local cn="${CADDY_SELF_CONTAINER}"
    if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$cn"; then ok "自建 Caddy 容器运行中（$cn）"; else problem "自建 Caddy 容器未运行（$cn）"; fi
  fi

  printf '\n'
  info "最近日志（末 5 行）："
  docker logs --tail 5 "$CONTAINER" 2>&1 | sed 's/^/    /' || true
}

# 从本机 agent2api 的库里读出网关 Key —— 免去「面板显示一次、手工复制粘贴」那一步。
# 只读取、只交给本机的 manager 接口用，明文不经手任何输出。
read_gateway_key_from_db() {
  local db="${INSTALL_DIR}/data/agent2api.db"
  [ -f "$db" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$db" <<'PY' 2>/dev/null
import sqlite3, json, sys
try:
    c = sqlite3.connect("file:%s?mode=ro" % sys.argv[1], uri=True)
    row = c.execute("select value from kv where key='apiKeys'").fetchone()
    if not row or not row[0]:
        raise SystemExit(1)
    ks = [k for k in json.loads(row[0]) if k.get("enabled") and k.get("key")]
    if not ks:
        raise SystemExit(1)
    print(ks[0]["key"])
except SystemExit:
    raise
except Exception:
    raise SystemExit(1)
PY
}

# ── 卸载 ────────────────────────────────────────────────────────────────────
do_uninstall() {
  title "卸载 agent2api"
  load_state || true
  [ -n "$INSTALL_DIR" ] || INSTALL_DIR="$DEFAULT_DIR"
  [ -n "$CONTAINER" ] || CONTAINER="$DEFAULT_CONTAINER"

  if [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    run compose down || warn "compose down 出错"
    ok "容器已停止并移除"
  else
    warn "没找到 $INSTALL_DIR/docker-compose.yml，尝试直接删容器"
    run docker rm -f "$CONTAINER" 2>/dev/null || true
  fi

  if [ -n "$CADDY_FILE" ] && [ -f "$CADDY_FILE" ] && grep -qF "$MARK_BEGIN" "$CADDY_FILE"; then
    if [ "$CADDY_MODE" = "self" ]; then
      info "自建 Caddy 的配置在 $CADDY_FILE，容器已随 compose 移除；文件请在下一步决定是否随目录删除"
    elif ask_yn "从 $CADDY_FILE 移除站点块？" "y"; then
      if [ "$DRY_RUN" = 0 ]; then
        cp "$CADDY_FILE" "${CADDY_FILE}.bak-$(date +%Y%m%d-%H%M%S)-preUninstallAgent2API"
        strip_managed_block "$CADDY_FILE"
        if caddy_validate; then caddy_reload && ok "站点块已移除并重载"; else
          problem "校验失败，站点块保留未移除"; fi
      fi
    fi
  fi

  if [ -d "$INSTALL_DIR" ]; then
    if ask_yn "删除目录 $INSTALL_DIR（含数据卷 data/，不可恢复）？" "n"; then
      run rm -rf "$INSTALL_DIR"; ok "已删除 $INSTALL_DIR"
    else
      info "目录保留：$INSTALL_DIR"
    fi
  fi
  local img="${DEFAULT_IMAGE_REPO}:${IMAGE_TAG:-$DEFAULT_TAG}"
  info "镜像 ${img} 保留未删（需要时：docker rmi ${img}）"
  ok "卸载完成"
}

# ── 汇总 ────────────────────────────────────────────────────────────────────
summary() {
  title "安装完成"
  case "$CADDY_MODE" in
    self)
      info "反代：本脚本自建的 Caddy 容器 ${CADDY_SELF_CONTAINER}（证书落在 ${INSTALL_DIR}/caddy-data）"
      info "后端：${CONTAINER}:${PANEL_PORT}（面板）/ ${CONTAINER}:${GW_PORT}（网关）" ;;
    *)
      if [ "$UPSTREAM_STYLE" = "container" ]; then
        info "反代后端：${CONTAINER}:${PANEL_PORT}（与 Caddy 同网络 ${CADDY_NET}）"
      else
        info "反代后端：127.0.0.1:${PANEL_PORT}"
      fi ;;
  esac
  printf '\n'
  if [ -n "$DOMAIN" ]; then
    case "$EXPOSE_MODE" in
      panel)   printf '  %s面板：%s https://%s/\n' "$C_BLD" "$C_OFF" "$DOMAIN" ;;
      gateway) printf '  %s网关：%s https://%s/v1\n' "$C_BLD" "$C_OFF" "$DOMAIN" ;;
      *)       printf '  %s面板：%s https://%s/\n' "$C_BLD" "$C_OFF" "$DOMAIN"
               printf '  %s网关：%s https://%s/v1\n' "$C_BLD" "$C_OFF" "$DOMAIN" ;;
    esac
  else
    # 不绑域名时，必须把「怎么用」讲清楚。只给面板端口是不够的 ——
    # 用户真正要连的是**网关**（客户端 base_url 填的就是它），隧道里漏了它等于装完没法用。
    local ssh_host ssh_user
    ssh_host=$(host_public_ip || true)
    [ -n "$ssh_host" ] || ssh_host="<你的服务器IP>"
    ssh_user="${SUDO_USER:-}"
    [ -n "$ssh_user" ] || ssh_user="$(id -un 2>/dev/null || echo root)"

    info "未绑域名 —— 用 SSH 隧道访问。下面这条在${C_BLD}你自己的电脑${C_OFF}上执行："
    printf '\n'
    printf '      %sssh -N -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s %s@%s%s\n' \
      "$C_DIM" "$PANEL_PORT" "$PANEL_PORT" "$GW_PORT" "$GW_PORT" "$ssh_user" "$ssh_host" "$C_OFF"
    printf '\n'
    info "${C_DIM}这条命令要一直开着（另开一个终端窗口跑）。它不输出任何东西、看着像卡住 —— 那是在转发，正常。${C_OFF}"
    printf '\n'
    printf '      面板 → 浏览器打开 %shttp://127.0.0.1:%s%s\n' "$C_BLD" "$PANEL_PORT" "$C_OFF"
    printf '      网关 → 客户端 base_url 填 %shttp://127.0.0.1:%s/v1%s\n' "$C_BLD" "$GW_PORT" "$C_OFF"
    printf '\n'
    info "隧道只对你这台电脑有效，别人访问不到（这也是它比直接暴露公网安全的地方）。"
    info "想省掉隧道：带上域名重跑（--domain 你的域名），会自动签 HTTPS 证书。"
  fi
  printf '\n'
  info "首次使用：打开面板 → 注册管理员 → 「账号」添加上游账号 → 「网关 Key」建一把 Key"
  if [ -n "$DOMAIN" ]; then
    info "客户端接入：base_url = https://${DOMAIN}/v1，api_key = 面板里那把 Key"
  else
    info "客户端接入：base_url = http://127.0.0.1:${GW_PORT}/v1（走上面的隧道），api_key = 面板里那把 Key"
  fi
  [ "$LOCK_REGISTER" = "y" ] && info "${C_YEL}注意：公网自助注册已封（$SETUP_PATH → 403）。${C_OFF}"
  printf '\n'
  info "常用命令："
  printf '      cd %s && docker compose logs -f --tail 50\n' "$INSTALL_DIR"
  printf '      cd %s && docker compose restart\n' "$INSTALL_DIR"
  printf '      bash %s --status\n' "$0"
  printf '      bash %s --upgrade\n' "$0"
  printf '      bash %s --uninstall\n' "$0"
  printf '\n'
  info "状态文件：$(state_file)（改完重跑脚本即可生效）"
  printf '\n'
  # 换新机器时不用再手动下载上传 —— 直接把这行粘到新 VPS 上
  info "要在别的机器上装，把下面这行粘过去就行（不用先下载再上传）："
  printf '      curl -fsSL https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/deploy.sh | sudo bash\n'
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  title "agent2api 一键安装器 v$SCRIPT_VERSION"
  [ "$DRY_RUN" = 1 ] && warn "dry-run 模式：只打印计划，不会做任何改动"

  need_root
  check_docker

  step "1/6" "探测环境"
  detect_web_server
  resolve_caddy_net
  case "$CADDY_MODE" in
    docker) ok "发现 Caddy 容器：$CADDY_CONTAINER" ;;
    host)   ok "发现宿主 Caddy（systemd/进程）" ;;
    nginx)  warn "80/443 上是 Nginx（本脚本只自动写 Caddy 配置）—— 绑域名需你手动反代" ;;
    other)  warn "80/443 被非 Caddy 程序占用 —— 绑域名需你手动反代" ;;
    none)   info "80/443 上没有反向代理；若绑域名，将由本脚本自建 Caddy 容器（需 80/443 空闲）" ;;
  esac
  if locate_caddyfile; then ok "Caddyfile：$CADDY_FILE"; elif [ "$CADDY_MODE" != "none" ]; then warn "未定位到 Caddyfile"; fi

  # 安装目录先定下来（状态文件在它下面），再读回上次的配置作为默认值
  [ -n "$INSTALL_DIR" ] || INSTALL_DIR="$DEFAULT_DIR"
  prefill_from_saved

  if [ "$DO_UNINSTALL" = 1 ]; then do_uninstall; exit 0; fi
  if [ "$DO_STATUS" = 1 ]; then do_status; exit 0; fi
  if [ "$DO_CHECK_UPDATE" = 1 ]; then do_check_update; exit $?; fi
  if [ "$DO_UPGRADE" = 1 ]; then do_upgrade; exit $?; fi

  step "2/6" "收集配置"
  gather_config
  validate_inputs

  # 域名冲突要早发现：此时还没起容器、没动反代，退出成本为零
  if precheck_domain_conflict; then
    problem "Caddyfile 里已经存在 ${DOMAIN} 的站点块（不在本脚本的托管块内）"
    info "请先手工处理该冲突（合并或删除旧块）再重跑本脚本。"
    die "未做任何改动。"
  fi

  # 裸机（80/443 上没有反代）时决定自建 Caddy —— 必须在生成 compose 之前定下来
  decide_caddy_mode

  info "安装目录：$INSTALL_DIR"
  info "镜像：${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}"
  info "面板端口：$PANEL_PORT    网关端口：$GW_PORT"
  info "域名：${DOMAIN:-（不绑）}    暴露：${EXPOSE_MODE}"
  info "注册封锁：${LOCK_REGISTER}    内存上限：$MEM_LIMIT"

  if [ "$ASSUME_YES" = 0 ] && [ -t 0 ]; then
    printf '\n'
    ask_yn "确认开始安装？" "y" || die "已取消"
  fi

  gen_compose
  if ! start_container || ! verify_ports_bound; then
    case "$LAST_FAIL_KIND" in
      name)
        # 换端口救不了容器名冲突，别做无用的三次重试
        die "容器名冲突，未做换端口重试。请加 --container <别的名字> 或先 docker rm -f ${CONTAINER} 再重跑。" ;;
      health)
        die "容器起来了但健康检查没过，请先看日志排查：cd ${INSTALL_DIR} && docker compose logs --tail 50" ;;
    esac
    warn "容器未就绪或端口未全部绑定，尝试自动换端口重试"
    retry_with_free_ports \
      || die "多次重试后仍未成功。请用 --panel-port / --gateway-port 手动指定两个空闲端口后重跑。"
  fi
  ok "服务自检通过（容器内 ${GW_PORT} 网关 /health、${PANEL_PORT} 面板 / 均可达）"

  maybe_remove_site_block
  apply_domain
  save_state
  integrate_manager
  summary
}

main "$@"
