-- ============================================================
--  config.lua  --  PROCESSING STATION COMPUTER
--
--  Place this file as "config.lua" on a processing station
--  computer, then run processing_station.lua.
-- ============================================================

local cfg = {}

cfg.role         = "processing_station"
cfg.protocol     = "CRAFT_NET"

-- Must match the `station` field in processing.lua and the Create
-- address that receives the incoming ingredient package.
cfg.station_name = "press_station"

-- Barrel that receives the processed machine output.
-- Keep this barrel dedicated to one active order at a time.
cfg.output_barrel = "minecraft:barrel_0"

-- Return packager sends the completed package back to home.
cfg.return_packager_name = "Create_Packager_2"
cfg.home_address         = "home frogport"

-- Seconds to wait for the processing machine to finish a request.
cfg.process_timeout = 300

return cfg
