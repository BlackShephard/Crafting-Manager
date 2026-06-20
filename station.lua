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
    ["o:dusts/redstone"]        = "minecraft:redstone",
    ["createbigcannons:dusts_redstone"] = "minecraft:redstone",
    ["c:dusts/glowstone"]       = "minecraft:glowstone_dust",
    ["o:dusts/glowstone"]       = "minecraft:glowstone_dust",
    ["c:rods/wooden"]           = "minecraft:stick",
    ["o:rods/wooden"]           = "minecraft:stick",
    ["c:rods/blaze"]            = "minecraft:blaze_rod",
    ["o:rods/blaze"]            = "minecraft:blaze_rod",
    ["c:ingots/iron"]           = "minecraft:iron_ingot",
    ["o:ingots/iron"]           = "minecraft:iron_ingot",
    ["c:ingots/gold"]           = "minecraft:gold_ingot",
    ["o:ingots/gold"]           = "minecraft:gold_ingot",
    ["c:ingots/copper"]         = "minecraft:copper_ingot",
    ["o:ingots/copper"]         = "minecraft:copper_ingot",
    ["c:ingots/zinc"]           = "create:zinc_ingot",
    ["o:ingots/zinc"]           = "create:zinc_ingot",
    ["c:ingots/brass"]          = "create:brass_ingot",
    ["o:ingots/brass"]          = "create:brass_ingot",
    ["c:ingots/netherite"]      = "minecraft:netherite_ingot",
    ["o:ingots/netherite"]      = "minecraft:netherite_ingot",
    ["c:nuggets/iron"]          = "minecraft:iron_nugget",
    ["o:nuggets/iron"]          = "minecraft:iron_nugget",
    ["c:nuggets/gold"]          = "minecraft:gold_nugget",
    ["o:nuggets/gold"]          = "minecraft:gold_nugget",
    ["c:gems/diamond"]          = "minecraft:diamond",
    ["o:gems/diamond"]          = "minecraft:diamond",
    ["c:gems/emerald"]          = "minecraft:emerald",
    ["o:gems/emerald"]          = "minecraft:emerald",
    ["c:gems/lapis"]            = "minecraft:lapis_lazuli",
    ["o:gems/lapis"]            = "minecraft:lapis_lazuli",
    ["c:gems/quartz"]           = "minecraft:quartz",
    ["o:gems/quartz"]           = "minecraft:quartz",
    ["createbigcannons:gems_quartz"] = "minecraft:quartz",
    ["c:gems/amethyst"]         = "minecraft:amethyst_shard",
    ["o:gems/amethyst"]         = "minecraft:amethyst_shard",
    ["c:stones"]                = "minecraft:stone",
    ["o:stones"]                = "minecraft:stone",
    ["minecraft:stone_tool_materials"] = "minecraft:cobblestone",
    ["c:cobblestones"]          = "minecraft:cobblestone",
    ["o:cobblestones"]          = "minecraft:cobblestone",
    ["c:cobblestones/normal"]   = "minecraft:cobblestone",
    ["c:obsidians"]             = "minecraft:obsidian",
    ["o:obsidians"]             = "minecraft:obsidian",
    ["c:netherracks"]           = "minecraft:netherrack",
    ["o:netherracks"]           = "minecraft:netherrack",
    ["c:sands/colorless"]       = "minecraft:sand",
    ["o:sands/colorless"]       = "minecraft:sand",
    ["c:glass/colorless"]       = "minecraft:glass",
    ["o:glass"]                 = "minecraft:glass",
    ["c:glass_panes/colorless"] = "minecraft:glass_pane",
    ["o:paneGlass"]             = "minecraft:glass_pane",
    ["minecraft:terracotta"]    = "minecraft:terracotta",
    ["c:bricks/nether"]         = "minecraft:nether_brick",
    ["o:bricks/nether"]         = "minecraft:nether_brick",
    ["c:andesite_alloys"]       = "create:andesite_alloy",
    ["c:cogwheels"]             = "create:cogwheel",
    ["c:large_cogwheels"]       = "create:large_cogwheel",
    ["c:brass_sheets"]          = "create:brass_sheet",
    ["c:copper_sheets"]         = "create:copper_sheet",
    ["c:iron_sheets"]           = "create:iron_sheet",
    ["c:zinc_sheets"]           = "create:zinc_sheet",
    ["c:strings"]               = "minecraft:string",
    ["c:leathers"]              = "minecraft:leather",
    ["c:gunpowders"]            = "minecraft:gunpowder",
    ["createbigcannons:gunpowder"] = "minecraft:gunpowder",
    ["minecraft:candles"]       = "minecraft:candle",
    ["c:nether_stars"]          = "minecraft:nether_star",
    ["c:buckets/water"]         = "minecraft:water_bucket",
    ["c:foods/milk"]            = "minecraft:milk_bucket",
    ["c:slimeballs"]            = "minecraft:slime_ball",
    ["c:ender_pearls"]          = "minecraft:ender_pearl",
    ["c:crops/wheat"]           = "minecraft:wheat",
    ["c:crop/wheat"]            = "minecraft:wheat",
    ["c:crops/potato"]          = "minecraft:potato",
    ["c:crops/nether_wart"]     = "minecraft:nether_wart",
    ["c:dyes"]                  = "minecraft:white_dye",
    ["c:dyes/red"]              = "minecraft:red_dye",
    ["c:dyes/blue"]             = "minecraft:blue_dye",
    ["c:dyes/green"]            = "minecraft:green_dye",
    ["c:dyes/yellow"]           = "minecraft:yellow_dye",
    ["c:dyes/black"]            = "minecraft:black_dye",
    ["c:dyes/white"]            = "minecraft:white_dye",
    ["c:dyes/purple"]           = "minecraft:purple_dye",
    ["c:dyes/orange"]           = "minecraft:orange_dye",
    ["c:dyes/pink"]             = "minecraft:pink_dye",
    ["c:dyes/brown"]            = "minecraft:brown_dye",
    ["c:dyes/cyan"]             = "minecraft:cyan_dye",
    ["c:dyes/gray"]             = "minecraft:gray_dye",
    ["c:dyes/light_blue"]       = "minecraft:light_blue_dye",
    ["c:dyes/light_gray"]       = "minecraft:light_gray_dye",
    ["c:dyes/lime"]             = "minecraft:lime_dye",
    ["c:dyes/magenta"]          = "minecraft:magenta_dye",
    ["c:chests/wooden"]         = "minecraft:chest",
    ["o:chests/wooden"]         = "minecraft:chest",
    ["c:wooden_chests"]         = "minecraft:chest",
    ["o:wooden_chests"]         = "minecraft:chest",
    ["c:chests"]                = "minecraft:chest",
    ["o:chests"]                = "minecraft:chest",
    ["c:barrels/wooden"]        = "minecraft:barrel",
    ["o:barrels/wooden"]        = "minecraft:barrel",
    ["c:storage_blocks/coal"]   = "minecraft:coal_block",
    ["c:storage_blocks/copper"] = "minecraft:copper_block",
    ["c:storage_blocks/diamond"] = "minecraft:diamond_block",
    ["c:storage_blocks/emerald"] = "minecraft:emerald_block",
    ["c:storage_blocks/gold"]   = "minecraft:gold_block",
    ["c:storage_blocks/iron"]   = "minecraft:iron_block",
    ["c:storage_blocks/netherite"] = "minecraft:netherite_block",
}

local function resolveItem(name)
    if type(name) ~= "string" then return name end
    local key = name:gsub("^TODO:", "")
    return TAG_MAP[key] or key
end

local function isGenericPlanksTag(name)
    if type(name) ~= "string" then return false end
    local key = name:gsub("^TODO:", "")
    return key == "c:planks"
        or key == "o:planks"
        or key == "minecraft:planks"
        or key == "planks"
end

local function isPlankItem(name)
    local key = resolveItem(name)
    return type(key) == "string"
        and (key:sub(-7) == "_planks" or key:sub(-6) == "planks")
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
        local item = isGenericPlanksTag(ing.item) and "<any_planks>" or resolveItem(ing.item)
        needed[item] = (needed[item] or 0) + ing.count * qty
    end

    while os.epoch("utc") < deadline do
        local have = {}
        for _, stack in pairs(inputChest.list()) do
            local item = resolveItem(stack.name)
            have[item] = (have[item] or 0) + stack.count
        end
        local ready = true
        for item, n in pairs(needed) do
            local count = item == "<any_planks>" and 0 or (have[item] or 0)
            if item == "<any_planks>" then
                count = 0
                for name, stackCount in pairs(have) do
                    if type(name) == "string" and name:sub(-7) == "_planks" then
                        count = count + stackCount
                    end
                end
            end
            if count < n then
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
        local itemName = isGenericPlanksTag(ing.item) and nil or resolveItem(ing.item)
        local needed = ing.count * qty
        local loaded = 0
        for srcSlot, stack in pairs(inputChest.list()) do
            if loaded >= needed then break end
            local matches = false
            if isGenericPlanksTag(ing.item) then
                matches = isPlankItem(stack.name)
            else
                matches = stack.name == itemName
            end
            if matches then
                local toMove = math.min(needed - loaded, stack.count)
                local moved  = inputChest.pushItems(
                                   cfg.crafter_name, srcSlot, toMove, ing.slot)
                print(("    %s: barrel[%d] → crafter[%d] (moved %d/%d)"):format(
                    (itemName or "planks"):match("(.+)") or (itemName or "planks"),
                    srcSlot, ing.slot, moved, toMove))
                loaded = loaded + moved
            end
        end
        if loaded < needed then
            return false,
                ("Not enough %s: need %d, placed %d"):format(
                    itemName or "planks", needed, loaded)
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
