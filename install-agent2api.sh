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

SCRIPT_VERSION="1.7.1"
DEFAULT_IMAGE_REPO="aimodcc/agent2api"
DEFAULT_TAG="2.9.1"          # 离线兜底用的「已知可用版本」（只在查不到 Docker Hub 时才用；线上实测 healthy）
DEFAULT_DIR="/opt/agent2api"
DEFAULT_CONTAINER="agent2api"
CADDY_IMAGE="caddy:2-alpine"   # self 模式下自建反代用的镜像
DEFAULT_PANEL_PORT="3066"
DEFAULT_GW_PORT="3065"
DEFAULT_MEM="384m"
SETUP_PATH="/api/panel/setup"  # agent2api 的自助注册端点（可选封锁，默认不封）
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
AUTO_DEPS=1               # 缺依赖自动装（--no-deps 关掉）
DRY_RUN=0
ASSUME_YES=0
DO_UNINSTALL=0
SKIP_DNS_CHECK=0
DO_UPGRADE=0             # --upgrade
DO_CHECK_UPDATE=0        # --check-update
DO_STATUS=0              # --status
IMAGE_TAG_OVERRIDE=""    # --tag 显式指定的目标版本（升级时用它，别被状态文件覆盖）
NO_DOMAIN=0              # 本次明确不要域名（会摘掉上次写入的站点块）
RECONFIG=0               # 用户在「检测到已安装」菜单里明确选了「重新配置」→ 必须给高级选项开关
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

# 备份文件要**限量**：每次改共享反代配置都会存一份，
# 用户来回折腾几次就在 /etc/caddy/ 里堆一排（实测连跑 4 次 = 4 个）。
# 只保留最近 3 个 —— 只删**本脚本自己建的**（严格匹配文件名模式），
# 绝不碰用户自己的备份。
prune_own_backups() {
  local dir; dir="$(dirname "$CADDY_FILE")"
  local base; base="$(basename "$CADDY_FILE")"
  local keep=3
  ls -1t "$dir/$base".bak-*-preAgent2API 2>/dev/null \
    | tail -n +$((keep + 1)) \
    | while IFS= read -r f; do rm -f "$f"; done
}

# 还原反代配置。只有一个成立时才动手：确实备份过、且还没走到「改动已落地」那步。
# 正常跑完的路径在 apply_domain 末尾把 CADDY_BACKED_UP 清 0，所以退出时这里直接返回。
restore_caddy() {
  [ "$CADDY_BACKED_UP" = 1 ] || return 0
  [ -n "$BACKUP_FILE" ] && [ -f "$BACKUP_FILE" ] || return 0
  [ -n "$CADDY_FILE" ] || return 0
  # 先摘掉陷阱：下面 caddy_validate/caddy_reload 自身可能失败，不能再触发 ERR/EXIT 递归
  trap - ERR EXIT
  printf '\n  %s!%s 正在还原 Caddyfile：%s\n' "$C_YEL" "$C_OFF" "$BACKUP_FILE" >&2
  cp "$BACKUP_FILE" "$CADDY_FILE" 2>/dev/null || return 0
  if caddy_validate >/dev/null 2>&1 && caddy_reload >/dev/null 2>&1; then
    printf '  %s✓%s 已还原并重载\n' "$C_GRN" "$C_OFF" >&2
  else
    printf '  %s×%s 还原后校验/重载未通过，请手工检查 %s\n' "$C_RED" "$C_OFF" "$CADDY_FILE" >&2
  fi
  return 0
}

on_signal() {
  restore_caddy
  printf '  %s已中止。%s\n' "$C_YEL" "$C_OFF" >&2
  printf '  %s反代配置已还原到你运行前的状态，没有改坏任何东西。%s\n' "$C_DIM" "$C_OFF" >&2
  # 说实话：中断时可能已经起了容器（实测：在下载镜像阶段杀掉，容器已存在但状态文件还没写）。
  # 只说"什么都没发生"会让用户以为环境是干净的。
  printf '  %s如果刚才已经跑到「启动服务」那一步，容器可能已经建起来了（但不影响使用）。%s\n' "$C_DIM" "$C_OFF" >&2
  printf '  %s直接重跑一次脚本就能接上（不会重复装）。%s\n' "$C_DIM" "$C_OFF" >&2
  exit 130
}
trap on_signal INT TERM
# 🔴 原来只接了 INT/TERM。可脚本是 set -Eeuo pipefail —— **任何未处理的失败会直接退出**，
#   不会走到 on_signal。那种情况下 Caddyfile 可能已经被改过（strip 过了、站点块追加了一半、
#   磁盘满导致写截断），却没人还原，等到下次 reload/重启才炸 —— 最难排查的那类故障。
#   ERR + EXIT 同时兜住，并在还原前先摘掉这两个 trap 防止递归。
trap restore_caddy ERR EXIT

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
  # read 失败 = EOF / 终端断开，**不是**"用户按了回车"。必须说出来，
  # 否则用户看到的是"它自己选了个值"，完全不知道发生了什么。
  if ! IFS= read -r ans; then
    printf '\n  %s（读不到输入，采用默认值：%s）%s\n' "$C_DIM" "$def" "$C_OFF" >&2
    printf '%s' "$def"; return 0
  fi
  printf '%s' "${ans:-$def}"
}
ask_yn() {  # ask_yn <提示> <y|n> -> 返回 0=是
  local prompt="$1" def="$2" ans=""
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then [ "$def" = "y" ]; return; fi
  printf '  %s [%s]: ' "$prompt" "$def" >&2
  while :; do
    # 🔴 EOF 绝不能当成"回车确认默认值"：确认安装的默认是 y，
    # 那样输入一断就会**直接开装**。读不到就按「否」处理。
    if ! IFS= read -r ans; then
      printf '\n  %s（读不到输入，按「否」处理）%s\n' "$C_DIM" "$C_OFF" >&2
      return 1
    fi
    case "$ans" in
      '') [ "$def" = "y" ] && return 0 || return 1 ;;
      # 中文用户会直接打「是 / 好 / 对 / 要」—— 实测以前这些都落进 `*)` 被当成**否**，
      # 等于回答了相反的意思（问"要不要禁止…"，答"是"结果没禁止）。
      y|Y|yes|YES|Yes|true|1|是|是的|好|好的|对|要|嗯|可以|行|确定) return 0 ;;
      n|N|no|NO|No|false|0|否|不|不要|不用|不是|取消) return 1 ;;
      *) printf '  %s没看懂「%s」—— 请回答 y（是）或 n（否），直接回车则用默认值 %s%s\n' \
           "$C_YEL" "$ans" "$def" "$C_OFF" >&2
         printf '  %s [%s]: ' "$prompt" "$def" >&2 ;;
    esac
  done
}

# 带格式校验的提问：交互模式下**当场重问**，别让用户填错一个字符就得重跑一遍、
# 把前面 8 个问题全重答一遍（实测体验很差）。非交互/--yes 直接返回默认值，
# 后面 validate_inputs 仍会兜底。
ask_port() {  # ask_port <提示> <默认> -> 1-65535 的整数
  local prompt="$1" def="$2" ans
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  while :; do
    ans=$(ask "$prompt" "$def")
    if printf '%s' "$ans" | grep -qE '^[0-9]+$' && [ "$ans" -ge 1 ] && [ "$ans" -le 65535 ]; then
      printf '%s' "$ans"; return 0
    fi
    printf '  %s端口要是 1-65535 之间的数字，请重新输入（或直接回车用 %s）%s\n' "$C_YEL" "$def" "$C_OFF" >&2
  done
}
ask_mem() {  # ask_mem <提示> <默认> -> 形如 256m / 512m / 1g
  local prompt="$1" def="$2" ans
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  while :; do
    ans=$(ask "$prompt" "$def")
    if printf '%s' "$ans" | grep -qE '^[0-9]+[bkmgBKMG]?$'; then printf '%s' "$ans"; return 0; fi
    printf '  %s内存上限格式形如 256m / 512m / 1g，请重新输入（或直接回车用 %s）%s\n' "$C_YEL" "$def" "$C_OFF" >&2
  done
}
choose() {  # choose <提示> <默认序号> <选项...> -> 只把序号打到 stdout，菜单走 stderr
  local prompt="$1" def="$2"; shift 2
  local opts=("$@") i=1 ans=""
  for o in "${opts[@]}"; do printf '    %d) %s\n' "$i" "$o" >&2; i=$((i+1)); done
  if [ "$ASSUME_YES" = 1 ] || [ ! -t 0 ]; then printf '%s' "$def"; return 0; fi
  printf '  %s [%s]: ' "$prompt" "$def" >&2
  while :; do
    if ! IFS= read -r ans; then
      printf '\n  %s（读不到输入，用默认值 %s）%s\n' "$C_DIM" "$def" "$C_OFF" >&2
      printf '%s' "$def"; return 0
    fi
    case "$ans" in
      '') printf '%s' "$def"; return 0 ;;
    esac
    # 越界或非数字**重问**：以前会静默回落成默认项，用户输 9 却跑了第 1 项，很意外
    if printf '%s' "$ans" | grep -qE '^[0-9]+$' && [ "$ans" -ge 1 ] && [ "$ans" -le "${#opts[@]}" ]; then
      printf '%s' "$ans"; return 0
    fi
    printf '  %s请输入 1-%s 之间的数字（直接回车用默认 %s）%s\n' "$C_YEL" "${#opts[@]}" "$def" "$C_OFF" >&2
    printf '  %s [%s]: ' "$prompt" "$def" >&2
  done
}

# ── 参数解析 ────────────────────────────────────────────────────────────────
parse_args() {
  while [ $# -gt 0 ]; do
    # 🔴 下面这一组参数都吃一个值。缺值时原来的 `shift 2` 会越界，
    #   set -e 直接退出，用户看到的是 bash 的 `shift count out of range`，
    #   完全不知道是自己漏打了值。提前拦下并说人话。
    case "$1" in
      --dir|--tag|--container|--domain|--expose|--panel-port|--gateway-port|--mem|--tz|--caddy-mode)
        [ $# -ge 2 ] || die "参数 $1 需要一个值（例如：$1 xxx）"
        # ⚠️ 只在「下一个参数就是本脚本认识的**选项**」时才提示漏写值。
        #   一开始这里拦的是所有 `-` 开头的值，结果把 `--container -bad`
        #   （本意是测容器名校验）也抢下来了，报成「看起来像个选项」——
        #   既误导又破坏了原有行为。非选项的 `-xxx` 值一律放行，
        #   交给 validate_inputs 去报「容器名非法」这类真正准确的错误。
        case "${2:-}" in
          --dir|--tag|--container|--domain|--expose|--panel-port|--gateway-port|--mem|--tz|--caddy-mode|--cf|--no-cf|--open-register|--lock-register|--with-manager|--no-manager|--dry-run|--upgrade|--check-update|--status|--skip-dns-check|--no-deps|--uninstall|--no-domain|--yes|-y|--help|-h)
            die "参数 $1 需要一个值，但你紧接着写的是 '$2'（那是另一个选项）—— 是不是漏写了 $1 的值？" ;;
        esac
        ;;
    esac
    case "$1" in
      --dir)          INSTALL_DIR="$2"; shift 2 ;;
      --tag)          IMAGE_TAG="$2"; IMAGE_TAG_OVERRIDE="$2"; shift 2 ;;
      --container)    CONTAINER="$2"; shift 2 ;;
      --domain)       DOMAIN="$2"; shift 2 ;;
      --expose)
        # 非法枚举**在这里就拦下**：以前只在 validate_inputs 里查，而「没绑域名」时
        # gather_config 会把 EXPOSE_MODE 强制覆盖成 none，于是 `--expose foo`
        # 被静默吞掉、一个错都不报（实测踩到）。枚举值对不对跟有没有域名无关。
        EXPOSE_MODE="$2"
        case "$2" in
          both|panel|gateway|none) : ;;
          *) die "--expose 只能是 both / panel / gateway，收到：'$2'" ;;
        esac
        shift 2 ;;
      --panel-port)   PANEL_PORT="$2"; shift 2 ;;
      --gateway-port) GW_PORT="$2"; shift 2 ;;
      --mem)          MEM_LIMIT="$2"; shift 2 ;;
      --tz)           TZ_NAME="$2"; shift 2 ;;
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
      --caddy-mode)
        # 同上：非法枚举当场拦下。以前这里不校验，decide_caddy_mode 里的 case 匹配不上
        # 就静默沿用自动探测结果 —— 用户明确指定的形态被无声忽略（实测踩到）。
        CADDY_MODE_FORCE="$2"
        case "$2" in
          docker|host|self) : ;;
          *) die "--caddy-mode 只能是 docker / host / self，收到：'$2'" ;;
        esac
        shift 2 ;;
      --dry-run)      DRY_RUN=1; shift ;;
      --upgrade)      DO_UPGRADE=1; shift ;;
      --check-update) DO_CHECK_UPDATE=1; shift ;;
      --status)       DO_STATUS=1; shift ;;
      --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
      --no-deps)      AUTO_DEPS=0; shift ;;      # 别动我的系统，缺什么我自己装
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
  --lock-register         公网禁止自助注册（默认不封，注册端点正常可用）
  --open-register         不封注册端点（默认行为）。注意 agent2api 是「首个访客注册管理员」
  --with-manager          把本服务登记为已有 workbuddy-manager 的上游
  --no-manager            不登记（默认交互询问）
  --dry-run               只打印将要做什么，不实际改动
  --status                查看运行状态（容器/端口/域名/证书到期/最近日志）
  --check-update          查询 Docker Hub 上是否有新版本
  --upgrade               升级到最新版（可配合 --tag 指定版本）；健康复检不过自动回滚
  --skip-dns-check        跳过「域名是否解析到本机」的校验（走 CDN 回源时需要）
  --no-deps               不要自动装依赖（缺 docker 时只给命令，不替你装）
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

# ── 自动装依赖 ──────────────────────────────────────────────────────────────
# 一键脚本就该真的"一键"：缺什么自己装，而不是让用户自己去敲命令（实测被用户吐槽）。
# docker 三种装法依次降级：官方脚本 → 官方脚本+阿里云镜像 → 发行版自带仓库。
# 不想让脚本动系统的可以加 --no-deps（那就退回"给出可粘命令"的老行为）。
PKG_MGR=""
detect_pkg_mgr() {
  local m
  for m in apt-get dnf yum apk zypper; do
    command -v "$m" >/dev/null 2>&1 && { PKG_MGR="$m"; return 0; }
  done
  return 1
}
pkg_install() {   # pkg_install <包...>；失败返回非 0
  case "$PKG_MGR" in
    apt-get) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" ;;
    dnf|yum) "$PKG_MGR" install -y "$@" ;;
    apk)     apk add --no-cache "$@" ;;
    zypper)  zypper --non-interactive install "$@" ;;
    *)       return 1 ;;
  esac
}
# 取一个 URL 到文件（curl 或 wget 都行）
fetch_to() {   # fetch_to <url> <目标文件>
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 180 -o "$2" "$1"
  elif command -v wget >/dev/null 2>&1; then wget -q -T 180 -O "$2" "$1"
  else return 1; fi
}

ensure_docker() {
  command -v docker >/dev/null 2>&1 && return 0

  # --no-deps：不碰用户系统，退回"给命令让用户自己装"
  if [ "$AUTO_DEPS" != 1 ]; then
    problem "这台机器上还没装 docker（跑这个服务必须用它）"
    info "自己装的话，把下面这行粘进去回车就行："
    printf '      %scurl -fsSL https://get.docker.com | sh%s\n' "$C_BLD" "$C_OFF"
    info "${C_DIM}（或者去掉 --no-deps 重跑，脚本会自动帮你装）${C_OFF}"
    return 1
  fi

  warn "这台机器上还没装 docker —— 我来装（跑服务必须用它，大概 1-2 分钟，别急）"
  printf '\n'

  # 得先有下载工具
  if ! command -v curl >/dev/null 2>&1 && ! command -v wget >/dev/null 2>&1; then
    if detect_pkg_mgr; then
      info "先装个下载工具（curl）…"
      pkg_install curl >/dev/null 2>&1 || true
    fi
  fi

  local script=/tmp/agent2api-get-docker.sh log=/tmp/agent2api-docker-install.log ok=0
  rm -f "$script" "$log"

  # 🔴 判定标准必须是「docker 命令是否真的可用」，**不能看脚本退出码**。
  # 实测：包已装、二进制却被删掉时，get.docker.com 会退出 0 却什么都不装
  #（apt 认为"已是最新版"，直接跳过）—— 信退出码就会误判成功、不走进降级分支。
  docker_ok() { command -v docker >/dev/null 2>&1; }

  # 方式 1：官方一键脚本
  if fetch_to https://get.docker.com "$script" 2>/dev/null && [ -s "$script" ]; then
    info "方式 1/4：docker 官方一键脚本"
    sh "$script" >"$log" 2>&1 || true
    docker_ok && ok=1

    # 方式 2：官方脚本 + 阿里云镜像（国内网络通常更快/更通）
    if [ "$ok" != 1 ]; then
      info "方式 2/4：官方脚本 + 阿里云镜像"
      sh "$script" --mirror Aliyun >"$log" 2>&1 || true
      docker_ok && ok=1
    fi
  else
    info "方式 1/4：官方脚本没下下来（网络受限？），换本地仓库"
  fi

  # 方式 3：发行版自带仓库
  if [ "$ok" != 1 ] && detect_pkg_mgr; then
    info "方式 3/4：用 ${PKG_MGR} 装发行版自带的 docker"
    case "$PKG_MGR" in
      apt-get) pkg_install docker.io >"$log" 2>&1 || true ;;
      apk)     pkg_install docker >"$log" 2>&1 || true ;;
      *)       pkg_install docker >"$log" 2>&1 || true ;;
    esac
    docker_ok && ok=1
  fi

  # 方式 4：重装（专门对付「dpkg 说已安装、二进制却缺失/损坏」这种坏状态 ——
  # 普通 install 在这种情况下什么都不会做）
  if [ "$ok" != 1 ] && detect_pkg_mgr; then
    info "方式 4/4：重装 docker 包（包状态可能是坏的）"
    case "$PKG_MGR" in
      apt-get) pkg_install --reinstall docker-ce docker-ce-cli containerd.io >"$log" 2>&1 || true
               docker_ok || pkg_install --reinstall docker.io >"$log" 2>&1 || true ;;
      apk)     pkg_install --force-broken-world docker >"$log" 2>&1 || true ;;
      *)       pkg_install --reinstall docker >"$log" 2>&1 || true ;;
    esac
    docker_ok && ok=1
  fi

  if ! docker_ok; then
    problem "自动装 docker 没成功（四种方式都试过了）"
    if [ -s "$log" ]; then
      info "失败日志最后几行（完整日志：$log）："
      tail -6 "$log" | sed 's/^/      /' >&2
    fi
    info "如果之前手动删过 docker 的文件，可能 dpkg 状态坏了，试试先卸干净再装："
    printf '      %sapt purge -y docker-ce docker-ce-cli containerd.io && curl -fsSL https://get.docker.com | sh%s\n' "$C_BLD" "$C_OFF"
    return 1
  fi
  ok "docker 装好了（$(docker --version 2>/dev/null | cut -c1-40)）"
  return 0
}

ensure_docker_running() {
  docker info >/dev/null 2>&1 && return 0
  warn "docker 装了，但服务没在跑 —— 帮你启起来"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl start docker >/dev/null 2>&1 || true
    systemctl enable docker >/dev/null 2>&1 || true
  elif command -v service >/dev/null 2>&1; then
    service docker start >/dev/null 2>&1 || true
  fi
  local i
  for i in 1 2 3 4 5 6 7 8; do
    docker info >/dev/null 2>&1 && { ok "docker 服务已启动"; return 0; }
    sleep 1
  done
  problem "docker 服务起不来"
  info "看看它为什么起不来：journalctl -u docker --no-pager -n 20"
  return 1
}

ensure_compose() {
  if docker compose version >/dev/null 2>&1; then DC=(docker compose); return 0; fi
  if command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose); return 0; fi

  if [ "$AUTO_DEPS" != 1 ]; then
    problem "缺 docker compose（用来编排服务）"
    info "装一个：apt install -y docker-compose-plugin（或对应发行版的包名）"
    return 1
  fi

  warn "缺 docker compose —— 我来装"
  # 1) 包管理器
  if detect_pkg_mgr; then
    case "$PKG_MGR" in
      apt-get) pkg_install docker-compose-plugin >/dev/null 2>&1 \
                 || pkg_install docker-compose-v2 >/dev/null 2>&1 \
                 || pkg_install docker-compose >/dev/null 2>&1 || true ;;
      *)       pkg_install docker-compose-plugin >/dev/null 2>&1 \
                 || pkg_install docker-compose >/dev/null 2>&1 || true ;;
    esac
    docker compose version >/dev/null 2>&1 && { DC=(docker compose); ok "compose 装好了"; return 0; }
    command -v docker-compose >/dev/null 2>&1 && { DC=(docker-compose); ok "compose 装好了"; return 0; }
  fi

  # 2) 直接下 compose 插件二进制（最通用，不依赖包管理器）
  local dir=/usr/local/lib/docker/cli-plugins ver arch tmp
  mkdir -p "$dir"
  tmp=$(mktemp)
  ver=""
  if fetch_to https://api.github.com/repos/docker/compose/releases/latest "$tmp" 2>/dev/null; then
    ver=$(grep -o '"tag_name": *"[^"]*"' "$tmp" 2>/dev/null | head -1 | cut -d'"' -f4)
  fi
  rm -f "$tmp"
  [ -n "$ver" ] || ver="v2.29.7"          # 查不到就用一个已知可用的版本
  arch=$(uname -m)
  case "$arch" in x86_64|amd64) arch=x86_64 ;; aarch64|arm64) arch=aarch64 ;; esac
  if fetch_to "https://github.com/docker/compose/releases/download/${ver}/docker-compose-linux-${arch}" "$dir/docker-compose" 2>/dev/null \
     && [ -s "$dir/docker-compose" ]; then
    chmod +x "$dir/docker-compose"
    docker compose version >/dev/null 2>&1 && { DC=(docker compose); ok "compose 装好了（${ver}）"; return 0; }
  fi

  problem "compose 没装上"
  info "手动装一次再重跑：apt install -y docker-compose-plugin"
  return 1
}

check_docker() {
  # ⚠️ 只在"真的要装/升级"时才自动装依赖。
  # 查状态/卸载/查更新时自动装 docker 是反直觉的 —— 用户说"卸载"，脚本却给他装了个 docker
  # 出来（实测踩到：我的测试命令里先跑 --uninstall，结果它把 docker 装回来了）。
  # --upgrade 同样属于"只是来看一眼/升一下"，不该顺手给人家装一整套 Docker，故一并挡掉。
  case "${DO_STATUS}${DO_UNINSTALL}${DO_CHECK_UPDATE}${DO_UPGRADE}" in
    *1*) AUTO_DEPS=0 ;;
  esac

  # 🔴 --dry-run 的承诺是「只打印计划，不实际改动」。原来 dry-run 走的是安装路径，
  #   AUTO_DEPS 仍是 1 → 机器上缺 docker 时**真的会装上一整套 Docker**，
  #   装完再打印「dry-run 不做任何改动」—— 自相矛盾，用户以为环境是干净的。
  #   这里改成：只**检测**、只提示将要做什么，缺了就说明并退出，绝不安装/不启动。
  if [ "$DRY_RUN" = 1 ]; then
    if ! command -v docker >/dev/null 2>&1; then
      warn "[dry-run] 本机没有 docker —— 真跑时会先自动安装并启动它；本次不做任何改动"
      info "  ${C_DIM}装完 docker 后请重新跑一次 --dry-run，才能看到反代探测结果${C_OFF}"
      return 1
    fi
    if ! docker info >/dev/null 2>&1; then
      warn "[dry-run] docker 服务未运行 —— 真跑时会尝试启动它；本次不做任何改动"
      return 1
    fi
    if docker compose version >/dev/null 2>&1; then DC=(docker compose)
    elif command -v docker-compose >/dev/null 2>&1; then DC=(docker-compose)
    else
      warn "[dry-run] 缺 docker compose —— 真跑时会自动装；本次不做任何改动"
      return 1
    fi
    ok "[dry-run] docker 已就绪（本次未做任何改动）"
    return 0
  fi

  # 本次只是"看 / 升 / 卸"，不需要 docker 来跑服务 —— 缺了就直接说明，**不装、也不启动**。
  # （单独拎出来是因为 ensure_docker 的提示里带着「自己装的话粘这行」，
  #   对 --status/--upgrade 这类操作是误导 —— 它会让人以为待会儿真会装。）
  if [ "$AUTO_DEPS" != 1 ] && ! command -v docker >/dev/null 2>&1; then
    problem "这台机器上没有 docker，而本次操作不需要它跑服务，所以我没有安装。"
    info "  本次**没有对系统做任何改动**：没装任何包、没改任何配置、没起任何容器。"
    info "  要装的话自己敲：curl -fsSL https://get.docker.com | sh"
    die "已中止。"
  fi

  # ⚠️ 失败文案要如实：走到这里时 ensure_docker **可能已经装了一部分东西**
  #   （apt 半途失败、装完二进制但服务起不来等）。说「未做任何改动」是误导——
  #   用户会以为环境干净，于是什么都不去查。准确的说法是「没改你的配置」。
  if ! ensure_docker; then
    problem "docker 没装上（失败原因见上方输出）。"
    info "  注意：这一步**可能已经在机器上装了一部分东西**（按上面的日志核对）。"
    info "  但本脚本**没有改动任何配置**：没写 Caddyfile、没起容器、没删任何文件。"
    die "已中止。"
  fi
  if ! ensure_docker_running; then
    problem "docker 装了但服务起不来。"
    info "  本脚本没有改动任何配置（没写 Caddyfile、没起容器、没删文件）。"
    info "  先自己排掉：journalctl -u docker --no-pager -n 20"
    die "已中止。"
  fi
  if ! ensure_compose; then
    problem "docker compose 装不上。"
    info "  本脚本没有改动任何配置（没写 Caddyfile、没起容器、没删文件）。"
    die "已中止。"
  fi
  ok "docker 已就绪（跑服务要用的容器工具，不用你管）"
}

# 十六进制转十进制（纯 awk 实现）。
# ⚠️ 不能用 gawk 的 strtonum() —— Debian 默认的 mawk 没有这个扩展。
h2d() {
  awk 'function h2d(h,  i,c,d,v){v=0;for(i=1;i<=length(h);i++){c=tolower(substr(h,i,1));d=index("0123456789abcdef",c)-1;v=v*16+d}return v}
       {n=split($2,a,":"); if($4=="0A") print h2d(a[n])}' "$1" 2>/dev/null
}
# 宿主上所有被占用的 TCP 监听端口（宿主监听 + docker 已发布）
# ⚠️ 不能只依赖 ss：精简镜像常常没装 iproute2，而 `ss ... 2>/dev/null` 会把
#   「命令不存在」和「没有输出」混为一谈 → 返回空 → **所有端口都误判为空闲**。
#   后果实测过：自建 Caddy 模式一路顺利走到 docker up 才撞 80/443，
#   随后反复换面板端口也解不开（面板端口不是问题所在）。
#   这里补一条 /proc/net/tcp{,6} 兜底 —— 内核始终提供，不需要装任何东西。
used_ports() {
  { if command -v ss >/dev/null 2>&1; then
      ss -ltnH 2>/dev/null | awk '{print $4}' | sed 's/.*://'
    else
      h2d /proc/net/tcp
      h2d /proc/net/tcp6
    fi
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
  if ! command -v ss >/dev/null 2>&1; then
    # 没有 ss 就看不见「是哪个进程占着 80/443」，只能知道有没有被占（靠 used_ports）。
    # 不说清楚的话，探测结果一律落到 none → 脚本会去自建 Caddy → 抢不到端口。
    warn "这台机器没装 ss（iproute2），**无法识别已有的反代进程**。"
    info "${C_DIM}  端口占用仍会检查（走 /proc/net/tcp），但识别不出 Caddy/Nginx。${C_OFF}"
    info "  想让探测更准：apt install -y iproute2"
  fi
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
  local p busy="" used
  # 走 used_ports 而不是直接用 ss：它在没有 ss 时有 /proc/net/tcp 兜底，
  # 且用 grep -qx 精确匹配，避开了原来 "[:.]${p}$" 把 ${p} 当正则的隐患。
  used=$(used_ports || true)
  for p in "$@"; do
    if printf '%s\n' "$used" | grep -qx "$p"; then busy="${busy} ${p}"; fi
  done
  if [ -n "$busy" ]; then
    problem "端口${busy} 被别的程序占着 —— 本脚本要腾出 80/443 才能申请 HTTPS 证书"
    info "三个办法，任选一个："
    info "  ① 把占着 80/443 的程序停掉，再重跑本脚本"
    info "  ② 不绑域名：重跑时加 --no-domain（之后走 SSH 隧道访问，不影响使用）"
    info "  ③ 你自己用现有的网页服务器转发到 127.0.0.1:${PANEL_PORT}（面板）和 :${GW_PORT}（网关）"
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
  local f="$1" tmp staged
  tmp=$(mktemp) || return 1
  staged=$(mktemp) || { rm -f "$tmp"; return 1; }
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b {skip=1}
    skip != 1 {print}
    $0 == e {skip=0}
  ' "$f" > "$tmp"
  # 🔴 原来用 `cat "$tmp" > "$f"` 原地覆盖：保留权限/属主是对的，
  #   但**不是原子** —— 写到一半断电或被 kill，Caddyfile 就被截断了，
  #   而本函数自己不备份（apply_domain 的备份在调用前才做，别处不一定有）。
  #   改成：先 cp 原文件做载体（继承权限/属主），内容写进载体，最后 mv 原子替换。
  #   中途失败只会留下垃圾临时文件，不会把线上配置改坏。
  if cp "$f" "$staged" 2>/dev/null && cat "$tmp" > "$staged"; then
    mv -f "$staged" "$f" || rm -f "$staged"
  else
    rm -f "$staged"
  fi
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
# 状态文件是「KEY=VALUE」纯数据。**绝不 source**：
#   ① 里面任何一行都会被当 shell 执行 —— 能写这个文件的人等于能以 root 执行任意代码；
#   ② 文件被写坏时会产生一堆莫名其妙的报错，然后静默回落到默认值（实测踩到）。
# 这里自己解析：只认白名单里的键，值用 printf -v 赋值（不经过 eval，含空格也安全）。
load_state() {
  local f; f="$(state_file)"
  [ -f "$f" ] || return 1
  local line key val n=0 bad=0
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    case "$line" in
      *=*) key="${line%%=*}"; val="${line#*=}" ;;
      *)   bad=1; continue ;;
    esac
    case "$key" in
      INSTALL_DIR|IMAGE_TAG|CONTAINER|PANEL_PORT|GW_PORT|MEM_LIMIT|TZ_NAME|DOMAIN|\
      EXPOSE_MODE|LOCK_REGISTER|BEHIND_CF|CADDY_MODE|CADDY_CONTAINER|CADDY_FILE|\
      CADDY_INNER|CADDY_NET|UPSTREAM_STYLE)
        printf -v "$key" '%s' "$val"; n=$((n+1)) ;;
      *) bad=1 ;;
    esac
  done < "$f"
  if [ "$bad" = 1 ]; then
    warn "状态文件 $(basename "$f") 里有无法识别的行，已忽略（不会执行它们）"
  fi
  [ "$n" -gt 0 ]
}

# ── 交互采集配置 ────────────────────────────────────────────────────────────
gather_config() {
  local existing=0
  if [ -n "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/install.conf" ]; then existing=1; fi
  if [ "$existing" = 1 ] && [ "$DO_UNINSTALL" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
    title "检测到已安装"
    info "目录：$INSTALL_DIR"
    info "容器：$CONTAINER    面板端口：$PANEL_PORT    网关端口：$GW_PORT"
    info "域名：${DOMAIN:-（无）}"
    local c; c=$(choose "要做什么？" 1 "重新配置并重启服务" "升级到新版本" "卸载" "退出")
    # ⚠️ 这里**必须直接调用函数**，不能只设 DO_xxx 标记：
    # 那些标记是在 main() 开头（本函数之前）就检查过的，现在再设等于没人看 ——
    # 实测：选「3) 卸载」后脚本照旧往下走，还问「确认开始安装？」。
    case "$c" in
      1) RECONFIG=1 ;;   # 明确要重新配置 → 后面【第 2 步】必须给开关（不能因为状态文件已填满就跳过）
      2) local t; t=$(ask "要升级到哪个版本（直接回车 = 最新版）" "latest")
         IMAGE_TAG_OVERRIDE="$t"
         do_upgrade; exit $? ;;
      3) do_uninstall; exit 0 ;;
      4) exit 0 ;;
    esac
  fi

  title "agent2api 安装配置"
  # 说明只在**真的会提问**时才打印。以前 --yes / 管道场景下也会打印"直接回车 = 用默认值"
  # 和整段提问说明，看着像要问你、其实一个问题都不问 —— 对新手是误导。
  local will_ask=0
  if [ "$ASSUME_YES" = 1 ]; then
    info "${C_DIM}（--yes 模式：全部使用默认值，不会问你任何问题）${C_OFF}"
  elif [ ! -t 0 ]; then
    warn "当前不是交互终端（stdin 不是 tty）：所有问题将自动采用默认值，不会问你。"
    info "${C_DIM}想逐项选择，请在终端里直接执行：bash $0${C_OFF}"
  else
    will_ask=1
    info "下面会问你 1-2 个问题 —— 直接回车 = 用括号里的默认值"
  fi

  # ── 第 1 步：域名。它决定你后面**怎么访问**，是最关键的决策，所以放最前 ──
  if [ -z "$DOMAIN" ] && [ "$NO_DOMAIN" != 1 ]; then
    if [ "$will_ask" = 1 ]; then
      printf '\n' >&2
      info "【第 1 步】要不要绑域名？"
      printf '        %s绑  → 自动申请 HTTPS 证书，客户端用 https://你的域名/v1（推荐）%s\n' "$C_DIM" "$C_OFF"
      printf '        %s不绑 → 只能走 SSH 隧道，客户端用 http://127.0.0.1:<网关端口>/v1%s\n' "$C_DIM" "$C_OFF"
      printf '        %s（不确定就回车：装完会告诉你下一步怎么做）%s\n' "$C_DIM" "$C_OFF"
    fi
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
      info "${C_DIM}agent2api 的规则是「首个访问者注册管理员」。所以面板一上线，谁先打开谁就是管理员。${C_OFF}"
      info "${C_DIM}不封（默认）：注册最方便，但你得尽快去注册 —— 域名签证书后会进 CT 日志被公开索引。${C_OFF}"
      info "${C_DIM}封掉：注册端点返回 403，注册只能走 SSH 隧道（安全，但多一步）。${C_OFF}"
      if ask_yn "要不要禁止别人从网上自己注册账号？" "n"; then LOCK_REGISTER="y"; else LOCK_REGISTER="n"; fi
    fi
    if [ -z "$BEHIND_CF" ]; then
      if [ "$will_ask" = 1 ]; then
        info "${C_DIM}你的域名是不是在 Cloudflare 上、并且开了「橙色云朵」？是的话选 y；不确定就回车。${C_OFF}"
      fi
      if ask_yn "域名走了 Cloudflare 代理（橙云）吗？" "n"; then BEHIND_CF="y"; else BEHIND_CF="n"; fi
    fi
  else
    EXPOSE_MODE="none"; LOCK_REGISTER="${LOCK_REGISTER:-n}"; BEHIND_CF="n"
  fi

  # ── 第 2 步：高级选项。默认**一个都不问** —— 小白不该被问容器名/时区/内存 ──
  # 判据是「还有哪些值没定」+「用户是否明确要重新配置」，**不是**「命令行给过参数」：
  # 早先用 ADV_GIVEN 判断，结果只传一个 --dir 也会被连问 6 个问题（实测踩到）；
  # 而重跑时状态文件已填满，又会导致开关永远不出现、想改也改不了。
  local adv=1 missing=0
  for _v in "$INSTALL_DIR" "$CONTAINER" "$TZ_NAME" "$IMAGE_TAG" "$PANEL_PORT" "$GW_PORT" "$MEM_LIMIT"; do
    [ -n "$_v" ] || { missing=1; break; }
  done
  if [ "$ASSUME_YES" = 0 ] && [ -t 0 ] && { [ "$missing" = 1 ] || [ "$RECONFIG" = 1 ]; }; then
    printf '\n' >&2
    info "【第 2 步】高级选项：安装目录 / 服务名字 / 端口 / 内存 / 时区 / 版本"
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
    [ -n "$CONTAINER" ]   || CONTAINER=$(ask "服务名字（就是个标识，随便起）" "$DEFAULT_CONTAINER")
    [ -n "$TZ_NAME" ]     || TZ_NAME=$(ask "时区（影响日志时间，一般不用改）" "Asia/Shanghai")

    if [ -z "$IMAGE_TAG" ]; then
      local latest; latest=$(docker_hub_latest_tag || true)
      if [ -n "$latest" ]; then
        IMAGE_TAG=$(ask "版本（最新是 $latest）" "$latest")
      else
        IMAGE_TAG=$(ask "版本" "$DEFAULT_TAG")
      fi
    fi

    # 端口：自动避让
    if [ -z "$PANEL_PORT" ]; then
      local auto_panel; auto_panel=$(pick_port "$DEFAULT_PANEL_PORT" "" || echo "$DEFAULT_PANEL_PORT")
      PANEL_PORT=$(ask_port "面板端口（已自动挑好空闲的，一般不用改）" "$auto_panel")
    fi
    if [ -z "$GW_PORT" ]; then
      local auto_gw; auto_gw=$(pick_port "$DEFAULT_GW_PORT" "$PANEL_PORT" || echo "$DEFAULT_GW_PORT")
      GW_PORT=$(ask_port "网关端口（同上，不用改）" "$auto_gw")
    fi
    [ "$PANEL_PORT" != "$GW_PORT" ] || die "面板端口与网关端口不能相同（都是 $PANEL_PORT）"

    # 端口占用明确告警（用户手动指定的情况）
    if ! port_free "$PANEL_PORT"; then warn "端口 $PANEL_PORT 已被占用，启动失败时脚本会自动换端口重试"; fi
    if ! port_free "$GW_PORT";    then warn "端口 $GW_PORT 已被占用，启动失败时脚本会自动换端口重试"; fi

    [ -n "$MEM_LIMIT" ] || MEM_LIMIT=$(ask_mem "内存上限（够用就行）" "$DEFAULT_MEM")
  fi

  # workbuddy-manager 集成（只在交互 + 高级选项开启时问）
  if [ -z "$MANAGER_INTEGRATE" ]; then
    if [ "$adv" = 1 ] && docker ps --format '{{.Names}}' 2>/dev/null | grep -q 'workbuddy-manager'; then
      printf '\n' >&2
      if ask_yn "这台机器上还有个 workbuddy-manager 面板，要不要把它接到那个面板上？" "n"; then
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
  local line k v reused=0 seen=0
  while IFS= read -r line; do
    case "$line" in ''|\#*) continue ;; esac
    k="${line%%=*}"; v="${line#*=}"
    case "$k" in
      IMAGE_TAG) seen=1;      if [ -z "$IMAGE_TAG" ];   then IMAGE_TAG="$v";   reused=1; fi ;;
      CONTAINER) seen=1;      if [ -z "$CONTAINER" ];   then CONTAINER="$v";   reused=1; fi ;;
      PANEL_PORT) seen=1;     if [ -z "$PANEL_PORT" ];  then PANEL_PORT="$v";  reused=1; fi ;;
      GW_PORT) seen=1;        if [ -z "$GW_PORT" ];     then GW_PORT="$v";     reused=1; fi ;;
      MEM_LIMIT) seen=1;      if [ -z "$MEM_LIMIT" ];   then MEM_LIMIT="$v";   reused=1; fi ;;
      TZ_NAME) seen=1;        if [ -z "$TZ_NAME" ];     then TZ_NAME="$v";     reused=1; fi ;;
      DOMAIN) seen=1;         if [ "$NO_DOMAIN" != 1 ] && [ -z "$DOMAIN" ]; then DOMAIN="$v"; reused=1; fi ;;
      EXPOSE_MODE) seen=1;    if [ -z "$EXPOSE_MODE" ];  then EXPOSE_MODE="$v"; reused=1; fi ;;
      LOCK_REGISTER) seen=1;  if [ -z "$LOCK_REGISTER" ];then LOCK_REGISTER="$v"; reused=1; fi ;;
      BEHIND_CF) seen=1;      if [ -z "$BEHIND_CF" ];   then BEHIND_CF="$v";   reused=1; fi ;;
    esac
  done < "$sf"
  if [ "$reused" = 1 ]; then
    info "已读回上次的配置作为默认值（命令行显式给出的以命令行为准）"
  elif [ "$seen" = 0 ] && [ -s "$sf" ]; then
    # 文件有内容却一个可用键都没有 → 多半被改坏了。必须说出来，
    # 否则用户会看到"它按默认值装了另一个容器"却不知道为什么（实测踩到）。
    warn "状态文件 $(basename "$sf") 里没有可识别的配置（可能被改坏了），将按默认值处理"
  fi
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
    # 位数先卡死：下面 `[ "$p" -gt 65535 ]` 碰到超长数字会整数溢出而报错，
    # 在 set -e 下让脚本在一个莫名其妙的位置退出。5 位 = 最多 99999。
    if [ "${#p}" -gt 5 ]; then
      problem "端口超出范围（1-65535）：$p"; bad=1; continue
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
  else
    # 光看格式不够：0m / 1k 都"合法"，但 docker 的最低内存限制是 6MB，
    # 交给 docker 会得到一个很难懂的报错。这里提前拦下（实测 --mem 0m 曾被放过去）。
    local _n _u _mb
    _n=$(printf '%s' "$MEM_LIMIT" | sed -E 's/^([0-9]+).*/\1/')
    _u=$(printf '%s' "$MEM_LIMIT" | sed -E 's/^[0-9]+([bkmgBKMG]?)$/\1/' | tr 'A-Z' 'a-z')
    # 🔴 位数先卡死：下面要算 `$((_n * 1024))`。`--mem 99999999999999g` 能过上面的正则，
    #   但算术会溢出（bash 报 "value too great for base"），在 set -e 下让脚本
    #   在一个莫名其妙的位置退出。6 位数 = 最多 999999 GB，够用且不会溢出。
    if [ "${#_n}" -gt 6 ]; then
      problem "内存上限的数值过大：'$MEM_LIMIT'（最多 6 位数，即 999999g）"; bad=1
    else
      case "$_u" in
        g) _mb=$((_n * 1024)) ;;
        m|'') _mb=$_n ;;
        k) _mb=$((_n / 1024)) ;;
        b) _mb=0 ;;
      esac
      if [ "$_mb" -lt 6 ]; then
        problem "内存上限太小：'$MEM_LIMIT'（docker 最低 6m；实际使用建议 256m 以上）"; bad=1
      fi
    fi
  fi

  # --no-domain 与 --domain 同时给：语义矛盾，必须直接报错。
  # （实测：两个都给时，脚本一边把域名写进配置、一边又按「不绑域名」处理，输出自相矛盾）
  if [ "$NO_DOMAIN" = 1 ] && [ -n "$DOMAIN" ]; then
    problem "--no-domain 与 --domain 不能同时使用（一个说不要域名、一个给了域名）"
    bad=1
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
  # （这里只需要隧道面板：网关本身是公网可达的。命令里的 IP/用户名都填好，别留占位符）
  if [ -n "$DOMAIN" ] && [ "$EXPOSE_MODE" = "gateway" ]; then
    local _h _u
    _h=$(host_public_ip || true); [ -n "$_h" ] || _h="<你的服务器IP>"
    _u="${SUDO_USER:-}"; [ -n "$_u" ] || _u="$(id -un 2>/dev/null || echo root)"
    warn "只暴露了 /v1 网关，面板没有公网入口 —— 注册管理员 / 加账号要走 SSH 隧道："
    printf '      %sssh -N -L %s:127.0.0.1:%s %s@%s%s\n' "$C_DIM" "$PANEL_PORT" "$PANEL_PORT" "$_u" "$_h" "$C_OFF"
    printf '      然后浏览器打开 %shttp://127.0.0.1:%s%s\n' "$C_BLD" "$PANEL_PORT" "$C_OFF"
    info "${C_DIM}（网关本身公网可达、不用隧道；只有面板需要）${C_OFF}"
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
        # 🔴 取不到共享网络时**不能**静默回落到 loopback。
        #   容器里的反代够不到宿主的 127.0.0.1，于是生成的 Caddyfile 语法正确、
        #   validate 通过、reload 也成功 —— 但一访问就是 502。更糟的是旧版
        #   verify_tls 会把 502 报成「证书尚未就绪」，把人引向 DNS / 安全组，
        #   三个方向一个都不对（实测踩过）。
        #   正确做法只有两条：同网络走容器名，或宿主侧服务改绑 docker 网桥网关
        #   （线上实测就是 172.19.0.1，不是 127.0.0.1）。
        #   这里没有域名、不写站点块时无所谓；有域名就必须问清楚。
        if [ -n "$DOMAIN" ]; then
          problem "反代容器 ${CADDY_CONTAINER} 上没取到 docker 网络，无法确定反代方式。"
          info "  容器里的反代够不到宿主 127.0.0.1。若按 127.0.0.1 生成配置，"
          info "  Caddyfile 会校验通过、reload 也成功，但一访问就是 502。"
          info "  先查清楚它到底在哪个网络："
          info "    docker inspect ${CADDY_CONTAINER} | grep -A3 NetworkSettings"
          info "  确认网络名后，可加 --caddy-mode docker 强制走容器名反代。"
          die "已中止（未做任何改动）。"
        fi
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
  step "3/6" "下载并启动服务"
  info "${C_DIM}第一次要下载程序本体，这一步最慢 —— 网慢的话几分钟，看着不动也别关。${C_OFF}"
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
    || { info "${C_DIM}（这台机器上跑着 ${CADDY_MODE}，本脚本不会去改它，以免弄坏你现有的网站）${C_OFF}"
         die "没法自动配域名。两个办法：重跑时加 --no-domain（走 SSH 隧道），或你自己把域名转发到 127.0.0.1:${PANEL_PORT}（面板）和 :${GW_PORT}（网关）。"; }
  if [ "$CADDY_MODE" = "self" ]; then
    install -d -m 755 "$INSTALL_DIR"
    [ -f "$CADDY_FILE" ] || printf '# managed by install-agent2api.sh\n' > "$CADDY_FILE"
  else
    locate_caddyfile || die "找到了网页服务器（Caddy），但没找到它的配置文件（通常就在 /etc/caddy/Caddyfile）。也可以重跑时加 --no-domain，走隧道访问。"
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
  prune_own_backups   # 只留最近 3 份自己的备份，别往系统目录堆垃圾

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
  local i tls="" code
  info "等待证书签发（最长 60 秒）…"

  # 🔴 必须把「证书没签出来」与「后端连不上」**分开判**。
  # 原来只看 HTTP 状态码是不是 2xx/3xx，而反代拿不到后端返回的是 502 →
  # 不匹配 → 统一报成「证书尚未就绪」，并把用户指向 DNS / 安全组 / 解析传播。
  # 那三个方向**一个都不对**（实测踩过：后端容器根本没在监听）。
  # 所以先单独验 TLS 握手：能拿到 X509 才说明证书链路通了。
  for i in $(seq 1 20); do
    tls=$(echo | timeout 8 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
    [ -n "$tls" ] && break
    sleep 3
  done
  if [ -z "$tls" ]; then
    problem "TLS 握手拿不到证书 —— 这一步确实还没通"
    info "  · 域名没解析到本机（Let's Encrypt 需从公网访问 80/443）"
    info "  · 云安全组 / 防火墙没放通 80、443"
    info "  · 80/443 上跑的不是本脚本配置的 Caddy"
    info "  · 证书还在签发中：docker logs ${CADDY_CONTAINER:-${CADDY_SELF_CONTAINER:-<caddy>}} 2>&1 | tail -20"
    return 1
  fi
  ok "证书已签发（到期：$tls）"

  # 证书已确认，再看 HTTP：此时的失败一定是应用层，不会再误报成证书问题
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
          --resolve "${DOMAIN}:443:127.0.0.1" "https://${DOMAIN}/" 2>/dev/null || echo 000)
  case "$code" in
    2*|3*) ok "HTTPS 就绪（HTTP $code）" ;;
    502|504)
      problem "反代拿不到后端（HTTP $code）—— 证书是好的，问题在容器网络"
      info "  · 反代在**容器**里时够不到宿主的 127.0.0.1，必须同网络走容器名，"
      info "    或宿主侧服务改绑 docker 网桥网关（如 172.19.0.1）而不是 127.0.0.1"
      info "  · 查反代所在网络：docker inspect -f '{{range \$k,\$v := .NetworkSettings.Networks}}{{\$k}}{{\"\n\"}}{{end}}' ${CADDY_CONTAINER:-<caddy容器>}"
      info "  · 查后端在不在：docker logs ${CONTAINER} --tail 20"
      return 1 ;;
    *)  problem "HTTPS 返回 $code（证书正常，是应用层异常）" ;;
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
    warn "容器里没有 WB_ADMIN_PASSWORD —— 面板用的是首次启动时随机生成的密码，自动登记跳过。"
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

  # 🔴 登录失败必须**明确区分**「密码不对」和「其它问题」。
  #   WB_ADMIN_PASSWORD 只是 workbuddy-manager **首次启动**时的初始值；
  #   用户后来在面板里改过密码后，环境变量里那份就成了旧密码（源码 security.py:135
  #   只在首次启动时用它建用户，之后以 users.json 的 pwd_hash 为准）。
  #   而该项目的登录失败计数是 IP + **用户名**双维度，阈值 5 次 / 锁定 10 分钟
  #   （security.py: MAX_FAILS=5、LOCK_SECONDS=600）。也就是说
  #   **每重跑一次本脚本就记一次失败，5 次后连管理员本人都被锁在外面。**
  #   所以这里绝不能让用户以为「再跑一次就好了」。
  local rc=0
  MGR_BASE="$url_base" MGR_USER="$user" MGR_PW="$pw" MGR_KEY="$a2akey" \
  MGR_UP_URL="http://${CONTAINER}:${GW_PORT}" MGR_UP_NAME="${CONTAINER}(Qoder)" \
  python3 - <<'PY' || rc=$?
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
    except Exception as e:
        return 0, str(e)[:200]
st,body=call("/api/login", {"username":os.environ["MGR_USER"], "password":os.environ["MGR_PW"]})
if st!=200:
    print("  manager 登录未成功（HTTP %s）%s" % (st, ("：" + str(body)[:120]) if st not in (401,) else "：用户名或密码错误"))
    raise SystemExit(2 if st in (401,403,429) else 1)
print("  已登录 manager")
st,up=call("/api/upstreams")
if st!=200:
    print("  读取上游列表失败（HTTP %s）" % st); raise SystemExit(1)
target=os.environ["MGR_UP_URL"]
if any(u.get("base_url")==target for u in (up.get("items") or [])):
    print("  上游已存在，无需重复添加")
else:
    st,res=call("/api/upstreams", {"name":os.environ["MGR_UP_NAME"], "base_url":target,
        "api_key":os.environ["MGR_KEY"], "note":"由 install-agent2api.sh 自动登记",
        "enabled":True, "auth_dir":"", "container":os.environ.get("MGR_UP_CONTAINER","")})
    if st in (200,201):
        print("  新增上游：成功")
    else:
        print("  新增上游失败（HTTP %s）：%s" % (st, res)); raise SystemExit(1)
PY

  if [ "$rc" = 2 ]; then
    problem "manager 自动登记已跳过 —— 登录被拒。"
    info "  最可能的原因：WB_ADMIN_PASSWORD 是面板**首次启动**时的初始值；"
    info "  如果你后来在面板里改过密码，它就已经过期了。"
    info "  ⚠️ 该项目有登录锁定（同一用户名失败 5 次即锁 10 分钟），"
    info "     请**不要反复重跑本脚本**去试密码。"
    info "  两条出路："
    info "    ① 到 manager 面板「设置」里重设密码，或确认环境变量与面板密码一致"
    info "    ② 重跑时加 --no-manager 跳过自动登记，再到面板「设置 → 上游」手工新增"
    info "        地址 http://${CONTAINER}:${GW_PORT}（不带 /v1）"
    info "        密钥 = agent2api 面板「网关 Key」里那把"
  elif [ "$rc" != 0 ]; then
    warn "manager 登记未完成（HTTP/网络层问题，不是密码问题）"
    info "  请到面板「设置 → 上游」手动新增："
    info "    地址 http://${CONTAINER}:${GW_PORT}（不带 /v1）"
  fi
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
  need_state
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
  need_state
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

# 读安装状态文件；读不到就给出**能照着做**的提示。
# 原来三处都只说「读不到 xxx/install.conf（用 --dir 指定安装目录）」——
# 可用户明明已经传了 --dir，真正的原因是"上次装到一半中断了、状态文件还没写"，
# 那句话会把人带偏（实测：中断后跑 --status 就撞上这个）。
need_state() {
  load_state && return 0
  if [ -d "$INSTALL_DIR" ]; then
    problem "在 $INSTALL_DIR 里没找到安装记录（install.conf）"
    info "多半是上次装到一半中断了。直接重跑脚本就能接着装："
    printf '      %sbash %s --dir %s%s\n' "$C_BLD" "$0" "$INSTALL_DIR" "$C_OFF"
  else
    problem "这台机器上还没装过（$INSTALL_DIR 不存在）"
    info "先跑一次安装就行："
    printf '      %sbash %s%s\n' "$C_BLD" "$0" "$C_OFF"
  fi
  die "已中止（未做任何改动）。"
}

do_status() {
  need_state
  title "运行状态"
  info "安装目录：$INSTALL_DIR"
  info "程序：${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}"
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
    # 🔴 白名单：拒绝删顶层目录。
    #   INSTALL_DIR 来自 --dir/状态文件，validate_inputs 只查了空格与绝对路径；
    #   而这里要跑的是 rm -rf。`--dir /opt` 一次确认就能把整棵 /opt 端掉 ——
    #   而真实部署往往就在 /opt 下面。确认框挡得住「手快」，挡不住「我就是想删它」。
    case "$INSTALL_DIR" in
      /|/bin|/boot|/dev|/etc|/home|/lib|/lib64|/media|/mnt|/opt|/proc|/root|/run|/sbin|/srv|/sys|/tmp|/usr|/var)
        problem "拒绝删除顶层目录：$INSTALL_DIR"
        info "${C_DIM}  脚本只该删自己的安装子目录（默认 /opt/agent2api）。${C_OFF}"
        info "目录保留：$INSTALL_DIR"
        ;;
      *)
        if ask_yn "删除目录 $INSTALL_DIR（含数据卷 data/，不可恢复）？" "n"; then
          run rm -rf "$INSTALL_DIR"; ok "已删除 $INSTALL_DIR"
        else
          info "目录保留：$INSTALL_DIR"
        fi ;;
    esac
  fi
  local img="${DEFAULT_IMAGE_REPO}:${IMAGE_TAG:-$DEFAULT_TAG}"
  info "镜像 ${img} 保留未删（需要时：docker rmi ${img}）"
  ok "卸载完成"
}

# 供应链可核对性：把「现在跑的到底是哪个镜像、内容摘要是什么」明确打出来。
# 只打印 tag 是不够的 —— **tag 是可变的**，同一个 tag 随时可以被重新推成另一个镜像，
# 用户只看到 "2.9.1" 无从发现。digest 才是不可变的内容地址。
print_image_provenance() {
  local img id
  img="${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}"
  id=$(docker inspect "$CONTAINER" --format '{{.Image}}' 2>/dev/null || true)
  if [ -n "$id" ]; then
    ok "镜像：$img"
    info "${C_DIM}  内容摘要 sha256:${id}（不可变；核对可用 docker inspect --format '{{.Image}}' ${CONTAINER}）${C_OFF}"
  else
    warn "读不到镜像摘要（容器可能还没起来）。"
  fi
  case "$IMAGE_TAG" in
    latest|main|master|"")
      problem "你在用可变 tag（${IMAGE_TAG:-空}）—— 它随时可能被重新指向另一个镜像。"
      info "  生产环境请锁定具体版本号，或用 --tag 指定；改完记得同步更新 install.conf。"
      ;;
  esac
}

# ── 汇总 ────────────────────────────────────────────────────────────────────
summary() {
  # 管理员注册状态（决定"下一步"该说注册还是说登录）
  local registered=0
  if docker exec "$CONTAINER" curl -s --max-time 6 "http://127.0.0.1:${PANEL_PORT}/api/panel/status" 2>/dev/null \
     | grep -q '"registered":true'; then
    registered=1
  fi

  local panel_url
  if [ -n "$DOMAIN" ]; then panel_url="https://${DOMAIN}/"; else panel_url="http://127.0.0.1:${PANEL_PORT}/"; fi

  title "装好了！"
  print_image_provenance

  # ══════════ 新手只需要看这一段：一个明确的下一个动作 ══════════
  printf '\n'
  printf '%s════════════════════════════════════════════════════════%s\n' "$C_BLD" "$C_OFF"
  if [ "$registered" = 1 ]; then
    printf '%s  下一步：用浏览器打开面板，用你刚注册的账号登录%s\n' "$C_BLD" "$C_OFF"
  else
    printf '%s  下一步：用浏览器打开面板，注册一个管理员账号%s\n' "$C_BLD" "$C_OFF"
  fi
  printf '%s════════════════════════════════════════════════════════%s\n' "$C_BLD" "$C_OFF"
  printf '\n'

  if [ -n "$DOMAIN" ]; then
    printf '  打开这个网址：%s%s%s\n' "$C_BLD" "$panel_url" "$C_OFF"
    [ "$registered" = 1 ] || printf '  然后按页面提示设个用户名和密码（随便设，记住就行）。\n'
    if [ "$registered" != 1 ] && [ "$LOCK_REGISTER" != "y" ]; then
      printf '\n'
      problem "这一步请尽快做：现在任何人打开这个网址，都能抢先注册成管理员"
      info "${C_DIM}（不想这样：重跑时加 --lock-register，注册就只走 SSH 隧道）${C_OFF}"
    fi
  else
    # 不绑域名 → 面板只能从用户自己的电脑访问。新手最容易卡在这一步：
    # 要开隧道、还会被问密码。所以分两步写清楚，连"会问密码""看着像卡住是正常的""窗口不能关"都说明白。
    # 另外必须提一句"如果你平时不是用密码登录的"——脚本打印的是 root@IP，
    # 会绕过用户自己的 ssh 别名/密钥（实测：用别名能通、直接敲 IP 会被拒）。
    local ssh_host ssh_user
    ssh_host=$(host_public_ip || true); [ -n "$ssh_host" ] || ssh_host="<你的服务器IP>"
    ssh_user="${SUDO_USER:-}"; [ -n "$ssh_user" ] || ssh_user="$(id -un 2>/dev/null || echo root)"

    printf '  你没绑域名，所以面板只能从你自己的电脑访问。两步：\n\n'
    printf '  %s第 1 步：在你自己的电脑上开个终端（Windows 按 Win+R 输入 cmd 回车），粘这条：%s\n' "$C_BLD" "$C_OFF"
    printf '\n'
    printf '      %sssh -N -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s %s@%s%s\n' \
      "$C_DIM" "$PANEL_PORT" "$PANEL_PORT" "$GW_PORT" "$GW_PORT" "$ssh_user" "$ssh_host" "$C_OFF"
    printf '\n'
    printf '      %s它会让你输密码 —— 就是你登录这台服务器时用的那个。%s\n' "$C_DIM" "$C_OFF"
    printf '      %s输完屏幕上不会出现任何东西、看着像卡住，那是正常的（它在保持连接）。%s\n' "$C_DIM" "$C_OFF"
    printf '      %s这个窗口别关，关了连接就断。%s\n' "$C_DIM" "$C_OFF"
    printf '\n'
    printf '      %s如果它报 Permission denied（密码不对），说明你平时不是用密码登录这台机器的 ——%s\n' "$C_DIM" "$C_OFF"
    printf '      %s那就把你自己平时登录它的那条 ssh 命令拿出来，在后面加上这两个参数：%s\n' "$C_DIM" "$C_OFF"
    printf '          %s-N -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s%s\n' \
      "$C_BLD" "$PANEL_PORT" "$PANEL_PORT" "$GW_PORT" "$GW_PORT" "$C_OFF"
    printf '      %s（比如平时敲 ssh myvps 就能进，那就敲：ssh -N -L %s:127.0.0.1:%s -L %s:127.0.0.1:%s myvps）%s\n' \
      "$C_DIM" "$PANEL_PORT" "$PANEL_PORT" "$GW_PORT" "$GW_PORT" "$C_OFF"
    printf '\n'
    printf '  %s第 2 步：另开浏览器，打开 %s%s%s%s\n' "$C_BLD" "$C_OFF" "$C_BLD" "$panel_url" "$C_OFF"
    printf '          然后按页面提示设个用户名和密码。\n'
  fi

  # ── 进面板之后要做的三件事（小白最容易卡在「建了 Key 但没有模型」）──
  printf '\n'
  info "进面板之后，按这个顺序做三件事："
  # 措辞是实测出来的：原来只说"加上你的 AI 上游账号"，小白根本不知道指什么。
  # 面板实际支持这些 AI 工具的账号（实测 /api/accounts 拿到 14 种），把例子列出来他才明白要准备什么。
  printf '      %s①%s 在「账号」里加上游账号 —— 面板会列出支持的类型：\n' "$C_BLD" "$C_OFF"
  printf '         %sWorkBuddy / 小浣熊 / Qoder / Trae / Cline / Accio / ZCode / CatPaw / CodeArts …%s\n' "$C_DIM" "$C_OFF"
  printf '         %s选一个你有的，按提示登录或填 Key。少了这步，客户端拿不到任何模型%s\n' "$C_DIM" "$C_OFF"
  printf '      %s②%s 在「网关 Key」里建一把 Key（客户端要用它）\n' "$C_BLD" "$C_OFF"
  printf '      %s③%s 把它填到你的 AI 工具里（见下面「客户端里怎么填」）\n' "$C_BLD" "$C_OFF"

  # ══════════ 以下降级为参考资料 ══════════
  printf '\n'
  printf '%s  ────────── 以下是详细信息，以后需要再查 ──────────%s\n' "$C_DIM" "$C_OFF"
  printf '\n'

  case "$CADDY_MODE" in
    self)        info "网页服务器：本脚本自建的容器（证书存在 ${INSTALL_DIR}/caddy-data）" ;;
    docker|host) info "网页服务器：复用这台机器上已有的 Caddy（配置已自动备份，不影响现有网站）" ;;
  esac
  if [ -n "$DOMAIN" ]; then
    case "$EXPOSE_MODE" in
      panel)   printf '  %s面板：%s https://%s/\n' "$C_BLD" "$C_OFF" "$DOMAIN" ;;
      gateway) printf '  %s网关：%s https://%s/v1\n' "$C_BLD" "$C_OFF" "$DOMAIN" ;;
      *)       printf '  %s面板：%s https://%s/\n' "$C_BLD" "$C_OFF" "$DOMAIN"
               printf '  %s网关：%s https://%s/v1\n' "$C_BLD" "$C_OFF" "$DOMAIN" ;;
    esac
  else
    printf '  %s面板：%s http://127.0.0.1:%s（走上面的隧道）\n' "$C_BLD" "$C_OFF" "$PANEL_PORT"
    printf '  %s网关：%s http://127.0.0.1:%s/v1\n' "$C_BLD" "$C_OFF" "$GW_PORT"
  fi
  printf '\n'
  info "客户端里怎么填（base_url 填地址，api_key 填面板里建的那把 Key）："
  if [ -n "$DOMAIN" ]; then
    printf '      base_url = %shttps://%s/v1%s\n' "$C_BLD" "$DOMAIN" "$C_OFF"
  else
    printf '      base_url = %shttp://127.0.0.1:%s/v1%s\n' "$C_BLD" "$GW_PORT" "$C_OFF"
  fi
  printf '      api_key  = 面板 →「网关 Key」→ 新建，建出来是一串 sk-a2a- 开头的字符\n'
  printf '\n'
  info "常用命令："
  printf '      bash %s --status        # 看运行状态\n' "$0"
  printf '      bash %s --upgrade       # 升级\n' "$0"
  printf '      bash %s --uninstall     # 卸载\n' "$0"
  printf '      cd %s && docker compose logs -f --tail 50   # 看日志\n' "$INSTALL_DIR"
  printf '\n'
  info "${C_DIM}状态文件：$(state_file)（改完重跑脚本即可生效）${C_OFF}"
  if [ "$LOCK_REGISTER" = "y" ] && [ -n "$DOMAIN" ]; then
    info "${C_DIM}注册端点已封。要开放就重跑并加 --open-register。${C_OFF}"
  fi
  printf '\n'
  info "${C_DIM}要在别的机器上装，把这行粘过去就行：${C_OFF}"
  printf '      %scurl -fsSL https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/deploy.sh | sudo bash%s\n' "$C_DIM" "$C_OFF"
}

# ── 主流程 ──────────────────────────────────────────────────────────────────
main() {
  parse_args "$@"
  title "agent2api 一键安装器 v$SCRIPT_VERSION"
  [ "$DRY_RUN" = 1 ] && warn "dry-run 模式：只打印计划，不会做任何改动"

  # 新手友好：先用人话说清楚「在装什么、要多久、会被问几个问题」。
  # 小白刚粘完一条陌生命令，第一屏必须让他知道"这事在往哪走"，而不是直接看到一堆术语。
  # 只在安装路径显示（查状态/卸载/升级时不需要这段开场白）。
  if [ -z "${DO_STATUS}${DO_UNINSTALL}${DO_UPGRADE}${DO_CHECK_UPDATE}" ]; then
    printf '\n'
    info "我在帮你装一个 agent2api 服务。装好之后你可以："
    info "  · 用浏览器打开一个网址来管理它（加账号、建密钥）"
    info "  · 让 AI 工具（客户端）连上它来调用接口"
    printf '\n'
    info "${C_DIM}大概要 1-3 分钟 —— 第一次得下载程序本体，网慢就久一点，别急。${C_OFF}"
    info "${C_DIM}只会问你 1-2 个问题。拿不准的${C_OFF}${C_BLD}直接按回车${C_OFF}${C_DIM}，用默认值就行。${C_OFF}"
  fi

  need_root
  check_docker

  step "1/6" "检查环境"
  detect_web_server
  resolve_caddy_net
  case "$CADDY_MODE" in
    docker) ok "发现 Caddy 容器：$CADDY_CONTAINER" ;;
    host)   ok "这台机器上已有网页服务器（Caddy），会复用它配 HTTPS" ;;
    nginx)  warn "80/443 上是 Nginx（本脚本只自动写 Caddy 配置）—— 绑域名需你手动反代" ;;
    other)  warn "80/443 被非 Caddy 程序占用 —— 绑域名需你手动反代" ;;
    none)   info "80/443 上没有反向代理；若绑域名，将由本脚本自建 Caddy 容器（需 80/443 空闲）" ;;
  esac
  if locate_caddyfile; then
    ok "已找到它的配置文件（改之前会自动备份，不影响你现有的网站）"
    info "${C_DIM}  （文件位置：$CADDY_FILE）${C_OFF}"
  elif [ "$CADDY_MODE" != "none" ]; then warn "没找到网页服务器的配置文件，稍后会按另一种方式处理"; fi

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
  info "程序：${DEFAULT_IMAGE_REPO}:${IMAGE_TAG}"
  info "面板端口：$PANEL_PORT    网关端口：$GW_PORT"
  local expose_cn
  case "$EXPOSE_MODE" in
    both)    expose_cn="面板 + 网关" ;;
    panel)   expose_cn="只有面板" ;;
    gateway) expose_cn="只有网关（/v1）" ;;
    *)       expose_cn="无（没绑域名）" ;;
  esac
  info "域名：${DOMAIN:-（不绑）}    对外提供：$expose_cn"
  info "禁止自助注册：${LOCK_REGISTER}    内存上限：$MEM_LIMIT"

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
