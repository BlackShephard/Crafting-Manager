-- ============================================================
--  station.lua  —  Crafting Station Client
--
--  PHYSICAL SETUP (this computer needs):
--    • Wired modem  → Staging Barrel  (Repackager faces this)
--    • Wired modem  → Mechanical Crafter (connected 3×3 network)
--    • Wired modem  → Output Barrel    (crafter output lands here)
--    • Wired modem  → Return Packager  (sends output home)
--    • Redstone wire from computer side → crafter (force-craft signal)
--    • Ender Modem  → wireless rednet to server computer
--
--  PHYSICAL ITEM FLOW:
--    Frog Port → barrel → Repackager → Staging Barrel
--    [CC] Staging Barrel → Crafter at specific recipe slots
--    [CC] Redstone pulse → Crafter starts force-craft
--    Crafter output → Output Barrel
--    [CC] Output Barrel → Return Packager → Frog Port → Home
--
--  SETUP:
--    1. Copy config_template.lua → config.lua, set role="station"
--    2. Copy recipes.lua to this computer
--    3. Set server_id to the server's in-game computer ID
--    4. Run this script or add to startup.lua
-- ============================================================

local cfg     = dofile("config.lua")
local recipes = dofile("recipes.lua")
local PROTO   = cfg.protocol or "CRAFT_NET"

-- ── Peripherals ────────────────────────────────────────────

local inputChest  = nil
local crafter     = nil
local outputBarrel = nil
local retPackager = nil

local function findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m.isWireless() then
                return name
            end
        end
    end
    return nil
end

local function boot()
    inputChest = peripheral.wrap(cfg.input_chest)
    assert(inputChest,
        "Staging barrel not found (cfg.input_chest = "
        .. tostring(cfg.input_chest) .. ")")

    crafter = peripheral.wrap(cfg.crafter_name)
    assert(crafter,
        "Mechanical Crafter not found (cfg.crafter_name = "
        .. tostring(cfg.crafter_name) .. ")")

    outputBarrel = peripheral.wrap(cfg.output_barrel)
    assert(outputBarrel,
        "Output barrel not found (cfg.output_barrel = "
        .. tostring(cfg.output_barrel) .. ")")

    retPackager = peripheral.wrap(cfg.return_packager_name)
    assert(retPackager,
        "Return Packager not found (cfg.return_packager_name = "
        .. tostring(cfg.return_packager_name) .. ")")

    local modem = findWirelessModem()
    assert(modem, "No wireless/ender modem found on this computer!")
    rednet.open(modem)

    print("[station:" .. cfg.station_name .. "] Online. ID: "
          .. os.computerID())
end

-- ── Recipe lookup ──────────────────────────────────────────

local function findRecipe(id)
    for _, r in ipairs(recipes) do
        if r.id == id then return r end
    end
    return nil
end

-- Resolve tag-style ingredient names to concrete item IDs.
local TAG_MAP = {
    ["c:dusts/redstone"]        = "minecraft:redstone",
    ["c:rods/wooden"]           = "minecraft:stick",
    ["c:ingots/iron"]           = "minecraft:iron_ingot",
    ["c:ingots/gold"]           = "minecraft:gold_ingot",
    ["c:ingots/copper"]         = "minecraft:copper_ingot",
    ["c:ingots/zinc"]           = "create:zinc_ingot",
    ["c:ingots/brass"]          = "create:brass_ingot",
    ["c:nuggets/iron"]          = "minecraft:iron_nugget",
    ["c:nuggets/gold"]          = "minecraft:gold_nugget",
    ["c:andesite_alloys"]       = "create:andesite_alloy",
    ["c:cogwheels"]             = "create:cogwheel",
    ["c:large_cogwheels"]       = "create:large_cogwheel",
}

local function resolveItem(name)
    if type(name) ~= "string" then return name end
    local key = name:gsub("^TODO:", "")
    return TAG_MAP[key] or key
end

-- ── Crafting logic ──────────────────────────────────────────

-- Wait until all required items are present in the staging barrel.
-- Aggregates totals per item so recipes with the same item in multiple
-- slots (e.g. shaft: andesite_alloy in slot 1 AND slot 4) correctly
-- require the full combined count before proceeding.
local function waitForItems(recipe, qty, timeout)
    timeout = timeout or 30
    local deadline = os.epoch("utc") + timeout * 1000

    -- Build total-needed map (merge duplicate items across slots).
    local needed = {}
    for _, ing in ipairs(recipe.ingredients) do
        local item = resolveItem(ing.item)
        needed[item] = (needed[item] or 0) + ing.count * qty
    end

    while os.epoch("utc") < deadline do
        local have = {}
        for _, stack in pairs(inputChest.list()) do
            have[stack.name] = (have[stack.name] or 0) + stack.count
        end
        local ready = true
        for item, n in pairs(needed) do
            if (have[item] or 0) < n then
                ready = false
                break
            end
        end
        if ready then return true end
        os.sleep(0.5)
    end
    return false
end

-- Push each ingredient from the staging barrel into its designated
-- crafter slot.  Create's IItemHandler routes slot-specific insertions
-- to the correct crafter block in the connected network.
local function loadCrafter(recipe, qty)
    local crafterName = cfg.crafter_name
    for _, ing in ipairs(recipe.ingredients) do
        local itemName = resolveItem(ing.item)
        local needed = ing.count * qty
        local loaded = 0
        for srcSlot, stack in pairs(inputChest.list()) do
            if loaded >= needed then break end
            if stack.name == itemName then
                local toMove = math.min(needed - loaded, stack.count)
                local moved  = inputChest.pushItems(
                                   cfg.crafter_name, srcSlot, toMove, ing.slot)
                print(("    %s: barrel[%d] → crafter[%d] (moved %d/%d)"):format(
                    itemName:match(":(.+)") or itemName,
                    srcSlot, ing.slot, moved, toMove))
                loaded = loaded + moved
            end
        end
        if loaded < needed then
            return false,
                ("Not enough %s: need %d, placed %d"):format(
                    itemName, needed, loaded)
        end
    end
    return true
end

-- Wait until the output barrel has the expected crafted items.
local function waitForOutput(recipe, qty, timeout)
    timeout       = timeout or 60
    local deadline = os.epoch("utc") + timeout * 1000
    local expected = recipe.output_count * qty
    while os.epoch("utc") < deadline do
        local have = 0
        for _, stack in pairs(outputBarrel.list()) do
            if stack.name == resolveItem(recipe.output) then
                have = have + stack.count
            end
        end
        if have >= expected then return true end
        os.sleep(0.5)
    end
    return false
end

-- Trigger the return Packager to pull from the adjacent output barrel
-- and dispatch home.  The Packager is physically next to the output
-- barrel, so makePackage() causes it to grab items itself — we must
-- NOT push items into it via CC (Packager is not a CC inventory).
local function sendOutputHome()
    retPackager.setAddress(cfg.home_address)
    local ok, err = pcall(retPackager.makePackage)
    if not ok then
        print("[WARN] makePackage failed: " .. tostring(err))
        print("  Ensure cfg.home_address matches the home frog port label.")
    end
end

-- Full craft cycle.
local function executeCraft(recipe, qty)
    print((("[%s] Request: %s x%d"):format(cfg.station_name, recipe.name, qty)))

    -- 1. Wait for all items to arrive in the staging barrel.
    print("  Waiting for items in staging barrel...")
    if not waitForItems(recipe, qty, 30) then
        return false, "Timed out waiting for items in staging barrel"
    end

    -- Helper: count how many of the recipe output are currently in the barrel.
    local function countOutput()
        local n = 0
        local outputName = resolveItem(recipe.output)
        for _, stack in pairs(outputBarrel.list()) do
            if stack.name == outputName then n = n + stack.count end
        end
        return n
    end

    -- Snapshot output before we start (barrel may already have leftovers).
    local baseline = countOutput()

    -- 2. Each Mechanical Crafter slot holds at most 1 item, so craft one
    --    run at a time.  After each pulse, poll the output barrel until it
    --    gains exactly recipe.output_count new items — that confirms the run
    --    finished regardless of how fast or slow the recipe is.
    local runTimeout = 60   -- seconds per individual run
    for run = 1, qty do
        print(("  Run %d/%d — loading crafter..."):format(run, qty))
        local ok, err = loadCrafter(recipe, 1)
        if not ok then return false, err end

        if cfg.redstone_side then
            redstone.setOutput(cfg.redstone_side, true)
            os.sleep(0.2)
            redstone.setOutput(cfg.redstone_side, false)
        end

        -- Wait for this run's output to land in the barrel.
        local target   = baseline + run * recipe.output_count
        local deadline = os.epoch("utc") + runTimeout * 1000
        while os.epoch("utc") < deadline do
            if countOutput() >= target then break end
            os.sleep(0.25)
        end
        if countOutput() < target then
            return false, ("Run %d/%d timed out — crafter produced no output after %ds"):format(
                run, qty, runTimeout)
        end
        print(("  Run %d/%d complete"):format(run, qty))
    end

    -- 3. Ship everything home.
    print("  Sending output home...")
    sendOutputHome()

    print((("  Done: %s x%d"):format(recipe.name, qty)))
    return true
end

-- ── Registration ─────────────────────────────────────────────

local function myRecipeIDs()
    local ids = {}
    for _, r in ipairs(recipes) do
        if r.station == cfg.station_name then
            ids[#ids + 1] = r.id
        end
    end
    return ids
end

local function registerWithServer()
    local ids = myRecipeIDs()
    print((("[%s] Broadcasting HELLO (%d recipes)"):format(
        cfg.station_name, #ids)))
    rednet.broadcast({
        type         = "HELLO",
        station_name = cfg.station_name,
        recipes      = ids,
    }, PROTO)
end

-- ── Main loop ─────────────────────────────────────────────────

boot()
registerWithServer()

local helloTimer = os.startTimer(60)

while true do
    local ev = { os.pullEvent() }

    if ev[1] == "rednet_message" and ev[4] == PROTO then
        local sid, msg = ev[2], ev[3]

        if type(msg) ~= "table" then
        elseif msg.type == "ACK" then
            print("[" .. cfg.station_name
                  .. "] Registered with server #" .. sid)

        elseif msg.type == "REQUEST" then
            local recipe = findRecipe(msg.recipe)
            if not recipe then
                rednet.send(sid, {
                    type   = "DENY",
                    id     = msg.id,
                    reason = "Unknown recipe id: " .. tostring(msg.recipe),
                }, PROTO)
            else
                rednet.send(sid, { type = "ACCEPT", id = msg.id }, PROTO)

                local ok, err = executeCraft(recipe, msg.count or 1)

                if ok then
                    rednet.send(sid, { type = "DONE", id = msg.id }, PROTO)
                else
                    print("[ERR] " .. tostring(err))
                    rednet.send(sid, {
                        type   = "DENY",
                        id     = msg.id,
                        reason = err,
                    }, PROTO)
                end
            end
        end

    elseif ev[1] == "timer" and ev[2] == helloTimer then
        registerWithServer()
        helloTimer = os.startTimer(60)
    end
end
