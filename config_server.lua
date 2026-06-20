-- ============================================================
--  config.lua  —  HOME / VAULT / SERVER COMPUTER  (ID: 7)
--
--  Place this file as "config.lua" on the home computer.
-- ============================================================

local cfg = {}

cfg.role            = "server"
cfg.protocol        = "CRAFT_NET"

cfg.vault_name           = "create:item_vault_0"
cfg.packager_name        = "Create_Packager_1"
cfg.dispatch_barrel_name = "minecraft:barrel_0"   -- barrel adjacent to the outgoing Packager
-- Legacy/default station address. Mechanical station dispatch now uses the
-- address registered by each station, normally matching cfg.station_name.
cfg.station_address      = "Crafting_Station_1"
cfg.monitor_name         = "monitor_1"
cfg.stock_ticker_name    = "Create_StockTicker_0"

-- After a station reports DONE, wait briefly for the return package to
-- actually arrive in the vault before advancing dependent queue steps.
cfg.return_arrival_timeout = 20
cfg.return_arrival_scan_interval = 0.5

return cfg
