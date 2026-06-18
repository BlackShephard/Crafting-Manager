-- ============================================================
--  config.lua  —  CRAFTING STATION COMPUTER  (ID: 6)
--
--  PHYSICAL FLOW (Create automation, no CC involvement):
--    Frog port → barrel → Repackager → belt → Packager → Crafter
--
--  CC involvement:
--    • Detect craft completion (poll output barrel)
--    • Push output barrel → return Packager → makePackage home
--
--  Place this file as "config.lua" on the crafting computer.
-- ============================================================

local cfg = {}

cfg.role                 = "station"
cfg.protocol             = "CRAFT_NET"

cfg.station_name         = "cogwheel_station"
cfg.server_id            = 7

-- Staging barrel: Repackager must face THIS barrel directly.
-- CC reads items from here and places them into specific crafter slots.
cfg.input_chest          = "minecraft:barrel_1"   -- frogport input barrel

-- Mechanical Crafter peripheral name (the connected 3×3 network).
-- Must be the wired-modem name (not a side) so pushItems works between
-- two wired-network inventories, as required by the CC inventory API.
cfg.crafter_name         = "create:mechanical_crafter_0"

-- Barrel that receives the crafter's output.
cfg.output_barrel        = "minecraft:barrel_0"   -- output barrel

-- Return packager sends finished goods back to the home vault.
cfg.return_packager_name = "Create_Packager_2"
cfg.home_address         = "home frogport"   -- ← set to your actual home frog port address

-- Side of the station computer that outputs redstone to the crafter.
-- Used to pulse a "force craft" signal after items arrive.
-- Valid sides: "top", "bottom", "left", "right", "front", "back"
-- Set to nil to disable (if crafter triggers automatically).
cfg.redstone_side        = "right"   -- ← set to the side facing the crafter

-- Seconds to wait after a craft request before pulsing redstone.
-- Give the belt/packager time to load items into the crafter.
cfg.redstone_delay       = 3

return cfg
