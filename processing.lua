-- processing.lua
-- Recipes for items produced by non-mechanical-crafter machines
-- (mechanical press, mechanical mixer, etc.).
--
-- How it works:
--   When compound crafting needs one of these items, the server pushes
--   the raw ingredients into a package addressed to `station`.
--   The Create logistics system routes the package to the processing
--   machine, which transforms it and sends the output back to the
--   home vault automatically.  No CC computer is needed at the
--   processing end -- the machine runs unattended.
--
-- Fields:
--   id           unique recipe identifier (string)
--   name         display name shown in the compound plan panel
--   type         machine type: "press" | "mix" | "fan_wash" | ...
--                (used for the [PRESS] / [MIX] label in the UI)
--   station      Create frogport/packager address the package is
--                sent to (must match the label on the receiving
--                packager at the processing machine)
--   output       item id this recipe produces
--   output_count how many output items are produced per craft
--   ingredients  list of { item=<item_id>, count=<number> }
--
-- To add a recipe: duplicate an existing entry and change the fields.
-- The `station` name must match the frogport address label you set
-- on the Create packager next to the processing machine.

return {

    -- ================================================================
    --  MECHANICAL PRESS  --  Pressing
    --  station address: "press_station"
    --  Feed raw ingot -> machine presses -> returns flat sheet.
    -- ================================================================

    {
        id="press_copper_sheet",  name="Copper Sheet",
        type="press",  station="press_station",
        output="create:copper_sheet",  output_count=1,
        ingredients = { {item="minecraft:copper_ingot", count=1} },
    },
    {
        id="press_iron_sheet",  name="Iron Sheet",
        type="press",  station="press_station",
        output="create:iron_sheet",  output_count=1,
        ingredients = { {item="minecraft:iron_ingot", count=1} },
    },
    {
        id="press_gold_sheet",  name="Gold Sheet",
        type="press",  station="press_station",
        output="create:gold_sheet",  output_count=1,
        ingredients = { {item="minecraft:gold_ingot", count=1} },
    },
    {
        id="press_zinc_sheet",  name="Zinc Sheet",
        type="press",  station="press_station",
        output="create:zinc_sheet",  output_count=1,
        ingredients = { {item="create:zinc_ingot", count=1} },
    },
    {
        id="press_brass_sheet",  name="Brass Sheet",
        type="press",  station="press_station",
        output="create:brass_sheet",  output_count=1,
        ingredients = { {item="create:brass_ingot", count=1} },
    },

    -- ================================================================
    --  MECHANICAL MIXER  --  Alloying  (requires heat source)
    --  station address: "mixer_station"
    -- ================================================================

    {
        id="mix_brass_ingot",  name="Brass Ingot",
        type="mix",  station="mixer_station",
        output="create:brass_ingot",  output_count=3,
        ingredients = {
            {item="minecraft:copper_ingot", count=2},
            {item="create:zinc_ingot",      count=1},
        },
    },
    {
        id="mix_andesite_alloy",  name="Andesite Alloy",
        type="mix",  station="mixer_station",
        output="create:andesite_alloy",  output_count=2,
        ingredients = {
            {item="minecraft:iron_nugget", count=1},
            {item="minecraft:andesite",    count=1},
        },
    },

    -- ================================================================
    --  Add more entries here as you build new processing stations.
    -- ================================================================
}
