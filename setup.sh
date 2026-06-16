#!/bin/bash
# ───────────────────────────────────────────────────
# Minecraft Assistant — 一键环境安装
# 自动检测并安装所有缺失的依赖。
#
# 用法: setup.sh [-y]
#   -y  非交互模式（skill 自动调用时使用）
# ───────────────────────────────────────────────────

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RED='\033[31m'; GREEN='\033[32m'; YELLOW='\033[33m'; BOLD='\033[1m'; NC='\033[0m'

echo "╔══════════════════════════════════════════╗"
echo "║  Minecraft Assistant — Setup            ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── 检测 OS & 包管理器 ───
OS=$(uname -s)
ARCH=$(uname -m)
PKG_MANAGER=""
INSTALL_CMD=""

case "$OS" in
  Darwin)
    PKG_MANAGER="Homebrew"
    if command -v brew &>/dev/null; then
      INSTALL_CMD="brew install"
    fi
    ;;
  Linux)
    if command -v apt-get &>/dev/null; then
      PKG_MANAGER="apt"
      INSTALL_CMD="sudo apt-get install -y"
    elif command -v dnf &>/dev/null; then
      PKG_MANAGER="dnf"
      INSTALL_CMD="sudo dnf install -y"
    elif command -v pacman &>/dev/null; then
      PKG_MANAGER="pacman"
      INSTALL_CMD="sudo pacman -S --noconfirm"
    fi
    ;;
  *)
    echo "⚠  Unsupported OS: $OS"
    echo "   You'll need to install dependencies manually."
    ;;
esac

echo "OS:      $OS ($ARCH)"
echo "PKG:     ${PKG_MANAGER:-not detected}"
echo ""

if [ -z "$INSTALL_CMD" ] && [ "$PKG_MANAGER" != "Homebrew" ]; then
  # On macOS, Homebrew can be installed
  if [ "$OS" = "Darwin" ]; then
    if $AUTO_YES; then
      echo "Homebrew not found. Auto-installing..."
      /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || true
      if [ -f /opt/homebrew/bin/brew ]; then
        eval "$(/opt/homebrew/bin/brew shellenv)"
        INSTALL_CMD="brew install"
      fi
    else
      echo "Homebrew not found. Install it first:"
      echo "  /bin/bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
      echo ""
      read -rp "Install Homebrew now? [y/N] " ans
      if [[ "$ans" =~ ^[Yy] ]]; then
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [ -f /opt/homebrew/bin/brew ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
          INSTALL_CMD="brew install"
        fi
      else
        echo "Cannot auto-install without a package manager. Exiting."
        exit 1
      fi
    fi
  fi
fi

# ─── 检测 & 安装依赖 ───
NEED_INSTALL=()
INSTALLED=()

check_and_install() {
  local name="$1"
  local pkg="$2"
  local check_cmd="$3"
  local install_hint="$4"

  echo -n "  $name ... "

  if command -v "$check_cmd" &>/dev/null || [ -x "$check_cmd" ] 2>/dev/null; then
    echo -e "${GREEN}✓ found${NC}"
    INSTALLED+=("$name")
    return 0
  fi

  echo -e "${RED}✗ missing${NC}"
  NEED_INSTALL+=("$pkg:$name:$install_hint")
  return 1
}

# Java 21+ (need to check version specifically)
echo "=== Required Dependencies ==="
JAVA_OK=false
JAVA_MAJOR=0
if [ -n "${JAVA_HOME:-}" ] && [ -x "$JAVA_HOME/bin/java" ]; then
  JAVA_MAJOR=$("$JAVA_HOME/bin/java" -version 2>&1 | grep -oE '"([0-9]+)' | tr -d '"' || echo "0")
elif command -v java &>/dev/null; then
  JAVA_MAJOR=$(java -version 2>&1 | grep -oE '"([0-9]+)' | tr -d '"' || echo "0")
fi
if [ "$JAVA_MAJOR" -ge 21 ] 2>/dev/null; then
  echo -e "  Java ($JAVA_MAJOR) ... ${GREEN}✓${NC}"
  INSTALLED+=("Java $JAVA_MAJOR")
else
  echo -e "  Java >= 21 ... ${RED}✗ (found: $JAVA_MAJOR)${NC}"
  NEED_INSTALL+=("openjdk@21:Java 21:brew install openjdk@21")
fi

# CFR
check_and_install "CFR Decompiler" "cfr-decompiler" "cfr-decompiler" "brew install cfr-decompiler"

# Node.js
check_and_install "Node.js" "node" "node" "brew install node"

# grep / find / unzip / strings / shasum (usually pre-installed)
for tool in grep find unzip strings; do
  check_and_install "$tool" "$tool" "$tool" "should be pre-installed"
done

# shasum (macOS) or sha256sum (Linux)
if command -v shasum &>/dev/null || command -v sha256sum &>/dev/null; then
  echo -e "  shasum ... ${GREEN}✓${NC}"
  INSTALLED+=("shasum")
else
  echo -e "  shasum ... ${RED}✗${NC}"
  NEED_INSTALL+=("coreutils:shasum:brew install coreutils")
fi

# ─── 检查是否非交互模式 ───
AUTO_YES=false
if [ "${1:-}" = "-y" ] || [ "${1:-}" = "--yes" ]; then
  AUTO_YES=true
fi

echo ""

# ─── 安装缺失的依赖 ───
if [ ${#NEED_INSTALL[@]} -eq 0 ]; then
  echo -e "${GREEN}✅ All dependencies installed.${NC}"
else
  echo -e "${YELLOW}${#NEED_INSTALL[@]} dependency(s) need installation:${NC}"
  echo ""

  for item in "${NEED_INSTALL[@]}"; do
    pkg="${item%%:*}"
    rest="${item#*:}"
    name="${rest%%:*}"
    hint="${rest#*:}"
    echo "  - $name ($pkg)"
  done

  if $AUTO_YES; then
    echo ""
    echo "Non-interactive mode: auto-installing..."
  else
    echo ""
    read -rp "Install now? [Y/n] " ans
    if [[ "$ans" =~ ^[Nn] ]]; then
      echo "Skipped. Run: $SCRIPT_DIR/setup.sh to try again."
      exit 1
    fi
  fi

  echo ""
  echo "=== Installing ==="
  for item in "${NEED_INSTALL[@]}"; do
    pkg="${item%%:*}"
    rest="${item#*:}"
    name="${rest%%:*}"

    echo ""
    echo "--- Installing $name ($pkg) ---"

    if [ "$pkg" = "openjdk@21" ]; then
      if [ "$PKG_MANAGER" = "Homebrew" ]; then
        brew install openjdk@21
        # Set up symlinks
        brew link --force --overwrite openjdk@21 2>/dev/null || true
        echo "Java 21 installed. Add to PATH if needed:"
        echo '  export PATH="/opt/homebrew/opt/openjdk@21/bin:$PATH"'
      elif [ "$PKG_MANAGER" = "apt" ]; then
        sudo apt-get install -y openjdk-21-jdk
      else
        echo "Please install Java 21 manually: $hint"
      fi
    else
      $INSTALL_CMD "$pkg" 2>&1 || {
        echo -e "${RED}Failed to install $pkg. Try manually:${NC}"
        echo "  $hint"
      }
    fi
  done

  echo ""
fi

# ─── 验证 ───
echo "=== Running environment check ==="
echo ""
if [ -x "$SCRIPT_DIR/scripts/check-env.sh" ]; then
  "$SCRIPT_DIR/scripts/check-env.sh" || true
else
  # Fallback verification
  echo "Java:  $(java -version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "CFR:   $(cfr-decompiler --version 2>&1 | head -1 || echo 'NOT FOUND')"
  echo "Node:  $(node --version 2>&1 || echo 'NOT FOUND')"
fi

# ─── 创建 /mc 别名 ───
MC_ALIAS_DIR="$HOME/.claude/skills/mc"
echo ""
echo "=== Creating /mc alias ==="
if [ -d "$MC_ALIAS_DIR" ]; then
  echo "  /mc alias already exists — skipping"
else
  mkdir -p "$MC_ALIAS_DIR"
  cat > "$MC_ALIAS_DIR/SKILL.md" << 'SKILLEOF'
---
name: mc
description: Minecraft 模组游戏助手 — 由 minecraft-assistant setup.sh 自动创建的别名
---

# /mc → minecraft-assistant

这是 `/mc` 的入口别名。收到用户请求后，**立即使用 Skill 工具调用 `minecraft-assistant`** 处理。
SKILLEOF
  echo -e "  ${GREEN}✓ /mc alias created${NC}"
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Setup complete!                        ║"
echo "║                                         ║"
echo "║  Triggers: /mc  /minecraft-assistant    ║"
echo "║                                         ║"
echo "║  Next: build your knowledge base        ║"
echo "║  ./build-knowledge.sh <instance_path>   ║"
echo "╚══════════════════════════════════════════╝"
