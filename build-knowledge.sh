#!/bin/bash
# ───────────────────────────────────────────────────
# Minecraft Assistant — Phase 0 全量知识库构建
# 每个实例拥有独立的知识库目录。
#
# 用法: build-knowledge.sh <instance_path> [--force]
# 示例: build-knowledge.sh "/Users/.../GTNH2.9.0/.minecraft"
# ───────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KNOWLEDGE_ROOT="$SCRIPT_DIR/knowledge"

INSTANCE_PATH="${1:-}"
FORCE="${2:-}"

if [ -z "$INSTANCE_PATH" ]; then
  echo "Usage: build-knowledge.sh <instance_path> [--force]"
  echo "Run check-env.sh first to discover instances."
  exit 1
fi

INSTANCE_PATH="$(cd "$INSTANCE_PATH" 2>/dev/null && pwd || echo "$INSTANCE_PATH")"
INSTANCE_NAME=$(basename "$(dirname "$INSTANCE_PATH")" 2>/dev/null || echo "unknown")
# Handle the case where the path IS the .minecraft dir
[ "$INSTANCE_NAME" = ".minecraft" ] && INSTANCE_NAME=$(basename "$(dirname "$(dirname "$INSTANCE_PATH")")" 2>/dev/null || echo "unknown")

MODS_DIR="$INSTANCE_PATH/mods"
CONFIG_DIR="$INSTANCE_PATH/config"

if [ ! -d "$MODS_DIR" ]; then
  echo "ERROR: mods directory not found at $MODS_DIR"
  exit 1
fi

# ─── 独立知识库目录 ───
INSTANCE_SLUG=$(echo "$INSTANCE_NAME" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9._-' | cut -c1-40)
KNOWLEDGE_DIR="$KNOWLEDGE_ROOT/$INSTANCE_SLUG"
echo "Instance: $INSTANCE_NAME"
echo "Knowledge: $KNOWLEDGE_DIR"
echo ""

# ─── Phase -1: 环境预检 ───
if [ -x "$SCRIPT_DIR/scripts/check-env.sh" ]; then
  "$SCRIPT_DIR/scripts/check-env.sh" "$INSTANCE_PATH" || {
    echo "❌ Environment check failed. Fix issues and retry."
    exit 1
  }
fi

# ─── 检测 Java ───
# 优先使用实例配置中的 Java（check-env.sh 已输出），这里做 fallback
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA_BIN="$JAVA_HOME/bin/java"
elif command -v java &>/dev/null; then
  JAVA_BIN=$(command -v java)
else
  echo "ERROR: Java not found."
  exit 1
fi

# ─── 检测 CFR ───
CFR_JAR=""
for candidate in \
  /opt/homebrew/Cellar/cfr-decompiler/*/libexec/cfr-*.jar \
  /usr/local/Cellar/cfr-decompiler/*/libexec/cfr-*.jar; do
  for j in $candidate; do [ -f "$j" ] && { CFR_JAR="$j"; break 2; }; done
done
if [ -z "$CFR_JAR" ]; then
  echo "ERROR: CFR decompiler not found. Install: brew install cfr-decompiler"
  exit 1
fi
echo "Java: $JAVA_BIN"
echo "CFR:  $CFR_JAR"
echo ""

# ─── 增量检查 ───
META_FILE="$KNOWLEDGE_DIR/.build-meta.json"
if [ "$FORCE" != "--force" ] && [ -f "$META_FILE" ]; then
  NEWER=$(find "$MODS_DIR" -name "*.jar" -newer "$META_FILE" 2>/dev/null | head -1)
  JAR_COUNT_NOW=$(ls "$MODS_DIR"/*.jar 2>/dev/null | wc -l | tr -d ' ')
  JAR_COUNT_META=$(python3 -c "import json; d=json.load(open('$META_FILE')); print(d.get('jar_count',0))" 2>/dev/null || echo "0")
  if [ -z "$NEWER" ] && [ "$JAR_COUNT_NOW" = "$JAR_COUNT_META" ]; then
    echo "Knowledge base for '$INSTANCE_NAME' is up to date."
    echo "Use --force to rebuild."
    exit 0
  fi
  echo "Changes detected: $JAR_COUNT_META → $JAR_COUNT_NOW jars"
fi

# ─── 初始化目录 ───
mkdir -p "$KNOWLEDGE_DIR/sources"
mkdir -p "$KNOWLEDGE_DIR/lang"
mkdir -p "$KNOWLEDGE_DIR/tmp"

# ═══════════════════════════════════════════
# Step 1: 扫描 recipe-related classes
# ═══════════════════════════════════════════
echo "=== Step 1: Scanning for recipe-related classes ==="
CLASS_LIST="$KNOWLEDGE_DIR/tmp/classes_to_decompile.txt"
> "$CLASS_LIST"

total_jars=0
for jar in "$MODS_DIR"/*.jar; do
  total_jars=$((total_jars + 1))
  jar_name=$(basename "$jar")
  unzip -l "$jar" 2>/dev/null | \
    grep -iE "Recipe|Loader|Registry" | \
    grep "\.class$" | \
    grep -v '\$' | \
    awk -v j="$jar_name" '{print j ":::" $4}' >> "$CLASS_LIST" || true
done
total_classes=$(wc -l < "$CLASS_LIST" | tr -d ' ')
echo "Found $total_classes recipe-related classes across $total_jars jars"

# ═══════════════════════════════════════════
# Step 2: CFR 反编译
# ═══════════════════════════════════════════
echo "=== Step 2: Decompiling with CFR ==="
count=0
while IFS=':::' read -r jar_name class_path; do
  [ -z "$jar_name" ] && continue
  count=$((count + 1))
  mod_name="${jar_name%.jar}"
  class_name=$(echo "$class_path" | sed 's/\.class$//' | tr '/' '.')
  output_dir="$KNOWLEDGE_DIR/sources/$mod_name"
  mkdir -p "$output_dir"

  "$JAVA_BIN" -jar "$CFR_JAR" \
    "$MODS_DIR/$jar_name" \
    --outputdir "$output_dir" \
    "$class_name" > /dev/null 2>&1 || true

  [ $((count % 100)) -eq 0 ] && echo "  [$count/$total_classes] decompiled..."
done < "$CLASS_LIST"
echo "Decompilation complete: $count classes"

# ═══════════════════════════════════════════
# Step 3: 解析 lang 文件
# ═══════════════════════════════════════════
echo "=== Step 3: Parsing language files ==="
LANG_OUT="$KNOWLEDGE_DIR/lang/zh_CN.jsonl"
> "$LANG_OUT"

for langfile in "$INSTANCE_PATH"/*_zh_CN.lang "$INSTANCE_PATH"/resources/*/zh_CN.lang; do
  [ -f "$langfile" ] || continue
  mod_name=$(basename "$langfile" | sed 's/_zh_CN.*//')
  echo "  Parsing $mod_name..."
  while IFS='=' read -r key value; do
    [ -z "$key" ] && continue
    [[ "$key" == \#* ]] && continue
    unlocalized=$(echo "$key" | sed -n 's/.*S:"\([^"]*\)".*/\1/p')
    [ -z "$unlocalized" ] && unlocalized=$(echo "$key" | sed -n 's/.*"\([^"]*\)".*/\1/p')
    [ -z "$unlocalized" ] && continue
    # Escape for JSON
    escaped=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo "{\"unlocalized\":\"$unlocalized\",\"display\":\"$escaped\",\"mod\":\"$mod_name\",\"lang\":\"zh_CN\"}" >> "$LANG_OUT"
  done < "$langfile"
done

lang_entries=$(wc -l < "$LANG_OUT" | tr -d ' ')
echo "Parsed $lang_entries lang entries"

# ═══════════════════════════════════════════
# Step 4: 构建索引
# ═══════════════════════════════════════════
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
  echo "  Install: brew install node"
fi

# ═══════════════════════════════════════════
# Step 5: 写入构建元数据（含Java信息）
# ═══════════════════════════════════════════
echo "=== Step 5: Writing metadata ==="
JAR_COUNT=$(ls "$MODS_DIR"/*.jar 2>/dev/null | wc -l | tr -d ' ')

# 获取 Java 信息
JAVA_VER=$("$JAVA_BIN" -version 2>&1 | head -1 | tr -d '\n')
JAVA_MAJOR=$(echo "$JAVA_VER" | grep -oE '"([0-9]+)' | tr -d '"' || echo "0")

# 计算 jar checksums
echo "  Computing checksums..."
JAR_CHECKSUMS="{}"
if command -v python3 &>/dev/null; then
  JAR_CHECKSUMS=$(python3 -c "
import json, hashlib, os, glob
mods='$MODS_DIR'
checksums = {}
for jar in sorted(glob.glob(os.path.join(mods, '*.jar'))):
    try:
        with open(jar, 'rb') as f:
            h = hashlib.sha256(f.read()).hexdigest()
        checksums[os.path.basename(jar)] = h
    except: pass
print(json.dumps(checksums))
" 2>/dev/null || echo "{}")
fi

RECIPE_COUNT=$(python3 -c "import json; d=json.load(open('$KNOWLEDGE_DIR/index.json')); print(len(d.get('recipes',[])))" 2>/dev/null || echo 0)
ITEM_COUNT=$(python3 -c "import json; d=json.load(open('$KNOWLEDGE_DIR/index.json')); print(len(d.get('items',{})))" 2>/dev/null || echo 0)

python3 -c "
import json
meta = {
    'build_date': '$(date -u +%Y-%m-%dT%H:%M:%SZ)',
    'instance_name': '$INSTANCE_NAME',
    'instance_path': '$INSTANCE_PATH',
    'java': {
        'path': '$JAVA_BIN',
        'version': '$JAVA_VER',
        'major': $JAVA_MAJOR,
    },
    'jar_count': $JAR_COUNT,
    'classes_decompiled': $total_classes,
    'lang_entries': $lang_entries,
    'recipes_extracted': $RECIPE_COUNT,
    'items_indexed': $ITEM_COUNT,
    'jar_checksums': $JAR_CHECKSUMS,
}
with open('$META_FILE', 'w') as f:
    json.dump(meta, f, indent=2, ensure_ascii=False)
" 2>/dev/null || echo "WARNING: Could not write metadata (python3 needed)"

# ─── 清理 ───
rm -rf "$KNOWLEDGE_DIR/tmp"

# ─── 完成 ───
echo ""
echo "=== Build Complete ==="
echo "Instance:   $INSTANCE_NAME"
echo "Knowledge:  $KNOWLEDGE_DIR"
echo "Java:       Java $JAVA_MAJOR"
echo "Decompiled: $count classes"
echo "Lang:       $lang_entries entries"
echo "Index:      $ITEM_COUNT items, $RECIPE_COUNT recipes"
du -sh "$KNOWLEDGE_DIR" 2>/dev/null
echo ""
echo "Ready to answer Minecraft questions!"
