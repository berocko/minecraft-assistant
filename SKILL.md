---
name: minecraft-assistant
description: Minecraft 模组游戏助手，回答 GregTech/GTNH 等整合包的游戏问题（合成配方、机器用途、生产链等）。网络搜索优先，本地反编译知识库兜底。支持自动检测、构建和精准更新知识库。Use when 用户问 Minecraft 游戏相关问题，尤其是 GTNH/格雷科技/模组合成配方/机器用途。
---

# Minecraft 模组游戏助手

## 快速开始

用户通过 `/mc` 或直接描述问题触发：

```
/mc GTNH里高级电路板怎么合成？
/mc AE2的输出总线怎么把物品输出到GT++的输入总线？
/mc 铝从矿石到锭的完整生产链
```

## 实例配置

首次使用前，用户需告知 Minecraft 实例路径（如 PrismLauncher 的 instances 目录）。
skill 会自动检测 `.minecraft/mods/`、`.minecraft/config/` 等目录。

默认查找路径（按优先级）：
1. 用户明确指定的路径
2. `~/Library/Application Support/PrismLauncher/instances/` 下的实例
3. 其他常见启动器路径

## 工作流

### Phase 0: 知识库构建（首次 / mods 变更时触发）

**触发条件：**
- `~/.claude/skills/minecraft-assistant/knowledge/.build-meta.json` 不存在
- 或检测到 mods 目录的 jar 比 meta 文件更新

**操作流程：**
1. 解析实例路径，定位 `mods/`、`config/`、`.lang` 文件
2. 运行 CFR 反编译：对所有 jar 中名字包含 `Recipe|Loader|Registry` 的 class 进行反编译
3. 解析 lang 文件：将 `.lang` 转为 JSONL 格式（只保留用户当前语言）
4. 构建索引：生成 `index.json` 包含物品→配方→用途的映射
5. 写入 `.build-meta.json` 指纹

详见 BUILD.md。

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
