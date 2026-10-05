#!/usr/bin/env bash
#
# agent2api 安装器 —— 引导脚本（让「装到 VPS」变成一行命令）
# ============================================================================
# 用法（在 VPS 上执行，root 权限）：
#
#   curl -fsSL https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/deploy.sh | sudo bash
#
#   # 带上安装参数（-- 后面原样传给安装器）
#   curl -fsSL https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/deploy.sh \
#     | sudo bash -s -- --domain a2a.example.com --expose both
#
# 它做的事：依次尝试多个下载源 → 校验拿到的是合法脚本 → 落盘到固定路径 → 执行。
# 落盘（而不是直接管道给 bash）是有意的：安装器要靠自身路径打印「以后怎么重跑 / 怎么卸载」，
# 管道执行时 $0 是 bash，那些提示就没用了。
#
# 环境变量：
#   A2A_TARGET  安装器落盘路径（默认 /root/install-agent2api.sh）
#
set -euo pipefail

TARGET="${A2A_TARGET:-/root/install-agent2api.sh}"
SOURCES=(
  "https://pan.ailxw.com/api/pickup-download?code=20818"
  "https://cdn.jsdelivr.net/gh/yys9253462-gif/agent2api-installer@main/install-agent2api.sh"
  "https://raw.githubusercontent.com/yys9253462-gif/agent2api-installer/main/install-agent2api.sh"
)

say() { printf '  %s\n' "$1"; }

# ── 下载内容的三级校验 ──────────────────────────────────────────────────────
# ⚠️ 原来只做 `bash -n`（语法检查）。那挡不住两件事：
#   ① 下载源挂了返回 HTML/JSON 错误页 —— 有小概率仍是"合法 shell"；
#   ② 第一源是**静态副本**（网盘），与 GitHub main 会漂移；有人改了网盘上的文件，
#      语法完全正常，但内容已经不是同一个东西了。
# 三级：① 必须像安装器 ② 版本号可读 ③ 期望摘要相符（设了才查）。
# 想强校验：EXPECT_SHA256=<64位十六进制> curl … | sudo bash
EXPECT_SHA256="${EXPECT_SHA256:-}"
verify_downloaded() {   # $1=文件；返回 0=通过
  local f="$1" head1 ver
  head1=$(head -c 2 "$f" 2>/dev/null || true)
  if [ "$head1" != "#!" ]; then
    say "× 下载到的不是可执行脚本（缺少 shebang，可能是错误页）"
    return 1
  fi
  ver=$(grep -m1 '^SCRIPT_VERSION=' "$f" 2>/dev/null | cut -d'"' -f2 || true)
  if [ -z "$ver" ]; then
    say "× 下载到的脚本里没有 SCRIPT_VERSION —— 不是 agent2api 安装器"
    return 1
  fi
  if [ -n "$EXPECT_SHA256" ]; then
    local got
    got=$(sha256sum "$f" 2>/dev/null | cut -d' ' -f1 || true)
    if [ "$got" != "$EXPECT_SHA256" ]; then
      say "× SHA256 不符 —— 期望 $EXPECT_SHA256，实际 ${got:-取不到}"
      return 1
    fi
    say "  ✓ SHA256 相符"
  fi
  bash -n "$f" 2>/dev/null || { say "× 语法检查不通过"; return 1; }
  return 0
}

if [ "$(id -u)" != 0 ]; then
  # 别无脑提示「加 sudo」—— 很多精简镜像根本没装 sudo（登录就是 root）
  if command -v sudo >/dev/null 2>&1; then
    echo "需要 root 权限。请改用：curl -fsSL <本脚本地址> | sudo bash" >&2
  else
    echo "需要 root 权限，但这台机器上没有 sudo。请先 su - 切到 root 再执行。" >&2
  fi
  exit 1
fi
for c in curl bash; do
  command -v "$c" >/dev/null 2>&1 || { echo "缺少 $c，请先安装" >&2; exit 1; }
done

echo
say "agent2api 安装器引导"
say "------------------------------------------------------------"
say "正在下载安装器（会依次尝试 ${#SOURCES[@]} 个源）…"

ok=0
# 🔴 下载到**临时文件**，校验通过才 install 到 $TARGET。
#   原来直接 curl -o "$TARGET"：校验失败时那份不合格的内容**仍然留在磁盘上**
#   （默认就是 /root/install-agent2api.sh）。用户看到「所有源都没成功」，
#   却可能稍后手动 `bash /root/install-agent2api.sh` —— 跑的正是没通过校验的文件。
#   实测踩过：三个源全被 SHA256 拒绝后，$TARGET 里仍躺着 95874 字节的过期内容。
CAND="$(mktemp -d)/installer.sh"
cleanup() { rm -rf "$(dirname "$CAND")"; }
trap cleanup EXIT

for u in "${SOURCES[@]}"; do
  host=$(printf '%s' "$u" | awk -F/ '{print $3}')
  if curl -fsSL --max-time 60 "$u" -o "$CAND" 2>/dev/null && [ -s "$CAND" ] && verify_downloaded "$CAND"; then
    if install -m 0755 "$CAND" "$TARGET" 2>/dev/null || { cp "$CAND" "$TARGET" && chmod +x "$TARGET"; }; then
      say "✓ 来自 $host（$(wc -c < "$TARGET" | tr -d ' ') 字节）"
      ok=1
      break
    fi
    say "× 写不进 $TARGET，换下一个源"
  fi
  rm -f "$CAND"
  say "× $host 不可用或校验不通过，换下一个"
done

if [ "$ok" != 1 ]; then
  say "所有源都没成功。**$TARGET 未被写入**（原先那份如果有，也原封未动）。"
  say "可以自己下载后放到 $TARGET 再执行。"
  exit 1
fi

chmod +x "$TARGET" 2>/dev/null || true
ver=$(grep -m1 '^SCRIPT_VERSION=' "$TARGET" 2>/dev/null | cut -d'"' -f2 || true)
say "版本：${ver:-未知}    路径：$TARGET"
if command -v sha256sum >/dev/null 2>&1; then
  got_sha=$(sha256sum "$TARGET" | cut -d' ' -f1)
  say "SHA256：${got_sha}"
  if [ -z "$EXPECT_SHA256" ]; then
    say "  （未设置 EXPECT_SHA256，本次只做了「是不是安装器 + 语法」两级校验）"
  fi
fi
say "------------------------------------------------------------"
echo

# 🔴 关键：这个脚本通常是「管道喂给 bash」的（curl … | sudo bash），
#    此时 stdin 已经被 curl 用完了（EOF）。而安装器默认是**交互式**的，
#    它读不到键盘就会静默走默认值 —— 实测 `bash install.sh < /dev/null` 一个都不问、
#    直接用默认值往下装，用户完全不知道自己"被默认"了。
#    所以有终端就把 stdin 接回终端。
if [ -t 0 ]; then
  exec bash "$TARGET" "$@"                       # 本来就是从终端来的，直接跑
elif (exec 3</dev/tty) 2>/dev/null; then
  # 注意：不能只用 [ -c /dev/tty ] 判断 —— 设备节点总是存在，但**没有控制终端时
  # 打开它会 ENXIO**（实测把 --help 都搞挂了）。必须真的试开一次。
  exec bash "$TARGET" "$@" </dev/tty             # 从管道来的 → 接回终端
else
  say "注意：当前没有可用的终端，交互提问会全部采用默认值。"
  say "      想指定参数请用：sudo bash $TARGET --yes --domain 你的域名"
  echo
  exec bash "$TARGET" "$@" </dev/null
fi
