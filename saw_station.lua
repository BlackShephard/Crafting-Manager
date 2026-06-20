-- ============================================================
--  saw_station.lua  --  Saw Bank Routing Station
--
--  PHYSICAL SETUP (this computer needs):
--    . Wired modem  -> Incoming package/input barrel
--    . Wired modem  -> Every configured saw
--    . Wired modem  -> Shared output barrel
--    . Wired modem  -> Return Packager
--    . Ender Modem  -> wireless rednet to server computer
--
--  The computer routes incoming ingredients to the correct filtered
--  saw. Saw outputs are ejected physically and must be collected into
--  the shared output barrel.
-- ============================================================

local cfg   = dofile("config.lua")
local PROTO = cfg.protocol or "CRAFT_NET"

local inputBarrel  = nil
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

local function boot()
    inputBarrel = peripheral.wrap(cfg.input_barrel)
    assert(inputBarrel,
        "Input barrel not found (cfg.input_barrel = "
        .. tostring(cfg.input_barrel) .. ")")

    outputBarrel = peripheral.wrap(cfg.output_barrel)
    assert(outputBarrel,
        "Output barrel not found (cfg.output_barrel = "
        .. tostring(cfg.output_barrel) .. ")")

    retPackager = peripheral.wrap(cfg.return_packager_name)
    assert(retPackager,
        "Return Packager not found (cfg.return_packager_name = "
        .. tostring(cfg.return_packager_name) .. ")")

    for route, sawName in pairs(cfg.routes or {}) do
        assert(peripheral.wrap(sawName),
            ("Saw route '%s' peripheral not found: %s"):format(
                route, tostring(sawName)))
    end

    local modem = findWirelessModem()
    assert(modem, "No wireless/ender modem found on this computer!")
    rednet.open(modem)

    print("[saw:" .. cfg.station_name .. "] Online. ID: "
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
    local wanted = 0
    local other = {}

    for _, stack in pairs(outputBarrel.list()) do
        if stack.name == outputName then
            wanted = wanted + stack.count
        else
            other[#other + 1] = {
                name = stack.name,
                count = stack.count,
            }
        end
    end

    return wanted, other
end

local function describeOther(other)
    if #other == 0 then return nil end
    local first = other[1]
    return ("%s x%d"):format(first.name, first.count)
end

local function buildNeeded(msg)
    local needed = {}
    local crafts = tonumber(msg.crafts) or 1

    if type(msg.ingredients) ~= "table" then
        return needed
    end

    for _, ing in ipairs(msg.ingredients) do
        if type(ing.item) == "string" then
            needed[ing.item] = (needed[ing.item] or 0)
                + (tonumber(ing.count) or 1) * crafts
        end
    end

    return needed
end

local function waitForInputs(needed, timeout)
    timeout = timeout or cfg.input_timeout or 60
    local deadline = os.epoch("utc") + timeout * 1000

    while os.epoch("utc") < deadline do
        local ready = true
        for item, count in pairs(needed) do
            if countInventory(inputBarrel, item) < count then
                ready = false
                break
            end
        end
        if ready then return true end
        os.sleep(0.5)
    end

    local missing = {}
    for item, count in pairs(needed) do
        local have = countInventory(inputBarrel, item)
        if have < count then
            missing[#missing + 1] = ("%s %d/%d"):format(item, have, count)
        end
    end
    return false, "Timed out waiting for input: " .. table.concat(missing, ", ")
end

local function routeFor(msg)
    if cfg.recipe_routes and cfg.recipe_routes[msg.recipe] then
        return cfg.recipe_routes[msg.recipe]
    end
    if type(msg.route) == "string" and msg.route ~= "" then
        return msg.route
    end

    local output = tostring(msg.output or "")
    local item = output:match("^[^:]+:(.+)$") or output

    if item:match("_hanging_sign$") then return nil, "hanging signs are not saw-routed" end
    if item:match("^stripped_.+_log$") then return "stripped_log" end
    if item:match("^stripped_.+_wood$") then return "stripped_wood" end
    if item:match("_pressure_plate$") then return "pressure_plate" end
    if item:match("_fence_gate$") then return "fence_gate" end
    if item:match("_trapdoor$") then return "trapdoor" end
    if item:match("_stairs$") then return "stair" end
    if item:match("_button$") then return "button" end
    if item:match("_planks$") then return "plank" end
    if item:match("_slab$") then return "slab" end
    if item:match("_sign$") then return "sign" end
    if item:match("_fence$") then return "fence" end
    if item:match("_door$") then return "door" end
    if item:match("_wood$") then return "wood" end

    return nil, "No saw route for output: " .. tostring(msg.output)
end

local function pushInputsToSaw(sawName, needed, timeout)
    timeout = timeout or cfg.input_timeout or 60
    local deadline = os.epoch("utc") + timeout * 1000
    local movedByItem = {}

    while os.epoch("utc") < deadline do
        local done = true

        for item, total in pairs(needed) do
            movedByItem[item] = movedByItem[item] or 0
            local remaining = total - movedByItem[item]

            for slot, stack in pairs(inputBarrel.list()) do
                if remaining <= 0 then break end
                if stack.name == item then
                    local moved = inputBarrel.pushItems(
                        sawName, slot, math.min(remaining, stack.count))
                    remaining = remaining - moved
                    movedByItem[item] = movedByItem[item] + moved
                    if moved == 0 then os.sleep(0.25) end
                end
            end

            if remaining > 0 then done = false end
        end

        if done then return true end
        os.sleep(0.5)
    end

    return false, "Timed out pushing input into " .. tostring(sawName)
end

local function waitForExactOutput(outputName, expected, timeout)
    timeout = timeout or cfg.process_timeout or 300
    local deadline = os.epoch("utc") + timeout * 1000

    while os.epoch("utc") < deadline do
        local have, other = countOutput(outputName)
        if #other > 0 then
            return false, "Unexpected item in output barrel: " .. describeOther(other)
        end
        if have == expected then return true end
        if have > expected then
            return false, ("Output over target: %s has %d, expected %d"):format(
                outputName, have, expected)
        end
        os.sleep(0.5)
    end

    local have = countOutput(outputName)
    return false, ("Timed out waiting for %s x%d (have %d)"):format(
        outputName, expected, have)
end

local function waitForBarrelDrained(outputName, timeout)
    timeout = timeout or cfg.package_drain_timeout or 10
    local deadline = os.epoch("utc") + timeout * 1000

    while os.epoch("utc") < deadline do
        local have, other = countOutput(outputName)
        if #other > 0 then
            return false, "Unexpected item in output barrel: " .. describeOther(other)
        end
        if have == 0 then return true end
        os.sleep(0.5)
    end

    local have = countOutput(outputName)
    return false, ("Packager did not drain output barrel (still have %d)"):format(have)
end

local function sendOutputHome(outputName, expected)
    local attempts = cfg.package_attempts or 3
    local settleDelay = cfg.package_settle_delay or 1

    retPackager.setAddress(cfg.home_address)

    for attempt = 1, attempts do
        os.sleep(settleDelay)

        local have, other = countOutput(outputName)
        if #other > 0 then
            return false, "Unexpected item in output barrel: " .. describeOther(other)
        end
        if have ~= expected then
            return false, ("Output changed before packaging: %s has %d, expected %d"):format(
                outputName, have, expected)
        end

        local ok, err = pcall(retPackager.makePackage)
        if not ok then
            return false, "makePackage failed: " .. tostring(err)
        end

        ok, err = waitForBarrelDrained(outputName)
        if ok then return true end

        print(("[WARN] Package attempt %d/%d did not drain barrel: %s"):format(
            attempt, attempts, tostring(err)))
    end

    return false, "Return packager did not pull items from output barrel"
end

local function registerWithServer()
    print(("[saw:%s] Broadcasting HELLO"):format(cfg.station_name))
    rednet.broadcast({
        type         = "HELLO",
        station_name = cfg.station_name,
        station_type = "processing",
    }, PROTO)
end

local function executeSaw(msg)
    local outputName = msg.output
    local expected = tonumber(msg.count) or 0
    if type(outputName) ~= "string" or expected <= 0 then
        return false, "Invalid PROCESS_REQUEST"
    end

    local route, routeErr = routeFor(msg)
    if not route then return false, routeErr end

    local sawName = cfg.routes and cfg.routes[route]
    if not sawName then return false, "No saw configured for route: " .. tostring(route) end

    local needed = buildNeeded(msg)
    if not next(needed) then
        return false, "PROCESS_REQUEST missing ingredients"
    end

    print(("[%s] Route %s -> %s for %s x%d"):format(
        cfg.station_name, route, sawName, outputName, expected))

    local ok, err = waitForInputs(needed)
    if not ok then return false, err end

    ok, err = pushInputsToSaw(sawName, needed)
    if not ok then return false, err end

    ok, err = waitForExactOutput(outputName, expected)
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

            local ok, err = executeSaw(msg)
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
