# Minecraft Assistant — Claude Code Skill

Minecraft 模组游戏助手 skill，专为 **GT New Horizons** 等大型整合包设计。支持中文查询，网络搜索优先 + 本地反编译知识库兜底。

## 特性

- 🔍 **三层检索**：网络搜索（MCMOD/MCBBS/Wiki）→ 本地知识库 → 精准重建
- 🧬 **CFR 反编译**：自动从 mod jar 包提取配方和物品数据，不依赖 NEI dump
- 🎯 **外科手术式更新**：检索失败时根据查询语境精准补全，不重扫全部 241 个 mod
- 🌐 **多源网络搜索**：MCMOD、MCBBS、GTNH Wiki、Minecraft Wiki、FTB Wiki
- 📦 **跨 mod 关联**：通过 OreDict 统一 key 关联不同 mod 的物品和配方

## 安装

```bash
# Clone 到 Claude Code skills 目录
git clone https://github.com/berocko/minecraft-assistant.git ~/.claude/skills/minecraft-assistant
```

## 快速开始

### 1. 构建知识库（首次使用）

```bash
~/.claude/skills/minecraft-assistant/build-knowledge.sh \
  "/path/to/your/.minecraft"
```

知识库将生成到 `knowledge/` 目录:
- `index.json` — 物品/配方/映射索引
- `sources/` — CFR 反编译的 Java 源码
- `lang/zh_CN.jsonl` — 中文翻译映射

### 2. 开始提问

在 Claude Code 中直接使用：

```
/mc GTNH里高级电路板怎么合成？
/mc AE2的输出总线怎么把物品输出到GT++的输入总线？
/mc 铝从矿石到锭的完整生产链
```

### 3. 精准重建

如果答案不准确，skill 会自动触发精准重建。也可以手动触发：

```
/mc rebuild
```

或运行脚本：

```bash
scripts/targeted-rebuild.sh ".minecraft" "AE2" "输出总线" "GT++"
```

## 依赖

| 工具 | 用途 | 安装 |
|------|------|------|
| CFR | Java 反编译器 | `brew install cfr-decompiler` |
| Node.js | 索引构建 | `brew install node` |
| Java 21+ | 运行 CFR | `brew install openjdk@21` |

## 支持的整合包

理论上支持所有 Minecraft 1.7.10 Forge 整合包，实测：
- GT New Horizons 2.9.0 (241 mods)

1.12+ 版本部分兼容（配方格式不同，但 lang 文件和 config 解析通用）。

## 工作原理

```
用户Query → Phase 1 网络搜索 (MCMOD/MCBBS/Wiki)
              ├─ HIGH 置信度 → 直接回答
              ├─ MEDIUM → 回答 + 本地验证
              └─ LOW → Phase 2 本地知识库检索
                         ├─ 命中 → 回答
                         └─ 未命中 → Phase 3 精准重建
                                     └─ 增量反编译 → 更新索引 → 重试
```

## 文件结构

```
minecraft-assistant/
├── SKILL.md                    # Skill 主入口
├── REFERENCE.md                # 数据结构与算法详解
├── build-knowledge.sh          # Phase 0: 全量构建
└── scripts/
    ├── build-index.js          # 索引构建器
    ├── targeted-rebuild.sh     # Phase 3: 精准重建
    ├── decompile.sh            # CFR 包装器
    └── parse-lang.sh           # .lang → JSONL
```

## License

MIT
