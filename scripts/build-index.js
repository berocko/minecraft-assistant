#!/usr/bin/env node
/**
 * Minecraft Assistant — Index Builder
 *
 * Reads decompiled source files + lang JSONL + config files
 * and produces a unified index.json for fast retrieval.
 *
 * Usage:
 *   node build-index.js --sources <dir> --lang <file> --config <dir> --output <file> --mods <dir>
 */

const fs = require("fs");
const path = require("path");

// ─── Argument parsing ───
const args = process.argv.slice(2);
const getArg = (name) => {
  const idx = args.indexOf(`--${name}`);
  return idx >= 0 ? args[idx + 1] : null;
};

const SOURCES_DIR = getArg("sources");
const LANG_FILE = getArg("lang");
const CONFIG_DIR = getArg("config");
const OUTPUT_FILE = getArg("output");
const MODS_DIR = getArg("mods");

if (!SOURCES_DIR || !OUTPUT_FILE) {
  console.error("Usage: build-index.js --sources <dir> --lang <file> --config <dir> --output <file> [--mods <dir>]");
  process.exit(1);
}

// ─── Data containers ───
const items = {};           // unlocalized → item metadata
const recipes = [];         // machine recipes
const crafting = [];        // crafting table recipes
const displayToId = {};     // display name → [unlocalized IDs]
const oredictMap = {};      // oredict → [unlocalized IDs]
const machineMaps = {};     // recipe map name → Chinese name

// ─── Machine map translations ───
const MACHINE_MAP_NAMES = {
  assemblerRecipes: "组装机",
  formingPressRecipes: "冲压机床",
  autoclaveRecipes: "高压釜",
  compressorRecipes: "压缩机",
  extractorRecipes: "提取机",
  fluidExtractorRecipes: "流体提取机",
  fluidSolidifierRecipes: "流体固化器",
  maceratorRecipes: "打粉机",
  centrifugeRecipes: "离心机",
  electrolyzerRecipes: "电解机",
  chemicalReactorRecipes: "化学反应釜",
  blastFurnaceRecipes: "高炉",
  implosionCompressorRecipes: "爆聚压缩机",
  vacuumFreezerRecipes: "真空冷冻机",
  wiremillRecipes: "线材轧机",
  bendingMachineRecipes: "弯曲机",
  latheRecipes: "车床",
  cutterRecipes: "切割机",
  slicerRecipes: "切片机",
  extruderRecipes: "挤出机",
  alloySmelterRecipes: "合金炉",
  arcFurnaceRecipes: "电弧炉",
  plasmaArcFurnaceRecipes: "等离子电弧炉",
  sifterRecipes: "筛分机",
  thermalCentrifugeRecipes: "热力离心机",
  oreWasherRecipes: "洗矿机",
  chemicalBathRecipes: "化学浸洗机",
  electromagneticSeparatorRecipes: "电磁选矿机",
  circuitAssemblerRecipes: "电路组装机",
  laserEngraverRecipes: "激光蚀刻机",
  canningMachineRecipes: "罐装机",
  fermenterRecipes: "发酵槽",
  fluidHeaterRecipes: "流体加热器",
  distilleryRecipes: "蒸馏室",
  mixerRecipes: "搅拌机",
  packagerRecipes: "打包机",
  unpackagerRecipes: "拆包机",
  rockBreakerRecipes: "碎石机",
};

// Merge machine map names
Object.assign(machineMaps, MACHINE_MAP_NAMES);

// ─── Step 1: Load language data ───
console.log("Loading language data...");
if (LANG_FILE && fs.existsSync(LANG_FILE)) {
  const lines = fs.readFileSync(LANG_FILE, "utf-8").split("\n").filter(Boolean);
  for (const line of lines) {
    try {
      const entry = JSON.parse(line);
      const id = entry.unlocalized;

      if (!items[id]) {
        items[id] = {
          unlocalized: id,
          display: entry.display,
          mod: entry.mod,
          oredict: [],
          type: "unknown",
          recipes_made_in: [],
          used_in: [],
          source_files: [],
        };
      }

      // Build reverse mapping
      if (entry.display) {
        if (!displayToId[entry.display]) displayToId[entry.display] = [];
        if (!displayToId[entry.display].includes(id)) displayToId[entry.display].push(id);
      }
    } catch (e) {
      // Skip malformed lines
    }
  }
  console.log(`  ${Object.keys(items).length} items loaded from lang`);
}

// ─── Step 2: Scan decompiled sources for recipes ───
console.log("Scanning source files for recipes...");

function walkDir(dir) {
  const results = [];
  try {
    const entries = fs.readdirSync(dir, { withFileTypes: true });
    for (const entry of entries) {
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        results.push(...walkDir(full));
      } else if (entry.name.endsWith(".java")) {
        results.push(full);
      }
    }
  } catch (e) {
    // Skip inaccessible dirs
  }
  return results;
}

function extractItemName(expr) {
  // Extract human-readable item name from Java expressions
  expr = expr.replace(/\s+/g, " ").trim();

  // Pattern: ItemList.Some_Item.get(1L, ...)
  let m = expr.match(/ItemList\.(\w+)\.get\(/);
  if (m) return { type: "itemlist", name: m[1].replace(/_/g, " ") };

  // Pattern: Materials.MaterialName
  m = expr.match(/Materials\.(\w+)\.get\(/);
  if (m) return { type: "material", name: m[1] };

  // Pattern: WerkstoffLoader.MaterialName.get(...)
  m = expr.match(/WerkstoffLoader\.(\w+)\.get\(/);
  if (m) return { type: "werkstoff", name: m[1] };

  // Pattern: OrePrefixes.prefixName
  m = expr.match(/OrePrefixes\.(\w+)/);
  if (m) return { type: "oreprefix", name: m[1] };

  // Pattern: "oredictString" (quoted ore dictionary name)
  m = expr.match(/"([a-zA-Z_][a-zA-Z0-9_.]*[a-zA-Z])"/);
  if (m) return { type: "oredict", name: m[1] };

  // Pattern: ItemRegistry.SOME_ITEM
  m = expr.match(/ItemRegistry\.(\w+)/);
  if (m) return { type: "itemregistry", name: m[1] };

  // Pattern: new ItemStack(ItemRegistry.SOME_BLOCK[n])
  m = expr.match(/ItemRegistry\.(\w+)\[/);
  if (m) return { type: "itemregistry_block", name: m[1] };

  return { type: "unknown", name: expr.substring(0, 60) };
}

function extractTimeValue(expr) {
  // Extract tick count: .duration(N) or duration(ticks * 20)
  const m = expr.match(/\.duration\((\d+)\)/);
  return m ? parseInt(m[1]) / 20 : null; // Convert ticks to seconds
}

function extractEUTier(expr) {
  const tiers = {
    RECIPE_ULV: "ULV", RECIPE_LV: "LV", RECIPE_MV: "MV",
    RECIPE_HV: "HV", RECIPE_EV: "EV", RECIPE_IV: "IV",
    RECIPE_LuV: "LuV", RECIPE_ZPM: "ZPM", RECIPE_UV: "UV",
    RECIPE_UHV: "UHV", RECIPE_UEV: "UEV", RECIPE_UIV: "UIV",
    RECIPE_UMV: "UMV", RECIPE_UXV: "UXV", RECIPE_MAX: "MAX",
  };
  for (const [key, val] of Object.entries(tiers)) {
    if (expr.includes(key)) return val;
  }
  return "unknown";
}

const javaFiles = walkDir(SOURCES_DIR);
console.log(`  Found ${javaFiles.length} decompiled Java files`);

let recipeCount = 0;
let craftingCount = 0;

for (const file of javaFiles) {
  try {
    const content = fs.readFileSync(file, "utf-8");
    const lines = content.split("\n");
    const relPath = path.relative(SOURCES_DIR, file);
    const modName = relPath.split(path.sep)[0];

    // ─── Pattern 1: GT machine recipes ───
    // GTValues.RA.stdBuilder().itemInputs(...).itemOutputs(...).duration(N).eut(Tier).addTo(RecipeMaps.xxx)
    const stdBuilderRegex = /GTValues\.RA\.stdBuilder\(\)/g;
    const contentOneLine = content.replace(/\n\s*/g, " ");
    let match;

    while ((match = stdBuilderRegex.exec(contentOneLine)) !== null) {
      // Get context around the match (the full recipe chain)
      const startPos = match.index;
      const endPos = Math.min(startPos + 2000, contentOneLine.length);
      const recipeBlock = contentOneLine.substring(startPos, endPos);

      // Extract recipe map (machine type)
      const mapMatch = recipeBlock.match(/\.addTo\([^)]*RecipeMaps\.(\w+)/);
      const recipeMap = mapMatch ? mapMatch[1] : "unknown";

      // Extract inputs
      const inputs = [];
      const inputMatch = recipeBlock.match(/\.itemInputs\(([^)]+)\)/);
      if (inputMatch) {
        // Split by "] , [" pattern
        const inputStr = inputMatch[1];
        const parts = inputStr.split(/\]\s*,\s*\[/);
        for (const part of parts) {
          inputs.push(extractItemName(part));
        }
      }

      // Extract outputs
      const outputs = [];
      const outputMatch = recipeBlock.match(/\.itemOutputs\(([^)]+)\)/);
      if (outputMatch) {
        const parts = outputMatch[1].split(/\]\s*,\s*\[/);
        for (const part of parts) {
          outputs.push(extractItemName(part));
        }
      }

      // Extract fluid inputs
      const fluidInputs = [];
      const fluidMatch = recipeBlock.match(/\.fluidInputs\(([^)]+)\)/);
      if (fluidMatch) {
        const fParts = fluidMatch[1].split(/\]\s*,\s*\[/);
        for (const part of fParts) {
          const amountMatch = part.match(/Materials\.(\w+)\.getMolten\((\d+)L\)/);
          if (amountMatch) {
            fluidInputs.push({ fluid: amountMatch[1], amount_mb: parseInt(amountMatch[2]) });
          }
        }
      }

      const durationSec = extractTimeValue(recipeBlock);
      const tier = extractEUTier(recipeBlock);

      // Extract EU/t
      const euMatch = recipeBlock.match(/\.eut\(TierEU\.(\w+)\)/);
      const euPerTick = euMatch ? euMatch[1] : tier;

      recipes.push({
        type: "machine",
        machine: machineMaps[recipeMap] || recipeMap,
        map: recipeMap,
        inputs,
        outputs,
        fluid_inputs: fluidInputs,
        duration_seconds: durationSec,
        eu_per_tick: euPerTick,
        tier,
        source_file: relPath,
        mod: modName,
      });
      recipeCount++;
    }

    // ─── Pattern 2: Crafting table recipes ───
    // GTModHandler.addCraftingRecipe(output, bits, new Object[]{"ABC", "DEF", ...})
    const craftRegex = /GTModHandler\.addCraftingRecipe\(([^;]+)\)/g;
    while ((match = craftRegex.exec(contentOneLine)) !== null) {
      const block = match[1];

      // Extract pattern lines (3 uppercase strings)
      const patternMatch = block.match(/"([A-Z]{1,3})"\s*,\s*"([A-Z]{1,3})"\s*,\s*"([A-Z]{1,3})"/);

      // Extract key mappings
      const keyMap = {};
      const charRegex = /Character\.valueOf\('(\w)'\)\s*,\s*([^,)]+)/g;
      let charMatch;
      while ((charMatch = charRegex.exec(block)) !== null) {
        keyMap[charMatch[1]] = extractItemName(charMatch[2]);
      }

      if (patternMatch) {
        crafting.push({
          type: "shaped",
          pattern: [patternMatch[1], patternMatch[2], patternMatch[3]],
          keys: keyMap,
          output: extractItemName(block), // approximate, first ItemStack
          source_file: relPath,
          mod: modName,
        });
        craftingCount++;
      }
    }

    // ─── Extract item references for building the items index ───
    // Look for ItemList registrations
    const itemListRegex = /ItemList\.(\w+)\.set\(/g;
    while ((match = itemListRegex.exec(content)) !== null) {
      const id = match[1];
      const unlocalizedId = `ItemList.${id}`;
      if (!items[unlocalizedId]) {
        items[unlocalizedId] = {
          unlocalized: unlocalizedId,
          display: id.replace(/_/g, " "),
          mod: modName,
          oredict: [],
          type: "item",
          recipes_made_in: [],
          used_in: [],
          source_files: [relPath],
        };
      }
    }

  } catch (e) {
    // Skip files that can't be read
  }
}

console.log(`  ${recipeCount} machine recipes extracted`);
console.log(`  ${craftingCount} crafting recipes extracted`);

// ─── Step 3: Build cross-references ───
console.log("Building cross-references...");

// Link recipes to items (used_in / recipes_made_in)
for (const recipe of recipes) {
  for (const output of recipe.outputs) {
    const displayName = output.name;
    const ids = displayToId[displayName] || [];
    for (const id of ids) {
      if (items[id]) {
        items[id].recipes_made_in.push({
          map: recipe.map,
          machine: recipe.machine,
          file: recipe.source_file,
        });
      }
    }
  }
  for (const input of recipe.inputs) {
    const displayName = input.name;
    const ids = displayToId[displayName] || [];
    for (const id of ids) {
      if (items[id]) {
        items[id].used_in.push({
          machine: recipe.machine,
          file: recipe.source_file,
        });
      }
    }
  }
}

// ─── Step 4: Write output ───
console.log("Writing index...");

const index = {
  build_info: {
    version: "1",
    built_at: new Date().toISOString(),
    recipe_count: recipeCount,
    crafting_count: craftingCount,
    item_count: Object.keys(items).length,
  },
  items,
  recipes,
  crafting,
  mappings: {
    display_to_id: displayToId,
    oredict: oredictMap,
  },
  machine_maps: machineMaps,
};

fs.writeFileSync(OUTPUT_FILE, JSON.stringify(index, null, 2));
console.log(`Index written to ${OUTPUT_FILE}`);
console.log(`  ${Object.keys(items).length} items`);
console.log(`  ${recipes.length} machine recipes`);
console.log(`  ${crafting.length} crafting recipes`);
