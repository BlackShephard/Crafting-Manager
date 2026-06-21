-- processing.lua
-- Recipes for items produced by non-mechanical-crafter machines
-- (mechanical press, mechanical mixer, etc.).
--
-- How it works:
--   When compound crafting needs one of these items, the server pushes
--   the raw ingredients into a package addressed to `station`.
--   The Create logistics system routes the package to the processing
--   machine.  A processing station computer watches that machine's
--   output barrel and only fires the return Packager when the exact
--   requested output count is ready.
--
-- Fields:
--   id           unique recipe identifier (string)
--   name         display name shown in the compound plan panel
--   type         machine type: "press" | "mix" | "saw" | "fan_wash" | ...
--                (used for the [PRESS] / [MIX] label in the UI)
--   station      Create frogport/packager address the package is
--                sent to. Also must match cfg.station_name on that
--                machine's processing_station.lua computer.
--   output       item id this recipe produces
--   output_count how many output items are produced per craft
--   ingredients  list of { item=<item_id>, count=<number> }
--
-- To add a recipe: duplicate an existing entry and change the fields.
-- The `station` name must match the frogport address label you set
-- on the Create packager next to the processing machine.

return {

    -- ================================================================
    --  LOG STRIPPER  --  Create saw processing
    --  station address: "saw_station"
    --  Feed raw log; saw strips it and returns stripped log.
    -- ================================================================

    {
        id="strip_oak_log",       name="Stripped Oak Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_oak_log",    output_count=1,
        ingredients = { {item="minecraft:oak_log", count=1} },
    },
    {
        id="strip_birch_log",     name="Stripped Birch Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_birch_log",  output_count=1,
        ingredients = { {item="minecraft:birch_log", count=1} },
    },
    {
        id="strip_spruce_log",    name="Stripped Spruce Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_spruce_log", output_count=1,
        ingredients = { {item="minecraft:spruce_log", count=1} },
    },
    {
        id="strip_jungle_log",    name="Stripped Jungle Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_jungle_log", output_count=1,
        ingredients = { {item="minecraft:jungle_log", count=1} },
    },
    {
        id="strip_acacia_log",    name="Stripped Acacia Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_acacia_log", output_count=1,
        ingredients = { {item="minecraft:acacia_log", count=1} },
    },
    {
        id="strip_dark_oak_log",  name="Stripped Dark Oak Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_dark_oak_log", output_count=1,
        ingredients = { {item="minecraft:dark_oak_log", count=1} },
    },
    {
        id="strip_mangrove_log",  name="Stripped Mangrove Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_mangrove_log", output_count=1,
        ingredients = { {item="minecraft:mangrove_log", count=1} },
    },
    {
        id="strip_cherry_log",    name="Stripped Cherry Log",
        type="saw", station="saw_station",
        output="minecraft:stripped_cherry_log", output_count=1,
        ingredients = { {item="minecraft:cherry_log", count=1} },
    },

    -- ================================================================
    --  MECHANICAL PRESS  --  Pressing
    --  station address: "press_station"
    --  Feed raw ingot; machine presses and returns flat sheet/plate.
    -- ================================================================

    {
        id="press_copper_sheet",  name="Copper Sheet",
        type="press",  station="press_station",
        output="create:copper_sheet",  output_count=1,
        ingredients = { {item="minecraft:copper_ingot", count=1} },
    },
    {
        id="press_iron_sheet",    name="Iron Sheet",
        type="press",  station="press_station",
        output="create:iron_sheet",    output_count=1,
        ingredients = { {item="minecraft:iron_ingot", count=1} },
    },
    {
        id="press_gold_sheet",    name="Gold Sheet",
        type="press",  station="press_station",
        output="create:gold_sheet",    output_count=1,
        ingredients = { {item="minecraft:gold_ingot", count=1} },
    },
    {
        id="press_zinc_sheet",    name="Zinc Sheet",
        type="press",  station="press_station",
        output="create:zinc_sheet",    output_count=1,
        ingredients = { {item="create:zinc_ingot", count=1} },
    },
    {
        id="press_brass_sheet",   name="Brass Sheet",
        type="press",  station="press_station",
        output="create:brass_sheet",   output_count=1,
        ingredients = { {item="create:brass_ingot", count=1} },
    },

    -- ================================================================
    --  MECHANICAL MIXER  --  Alloying  (requires heat source)
    --  station address: "mixer_station"
    -- ================================================================

    {
        id="mix_brass_ingot",     name="Brass Ingot",
        type="mix",  station="mixer_station",
        output="create:brass_ingot",   output_count=3,
        ingredients = {
            {item="minecraft:copper_ingot", count=2},
            {item="create:zinc_ingot",      count=1},
        },
    },
    {
        id="mix_andesite_alloy",  name="Andesite Alloy",
        type="mix",  station="mixer_station",
        output="create:andesite_alloy", output_count=2,
        ingredients = {
            {item="minecraft:iron_nugget", count=1},
            {item="minecraft:andesite",    count=1},
        },
    },

    -- ================================================================
    --  CASING MAKER  --  Deployer applies casing material to stripped log
    --  station address: "casing_station"
    --  Feed any stripped log + casing material; the casing station
    --  moves the log to the depot and the material into the deployer hand.
    -- ================================================================

    {
        id="deploy_andesite_casing", name="Andesite Casing",
        type="deploy", station="casing_station",
        output="create:andesite_casing", output_count=1,
        ingredients = {
            {item="c:stripped_logs",            count=1},
            {item="create:andesite_alloy",      count=1},
        },
    },
    {
        id="deploy_brass_casing",    name="Brass Casing",
        type="deploy", station="casing_station",
        output="create:brass_casing",    output_count=1,
        ingredients = {
            {item="c:stripped_logs",            count=1},
            {item="create:brass_ingot",         count=1},
        },
    },
    {
        id="deploy_copper_casing",   name="Copper Casing",
        type="deploy", station="casing_station",
        output="create:copper_casing",   output_count=1,
        ingredients = {
            {item="c:stripped_logs",            count=1},
            {item="minecraft:copper_ingot",     count=1},
        },
    },

    -- ================================================================
    --  Add more entries here as you build new processing stations.
    -- ================================================================
}
