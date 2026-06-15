#!/bin/bash
# ───────────────────────────────────────────────────
# Minecraft Assistant — Phase 3 精准重建
# ───────────────────────────────────────────────────
# 根据用户查询语境，定向扫描和补充知识库。
# 不进行全量反编译，只处理与关键词相关的 class。
#
# 用法: targeted-rebuild.sh <instance_path> <keyword1> [keyword2] ...
# 示例: targeted-rebuild.sh ".minecraft" "AE2" "output bus" "GT++" "input bus"
# ───────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KNOWLEDGE_DIR="$SCRIPT_DIR/knowledge"
CFR_JAR="/opt/homebrew/Cellar/cfr-decompiler/0.152/libexec/cfr-0.152.jar"
JAVA_BIN="${JAVA_HOME:-/opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home}/bin/java"

INSTANCE_PATH="${1:-}"
shift || true
KEYWORDS=("$@")

if [ -z "$INSTANCE_PATH" ] || [ ${#KEYWORDS[@]} -eq 0 ]; then
  echo "Usage: targeted-rebuild.sh <instance_path> <keyword1> [keyword2] ..."
  echo "Performs surgical rebuild — only processes what matches the keywords."
  exit 1
fi

MODS_DIR="$INSTANCE_PATH/mods"
CONFIG_DIR="$INSTANCE_PATH/config"

if [ ! -d "$MODS_DIR" ]; then
  echo "ERROR: mods directory not found at $MODS_DIR"
  exit 1
fi

# Build grep pattern from keywords
GREP_PATTERN=""
for kw in "${KEYWORDS[@]}"; do
  kw_clean=$(echo "$kw" | tr -d ' ' | tr '[:upper:]' '[:lower:]')
  if [ -n "$GREP_PATTERN" ]; then
    GREP_PATTERN="${GREP_PATTERN}|${kw_clean}"
  else
    GREP_PATTERN="${kw_clean}"
  fi
done

echo "=== Minecraft Assistant — Targeted Rebuild ==="
echo "Instance: $INSTANCE_PATH"
echo "Keywords: ${KEYWORDS[*]}"
echo "Pattern: $GREP_PATTERN"
echo ""

# ─── Step 1: 扫描 jar 中的 class 文件名 ───
echo "=== Step 1: Scanning class names in JARs ==="
MATCHED_CLASSES="$KNOWLEDGE_DIR/tmp/targeted_classes.txt"
> "$MATCHED_CLASSES"

for jar in "$MODS_DIR"/*.jar; do
  jar_name=$(basename "$jar")
  matches=$(unzip -l "$jar" 2>/dev/null | \
    grep "\.class$" | \
    grep -v '\$' | \
    grep -iE "$GREP_PATTERN" | \
    awk -v j="$jar_name" '{print j ":::" $4}' || true)
  if [ -n "$matches" ]; then
    echo "$matches" >> "$MATCHED_CLASSES"
  fi
done

class_count=$(wc -l < "$MATCHED_CLASSES" | tr -d ' ')
echo "Found $class_count matching classes"

# ─── Step 2: 扫描 jar 中的 strings ───
echo "=== Step 2: Scanning strings in JARs ==="
MATCHED_STRINGS="$KNOWLEDGE_DIR/tmp/targeted_strings.txt"
> "$MATCHED_STRINGS"

for jar in "$MODS_DIR"/*.jar; do
  jar_name=$(basename "$jar")
  # Extract strings and grep for keywords
  class_hits=$(unzip -p "$jar" 2>/dev/null | \
    strings 2>/dev/null | \
    grep -iE "$GREP_PATTERN" | \
    head -50 || true)

  if [ -n "$class_hits" ]; then
    echo "### $jar_name ###" >> "$MATCHED_STRINGS"
    echo "$class_hits" >> "$MATCHED_STRINGS"
    echo "" >> "$MATCHED_STRINGS"

    # Also find which class files contain these strings
    for classfile in $(unzip -l "$jar" 2>/dev/null | grep "\.class$" | grep -v '\$' | awk '{print $4}'); do
      if unzip -p "$jar" "$classfile" 2>/dev/null | strings 2>/dev/null | grep -qiE "$GREP_PATTERN"; then
        class_name=$(echo "$classfile" | sed 's/\.class$//' | tr '/' '.')
        echo "$jar_name:::$classfile" >> "$MATCHED_CLASSES"
      fi
    done
  fi
done

# Deduplicate matched classes
sort -u "$MATCHED_CLASSES" -o "$MATCHED_CLASSES"
class_count=$(wc -l < "$MATCHED_CLASSES" | tr -d ' ')
echo "Total unique matching classes (after string scan): $class_count"

# ─── Step 3: 扫描 config 文件 ───
echo "=== Step 3: Scanning config files ==="
MATCHED_CONFIGS="$KNOWLEDGE_DIR/tmp/targeted_configs.txt"
> "$MATCHED_CONFIGS"

if [ -d "$CONFIG_DIR" ]; then
  grep -rl -iE "$GREP_PATTERN" "$CONFIG_DIR" 2>/dev/null >> "$MATCHED_CONFIGS" || true
fi
config_count=$(wc -l < "$MATCHED_CONFIGS" | tr -d ' ')
echo "Found $config_count matching config files"

# ─── Step 4: 定向反编译 ───
echo "=== Step 4: Targeted decompilation ==="
MATCHED_CLASSES="$KNOWLEDGE_DIR/tmp/targeted_classes.txt"
MATCHED_STRINGS="$KNOWLEDGE_DIR/tmp/targeted_strings.txt"
MATCHED_CONFIGS="$KNOWLEDGE_DIR/tmp/targeted_configs.txt"
NEW_CLASSES=0

while IFS=':::' read -r jar_name class_path; do
  [ -z "$jar_name" ] && continue
  mod_name="${jar_name%.jar}"
  class_name=$(echo "$class_path" | sed 's/\.class$//' | tr '/' '.')

  output_dir="$KNOWLEDGE_DIR/sources/$mod_name"
  target_file="$output_dir/$(echo "$class_name" | tr '.' '/').java"

  # Skip if already decompiled
  if [ -f "$target_file" ]; then
    continue
  fi

  mkdir -p "$(dirname "$target_file")"

  if "$JAVA_BIN" -jar "$CFR_JAR" \
    "$MODS_DIR/$jar_name" \
    --outputdir "$output_dir" \
    "$class_name" > /dev/null 2>&1; then
    NEW_CLASSES=$((NEW_CLASSES + 1))
  fi
done < "$MATCHED_CLASSES"

echo "Newly decompiled: $NEW_CLASSES classes"

# ─── Step 5: 增量更新索引 ───
echo "=== Step 5: Incremental index update ==="

if [ -f "$KNOWLEDGE_DIR/index.json" ]; then
  # Backup existing index
  cp "$KNOWLEDGE_DIR/index.json" "$KNOWLEDGE_DIR/index.json.bak"

  # Rebuild index (build-index.js handles merging with existing data)
  if command -v node &>/dev/null; then
    node "$SCRIPT_DIR/scripts/build-index.js" \
      --sources "$KNOWLEDGE_DIR/sources" \
      --lang "$KNOWLEDGE_DIR/lang/zh_CN.jsonl" \
      --config "$CONFIG_DIR" \
      --output "$KNOWLEDGE_DIR/index.json" \
      --mods "$MODS_DIR"
  fi
fi

# ─── Step 6: 更新构建元数据 ───
echo "=== Step 6: Updating metadata ==="
META_FILE="$KNOWLEDGE_DIR/.build-meta.json"

if [ -f "$META_FILE" ]; then
  # Append last_targeted_rebuild info
  TEMP_META="$KNOWLEDGE_DIR/tmp/meta_updated.json"
  python3 -c "
import json
with open('$META_FILE') as f:
    meta = json.load(f)
meta['last_targeted_rebuild'] = {
    'query': '${KEYWORDS[*]}',
    'date': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'classes_added': $NEW_CLASSES,
    'configs_matched': $config_count
}
with open('$TEMP_META', 'w') as f:
    json.dump(meta, f, indent=2)
" 2>/dev/null && mv "$TEMP_META" "$META_FILE" || true
fi

# ─── 清理 ───
rm -rf "$KNOWLEDGE_DIR/tmp"

# ─── Summary ───
echo ""
echo "=== Targeted Rebuild Complete ==="
echo "Keywords:    ${KEYWORDS[*]}"
echo "Classes matched:  $class_count"
echo "Newly decompiled: $NEW_CLASSES"
echo "Configs matched:  $config_count"
echo ""
echo "Knowledge base updated. Retry your query now."
