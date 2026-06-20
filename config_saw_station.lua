-- ============================================================
--  config.lua  --  SAW ROUTING STATION COMPUTER
--
--  Place this file as "config.lua" on the saw station computer,
--  then run saw_station.lua.
-- ============================================================

local cfg = {}

cfg.role         = "saw_station"
cfg.protocol     = "CRAFT_NET"

-- Must match the `station` field in processing.lua saw recipes and
-- the Create address that receives incoming ingredient packages.
cfg.station_name = "saw_station"

-- Incoming packages unpack here. This computer pushes ingredients
-- from this barrel into the selected saw.
cfg.input_barrel = "minecraft:barrel_0"

-- All saw outputs must be physically collected into this barrel.
cfg.output_barrel = "minecraft:barrel_1"

-- Allowed saw byproducts may be returned home in the same package
-- as the requested output. Other unexpected items still fail the job.
cfg.byproduct_items = {
    ["farmersdelight:tree_bark"] = true,
}
cfg.byproduct_patterns = {
    "^farmersdelight:.*bark$",
}

-- Return packager sends the completed package back to home.
cfg.return_packager_name = "Create_Packager_2"
cfg.home_address         = "home frogport"

-- Seconds to wait for incoming package items and saw output.
cfg.input_timeout   = 60
cfg.process_timeout = 300

-- Packaging timing/retry settings.
cfg.package_settle_delay = 1
cfg.package_attempts = 3
cfg.package_drain_timeout = 10

-- Category -> saw peripheral. Each saw should be physically filtered/setup
-- for the matching output category.
cfg.routes = {
    door           = "create:saw_1",
    fence          = "create:saw_2",
    fence_gate     = "create:saw_3",
    slab           = "create:saw_4",
    stripped_log   = "create:saw_5",
    stair          = "create:saw_6",
    stripped_wood  = "create:saw_7",
    wood           = "create:saw_8",
    trapdoor       = "create:saw_9",
    plank          = "create:saw_10",
    sign           = "create:saw_11",
    pressure_plate = "create:saw_12",
    button         = "create:saw_13",
}

-- Optional per-recipe override when output-name inference is not enough.
-- Example:
-- cfg.recipe_routes = {
--     saw_oak_planks = "plank",
-- }
cfg.recipe_routes = {}

return cfg
