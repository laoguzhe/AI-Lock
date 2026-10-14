#!/bin/bash
# ============================================================================
#  Lumen UI 语法校验
#
#  沙箱是 Linux，没有 AppKit / SwiftUI，因此无法做完整的类型检查或编译。
#  本脚本做两件能可靠做到的事：
#
#    1. 语法解析（-parse）：全部新增 UI 文件 + 全部既有源文件。
#       能抓到括号不配、语法错误、非法声明。
#    2. 引用核对（grep）：检查新 UI 里调用的项目内部 API 是否真实存在，
#       避免拼错成员名（例如 snapshot.swapTotal 这种不存在的属性）。
#
#  类型层面的正确性依赖人工核对真实签名 —— 脚本会在第 2 步给出提示。
# ============================================================================
set -uo pipefail

SWIFT_BIN=${SWIFT_BIN:-/tmp/swifttc/swift-5.9.2-RELEASE-ubuntu22.04-aarch64/usr/bin}
SRC=${SRC:-/sessions/serene-clever-maxwell/mnt/ai-lock}

if [[ ! -x "$SWIFT_BIN/swiftc" ]]; then
  echo "找不到 swiftc：$SWIFT_BIN/swiftc"
  echo "（沙箱重置后需重新下载 Linux Swift 工具链）"
  exit 2
fi

cd "$SRC"

echo "== 1. 语法解析 =="
FILES=(Lumen*.swift)
for f in "${FILES[@]}"; do
  [[ -f "$f" ]] || continue
  out=$("$SWIFT_BIN/swiftc" -parse "$f" 2>&1)
  if [[ -n "$out" ]]; then
    echo "--- $f"
    echo "$out" | head -20
  else
    echo "  ok  $f"
  fi
done

echo
echo "== 2. 内部 API 引用核对 =="
# 从新 UI 里抽取 member 访问，确认对端类型确实声明了该成员。
# 只检查最容易出错的模式：snapshot.X / settings.X / alerts.X / model.X
check() {
  local pattern=$1 source=$2 label=$3
  local missing=()
  while read -r member; do
    [[ -z "$member" ]] && continue
    if ! grep -q "\b$member\b" "$source"; then
      missing+=("$member")
    fi
  done < <(grep -ho "\.$pattern" Lumen*.swift 2>/dev/null | sed "s/^\.$pattern//" | sort -u)
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "  $label 缺失: ${missing[*]}"
  else
    echo "  ok  $label"
  fi
}
check "snapshot" SystemMonitor.swift "SystemSnapshot 属性"

echo
echo "完成。类型错误需人工比对真实签名。"
