#!/bin/bash
# ───────────────────────────────────────────────────
# 解析 Minecraft .lang 文件 → JSONL
# 用法: parse-lang.sh <lang_file> [mod_name]
# ───────────────────────────────────────────────────
set -euo pipefail

LANG_FILE="${1:-}"
MOD_NAME="${2:-unknown}"
LANG_CODE="zh_CN"

if [ -z "$LANG_FILE" ] || [ ! -f "$LANG_FILE" ]; then
  echo "Usage: parse-lang.sh <lang_file> [mod_name]"
  echo "Parses a Minecraft .lang file into JSONL format."
  exit 1
fi

# Try to detect mod name from filename
if [ "$MOD_NAME" = "unknown" ]; then
  MOD_NAME=$(basename "$LANG_FILE" | sed 's/_zh_CN.*//' | sed 's/\.lang$//')
fi

while IFS='=' read -r key value; do
  # Skip empty lines and comments
  [ -z "$key" ] && continue
  [[ "$key" == \#* ]] && continue

  # Extract the S:"..." pattern
  unlocalized=$(echo "$key" | sed -n 's/.*S:"\([^"]*\)".*/\1/p')
  if [ -z "$unlocalized" ]; then
    # Try without the S: prefix
    unlocalized=$(echo "$key" | sed -n 's/.*"\([^"]*\)".*/\1/p')
  fi

  if [ -n "$unlocalized" ] && [ -n "$value" ]; then
    # Escape JSON special chars in value
    escaped_value=$(echo "$value" | sed 's/\\/\\\\/g; s/"/\\"/g')
    echo "{\"unlocalized\":\"$unlocalized\",\"display\":\"$escaped_value\",\"mod\":\"$MOD_NAME\",\"lang\":\"$LANG_CODE\"}"
  fi
done < "$LANG_FILE"
