-- Phoenix networked artillery with automatic loading: central fire control.
-- Run this on an advanced computer with a wireless/ender modem.
-- Each cannon must run artillery_gun_node_with_reloading.lua.

local CONFIG = {
    protocol = "phoenix.artillery.reloading.v1",
    protocol_version = 2,
    -- To secure the fleet, copy artillery_auth.lua to this computer and every
    -- gun node, set enabled=true everywhere, and use the same long secret.
    security_enabled = false,
    shared_secret = "",
    auth_max_age_ms = 30000,
    -- Keep false while the original fire-control startup launcher exists.
    install_startup = false,
    restart_after_crash_s = 3.0,
    node_timeout_s = 6.0,
    discovery_interval_s = 2.0,
    welcome_refresh_s = 5.0,
    aim_update_s = 0.75,
    fire_resend_s = 0.25,
    fire_refresh_s = 2.0,
    load_resend_s = 1.0,
    load_order_timeout_s = 45.0,
    -- FIRE waits this long for every selected loader. Any gun that has not
    -- reported LOADED by the deadline is skipped before the broadside begins.
    fire_load_phase_timeout_s = 15.0,
    -- Added after the last scheduled shot when waiting for fired/rejected ACKs.
    fire_ack_grace_s = 15.0,
    fire_order_timeout_s = 120.0,
    emergency_resend_s = 0.20,
    emergency_broadcast_s = 3.0,
    ripple_duration_s = 20.0,
    ripple_adjust_s = 5.0,
    ripple_duration_variance_fraction = 0.30,
    ripple_gap_variance_fraction = 0.35,
    ripple_shuffle_same_station = true,
    ripple_same_station_shuffle_chance = 0.35,
    broadside_separation_m = 1.5,
    monitor_text_scale = 0.5,
    manual_yaw_step_deg = 1.0,
    manual_elevation_step_deg = 1.0,
    manual_min_yaw_deg = -23,
    manual_max_yaw_deg = 23,
    manual_min_elevation_deg = -4,
    manual_max_elevation_deg = 15,

    gravity = 9.81,
    -- Fixed identical cannon/load profile: 1 chamber, 5 unrifled barrels, and
    -- one fully loaded big cartridge. Only projectile selection changes.
    chambers = 1,
    rifled_barrels = 0,
    unrifled_barrels = 5,
    rifled_velocity_multiplier = 0.985,
    full_big_cartridge_launch_power = 8.0,
    muzzle_speed = 0,
    projectile_name = "HE Shell",
    projectile_mass = 3519.5,
    drag_enabled = true,
    drag_air_density = 1.225,
    drag_coefficient = 0.47,
    projectile_diameter_m = 0.754441738242,
    drag_multiplier = 1.0,
    drag_step_s = 0.05,
    drag_max_time_s = 120.0,
    drag_pitch_scan_step_deg = 2.0,
    drag_bisect_steps = 18,
    -- Physical ballistic elevation envelope. Keep these synchronized with the
    -- gun-node min/max elevation while commissioning new pitch limits.
    min_pitch = -4,
    max_pitch = 15,
    default_arc = "low",
    world_yaw_mode = "mc",
    compensate_ship_motion = true,
}

-- Same Robins constants and projectile masses used by artillery.lua. Add or
-- correct projectile modifiers here without changing the fixed cannon/load.
local ROBINS_K = 606.8568
local POWDER_MASS = 121.593455168150
local CHARGE_LENGTH = 1.0

local PROJECTILES = {
    {name = "Solid Shot",        mass = 3519.5},
    {name = "AP Shot",           mass = 3455.5},
    {name = "Shrapnel Shell",    mass = 3410.6},
    {name = "AP Shell",          mass = 3159.9},
    {name = "HE Shell",          mass = 3519.5},
    {name = "Shell Holder MkV",  mass = 3519.5},
    {name = "Fluid Shell",       mass = 2400.0},
    {name = "Drop Mortar Shell", mass = 2255.5},
    {name = "Mortar Stone",      mass = 1162.3},
    {name = "Smoke Shell",       mass = 1037.0},
    {name = "Grapeshot Shell",   mass = 731.1},
}

-- Operator-facing battery IDs are SIDE-DECK-GUN. Central maps them to a
-- horizontal station so staggered decks join the ripple where they physically
-- sit. Any deck omitted from the map defaults to station == gun number.
local DECK_GUN_COUNTS = {8, 15, 14, 16}
local DECK_STATION_MAP = {
    [1] = {
        2.33, 2.67, 10.5, 11.5, 12.5, 13.5, 14.5, 15.5,
    },
    [3] = {
        2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
    },
    [4] = {
        0.5, 1.5, 2.5, 3.5, 4.5, 5.5, 6.5, 7.5,
        8.5, 9.5, 10.5, 11.5, 12.5, 13.5, 14.5, 15.5,
    },
}

local nodes = {}
local target = nil
local arc = CONFIG.default_arc
local sideMode = "port"
local fireMode = "ripple"
local gunCountMode = "full"
local singleFireCursor = {port = nil, starboard = nil, bow = nil}
local aimMode = "automatic"
local manualAim = {
    port = {yaw = 0, elevation = 0},
    starboard = {yaw = 0, elevation = 0},
    bow = {yaw = 0, elevation = 0},
}
local projectileIndex = 5
local lastAimAt = 0
local lastSolution = nil
local lastSolutionError = "No target"
local lastLayout = nil
local firePlan = nil
local loadPlan = nil
local emergencyUntil = 0
local lastEmergencySentAt = 0
local statusLine = "Waiting for gun nodes"
local running = true
local modemName = nil
local modemNames = {}
local monitor = nil
local monitorName = nil
local monitorButtons = {}
local lastMonitorDrawAt = 0
local lastDiscoveryAt = 0
local lastSolveMs = 0
local authModule = nil
local seenAuthNonces = {}
local authRejects = 0
local sentPacketCount = 0
local lastSentType = nil
local lastSentRecipient = nil
local receivedPacketCount = 0

local function nowMs()
    return os.epoch("utc")
end

local function initializeRandom()
    local seed = (nowMs() + os.getComputerID() * 1000003) % 2147483647
    math.randomseed(seed)
    math.random(); math.random(); math.random()
end

local function ensureStartupLauncher()
    if not CONFIG.install_startup then return true end
    local startupDirectory = "/startup"
    local startupPath = startupDirectory .. "/phoenix_fire_control_with_reloading.lua"
    local programPath = "/central_fire_control_with_reloading.lua"
    local restartDelay = tonumber(CONFIG.restart_after_crash_s) or 3
    local content = table.concat({
        "-- Installed automatically by Phoenix fire control with reloading.",
        "local program = " .. string.format("%q", programPath),
        "local restartDelay = " .. tostring(restartDelay),
        "if not fs.exists(program) then",
        "    printError('Missing ' .. program)",
        "    return",
        "end",
        "while true do",
        "    local completedNormally = shell.run(program)",
        "    if completedNormally then return end",
        "    printError('Fire control stopped unexpectedly; restarting in ' .. restartDelay .. 's')",
        "    sleep(restartDelay)",
        "end",
        "",
    }, "\n")
    local ok, errorMessage = pcall(function()
        if fs.exists(startupDirectory) and not fs.isDir(startupDirectory) then
            error(startupDirectory .. " exists but is not a directory")
        end
        if not fs.exists(startupDirectory) then fs.makeDir(startupDirectory) end
        local existing = nil
        if fs.exists(startupPath) then
            local reader = fs.open(startupPath, "r")
            if reader then existing = reader.readAll(); reader.close() end
        end
        if existing ~= content then
            local writer = assert(fs.open(startupPath, "w"))
            writer.write(content)
            writer.close()
        end
    end)
    if not ok then return nil, tostring(errorMessage) end
    return true
end

local function initializeSecurity()
    if not CONFIG.security_enabled then return true end
    if type(CONFIG.shared_secret) ~= "string" or #CONFIG.shared_secret < 16 then
        return nil, "shared_secret must contain at least 16 characters"
    end
    local path = shell and shell.resolve and shell.resolve("artillery_auth.lua") or "artillery_auth.lua"
    local ok, loaded = pcall(dofile, path)
    if not ok or type(loaded) ~= "table" then return nil, "Cannot load artillery_auth.lua: " .. tostring(loaded) end
    authModule = loaded
    return true
end

local function secureOutgoing(message)
    if CONFIG.security_enabled then
        authModule.seal(message, CONFIG.shared_secret, os.getComputerID(), nowMs())
    end
    return message
end

local function authenticateIncoming(sender, message)
    if not CONFIG.security_enabled then return true end
    if type(message) ~= "table"
        or message.senderId ~= sender
        or type(message.sentAt) ~= "number"
        or type(message.nonce) ~= "string"
        or math.abs(nowMs() - message.sentAt) > CONFIG.auth_max_age_ms
        or not authModule.verify(message, CONFIG.shared_secret) then
        authRejects = authRejects + 1
        statusLine = "AUTH REJECT from computer " .. tostring(sender)
        return false
    end
    if seenAuthNonces[message.nonce] then return false end
    seenAuthNonces[message.nonce] = nowMs()
    local cutoff = nowMs() - CONFIG.auth_max_age_ms * 2
    for nonce, acceptedAt in pairs(seenAuthNonces) do
        if acceptedAt < cutoff then seenAuthNonces[nonce] = nil end
    end
    return true
end

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function wrap360(a)
    return ((a % 360) + 360) % 360
end

local function vec(x, y, z)
    return {x = x, y = y, z = z}
end

local function calculateFixedMuzzleVelocity(projectile)
    local chargeEquivalent = CONFIG.full_big_cartridge_launch_power / 2.0
    local mountedLength = (CONFIG.rifled_barrels + CONFIG.unrifled_barrels + CONFIG.chambers) * CHARGE_LENGTH
    local chargeLength = chargeEquivalent * CHARGE_LENGTH
    if mountedLength <= chargeLength then
        return nil, string.format("Fixed cannon too short: %.2f <= charge %.2f", mountedLength, chargeLength)
    end
    local propellantMass = chargeEquivalent * POWDER_MASS
    local velocitySquared = (propellantMass / (projectile.mass + propellantMass / 3))
        * math.log(mountedLength / chargeLength)
    if velocitySquared <= 0 then return nil, "Invalid fixed interior-ballistics profile" end
    local cannonMultiplier = CONFIG.rifled_velocity_multiplier ^ CONFIG.rifled_barrels
    local projectileMultiplier = projectile.velocity_multiplier or 1.0
    return ROBINS_K * cannonMultiplier * projectileMultiplier * math.sqrt(velocitySquared)
end

local function applyProjectile(index)
    local projectile = PROJECTILES[index]
    if not projectile then return nil, "Unknown projectile" end
    local muzzleSpeed, errorMessage = calculateFixedMuzzleVelocity(projectile)
    if not muzzleSpeed then return nil, errorMessage end
    projectileIndex = index
    CONFIG.projectile_name = projectile.name
    CONFIG.projectile_mass = projectile.mass
    CONFIG.drag_multiplier = projectile.drag_multiplier or 1.0
    CONFIG.muzzle_speed = muzzleSpeed
    lastAimAt = 0
    return true
end

local function validVec(p)
    return type(p) == "table"
        and type(p.x) == "number"
        and type(p.y) == "number"
        and type(p.z) == "number"
end

local function vsub(a, b)
    return vec(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vdot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vlen(a)
    return math.sqrt(vdot(a, a))
end

local function vnorm(a)
    local length = vlen(a)
    if length < 1e-9 then return nil end
    return vec(a.x / length, a.y / length, a.z / length)
end

local function worldYawFromUnit(u)
    if CONFIG.world_yaw_mode == "xz" then
        return wrap360(math.atan2(u.z, u.x) * 180 / math.pi)
    end
    return wrap360(math.atan2(u.x, -u.z) * 180 / math.pi)
end

local function openWirelessModem()
    local ok, modems = pcall(function()
        return {peripheral.find("modem", function(_, candidate)
            return type(candidate.isWireless) == "function" and candidate.isWireless()
        end)}
    end)
    if not ok or type(modems) ~= "table" or #modems == 0 then
        modemNames = {}
        return nil, "No wireless or ender modem"
    end

    local opened = {}
    local lastError = nil
    for _, modem in ipairs(modems) do
        local nameOk, name = pcall(peripheral.getName, modem)
        if nameOk and name then
            local openOk, openError = pcall(function()
                if not rednet.isOpen(name) then rednet.open(name) end
            end)
            if openOk then
                opened[#opened + 1] = name
            else
                lastError = tostring(openError)
            end
        end
    end
    modemNames = opened
    if #opened == 0 then return nil, lastError or "Could not open attached modems" end
    return opened[1]
end

local function ensureModem()
    if modemName then
        local ok, isOpen = pcall(rednet.isOpen, modemName)
        if ok and isOpen then return true end
    end
    local errorMessage
    modemName, errorMessage = openWirelessModem()
    if not modemName then
        modemNames = {}
        statusLine = "COMMS OFFLINE: " .. tostring(errorMessage)
        return false
    end
    return true
end

local function safeSend(recipient, message)
    if not ensureModem() then return false end
    secureOutgoing(message)
    local ok, sent = pcall(rednet.send, recipient, message, CONFIG.protocol)
    if not ok then
        modemName = nil
        modemNames = {}
        statusLine = "COMMS ERROR: " .. tostring(sent)
        return false
    end
    if sent ~= false then
        sentPacketCount = sentPacketCount + 1
        lastSentType = tostring(message.type or "?")
        lastSentRecipient = tostring(recipient)
    end
    return sent ~= false
end

local function safeBroadcast(message)
    if not ensureModem() then return false end
    secureOutgoing(message)
    local ok, sent = pcall(rednet.broadcast, message, CONFIG.protocol)
    if not ok then
        modemName = nil
        modemNames = {}
        statusLine = "COMMS ERROR: " .. tostring(sent)
        return false
    end
    if sent ~= false then
        sentPacketCount = sentPacketCount + 1
        lastSentType = tostring(message.type or "?")
        lastSentRecipient = "*"
    end
    return sent ~= false
end

local function sendDiscovery(force)
    local now = nowMs()
    if not force and now - lastDiscoveryAt < CONFIG.discovery_interval_s * 1000 then return end
    if safeBroadcast({
        type = "discover",
        version = CONFIG.protocol_version,
        centralId = os.getComputerID(),
    }) then
        lastDiscoveryAt = now
    end
end

local function ensureMonitor()
    if monitor and monitorName then return true end
    local ok, found = pcall(peripheral.find, "monitor", function(_, candidate)
        local colorMethod = candidate.isColor or candidate.isColour
        return type(colorMethod) == "function" and colorMethod()
    end)
    if not ok or not found then
        monitor, monitorName = nil, nil
        return false
    end
    local nameOk, name = pcall(peripheral.getName, found)
    if not nameOk or not name then return false end
    local setupOk = pcall(function()
        found.setTextScale(CONFIG.monitor_text_scale)
        found.setBackgroundColor(colors.black)
        found.setTextColor(colors.white)
        found.clear()
    end)
    if not setupOk then
        monitor, monitorName = nil, nil
        return false
    end
    monitor, monitorName = found, name
    return true
end

local function batteryIdentityError(node)
    if node.enabled == false then return "DISABLED" end
    if node.sideHint ~= "port" and node.sideHint ~= "starboard" then return "NO SIDE" end
    local role = node.batteryRole or "broadside"
    if role == "bow_chaser" then
        if type(node.chaserNumber) ~= "number" or node.chaserNumber % 1 ~= 0
            or node.chaserNumber < 1 then return "NO/INVALID CHASER NUMBER" end
    elseif role ~= "broadside" then
        return "INVALID BATTERY ROLE"
    else
    if type(node.deckNumber) ~= "number" or node.deckNumber % 1 ~= 0
        or not DECK_GUN_COUNTS[node.deckNumber] then return "NO/INVALID DECK" end
    local maximum = DECK_GUN_COUNTS[node.deckNumber]
    if type(node.gunNumber) ~= "number" or node.gunNumber % 1 ~= 0
        or node.gunNumber < 1 or node.gunNumber > maximum then
        return string.format("INVALID GUN (deck %d allows 1-%d)", node.deckNumber, maximum)
    end
    end
    if node.stationOverride ~= nil then
        if type(node.stationOverride) ~= "number"
            or node.stationOverride ~= node.stationOverride
            or node.stationOverride == math.huge
            or node.stationOverride == -math.huge
            or node.stationOverride <= 0 then
            return "INVALID STATION OVERRIDE"
        end
    end
    return nil
end

local function batteryStation(node)
    if type(node.stationOverride) == "number" then return node.stationOverride end
    if node.batteryRole == "bow_chaser" then return node.chaserNumber end
    local deckMap = DECK_STATION_MAP[node.deckNumber]
    return deckMap and deckMap[node.gunNumber] or node.gunNumber
end

local function batteryLabel(node)
    local side = node.sideHint == "port" and "P" or node.sideHint == "starboard" and "S" or "?"
    if node.batteryRole == "bow_chaser" then
        return string.format("BC-%s-%s", side, tostring(node.chaserNumber or "?"))
    end
    return string.format("%s-%s-%s", side,
        tostring(node.deckNumber or "?"), tostring(node.gunNumber or "?"))
end

local function activeNodes()
    local result = {}
    local cutoff = nowMs() - CONFIG.node_timeout_s * 1000
    for _, node in pairs(nodes) do
        if node.lastSeen >= cutoff and node.enabled ~= false and validVec(node.position)
            and node.mountOnline ~= false and not batteryIdentityError(node) then
            node.station = batteryStation(node)
            node.batteryLabel = batteryLabel(node)
            result[#result + 1] = node
        end
    end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local function knownNodes()
    local result = {}
    for _, node in pairs(nodes) do result[#result + 1] = node end
    table.sort(result, function(a, b) return a.id < b.id end)
    return result
end

local function nodeInactiveReason(node)
    local age = math.max(0, (nowMs() - (node.lastSeen or 0)) / 1000)
    if age > CONFIG.node_timeout_s then return string.format("STALE %.1fs", age) end
    if node.enabled == false then return "DISABLED" end
    if not validVec(node.position) then return "NO POSITION" end
    if node.mountOnline == false then return node.hardwareError or "MOUNT OFFLINE" end
    if type(node.heading) ~= "number" then return "NO SABLE HEADING" end
    local identityError = batteryIdentityError(node)
    if identityError then return identityError end
    return nil
end

local function averageHeading(list)
    local sinSum, cosSum, count = 0, 0, 0
    for _, node in ipairs(list) do
        if type(node.heading) == "number" then
            local radians = node.heading * math.pi / 180
            sinSum = sinSum + math.sin(radians)
            cosSum = cosSum + math.cos(radians)
            count = count + 1
        end
    end
    if count == 0 then return nil end
    return wrap360(math.atan2(sinSum, cosSum) * 180 / math.pi)
end

local function analyzeLayout()
    local list = activeNodes()
    if #list == 0 then return nil, "No active guns with positions" end
    local occupiedBatteryIds = {}
    for _, node in ipairs(list) do
        local key
        if node.batteryRole == "bow_chaser" then
            key = string.format("bow:%s:%d", node.sideHint, node.chaserNumber)
        else
            key = string.format("%s:%d:%d", node.sideHint, node.deckNumber, node.gunNumber)
        end
        if occupiedBatteryIds[key] then
            return nil, string.format("Duplicate battery ID %s on computers %d and %d",
                batteryLabel(node), occupiedBatteryIds[key].id, node.id)
        end
        occupiedBatteryIds[key] = node
    end

    local center = vec(0, 0, 0)
    local velocity = vec(0, 0, 0)
    local velocityCount = 0
    for _, node in ipairs(list) do
        center.x = center.x + node.position.x
        center.y = center.y + node.position.y
        center.z = center.z + node.position.z
        if validVec(node.velocity) then
            velocity.x = velocity.x + node.velocity.x
            velocity.y = velocity.y + node.velocity.y
            velocity.z = velocity.z + node.velocity.z
            velocityCount = velocityCount + 1
        end
    end
    center.x, center.y, center.z = center.x / #list, center.y / #list, center.z / #list
    if velocityCount > 0 then
        velocity.x = velocity.x / velocityCount
        velocity.y = velocity.y / velocityCount
        velocity.z = velocity.z / velocityCount
    end

    local heading = averageHeading(list)
    if not heading then return nil, "Gun nodes have no Sable heading" end
    local h = heading * math.pi / 180
    local forward = vec(math.sin(h), 0, -math.cos(h))
    local right = vec(math.cos(h), 0, math.sin(h))

    for _, node in ipairs(list) do
        node.side = node.batteryRole == "bow_chaser" and "bow" or node.sideHint
        node.station = batteryStation(node)
        node.batteryLabel = batteryLabel(node)
        node.longitudinal = -node.station
        node.lateral = 0
    end

    local counts = {port = 0, starboard = 0, bow = 0, all = #list}
    for _, node in ipairs(list) do
        counts[node.side] = counts[node.side] + 1
    end
    table.sort(list, function(a, b)
        if a.side ~= b.side then
            local sideOrder = {port = 1, starboard = 2, bow = 3}
            return sideOrder[a.side] < sideOrder[b.side]
        end
        if a.station ~= b.station then return a.station < b.station end
        local aDeck, bDeck = a.deckNumber or 0, b.deckNumber or 0
        if aDeck ~= bDeck then return aDeck < bDeck end
        local aGun, bGun = a.gunNumber or a.chaserNumber or 0, b.gunNumber or b.chaserNumber or 0
        if aGun ~= bGun then return aGun < bGun end
        return a.id < b.id
    end)
    local hasTwoSides = counts.port > 0 and counts.starboard > 0

    return {
        nodes = list,
        center = center,
        velocity = CONFIG.compensate_ship_motion and velocity or vec(0, 0, 0),
        heading = heading,
        forward = forward,
        right = right,
        lateralSpan = 0,
        hasTwoSides = hasTwoSides,
        counts = counts,
    }
end

local function dragAccelScale()
    local radius = CONFIG.projectile_diameter_m * 0.5
    local area = math.pi * radius * radius
    return 0.5 * CONFIG.drag_air_density * CONFIG.drag_coefficient * area
        * CONFIG.drag_multiplier / CONFIG.projectile_mass
end

local function simulateDragToRange(range, deltaY, forwardVelocity, verticalVelocity)
    local k = dragAccelScale()
    local x, y, vx, vy, elapsed = 0, 0, forwardVelocity, verticalVelocity, 0
    local previousX, previousY, previousTime = 0, 0, 0
    while elapsed < CONFIG.drag_max_time_s do
        local speed = math.sqrt(vx * vx + vy * vy)
        local ax, ay = 0, -CONFIG.gravity
        if speed > 1e-6 then
            ax = ax - k * speed * vx
            ay = ay - k * speed * vy
        end
        vx = vx + ax * CONFIG.drag_step_s
        vy = vy + ay * CONFIG.drag_step_s
        previousX, previousY, previousTime = x, y, elapsed
        x = x + vx * CONFIG.drag_step_s
        y = y + vy * CONFIG.drag_step_s
        elapsed = elapsed + CONFIG.drag_step_s
        if x >= range then
            local width = x - previousX
            local fraction = width > 1e-9 and (range - previousX) / width or 0
            local hitY = previousY + (y - previousY) * fraction
            local hitTime = previousTime + (elapsed - previousTime) * fraction
            return hitY - deltaY, hitTime
        end
        if y < deltaY - 2000 and vy < 0 then return nil end
    end
    return nil
end

local function solveWithDrag(shooter, shooterVelocity)
    local delta = vsub(target, shooter)
    local range = math.sqrt(delta.x * delta.x + delta.z * delta.z)
    if range < 1e-6 then return nil, "Target is too close" end
    local horizontal = vec(delta.x / range, 0, delta.z / range)
    local forwardShipVelocity = vdot(shooterVelocity, horizontal)
    local verticalShipVelocity = shooterVelocity.y

    local function heightError(pitchDegrees)
        local pitch = pitchDegrees * math.pi / 180
        local forwardVelocity = CONFIG.muzzle_speed * math.cos(pitch) + forwardShipVelocity
        if forwardVelocity <= 0 then return nil end
        return simulateDragToRange(
            range,
            delta.y,
            forwardVelocity,
            CONFIG.muzzle_speed * math.sin(pitch) + verticalShipVelocity
        )
    end

    local brackets = {}
    local previousPitch, previousError = nil, nil
    local pitch = CONFIG.min_pitch
    while pitch <= CONFIG.max_pitch do
        local err = heightError(pitch)
        if err then
            if previousError and previousError * err <= 0 then
                brackets[#brackets + 1] = {low = previousPitch, high = pitch}
            end
            previousPitch, previousError = pitch, err
        end
        pitch = pitch + CONFIG.drag_pitch_scan_step_deg
    end
    if #brackets == 0 then return nil, "Target out of range" end

    local bracket = arc == "high" and brackets[#brackets] or brackets[1]
    local low, high = bracket.low, bracket.high
    local lowError = heightError(low)
    local bestPitch, bestError, bestTime = low, math.abs(lowError or math.huge), 0
    for _ = 1, CONFIG.drag_bisect_steps do
        local middle = (low + high) * 0.5
        local middleError, flightTime = heightError(middle)
        if middleError then
            if math.abs(middleError) < bestError then
                bestPitch, bestError, bestTime = middle, math.abs(middleError), flightTime or 0
            end
            if lowError and lowError * middleError <= 0 then
                high = middle
            else
                low, lowError = middle, middleError
            end
        else
            high = middle
        end
    end
    local _, finalTime = heightError(bestPitch)
    return {
        worldYaw = worldYawFromUnit(horizontal),
        pitch = bestPitch,
        range = range,
        tof = finalTime or bestTime,
        drag = true,
    }
end

local function solveWithoutDrag(shooter, shooterVelocity)
    local delta = vsub(target, shooter)
    local gravity = vec(0, -CONFIG.gravity, 0)
    local function equation(time)
        local x = delta.x - shooterVelocity.x * time - gravity.x * 0.5 * time * time
        local y = delta.y - shooterVelocity.y * time - gravity.y * 0.5 * time * time
        local z = delta.z - shooterVelocity.z * time - gravity.z * 0.5 * time * time
        return x * x + y * y + z * z - (CONFIG.muzzle_speed * time) ^ 2
    end
    local roots, step, previousTime = {}, 0.02, 0.02
    local previousValue = equation(previousTime)
    local time = previousTime + step
    while time <= 120 do
        local value = equation(time)
        if previousValue == 0 or previousValue * value < 0 then
            local low, high, lowValue = time - step, time, previousValue
            for _ = 1, 40 do
                local middle = (low + high) * 0.5
                local middleValue = equation(middle)
                if lowValue * middleValue <= 0 then high = middle else low, lowValue = middle, middleValue end
            end
            roots[#roots + 1] = (low + high) * 0.5
        end
        previousValue, time = value, time + step
    end
    if #roots == 0 then return nil, "Target out of range" end
    local flightTime = arc == "high" and roots[#roots] or roots[1]
    local aim = vec(
        delta.x - shooterVelocity.x * flightTime - gravity.x * 0.5 * flightTime * flightTime,
        delta.y - shooterVelocity.y * flightTime - gravity.y * 0.5 * flightTime * flightTime,
        delta.z - shooterVelocity.z * flightTime - gravity.z * 0.5 * flightTime * flightTime
    )
    local unit = vnorm(aim)
    if not unit then return nil, "Degenerate solution" end
    return {
        worldYaw = worldYawFromUnit(unit),
        pitch = math.asin(clamp(unit.y, -1, 1)) * 180 / math.pi,
        range = math.sqrt(delta.x * delta.x + delta.z * delta.z),
        tof = flightTime,
        drag = false,
    }
end

local function calculateSolution(layout)
    if not target then return nil, "No target" end
    local startedAt = nowMs()
    local solution, solutionError
    if CONFIG.drag_enabled then
        solution, solutionError = solveWithDrag(layout.center, layout.velocity)
    else
        solution, solutionError = solveWithoutDrag(layout.center, layout.velocity)
    end
    local finishedAt = nowMs()
    lastSolveMs = math.max(0, finishedAt - startedAt)

    -- ComputerCraft cannot receive queued modem events while this synchronous
    -- solver is running. Do not count that unavoidable local pause as evidence
    -- that every gun disappeared at once.
    if lastSolveMs > 0 then
        for _, node in pairs(nodes) do
            if node.lastSeen and node.lastSeen <= startedAt then
                node.lastSeen = node.lastSeen + lastSolveMs
            end
        end
    end
    return solution, solutionError
end

local function manualSolution()
    local setting = manualAim[sideMode]
    return {
        manual = true,
        yawFromCenter = setting.yaw,
        pitch = setting.elevation,
        range = 0,
        tof = 0,
    }
end

local function solutionForMode(layout)
    if aimMode == "manual" then return manualSolution() end
    return calculateSolution(layout)
end

local function addAimFields(message, solution)
    if solution.manual then
        message.aimMode = "manual"
        message.yawFromCenter = solution.yawFromCenter
        message.pitch = solution.pitch
    else
        message.aimMode = "world"
        message.worldYaw = solution.worldYaw
        message.pitch = solution.pitch
    end
    return message
end

local function selectedSide(_)
    return sideMode
end

local function fireSlotLess(a, b)
    if a.station ~= b.station then return a.station < b.station end
    local aDeck, bDeck = a.deckNumber or 0, b.deckNumber or 0
    if aDeck ~= bDeck then return aDeck < bDeck end
    local aGun, bGun = a.gunNumber or a.chaserNumber or 0, b.gunNumber or b.chaserNumber or 0
    if aGun ~= bGun then return aGun < bGun end
    return a.id < b.id
end

local function slotIsAfterCursor(node, cursor)
    if not cursor then return true end
    if node.station ~= cursor.station then return node.station > cursor.station end
    local nodeDeck, cursorDeck = node.deckNumber or 0, cursor.deckNumber or 0
    if nodeDeck ~= cursorDeck then return nodeDeck > cursorDeck end
    local nodeGun = node.gunNumber or node.chaserNumber or 0
    local cursorGun = cursor.gunNumber or cursor.chaserNumber or 0
    if nodeGun ~= cursorGun then return nodeGun > cursorGun end
    return node.id > cursor.id
end

local function cursorForNode(node)
    return {
        station = node.station,
        deckNumber = node.deckNumber,
        gunNumber = node.gunNumber,
        chaserNumber = node.chaserNumber,
        id = node.id,
    }
end

local function nextSingleGun(guns, side)
    local cursor = singleFireCursor[side]
    for index, node in ipairs(guns) do
        if slotIsAfterCursor(node, cursor) then return node, index end
    end
    return guns[1], #guns > 0 and 1 or nil
end

local function selectedGuns(layout, requireAimReady)
    local side = selectedSide(layout)
    local result = {}
    for _, node in ipairs(layout.nodes) do
        if node.side == side
            and (not requireAimReady or node.aimReady ~= false) then
            result[#result + 1] = node
        end
    end
    table.sort(result, fireSlotLess)
    return result, side
end

local function requestedGunCount()
    if gunCountMode == "full" then return math.huge end
    return tonumber(gunCountMode) or math.huge
end

local function gunsForOrder(layout, requireAimReady, advanceSingle)
    local guns, side = selectedGuns(layout, requireAimReady)
    if fireMode == "single" then
        local selected = nextSingleGun(guns, side)
        if not selected then return {}, side end
        if advanceSingle then singleFireCursor[side] = cursorForNode(selected) end
        return {selected}, side
    end
    local limit = math.min(#guns, requestedGunCount())
    local limited = {}
    for index = 1, limit do limited[index] = guns[index] end
    return limited, side
end

local function sendWelcome(node)
    local sent = safeSend(node.id, {
        type = "welcome",
        version = CONFIG.protocol_version,
        centralId = os.getComputerID(),
        side = node.side,
    })
    if sent then
        node.lastWelcomeAt = nowMs()
        node.lastWelcomeSide = node.side
    end
end

local function handleNetwork(sender, message)
    if type(message) ~= "table" or message.version ~= CONFIG.protocol_version then return end
    if not authenticateIncoming(sender, message) then return end
    if message.type == "hello" then
        if not validVec(message.position) then return end
        local wasKnown = nodes[sender] ~= nil
        local node = nodes[sender] or {id = sender}
        node.label = tostring(message.label or ("Gun " .. sender))
        node.position = message.position
        node.velocity = validVec(message.velocity) and message.velocity or vec(0, 0, 0)
        node.heading = message.heading
        node.positionSource = message.positionSource or "unknown"
        node.sideHint = message.sideHint
        node.batteryRole = message.batteryRole or "broadside"
        node.deckNumber = message.deckNumber
        node.gunNumber = message.gunNumber
        node.chaserNumber = message.chaserNumber
        node.stationOverride = message.stationOverride
        node.enabled = message.enabled ~= false
        node.batteryLabel = batteryLabel(node)
        node.mountName = message.mountName
        node.mountOnline = message.mountOnline ~= false and message.ready ~= false
        node.hardwareError = message.error
        node.loaderOnline = message.loaderOnline == true
        node.loaderState = message.loaderState or "UNKNOWN"
        node.loadedProjectile = message.loadedProjectile
        node.loaderSourceName = message.loaderSourceName
        node.loaderDepotName = message.loaderDepotName
        node.loaderError = message.loaderError
        node.lastSeen = nowMs()
        node.ready = message.ready ~= false
        nodes[sender] = node
        local identityError = batteryIdentityError(node)
        if identityError then
            statusLine = string.format("Gun %d inactive: %s", sender, identityError)
        elseif node.mountOnline == false then
            statusLine = string.format("Gun %d inactive: %s", sender, node.hardwareError or "cannon mount offline")
        end
        lastLayout = analyzeLayout()
        -- Heartbeats arrive every second. A WELCOME every heartbeat adds no
        -- registration value and can crowd command traffic on a large battery.
        if not wasKnown or not node.lastWelcomeAt
            or nowMs() - node.lastWelcomeAt >= CONFIG.welcome_refresh_s * 1000
            or node.lastWelcomeSide ~= node.side then
            sendWelcome(node)
        end
    elseif message.type == "ack" then
        local node = nodes[sender]
        if node then
            node.lastSeen = nowMs()
            node.lastAck = message.orderId
            node.lastAckType = message.ackType
            if message.ackType == "aim" and node.pendingAimOrder == message.orderId then
                node.aimReady = message.accepted ~= false
            end
            if loadPlan and loadPlan.orderId == message.orderId
                and loadPlan.entries[sender] then
                local entry = loadPlan.entries[sender]
                if message.ackType == "load" and message.accepted ~= false then
                    entry.accepted = true
                elseif message.ackType == "loaded" and message.accepted ~= false then
                    entry.accepted, entry.loaded = true, true
                    node.loaderState = "LOADED"
                    node.loadedProjectile = message.projectile or loadPlan.projectile
                end
            end
            if firePlan and firePlan.orderId == message.orderId
                and firePlan.entries[sender] then
                local entry = firePlan.entries[sender]
                if message.ackType == "load" and message.accepted ~= false then
                    entry.accepted = true
                elseif message.ackType == "loaded" and message.accepted ~= false then
                    entry.accepted, entry.loaded = true, true
                    node.loaderState = "LOADED"
                    node.loadedProjectile = message.projectile or firePlan.projectile
                elseif message.ackType == "fired" and message.accepted ~= false then
                    entry.accepted, entry.loaded, entry.fired = true, true, true
                    node.loaderState = "EMPTY"
                    node.loadedProjectile = nil
                end
            end
            if message.accepted ~= false then
                node.error = nil
            end
            if message.accepted == false then
                if loadPlan and loadPlan.orderId == message.orderId
                    and loadPlan.entries[sender] then
                    loadPlan.entries[sender].failed = true
                end
                if firePlan and firePlan.orderId == message.orderId
                    and firePlan.entries[sender] then
                    firePlan.entries[sender].failed = true
                end
                node.error = message.error or "Order rejected"
                statusLine = string.format("Gun %d rejected order: %s", sender, node.error)
            end
        end
    elseif message.type == "status" then
        local node = nodes[sender]
        if node then
            node.lastSeen = nowMs()
            node.ready = message.ready ~= false
            node.mountOnline = message.mountOnline ~= false and message.ready ~= false
            node.hardwareError = message.error
            node.loaderOnline = message.loaderOnline == true
            node.loaderState = message.loaderState or node.loaderState
            node.loadedProjectile = message.loadedProjectile
            node.loaderSourceName = message.loaderSourceName or node.loaderSourceName
            node.loaderDepotName = message.loaderDepotName or node.loaderDepotName
            node.loaderError = message.loaderError
            if node.mountOnline == false then
                statusLine = string.format("Gun %d inactive: %s", sender, node.hardwareError or "cannon mount offline")
            end
        end
    end
end

local function sendAim(layout, solution)
    local orderId = "aim-" .. tostring(nowMs())
    local guns = {}
    if firePlan then
        -- Once a ripple is issued, never redirect the opposite broadside merely
        -- because casualties changed the automatic layout classification.
        for _, node in ipairs(layout.nodes) do
            local entry = firePlan.entries[node.id]
            if entry and not entry.failed then guns[#guns + 1] = node end
        end
    else
        guns = selectedGuns(layout)
    end
    for _, node in ipairs(guns) do
        node.pendingAimOrder = orderId
        node.aimReady = nil
        safeSend(node.id, addAimFields({
            type = "aim",
            version = CONFIG.protocol_version,
            orderId = orderId,
            validUntil = nowMs() + CONFIG.node_timeout_s * 1000,
        }, solution))
    end
end

local function shuffleSameStationGroups(guns)
    local result = {}
    for index, node in ipairs(guns) do result[index] = node end
    if not CONFIG.ripple_shuffle_same_station then return result end
    local first = 1
    while first <= #result do
        local last = first
        while last + 1 <= #result
            and math.abs(result[last + 1].station - result[first].station) < 1e-9 do
            last = last + 1
        end
        local shuffleChance = clamp(
            tonumber(CONFIG.ripple_same_station_shuffle_chance) or 0, 0, 1
        )
        if last > first and math.random() < shuffleChance then
            for index = last, first + 1, -1 do
                local other = math.random(first, index)
                result[index], result[other] = result[other], result[index]
            end
        end
        first = last + 1
    end
    return result
end

local function buildRippleOffsets(gunCount)
    local offsets = {}
    if gunCount <= 0 then return offsets, 0 end
    offsets[1] = 0
    if gunCount == 1 then return offsets, 0 end
    local durationVariance = clamp(
        tonumber(CONFIG.ripple_duration_variance_fraction) or 0, 0, 0.95
    )
    local actualDuration = CONFIG.ripple_duration_s
        * (1 + (math.random() * 2 - 1) * durationVariance)
    local gapVariance = clamp(
        tonumber(CONFIG.ripple_gap_variance_fraction) or 0, 0, 0.95
    )
    local weights, weightTotal = {}, 0
    for index = 1, gunCount - 1 do
        local weight = 1 + (math.random() * 2 - 1) * gapVariance
        weights[index] = weight
        weightTotal = weightTotal + weight
    end
    local elapsed = 0
    for index = 2, gunCount do
        elapsed = elapsed + weights[index - 1]
        offsets[index] = actualDuration * elapsed / weightTotal
    end
    return offsets, actualDuration
end

local function beginFireOrder()
    if firePlan then statusLine = "A fire order is already active" return end
    if nowMs() < emergencyUntil then statusLine = "Emergency abort broadcast is still active" return end
    local layout, layoutError = analyzeLayout()
    if not layout then statusLine = layoutError return end
    local solution, solutionError = solutionForMode(layout)
    if not solution then statusLine = solutionError return end
    local now = nowMs()
    lastSolution, lastSolutionError = solution, nil

    if loadPlan then
        -- Preserve the exact side/mode/count/projectile/gun set selected when
        -- LOAD was pressed. Reusing its order ID lets nodes already loading
        -- continue in place instead of feeding a duplicate round.
        local promoted = loadPlan
        loadPlan = nil
        firePlan = {
            orderId = promoted.orderId,
            side = promoted.side,
            mode = promoted.mode,
            projectile = promoted.projectile,
            solution = solution,
            entries = promoted.entries,
            -- A completed LOAD may wait at action stations indefinitely. FIRE
            -- gets a fresh execution timeout even though it reuses the load ID.
            startedAt = now,
            phase = "loading",
            phaseStartedAt = now,
            loadDeadline = now + CONFIG.fire_load_phase_timeout_s * 1000,
            orderedDuration = promoted.orderedDuration or CONFIG.ripple_duration_s,
            actualDuration = 0,
        }
        local selectedCount, selectedNode = 0, nil
        for _, entry in pairs(firePlan.entries) do
            selectedCount = selectedCount + 1
            selectedNode = selectedNode or entry.node
            entry.fireDelayMs = 0
            entry.fired = false
            entry.lastSent = 0
        end
        if firePlan.mode == "single" and selectedNode then
            singleFireCursor[firePlan.side] = cursorForNode(selectedNode)
        end
        statusLine = string.format(
            "%s %s armed: waiting for %d selected loader%s",
            firePlan.side, firePlan.mode, selectedCount,
            selectedCount == 1 and "" or "s")
    else
        local guns, side = gunsForOrder(layout, true, true)
        if #guns == 0 then statusLine = "No active guns in " .. side .. " battery" return end
        local orderId = string.format("fire-%d-%d", os.getComputerID(), now)
        firePlan = {
            orderId = orderId,
            side = side,
            mode = fireMode,
            projectile = CONFIG.projectile_name,
            solution = solution,
            entries = {},
            startedAt = now,
            phase = "loading",
            phaseStartedAt = now,
            loadDeadline = now + CONFIG.fire_load_phase_timeout_s * 1000,
            orderedDuration = CONFIG.ripple_duration_s,
            actualDuration = 0,
        }
        for index, node in ipairs(guns) do
            firePlan.entries[node.id] = {
                node = node,
                fireDelayMs = 0,
                sequenceIndex = index,
                accepted = false,
                loaded = false,
                fired = false,
                failed = false,
                lastSent = 0,
            }
        end
        statusLine = string.format(
            "Loading %d %s gun%s before %s",
            #guns, side, #guns == 1 and "" or "s", fireMode)
    end
end

local function releaseLoadedFirePlan(now)
    local survivorNodes, failedCount = {}, 0
    for _, entry in pairs(firePlan.entries) do
        if entry.loaded and not entry.failed then
            survivorNodes[#survivorNodes + 1] = entry.node
        else
            failedCount = failedCount + 1
        end
    end
    table.sort(survivorNodes, fireSlotLess)
    if firePlan.mode == "ripple" then
        survivorNodes = shuffleSameStationGroups(survivorNodes)
    end
    if #survivorNodes == 0 then
        local side, mode = firePlan.side, firePlan.mode
        firePlan = nil
        statusLine = string.format(
            "%s %s cancelled: no selected gun loaded (%d skipped)",
            side, mode, failedCount)
        return
    end

    local rippleOffsets, actualDuration = {}, 0
    if firePlan.mode == "ripple" then
        -- Recompute timing only across survivors, so a failed loader leaves no
        -- dead slot and the live guns still span the ordered broadside.
        rippleOffsets, actualDuration = buildRippleOffsets(#survivorNodes)
    end
    for index, node in ipairs(survivorNodes) do
        local entry = firePlan.entries[node.id]
        entry.sequenceIndex = index
        entry.fireDelayMs = (rippleOffsets[index] or 0) * 1000
        entry.accepted = false
        entry.lastSent = 0
    end
    firePlan.phase = "firing"
    firePlan.phaseStartedAt = now
    firePlan.actualDuration = actualDuration
    firePlan.fireDeadline = now
        + actualDuration * 1000
        + CONFIG.fire_ack_grace_s * 1000
    statusLine = string.format(
        "Load barrier complete: %d ready, %d skipped; releasing %s",
        #survivorNodes, failedCount, firePlan.mode)
end

local function serviceFirePlan()
    if not firePlan then return end
    local now = nowMs()
    if now - firePlan.startedAt > CONFIG.fire_order_timeout_s * 1000 then
        local expired = firePlan
        firePlan = nil
        for nodeId in pairs(expired.entries) do
            safeSend(nodeId, {
                type = "cancel",
                version = CONFIG.protocol_version,
                orderId = expired.orderId,
            })
        end
        statusLine = "Fire order timed out and was cancelled"
        return
    end

    if firePlan.phase == "loading" then
        local allResolved = true
        for nodeId, entry in pairs(firePlan.entries) do
            if not entry.loaded and not entry.failed then
                if now >= firePlan.loadDeadline then
                    entry.failed = true
                    safeSend(nodeId, {
                        type = "cancel",
                        version = CONFIG.protocol_version,
                        orderId = firePlan.orderId,
                    })
                else
                    allResolved = false
                    if now - entry.lastSent >= CONFIG.load_resend_s * 1000 then
                        safeSend(nodeId, {
                            type = "load",
                            version = CONFIG.protocol_version,
                            orderId = firePlan.orderId,
                            projectile = firePlan.projectile,
                            validUntil = firePlan.loadDeadline,
                        })
                        entry.lastSent = now
                    end
                end
            end
        end
        if now >= firePlan.loadDeadline then allResolved = true end
        if allResolved then releaseLoadedFirePlan(now) end
        return
    end

    local allFinished, firedCount, failedCount = true, 0, 0
    for nodeId, entry in pairs(firePlan.entries) do
        if entry.fired then firedCount = firedCount + 1 end
        if entry.failed then failedCount = failedCount + 1 end
        if not entry.fired and not entry.failed then
            if firePlan.fireDeadline and now >= firePlan.fireDeadline then
                entry.failed = true
                failedCount = failedCount + 1
                safeSend(nodeId, {
                    type = "cancel",
                    version = CONFIG.protocol_version,
                    orderId = firePlan.orderId,
                })
            else
                allFinished = false
                local resendAfter = entry.accepted
                    and CONFIG.fire_refresh_s or CONFIG.fire_resend_s
                if now - entry.lastSent >= resendAfter * 1000 then
                    local currentSolution = firePlan.solution
                    if not firePlan.solution.manual
                        and lastSolution and not lastSolution.manual then
                        currentSolution = lastSolution
                    end
                    safeSend(nodeId, addAimFields({
                        type = "load_fire",
                        version = CONFIG.protocol_version,
                        orderId = firePlan.orderId,
                        projectile = firePlan.projectile,
                        fireDelayMs = entry.fireDelayMs,
                        validUntil = firePlan.fireDeadline,
                    }, currentSolution))
                    entry.lastSent = now
                end
            end
        end
    end
    if allFinished then
        statusLine = string.format("%s %s complete: %d fired, %d failed",
            firePlan.side, firePlan.mode, firedCount, failedCount)
        firePlan = nil
    end
end

local function beginLoadOrder()
    if firePlan then statusLine = "Cannot issue LOAD during an active fire order" return end
    if loadPlan then statusLine = "A load order is already active" return end
    if nowMs() < emergencyUntil then statusLine = "Emergency abort broadcast is still active" return end
    local layout, layoutError = analyzeLayout()
    if not layout then statusLine = layoutError return end
    local guns, side = gunsForOrder(layout, false, false)
    if #guns == 0 then statusLine = "No active guns in " .. side .. " battery" return end
    local orderId = string.format("load-%d-%d", os.getComputerID(), nowMs())
    loadPlan = {
        orderId = orderId,
        side = side,
        mode = fireMode,
        projectile = CONFIG.projectile_name,
        entries = {},
        startedAt = nowMs(),
        phase = "loading",
        orderedDuration = CONFIG.ripple_duration_s,
    }
    for index, node in ipairs(guns) do
        loadPlan.entries[node.id] = {
            node = node,
            sequenceIndex = index,
            accepted = false,
            loaded = false,
            failed = false,
            lastSent = 0,
        }
    end
    statusLine = string.format("Loading %d %s gun%s with %s",
        #guns, side, #guns == 1 and "" or "s", CONFIG.projectile_name)
end

local function serviceLoadPlan()
    if not loadPlan then return end
    if loadPlan.phase == "ready" then return end
    local now = nowMs()
    if now - loadPlan.startedAt > CONFIG.load_order_timeout_s * 1000 then
        local loadedCount, failedCount = 0, 0
        for nodeId, entry in pairs(loadPlan.entries) do
            if entry.loaded then
                loadedCount = loadedCount + 1
            else
                if not entry.failed then
                    entry.failed = true
                    safeSend(nodeId, {
                        type = "cancel",
                        version = CONFIG.protocol_version,
                        orderId = loadPlan.orderId,
                    })
                end
                failedCount = failedCount + 1
            end
        end
        loadPlan.phase = "ready"
        statusLine = string.format(
            "%s load closed: %d loaded, %d skipped; FIRE or ABORT",
            loadPlan.side, loadedCount, failedCount)
        return
    end
    local allFinished, loadedCount, failedCount = true, 0, 0
    for nodeId, entry in pairs(loadPlan.entries) do
        if entry.loaded then loadedCount = loadedCount + 1 end
        if entry.failed then failedCount = failedCount + 1 end
        if not entry.loaded and not entry.failed then
            allFinished = false
            if now - entry.lastSent >= CONFIG.load_resend_s * 1000 then
                safeSend(nodeId, {
                    type = "load",
                    version = CONFIG.protocol_version,
                    orderId = loadPlan.orderId,
                    projectile = loadPlan.projectile,
                    validUntil = loadPlan.startedAt + CONFIG.load_order_timeout_s * 1000,
                })
                entry.lastSent = now
            end
        end
    end
    if allFinished then
        loadPlan.phase = "ready"
        statusLine = string.format(
            "%s load complete: %d loaded, %d failed; FIRE or ABORT",
            loadPlan.side, loadedCount, failedCount)
    end
end

local function cancelAllOrders(reason)
    local plans = {firePlan, loadPlan}
    for _, plan in ipairs(plans) do
        if plan then
            for nodeId in pairs(plan.entries) do
                safeSend(nodeId, {
                    type = "cancel",
                    version = CONFIG.protocol_version,
                    orderId = plan.orderId,
                })
            end
        end
    end
    firePlan, loadPlan = nil, nil
    statusLine = reason or "All active orders cancelled"
end

local function emergencyPacket()
    return {
        type = "emergency_abort",
        version = CONFIG.protocol_version,
        orderId = "abort-" .. tostring(nowMs()),
    }
end

local function transmitEmergencyAbort()
    safeBroadcast(emergencyPacket())
    for nodeId in pairs(nodes) do safeSend(nodeId, emergencyPacket()) end
    lastEmergencySentAt = nowMs()
end

local function emergencyAbort()
    firePlan, loadPlan = nil, nil
    emergencyUntil = nowMs() + CONFIG.emergency_broadcast_s * 1000
    lastEmergencySentAt = 0
    transmitEmergencyAbort()
    statusLine = "EMERGENCY ABORT: all load/fire orders stopped"
end

local function serviceEmergencyAbort()
    if nowMs() >= emergencyUntil then return end
    if nowMs() - lastEmergencySentAt >= CONFIG.emergency_resend_s * 1000 then
        transmitEmergencyAbort()
    end
end

local function readWhileNetworking()
    local result
    parallel.waitForAny(
        function()
            result = read()
        end,
        function()
            while true do
                local event, a, b, c = os.pullEvent()
                if event == "rednet_message" and c == CONFIG.protocol then
                    handleNetwork(a, b)
                elseif event == "peripheral" or event == "peripheral_detach" then
                    modemName = nil
                    modemNames = {}
                    monitor, monitorName = nil, nil
                    ensureModem()
                    sendDiscovery(true)
                    ensureMonitor()
                end
            end
        end
    )
    return result or ""
end

local function promptNumber(label, current)
    write(string.format("%s [%.2f]: ", label, current))
    local value = readWhileNetworking()
    if value == "" then return current end
    return tonumber(value) or current
end

local function parseCoordinateString(value)
    local numbers = {}
    for token in tostring(value or ""):gmatch("[-+]?%d*%.?%d+") do
        numbers[#numbers + 1] = tonumber(token)
    end
    if #numbers ~= 3 then return nil end
    return vec(numbers[1], numbers[2], numbers[3])
end

local function promptTarget()
    if firePlan or loadPlan then statusLine = "Target locked while an order is active" return end
    term.clear(); term.setCursorPos(1, 1)
    print("=== Set Target ===")
    print("Paste X Y Z (spaces, commas, and labels accepted),")
    write("or press Enter for separate fields: ")
    local pasted = readWhileNetworking()
    if pasted ~= "" then
        local parsed = parseCoordinateString(pasted)
        if parsed then
            target = parsed
            lastAimAt = 0
            statusLine = "Target pasted successfully"
            return
        end
        print("Could not find exactly three coordinates; enter separately.")
    end
    local old = target or vec(0, 0, 0)
    target = vec(promptNumber("Target X", old.x), promptNumber("Target Y", old.y), promptNumber("Target Z", old.z))
    lastAimAt = 0
    statusLine = "Target updated"
end

local function promptRipple()
    term.clear(); term.setCursorPos(1, 1)
    CONFIG.ripple_duration_s = math.max(0, promptNumber("First-to-last ripple seconds", CONFIG.ripple_duration_s))
    statusLine = "Ripple duration updated"
end

local function promptProjectile()
    if firePlan or loadPlan then statusLine = "Projectile locked while an order is active" return end
    term.clear(); term.setCursorPos(1, 1)
    print("=== Select Projectile ===")
    print("Fixed load: 1 chamber, 5 unrifled barrels, 1 full big cartridge")
    for index, projectile in ipairs(PROJECTILES) do
        local marker = index == projectileIndex and "*" or " "
        print(string.format("%s %2d) %-18s %.1f kg", marker, index, projectile.name, projectile.mass))
    end
    local selected = math.floor(promptNumber("Projectile number", projectileIndex))
    local ok, errorMessage = applyProjectile(selected)
    if ok then
        statusLine = string.format("Projectile: %s, v0 %.2f m/s", CONFIG.projectile_name, CONFIG.muzzle_speed)
    else
        statusLine = "Projectile selection failed: " .. tostring(errorMessage)
    end
end

local function cycleProjectile()
    if firePlan or loadPlan then statusLine = "Projectile locked while an order is active" return end
    local nextIndex = projectileIndex % #PROJECTILES + 1
    local ok, errorMessage = applyProjectile(nextIndex)
    if ok then
        statusLine = string.format("Projectile: %s, v0 %.2f m/s", CONFIG.projectile_name, CONFIG.muzzle_speed)
    else
        statusLine = "Projectile selection failed: " .. tostring(errorMessage)
    end
end

local function setSide(side)
    if side ~= "port" and side ~= "starboard" and side ~= "bow" then return end
    if firePlan or loadPlan then statusLine = "Broadside locked while an order is active" return end
    if side == "bow" and aimMode ~= "manual" then
        statusLine = "Bow chasers are available in manual aim mode only"
        return
    end
    sideMode = side
    lastAimAt = 0
    statusLine = "Broadside selection: " .. sideMode
end

local function cycleSide()
    if aimMode == "manual" then
        setSide(sideMode == "port" and "starboard"
            or sideMode == "starboard" and "bow" or "port")
    else
        setSide(sideMode == "port" and "starboard" or "port")
    end
end

local function setFireMode(mode)
    if mode ~= "ripple" and mode ~= "salvo" and mode ~= "single" then return end
    if firePlan or loadPlan then statusLine = "Fire mode locked while an order is active" return end
    fireMode = mode
    statusLine = "Fire mode: " .. fireMode
end

local function cycleFireMode()
    setFireMode(fireMode == "ripple" and "salvo"
        or fireMode == "salvo" and "single" or "ripple")
end

local function setGunCountMode(value)
    if value ~= 1 and value ~= 5 and value ~= 10 and value ~= "full" then return end
    if firePlan or loadPlan then statusLine = "Gun count locked while an order is active" return end
    gunCountMode = value
    statusLine = "Gun count: " .. (value == "full" and "FULL" or tostring(value))
end

local function cycleGunCountMode()
    setGunCountMode(gunCountMode == 1 and 5
        or gunCountMode == 5 and 10
        or gunCountMode == 10 and "full" or 1)
end

local function setAimMode(mode)
    if mode ~= "automatic" and mode ~= "manual" then return end
    if firePlan or loadPlan then statusLine = "Aim mode locked while an order is active" return end
    aimMode = mode
    if mode == "automatic" and sideMode == "bow" then sideMode = "port" end
    lastAimAt = 0
    lastSolution = nil
    lastSolutionError = mode == "manual" and nil or (target and "Calculating" or "No target")
    for _, node in pairs(nodes) do node.aimReady = nil end
    statusLine = mode == "manual"
        and ("Manual broadside aim: " .. sideMode)
        or "Automatic target-coordinate aim"
end

local function toggleAimMode()
    setAimMode(aimMode == "automatic" and "manual" or "automatic")
end

local function adjustManualAim(yawDelta, elevationDelta)
    if aimMode ~= "manual" then statusLine = "Enable MANUAL aim first" return end
    if firePlan or loadPlan then statusLine = "Manual aim locked while an order is active" return end
    local setting = manualAim[sideMode]
    setting.yaw = clamp(setting.yaw + (yawDelta or 0),
        CONFIG.manual_min_yaw_deg, CONFIG.manual_max_yaw_deg)
    setting.elevation = clamp(setting.elevation + (elevationDelta or 0),
        CONFIG.manual_min_elevation_deg, CONFIG.manual_max_elevation_deg)
    lastAimAt = 0
    statusLine = string.format("%s manual yaw/elev %+.1f / %+.1f",
        sideMode, setting.yaw, setting.elevation)
end

local function promptManualAim()
    if aimMode ~= "manual" then statusLine = "Enable MANUAL aim first" return end
    if firePlan or loadPlan then statusLine = "Manual aim locked while an order is active" return end
    term.clear(); term.setCursorPos(1, 1)
    print("=== Manual " .. string.upper(sideMode) .. " Broadside Aim ===")
    local setting = manualAim[sideMode]
    setting.yaw = clamp(promptNumber("Yaw from center", setting.yaw),
        CONFIG.manual_min_yaw_deg, CONFIG.manual_max_yaw_deg)
    setting.elevation = clamp(promptNumber("Elevation", setting.elevation),
        CONFIG.manual_min_elevation_deg, CONFIG.manual_max_elevation_deg)
    lastAimAt = 0
    statusLine = string.format("%s manual yaw/elev %+.1f / %+.1f",
        sideMode, setting.yaw, setting.elevation)
end

local function toggleArc()
    if firePlan or loadPlan then statusLine = "Arc locked while an order is active" return end
    arc = arc == "low" and "high" or "low"
    lastAimAt = 0
    statusLine = "Trajectory arc: " .. arc
end

local function adjustRipple(delta)
    if firePlan or loadPlan then
        statusLine = "Ripple timing locked while an order is active"
        return
    end
    CONFIG.ripple_duration_s = math.max(0, CONFIG.ripple_duration_s + delta)
    statusLine = string.format("Ripple duration: %.1fs", CONFIG.ripple_duration_s)
end

local function planProgress(plan)
    local total, loaded, fired, failed = 0, 0, 0, 0
    if not plan then return total, loaded, fired, failed end
    for _, entry in pairs(plan.entries) do
        total = total + 1
        if entry.loaded then loaded = loaded + 1 end
        if entry.fired then fired = fired + 1 end
        if entry.failed then failed = failed + 1 end
    end
    return total, loaded, fired, failed
end

local function short(value, width)
    value = tostring(value or "")
    return #value <= width and value or value:sub(1, width - 1) .. "~"
end

local function monitorWriteAt(x, y, value, textColor, backgroundColor)
    if textColor then monitor.setTextColor(textColor) end
    if backgroundColor then monitor.setBackgroundColor(backgroundColor) end
    monitor.setCursorPos(x, y)
    monitor.write(value)
end

local function addMonitorButton(id, x1, y1, x2, y2, label, active, buttonColor)
    local width, height = monitor.getSize()
    x1, x2 = math.max(1, x1), math.min(width, x2)
    y1, y2 = math.max(1, y1), math.min(height, y2)
    if x1 > x2 or y1 > y2 then return end
    local background = active and (buttonColor or colors.blue) or colors.gray
    for y = y1, y2 do
        monitorWriteAt(x1, y, string.rep(" ", x2 - x1 + 1), colors.white, background)
    end
    local labelX = x1 + math.max(0, math.floor((x2 - x1 + 1 - #label) / 2))
    local labelY = y1 + math.floor((y2 - y1) / 2)
    monitorWriteAt(labelX, labelY, short(label, x2 - labelX + 1), colors.white, background)
    monitorButtons[#monitorButtons + 1] = {id = id, x1 = x1, y1 = y1, x2 = x2, y2 = y2}
end

local function drawMonitor(force)
    if not force and nowMs() - lastMonitorDrawAt < 250 then return end
    if not ensureMonitor() then return end
    local ok = pcall(function()
        local width, height = monitor.getSize()
        monitorButtons = {}
        monitor.setBackgroundColor(colors.black)
        monitor.setTextColor(colors.white)
        monitor.clear()
        if width < 30 or height < 28 then
            monitorWriteAt(1, 1, "Monitor too small; use more blocks or text scale 0.5", colors.red, colors.black)
            return
        end

        local controlsLocked = firePlan ~= nil or loadPlan ~= nil
        local function optionColor(normalColor)
            return controlsLocked and colors.lightGray or normalColor
        end

        local transmitSummary = lastSentType
            and string.format(" TX:%d/%s>%s RX:%d", sentPacketCount,
                lastSentType:sub(1, 9), tostring(lastSentRecipient),
                receivedPacketCount)
            or string.format(" TX:0/- RX:%d", receivedPacketCount)
        monitorWriteAt(2, 1, short(
            "PHOENIX FIRE CONTROL AUTH:"
                .. (CONFIG.security_enabled and "ON" or "OFF")
                .. transmitSummary,
            width - 2), colors.yellow, colors.black)
        local half = math.floor(width / 2)
        if aimMode == "manual" then
            local sideThird = math.floor((width - 2) / 3)
            addMonitorButton("side_port", 2, 2, 1 + sideThird, 4,
                "PORT", sideMode == "port", optionColor(colors.blue))
            addMonitorButton("side_starboard", 2 + sideThird, 2, 1 + sideThird * 2, 4,
                "STARBOARD", sideMode == "starboard", optionColor(colors.blue))
            addMonitorButton("side_bow", 2 + sideThird * 2, 2, width - 1, 4,
                "BOW", sideMode == "bow", optionColor(colors.blue))
        else
            addMonitorButton("side_port", 2, 2, half - 1, 4,
                "PORT", sideMode == "port", optionColor(colors.blue))
            addMonitorButton("side_starboard", half + 1, 2, width - 1, 4,
                "STARBOARD", sideMode == "starboard", optionColor(colors.blue))
        end
        local third = math.floor((width - 2) / 3)
        addMonitorButton("mode_ripple", 2, 5, 1 + third, 7,
            "RIPPLE", fireMode == "ripple", optionColor(colors.purple))
        addMonitorButton("mode_salvo", 2 + third, 5, 1 + third * 2, 7,
            "SALVO", fireMode == "salvo", optionColor(colors.purple))
        addMonitorButton("mode_single", 2 + third * 2, 5, width - 1, 7,
            "SINGLE", fireMode == "single", optionColor(colors.purple))

        local quarter = math.floor((width - 2) / 4)
        addMonitorButton("count_1", 2, 8, 1 + quarter, 10,
            "1 GUN", gunCountMode == 1, optionColor(colors.green))
        addMonitorButton("count_5", 2 + quarter, 8, 1 + quarter * 2, 10,
            "5 GUNS", gunCountMode == 5, optionColor(colors.green))
        addMonitorButton("count_10", 2 + quarter * 2, 8, 1 + quarter * 3, 10,
            "10 GUNS", gunCountMode == 10, optionColor(colors.green))
        addMonitorButton("count_full", 2 + quarter * 3, 8, width - 1, 10,
            "FULL", gunCountMode == "full", optionColor(colors.green))

        addMonitorButton("ripple_minus", 2, 11, 7, 13, "-5S", false, colors.gray)
        addMonitorButton("ripple_plus", 9, 11, 14, 13, "+5S", false, colors.gray)
        monitorWriteAt(15, 12, short(string.format("%.0fs", CONFIG.ripple_duration_s),
            math.max(1, width - 29)), colors.white, colors.black)
        addMonitorButton("aim_mode", math.max(18, width - 11), 11, width - 1, 13,
            aimMode == "manual" and "MANUAL" or "AUTO", true,
            optionColor(aimMode == "manual" and colors.orange or colors.cyan))

        if aimMode == "manual" then
            addMonitorButton("manual_yaw_minus", 2, 14, 1 + quarter, 16, "YAW-", false, colors.gray)
            addMonitorButton("manual_yaw_plus", 2 + quarter, 14, 1 + quarter * 2, 16, "YAW+", false, colors.gray)
            addMonitorButton("manual_elev_minus", 2 + quarter * 2, 14, 1 + quarter * 3, 16, "EL-", false, colors.gray)
            addMonitorButton("manual_elev_plus", 2 + quarter * 3, 14, width - 1, 16, "EL+", false, colors.gray)
            addMonitorButton("projectile", 2, 17, width - 1, 19,
                short("SHELL: " .. string.upper(CONFIG.projectile_name), width - 4),
                true, optionColor(colors.brown))
        else
            addMonitorButton("projectile", 2, 17, half - 1, 19,
                short("PROJ: " .. string.upper(CONFIG.projectile_name), half - 3),
                true, optionColor(colors.brown))
            addMonitorButton("arc", half + 1, 17, width - 1, 19,
                string.upper(arc) .. " ARC", true, optionColor(colors.cyan))
        end

        local layout = analyzeLayout()
        local knownCount = 0
        for _ in pairs(nodes) do knownCount = knownCount + 1 end
        local informationRow = 20
        if aimMode == "manual" then
            local setting = manualAim[sideMode]
            monitorWriteAt(2, informationRow, short(string.format("MANUAL %s  Yaw %+.1f  Elev %+.1f",
                string.upper(sideMode), setting.yaw, setting.elevation), width - 2), colors.orange, colors.black)
        elseif target then
            monitorWriteAt(2, informationRow, short(string.format("Target %.1f, %.1f, %.1f", target.x, target.y, target.z), width - 2), colors.white, colors.black)
        else
            monitorWriteAt(2, informationRow, "NO TARGET - use T on computer", colors.red, colors.black)
        end
        if lastSolution and lastSolution.manual then
            monitorWriteAt(2, informationRow + 1, "Direct broadside aim - no ballistic solution", colors.orange, colors.black)
        elseif lastSolution then
            monitorWriteAt(2, informationRow + 1, short(string.format("v0 %.2f  Yaw %.2f  Elev %.2f  Range %.0f", CONFIG.muzzle_speed, lastSolution.worldYaw, lastSolution.pitch, lastSolution.range), width - 2), colors.lime, colors.black)
        else
            monitorWriteAt(2, informationRow + 1, short("No solution: " .. tostring(lastSolutionError), width - 2), colors.orange, colors.black)
        end
        if layout then
            monitorWriteAt(2, informationRow + 2, short(string.format("Online %d/%d P:%d S:%d Bow:%d",
                #layout.nodes, knownCount, layout.counts.port,
                layout.counts.starboard, layout.counts.bow), width - 2), colors.lightGray, colors.black)
            monitorWriteAt(2, informationRow + 3, "ID   BATTERY   STATION  AIM / LOADER", colors.lightGray, colors.black)
            local row = informationRow + 4
            for _, node in ipairs(layout.nodes) do
                if row > height - 5 then break end
                local state = node.error and "LIMIT"
                    or node.loaderError and "LOAD ERR"
                    or node.loadedProjectile and ("LOADED " .. node.loadedProjectile)
                    or node.loaderState or "READY"
                local color = (node.error or node.loaderError) and colors.orange or colors.lime
                monitorWriteAt(2, row, short(string.format("%-4d %-9s %7.2f  %s",
                    node.id, node.batteryLabel, node.station, state), width - 2), color, colors.black)
                row = row + 1
            end
        else
            monitorWriteAt(2, informationRow + 2, short("No active guns: " .. tostring(select(2, analyzeLayout())), width - 2), colors.red, colors.black)
            local known = knownNodes()
            if known[1] then
                monitorWriteAt(2, informationRow + 3, short(string.format("Gun %d: %s", known[1].id, nodeInactiveReason(known[1]) or "inactive"), width - 2), colors.orange, colors.black)
            end
        end

        monitorWriteAt(2, height - 4, short(statusLine, width - 2), colors.yellow, colors.black)
        local bottomThird = math.floor((width - 2) / 3)
        local loadLabel = "LOAD"
        if loadPlan then
            loadLabel = loadPlan.phase == "ready" and "LOADED" or "LOADING..."
        elseif firePlan then
            loadLabel = firePlan.phase == "loading" and "LOADING..." or "LOCKED"
        end
        addMonitorButton("load", 2, height - 3, 1 + bottomThird, height - 1,
            loadLabel,
            not firePlan and not loadPlan, colors.brown)
        addMonitorButton("emergency_abort", 2 + bottomThird, height - 3,
            1 + bottomThird * 2, height - 1, "EMERGENCY ABORT", true, colors.red)
        local fireLabel = "FIRE " .. string.upper(sideMode)
        local fireEnabled = firePlan == nil
        if firePlan then
            local total, loaded, fired, failed = planProgress(firePlan)
            if firePlan.phase == "loading" then
                fireLabel = string.format("WAIT %d/%d", loaded + failed, total)
            else
                fireLabel = string.format("FIRING %d/%d", fired + failed, total)
            end
        elseif loadPlan then
            local total, loaded, _, failed = planProgress(loadPlan)
            fireLabel = loadPlan.phase == "ready"
                and string.format("FIRE %d READY", loaded)
                or string.format("ARM FIRE %d/%d", loaded + failed, total)
        elseif fireMode == "single" and layout then
            local eligible = selectedGuns(layout, true)
            local nextGun = nextSingleGun(eligible, sideMode)
            fireLabel = nextGun and ("FIRE " .. nextGun.batteryLabel) or "NO READY GUN"
        end
        addMonitorButton("fire", 2 + bottomThird * 2, height - 3, width - 1, height - 1,
            fireLabel, fireEnabled, colors.red)
    end)
    if not ok then
        monitor, monitorName = nil, nil
        monitorButtons = {}
        return
    end
    lastMonitorDrawAt = nowMs()
end

local function handleMonitorTouch(side, x, y)
    if not monitorName or side ~= monitorName then return end
    for _, button in ipairs(monitorButtons) do
        if x >= button.x1 and x <= button.x2 and y >= button.y1 and y <= button.y2 then
            local controlsLocked = firePlan ~= nil or loadPlan ~= nil
            if controlsLocked
                and button.id ~= "fire"
                and button.id ~= "emergency_abort" then
                statusLine = "Order locked: only FIRE or EMERGENCY ABORT is available"
            elseif button.id == "side_port" then setSide("port")
            elseif button.id == "side_starboard" then setSide("starboard")
            elseif button.id == "side_bow" then setSide("bow")
            elseif button.id == "mode_ripple" then setFireMode("ripple")
            elseif button.id == "mode_salvo" then setFireMode("salvo")
            elseif button.id == "mode_single" then setFireMode("single")
            elseif button.id == "count_1" then setGunCountMode(1)
            elseif button.id == "count_5" then setGunCountMode(5)
            elseif button.id == "count_10" then setGunCountMode(10)
            elseif button.id == "count_full" then setGunCountMode("full")
            elseif button.id == "ripple_minus" then adjustRipple(-CONFIG.ripple_adjust_s)
            elseif button.id == "ripple_plus" then adjustRipple(CONFIG.ripple_adjust_s)
            elseif button.id == "aim_mode" then toggleAimMode()
            elseif button.id == "manual_yaw_minus" then adjustManualAim(-CONFIG.manual_yaw_step_deg, 0)
            elseif button.id == "manual_yaw_plus" then adjustManualAim(CONFIG.manual_yaw_step_deg, 0)
            elseif button.id == "manual_elev_minus" then adjustManualAim(0, -CONFIG.manual_elevation_step_deg)
            elseif button.id == "manual_elev_plus" then adjustManualAim(0, CONFIG.manual_elevation_step_deg)
            elseif button.id == "arc" then toggleArc()
            elseif button.id == "projectile" then cycleProjectile()
            elseif button.id == "load" then beginLoadOrder()
            elseif button.id == "emergency_abort" then emergencyAbort()
            elseif button.id == "fire" then beginFireOrder() end
            drawMonitor(true)
            return
        end
    end
end

local function draw()
    local width, height = term.getSize()
    term.clear(); term.setCursorPos(1, 1)
    print("=== Phoenix Central Fire Control ===")
    local layout, layoutError = analyzeLayout()
    lastLayout = layout
    local knownCount = 0
    for _ in pairs(nodes) do knownCount = knownCount + 1 end
    if layout then
        local chosen = selectedSide(layout)
        print(string.format("Guns:%d/%d P:%d S:%d Bow:%d Selected:%s",
            #layout.nodes, knownCount, layout.counts.port,
            layout.counts.starboard, layout.counts.bow, chosen))
        print(string.format("Deck midpoint: %.1f %.1f %.1f", layout.center.x, layout.center.y, layout.center.z))
        print(string.format("Heading:%.1f  Explicit battery topology", layout.heading))
    else
        print("Layout: " .. tostring(layoutError))
        print(string.format("Known:%d Modems:%d %s Auth:%s", knownCount, #modemNames, modemName and "online" or "offline", CONFIG.security_enabled and "ON" or "OFF"))
    end
    if aimMode == "manual" then
        local setting = manualAim[sideMode]
        print(string.format("Manual %s yaw/elev: %+.1f / %+.1f",
            sideMode, setting.yaw, setting.elevation))
    elseif target then
        print(string.format("Target: %.1f %.1f %.1f  Arc:%s", target.x, target.y, target.z, arc))
    else
        print("Target: not set (press T)")
    end
    print(short(string.format("Aim:%s Fire:%s Count:%s Projectile:%s Auth:%s TX:%d/%s>%s RX:%d",
        aimMode, fireMode, gunCountMode == "full" and "FULL" or tostring(gunCountMode),
        CONFIG.projectile_name, CONFIG.security_enabled and "ON" or "OFF",
        sentPacketCount, tostring(lastSentType or "-"),
        tostring(lastSentRecipient or "-"), receivedPacketCount), width))
    print(short(string.format("Fixed 1ch/5u/full cart v0:%.2f Drag:%s Solve:%dms Ripple:%.1fs",
        CONFIG.muzzle_speed, CONFIG.drag_enabled and "on" or "off",
        lastSolveMs, CONFIG.ripple_duration_s), width))
    if lastSolution and lastSolution.manual then
        print(string.format("Direct aim yaw/elev: %+.2f / %+.2f",
            lastSolution.yawFromCenter, lastSolution.pitch))
        print("Ballistic target solution bypassed")
    elseif lastSolution then
        print(string.format("Solution yaw/pitch: %.2f / %.2f", lastSolution.worldYaw, lastSolution.pitch))
        print(string.format("Range:%.1f  TOF:%.2fs", lastSolution.range, lastSolution.tof))
    else
        print("Solution: " .. tostring(lastSolutionError))
    end
    print(short(statusLine, width))
    print("")
    print("ID  Battery   Station Deck/Gun State")
    if layout then
        local room = math.max(0, height - 14)
        for index, node in ipairs(layout.nodes) do
            if index > room then break end
            local slotText = node.batteryRole == "bow_chaser"
                and ("BC/" .. tostring(node.chaserNumber))
                or string.format("%d/%d", node.deckNumber, node.gunNumber)
            local nodeState = node.error and "LIMIT"
                or node.loaderError and "LOAD ERR"
                or node.loadedProjectile and ("LOADED " .. node.loadedProjectile)
                or node.loaderState or "OK"
            print(string.format("%-3d %-9s %7.2f  %-5s %s",
                node.id, short(node.batteryLabel, 9), node.station,
                slotText, nodeState))
        end
    else
        local room = math.max(0, height - 14)
        for index, node in ipairs(knownNodes()) do
            if index > room then break end
            local reason = nodeInactiveReason(node) or tostring(layoutError)
            print(string.format("%-3d %-10s %7s       %s", node.id,
                short(node.batteryLabel or batteryLabel(node), 10), "--",
                short(reason, math.max(8, width - 31))))
        end
    end
    term.setCursorPos(1, height)
    write(short("D aim | X exact | F LOAD+FIRE | L LOAD | C EMERGENCY | G count | M mode | Q quit", width))
    drawMonitor(false)
end

local function tick()
    ensureModem()
    sendDiscovery(false)
    local layout, layoutError = analyzeLayout()
    lastLayout = layout
    if layout and (aimMode == "manual" or target)
        and nowMs() - lastAimAt >= CONFIG.aim_update_s * 1000 then
        lastSolution, lastSolutionError = solutionForMode(layout)
        if lastSolution then sendAim(layout, lastSolution) end
        lastAimAt = nowMs()
    elseif not layout then
        lastSolution, lastSolutionError = nil, layoutError
    elseif aimMode == "automatic" and not target then
        lastSolution, lastSolutionError = nil, "No target"
    end
    serviceLoadPlan()
    serviceFirePlan()
    serviceEmergencyAbort()
    draw()
end

local function main()
    initializeRandom()
    local startupOk, startupError = ensureStartupLauncher()
    if not startupOk then statusLine = "STARTUP INSTALL: " .. tostring(startupError) end
    local projectileOk, projectileError = applyProjectile(projectileIndex)
    if not projectileOk then error("Fixed cannon profile error: " .. tostring(projectileError)) end
    local securityOk, securityError = initializeSecurity()
    if not securityOk then error("Artillery security error: " .. tostring(securityError)) end
    ensureModem()
    sendDiscovery(true)
    ensureMonitor()
    -- Arm the periodic tick only after the initial monitor redraw. Monitor
    -- writes are yielding peripheral calls and may otherwise consume the timer
    -- event before the main loop begins waiting for it.
    draw()
    local timer = os.startTimer(0.10)
    while running do
        local event, a, b, c = os.pullEvent()
        if event == "rednet_message" and c == CONFIG.protocol then
            receivedPacketCount = receivedPacketCount + 1
            local ok, networkError = pcall(handleNetwork, a, b)
            if not ok then
                statusLine = "NETWORK HANDLER: " .. tostring(networkError)
            end
            -- HELLO/ACK processing can yield while sending WELCOME. Rearming
            -- here prevents that work from consuming the only service timer.
            timer = os.startTimer(0.10)
        elseif event == "peripheral" or event == "peripheral_detach" then
            modemName = nil
            modemNames = {}
            monitor, monitorName = nil, nil
            ensureModem()
            sendDiscovery(true)
            ensureMonitor()
            drawMonitor(true)
            timer = os.startTimer(0.10)
        elseif event == "monitor_touch" then
            handleMonitorTouch(a, b, c)
            -- handleMonitorTouch performs a full monitor redraw. Start a fresh
            -- tick afterward in case that redraw consumed the prior timer.
            timer = os.startTimer(0.10)
        elseif event == "timer" and a == timer then
            tick()
            timer = os.startTimer(0.10)
        elseif event == "key" then
            local controlsLocked = firePlan ~= nil or loadPlan ~= nil
            if a == keys.q then
                if firePlan or loadPlan then cancelAllOrders("Orders cancelled; shutting down") end
                running = false
            elseif a == keys.c then
                emergencyAbort()
            elseif controlsLocked then
                if a == keys.f then
                    beginFireOrder()
                else
                    statusLine = "Order locked: only F FIRE, C EMERGENCY, or Q quit"
                end
            elseif a == keys.t then promptTarget()
            elseif a == keys.r then promptRipple()
            elseif a == keys.p then promptProjectile()
            elseif a == keys.x then promptManualAim()
            elseif a == keys.d then toggleAimMode()
            elseif a == keys.left then adjustManualAim(-CONFIG.manual_yaw_step_deg, 0)
            elseif a == keys.right then adjustManualAim(CONFIG.manual_yaw_step_deg, 0)
            elseif a == keys.down then adjustManualAim(0, -CONFIG.manual_elevation_step_deg)
            elseif a == keys.up then adjustManualAim(0, CONFIG.manual_elevation_step_deg)
            elseif a == keys.s then cycleSide()
            elseif a == keys.m then cycleFireMode()
            elseif a == keys.g then cycleGunCountMode()
            elseif a == keys.a then toggleArc()
            elseif a == keys.f then beginFireOrder()
            elseif a == keys.l then beginLoadOrder()
            end
            draw()
            if running then timer = os.startTimer(0.10) end
        end
    end
    term.clear(); term.setCursorPos(1, 1)
    print("Central fire control stopped")
end

main()
