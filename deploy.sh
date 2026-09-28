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
for u in "${SOURCES[@]}"; do
  host=$(printf '%s' "$u" | awk -F/ '{print $3}')
  if curl -fsSL --max-time 60 "$u" -o "$TARGET" 2>/dev/null && [ -s "$TARGET" ] && bash -n "$TARGET" 2>/dev/null; then
    say "✓ 来自 $host（$(wc -c < "$TARGET" | tr -d ' ') 字节）"
    ok=1
    break
  fi
  say "× $host 不可用，换下一个"
done

if [ "$ok" != 1 ]; then
  say "所有源都没成功。可以自己下载后放到 $TARGET 再执行。"
  exit 1
fi

chmod +x "$TARGET" 2>/dev/null || true
ver=$(grep -m1 '^SCRIPT_VERSION=' "$TARGET" 2>/dev/null | cut -d'"' -f2 || true)
say "版本：${ver:-未知}    路径：$TARGET"
if command -v sha256sum >/dev/null 2>&1; then
  say "SHA256：$(sha256sum "$TARGET" | cut -c1-16)…"
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
