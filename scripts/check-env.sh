#!/bin/bash
# ───────────────────────────────────────────────────
# Minecraft Assistant — Environment Check
# 用法: check-env.sh [instance_path]
#
# 检测内容:
#   - OS / 架构
#   - CFR 是否安装
#   - Node.js 是否可用
#   - 基础工具 (grep/find/unzip/strings/shasum)
#   - 启动器类型 & 所有实例
#   - 每个实例的 Java（从启动器配置读取，不是系统PATH）
#   - 磁盘空间
#
# 输出: JSON report
# 退出码: 0=就绪, 1=缺少关键依赖, 2=可降级运行
# ───────────────────────────────────────────────────

set -euo pipefail

INSTANCE_PATH="${1:-}"
SKILL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
KNOWLEDGE_ROOT="$SKILL_DIR/knowledge"

# ─── 工具函数：JSON 字符串转义 ───
json_escape() {
  # 读取 stdin，转义双引号和反斜杠，移除换行符
  sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\n'
}

# ═══════════════════════════════════════════
# 检测函数
# ═══════════════════════════════════════════

detect_os() {
  local os_name=$(uname -s)
  local os_arch=$(uname -m)
  local os_version="unknown"

  case "$os_name" in
    Darwin)
      os_version=$(sw_vers -productVersion 2>/dev/null || echo "unknown")
      ;;
    Linux)
      if [ -f /etc/os-release ]; then
        os_version=$(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
      fi
      ;;
    MINGW*|MSYS*|CYGWIN*)
      os_name="Windows"
      os_version=$(uname -r)
      ;;
  esac
  printf '{"os":"%s","arch":"%s","version":"%s"}' "$os_name" "$os_arch" "$os_version"
}

detect_cfr() {
  local jar=""
  local ver="unknown"
  local ok=false

  for candidate in \
    /opt/homebrew/Cellar/cfr-decompiler/*/libexec/cfr-*.jar \
    /usr/local/Cellar/cfr-decompiler/*/libexec/cfr-*.jar; do
    for j in $candidate; do
      [ -f "$j" ] && { jar="$j"; ver=$(echo "$j" | grep -oE '[0-9]+\.[0-9]+' | head -1); ok=true; break 2; }
    done
  done

  if ! $ok && command -v cfr-decompiler &>/dev/null; then
    jar="$(command -v cfr-decompiler)"
    ver=$(cfr-decompiler --version 2>&1 | head -1 || echo "unknown")
    ok=true
  fi

  printf '{"jar":"%s","version":"%s","ok":%s}' "$jar" "$ver" "$ok"
}

detect_node() {
  local bin=""; local ver=""; local ok=false
  if command -v node &>/dev/null; then
    bin=$(command -v node)
    ver=$(node --version 2>/dev/null || echo "unknown")
    ok=true
  fi
  printf '{"path":"%s","version":"%s","ok":%s}' "$bin" "$ver" "$ok"
}

detect_tools() {
  local g=false; local f=false; local u=false; local s=false; local h=false
  command -v grep   &>/dev/null && g=true
  command -v find   &>/dev/null && f=true
  command -v unzip  &>/dev/null && u=true
  command -v strings &>/dev/null && s=true
  command -v shasum &>/dev/null && h=true
  printf '{"grep":%s,"find":%s,"unzip":%s,"strings":%s,"shasum":%s}' "$g" "$f" "$u" "$s" "$h"
}

detect_disk() {
  local avail=0
  local target="${KNOWLEDGE_ROOT:-$HOME}"
  if command -v df &>/dev/null; then
    if [[ "$(uname -s)" == "Darwin" ]]; then
      avail=$(df -m "$target" 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    else
      avail=$(df -m --output=avail "$target" 2>/dev/null | tail -1 | tr -d ' ' || echo "0")
    fi
  fi
  local ok=false
  [ "${avail:-0}" -gt 2048 ] 2>/dev/null && ok=true
  printf '{"available_mb":%s,"sufficient":%s}' "${avail:-0}" "$ok"
}

# ═══════════════════════════════════════════
# 启动器 & 实例发现（核心）
# ═══════════════════════════════════════════

detect_launcher_and_instances() {
  # 返回完整的 JSON：{ launcher, instances_dir, instances: [...] }
  # 每个 instance 包含从启动器配置读取的 Java 信息

  local launcher="none"
  local instances_dir=""

  # 按优先级查找启动器
  for candidate in \
    "$HOME/Library/Application Support/PrismLauncher/instances:PrismLauncher" \
    "$HOME/Library/Application Support/MultiMC/instances:MultiMC" \
    "$HOME/Library/Application Support/ATLauncher/instances:ATLauncher" \
    "$HOME/.local/share/PrismLauncher/instances:PrismLauncher" \
    "$HOME/.local/share/MultiMC/instances:MultiMC"; do
    dir="${candidate%%:*}"
    name="${candidate##*:}"
    if [ -d "$dir" ]; then
      launcher="$name"
      instances_dir="$dir"
      break
    fi
  done

  # 构建实例列表
  local instance_entries=""
  local dirs_to_scan=()

  # 启动器管理的实例
  if [ -n "$instances_dir" ] && [ -d "$instances_dir" ]; then
    for d in "$instances_dir"/*/; do
      [ -d "$d" ] && dirs_to_scan+=("${d%/}")  # remove trailing /
    done
  fi

  # 用户指定路径
  if [ -n "$INSTANCE_PATH" ]; then
    dirs_to_scan+=("$INSTANCE_PATH")
  fi

  # 独立 .minecraft
  for d in "$HOME/.minecraft" "$HOME/minecraft"; do
    if [ -d "$d" ] && [ -d "$d/mods" ]; then
      dirs_to_scan+=("$d")
    fi
  done

  for d in "${dirs_to_scan[@]}"; do
    [ -z "$d" ] && continue

    # 确定 minecraft 子目录
    local mc_dir="$d"
    [ -d "$d/.minecraft" ] && mc_dir="$d/.minecraft"
    [ -d "$d/minecraft" ]  && mc_dir="$d/minecraft"

    # 必须有 mods 目录才视为有效实例
    [ ! -d "$mc_dir/mods" ] && continue

    local inst_name=$(basename "$d")
    local mod_count=$(ls "$mc_dir/mods"/*.jar 2>/dev/null | wc -l | tr -d ' ')
    local config_count=0
    [ -d "$mc_dir/config" ] && config_count=$(find "$mc_dir/config" -type f 2>/dev/null | wc -l | tr -d ' ')

    [ "$mod_count" -eq 0 ] && continue

    # ─── 从启动器配置读取 Java 信息 ───
    local java_info
    java_info=$(detect_instance_java "$d" "$launcher")

    # ─── 读取 MC 版本/Forge 版本 ───
    local mc_version="unknown"
    local forge_version="unknown"
    if [ -f "$d/mmc-pack.json" ]; then
      mc_version=$(python3 -c "
import json,sys
try:
    d=json.load(open('$d/mmc-pack.json'))
    for c in d.get('components',[]):
        if c.get('uid')=='net.minecraft': print(c.get('version','')); break
except: pass
" 2>/dev/null || echo "unknown")
      forge_version=$(python3 -c "
import json,sys
try:
    d=json.load(open('$d/mmc-pack.json'))
    for c in d.get('components',[]):
        if c.get('uid')=='net.minecraftforge': print(c.get('version','')); break
except: pass
" 2>/dev/null || echo "unknown")
    fi

    # ─── 组装实例条目 ───
    local entry
    entry=$(printf '{"name":"%s","path":"%s","launcher":"%s","mods":%s,"configs":%s,"mc_version":"%s","forge_version":"%s","java":%s}' \
      "$inst_name" "$mc_dir" "$launcher" "$mod_count" "$config_count" "$mc_version" "$forge_version" "$java_info")

    if [ -z "$instance_entries" ]; then
      instance_entries="$entry"
    else
      instance_entries="$instance_entries,$entry"
    fi
  done

  printf '{"launcher":"%s","instances_dir":"%s","instances":[%s]}' \
    "$launcher" "$instances_dir" "$instance_entries"
}

# ═══════════════════════════════════════════
# 核心：从启动器配置读取该实例的 Java
# ═══════════════════════════════════════════

detect_instance_java() {
  local inst_dir="$1"
  local launcher="$2"
  local java_path=""
  local java_version="unknown"
  local java_major=0
  local java_ok=false

  # ─── PrismLauncher / MultiMC ───
  if [ "$launcher" = "PrismLauncher" ] || [ "$launcher" = "MultiMC" ]; then
    local cfg="$inst_dir/instance.cfg"
    if [ -f "$cfg" ]; then
      # 读取 JavaPath（支持 = 两边有空格和无空格）
      java_path=$(grep -E '^JavaPath=' "$cfg" 2>/dev/null | sed 's/^JavaPath=//' | xargs || echo "")
      # 如果为空，可能是旧格式 "JavaPath = /path"
      [ -z "$java_path" ] && java_path=$(grep -E '^\s*JavaPath\s*=' "$cfg" 2>/dev/null | sed 's/.*=\s*//' | xargs || echo "")
    fi
  fi

  # ─── 官方启动器 ───
  if [ "$launcher" = "Vanilla" ] || [ -z "$java_path" ]; then
    # 官方启动器使用 launcher_settings.json 中的全局 Java
    local vanilla_settings="$HOME/Library/Application Support/minecraft/launcher_settings.json"
    if [ -f "$vanilla_settings" ]; then
      java_path=$(python3 -c "
import json,sys
try:
    d=json.load(open('$vanilla_settings'))
    print(d.get('javaPath',''))
except: pass
" 2>/dev/null || echo "")
    fi
  fi

  # ─── 如果仍未找到，尝试全局 JAVA_HOME ───
  if [ -z "$java_path" ]; then
    if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
      java_path="$JAVA_HOME/bin/java"
    elif command -v java &>/dev/null; then
      java_path=$(command -v java)
    fi
  fi

  # ─── 验证 Java 并获取版本 ───
  if [ -n "$java_path" ] && [ -x "$java_path" ]; then
    java_version=$("$java_path" -version 2>&1 | head -1 | tr -d '\n' | json_escape)
    java_major=$(echo "$java_version" | grep -oE '\\"([0-9]+)' | tr -d '\\"' || echo "0")
    [ "${java_major:-0}" -ge 17 ] 2>/dev/null && java_ok=true
  fi

  printf '{"path":"%s","version":"%s","major":%s,"ok":%s}' \
    "$(echo "$java_path" | json_escape)" "$java_version" "${java_major:-0}" "$java_ok"
}

# ═══════════════════════════════════════════
# 主逻辑
# ═══════════════════════════════════════════

echo "=== Minecraft Assistant — Environment Check ==="
echo ""

OS_INFO=$(detect_os)
echo "OS:     $(echo "$OS_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['os']} {d['version']} ({d['arch']})\")" 2>/dev/null || echo "$OS_INFO")"

CFR_INFO=$(detect_cfr)
echo "CFR:    $(echo "$CFR_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{'✓ v'+d['version'] if d['ok'] else '✗ NOT FOUND'}\")" 2>/dev/null || echo "$CFR_INFO")"

NODE_INFO=$(detect_node)
echo "Node:   $(echo "$NODE_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{'✓ '+d['version'] if d['ok'] else '✗ (will skip index build)'}\")" 2>/dev/null || echo "$NODE_INFO")"

TOOLS_INFO=$(detect_tools)
echo "Tools:  $(echo "$TOOLS_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print('✓ all present' if all(d.values()) else '✗ some missing')" 2>/dev/null || echo "$TOOLS_INFO")"

echo ""
echo "=== Minecraft Instances ==="
INSTANCES_INFO=$(detect_launcher_and_instances)

echo "$INSTANCES_INFO" | python3 -c "
import sys,json
d=json.load(sys.stdin)
print(f\"Launcher: {d['launcher']}\")
print()
for i, inst in enumerate(d['instances'], 1):
    java = inst['java']
    jok = '✓' if java['ok'] else '✗ <17'
    print(f\"  [{i}] {inst['name']}\")
    print(f\"      MC {inst['mc_version']} / Forge {inst['forge_version']} / {inst['mods']} mods\")
    print(f\"      Java: {java['major']} ({jok}) — {java['path']}\")
    print(f\"      Path: {inst['path']}\")
    print()
if not d['instances']:
    print('  (no instances found)')
" 2>/dev/null || echo "$INSTANCES_INFO"

DISK_INFO=$(detect_disk)
echo "Disk: $(echo "$DISK_INFO" | python3 -c "import sys,json; d=json.load(sys.stdin); print(f\"{d['available_mb']}MB — {'✓' if d['sufficient'] else '✗ <2GB'}\")" 2>/dev/null || echo "$DISK_INFO")"

# ═══════════════════════════════════════════
# 汇总最终 JSON 报告
# ═══════════════════════════════════════════
echo ""
echo "=== FINAL REPORT ==="

REPORT_DIR=$(mktemp -d)
echo "$OS_INFO"        > "$REPORT_DIR/os.json"
echo "$CFR_INFO"       > "$REPORT_DIR/cfr.json"
echo "$NODE_INFO"      > "$REPORT_DIR/node.json"
echo "$TOOLS_INFO"     > "$REPORT_DIR/tools.json"
echo "$INSTANCES_INFO" > "$REPORT_DIR/instances.json"
echo "$DISK_INFO"      > "$REPORT_DIR/disk.json"

python3 -c "
import json, sys, os

rd = '$REPORT_DIR'
report = {}
for key in ['os','cfr','node','tools','instances','disk']:
    with open(f'{rd}/{key}.json') as f:
        report[key] = json.load(f)

issues = []
if not report['cfr']['ok']:
    issues.append('CFR decompiler not found (install: brew install cfr-decompiler)')
for tool in ['grep','find','unzip','strings']:
    if not report['tools'].get(tool, False):
        issues.append(f'{tool} not found')

# 检查每个实例的 Java
java_issues = 0
for inst in report['instances'].get('instances', []):
    if not inst['java']['ok']:
        java_issues += 1
if java_issues > 0:
    issues.append(f'{java_issues} instance(s) have Java < 17 (check launcher JavaPath setting)')

warnings = []
if not report['node']['ok']:
    warnings.append('Node.js not found — index build skipped, decompilation + lang parsing still work')
if not report['instances'].get('instances'):
    warnings.append('No Minecraft instances with mods detected')
if not report['disk']['sufficient']:
    warnings.append('Low disk space — decompilation needs ~2GB')

report['issues'] = issues
report['warnings'] = warnings
report['ready'] = len(issues) == 0

print(json.dumps(report, indent=2, ensure_ascii=False))
print()

if issues:
    for w in warnings:
        print(f'\033[33m⚠  {w}\033[0m')
    print(f'\033[31m❌ {len(issues)} issue(s) block the build:\033[0m')
    for i in issues:
        print(f'   - {i}')
    print()
    print('Fix: Set JavaPath in instance.cfg to a Java 17+ JDK, then install missing tools.')
    sys.exit(1)

if warnings:
    for w in warnings:
        print(f'\033[33m⚠  {w}\033[0m')

if report['instances'].get('instances'):
    print(f'\033[32m✅ {len(report[\"instances\"][\"instances\"])} instance(s) ready for knowledge base build.\033[0m')
else:
    print('\033[33m⚠  No instances found. Provide path: check-env.sh /path/to/.minecraft\033[0m')
sys.exit(0)
"

EXIT_CODE=$?
rm -rf "$REPORT_DIR"
exit $EXIT_CODE
