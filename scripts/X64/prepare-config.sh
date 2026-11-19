#!/usr/bin/env bash
# 用法: prepare-config.sh <内核树> <仓库根> <基线 config 文件>
#
# 基线只有一个：仓库里钉死的 Debian 6.18 系列 amd64 内核 config
# （config/X64/debian-6.18.15-amd64.config，来自 trixie-backports 的
#   linux-image-6.18.15+deb13-amd64_6.18.15-1~bpo13+1_amd64.deb 里的 /boot/config-*）。
# 构建时不再联网抓 config —— Debian testing 现在是 7.3，抓来的 config 与 6.18.58
# 跨了 5 个次版本，olddefconfig 会把 Debian 特意设的 =m 大面积默认化。
#
# 流程：基线 → 强制关掉/打开的几项 → 叠加 config/X64/*.fragment → olddefconfig 收敛
#       → 断言 + 量化报告（丢了多少基线符号、fragment 有哪几项没生效）。
set -Eeuo pipefail

SRC="${1:?usage: SRC REPO BASELINE_CONFIG}"
REPO="${2:?}"
DEBCFG="${3:?}"

[[ -s "$DEBCFG" ]] || { echo "::error::基线配置为空或不存在: $DEBCFG"; exit 1; }
grep -q '^CONFIG_X86_64=y' "$DEBCFG" || { echo "::error::基线不是 x86_64 配置"; exit 1; }

cd "$SRC"
echo "==> 基线: $(basename "$DEBCFG")"
cp "$DEBCFG" .config
baseline_keys=$(grep -oE '^(CONFIG_[A-Za-z0-9_]+)' "$DEBCFG" | sort -u | wc -l)

# vanilla 树里这几项必须清掉，否则 bindeb-pkg 会去找 Debian 的证书而失败。
# MODULE_SIG 相关是整个「构建不签名、拿到本地再签」方案的地基：
#   MODULE_SIG=y      → 保留模块签名机制（否则本地签了也没用）
#   MODULE_SIG_ALL=n  → 构建期**不要**用临时钥把模块签死（签死后无法叠加本地签名）
#   MODULE_SIG_FORCE=n→ 未签模块仍可加载
#   MODULE_COMPRESS 关掉 → .ko 不压缩，本地 sign-file 可直接处理
cat >> .config <<'EOF'
CONFIG_SYSTEM_TRUSTED_KEYS=""
CONFIG_SYSTEM_REVOCATION_KEYS=""
CONFIG_LOCALVERSION=""
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_MODULE_SIG=y
# CONFIG_MODULE_SIG_ALL is not set
# CONFIG_MODULE_SIG_FORCE is not set
# 6.18 的 Kconfig 里**没有**「不压缩」这种 choice 选项（MODULE_COMPRESS_NONE 早被删了）：
# MODULE_COMPRESS 是父 bool，关掉它就是「不压缩」。XZ/GZIP/ZSTD 一并显式关，
# 免得基线里残留的 MODULE_COMPRESS_XZ=y 让 choice 又被选中。
# CONFIG_MODULE_COMPRESS is not set
# CONFIG_MODULE_COMPRESS_GZIP is not set
# CONFIG_MODULE_COMPRESS_XZ is not set
# CONFIG_MODULE_COMPRESS_ZSTD is not set
# CONFIG_DEBUG_INFO is not set
# CONFIG_DEBUG_INFO_BTF is not set
# CONFIG_DEBUG_INFO_SPLIT is not set
CONFIG_MODULES=y
EOF

shopt -s nullglob
for f in "$REPO"/config/X64/*.fragment; do
  echo "==> 叠加 $(basename "$f")"
  cat "$f" >> .config
done

make ARCH=x86_64 olddefconfig

check() {
  local key="$1" want="$2" got
  got=$(grep -m1 "^${key}=" .config || true)
  if [[ "$got" != "$want" ]]; then
    echo "::error::配置断言失败: 期望 ${want}，实际 '${got}'"
    echo "         若 CONFIG_HYPERV 被清掉，说明基线或微软树的 x86 Kconfig 依赖有问题"
    exit 1
  fi
  echo "    OK ${want}"
}

check_unset() {
  local key="$1" want="# ${1} is not set"
  grep -qxF "$want" .config || { echo "::error::配置断言失败: 期望 '${want}'"; exit 1; }
  echo "    OK ${want}"
}

check CONFIG_DXGKRNL 'CONFIG_DXGKRNL=y'
check CONFIG_HYPERV 'CONFIG_HYPERV=y'
check CONFIG_HYPERV_VMBUS 'CONFIG_HYPERV_VMBUS=y'
# x86 上 HYPERV_TIMER 是真实实现（def_bool HYPERV && X86），与 arm64 相反
check CONFIG_HYPERV_TIMER 'CONFIG_HYPERV_TIMER=y'
check CONFIG_MODULES 'CONFIG_MODULES=y'
check CONFIG_ANDROID_BINDER_IPC 'CONFIG_ANDROID_BINDER_IPC=y'
# GPU-PV 在这台机器上走的是 vPCI 直通，MTRR/PAT 决定映射的内存属性，缺一不可
check CONFIG_MTRR 'CONFIG_MTRR=y'
check CONFIG_X86_PAT 'CONFIG_X86_PAT=y'
# 「构建不签名」的地基，三项缺一，本地补签方案就不成立
check CONFIG_MODULE_SIG 'CONFIG_MODULE_SIG=y'
check_unset CONFIG_MODULE_SIG_ALL
check_unset CONFIG_MODULE_SIG_FORCE
check_unset CONFIG_MODULE_COMPRESS
# 子选项 GZIP/XZ/ZSTD 不必断言：父开关为 n 时它们不可见，olddefconfig 会直接删掉整行，
# 连 "# ... is not set" 都不会留下，硬断言只会误报。

echo "==> 报告：基线符号在 6.18.58 里被丢弃/改写的部分"
dropped=$(comm -23 \
  <(grep -oE '^(CONFIG_[A-Za-z0-9_]+)' "$DEBCFG" | sort -u) \
  <(grep -oE '^(CONFIG_[A-Za-z0-9_]+)' .config | sort -u) | grep -v '^CONFIG_LOCALVERSION' || true)
if [[ -z "$dropped" ]]; then
  echo "    无（基线里 ${baseline_keys} 个符号在 6.18.58 全部存在）"
else
  echo "    $(printf '%s\n' "$dropped" | wc -l) 项（基线 ${baseline_keys} 个符号）："
  printf '%s\n' "$dropped" | head -40 | sed 's/^/      /'
  [[ $(printf '%s\n' "$dropped" | wc -l) -gt 40 ]] && echo "      ...（截断）"
fi

echo "==> 报告：未生效的 fragment 项"
uneff=0
for f in "$REPO"/config/X64/*.fragment; do
  while IFS= read -r line; do
    case "$line" in
      '#'*|'') continue ;;
      CONFIG_*=*)
        k=${line%%=*}
        if ! grep -q "^${k}=" .config; then
          # 被写成一行的 "is not set" 也算生效
          grep -qxF "# ${k} is not set" .config || {
            echo "    [丢弃] $k  ($(basename "$f"))"
            uneff=$((uneff + 1))
          }
        fi
        ;;
    esac
  done < "$f"
done
[[ "$uneff" -eq 0 ]] && echo "    无"

echo "==> 完成: $(grep -c '^CONFIG_' .config) 个 CONFIG 项"
