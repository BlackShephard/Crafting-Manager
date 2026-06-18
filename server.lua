-- ============================================================
--  server.lua  --  Vault Inventory Manager & Crafting Dispatcher
--
--  PHYSICAL SETUP (this computer needs):
--    . Wired modem  -> Create Item Vault
--    . Wired modem  -> Create Packager (outgoing ingredients)
--    . Wired modem  -> Monitor
--    . Ender Modem  -> wireless rednet to station computer(s)
--
--  FLOW:
--    1. User taps recipe on monitor
--    2. This script pulls ingredients from vault -> pushes into
--       the Packager -> Create transports the package to the
--       crafting station automatically
--    3. Station computer sends DONE when crafting is complete
--    4. Create transports finished goods back to vault
--       automatically (no CC involvement needed on return)
--    5. Vault display refreshes
--
--  SETUP:
--    1. Copy config_template.lua -> config.lua, set role="server"
--    2. Copy recipes.lua to this computer
--    3. Run this script, or add to startup.lua:
--         shell.run("server.lua")
-- ============================================================

local cfg  = dofile("config.lua")
local recipes = dofile("recipes.lua")
-- Non-crafter processing recipes (press, mixer, etc.).
-- Safe to load even if file is absent (returns empty table).
local proc = (function()
    if fs.exists("processing.lua") then return dofile("processing.lua") end
    return {}
end)()

-- Min-stock targets: load from minstock.lua, persists across reboots
local minStock = {}
if fs.exists("minstock.lua") then
    local ok, t = pcall(dofile, "minstock.lua")
    if ok and type(t) == "table" then minStock = t end
end

local function saveMinStock()
    local f = io.open("minstock.lua", "w")
    if not f then return end
    f:write("return {\n")
    for item, n in pairs(minStock) do
        f:write(('  ["%s"] = %d,\n'):format(item, n))
    end
    f:write("}\n")
    f:close()
end
local PROTO   = cfg.protocol or "CRAFT_NET"

-- Peripherals

local vault, mon, packager, dispatchBarrel, stockTicker
local monName = ""

local function findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m.isWireless() then return name end
        end
    end
    return nil
end

local function boot()
    local function findOrWrap(ptype, cfgName, label)
        local p = peripheral.find(ptype)
        if p then return p end
        if cfgName then
            p = peripheral.wrap(cfgName)
            if p then return p end
        end
        error(label .. " not found (type: " .. ptype .. ")"
              .. "\n  Run discover.lua to list connected peripherals.")
    end

    vault    = findOrWrap("create:item_vault",   cfg.vault_name,    "Item Vault")
    packager = findOrWrap("Create_Packager", cfg.packager_name, "Packager")

    dispatchBarrel = peripheral.wrap(cfg.dispatch_barrel_name)
    assert(dispatchBarrel,
        "Dispatch barrel not found (cfg.dispatch_barrel_name = "
        .. tostring(cfg.dispatch_barrel_name) .. ")")

    stockTicker = peripheral.find("Create_StockTicker")
                  or (cfg.stock_ticker_name
                      and peripheral.wrap(cfg.stock_ticker_name))
    if stockTicker then print("[server] Stock Ticker found.") end

    mon = peripheral.find("monitor")
    if not mon and cfg.monitor_name then
        mon = peripheral.wrap(cfg.monitor_name)
        monName = cfg.monitor_name or ""
    elseif mon then
        monName = peripheral.getName(mon)
    end
    assert(mon, "No monitor found. Connect a monitor via wired modem.")
    mon.setTextScale(0.5)

    local modem = findWirelessModem()
    assert(modem, "No wireless/ender modem found on this computer!")
    rednet.open(modem)

    print("[server] Online. Computer ID: " .. os.computerID())
end

-- Inventory

local invItems = {}

local function scanVault()
    local merged = {}
    for _, it in pairs(vault.list()) do
        if merged[it.name] then
            merged[it.name].count = merged[it.name].count + it.count
        else
            merged[it.name] = {
                name        = it.name,
                displayName = it.displayName
                              or it.name:match(":(.+)") or it.name,
                count       = it.count,
            }
        end
    end
    invItems = {}
    for _, v in pairs(merged) do invItems[#invItems + 1] = v end
    table.sort(invItems, function(a, b)
        return a.displayName:lower() < b.displayName:lower()
    end)
end

-- Tag-to-item resolution for unresolved recipe tags.
-- Both `c:` (NeoForge common) and `o:` (ore-dict compat) prefixes are mapped.
-- Add entries here whenever a recipe shows a tag name instead of an item ID.
local TAG_MAP = {
    -- Dusts
    ["c:dusts/redstone"]         = "minecraft:redstone",
    ["o:dusts/redstone"]         = "minecraft:redstone",
    ["c:dusts/glowstone"]        = "minecraft:glowstone_dust",
    ["o:dusts/glowstone"]        = "minecraft:glowstone_dust",
    -- Rods / sticks
    ["c:rods/wooden"]            = "minecraft:stick",
    ["o:rods/wooden"]            = "minecraft:stick",
    ["c:rods/blaze"]             = "minecraft:blaze_rod",
    ["o:rods/blaze"]             = "minecraft:blaze_rod",
    -- Ingots
    ["c:ingots/iron"]            = "minecraft:iron_ingot",
    ["o:ingots/iron"]            = "minecraft:iron_ingot",
    ["c:ingots/gold"]            = "minecraft:gold_ingot",
    ["o:ingots/gold"]            = "minecraft:gold_ingot",
    ["c:ingots/copper"]          = "minecraft:copper_ingot",
    ["o:ingots/copper"]          = "minecraft:copper_ingot",
    ["c:ingots/zinc"]            = "create:zinc_ingot",
    ["o:ingots/zinc"]            = "create:zinc_ingot",
    ["c:ingots/brass"]           = "create:brass_ingot",
    ["o:ingots/brass"]           = "create:brass_ingot",
    -- Nuggets
    ["c:nuggets/iron"]           = "minecraft:iron_nugget",
    ["o:nuggets/iron"]           = "minecraft:iron_nugget",
    ["c:nuggets/gold"]           = "minecraft:gold_nugget",
    ["o:nuggets/gold"]           = "minecraft:gold_nugget",
    -- Gems
    ["c:gems/diamond"]           = "minecraft:diamond",
    ["o:gems/diamond"]           = "minecraft:diamond",
    ["c:gems/emerald"]           = "minecraft:emerald",
    ["o:gems/emerald"]           = "minecraft:emerald",
    ["c:gems/lapis"]             = "minecraft:lapis_lazuli",
    ["o:gems/lapis"]             = "minecraft:lapis_lazuli",
    ["c:gems/quartz"]            = "minecraft:quartz",
    ["o:gems/quartz"]            = "minecraft:quartz",
    -- Stones / blocks
    ["c:stones"]                 = "minecraft:stone",
    ["o:stones"]                 = "minecraft:stone",
    ["c:cobblestones"]           = "minecraft:cobblestone",
    ["o:cobblestones"]           = "minecraft:cobblestone",
    ["c:cobblestones/normal"]    = "minecraft:cobblestone",
    ["c:glass/colorless"]        = "minecraft:glass",
    ["o:glass"]                  = "minecraft:glass",
    ["c:glass_panes/colorless"]  = "minecraft:glass_pane",
    ["o:paneGlass"]              = "minecraft:glass_pane",
    -- Create-specific
    ["c:andesite_alloys"]        = "create:andesite_alloy",
    ["c:cogwheels"]              = "create:cogwheel",
    ["c:large_cogwheels"]        = "create:large_cogwheel",
    ["c:brass_sheets"]           = "create:brass_sheet",
    ["c:copper_sheets"]          = "create:copper_sheet",
    ["c:iron_sheets"]            = "create:iron_sheet",
    ["c:zinc_sheets"]            = "create:zinc_sheet",
    -- Dyes
    ["c:dyes/red"]               = "minecraft:red_dye",
    ["c:dyes/blue"]              = "minecraft:blue_dye",
    ["c:dyes/green"]             = "minecraft:green_dye",
    ["c:dyes/yellow"]            = "minecraft:yellow_dye",
    ["c:dyes/black"]             = "minecraft:black_dye",
    ["c:dyes/white"]             = "minecraft:white_dye",
    ["c:dyes/purple"]            = "minecraft:purple_dye",
    ["c:dyes/orange"]            = "minecraft:orange_dye",
    ["c:dyes/pink"]              = "minecraft:pink_dye",
    ["c:ender_pearls"]          = "minecraft:ender_pearl",
    ["c:slimeballs"]            = "minecraft:slime_ball",
    ["c:strings"]               = "minecraft:string",
    ["c:crops/wheat"]           = "minecraft:wheat",
    ["c:crop/wheat"]            = "minecraft:wheat",
    ["c:crops/potato"]          = "minecraft:potato",
    ["c:dyes/pink"]             = "minecraft:pink_dye",
}

-- Resolve a tag name or item ID to a concrete item ID.
local function resolveItem(name)
    if type(name) ~= "string" then return name end
    local key = name:gsub("^TODO:", "")
    return TAG_MAP[key] or key:match("^([^:]+:[^:]+)$") or key
end

local function itemKey(name)
    local resolved = resolveItem(name)
    if type(resolved) ~= "string" then return resolved end
    return resolved:gsub("^minecraft:", ""):gsub("^create:", "")
end

local function isGenericPlanksTag(name)
    if type(name) ~= "string" then return false end
    local key = name:gsub("^TODO:", "")
    return key == "c:planks" or key == "o:planks"
end

local function isPlankItem(name)
    local key = itemKey(name)
    return type(key) == "string" and key:sub(-7) == "_planks"
end

local function stockOf(itemName)
    if isGenericPlanksTag(itemName) then
        local total = 0
        for _, it in ipairs(invItems) do
            if isPlankItem(it.name) then
                total = total + it.count
            end
        end
        return total
    end
    local resolved = itemKey(itemName)
    for _, it in ipairs(invItems) do
        if itemKey(it.name) == resolved then return it.count end
    end
    return 0
end

-- Fixed: merges duplicate ingredient entries (e.g. shaft needs 2x andesite_alloy)
local function canCraft(rec, qty)
    qty = qty or 1
    local needed = {}
    for _, ing in ipairs(rec.ingredients) do
        local item = isGenericPlanksTag(ing.item) and "<any_planks>" or itemKey(ing.item)
        needed[item] = (needed[item] or 0) + ing.count * qty
    end
    for item, n in pairs(needed) do
        local have = item == "<any_planks>" and stockOf("c:planks") or stockOf(item)
        if have < n then return false end
    end
    return true
end

-- Item dispatch

local function requestItems(recipe, qty)
    local needed = {}
    local order  = {}
    for _, ing in ipairs(recipe.ingredients) do
        local item = isGenericPlanksTag(ing.item) and "<any_planks>" or itemKey(ing.item)
        if needed[item] then
            needed[item] = needed[item] + ing.count * qty
        else
            needed[item] = ing.count * qty
            order[#order + 1] = item
        end
    end

    for slot in pairs(dispatchBarrel.list()) do
        dispatchBarrel.pushItems(cfg.vault_name, slot)
    end

    for _, item in ipairs(order) do
        local count    = needed[item]
        local realItem = item == "<any_planks>" and nil or resolveItem(item)
        local moved    = 0
        for slot, stack in pairs(vault.list()) do
            if moved >= count then break end
            local stackKey = itemKey(stack.name)
            local matches = false
            if item == "<any_planks>" then
                matches = isPlankItem(stack.name)
            else
                matches = stackKey == itemKey(realItem)
            end
            if matches then
                local n = vault.pushItems(
                    cfg.dispatch_barrel_name, slot,
                    math.min(count - moved, stack.count))
                moved = moved + n
            end
        end
        if moved < count then
            for slot in pairs(dispatchBarrel.list()) do
                dispatchBarrel.pushItems(cfg.vault_name, slot)
            end
            local missingName = item == "<any_planks>" and "planks" or realItem
            return false,
                ("Not enough %s: need %d, have %d"):format(missingName, count, moved)
        end
    end

    os.sleep(0.5)
    local addr = cfg.station_address
    packager.setAddress(addr)
    local ok, err = pcall(packager.makePackage)
    if not ok then
        return false, "makePackage failed: " .. tostring(err)
    end

    print(("[dispatch] Sent package to %s"):format(addr))
    return true
end

-- Send raw materials to a processing machine (press, mixer, etc.).
-- The machine transforms them and routes output back to vault via Create
-- logistics -- no CC station handshake or busy-tracking needed.
local function dispatchProcess(rec, qty)
    -- Temporarily redirect the packager to the processing station address
    local savedAddr = cfg.station_address
    cfg.station_address = rec.station
    local ok, err = requestItems(rec, qty)
    cfg.station_address = savedAddr
    if not ok then
        ui.status = "ERROR (process): " .. err
        return false
    end
    local typeLabel = (rec.type or "process"):upper()
    ui.status = ("[%s] Sent: %s x%d -> %s"):format(
        typeLabel, rec.name, qty * (rec.output_count or 1), rec.station)
    return true
end

-- Network state

-- stations[name] = { id = computerID, busy = false }
local stations = {}
-- pending[reqID] = { recipe, qty, sid, stationName }
local pending  = {}
local nextID   = 1
local queue    = {}   -- { rec, qty }

local function findFreeStation(preferredName)
    if preferredName and stations[preferredName]
            and not stations[preferredName].busy then
        return preferredName, stations[preferredName].id
    end
    for name, st in pairs(stations) do
        if not st.busy then return name, st.id end
    end
    return nil, nil
end

local function countStations()
    local total, free = 0, 0
    for _, st in pairs(stations) do
        total = total + 1
        if not st.busy then free = free + 1 end
    end
    return total, free
end

-- UI state (defined early so dispatch functions can reference it)

local ui = {
    tab         = "craft",   -- "craft" | "queue"
    invSel      = 1,
    invScroll   = 0,
    recSel      = 1,
    recScroll   = 0,
    qty         = 1,
    status      = "Booting...",
    showDetail  = false,
    -- Search
    search      = "",
    searchMode  = false,
    -- Queue tab
    queueSel    = 0,
    -- Partial order confirm: nil or { rec, canMake, requested, missing }
    confirm     = nil,
    -- Compound craft plan: nil or { rec, qty, plan=[{rec,qty},...] }
    compoundPlan = nil,
    -- Min-stock editor
    invDetail   = false,   -- true when editor is open for selected inv item
    minQty      = 0,       -- qty being configured in the editor
}

-- Dispatch (defined before touch handlers need it)

local function dispatchCraft(rec, qty)
    local stName, sid = findFreeStation(rec.station)
    if not stName then
        ui.status = "ERROR: no station online"
        return false
    end

    stations[stName].busy = true

    local ok, err = requestItems(rec, qty)
    if not ok then
        stations[stName].busy = false
        ui.status = "ERROR: " .. err
        return false
    end

    local id = nextID
    nextID   = nextID + 1
    pending[id] = { recipe = rec, qty = qty, sid = sid, stationName = stName }

    rednet.send(sid, {
        type   = "REQUEST",
        id     = id,
        recipe = rec.id,
        count  = qty,
    }, PROTO)

    local _, freeN = countStations()
    local qStr = #queue > 0 and ("  Q:" .. #queue) or ""
    ui.status = ("Sent: %s x%d -> %s  (%d free%s)"):format(
        rec.name, qty, stName, freeN, qStr)
    return true
end

local function tryDispatchNext()
    local i = 1
    while i <= #queue do
        local job = queue[i]
        if not canCraft(job.rec, job.qty) then
            -- Ingredients not ready yet; leave in queue
            i = i + 1
        elseif job.rec.type == "press"
            or job.rec.type == "mix"
            or job.rec.type == "deploy"
            or job.rec.type == "fan_wash"
            or job.rec.type == "fan_haunt"
            or job.rec.type == "fan_cool"
            or job.rec.type == "process" then
            -- Processing job: no CC station needed, dispatch directly
            table.remove(queue, i)
            if ui.queueSel >= i then
                ui.queueSel = math.max(0, ui.queueSel - 1)
            end
            dispatchProcess(job.rec, job.qty)
            -- i unchanged; re-check same position (now holds next job)
        else
            -- Mechanical crafter job: needs a free CC station
            local stName = findFreeStation()
            if not stName then
                i = i + 1  -- no station free; skip for now
            else
                table.remove(queue, i)
                if ui.queueSel >= i then
                    ui.queueSel = math.max(0, ui.queueSel - 1)
                end
                dispatchCraft(job.rec, job.qty)
            end
        end
    end
end

-- Auto-replenish: queue compound plans for items below their min-stock target.
-- Skips items already being handled (in queue or pending).
local function checkMinStock()
    local anyQueued = false
    for item, minN in pairs(minStock) do
        if stockOf(item) < minN then
            local busy = false
            for _, job in ipairs(queue) do
                if itemKey(job.rec.output) == itemKey(item) then busy = true; break end
            end
            if not busy then
                for _, p in pairs(pending) do
                    if itemKey(p.recipe.output) == itemKey(item) then busy = true; break end
                end
            end
            if not busy then
                local needed = minN - stockOf(item)
                local plan = buildCraftPlan(item, needed)
                if #plan > 0 then
                    for _, job in ipairs(plan) do
                        queue[#queue + 1] = { rec = job.rec, qty = job.qty }
                    end
                    anyQueued = true
                    ui.status = ("Restocking: %s (+%d needed)"):format(
                        item:match(":(.+)") or item, needed)
                end
            end
        end
    end
    if anyQueued then tryDispatchNext() end
end

-- Recipe filtering

local filteredRec = recipes

local function buildFilteredRec(query)
    if not query or query == "" then
        filteredRec = recipes
        return
    end
    local q = query:lower()
    local t = {}
    for _, r in ipairs(recipes) do
        if r.name:lower():find(q, 1, true) then
            t[#t + 1] = r
        end
    end
    filteredRec = t
end

-- Partial order helpers

-- How many complete crafts can be made right now?
local function maxCraftable(rec)
    local needed = {}
    for _, ing in ipairs(rec.ingredients) do
        local item = itemKey(ing.item)
        needed[item] = (needed[item] or 0) + ing.count
    end
    if not next(needed) then return math.huge end
    local best = math.huge
    for item, perUnit in pairs(needed) do
        local n = math.floor(stockOf(item) / perUnit)
        if n < best then best = n end
    end
    return best
end

-- Returns list of { item, have, need, short } for a given qty
local function getMissing(rec, qty)
    local needed = {}
    for _, ing in ipairs(rec.ingredients) do
        local item = itemKey(ing.item)
        needed[item] = (needed[item] or 0) + ing.count * qty
    end
    local out = {}
    for item, need in pairs(needed) do
        local have = stockOf(item)
        if have < need then
            out[#out + 1] = {
                item  = item:match(":(.+)") or item,
                have  = have,
                need  = need,
                short = need - have,
            }
        end
    end
    table.sort(out, function(a, b) return a.short > b.short end)
    return out
end

-- Compound crafting helpers

-- Find the first recipe (crafter or processing) that outputs itemName
local function findRecipeFor(itemName)
    local key = itemKey(itemName)
    for _, r in ipairs(recipes) do
        if itemKey(r.output) == key then return r end
    end
    for _, r in ipairs(proc) do
        if itemKey(r.output) == key then return r end
    end
    return nil
end

-- Build an ordered list of {rec, qty} jobs needed to produce qty of itemName.
-- Jobs are in execution order: leaf dependencies first, final recipe last.
-- projected tracks items that earlier plan steps will produce, so we don't
-- over-plan the same ingredient twice.
local function buildCraftPlan(itemName, qty, plan, projected, depth)
    plan      = plan      or {}
    projected = projected or {}
    depth     = depth     or 0
    if depth > 10 then return plan end  -- cycle guard

    local rec = findRecipeFor(itemName)
    if not rec then return plan end

    -- For sub-ingredients (depth > 0): skip if vault already has enough.
    -- For the root item (depth == 0): always plan to make the full qty --
    -- the user explicitly asked to craft it, regardless of existing stock.
    local have
    if depth == 0 then
        have = projected[itemName] or 0
    else
        have = stockOf(itemName) + (projected[itemName] or 0)
    end
    local shortfall = qty - have
    if shortfall <= 0 then return plan end

    local crafts = math.ceil(shortfall / math.max(1, rec.output_count or 1))

    -- Register projected output before recursing (prevents over-planning)
    projected[itemName] = (projected[itemName] or 0)
                          + crafts * math.max(1, rec.output_count or 1)

    -- Recurse into each ingredient (dependencies before self)
    local needed = {}
    for _, ing in ipairs(rec.ingredients) do
        local item = itemKey(ing.item)
        needed[item] = (needed[item] or 0) + ing.count * crafts
    end
    for item, n in pairs(needed) do
        buildCraftPlan(item, n, plan, projected, depth + 1)
    end

    plan[#plan + 1] = { rec = rec, qty = crafts }
    return plan
end

-- Drawing helpers

local function mw(x, y, s, fg, bg)
    mon.setCursorPos(x, y)
    if fg then mon.setTextColor(fg)       end
    if bg then mon.setBackgroundColor(bg) end
    mon.write(s)
end

local function mfill(x, y, w, ch, fg, bg)
    if w <= 0 then return end
    mw(x, y, string.rep(ch or " ", w), fg, bg)
end

local function trunc(s, n)
    if n <= 0 then return "" end
    if #s <= n then
        return s .. string.rep(" ", n - #s)
    end
    return s:sub(1, n - 1) .. "~"
end

-- Colors

local C = {
    hdr   = colors.blue,      hdrTx = colors.white,
    sub   = colors.gray,      subTx = colors.yellow,
    sel   = colors.blue,      selTx = colors.white,
    ok    = colors.green,
    bad   = colors.red,
    dim   = colors.lightGray,
    bg    = colors.black,
    btn   = colors.orange,    btnTx = colors.black,
    stat  = colors.gray,
    warn  = colors.orange,
}

-- Draw: Header

local function drawHeader(W)
    mfill(1, 1, W, " ", C.hdrTx, C.hdr)
    mw(2, 1, "VAULT INVENTORY MANAGER", C.hdrTx, C.hdr)
    local total, free = countStations()
    local stStr = ("St:%d/%d"):format(free, total)
                  .. (#queue > 0 and (" Q:" .. #queue) or "") .. " "
    mw(W - #stStr + 1, 1, stStr,
       free > 0 and C.ok or (total > 0 and C.warn or C.bad), C.hdr)
end

-- Draw: Tab bar (row 2)

local function drawTabs(W)
    mfill(1, 2, W, " ", C.dim, colors.gray)

    local cBg = ui.tab == "craft" and C.hdr or colors.gray
    local cFg = ui.tab == "craft" and C.hdrTx or C.dim
    mw(2,  2, " CRAFT ", cFg, cBg)

    local qBg = ui.tab == "queue" and C.hdr or colors.gray
    local qFg = ui.tab == "queue" and C.hdrTx or C.dim
    mw(10, 2, " QUEUE ", qFg, qBg)

    -- Active search indicator shown in tab bar
    if ui.search ~= "" then
        local sLabel = "  [/" .. ui.search .. "]"
        mw(18, 2, trunc(sLabel, W - 18), colors.yellow, colors.gray)
    end
end

-- Draw: CRAFT tab

local function drawCraftTab(W, H)
    local invW  = math.floor(W * 0.54)
    local divX  = invW + 1
    local recX  = invW + 2
    local recW  = W - recX + 1
    local listH = H - 5   -- rows 4..(H-2)

    -- When the min-stock editor is open, shrink the visible list by 4 rows
    -- so the editor occupies the bottom of the inventory column.
    local invListH = (ui.invDetail and ui.invSel >= 1
                      and ui.invSel <= #invItems)
                     and math.max(2, listH - 4) or listH

    -- Sub-headers (row 3)
    -- Inventory: label + [^][v] scroll arrows at far right
    mfill(1, 3, invW, " ", C.subTx, C.sub)
    mw(2, 3, trunc(("ITEMS (%d)"):format(#invItems), invW - 8), C.subTx, C.sub)
    mw(invW - 6, 3, "[^]", C.btnTx, colors.gray)
    mw(invW - 3, 3, "[v]", C.btnTx, colors.gray)

    mw(divX, 3, "|", C.subTx, C.sub)

    -- Recipe: search display + [^][v] at far right
    mfill(recX, 3, recW, " ", C.subTx, C.sub)
    local recLabel
    if ui.searchMode then
        recLabel = "> " .. ui.search .. "_"
    elseif ui.search ~= "" then
        recLabel = "/" .. ui.search .. " (" .. #filteredRec .. ")  [tap=edit]"
    else
        recLabel = ("RECIPES (%d)  [tap=search]"):format(#filteredRec)
    end
    mw(recX, 3, trunc(recLabel, recW - 8),
       ui.searchMode and colors.yellow or C.subTx, C.sub)
    mw(W - 6, 3, "[^]", C.btnTx, colors.gray)
    mw(W - 3, 3, "[v]", C.btnTx, colors.gray)

    -- Inventory list (rows 4..H-2, shorter when min-stock editor is open)
    for row = 1, listH do
        local idx = row + ui.invScroll
        local y   = row + 3
        mfill(1, y, invW, " ", C.dim, C.bg)
        mw(divX, y, "|", C.sub, C.bg)
        if row <= invListH and idx <= #invItems then
            local it    = invItems[idx]
            local sel   = (idx == ui.invSel)
            local minN  = minStock[it.name]
            local below = minN and (it.count < minN)
            local fg    = sel and C.selTx
                          or (below and C.warn or C.dim)
            local bg    = sel and C.sel or C.bg
            mfill(1, y, invW, " ", fg, bg)
            local cnt  = "x" .. it.count .. (minN and ("/" .. minN) or "")
            local namW = invW - #cnt - 1
            mw(1,               y, trunc(it.displayName, namW), fg, bg)
            mw(invW - #cnt + 1, y, cnt,
               sel and colors.yellow or (below and C.warn or C.ok), bg)
        end
    end

    -- Min-stock editor panel (bottom 4 rows of inventory column)
    if ui.invDetail and ui.invSel >= 1 and ui.invSel <= #invItems then
        local it  = invItems[ui.invSel]
        local ey1 = invListH + 4   -- first editor y  (= row invListH+1 → y=row+3)
        local ey2 = ey1 + 1
        local ey3 = ey1 + 2
        local ey4 = ey1 + 3

        -- Header
        mfill(1, ey1, invW, " ", C.sub, C.sub)
        mw(2, ey1, trunc("MIN: " .. it.displayName, invW - 1), C.subTx, C.sub)

        -- Current stock info
        local minN = minStock[it.name] or 0
        mfill(1, ey2, invW, " ", C.dim, C.bg)
        mw(2, ey2, ("Have:%d  Min:%d"):format(it.count, minN), C.dim, C.bg)

        -- Step buttons:  [-8] [-1]  qty  [+1] [+8]
        mfill(1, ey3, invW, " ", C.dim, C.bg)
        mw(1,        ey3, "[-8]", C.btnTx, C.bad)
        mw(6,        ey3, "[-1]", C.btnTx, C.bad)
        local qStr = tostring(ui.minQty)
        mw(math.max(11, math.floor((invW - #qStr) / 2) + 1),
           ey3, qStr, colors.white, C.bg)
        mw(invW - 8, ey3, "[+1]", C.btnTx, C.ok)
        mw(invW - 3, ey3, "[+8]", C.btnTx, C.ok)

        -- SET / CLR buttons
        local half = math.floor(invW / 2)
        mfill(1, ey4, invW, " ", C.dim, C.bg)
        mfill(1,      ey4, half,       " ", C.btnTx, C.ok)
        mw(2,         ey4, "SET",           C.btnTx, C.ok)
        mfill(half+1, ey4, invW - half, " ", C.btnTx, C.bad)
        mw(half + 2,  ey4, "CLR",           C.btnTx, C.bad)
    end

    -- Recipe panel

    -- PARTIAL ORDER CONFIRM OVERLAY
    if ui.confirm then
        local c = ui.confirm
        mfill(recX, 4, recW, " ", C.warn, C.bg)
        mw(recX, 4, trunc("  ! PARTIAL ORDER WARNING", recW), C.warn, C.bg)
        mfill(recX, 5, recW, " ", C.dim, C.bg)
        mw(recX, 5, trunc(("  %s  x%d"):format(c.rec.name, c.requested), recW),
           colors.white, C.bg)
        mfill(recX, 6, recW, " ", C.dim, C.bg)
        if c.canMake > 0 then
            mw(recX, 6, trunc(
               ("  Can make %d of %d  (short by %d)"):format(
                   c.canMake, c.requested, c.requested - c.canMake),
               recW), C.ok, C.bg)
        else
            mw(recX, 6, trunc("  Cannot make any!", recW), C.bad, C.bg)
        end
        mfill(recX, 7, recW, " ", C.dim, C.bg)
        mw(recX, 7, trunc("  Missing resources:", recW), C.dim, C.bg)
        local iy = 8
        for i, m in ipairs(c.missing) do
            if iy > H - 3 then
                mfill(recX, iy, recW, " ", C.dim, C.bg)
                mw(recX, iy, trunc(
                   ("  ...and %d more"):format(#c.missing - i + 1),
                   recW), C.dim, C.bg)
                iy = iy + 1
                break
            end
            mfill(recX, iy, recW, " ", C.dim, C.bg)
            mw(recX, iy, trunc(
               ("  need x%d more %s  (have %d)"):format(
                   m.short, m.item, m.have),
               recW), C.bad, C.bg)
            iy = iy + 1
        end
        while iy <= H - 3 do
            mfill(recX, iy, recW, " ", C.dim, C.bg)
            iy = iy + 1
        end
        -- Buttons (row H-2)
        local btnY = H - 2
        mfill(recX, btnY, recW, " ", C.dim, C.bg)
        if c.canMake > 0 then
            local lbl = (" CRAFT %d "):format(c.canMake)
            mw(recX, btnY, lbl, C.btnTx, C.ok)
        end
        mw(W - 9, btnY, " CANCEL ", C.btnTx, C.bad)
        return
    end

    -- COMPOUND CRAFT PLAN OVERLAY
    if ui.compoundPlan then
        local cp = ui.compoundPlan
        mfill(recX, 4, recW, " ", colors.cyan, C.bg)
        mw(recX, 4, trunc("  COMPOUND CRAFT PLAN", recW), colors.cyan, C.bg)
        mfill(recX, 5, recW, " ", C.dim, C.bg)
        mw(recX, 5, trunc(("  Target: %s x%d"):format(cp.rec.name, cp.qty), recW),
           colors.white, C.bg)
        mfill(recX, 6, recW, " ", C.dim, C.bg)
        mw(recX, 6, trunc(("  %d craft step(s):"):format(#cp.plan), recW), C.dim, C.bg)
        local iy = 7
        for si, job in ipairs(cp.plan) do
            if iy > H - 3 then
                mfill(recX, iy, recW, " ", C.dim, C.bg)
                mw(recX, iy, trunc(
                   ("  ...and %d more step(s)"):format(#cp.plan - si + 1),
                   recW), C.dim, C.bg)
                iy = iy + 1
                break
            end
            local isTarget  = (si == #cp.plan)
            local making    = job.qty * math.max(1, job.rec.output_count or 1)
            local have      = stockOf(job.rec.output)
            local typeLabel = job.rec.type and ("[%s] "):format((job.rec.type):upper()) or ""
            mfill(recX, iy, recW, " ", C.dim, C.bg)
            mw(recX, iy, trunc(
               ("  %d. %s%s x%d  (have %d)"):format(
                   si, typeLabel, job.rec.name, making, have),
               recW), isTarget and colors.yellow or C.ok, C.bg)
            iy = iy + 1
        end
        while iy <= H - 3 do
            mfill(recX, iy, recW, " ", C.dim, C.bg)
            iy = iy + 1
        end
        -- Buttons (row H-2)
        local btnY = H - 2
        mfill(recX, btnY, recW, " ", C.dim, C.bg)
        mw(recX,  btnY, " QUEUE ALL ", C.btnTx, C.ok)
        mw(W - 9, btnY, " CANCEL ",   C.btnTx, C.bad)
        return
    end

    -- RECIPE LIST / DETAIL VIEW
    local rec = filteredRec[ui.recSel]

    if ui.showDetail and rec then
        -- Top portion: scrollable recipe list
        local topH = math.max(2, math.floor(listH * 0.45))
        for row = 1, topH do
            local idx = row + ui.recScroll
            local y   = row + 3
            mfill(recX, y, recW, " ", C.dim, C.bg)
            if idx <= #filteredRec then
                local r   = filteredRec[idx]
                local sel = (idx == ui.recSel)
                local fg  = sel and C.selTx
                            or (canCraft(r, ui.qty) and C.ok or C.bad)
                local bg  = sel and C.sel or C.bg
                mfill(recX, y, recW, " ", fg, bg)
                mw(recX, y, trunc(r.name, recW), fg, bg)
            end
        end
        -- Divider
        local divY = 3 + topH + 1
        if divY <= H - 3 then
            mfill(recX, divY, recW, "-", C.subTx, C.bg)
            mw(recX, divY, trunc(" " .. rec.name .. " ", recW), C.subTx, C.sub)
        end
        -- Ingredient list
        local ingY = divY + 1
        for i, ing in ipairs(rec.ingredients) do
            local y = ingY + i - 1
            if y > H - 3 then break end
            local itemName = resolveItem(ing.item)
            local have = stockOf(itemName)
            local need = ing.count * ui.qty
            local fg   = have >= need and C.ok or C.bad
            mfill(recX, y, recW, " ", fg, C.bg)
            mw(recX, y, trunc(
               ("  x%d %s  (have %d)"):format(
                   need, itemName:match(":(.+)") or itemName, have),
               recW), fg, C.bg)
        end
        -- CRAFT button row (H-2)
        local btnY   = H - 2
        local canAll = canCraft(rec, ui.qty)
        local cm     = maxCraftable(rec)
        local tot, freeN = countStations()
        -- Green=full OK, Orange=partial possible, Gray=none/no stations
        local btnColor = canAll   and C.btn
                      or (cm > 0  and C.warn or colors.gray)
        if tot == 0 then btnColor = colors.gray end

        mfill(recX, btnY, recW, " ", C.dim, C.bg)
        mw(recX,     btnY, "[-]", C.btnTx, colors.gray)
        mw(W - 2,    btnY, "[+]", C.btnTx, colors.gray)
        local lbl = (" CRAFT x%d "):format(ui.qty)
        local bX  = recX + 3 + math.floor((recW - 6 - #lbl) / 2)
        mw(bX, btnY, lbl, C.btnTx, btnColor)

        -- Hint line (H-3)
        mfill(recX, H - 3, recW, " ", C.dim, C.bg)
        if tot == 0 then
            mw(recX, H - 3, trunc(" No stations online", recW), C.bad, C.bg)
        elseif not canAll and cm > 0 then
            mw(recX, H - 3,
               trunc((" ! Can only make %d of %d -- tap CRAFT for details"):format(cm, ui.qty), recW),
               C.warn, C.bg)
        elseif not canAll and cm == 0 then
            mw(recX, H - 3,
               trunc(" ! Insufficient resources -- tap CRAFT for details", recW),
               C.bad, C.bg)
        elseif freeN == 0 then
            mw(recX, H - 3,
               trunc((" All %d busy -- will queue"):format(tot), recW),
               C.warn, C.bg)
        end
    else
        -- Plain recipe list
        for row = 1, listH do
            local idx = row + ui.recScroll
            local y   = row + 3
            mfill(recX, y, recW, " ", C.dim, C.bg)
            if idx <= #filteredRec then
                local r   = filteredRec[idx]
                local sel = (idx == ui.recSel)
                local fg  = sel and C.selTx
                            or (canCraft(r, ui.qty) and C.ok or C.bad)
                local bg  = sel and C.sel or C.bg
                mfill(recX, y, recW, " ", fg, bg)
                mw(recX, y, trunc(r.name, recW), fg, bg)
            end
        end
    end
end

-- Draw: QUEUE tab

local function drawQueueTab(W, H)
    local leftW  = math.floor(W * 0.48)
    local divX   = leftW + 1
    local rightX = leftW + 2
    local rightW = W - rightX + 1
    local listH  = H - 5

    -- Sub-headers (row 3)
    local pendCount = 0
    for _ in pairs(pending) do pendCount = pendCount + 1 end

    mfill(1,      3, leftW, " ", C.subTx, C.sub)
    mw(2, 3, ("ACTIVE (%d)"):format(pendCount), C.subTx, C.sub)
    mw(divX, 3, "|", C.subTx, C.sub)
    mfill(rightX, 3, rightW, " ", C.subTx, C.sub)
    mw(rightX, 3, ("WAITING QUEUE (%d)"):format(#queue), C.subTx, C.sub)

    -- Left: station status + in-progress jobs
    local y = 4

    for name, st in pairs(stations) do
        if y > 3 + listH then break end
        local fg  = st.busy and C.warn or C.ok
        local tag = st.busy and "BUSY" or "FREE"
        mfill(1, y, leftW, " ", fg, C.bg)
        mw(2, y, trunc(("[%s] %s"):format(tag, name), leftW - 1), fg, C.bg)
        mw(divX, y, "|", C.sub, C.bg)
        y = y + 1
    end

    local pendList = {}
    for id, job in pairs(pending) do
        pendList[#pendList + 1] = { id = id, job = job }
    end
    table.sort(pendList, function(a, b) return a.id < b.id end)

    if #pendList > 0 and y <= 3 + listH then
        mfill(1, y, leftW, " ", C.dim, C.bg)
        mw(2, y, "--- crafting ---", C.dim, C.bg)
        mw(divX, y, "|", C.sub, C.bg)
        y = y + 1
        for _, p in ipairs(pendList) do
            if y > 3 + listH then break end
            mfill(1, y, leftW, " ", colors.yellow, C.bg)
            mw(2, y, trunc(
               ("%s x%d"):format(p.job.recipe.name, p.job.qty),
               leftW - 1), colors.yellow, C.bg)
            mw(divX, y, "|", C.sub, C.bg)
            y = y + 1
        end
    end

    while y <= 3 + listH do
        mfill(1, y, leftW, " ", C.dim, C.bg)
        mw(divX, y, "|", C.sub, C.bg)
        y = y + 1
    end

    -- Right: waiting queue
    for row = 1, listH do
        local ry = row + 3
        mfill(rightX, ry, rightW, " ", C.dim, C.bg)
        if row <= #queue then
            local job = queue[row]
            local sel = (row == ui.queueSel)
            local fg  = sel and C.selTx or colors.white
            local bg  = sel and C.sel   or C.bg
            mfill(rightX, ry, rightW, " ", fg, bg)
            mw(rightX, ry, trunc(
               ("%d. %s x%d"):format(row, job.rec.name, job.qty),
               rightW), fg, bg)
        end
    end

    -- Action row (H-2)
    local btnY = H - 2
    mfill(1, btnY, W, " ", C.dim, C.bg)
    mw(divX, btnY, "|", C.sub, C.bg)

    if ui.queueSel >= 1 and ui.queueSel <= #queue then
        local job = queue[ui.queueSel]
        mw(rightX, btnY, trunc(
           (" CANCEL JOB: %s x%d "):format(job.rec.name, job.qty),
           rightW), C.btnTx, C.bad)
    elseif #queue == 0 then
        mw(rightX, btnY, trunc(" Queue is empty", rightW), C.dim, C.bg)
    else
        mw(rightX, btnY, trunc(" Tap a job to select it", rightW), C.dim, C.bg)
    end
end

-- Main draw

local function drawUI()
    local W, H = mon.getSize()
    mon.setBackgroundColor(C.bg)
    mon.clear()

    drawHeader(W)
    drawTabs(W)

    if ui.tab == "craft" then
        drawCraftTab(W, H)
    else
        drawQueueTab(W, H)
    end

    -- Status bar (H-1)
    mfill(1, H - 1, W, " ", colors.white, C.stat)
    mw(2, H - 1, trunc(ui.status, W - 2), colors.white, C.stat)

    -- Footer hint (H)
    mfill(1, H, W, " ", C.hdrTx, C.hdr)
    local hint
    if ui.compoundPlan then
        hint = "Tap [QUEUE ALL] to queue all steps  |  Tap [CANCEL] to abort"
    elseif ui.confirm then
        hint = "Tap [CRAFT N] for partial order  |  Tap [CANCEL] to abort"
    elseif ui.tab == "craft" then
        if ui.searchMode then
            hint = "Type to filter  |  Backspace=delete  |  Enter/Esc=done"
        else
            hint = "Tap recipe=select  |  Tap again=detail  |  Tap search bar=filter"
        end
    else
        hint = "Tap queue item to select  |  Tap CANCEL JOB button to remove"
    end
    local hX = math.max(1, math.floor((W - #hint) / 2) + 1)
    mw(hX, H, trunc(hint, W), C.hdrTx, C.hdr)
end

-- Touch: CRAFT tab

local function handleCraftTouch(x, y, W, H)
    local invW  = math.floor(W * 0.54)
    local divX  = invW + 1
    local recX  = invW + 2
    local recW  = W - recX + 1
    local listH = H - 5
    local invListH = (ui.invDetail and ui.invSel >= 1
                      and ui.invSel <= #invItems)
                     and math.max(2, listH - 4) or listH

    -- Confirm overlay: only H-2 is interactive
    if ui.confirm then
        if y == H - 2 then
            local c = ui.confirm
            if c.canMake > 0 and x < W - 9 then
                ui.confirm = nil
                local _, freeN = countStations()
                if freeN > 0 then
                    dispatchCraft(c.rec, c.canMake)
                else
                    queue[#queue + 1] = { rec = c.rec, qty = c.canMake }
                    ui.status = ("Queued (partial %d): %s [%d waiting]"):format(
                        c.canMake, c.rec.name, #queue)
                    tryDispatchNext()
                end
            elseif x >= W - 9 then
                ui.confirm = nil
                ui.status  = "Order cancelled."
            end
        end
        return
    end

    -- Compound plan overlay: only H-2 is interactive
    if ui.compoundPlan then
        if y == H - 2 then
            local cp = ui.compoundPlan
            if x <= recX + 10 then
                -- [QUEUE ALL] -- add all steps in order
                ui.compoundPlan = nil
                for _, job in ipairs(cp.plan) do
                    queue[#queue + 1] = { rec = job.rec, qty = job.qty }
                end
                ui.status = ("Queued %d steps for %s x%d"):format(
                    #cp.plan, cp.rec.name, cp.qty)
                tryDispatchNext()
            elseif x >= W - 9 then
                ui.compoundPlan = nil
                ui.status = "Compound plan cancelled."
            end
        end
        return
    end

    -- Sub-header row 3: scroll arrows + search toggle
    if y == 3 then
        if x >= 1 and x <= invW then
            if x >= invW - 6 and x <= invW - 4 then
                -- [^] scroll inventory up
                ui.invScroll = math.max(0, ui.invScroll - 1)
            elseif x >= invW - 3 and x <= invW - 1 then
                -- [v] scroll inventory down
                ui.invScroll = math.min(
                    math.max(0, #invItems - listH), ui.invScroll + 1)
            end
        elseif x >= recX then
            if x >= W - 6 and x <= W - 4 then
                -- [^] scroll recipes up
                ui.recScroll = math.max(0, ui.recScroll - 1)
            elseif x >= W - 3 and x <= W - 1 then
                -- [v] scroll recipes down
                ui.recScroll = math.min(
                    math.max(0, #filteredRec - listH), ui.recScroll + 1)
            else
                -- Tap search label area -> toggle search mode
                ui.searchMode = not ui.searchMode
                if ui.searchMode then
                    ui.status = "Search mode -- type on keyboard, Enter to finish"
                else
                    if ui.search ~= "" then
                        ui.status = ("Filter: /" .. ui.search
                                     .. " -- " .. #filteredRec .. " results")
                    else
                        ui.status = "Search cleared."
                    end
                end
            end
        end
        return
    end

    -- Inventory list (rows 4..H-2)
    if x >= 1 and x <= invW and y >= 4 and y <= 3 + listH then
        -- Min-stock editor button taps (bottom 4 rows when editor is open)
        if ui.invDetail and ui.invSel >= 1 and ui.invSel <= #invItems then
            local ey1 = invListH + 4
            if y == ey1 + 2 then
                -- Step buttons row
                if     x <= 4        then ui.minQty = math.max(0, ui.minQty - 8)
                elseif x <= 9        then ui.minQty = math.max(0, ui.minQty - 1)
                elseif x >= invW - 3 then ui.minQty = ui.minQty + 8
                elseif x >= invW - 8 then ui.minQty = ui.minQty + 1
                end
                return
            elseif y == ey1 + 3 then
                -- SET / CLR row
                local it = invItems[ui.invSel]
                if x <= math.floor(invW / 2) then
                    -- SET
                    if ui.minQty > 0 then
                        minStock[it.name] = ui.minQty
                    else
                        minStock[it.name] = nil
                    end
                    saveMinStock()
                    ui.invDetail = false
                    ui.status = ("Min stock for %s set to %d"):format(
                        it.displayName, ui.minQty)
                else
                    -- CLR
                    minStock[it.name] = nil
                    saveMinStock()
                    ui.invDetail = false
                    ui.status = "Min stock cleared for " .. it.displayName
                end
                return
            elseif y >= ey1 then
                return  -- tap in editor header/info rows: ignore
            end
        end

        -- Normal inventory list tap
        local idx = (y - 3) + ui.invScroll
        if idx >= 1 and idx <= #invItems then
            if idx == ui.invSel and not ui.invDetail then
                -- Second tap on same item: open min-stock editor
                ui.invDetail = true
                ui.minQty    = minStock[invItems[idx].name] or 0
                ui.status    = "Set min stock for " .. invItems[idx].displayName
            else
                -- New item: select it, close any open editor
                ui.invSel    = idx
                ui.invDetail = false
                ui.showDetail = false
                ui.status    = invItems[idx].displayName
                               .. "  x" .. invItems[idx].count
                               .. (minStock[invItems[idx].name]
                                  and ("  (min:" .. minStock[invItems[idx].name] .. ")")
                                  or "")
            end
        end
        return
    end

    -- Recipe panel (right side)
    if x >= recX and y >= 4 then

        -- CRAFT button row (H-2), visible in detail view only
        if ui.showDetail and y == H - 2 then
            local rec = filteredRec[ui.recSel]
            if x <= recX + 2 then
                -- [-]
                ui.qty = math.max(1, ui.qty - 1)
                ui.status = "Quantity: " .. ui.qty
            elseif x >= W - 2 then
                -- [+]
                ui.qty = ui.qty + 1
                ui.status = "Quantity: " .. ui.qty
            elseif rec then
                -- CRAFT button: full order, compound, partial, or impossible
                local canMake = maxCraftable(rec)
                if canMake >= ui.qty then
                    -- Full order: have everything right now
                    local _, freeN = countStations()
                    if freeN > 0 then
                        dispatchCraft(rec, ui.qty)
                    else
                        queue[#queue + 1] = { rec = rec, qty = ui.qty }
                        ui.status = ("Queued: %s x%d [%d waiting]"):format(
                            rec.name, ui.qty, #queue)
                        tryDispatchNext()
                    end
                else
                    -- Missing ingredients -- try to build a compound plan
                    local plan = buildCraftPlan(rec.output, ui.qty)
                    if #plan > 1 then
                        -- Has sub-recipes: show compound plan panel
                        ui.compoundPlan = { rec = rec, qty = ui.qty, plan = plan }
                        ui.confirm      = nil
                        ui.status = ("Compound plan: %d steps for %s x%d"):format(
                            #plan, rec.name, ui.qty)
                    elseif canMake > 0 then
                        -- No sub-recipes, partial order possible
                        local miss = getMissing(rec, ui.qty)
                        ui.confirm = {
                            rec = rec, canMake = canMake,
                            requested = ui.qty, missing = miss,
                        }
                        ui.status = ("Partial: can make %d of %d %s"):format(
                            canMake, ui.qty, rec.name)
                    else
                        -- Can't make any and no sub-recipes
                        local miss = getMissing(rec, ui.qty)
                        ui.confirm = {
                            rec = rec, canMake = 0,
                            requested = ui.qty, missing = miss,
                        }
                        ui.status = "Insufficient resources -- see details"
                    end
                end
            end
            return
        end

        -- Recipe list rows: tap to select / toggle detail
        if y >= 4 and y <= 3 + listH then
            local topH = ui.showDetail
                and math.max(2, math.floor(listH * 0.45)) or listH
            if (y - 3) <= topH then
                local idx = (y - 3) + ui.recScroll
                if idx >= 1 and idx <= #filteredRec then
                    if idx == ui.recSel then
                        ui.showDetail = not ui.showDetail
                    else
                        ui.recSel     = idx
                        ui.showDetail = true
                    end
                    ui.confirm      = nil
                    ui.compoundPlan = nil
                    local r = filteredRec[ui.recSel]
                    ui.status = r.name
                        .. (ui.showDetail and " -- tap CRAFT to queue" or "")
                end
            end
        end
    end
end

-- Touch: QUEUE tab

local function handleQueueTouch(x, y, W, H)
    local leftW  = math.floor(W * 0.48)
    local rightX = leftW + 2
    local listH  = H - 5

    -- Right panel: waiting queue list
    if x >= rightX and y >= 4 and y <= 3 + listH then
        local idx = y - 3
        if idx >= 1 and idx <= #queue then
            -- Tap same item again to deselect
            ui.queueSel = (ui.queueSel == idx) and 0 or idx
            if ui.queueSel > 0 then
                local job = queue[ui.queueSel]
                ui.status = ("Selected #%d: %s x%d"):format(
                    ui.queueSel, job.rec.name, job.qty)
            end
        end
        return
    end

    -- Cancel button row (H-2)
    if y == H - 2 and x >= leftW + 2 then
        if ui.queueSel >= 1 and ui.queueSel <= #queue then
            local job = table.remove(queue, ui.queueSel)
            ui.status  = ("Cancelled: %s x%d"):format(job.rec.name, job.qty)
            ui.queueSel = math.min(math.max(0, ui.queueSel - 1), #queue)
        end
    end
end

-- Touch dispatcher

local function handleTouch(x, y)
    local W, H = mon.getSize()

    -- Tab bar (row 2)
    if y == 2 then
        if x >= 2 and x <= 8 then
            ui.tab          = "craft"
            ui.confirm      = nil
            ui.compoundPlan = nil
            ui.invDetail    = false
            ui.status       = "Craft & Recipes"
        elseif x >= 10 and x <= 16 then
            ui.tab          = "queue"
            ui.confirm      = nil
            ui.compoundPlan = nil
            ui.invDetail    = false
            ui.queueSel     = 0
            ui.status       = "Queue & Station Status"
        end
        return
    end

    if ui.tab == "craft" then
        handleCraftTouch(x, y, W, H)
    else
        handleQueueTouch(x, y, W, H)
    end
end

-- Network messages

local function handleMsg(sid, msg)
    if type(msg) ~= "table" then return end

    if msg.type == "HELLO" then
        local wasBusy = stations[msg.station_name]
                        and stations[msg.station_name].busy or false
        stations[msg.station_name] = { id = sid, busy = wasBusy }
        rednet.send(sid, { type = "ACK" }, PROTO)
        ui.status = "Station '" .. tostring(msg.station_name)
                    .. "' registered (ID:" .. sid .. ")"
        tryDispatchNext()

    elseif msg.type == "DONE" then
        local job = pending[msg.id]
        if job then
            pending[msg.id] = nil
            if stations[job.stationName] then
                stations[job.stationName].busy = false
            end
            scanVault()
            local qStr = #queue > 0
                and ("  [%d queued]"):format(#queue) or ""
            ui.status = ("Done: %s x%d via %s -- vault updated%s"):format(
                job.recipe.name, job.qty, job.stationName, qStr)
            tryDispatchNext()
            checkMinStock()
        end

    elseif msg.type == "DENY" then
        local job = pending[msg.id]
        if job then
            pending[msg.id] = nil
            if stations[job.stationName] then
                stations[job.stationName].busy = false
            end
            local qStr = #queue > 0
                and ("  [%d queued]"):format(#queue) or ""
            ui.status = "DENIED: " .. (msg.reason or "unknown reason") .. qStr
            tryDispatchNext()
        end
    end
end

-- Main loop

boot()
scanVault()
buildFilteredRec("")
ui.status = "Ready. Server ID: " .. os.computerID()
drawUI()

local refreshTimer = os.startTimer(10)

while true do
    local ev = { os.pullEvent() }

    if ev[1] == "monitor_touch" and ev[2] == monName then
        handleTouch(ev[3], ev[4])
        drawUI()

    -- Keyboard input for recipe search (type at the computer terminal)
    elseif ev[1] == "char" and ui.searchMode then
        ui.search    = ui.search .. ev[2]
        buildFilteredRec(ui.search)
        ui.recSel    = 1
        ui.recScroll = 0
        drawUI()

    elseif ev[1] == "key" and ui.searchMode then
        if ev[2] == keys.backspace then
            if #ui.search > 0 then
                ui.search = ui.search:sub(1, -2)
                buildFilteredRec(ui.search)
                ui.recSel    = 1
                ui.recScroll = 0
                drawUI()
            end
        elseif ev[2] == keys.enter or ev[2] == keys.escape then
            ui.searchMode = false
            drawUI()
        end

    elseif ev[1] == "rednet_message" and ev[4] == PROTO then
        handleMsg(ev[2], ev[3])
        drawUI()

    elseif ev[1] == "timer" and ev[2] == refreshTimer then
        scanVault()
        checkMinStock()
        tryDispatchNext()
        drawUI()
        refreshTimer = os.startTimer(10)
    end
end
