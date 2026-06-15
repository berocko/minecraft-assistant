---
name: minecraft-assistant
description: Minecraft 模组游戏助手，回答 GregTech/GTNH 等整合包的游戏问题（合成配方、机器用途、生产链等）。网络搜索优先，本地反编译知识库兜底。支持自动检测、构建和精准更新知识库。Use when 用户问 Minecraft 游戏相关问题，尤其是 GTNH/格雷科技/模组合成配方/机器用途。
---

# Minecraft 模组游戏助手

## 快速开始

### 安装

```bash
git clone https://github.com/berocko/minecraft-assistant.git ~/.claude/skills/minecraft-assistant
cd ~/.claude/skills/minecraft-assistant
bash setup.sh    # 一键安装 Java/CFR/Node.js 等所有依赖
```

### 构建知识库

```bash
bash build-knowledge.sh "/path/to/.minecraft"
```

### 提问

```
/mc GTNH里高级电路板怎么合成？
/mc AE2的输出总线怎么把物品输出到GT++的输入总线？
/mc 铝从矿石到锭的完整生产链
```

## 工作流总览

```
Phase -1: 环境预检 (每次调用前自动运行，<1秒)
   ↓
Phase 0:  知识库构建 (首次 / mods 变更时)
   ↓
Phase 1:  网络搜索 (每次查询)
   ↓
Phase 2:  本地知识库检索 (网络低置信度时)
   ↓
Phase 3:  外科手术式精准重建 (本地检索失败 or 玩家否定时)
```

---

### Phase -1: 环境预检（每次 skill 调用前自动运行，<1秒）

**第一步：运行检测**

执行 `scripts/check-env.sh` 检测系统环境。读取其 JSON 输出的 `ready` 和 `issues` 字段。

**第二步：自动修复缺失依赖**

如果 `ready: false` 或 `issues` 非空 — **不要直接报错，自动修复：**

1. 告知用户："检测到 N 个依赖缺失，正在自动安装..."
2. **直接运行** `bash setup.sh -y`（非交互模式，自动确认所有安装）
3. setup.sh 会自动检测 OS → 选包管理器 → 安装 Java 21 / CFR / Node.js
4. 安装完成后**重新运行** `scripts/check-env.sh` 验证

**第三步：确认就绪后继续**

只有 `ready: true` 时才进入 Phase 0。

如果自动安装失败（非 macOS/Linux、无网络、无权限），**直接执行安装命令提示用户手动操作**：

```bash
# macOS
brew install openjdk@21 cfr-decompiler node

# Ubuntu/Debian
sudo apt-get install -y openjdk-21-jdk nodejs npm
# CFR 需手动下载: https://www.benf.org/other/cfr/
```

**退出码处理：**
- `0` = 就绪 → 继续 Phase 0
- `1` = 缺少必需依赖 → 自动 `bash setup.sh` → 再检测 → 仍失败则停止并给出安装命令
- `2` = 部分就绪（如缺少 Node.js）→ 警告用户索引构建不可用，可降级运行

```
环境报告示例:
  OS:     Darwin 25.4.0 (arm64)
  Java:   25 — ✓
  CFR:    ✓ v0.152
  Node:   ✓ v22.5.1
  Tools:  ✓ all present
  Launcher: PrismLauncher — ✓
  Instances: GTNH2.9.0 (242 mods, 12154 configs)
  Disk: 52341MB — ✓ sufficient
  ✅ Environment ready
```

### Phase 0: 知识库构建（首次 / mods 变更时触发）

**前置条件：** Phase -1 通过（`ready: true`）

**触发条件：**
- `knowledge/.build-meta.json` 不存在
- 或检测到 mods 目录的 jar 文件有增删（数量变化或 checksum 变化）

**操作：** 运行 `build-knowledge.sh <instance_path>`，该脚本自动完成：
1. 扫描所有 jar，列出名字含 `Recipe|Loader|Registry` 的 class
2. CFR 批量反编译 → `knowledge/sources/<mod>/`
3. 解析 `.lang` 文件 → `knowledge/lang/<lang>.jsonl`
4. 调用 `scripts/build-index.js` 生成 `knowledge/index.json`
5. 写入 `knowledge/.build-meta.json`（含 jar checksums）

**耗时：** ~5-10 分钟（241 个 mod，~3000 个 recipe class）

**降级模式（无 Node.js）：** 跳过步骤 4，知识库仅含反编译源码 + lang JSONL，检索时直接用 grep + Read 源码。

### Phase 1: 网络搜索（每次查询先走这里）

对用户 query 进行网络搜索，检查以下来源：

| 来源 | 搜索方式 | 适用场景 |
|------|----------|----------|
| MCMOD | `WebSearch site:mcmod.cn <关键词>` | 中文物品介绍、合成表 |
| GTNH Wiki | `WebSearch site:gtnh.miraheze.org <关键词>` | GTNH 专属内容 |
| MCBBS | `WebSearch site:mcbbs.net <关键词>` | 中文教程、攻略 |
| Minecraft Wiki | `WebSearch site:minecraft.wiki <关键词>` | 原版机制 |
| FTB Wiki | `WebSearch site:ftb.fandom.com <关键词>` | 英文模组资料 |

**置信度评估（回答前必须判定）：**

| 级别 | 条件 | 行动 |
|------|------|------|
| HIGH | ≥2 个来源，内容一致，含具体配方或步骤，版本匹配 | 直接回答，标注来源链接 |
| MEDIUM | 1 个来源，或内容可能过时/版本不明确 | 用本地知识库验证关键数据后回答 |
| LOW | 无结果、不相关、版本不匹配、或结果明显错误 | 跳过网络，直接触发 Phase 2 本地检索 |

### Phase 2: 本地知识库检索

1. **分词匹配** — 从 query 提取物品名/模组名 → grep `index.json` 找到 Item ID
2. **读取源码** — 根据 `source_files` 字段，Read 对应的反编译 .java 文件
3. **提取配方** — 从源码中解析 `GTValues.RA.stdBuilder()` 或 `GTModHandler.addCraftingRecipe` 等模式
4. **关联展开** — 如果用户要完整生产链，沿 `used_in` / `recipes_made_in` 字段展开，最多 3 层

### Phase 3: 精准重建（本地检索失败 or 玩家否定时触发）

**触发条件：**
- Phase 2 检索未命中任何结果
- 或玩家明确表示答案不准确（"不对""不是这个""搞错了"）

**绝对不触发全量重建！** Phase 3 只做外科手术式补充：

**操作流程：**
1. **告知用户**：当前知识库对这个问题覆盖不足，将进行精准补全（10-30秒）
2. **提取关键词**：从 query 提取模组名、物品名、OreDict 术语
3. **定向扫描**：
   ```bash
   # 扫描所有 jar 中的 class 文件名
   for jar in mods/*.jar; do
     unzip -l "$jar" | grep -iE "keyword1|keyword2"
   done
   # 扫描所有 jar 中的 strings
   for jar in mods/*.jar; do
     unzip -p "$jar" | strings | grep -iE "keyword1|keyword2"
   done
   # 扫描 config 文件
   grep -rl "keyword1\|keyword2" config/
   ```
4. **定向反编译**：只反编译命中的 class 文件
5. **增量更新**：将新发现的物品/配方合并入 `index.json`，更新 `.build-meta.json`
6. **重新检索**：用更新后的知识库重新回答

### 全量重建触发条件

仅当以下情况才提示全量重建：
- mods 目录的 jar 文件有增删（数量变化）
- 用户手动要求 `/mc rebuild`

---

## 关键文件路径

| 文件 | 用途 |
|------|------|
| `knowledge/index.json` | 物品/配方/映射索引 |
| `knowledge/sources/` | 反编译源码（按 mod 分组） |
| `knowledge/lang/zh_CN.jsonl` | 中文翻译映射 |
| `knowledge/.build-meta.json` | 构建指纹（jar checksums） |
| `scripts/decompile.sh` | CFR 反编译引擎 |
| `scripts/build-index.js` | 索引构建器 |

详见 REFERENCE.md 了解完整数据结构。

## 多实例支持

每个 Minecraft 实例拥有**独立的知识库**，存储在 `knowledge/<instance_slug>/`：

```
knowledge/
├── GTNH2.9.0/
│   ├── .build-meta.json   # 含 Java 版本、实例路径、jar checksums
│   ├── index.json
│   ├── sources/
│   └── lang/
├── GT_New_Horizons_2.8.4/
│   └── ...
```

Java 版本**从启动器配置读取**（如 PrismLauncher 的 `instance.cfg` 中的 `JavaPath`），不使用系统全局 Java。
