#!/bin/bash
# ───────────────────────────────────────────────────
# CFR 反编译单个 class（便捷包装器）
# 用法: decompile.sh <jar_path> <class_name> [output_dir]
# ───────────────────────────────────────────────────
set -euo pipefail

JAR="${1:-}"
CLASS="${2:-}"
OUTDIR="${3:-/tmp/cfr-output}"

if [ -z "$JAR" ] || [ -z "$CLASS" ]; then
  echo "Usage: decompile.sh <jar_path> <class_name> [output_dir]"
  echo "Example: decompile.sh gregtech.jar gregtech.common.items.ItemIntegratedCircuit ./output"
  exit 1
fi

CFR_JAR="/opt/homebrew/Cellar/cfr-decompiler/0.152/libexec/cfr-0.152.jar"
JAVA_BIN="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}/bin/java"

mkdir -p "$OUTDIR"

exec "$JAVA_BIN" -jar "$CFR_JAR" "$JAR" --outputdir "$OUTDIR" "$CLASS"
