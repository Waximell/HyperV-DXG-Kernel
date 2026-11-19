#!/usr/bin/env bash
# 从 microsoft/WSL2-Linux-Kernel 的同版本 tag 里，把 Hyper-V 来宾侧需要的改动
# 搬进 kernel.org 的对应版本树（x86_64）。
#
# 关键设计：不是「整目录覆盖」，而是「逐个文件比对，只搬有差异的」。
#
#   1. x86 侧的架构层上游本来就完整（arch/x86/hyperv、arch/x86/include/asm/mshyperv.h
#      与微软树逐字节相同），所以白名单里根本没有架构补丁，只有驱动与两个改过的文件。
#   2. 只有真正必需的（dxgkrnl 本体、Kconfig/Makefile 接线、d3dkmthk.h）缺失才报错。
#   3. 额外扫描一批「已知可能有改动、但本仓库不打算搬」的路径，把差异列出来，
#      以后漏东西不用等编译报错才发现。
#
# 用法: apply-msft-patches.sh <标准内核树> <WSL树> <delta输出路径>
set -Eeuo pipefail

SRC="${1:?usage: apply-msft-patches.sh SRC MSFT DELTA}"
MSFT="${2:?}"
DELTA="${3:?}"

[[ -d "$SRC" ]] || { echo "::error::标准内核树不存在: $SRC"; exit 1; }
[[ -d "$MSFT" ]] || { echo "::error::WSL 树不存在: $MSFT"; exit 1; }

# ---- 会真正搬入的路径（宽集，靠逐文件比对决定搬不搬）----------------------
COPY_PATHS=(
  # dxgkrnl 本体 + Kconfig/Makefile 接线 + DXGK GUID + hv-rescind-race 修复
  drivers/hv
  include/linux/hyperv.h
  include/uapi/misc
  # x86 侧另有两个文件被微软改过：早期初始化与 Hyper-V 定时器。
  # 后者在 x86 上本来就是完整实现，但微软版本带了后续修正，逐文件比对后按需搬入。
  arch/x86/kernel/cpu/mshyperv.c
  drivers/clocksource/hyperv_timer.c
  # 故意不搬：arch/x86/hyperv（与上游逐字节相同）、arch/arm64/*（编 x86 不参与）
)

# 允许用环境变量追加（对应 workflow 的 extra_msft_paths 输入）
if [[ -n "${EXTRA_MSFT_PATHS:-}" ]]; then
  IFS=',' read -ra extra <<< "$EXTRA_MSFT_PATHS"
  for e in "${extra[@]}"; do
    [[ -n "$e" ]] && COPY_PATHS+=("$e")
  done
fi

# ---- 必须存在的路径（缺了直接失败，别浪费一小时编译）----------------------
REQUIRED=(
  drivers/hv/dxgkrnl
  drivers/hv/Kconfig
  drivers/hv/Makefile
  include/uapi/misc/d3dkmthk.h
)

# ---- 只报告、不搬的目录：这里出现差异说明我们可能漏了东西 -----------------
PROBE_ONLY=(
  include/hyperv
  drivers/gpu/drm/hyperv
  tools/hv
  arch/x86/hyperv
  arch/x86/include/asm/mshyperv.h
  arch/x86/include/asm/hyperv-tlfs.h
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/a" "$WORK/b"

changed=()
skipped=0

record_change() {
  local rel="$1" dst="$SRC/$1"
  mkdir -p "$WORK/a/$(dirname "$rel")" "$WORK/b/$(dirname "$rel")"
  if [[ -f "$dst" ]]; then
    cp -a "$dst" "$WORK/a/$rel"
  else
    : > "$WORK/a/$rel"
  fi
  mkdir -p "$(dirname "$dst")"
  cp -a "$MSFT/$rel" "$dst"
  cp -a "$dst" "$WORK/b/$rel"
  changed+=("$rel")
}

copy_one() {
  local rel="$1" dst="$SRC/$1"
  if [[ -f "$dst" ]] && cmp -s "$MSFT/$rel" "$dst"; then
    skipped=$((skipped + 1))
    return 0
  fi
  record_change "$rel"
}

echo "==> 必选路径检查"
for p in "${REQUIRED[@]}"; do
  if [[ ! -e "$MSFT/$p" ]]; then
    echo "::error::WSL 树里找不到必需路径 $p（tag 是否选错？）" >&2
    exit 1
  fi
  echo "    OK $p"
done

echo "==> 逐文件比对并搬运"
for p in "${COPY_PATHS[@]}"; do
  if [[ -d "$MSFT/$p" ]]; then
    while IFS= read -r -d '' f; do
      copy_one "${f#"$MSFT"/}"
    done < <(find "$MSFT/$p" -type f -print0)
  elif [[ -f "$MSFT/$p" ]]; then
    copy_one "$p"
  else
    echo "    [缺失] $p（上游可能已经自带，忽略）"
  fi
done

echo "    搬入 ${#changed[@]} 个文件，跳过 ${skipped} 个与上游一致的"

if ((${#changed[@]})); then
  for rel in "${changed[@]}"; do
    plus=$(diff -u "$WORK/a/$rel" "$WORK/b/$rel" 2>/dev/null | grep -c '^+' || true)
    minus=$(diff -u "$WORK/a/$rel" "$WORK/b/$rel" 2>/dev/null | grep -c '^-' || true)
    printf '    %-62s +%-5s -%s\n' "$rel" "$((plus > 0 ? plus - 1 : 0))" "$((minus > 0 ? minus - 1 : 0))"
  done
fi

echo "==> 硬断言：补丁没打对就当场失败"
[[ -f "$SRC/drivers/hv/dxgkrnl/Kconfig" ]] || { echo "::error::缺 dxgkrnl/Kconfig"; exit 1; }
grep -q '^config DXGKRNL' "$SRC/drivers/hv/dxgkrnl/Kconfig" || { echo "::error::Kconfig 无 DXGKRNL"; exit 1; }
grep -q 'DXGKRNL' "$SRC/drivers/hv/Makefile" || { echo "::error::drivers/hv/Makefile 未接线 dxgkrnl"; exit 1; }
grep -q 'dxgkrnl' "$SRC/drivers/hv/Kconfig" || { echo "::error::drivers/hv/Kconfig 未 source dxgkrnl/Kconfig"; exit 1; }
[[ -f "$SRC/include/uapi/misc/d3dkmthk.h" ]] || { echo "::error::缺 d3dkmthk.h"; exit 1; }
grep -q 'dxgsyncfile' "$SRC/drivers/hv/dxgkrnl/Makefile" || echo "::warning::dxgkrnl/Makefile 里未见 dxgsyncfile.o"

# x86 侧被微软改过的两个文件必须真的换成了微软版本（否则是「安静地少搬」）
grep -q 'hyperv_early_init' "$SRC/arch/x86/kernel/cpu/mshyperv.c" || {
  echo "::error::arch/x86/kernel/cpu/mshyperv.c 里没有 hyperv_early_init（可能仍是上游版本）"; exit 1; }

echo "==> 未纳入白名单的差异（仅提示，需人工判断）"
uncovered=0
for p in "${PROBE_ONLY[@]}"; do
  [[ -e "$MSFT/$p" ]] || continue
  if [[ -d "$MSFT/$p" ]]; then
    while IFS= read -r -d '' f; do
      rel="${f#"$MSFT"/}"
      if [[ ! -f "$SRC/$rel" ]] || ! cmp -s "$f" "$SRC/$rel"; then
        echo "    [未纳入] $rel"
        uncovered=$((uncovered + 1))
      fi
    done < <(find "$MSFT/$p" -type f -print0)
  elif [[ ! -f "$SRC/$p" ]] || ! cmp -s "$MSFT/$p" "$SRC/$p"; then
    echo "    [未纳入] $p"
    uncovered=$((uncovered + 1))
  fi
done
echo "    共 ${uncovered} 处"

echo "==> 生成 delta patch（审查用，patch -p1 可回放）"
( cd "$WORK" && diff -ruN a b ) > "$DELTA" || true

echo "==> 完成"
echo "    dxgkrnl 文件数: $(find "$SRC/drivers/hv/dxgkrnl" -type f | wc -l)"
echo "    delta 行数: $(wc -l < "$DELTA")"
