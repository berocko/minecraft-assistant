#!/bin/bash
# ───────────────────────────────────────────────────
# Minecraft Assistant — Phase 0 全量知识库构建
# ───────────────────────────────────────────────────
# 用法: build-knowledge.sh <instance_path> [--force]
# 示例: build-knowledge.sh "/Users/aether/Library/Application Support/PrismLauncher/instances/GTNH2.9.0/.minecraft"
#
# 流程:
#   1. 验证路径，检测 mods/config/lang 目录
#   2. CFR 反编译所有 recipe-related classes（仅一次，除非 --force）
#   3. 解析 .lang 文件 → knowledge/lang/<lang>.jsonl
#   4. 构建 index.json
#   5. 写入 .build-meta.json
# ───────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KNOWLEDGE_DIR="$SCRIPT_DIR/knowledge"
CFR_JAR="/opt/homebrew/Cellar/cfr-decompiler/0.152/libexec/cfr-0.152.jar"
JAVA_BIN="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}/bin/java"

# ─── 参数解析 ───
INSTANCE_PATH="${1:-}"
FORCE="${2:-}"

if [ -z "$INSTANCE_PATH" ]; then
  echo "Usage: build-knowledge.sh <instance_path> [--force]"
  echo ""
  echo "Auto-detecting instances..."
  PRISM_DIR="$HOME/Library/Application Support/PrismLauncher/instances"
  if [ -d "$PRISM_DIR" ]; then
    echo "PrismLauncher instances:"
    for d in "$PRISM_DIR"/*/; do
      if [ -d "${d}.minecraft/mods" ] || [ -d "${d}minecraft/mods" ]; then
        echo "  → $(basename "$d")"
      fi
    done
  fi
  exit 1
fi

# Normalize path
INSTANCE_PATH="$(cd "$INSTANCE_PATH" 2>/dev/null && pwd || echo "$INSTANCE_PATH")"
MODS_DIR="$INSTANCE_PATH/mods"
CONFIG_DIR="$INSTANCE_PATH/config"

if [ ! -d "$MODS_DIR" ]; then
  echo "ERROR: mods directory not found at $MODS_DIR"
  exit 1
fi

echo "=== Minecraft Assistant — Knowledge Build ==="
echo "Instance: $INSTANCE_PATH"
echo "Mods dir: $MODS_DIR"
echo "Config dir: $CONFIG_DIR"
echo ""

# ─── Step 0: 增量检查 ───
META_FILE="$KNOWLEDGE_DIR/.build-meta.json"
if [ "$FORCE" != "--force" ] && [ -f "$META_FILE" ]; then
  NEWER=$(find "$MODS_DIR" -name "*.jar" -newer "$META_FILE" 2>/dev/null | head -1)
  JAR_COUNT_NOW=$(ls "$MODS_DIR"/*.jar 2>/dev/null | wc -l | tr -d ' ')
  JAR_COUNT_META=$(python3 -c "import json; d=json.load(open('$META_FILE')); print(d.get('jar_count',0))" 2>/dev/null || echo "0")

  if [ -z "$NEWER" ] && [ "$JAR_COUNT_NOW" = "$JAR_COUNT_META" ]; then
    echo "Knowledge base is up to date. Use --force to rebuild."
    exit 0
  fi
  echo "Changes detected: rebuilding knowledge base..."
  echo "  Jars: $JAR_COUNT_META → $JAR_COUNT_NOW"
fi

# ─── 初始化目录 ───
mkdir -p "$KNOWLEDGE_DIR/sources"
mkdir -p "$KNOWLEDGE_DIR/lang"
mkdir -p "$KNOWLEDGE_DIR/tmp"

# ─── Step 1: 列出所有待反编译的 class ───
echo "=== Step 1: Scanning for recipe-related classes ==="
CLASS_LIST="$KNOWLEDGE_DIR/tmp/classes_to_decompile.txt"
> "$CLASS_LIST"

total_jars=0
total_classes=0
for jar in "$MODS_DIR"/*.jar; do
  total_jars=$((total_jars + 1))
  jar_name=$(basename "$jar")
  # Find classes with Recipe/Loader/Registry in name (excluding inner classes)
  unzip -l "$jar" 2>/dev/null | \
    grep -iE "Recipe|Loader|Registry" | \
    grep "\.class$" | \
    grep -v '\$' | \
    awk -v j="$jar_name" '{print j ":::" $4}' >> "$CLASS_LIST" || true
done
total_classes=$(wc -l < "$CLASS_LIST" | tr -d ' ')
echo "Found $total_classes recipe-related classes across $total_jars jars"

# ─── Step 2: CFR 反编译 ───
echo "=== Step 2: Decompiling with CFR ==="
DECOMPILE_LOG="$KNOWLEDGE_DIR/tmp/decompile.log"
> "$DECOMPILE_LOG"

count=0
while IFS=':::' read -r jar_name class_path; do
  count=$((count + 1))
  mod_name="${jar_name%.jar}"
  class_name=$(echo "$class_path" | sed 's/\.class$//' | tr '/' '.')

  # Determine output dir
  output_dir="$KNOWLEDGE_DIR/sources/$mod_name"
  mkdir -p "$output_dir"

  # Decompile
  if "$JAVA_BIN" -jar "$CFR_JAR" \
    "$MODS_DIR/$jar_name" \
    --outputdir "$output_dir" \
    "$class_name" >> "$DECOMPILE_LOG" 2>&1; then
    : # success
  fi

  # Progress every 100 classes
  if [ $((count % 100)) -eq 0 ]; then
    echo "  [$count/$total_classes] decompiled..."
  fi
done < "$CLASS_LIST"

echo "Decompilation complete: $count classes processed"

# ─── Step 3: 解析 lang 文件 ───
echo "=== Step 3: Parsing language files ==="
LANG_OUT="$KNOWLEDGE_DIR/lang/zh_CN.jsonl"
> "$LANG_OUT"

# Primary language file (check instance root + mods)
LANG_PATTERNS=(
  "$INSTANCE_PATH/GregTech_zh_CN.lang"
  "$INSTANCE_PATH/*_zh_CN.lang"
  "$INSTANCE_PATH/resources/*/zh_CN.lang"
)

for pattern in "${LANG_PATTERNS[@]}"; do
  for langfile in $pattern; do
    if [ -f "$langfile" ]; then
      mod_name="unknown"
      # Try to infer mod name from filename
      case "$(basename "$langfile")" in
        GregTech_zh_CN.lang) mod_name="gregtech" ;;
        *) mod_name=$(basename "$langfile" | sed 's/_zh_CN.*//') ;;
      esac

      # Convert .lang format to JSONL
      # Format: S:"unlocalizedName"=display text
      while IFS='=' read -r key value; do
        # Extract the S:"..." part
        unlocalized=$(echo "$key" | sed -n 's/.*S:"\([^"]*\)".*/\1/p')
        if [ -n "$unlocalized" ] && [ -n "$value" ]; then
          echo "{\"unlocalized\":\"$unlocalized\",\"display\":\"$value\",\"mod\":\"$mod_name\",\"lang\":\"zh_CN\"}" >> "$LANG_OUT"
        fi
      done < "$langfile"
    fi
  done
done

lang_entries=$(wc -l < "$LANG_OUT" | tr -d ' ')
echo "Parsed $lang_entries language entries"

# ─── Step 4: 构建索引（委托给 Node.js） ───
echo "=== Step 4: Building index ==="
if command -v node &>/dev/null; then
  node "$SCRIPT_DIR/scripts/build-index.js" \
    --sources "$KNOWLEDGE_DIR/sources" \
    --lang "$LANG_OUT" \
    --config "$CONFIG_DIR" \
    --output "$KNOWLEDGE_DIR/index.json" \
    --mods "$MODS_DIR"
  echo "Index built: $KNOWLEDGE_DIR/index.json"
else
  echo "WARNING: Node.js not found. Skipping index generation."
  echo "Index must be built manually with: node scripts/build-index.js ..."
fi

# ─── Step 5: 写入元数据 ───
echo "=== Step 5: Writing build metadata ==="
JAR_COUNT=$(ls "$MODS_DIR"/*.jar 2>/dev/null | wc -l | tr -d ' ')

# Compute jar checksums
declare -A jar_checksums
for jar in "$MODS_DIR"/*.jar; do
  jar_name=$(basename "$jar")
  jar_checksums["$jar_name"]=$(shasum -a 256 "$jar" 2>/dev/null | awk '{print $1}' || echo "unknown")
done

# Build JSON
{
  echo "{"
  echo "  \"build_date\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
  echo "  \"instance_path\": \"$INSTANCE_PATH\","
  echo "  \"jar_count\": $JAR_COUNT,"
  echo "  \"classes_decompiled\": $total_classes,"
  echo "  \"recipes_extracted\": $(python3 -c "import json; d=json.load(open('$KNOWLEDGE_DIR/index.json')); print(len(d.get('recipes',[])))" 2>/dev/null || echo 0),"
  echo "  \"items_indexed\": $(python3 -c "import json; d=json.load(open('$KNOWLEDGE_DIR/index.json')); print(len(d.get('items',{})))" 2>/dev/null || echo 0),"
  echo "  \"jar_checksums\": {"
  first=true
  for jar_name in "${!jar_checksums[@]}"; do
    [ "$first" = true ] || echo -n ","
    first=false
    echo -n "\"$jar_name\": \"${jar_checksums[$jar_name]}\""
  done
  echo ""
  echo "  }"
  echo "}"
} > "$META_FILE"

# ─── 清理临时文件 ───
rm -rf "$KNOWLEDGE_DIR/tmp"

# ─── 完成 ───
echo ""
echo "=== Build Complete ==="
du -sh "$KNOWLEDGE_DIR"
echo "Index: $(du -sh "$KNOWLEDGE_DIR/index.json" 2>/dev/null | awk '{print $1}')"
echo "Sources: $(du -sh "$KNOWLEDGE_DIR/sources" 2>/dev/null | awk '{print $1}')"
echo "Lang: $(du -sh "$KNOWLEDGE_DIR/lang" 2>/dev/null | awk '{print $1}')"
echo ""
echo "Ready to answer Minecraft questions!"
