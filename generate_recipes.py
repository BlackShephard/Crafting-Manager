#!/usr/bin/env python3
"""
generate_recipes.py  —  Extract shaped crafting recipes from Create mod JARs
and output a recipes.lua for the CC:Tweaked crafting automation system.

Usage:
    python generate_recipes.py <mods_folder> [options]

Examples:
    # All Create* JARs, default station name
    python generate_recipes.py "B:/minecraft mods/Instances/Create Aeronautics  Skyforge Chronicles/mods"

    # Only the base Create jar
    python generate_recipes.py "..." --mod create-1.21

    # Scan every mod (slow, many results)
    python generate_recipes.py "..." --all-mods

    # Specific output file
    python generate_recipes.py "..." --out computercraft/recipes.lua

Slot numbering used in output (matches Mechanical Crafter 3x3 grid):
    [1][2][3]
    [4][5][6]
    [7][8][9]
"""

import sys
import json
import zipfile
import argparse
import re
from pathlib import Path


# ── Ingredient resolution ─────────────────────────────────────────────────────

def get_ingredient_item(ing_def):
    """
    Resolve an ingredient definition to (item_id, is_tag).

    Handles:
      "namespace:item"
      {"item": "namespace:item"}
      {"tag":  "namespace:tag"}    → is_tag=True, needs manual substitution
      [list of above]              → first entry used
    """
    if isinstance(ing_def, list):
        if not ing_def:
            return None, False
        ing_def = ing_def[0]
    if isinstance(ing_def, str):
        return ing_def, False
    if isinstance(ing_def, dict):
        if "item" in ing_def:
            return ing_def["item"], False
        if "tag" in ing_def:
            return ing_def["tag"], True
    return None, False


def pattern_to_ingredients(pattern, key, tag_reg=None):
    """
    Convert a shaped recipe pattern + key dict into a list of
    {item, count, slot} dicts.

    Returns (ingredients, warnings).
    """
    ingredients = []
    warnings = []

    for row_idx, row in enumerate(pattern):
        for col_idx, char in enumerate(row):
            if char == " ":
                continue
            slot = row_idx * 3 + col_idx + 1
            if char not in key:
                warnings.append(f"key char '{char}' missing from key dict")
                continue

            item, is_tag = get_ingredient_item(key[char])
            if item is None:
                warnings.append(f"slot {slot}: empty ingredient definition")
                continue

            if is_tag:
                resolved = tag_reg.resolve(item) if tag_reg else None
                if resolved:
                    item = resolved   # resolved silently
                else:
                    warnings.append(
                        f"slot {slot}: tag '{item}' unresolved — replace manually"
                    )
                    item = "TODO:" + item

            ingredients.append({"item": item, "count": 1, "slot": slot})

    return ingredients, warnings


def get_result(result):
    """Return (item_id, count) from a result field (handles 1.21 and older formats)."""
    if isinstance(result, str):
        return result, 1
    if isinstance(result, dict):
        item = result.get("id") or result.get("item")
        count = int(result.get("count", 1))
        return item, count
    return None, 1


# ── Tag registry ──────────────────────────────────────────────────────────────

# Vanilla Minecraft tags that are defined in the MC client JAR (not in mod JARs).
# Maps tag_id → first/representative concrete item.
VANILLA_TAGS = {
    # Wood / planks
    "minecraft:planks":                    ["minecraft:oak_planks"],
    "minecraft:logs":                      ["minecraft:oak_log"],
    "minecraft:logs_that_burn":            ["minecraft:oak_log"],
    "minecraft:oak_logs":                  ["minecraft:oak_log"],
    "minecraft:spruce_logs":               ["minecraft:spruce_log"],
    "minecraft:birch_logs":                ["minecraft:birch_log"],
    "minecraft:jungle_logs":               ["minecraft:jungle_log"],
    "minecraft:acacia_logs":               ["minecraft:acacia_log"],
    "minecraft:dark_oak_logs":             ["minecraft:dark_oak_log"],
    "minecraft:mangrove_logs":             ["minecraft:mangrove_log"],
    "minecraft:cherry_logs":               ["minecraft:cherry_log"],
    "minecraft:bamboo_blocks":             ["minecraft:bamboo_block"],
    "minecraft:wooden_slabs":              ["minecraft:oak_slab"],
    "minecraft:wooden_stairs":             ["minecraft:oak_stairs"],
    "minecraft:wooden_pressure_plates":    ["minecraft:oak_pressure_plate"],
    "minecraft:wooden_buttons":            ["minecraft:oak_button"],
    "minecraft:wooden_doors":              ["minecraft:oak_door"],
    "minecraft:wooden_trapdoors":          ["minecraft:oak_trapdoor"],
    "minecraft:wooden_fences":             ["minecraft:oak_fence"],
    "minecraft:fence_gates":               ["minecraft:oak_fence_gate"],
    # Stone
    "minecraft:stone_crafting_materials":  ["minecraft:cobblestone"],
    "minecraft:stone_bricks":             ["minecraft:stone_bricks"],
    "minecraft:cobblestone":              ["minecraft:cobblestone"],
    "minecraft:stone_buttons":            ["minecraft:stone_button"],
    "minecraft:stone_pressure_plates":    ["minecraft:stone_pressure_plate"],
    # Ores / ingots / nuggets
    "minecraft:iron_ores":                ["minecraft:iron_ore"],
    "minecraft:gold_ores":                ["minecraft:gold_ore"],
    "minecraft:copper_ores":              ["minecraft:copper_ore"],
    "minecraft:coal_ores":                ["minecraft:coal_ore"],
    "minecraft:diamond_ores":             ["minecraft:diamond_ore"],
    "minecraft:emerald_ores":             ["minecraft:emerald_ore"],
    "minecraft:lapis_ores":               ["minecraft:lapis_ore"],
    "minecraft:redstone_ores":            ["minecraft:redstone_ore"],
    "minecraft:netherite_scrap_ores":     ["minecraft:ancient_debris"],
    "minecraft:coals":                    ["minecraft:coal"],
    # Wool / dyes
    "minecraft:wool":                     ["minecraft:white_wool"],
    "minecraft:carpets":                  ["minecraft:white_carpet"],
    "minecraft:beds":                     ["minecraft:white_bed"],
    "minecraft:dyes":                     ["minecraft:white_dye"],
    # Sand / gravel
    "minecraft:sand":                     ["minecraft:sand"],
    "minecraft:gravel":                   ["minecraft:gravel"],
    # Misc crafting
    "minecraft:sticks":                   ["minecraft:stick"],
    "minecraft:string":                   ["minecraft:string"],
    "minecraft:flowers":                  ["minecraft:dandelion"],
    "minecraft:small_flowers":            ["minecraft:dandelion"],
    "minecraft:tall_flowers":             ["minecraft:sunflower"],
    "minecraft:saplings":                 ["minecraft:oak_sapling"],
    "minecraft:leaves":                   ["minecraft:oak_leaves"],
    "minecraft:fences":                   ["minecraft:oak_fence"],
    "minecraft:slabs":                    ["minecraft:oak_slab"],
    "minecraft:stairs":                   ["minecraft:oak_stairs"],
    "minecraft:boats":                    ["minecraft:oak_boat"],
    "minecraft:signs":                    ["minecraft:oak_sign"],
    "minecraft:hanging_signs":            ["minecraft:oak_hanging_sign"],
    # Create-specific
    "create:cogwheels":                   ["create:cogwheel"],
    "create:large_cogwheels":             ["create:large_cogwheel"],
    "create:andesite_alloys":             ["create:andesite_alloy"],
    "create:brass_items":                 ["create:brass_ingot"],
    "create:copper_items":                ["minecraft:copper_ingot"],
    "create:zinc_items":                  ["create:zinc_ingot"],
    "create:crushed_ores":                ["create:crushed_iron_ore"],
    "create:fan_processing_catalysts/blasting": ["minecraft:lava_bucket"],
    "create:fan_processing_catalysts/smoking":  ["minecraft:campfire"],
}


class TagRegistry:
    """
    Resolves Minecraft item tags to concrete item ids by scanning
    data/*/tags/item*/ JSON files inside JARs.
    Pre-seeded with common vanilla tags that live in the MC client JAR.
    """

    def __init__(self):
        self._tags = dict(VANILLA_TAGS)   # start with vanilla seeds

    def load_jars(self, jars):
        """Load tag definitions from a list of JAR paths."""
        for jar_path in jars:
            try:
                with zipfile.ZipFile(jar_path, "r") as zf:
                    tag_files = [
                        n for n in zf.namelist()
                        if n.endswith(".json") and "/tags/item" in n
                    ]
                    for fname in tag_files:
                        try:
                            data = json.loads(zf.read(fname).decode("utf-8"))
                        except Exception:
                            continue
                        # Derive tag id: data/<ns>/tags/item[s]/<path>.json
                        parts = fname.split("/")
                        if len(parts) < 5:
                            continue
                        ns  = parts[1]
                        sub = "/".join(parts[4:]).removesuffix(".json")
                        tag_id = f"{ns}:{sub}"
                        if tag_id not in self._tags:
                            self._tags[tag_id] = []
                        for v in data.get("values", []):
                            if isinstance(v, str):
                                self._tags[tag_id].append(v)
                            elif isinstance(v, dict):
                                item = v.get("id") or v.get("item")
                                if item:
                                    self._tags[tag_id].append(item)
            except zipfile.BadZipFile:
                pass

    def resolve(self, tag_id, depth=0):
        """
        Return the first concrete item id for a tag, or None if unresolvable.
        Follows nested tag references up to depth 8.
        """
        if depth > 8:
            return None
        for item in self._tags.get(tag_id, []):
            if item.startswith("#"):
                result = self.resolve(item[1:], depth + 1)
                if result:
                    return result
            else:
                return item
        return None


# ── JAR scanning ──────────────────────────────────────────────────────────────

SHAPED_TYPES = {"minecraft:crafting_shaped", "create:mechanical_crafting"}


def scan_jar(jar_path, station_name, tag_reg=None):
    """
    Open one JAR and return (recipes, skipped_count).
    Extracts minecraft:crafting_shaped and create:mechanical_crafting recipes
    that fit within a 3×3 grid.  tag_reg is used to resolve tag ingredients.
    """
    recipes = []
    skipped = 0

    try:
        with zipfile.ZipFile(jar_path, "r") as zf:
            # 1.21 Create uses  data/*/recipe/  (singular, no trailing 's')
            # Older packs used  data/*/recipes/ (plural)
            recipe_files = [
                n for n in zf.namelist()
                if n.endswith(".json")
                and ("/recipe/" in n or "/recipes/" in n)
                and "/advancement/" not in n   # skip unlock-criteria files
            ]

            for fname in recipe_files:
                try:
                    raw = zf.read(fname).decode("utf-8")
                    data = json.loads(raw)
                except Exception:
                    skipped += 1
                    continue

                if data.get("type") not in SHAPED_TYPES:
                    skipped += 1
                    continue

                pattern = data.get("pattern")
                key     = data.get("key")
                result  = data.get("result")

                if not pattern or not key or result is None:
                    skipped += 1
                    continue

                # Skip patterns that don't fit in a 3×3 crafter
                if len(pattern) > 3 or any(len(row) > 3 for row in pattern):
                    skipped += 1
                    continue

                output_item, output_count = get_result(result)
                if not output_item:
                    skipped += 1
                    continue

                ingredients, warnings = pattern_to_ingredients(pattern, key, tag_reg)
                if not ingredients:
                    skipped += 1
                    continue

                # Build a stable id from the output item name
                rec_id = re.sub(r"[^a-z0-9_]", "_", output_item.lower())
                display = output_item.split(":")[-1].replace("_", " ").title()

                recipes.append({
                    "id":           rec_id,
                    "name":         display,
                    "output":       output_item,
                    "output_count": output_count,
                    "station":      station_name,
                    "ingredients":  ingredients,
                    "warnings":     warnings,
                    "source":       fname,
                })

    except zipfile.BadZipFile:
        print(f"    SKIP: {jar_path.name} is not a valid JAR")

    return recipes, skipped


# ── Lua output ────────────────────────────────────────────────────────────────

def lua_str(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def emit_lua_recipe(rec):
    lines = []

    # Source comment
    lines.append(f"  -- {rec['name']}  (from {rec['source'].split('/')[-1]})")

    # Any warnings as comments
    for w in rec["warnings"]:
        lines.append(f"  -- WARN: {w}")

    lines.append("  {")
    lines.append(f"    id           = {lua_str(rec['id'])},")
    lines.append(f"    name         = {lua_str(rec['name'])},")
    lines.append(f"    output       = {lua_str(rec['output'])},")
    lines.append(f"    output_count = {rec['output_count']},")
    lines.append(f"    station      = {lua_str(rec['station'])},")
    lines.append(f"    ingredients  = {{")
    for ing in rec["ingredients"]:
        lines.append(
            f"      {{item={lua_str(ing['item'])}, count={ing['count']}, slot={ing['slot']}}},"
        )
    lines.append("    },")
    lines.append("  },")

    return "\n".join(lines)


# ── Main ──────────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(
        description="Generate recipes.lua from Create mod JARs",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    ap.add_argument("mods_folder",
                    help="Path to the modpack mods folder")
    ap.add_argument("--mod", default=None,
                    help="Only scan JARs whose filename contains this string")
    ap.add_argument("--all-mods", action="store_true",
                    help="Scan ALL JARs (not just create* ones)")
    ap.add_argument("--station", default="cogwheel_station",
                    help="Station name assigned to every recipe (default: cogwheel_station)")
    ap.add_argument("--out", default=None,
                    help="Output path (default: recipes_generated.lua beside this script)")
    args = ap.parse_args()

    mods_dir = Path(args.mods_folder)
    if not mods_dir.is_dir():
        print(f"ERROR: mods folder not found:\n  {mods_dir}")
        sys.exit(1)

    # Collect JARs to scan
    if args.all_mods:
        jars = sorted(mods_dir.glob("*.jar"))
    elif args.mod:
        jars = sorted(j for j in mods_dir.glob("*.jar") if args.mod in j.name)
    else:
        jars = sorted(j for j in mods_dir.glob("*.jar")
                      if j.name.lower().startswith("create"))

    if not jars:
        print(f"ERROR: no matching JARs found in {mods_dir}")
        sys.exit(1)

    # Build tag registry from ALL JARs in the folder (tags are spread across mods)
    all_jars = list(mods_dir.glob("*.jar"))
    print(f"Building tag registry from {len(all_jars)} JARs...", end=" ", flush=True)
    tag_reg = TagRegistry()
    tag_reg.load_jars(all_jars)
    print("done.\n")

    print(f"Scanning {len(jars)} JAR(s) for shaped crafting recipes...\n")

    all_recipes  = []
    seen_outputs = {}   # output_item → recipe id (dedup by output)
    total_skip   = 0

    for jar in jars:
        recs, skip = scan_jar(jar, args.station, tag_reg)
        total_skip += skip
        added = 0
        for rec in recs:
            if rec["output"] in seen_outputs:
                continue    # keep first encountered (base Create wins over addons)
            seen_outputs[rec["output"]] = rec["id"]
            all_recipes.append(rec)
            added += 1
        print(f"  {jar.name}")
        print(f"    {added} new shaped recipes  ({skip} non-shaped/skipped)")

    # Sort alphabetically by display name
    all_recipes.sort(key=lambda r: r["name"].lower())

    tag_count = sum(
        1 for r in all_recipes for i in r["ingredients"]
        if i["item"].startswith("TODO:")
    )

    # Write output
    out_path = Path(args.out) if args.out else Path(__file__).parent / "recipes_generated.lua"

    with open(out_path, "w", encoding="utf-8") as f:
        f.write("-- ============================================================\n")
        f.write("--  recipes_generated.lua\n")
        f.write("--  AUTO-GENERATED by generate_recipes.py — review before use!\n")
        f.write("--\n")
        f.write(f"--  Total recipes : {len(all_recipes)}\n")
        if tag_count:
            f.write(f"--  Tag placeholders: {tag_count} ingredient(s) marked TODO:\n")
            f.write("--    Search for 'TODO:' and replace with concrete item ids\n")
        f.write("--\n")
        f.write(f'--  station field is set to "{args.station}" for all entries.\n')
        f.write("--  With any-station routing this is informational only, but\n")
        f.write("--  you can change it per recipe to prefer a specific station.\n")
        f.write("-- ============================================================\n\n")
        f.write("return {\n\n")

        for rec in all_recipes:
            f.write(emit_lua_recipe(rec))
            f.write("\n\n")

        f.write("}\n")

    print(f"\n{'='*60}")
    print(f"  {len(all_recipes)} recipes  ->  {out_path}")
    if tag_count:
        print(f"  WARN: {tag_count} tag ingredients need manual substitution (search TODO:)")
    print(f"{'='*60}")
    print("\nNext steps:")
    print("  1. Open recipes_generated.lua and review/trim to what you want")
    print("  2. Fix any TODO: tag placeholders with real item ids")
    print("  3. Rename to recipes.lua")
    print("  4. Copy to both the server and station computers in-game")


if __name__ == "__main__":
    main()
