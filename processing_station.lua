-- ============================================================
--  processing_station.lua  --  Processing Station Return Gate
--
--  PHYSICAL SETUP (this computer needs):
--    . Wired modem  -> Output Barrel
--    . Wired modem  -> Return Packager
--    . Ender Modem  -> wireless rednet to server computer
--
--  FLOW:
--    1. Server sends ingredients to this station's Create address.
--    2. Processing machine produces finished items into output barrel.
--    3. This computer waits until the output barrel contains exactly
--       the requested finished item count.
--    4. Return Packager sends that exact package home.
-- ============================================================

local cfg   = dofile("config.lua")
local PROTO = cfg.protocol or "CRAFT_NET"

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

    print("[processing:" .. cfg.station_name .. "] Online. ID: "
          .. os.computerID())
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

local function waitForExactOutput(outputName, expected, timeout)
    timeout = timeout or cfg.process_timeout or 300
    local deadline = os.epoch("utc") + timeout * 1000

    while os.epoch("utc") < deadline do
        local have = countOutput(outputName)
        if have >= expected then
            return true
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
        local have = countOutput(outputName)
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

        local have = countOutput(outputName)
        if have < expected then
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
    print(("[processing:%s] Broadcasting HELLO"):format(cfg.station_name))
    rednet.broadcast({
        type         = "HELLO",
        station_name = cfg.station_name,
        station_type = "processing",
    }, PROTO)
end

local function executeProcess(msg)
    local outputName = msg.output
    local expected   = tonumber(msg.count) or 0
    if type(outputName) ~= "string" or expected <= 0 then
        return false, "Invalid PROCESS_REQUEST"
    end

    print(("[%s] Waiting for %s x%d"):format(
        cfg.station_name, outputName, expected))

    local ok, err = waitForExactOutput(outputName, expected)
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

            local ok, err = executeProcess(msg)
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
