-- ============================================================
--  config.lua  --  CASING / DEPLOYER STATION COMPUTER
--
--  Place this file as "config.lua" on the casing station computer,
--  then run casing_station.lua.
-- ============================================================

local cfg = {}

cfg.role         = "casing_station"
cfg.protocol     = "CRAFT_NET"

-- Must match processing.lua casing recipes and the incoming package address.
cfg.station_name = "casing_station"

-- Incoming packages unpack here.
cfg.input_barrel = "minecraft:barrel_0"

-- The connected Create deployer inventory/hand.
cfg.deployer_name = "create:deployer_0"

-- The connected Create depot holding the stripped log being deployed onto.
cfg.depot_name = "create:depot_0"

-- Finished casings are moved here, next to the return packager.
cfg.output_barrel = "minecraft:barrel_1"

-- Return packager sends completed casings back to home.
cfg.return_packager_name = "Create_Packager_2"
cfg.home_address         = "home frogport"

-- The deployer hand and depot can each hold up to one stack.
cfg.deployer_capacity = 64
cfg.depot_capacity    = 64
cfg.batch_size        = 64

-- Seconds to wait for incoming package items and casing output.
cfg.input_timeout = 60
cfg.process_timeout = 300
cfg.slot_clear_timeout = 30

-- Packaging timing/retry settings.
cfg.package_settle_delay = 1
cfg.package_attempts = 3
cfg.package_drain_timeout = 10

-- Which material goes into the deployer hand for each casing output.
cfg.materials_by_output = {
    ["create:andesite_casing"] = "create:andesite_alloy",
    ["create:brass_casing"]    = "create:brass_ingot",
    ["create:copper_casing"]   = "minecraft:copper_ingot",
}

return cfg
