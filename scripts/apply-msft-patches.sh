#!/usr/bin/env bash
# 从 microsoft/WSL2-Linux-Kernel 的同版本 tag 里，把 Hyper-V 来宾侧需要的改动
# 搬进 kernel.org 的对应版本树。
#
# 关键设计：不是「整目录覆盖」，而是「逐个文件比对，只搬有差异的」。
#
#   1. 上游 6.18 已经自带 arch/arm64/hyperv（hv_core.c / hv_hvc.S / mshyperv.c），
#      与微软树同版本时内容一致 → 自动跳过，不会把上游新代码覆盖成微软树的旧版。
#   2. 微软删掉/改名的路径（arch/arm64/include/asm/hyperv-tlfs.h 已迁到
#      include/hyperv/hvhdk.h）不再硬断言缺文件就退出，只记一行。
#   3. 只有真正必需的（dxgkrnl 本体、Kconfig/Makefile 接线、d3dkmthk.h）缺失才报错。
#   4. 额外扫描一批「已知可能有改动、但本仓库不打算搬」的目录，把差异列出来，
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
  # arm64 与 x86 共用的 Hyper-V 定义（上游 6.18 未必有同名文件）
  include/asm-generic/mshyperv.h
  # arm64：上游已有同名文件，逐文件比对后只会补真正改过的
  arch/arm64/hyperv
  arch/arm64/include/asm/mshyperv.h
  # 故意不搬：arch/arm64/Makefile（微软的链接/编译开关与本仓库无关）、
  #           arch/x86/*（编 arm64 完全不参与，只会污染 delta）
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

echo "    搬入 $((${#changed[@]} + 0)) 个文件，跳过 ${skipped} 个与上游一致的"

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

# 上游 6.18 起 HYPERV 已支持 ARM64；若 tag 里又退回 X86-only，这里要能看见
if awk '/^config HYPERV$/{f=1;next} /^config [A-Z]/{f=0} f&&/depends on/' \
     "$SRC/drivers/hv/Kconfig" | grep -qi 'X86' && \
   ! awk '/^config HYPERV$/{f=1;next} /^config [A-Z]/{f=0} f&&/depends on/' \
     "$SRC/drivers/hv/Kconfig" | grep -qi 'ARM64'; then
  echo "::warning::CONFIG_HYPERV 的 depends 只见 X86、不见 ARM64，arm64 上会被清掉"
fi

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
echo "    arch/arm64/hyperv 文件数: $(find "$SRC/arch/arm64/hyperv" -type f 2>/dev/null | wc -l)"
echo "    delta 行数: $(wc -l < "$DELTA")"
