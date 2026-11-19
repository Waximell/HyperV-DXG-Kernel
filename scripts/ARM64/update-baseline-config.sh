#!/usr/bin/env bash
# 手动更新仓库里钉死的 Debian 基线 config（构建时**不会**调用这个脚本）。
#
# 为什么是 6.18.15：Debian 一个 suite 只养一条主线。trixie-backports 的 6.18 系列
# 停在 6.18.15（6.18.15-1~bpo13+1），之后直接跳 6.19/7.x；而 Debian 从来没有
# 单独的 linux-config-6.18 包（只有 5.10/6.1/6.12/7.2/7.3），所以拿不到 1–2 MB 的
# 拆分包，只能从内核镜像包里抽 /boot/config-*。
#
# 用法:
#   scripts/ARM64/update-baseline-config.sh [输出路径]
#   scripts/ARM64/update-baseline-config.sh --deb=/path/to/linux-image-*.deb [输出路径]
#
# 一次下载约 92 MB（linux-image-6.18.15+deb13-arm64）。只想校验已有快照就别跑它。
set -Eeuo pipefail

MIRROR="${MIRROR:-https://deb.debian.org/debian}"
POOL="main/l/linux-signed-arm64"
PKG="linux-image-6.18.15+deb13-arm64"
VER="6.18.15-1~bpo13+1"
DEB_URL="$MIRROR/pool/$POOL/${PKG}_${VER}_arm64.deb"

LOCAL_DEB=""
OUT=""
for arg in "$@"; do
  case "$arg" in
    --deb=*) LOCAL_DEB="${arg#--deb=}" ;;
    -*) echo "未知参数: $arg" >&2; exit 2 ;;
    *) OUT="$arg" ;;
  esac
done
OUT="${OUT:-config/ARM64/debian-6.18.15-arm64.config}"

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ -z "$LOCAL_DEB" ]]; then
  echo "==> 下载 $PKG ($VER)"
  size=$(curl -fsIL --retry 3 "$DEB_URL" | awk 'tolower($1)=="content-length:" {print $2}' | tr -d '\r' | tail -n1)
  if [[ -n "${size:-}" ]]; then
    echo "    体积: $((size / 1048576)) MB"
    if (( size > 100 * 1048576 )); then
      echo "::warning::超过 100 MB，确认流量再继续"
    fi
  fi
  curl -fL --retry 3 -C - -o "$TMP/image.deb" "$DEB_URL"
  LOCAL_DEB="$TMP/image.deb"
else
  echo "==> 使用本地 deb: $LOCAL_DEB"
fi

echo "==> 解包并抽取 /boot/config-*"
dpkg-deb -x "$LOCAL_DEB" "$TMP/root"
cfg=$(ls "$TMP"/root/boot/config-* 2>/dev/null | head -n1 || true)
[[ -n "$cfg" ]] || { echo "::error::这个 deb 里没有 /boot/config-*"; exit 1; }

mkdir -p "$(dirname "$OUT")"
cp "$cfg" "$OUT"
grep -q '^CONFIG_ARM64=y' "$OUT" || { echo "::error::抽出来的不是 arm64 config"; exit 1; }

# sha256 文件里的路径必须相对仓库根，CI 里才能直接 sha256sum -c；
# 用 realpath 归一，避免传绝对路径时把 /home/xxx/... 写进 .sha256
OUT_REL="$(realpath --relative-to=. "$OUT")"
sha256sum "$OUT_REL" > "$OUT.sha256"

echo "==> 写入 $OUT"
echo "    $(wc -l < "$OUT") 行 / $(grep -c '^CONFIG_' "$OUT") 个 CONFIG 项"
echo "    $(cat "$OUT.sha256")"
echo
echo "提交前自查：基线里若有 MODULE_SIG_ALL=y，prepare-config.sh 会把它关掉；"
echo "arm64 上 16K/64K pages 的项会被 CONFIG_ARM64_4K_PAGES 覆盖。"
