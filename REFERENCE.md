# Minecraft Assistant — 参考文档

## 数据结构

### index.json 结构

```json
{
  "build_info": {
    "version": "1",
    "built_at": "2026-06-15T22:00:00+08:00",
    "instance_path": "/Users/.../GTNH2.9.0/.minecraft",
    "mod_count": 241,
    "recipe_class_count": 2991
  },
  "items": {
    "gt.metaitem.01.32600": {
      "unlocalized": "gt.metaitem.01.32600",
      "display": "高级电路板",
      "mod": "gregtech",
      "oredict": ["circuitAdvanced", "circuitData"],
      "type": "component",
      "recipes_made_in": [
        {"map": "assemblerRecipes", "file": "CircuitComponent.java", "line": 420}
      ],
      "used_in": [
        {"item": "gt.blockmachines.1234", "display": "组装机", "file": "CraftingRecipes.java", "line": 85}
      ],
      "source_files": [
        "gregtech/CircuitComponent.java:420",
        "gregtech/CraftingRecipes.java:85"
      ]
    }
  },
  "recipes": [
    {
      "type": "machine",
      "machine": "assembler",
      "map": "assemblerRecipes",
      "inputs": [
        {"item": "gt.metaitem.01.32603", "display": "电路板基板", "count": 1},
        {"oredict": "circuitBasic", "count": 2}
      ],
      "outputs": [
        {"item": "gt.metaitem.01.32600", "display": "高级电路板", "count": 1}
      ],
      "fluid_inputs": [
        {"fluid": "molten.solderingalloy", "amount_mb": 144}
      ],
      "duration_ticks": 600,
      "eu_per_tick": 480,
      "tier": "HV",
      "conditions": ["requiresCleanRoom"],
      "source_file": "gregtech/CircuitComponent.java:420"
    }
  ],
  "crafting": [
    {
      "type": "shaped",
      "pattern": ["CDC", "SBS", "CFC"],
      "keys": {
        "C": {"oredict": "circuitAdvanced"},
        "D": {"item": "gt.metaitem.01.32750", "display": "显示屏"},
        "S": {"oredict": "cableGt12Platinum"},
        "B": {"item": "gt.blockmachines.01", "display": "机器外壳"},
        "F": {"item": "gt.metaitem.01.32690", "display": "力场发生器"}
      },
      "output": {"item": "gt.blockmachines.1234", "display": "组装机", "count": 1},
      "source_file": "gregtech/CraftingRecipes.java:85"
    }
  ],
  "mappings": {
    "display_to_id": {
      "高级电路板": ["gt.metaitem.01.32600"],
      "组装机": ["gt.blockmachines.1234"],
      "电路板基板": ["gt.metaitem.01.32603"]
    },
    "oredict": {
      "circuitAdvanced": ["gt.metaitem.01.32600", "bartworks.item.123"],
      "circuitBasic": ["gt.metaitem.01.32601", "..."]
    }
  },
  "machine_maps": {
    "assemblerRecipes": "组装机",
    "formingPressRecipes": "冲压机床",
    "autoclaveRecipes": "高压釜",
    "compressorRecipes": "压缩机",
    "extractorRecipes": "提取机"
  }
}
```

### .build-meta.json 结构

```json
{
  "build_date": "2026-06-15T22:00:00+08:00",
  "instance_path": "/Users/.../GTNH2.9.0/.minecraft",
  "jar_checksums": {
    "gregtech-5.09.52.594.jar": "sha256:abc123...",
    "GTNewHorizonsCoreMod-2.8.279.jar": "sha256:def456..."
  },
  "jar_count": 241,
  "mod_count": 242,
  "classes_decompiled": 2991,
  "recipes_extracted": 15234,
  "items_indexed": 98342,
  "last_targeted_rebuild": {
    "query": "AE2输出总线 GT++输入总线",
    "date": "2026-06-15T23:00:00+08:00",
    "classes_added": 3,
    "recipes_added": 12
  }
}
```

### lang JSONL 格式

每行一个 JSON 对象：

```jsonl
{"unlocalized":"gt.metaitem.01.32600.name","display":"高级电路板","mod":"gregtech","lang":"zh_CN"}
{"unlocalized":"gt.metaitem.01.32601.name","display":"基础电路板","mod":"gregtech","lang":"zh_CN"}
```

## 反编译源码目录结构

```
knowledge/sources/
├── gregtech/
│   ├── main/
│   │   └── java/
│   │       └── gregtech/
│   │           ├── common/
│   │           │   ├── items/
│   │           │   │   └── ItemIntegratedCircuit.java
│   │           │   └── loaders/
│   │           │       └── ...
│   │           └── api/
│   │               └── ...
│   └── crossmod/
│       └── bartworks/
│           └── ...
├── GTNewHorizonsCoreMod/
├── bartworks/
├── appliedenergistics2/
├── EnderIO/
└── ...
```

## 检索算法

### 物品名匹配（中文/英文均可）

```
输入: "高级电路板"
1. 查 mappings.display_to_id["高级电路板"] → ["gt.metaitem.01.32600"]
2. 查 items["gt.metaitem.01.32600"]
3. 返回: 物品元数据 + 关联配方 + 关联源文件

输入: "circuit board" (英文)
1. 查 items where oredict contains "circuit"
2. 交叉匹配 lang 显示名中包含 "电路板" 的条目
3. 返回候选项列表
```

### 配方展开（递归）

```
输入: "高级电路板怎么合成"
1. 匹配物品 → 找到 recipes_made_in
2. 读取首个配方: 输入包含 "电路板基板" + "circuitBasic"
3. 可选展开: "电路板基板" 的来源配方
4. 最多展开 3 层
```

### 生产链查询

```
输入: "铝从矿石到锭"
1. 匹配 "铝" → 找到 Aluminium 相关条目
2. 搜索链: 铝矿石 → (粉碎/洗矿/离心/电解) → 铝粉 → (熔炼) → 铝锭
3. 每一步在 index.json 中找到对应的 machine_map
4. 组合成完整流程图
```

## 配置选项

Skill 支持通过环境变量或配置文件覆盖默认行为：
- `MC_INSTANCE_PATH` — 直接指定 Minecraft 实例路径
- `MC_LANG` — 首选语言，默认 `zh_CN`
- `MC_MAX_CHAIN_DEPTH` — 配方展开最大深度，默认 3
