-- ============================================================
--  casing_station.lua  --  Dedicated Create Deployer Casing Station
--
--  FLOW:
--    1. Server sends stripped logs + casing material to input barrel.
--    2. Computer keeps the deployer hand and depot loaded in safe batches.
--    3. Deployer creates casings on the depot.
--    4. Computer moves finished casings to output barrel.
--    5. Return packager sends the exact requested casing count home.
-- ============================================================

local cfg   = dofile("config.lua")
local PROTO = cfg.protocol or "CRAFT_NET"

local inputBarrel  = nil
local deployer     = nil
local depot        = nil
local outputBarrel = nil
local retPackager  = nil

local function findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == "modem" then
            local m = peripheral.wrap(name)
            if m.isWireless() then return name end
        end
    end
    return nil
end

local function wrapRequired(name, label)
    local p = peripheral.wrap(name)
    assert(p, label .. " not found: " .. tostring(name))
    return p
end

local function boot()
    inputBarrel  = wrapRequired(cfg.input_barrel, "Input barrel")
    deployer     = wrapRequired(cfg.deployer_name, "Deployer")
    depot        = wrapRequired(cfg.depot_name, "Depot")
    outputBarrel = wrapRequired(cfg.output_barrel, "Output barrel")
    retPackager  = wrapRequired(cfg.return_packager_name, "Return Packager")

    local modem = findWirelessModem()
    assert(modem, "No wireless/ender modem found on this computer!")
    rednet.open(modem)

    print("[casing:" .. cfg.station_name .. "] Online. ID: "
          .. os.computerID())
end

local function countInventory(inv, itemName)
    local total = 0
    for _, stack in pairs(inv.list()) do
        if stack.name == itemName then
            total = total + stack.count
        end
    end
    return total
end

local function countOutput(outputName)
    return countInventory(outputBarrel, outputName)
end

local function countOtherOutput(outputName)
    for _, stack in pairs(outputBarrel.list()) do
        if stack.name ~= outputName then
            return stack.name, stack.count
        end
    end
    return nil
end

local function findSlot(inv, itemName)
    for slot, stack in pairs(inv.list()) do
        if stack.name == itemName then return slot, stack.count end
    end
    return nil, 0
end

local function itemCount(inv)
    local total = 0
    for _, stack in pairs(inv.list()) do
        total = total + stack.count
    end
    return total
end

local function firstItem(inv)
    for _, stack in pairs(inv.list()) do
        return stack.name, stack.count
    end
    return nil, 0
end

local function isStrippedLogItem(name)
    local item = tostring(name):match("^[^:]+:(.+)$") or tostring(name)
    return item:match("^stripped_.+_log$") ~= nil
        or item:match("^stripped_.+_stem$") ~= nil
end

local function casingMaterialFor(outputName)
    local map = cfg.materials_by_output or {}
    return map[outputName]
end

local function waitForInputs(materialName, total, timeout)
    timeout = timeout or cfg.input_timeout or 60
    local deadline = os.epoch("utc") + timeout * 1000

    while os.epoch("utc") < deadline do
        local logs = 0
        for _, stack in pairs(inputBarrel.list()) do
            if isStrippedLogItem(stack.name) then logs = logs + stack.count end
        end

        local material = countInventory(inputBarrel, materialName)
        if logs >= total and material >= total then return true end
        os.sleep(0.5)
    end

    return false, ("Timed out waiting for inputs: need %d stripped logs and %d %s"):format(
        total, total, materialName)
end

local function pushItemTo(targetName, itemName, count)
    local moved = 0
    while moved < count do
        local slot, slotCount = findSlot(inputBarrel, itemName)
        if not slot then break end
        local n = inputBarrel.pushItems(targetName, slot, math.min(count - moved, slotCount))
        if n <= 0 then break end
        moved = moved + n
    end
    return moved
end

local function pushAnyStrippedLogTo(targetName, count)
    local moved = 0
    while moved < count do
        local movedThisPass = false
        for slot, stack in pairs(inputBarrel.list()) do
            if isStrippedLogItem(stack.name) then
                local n = inputBarrel.pushItems(
                    targetName, slot, math.min(count - moved, stack.count))
                if n > 0 then
                    moved = moved + n
                    movedThisPass = true
                end
                if moved >= count then break end
            end
        end
        if not movedThisPass then break end
    end
    return moved
end

local function pullDepotOutput(outputName)
    local moved = 0
    for slot, stack in pairs(depot.list()) do
        if stack.name == outputName then
            moved = moved + depot.pushItems(cfg.output_barrel, slot, stack.count)
        end
    end
    return moved
end

local function waitForDepotFree(timeout)
    timeout = timeout or cfg.slot_clear_timeout or 30
    local deadline = os.epoch("utc") + timeout * 1000
    while os.epoch("utc") < deadline do
        if itemCount(depot) == 0 then return true end
        os.sleep(0.25)
    end
    local name, count = firstItem(depot)
    return false, ("Depot still occupied by %s x%d"):format(tostring(name), count)
end

local function deployerMaterialState(materialName)
    local total = 0
    for _, stack in pairs(deployer.list()) do
        if stack.name ~= materialName then
            return false, "Deployer already contains " .. stack.name
        end
        total = total + stack.count
    end

    return true, total, math.max(0, (cfg.deployer_capacity or 64) - total)
end

local function processCasings(outputName, materialName, expected)
    local done = countOutput(outputName)
    local deadline = os.epoch("utc") + (cfg.process_timeout or 300) * 1000
    local batchMax = math.min(cfg.batch_size or 64, cfg.depot_capacity or 64, cfg.deployer_capacity or 64)

    while done < expected and os.epoch("utc") < deadline do
        local otherName, otherCount = countOtherOutput(outputName)
        if otherName then
            return false, ("Unexpected output item: %s x%d"):format(otherName, otherCount)
        end

        pullDepotOutput(outputName)
        done = countOutput(outputName)
        if done >= expected then break end

        local batch = math.min(batchMax, expected - done)
        local ok, err = waitForDepotFree()
        if not ok then return false, err end

        local stateOk, heldOrErr, room = deployerMaterialState(materialName)
        if not stateOk then return false, heldOrErr end

        local held = heldOrErr
        local toLoad = math.max(0, math.min(room, batch - held))
        local movedMaterial = 0
        if toLoad > 0 then
            movedMaterial = pushItemTo(cfg.deployer_name, materialName, toLoad)
        end

        local usable = math.min(batch, held + movedMaterial)
        local movedLogs = pushAnyStrippedLogTo(cfg.depot_name, usable)
        if usable <= 0 or movedLogs <= 0 then
            return false, "Could not load deployer/depot for casing batch"
        end
        if movedLogs < usable then
            return false, ("Loaded material for %d but only %d stripped logs"):format(
                usable, movedLogs)
        end

        while os.epoch("utc") < deadline do
            pullDepotOutput(outputName)
            done = countOutput(outputName)
            if done >= expected then break end
            if itemCount(depot) == 0 then break end
            os.sleep(0.25)
        end
    end

    if done ~= expected then
        return false, ("Expected %s x%d, have %d"):format(outputName, expected, done)
    end
    return true
end

local function waitForBarrelDrained(outputName, timeout)
    timeout = timeout or cfg.package_drain_timeout or 10
    local deadline = os.epoch("utc") + timeout * 1000

    while os.epoch("utc") < deadline do
        if countOutput(outputName) == 0 then return true end
        os.sleep(0.5)
    end

    return false, ("Packager did not drain output barrel (still have %d)"):format(
        countOutput(outputName))
end

local function sendOutputHome(outputName, expected)
    local attempts = cfg.package_attempts or 3
    local settleDelay = cfg.package_settle_delay or 1

    retPackager.setAddress(cfg.home_address)

    for attempt = 1, attempts do
        os.sleep(settleDelay)
        if countOutput(outputName) ~= expected then
            return false, ("Output changed before packaging: %s has %d, expected %d"):format(
                outputName, countOutput(outputName), expected)
        end

        local ok, err = pcall(retPackager.makePackage)
        if not ok then return false, "makePackage failed: " .. tostring(err) end

        ok, err = waitForBarrelDrained(outputName)
        if ok then return true end

        print(("[WARN] Package attempt %d/%d did not drain barrel: %s"):format(
            attempt, attempts, tostring(err)))
    end

    return false, "Return packager did not pull items from output barrel"
end

local function registerWithServer()
    print(("[casing:%s] Broadcasting HELLO"):format(cfg.station_name))
    rednet.broadcast({
        type         = "HELLO",
        station_name = cfg.station_name,
        station_type = "processing",
    }, PROTO)
end

local function executeCasing(msg)
    local outputName = msg.output
    local expected = tonumber(msg.count) or 0
    if type(outputName) ~= "string" or expected <= 0 then
        return false, "Invalid PROCESS_REQUEST"
    end

    local materialName = casingMaterialFor(outputName)
    if not materialName then
        return false, "No casing material configured for " .. tostring(outputName)
    end

    print(("[%s] Making %s x%d with %s"):format(
        cfg.station_name, outputName, expected, materialName))

    local ok, err = waitForInputs(materialName, expected)
    if not ok then return false, err end

    ok, err = processCasings(outputName, materialName, expected)
    if not ok then return false, err end

    print("  Sending completed package home...")
    ok, err = sendOutputHome(outputName, expected)
    if not ok then return false, err end

    print(("  Done: %s x%d"):format(outputName, expected))
    return true
end

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

        elseif msg.type == "PROCESS_REQUEST" then
            rednet.send(sid, { type = "ACCEPT", id = msg.id }, PROTO)

            local ok, err = executeCasing(msg)
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

    elseif ev[1] == "timer" and ev[2] == helloTimer then
        registerWithServer()
        helloTimer = os.startTimer(60)
    end
end
