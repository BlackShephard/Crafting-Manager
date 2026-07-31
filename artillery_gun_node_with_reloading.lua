-- Phoenix networked artillery with automatic loading: per-cannon gun node.
-- Run one copy on each computer attached to a cannon_mount and wireless modem.

local CONFIG = {
    protocol = "phoenix.artillery.reloading.v1",
    protocol_version = 2,
    -- To secure the fleet, copy artillery_auth.lua to this computer and central,
    -- set enabled=true everywhere, and use the same long secret.
    security_enabled = false,
    shared_secret = "",
    auth_max_age_ms = 30000,
    -- Keep false while the original gun-node startup launcher exists.
    install_startup = false,
    restart_after_crash_s = 3.0,
    heartbeat_s = 2.0,
    discovery_reply_min_s = 3.0,
    display_refresh_s = 0.20,
    control_tick_s = 0.10,
    central_timeout_s = 15.0,
    monitor_text_scale = 0.5,
    fire_hold_s = 0.20,
    velocity_alpha = 0.70,
    nudge_step_deg = 0.1,
    coarse_nudge_step_deg = 5.0,

    -- The source inventory holds shells and fully filled big cartridges. The
    -- two depots are watched by separate input deployers. Leave these nil to
    -- auto-select the largest inventory as source and the two smallest other
    -- inventories as depots, or set exact names shown by node diagnostics.
    loader_enabled = true,
    loader_source_inventory = nil,
    loader_depot_inventories = nil,
    -- Legacy first-depot preference. When set without the list above, the
    -- second depot is still auto-discovered.
    loader_depot_inventory = nil,
    loader_shell_delay_s = 2.0,
    loader_cartridge_delay_s = 2.0,
    loader_state_file = "/.phoenix_artillery_loaded",

    -- Required battery identity. Deck 1 is topmost; gun 1 is nearest the bow.
    -- Central converts these simple values into the irregular horizontal order.
    -- Recommended quick form: "P-1-1", "S-3-10", etc. When set, it fills the
    -- expanded side/deck/gun fields below. If this and the expanded fields are
    -- unset, first startup prompts for an entry such as "S 3 4" and remembers
    -- it in battery_identity_file.
    battery_id = nil,
    battery_identity_file = "/.phoenix_artillery_battery",
    battery_role = "broadside",
    side_override = nil,
    deck_number = nil,
    gun_number = nil,
    chaser_number = nil,
    station_override = nil,
    gun_enabled = true,

    -- Default mount-frame conversion. Tune these for the assembled ship.
    yaw_command_mode = "ship_relative",
    auto_yaw_offset = 270,
    full_attitude_compensation = true,
    yaw_center_deg = 360,
    wrap_yaw_command = true,
    min_yaw_from_center_deg = -23,
    max_yaw_from_center_deg = 23,
    yaw_offset_deg = 0,
    pitch_offset_deg = 0,
    invert_yaw = false,
    invert_pitch = false,
    min_elevation_deg = -4,
    max_elevation_deg = 15,
    min_command_pitch = -360,
    max_command_pitch = 360,

    sable_offset_x = 0,
    sable_offset_y = 0,
    sable_offset_z = 0,
}

-- Item selection stays entirely on each node. Exact item IDs are preferred;
-- case-insensitive display names are a commissioning fallback. Add aliases
-- here if the modpack uses a different ammunition item ID.
local PROJECTILE_ITEMS = {
    ["Solid Shot"] = {
        ids = {"createbigcannons:solid_shot"},
        displayNames = {"Solid Shot"},
    },
    ["AP Shot"] = {
        ids = {"createbigcannons:ap_shot"},
        displayNames = {"AP Shot"},
    },
    ["Shrapnel Shell"] = {
        ids = {"createbigcannons:shrapnel_shell"},
        displayNames = {"Shrapnel Shell"},
    },
    ["AP Shell"] = {
        ids = {"createbigcannons:ap_shell"},
        displayNames = {"AP Shell"},
    },
    ["HE Shell"] = {
        ids = {"createbigcannons:he_shell"},
        displayNames = {"HE Shell", "High Explosive Shell"},
    },
    ["Shell Holder MkV"] = {
        ids = {"cbc_enhanced_shells:shell_holder_mk5"},
        displayNames = {"Shell Holder MkV", "Shell Holder Mk5"},
    },
    ["Fluid Shell"] = {
        ids = {"createbigcannons:fluid_shell"},
        displayNames = {"Fluid Shell"},
    },
    ["Drop Mortar Shell"] = {
        ids = {"createbigcannons:drop_mortar_shell"},
        displayNames = {"Drop Mortar Shell"},
    },
    ["Mortar Stone"] = {
        ids = {"createbigcannons:mortar_stone"},
        displayNames = {"Mortar Stone"},
    },
    ["Smoke Shell"] = {
        ids = {"createbigcannons:smoke_shell"},
        displayNames = {"Smoke Shell"},
    },
    ["Grapeshot Shell"] = {
        ids = {"createbigcannons:bag_of_grapeshot"},
        displayNames = {"Bag Of Grapeshot", "Grapeshot Shell"},
    },
}

local CARTRIDGE_ITEM = {
    ids = {"createbigcannons:big_cartridge"},
    displayNames = {"Big Cartridge"},
}

local DECK_GUN_COUNTS = {
    [1] = 8,
    [2] = 15,
    [3] = 14,
    [4] = 16,
}

-- Side profiles inherit every omitted value from CONFIG above. This lets the
-- same program be installed on every gun while port and starboard use different
-- mount-frame mappings. Uncomment and tune only the values that differ.
local SIDE_MOUNT_PROFILES = {
    port = {
        auto_yaw_offset = -90,
        -- yaw_offset_deg = 0,
        -- pitch_offset_deg = 0,
        -- invert_yaw = false,
        -- invert_pitch = false,
    },
    starboard = {
        auto_yaw_offset = 90,
        -- yaw_offset_deg = 0,
        -- pitch_offset_deg = 0,
        -- invert_yaw = false,
        -- invert_pitch = false,
    },
}

-- Optional final overrides for one unusual mount. Entries may use a numeric
-- computer ID or a computer label. ID overrides are applied last.
local GUN_MOUNT_OVERRIDES = {
    -- [8] = {yaw_offset_deg = 0.5, pitch_offset_deg = 0},
    -- ["Port bow"] = {invert_yaw = true},
}

local MOUNT_PROFILE_KEYS = {
    "yaw_command_mode", "auto_yaw_offset", "full_attitude_compensation",
    "yaw_center_deg", "wrap_yaw_command",
    "min_yaw_from_center_deg", "max_yaw_from_center_deg", "yaw_offset_deg",
    "pitch_offset_deg", "invert_yaw", "invert_pitch",
    "min_elevation_deg", "max_elevation_deg",
    "min_command_pitch", "max_command_pitch",
}

local centralId = nil
local centralLastSeen = 0
local lastHelloAt = 0
local assignedSide = CONFIG.side_override or "unassigned"
local pendingFire = nil
local loaderJob = nil
local loaderSourceName = nil
local loaderDepotName = nil
local loaderDepotNames = {}
local loaderOnline = false
local loaderState = "EMPTY"
local loaderError = nil
local loadedProjectile = nil
local completedLoads = {}
local emergencyStopRequested = false
local firing = false
local fireOffAt = nil
local fireSignalMount = nil
local lastCommand = "Waiting for central computer"
local lastError = nil
local lastAimState = nil
local lastRequestedAim = nil
local runtimeYawTrim = 0
local runtimePitchTrim = 0
local authModule = nil
local seenAuthNonces = {}
local authRejects = 0
local completedOrders = {}
local running = true
local modemName = nil
local modemNames = {}
local receivedPacketCount = 0
local lastReceivedType = nil
local lastReceivedSender = nil
local receivedOrderCount = 0
local lastReceivedOrderType = nil
local observedRednetCount = 0
local lastObservedSender = nil
local lastObservedProtocolMatches = nil
local lastObservedVersion = nil
local networkInbox = {}
local pendingAimPacket = nil
local pendingDiscoverPacket = nil
local pendingWelcomePacket = nil
local networkQueueDrops = 0
local networkHandlerError = nil
local NETWORK_INBOX_EVENT = "phoenix_artillery_network_inbox"
local NETWORK_QUEUE_LIMIT = 64
local monitor = nil
local monitorName = nil
local lastPose = nil
local lastPoseAt = nil
local velocity = {x = 0, y = 0, z = 0}

local function nowMs()
    return os.epoch("utc")
end

local function sideFromToken(token)
    token = tostring(token or ""):lower()
    if token == "p" or token == "port" then return "port", "P" end
    if token == "s" or token == "starboard" then return "starboard", "S" end
    return nil
end

local function parseBatteryIdentity(value)
    if type(value) ~= "string" then return nil, "identity must be text" end
    local separators = "[%s_%-]+"
    local chaserSide, chaserText = value:match(
        "^%s*[Bb][Cc]" .. separators .. "([%a]+)"
            .. separators .. "(%d+)%s*$"
    )
    if chaserSide then
        local side, sideLetter = sideFromToken(chaserSide)
        if not side then
            return nil, "bow-chaser side must be P/PORT or S/STARBOARD"
        end
        local chaserNumber = tonumber(chaserText)
        if not chaserNumber or chaserNumber < 1
            or chaserNumber % 1 ~= 0 then
            return nil, "bow-chaser number must be a positive whole number"
        end
        return {
            canonical = string.format("BC-%s-%d", sideLetter, chaserNumber),
            role = "bow_chaser",
            side = side,
            chaserNumber = chaserNumber,
        }
    end

    local sideToken, deckText, gunText = value:match(
        "^%s*([%a]+)" .. separators .. "(%d+)"
            .. separators .. "(%d+)%s*$"
    )
    if not sideToken then
        return nil, "use S 3 4, P-1-1, BC S 1, or BC-P-1"
    end
    local side, sideLetter = sideFromToken(sideToken)
    if not side then return nil, "side must be P/PORT or S/STARBOARD" end
    local deckNumber, gunNumber = tonumber(deckText), tonumber(gunText)
    local maximum = DECK_GUN_COUNTS[deckNumber]
    if not maximum then return nil, "deck must be 1, 2, 3, or 4" end
    if gunNumber < 1 or gunNumber > maximum or gunNumber % 1 ~= 0 then
        return nil, string.format(
            "deck %d gun number must be 1-%d", deckNumber, maximum)
    end
    return {
        canonical = string.format("%s-%d-%d", sideLetter, deckNumber, gunNumber),
        role = "broadside",
        side = side,
        deckNumber = deckNumber,
        gunNumber = gunNumber,
    }
end

local function applyBatteryIdentity(identity)
    CONFIG.battery_id = identity.canonical
    CONFIG.battery_role = identity.role
    CONFIG.side_override = identity.side
    CONFIG.deck_number = identity.deckNumber
    CONFIG.gun_number = identity.gunNumber
    CONFIG.chaser_number = identity.chaserNumber
    assignedSide = identity.side
end

local function configuredExpandedIdentity()
    local sideLetter = CONFIG.side_override == "port" and "P"
        or CONFIG.side_override == "starboard" and "S" or nil
    if not sideLetter then return nil end
    if CONFIG.battery_role == "bow_chaser" and CONFIG.chaser_number ~= nil then
        return parseBatteryIdentity(string.format(
            "BC-%s-%s", sideLetter, tostring(CONFIG.chaser_number)))
    end
    if CONFIG.deck_number ~= nil and CONFIG.gun_number ~= nil then
        return parseBatteryIdentity(string.format(
            "%s-%s-%s", sideLetter,
            tostring(CONFIG.deck_number), tostring(CONFIG.gun_number)))
    end
    return nil
end

local function readSavedBatteryIdentity()
    local path = CONFIG.battery_identity_file
    if type(path) ~= "string" or path == "" then
        return nil, "battery_identity_file must be a nonempty path"
    end
    local ok, result, readError = pcall(function()
        if not fs.exists(path) then return nil end
        local reader = fs.open(path, "r")
        if not reader then return nil, "cannot open saved identity" end
        local value = reader.readAll()
        reader.close()
        return value
    end)
    if not ok then return nil, "cannot read saved identity: " .. tostring(result) end
    if readError then return nil, readError end
    if result == nil then return nil end
    local identity, parseError = parseBatteryIdentity(result)
    if not identity then
        return nil, "saved identity is invalid: " .. tostring(parseError)
    end
    return identity
end

local function saveBatteryIdentity(identity)
    local ok, errorMessage = pcall(function()
        local writer = assert(fs.open(CONFIG.battery_identity_file, "w"))
        writer.write(identity.canonical .. "\n")
        writer.close()
    end)
    if not ok then
        return nil, "cannot save gun position: " .. tostring(errorMessage)
    end
    return true
end

local function promptForBatteryIdentity(previousError)
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        print("=== Phoenix Gun Position Setup ===")
        print("")
        print("Enter: SIDE DECK GUN")
        print("Example: S 3 4")
        print("  P = port, S = starboard")
        print("  Deck 1 is topmost")
        print("  Gun 1 is nearest the bow")
        print("")
        print("Bow chaser example: BC S 1")
        print("")
        if previousError then
            printError(tostring(previousError))
            previousError = nil
        end
        write("Gun position: ")
        local identity, parseError = parseBatteryIdentity(read())
        if identity then
            local saved, saveError = saveBatteryIdentity(identity)
            if not saved then return nil, saveError end
            return identity
        end
        previousError = parseError
    end
end

local function initializeBatteryIdentity()
    if CONFIG.battery_id ~= nil and CONFIG.battery_id ~= "" then
        local identity, parseError = parseBatteryIdentity(CONFIG.battery_id)
        if not identity then return nil, "battery_id: " .. tostring(parseError) end
        applyBatteryIdentity(identity)
        return true
    end

    local expandedIdentity, expandedError = configuredExpandedIdentity()
    if expandedError then return nil, "expanded battery identity: " .. tostring(expandedError) end
    if expandedIdentity then
        applyBatteryIdentity(expandedIdentity)
        return true
    end

    local savedIdentity, savedError = readSavedBatteryIdentity()
    if savedIdentity then
        applyBatteryIdentity(savedIdentity)
        return true
    end

    local promptedIdentity, promptError = promptForBatteryIdentity(savedError)
    if not promptedIdentity then return nil, promptError end
    applyBatteryIdentity(promptedIdentity)
    return true
end

local function ensureStartupLauncher()
    if not CONFIG.install_startup then return true end
    local startupDirectory = "/startup"
    local startupPath = startupDirectory .. "/phoenix_artillery_gun_with_reloading.lua"
    local programPath = "/artillery_gun_node_with_reloading.lua"
    local restartDelay = tonumber(CONFIG.restart_after_crash_s) or 3
    local content = table.concat({
        "-- Installed automatically by Phoenix artillery gun node with reloading.",
        "local program = " .. string.format("%q", programPath),
        "local restartDelay = " .. tostring(restartDelay),
        "if not fs.exists(program) then",
        "    printError('Missing ' .. program)",
        "    return",
        "end",
        "while true do",
        "    local completedNormally = shell.run(program)",
        "    if completedNormally then return end",
        "    printError('Gun node stopped unexpectedly; restarting in ' .. restartDelay .. 's')",
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
        lastError = "AUTH REJECT from computer " .. tostring(sender)
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

local function wrap360(angle)
    return ((angle % 360) + 360) % 360
end

local function roundNearest(value)
    if value >= 0 then return math.floor(value + 0.5) end
    return math.ceil(value - 0.5)
end

local function unwrapNear(value, reference)
    return value - roundNearest((value - reference) / 360) * 360
end

local function vec(x, y, z)
    return {x = x, y = y, z = z}
end

local function vectorFromTable(value)
    if type(value) ~= "table" then return nil end
    local x, y, z = value.x or value.X or value[1], value.y or value.Y or value[2], value.z or value.Z or value[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return nil end
    return vec(x, y, z)
end

local function quatHeadingDegrees(orientation)
    local w = orientation.a
    local x, y, z = orientation.v.x, orientation.v.y, orientation.v.z
    local tx, ty, tz = 0, 2 * z, -2 * y
    local fx = 1 + w * tx + (y * tz - z * ty)
    local fz = w * tz + (x * ty - y * tx)
    return wrap360(math.atan2(fx, -fz) * 180 / math.pi)
end

local function copyQuaternion(orientation)
    if type(orientation) ~= "table" or type(orientation.v) ~= "table" then return nil end
    local w, x, y, z = orientation.a, orientation.v.x, orientation.v.y, orientation.v.z
    if type(w) ~= "number" or type(x) ~= "number"
        or type(y) ~= "number" or type(z) ~= "number" then return nil end
    local length = math.sqrt(w * w + x * x + y * y + z * z)
    if length < 1e-9 then return nil end
    return {a = w / length, v = {x = x / length, y = y / length, z = z / length}}
end

local function getSablePose()
    if not sublevel or type(sublevel.getLogicalPose) ~= "function" then return nil end
    local ok, pose = pcall(sublevel.getLogicalPose)
    if not ok or not pose or not pose.position or not pose.orientation then return nil end
    local orientation = copyQuaternion(pose.orientation)
    if not orientation then return nil end
    return {
        position = vec(
            pose.position.x + CONFIG.sable_offset_x,
            pose.position.y + CONFIG.sable_offset_y,
            pose.position.z + CONFIG.sable_offset_z
        ),
        heading = quatHeadingDegrees(orientation),
        orientation = orientation,
        source = "sable",
    }
end

local function getMountPose(mount)
    if not mount then return nil end
    if type(mount.getInfo) ~= "function" then return nil end
    local ok, info = pcall(mount.getInfo)
    if not ok or type(info) ~= "table" then return nil end
    local position = vectorFromTable(info.position) or vectorFromTable(info.pos) or vectorFromTable(info)
    if not position then return nil end
    return {position = position, heading = nil, source = "mount"}
end

local function hasCannonMountMethods(candidate)
    if not candidate then return false end
    local ok, matches = pcall(function()
        return type(candidate.setTargetAngles) == "function"
            and type(candidate.fire) == "function"
    end)
    return ok and matches
end

local function findMount()
    local ok, mount = pcall(peripheral.find, "cannon_mount")
    if ok and hasCannonMountMethods(mount) then
        local nameOk, name = pcall(peripheral.getName, mount)
        return mount, nameOk and name or nil
    end

    -- Some addon versions expose a different peripheral type string. Fall
    -- back to the stable API methods visible on the mount itself.
    local namesOk, names = pcall(peripheral.getNames)
    if namesOk and type(names) == "table" then
        for _, name in ipairs(names) do
            local wrapOk, candidate = pcall(peripheral.wrap, name)
            if wrapOk and hasCannonMountMethods(candidate) then
                return candidate, name
            end
        end
    end
    return nil, nil
end

local function mountOfflineReason()
    local descriptions = {}
    local namesOk, names = pcall(peripheral.getNames)
    if namesOk and type(names) == "table" then
        for _, name in ipairs(names) do
            local typeOk, peripheralType = pcall(peripheral.getType, name)
            descriptions[#descriptions + 1] = name .. "=" .. tostring(typeOk and peripheralType or "unknown")
        end
    end
    if #descriptions == 0 then return "No cannon mount; no peripherals attached" end
    return "No cannon mount; attached: " .. table.concat(descriptions, ",")
end

local function saveLoadedProjectile()
    local ok, stateError = pcall(function()
        local writer = assert(fs.open(CONFIG.loader_state_file, "w"))
        writer.write(loadedProjectile or "")
        writer.close()
    end)
    if not ok then
        loaderError = "Cannot save loader state: " .. tostring(stateError)
        return false
    end
    return true
end

local function restoreLoadedProjectile()
    local ok, restored = pcall(function()
        if not fs.exists(CONFIG.loader_state_file) then return nil end
        local reader = assert(fs.open(CONFIG.loader_state_file, "r"))
        local value = reader.readAll()
        reader.close()
        value = tostring(value or ""):match("^%s*(.-)%s*$")
        return value ~= "" and value or nil
    end)
    if not ok then
        loaderError = "Cannot read loader state: " .. tostring(restored)
        return
    end
    if restored and PROJECTILE_ITEMS[restored] then
        loadedProjectile = restored
        loaderState = "LOADED"
    end
end

local function inventoryInfo(name)
    local wrapOk, candidate = pcall(peripheral.wrap, name)
    if not wrapOk or not candidate
        or type(candidate.list) ~= "function"
        or type(candidate.size) ~= "function" then return nil end
    local sizeOk, size = pcall(candidate.size)
    if not sizeOk or type(size) ~= "number" then return nil end
    return {
        name = name,
        peripheral = candidate,
        size = size,
        canPush = type(candidate.pushItems) == "function",
    }
end

local function discoverInventories()
    local result = {}
    local namesOk, names = pcall(peripheral.getNames)
    if not namesOk or type(names) ~= "table" then return result end
    for _, name in ipairs(names) do
        local info = inventoryInfo(name)
        if info then result[#result + 1] = info end
    end
    table.sort(result, function(a, b)
        if a.size ~= b.size then return a.size < b.size end
        return a.name < b.name
    end)
    return result
end

local function resolveLoaderInventories(force)
    if not CONFIG.loader_enabled then
        loaderOnline = false
        loaderError = "Loader disabled in CONFIG"
        return nil, loaderError
    end
    if not force and loaderOnline and loaderSourceName
        and #loaderDepotNames == 2 then
        local source = inventoryInfo(loaderSourceName)
        local depotOne = inventoryInfo(loaderDepotNames[1])
        local depotTwo = inventoryInfo(loaderDepotNames[2])
        if source and source.canPush and depotOne and depotTwo then
            return source.peripheral, {depotOne, depotTwo}
        end
    end

    loaderOnline, loaderSourceName, loaderDepotName = false, nil, nil
    loaderDepotNames = {}
    local inventories = discoverInventories()
    local sourceInfo
    if CONFIG.loader_source_inventory then
        sourceInfo = inventoryInfo(CONFIG.loader_source_inventory)
        if not sourceInfo or not sourceInfo.canPush then
            loaderError = "Invalid loader_source_inventory: "
                .. tostring(CONFIG.loader_source_inventory)
            return nil, loaderError
        end
    else
        for index = #inventories, 1, -1 do
            if inventories[index].canPush then sourceInfo = inventories[index] break end
        end
    end
    if not sourceInfo then
        loaderError = "No source inventory with pushItems"
        return nil, loaderError
    end

    local depotInfos, usedNames = {}, {[sourceInfo.name] = true}
    local function addDepotName(name, settingName)
        if type(name) ~= "string" or name == "" then
            return nil, "Invalid " .. settingName .. ": " .. tostring(name)
        end
        if usedNames[name] then
            return nil, settingName .. " duplicates source or another depot: " .. name
        end
        local info = inventoryInfo(name)
        if not info then return nil, "Invalid " .. settingName .. ": " .. name end
        usedNames[name] = true
        depotInfos[#depotInfos + 1] = info
        return true
    end

    if CONFIG.loader_depot_inventories ~= nil then
        if type(CONFIG.loader_depot_inventories) ~= "table"
            or #CONFIG.loader_depot_inventories ~= 2 then
            loaderError = "loader_depot_inventories must contain exactly two names"
            return nil, loaderError
        end
        for index, name in ipairs(CONFIG.loader_depot_inventories) do
            local added, addError = addDepotName(
                name, "loader_depot_inventories[" .. index .. "]"
            )
            if not added then loaderError = addError return nil, loaderError end
        end
    else
        if CONFIG.loader_depot_inventory then
            local added, addError = addDepotName(
                CONFIG.loader_depot_inventory, "loader_depot_inventory"
            )
            if not added then loaderError = addError return nil, loaderError end
        end
        for _, info in ipairs(inventories) do
            if #depotInfos >= 2 then break end
            if not usedNames[info.name] then
                usedNames[info.name] = true
                depotInfos[#depotInfos + 1] = info
            end
        end
    end
    if #depotInfos ~= 2 then
        loaderError = string.format(
            "Two separate loader depots required; found %d", #depotInfos)
        return nil, loaderError
    end

    loaderSourceName = sourceInfo.name
    loaderDepotNames = {depotInfos[1].name, depotInfos[2].name}
    loaderDepotName = table.concat(loaderDepotNames, " + ")
    loaderOnline, loaderError = true, nil
    return sourceInfo.peripheral, depotInfos
end

local function valueInList(value, list)
    if type(value) ~= "string" then return false end
    for _, candidate in ipairs(list or {}) do
        if value == candidate then return true end
    end
    return false
end

local function itemMatches(source, slot, summary, specification)
    if type(summary) ~= "table" or type(specification) ~= "table" then return false end
    if valueInList(summary.name, specification.ids) then return true end
    if type(source.getItemDetail) ~= "function" then return false end
    local detailOk, detail = pcall(source.getItemDetail, slot)
    if not detailOk or type(detail) ~= "table" then return false end
    local displayName = tostring(detail.displayName or ""):lower()
    for _, candidate in ipairs(specification.displayNames or {}) do
        if displayName == tostring(candidate):lower() then return true end
    end
    return false
end

local function attemptInventoryTransfer(source, depotInfo, matchingSlot)
    local pushOk, pushed = pcall(
        source.pushItems, depotInfo.name, matchingSlot, 1
    )
    if pushOk and pushed == 1 then return true end

    -- Some CC peripheral layouts expose a directly attached source as "left"
    -- while a depot has a wired-network name. Try the equivalent transfer from
    -- the destination side before declaring the inventories disconnected.
    local depot = depotInfo.peripheral
    local pullAvailable = type(depot.pullItems) == "function"
    local pullOk, pulled = false, "pullItems unavailable"
    if pullAvailable then
        pullOk, pulled = pcall(
            depot.pullItems, loaderSourceName, matchingSlot, 1
        )
        if pullOk and pulled == 1 then return true end
    end

    if pushOk and tonumber(pushed) == 0
        and pullAvailable and pullOk and tonumber(pulled) == 0 then
        return nil, "occupied or transfer refused", true
    end

    local pushResult = pushOk
        and ("moved " .. tostring(pushed))
        or tostring(pushed)
    local pullResult = not pullAvailable and "method unavailable"
        or pullOk and ("moved " .. tostring(pulled))
        or tostring(pulled)
    return nil, string.format(
        "push %s -> %s: %s; pull %s <- %s: %s",
        tostring(loaderSourceName), tostring(depotInfo.name), pushResult,
        tostring(depotInfo.name), tostring(loaderSourceName), pullResult
    ), false
end

local function moveOneToDepot(specification, description, excludedDepotName)
    local source, depotsOrError = resolveLoaderInventories(false)
    if not source then return nil, depotsOrError or loaderError end
    local depots = depotsOrError
    local listOk, contents = pcall(source.list)
    if not listOk or type(contents) ~= "table" then
        loaderOnline = false
        return nil, "Cannot list source inventory"
    end
    local matchingSlot
    for slot, summary in pairs(contents) do
        if itemMatches(source, slot, summary, specification) then
            matchingSlot = slot
            break
        end
    end
    if not matchingSlot then
        local available, seen = {}, {}
        for _, summary in pairs(contents) do
            local itemName = type(summary) == "table" and summary.name
            if itemName and not seen[itemName] then
                seen[itemName] = true
                available[#available + 1] = itemName
                if #available >= 4 then break end
            end
        end
        return nil, "No " .. description .. " in " .. loaderSourceName
            .. (#available > 0 and ("; found " .. table.concat(available, ", ")) or "; source empty")
    end

    local failures, candidateCount, allOccupied = {}, 0, true
    for _, depotInfo in ipairs(depots) do
        if depotInfo.name ~= excludedDepotName then
            candidateCount = candidateCount + 1
            local moved, transferError, occupied = attemptInventoryTransfer(
                source, depotInfo, matchingSlot
            )
            if moved then return true, depotInfo.name end
            failures[#failures + 1] = depotInfo.name .. ": " .. tostring(transferError)
            if not occupied then allOccupied = false end
        end
    end
    if candidateCount == 0 then
        return nil, "No second depot available for " .. description
    end
    if not allOccupied then loaderOnline = false end
    local prefix = allOccupied and "Loader depot occupied/refused"
        or "Inventory transfer failed"
    local topologyHint = allOccupied and "" or
        ". Connect source and BOTH depots by wired modems to the same cable network"
    return nil, prefix .. " for " .. description .. ": "
        .. table.concat(failures, " | ") .. topologyHint
end

local function openWirelessModem()
    local ok, modems = pcall(function()
        return {peripheral.find("modem", function(_, candidate)
            return type(candidate.isWireless) == "function"
                and candidate.isWireless()
        end)}
    end)
    if not ok or type(modems) ~= "table" or #modems == 0 then
        modemNames = {}
        return nil, "No wireless or ender modem"
    end

    local opened, lastOpenError = {}, nil
    for _, modem in ipairs(modems) do
        local nameOk, name = pcall(peripheral.getName, modem)
        if nameOk and name then
            local openOk, openError = pcall(function()
                if not rednet.isOpen(name) then rednet.open(name) end
            end)
            if openOk then
                opened[#opened + 1] = name
            else
                lastOpenError = tostring(openError)
            end
        end
    end
    modemNames = opened
    if #opened == 0 then
        return nil, lastOpenError or "Could not open attached modems"
    end
    return opened[1]
end

local function ensureModem()
    if modemName and #modemNames > 0 then
        local allOpen = true
        for _, name in ipairs(modemNames) do
            local ok, isOpen = pcall(rednet.isOpen, name)
            if not ok or not isOpen then allOpen = false break end
        end
        if allOpen then return true end
    end
    local errorMessage
    modemName, errorMessage = openWirelessModem()
    if not modemName then
        modemNames = {}
        lastError = "COMMS OFFLINE: " .. tostring(errorMessage)
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
        lastError = "COMMS ERROR: " .. tostring(sent)
        return false
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
        lastError = "COMMS ERROR: " .. tostring(sent)
        return false
    end
    return sent ~= false
end

local function enableMount(mount)
    if not mount then return false end
    local ok, errorMessage = pcall(function()
        if type(mount.setComputerControl) == "function" then mount.setComputerControl(true) end
        if type(mount.assemble) == "function" then mount.assemble(true) end
    end)
    if not ok then lastError = "Mount setup failed: " .. tostring(errorMessage) end
    return ok
end

local function currentPose(mount)
    return getSablePose() or getMountPose(mount)
end

local function updateVelocity(pose)
    local time = nowMs()
    if lastPose and lastPoseAt and time > lastPoseAt then
        local seconds = (time - lastPoseAt) / 1000
        local raw = vec(
            (pose.position.x - lastPose.position.x) / seconds,
            (pose.position.y - lastPose.position.y) / seconds,
            (pose.position.z - lastPose.position.z) / seconds
        )
        velocity.x = CONFIG.velocity_alpha * velocity.x + (1 - CONFIG.velocity_alpha) * raw.x
        velocity.y = CONFIG.velocity_alpha * velocity.y + (1 - CONFIG.velocity_alpha) * raw.y
        velocity.z = CONFIG.velocity_alpha * velocity.z + (1 - CONFIG.velocity_alpha) * raw.z
    end
    lastPose, lastPoseAt = pose, time
end

local function applyProfileValues(destination, source)
    if type(source) ~= "table" then return end
    for _, key in ipairs(MOUNT_PROFILE_KEYS) do
        if source[key] ~= nil then destination[key] = source[key] end
    end
end

local function resolvedMountConfig()
    local result = {}
    applyProfileValues(result, CONFIG)
    local side = assignedSide
    if side ~= "port" and side ~= "starboard" then side = CONFIG.side_override end
    if side == "port" or side == "starboard" then
        applyProfileValues(result, SIDE_MOUNT_PROFILES[side])
    end
    local label = os.getComputerLabel()
    if label then applyProfileValues(result, GUN_MOUNT_OVERRIDES[label]) end
    applyProfileValues(result, GUN_MOUNT_OVERRIDES[os.getComputerID()])
    return result, side or "default"
end

local function finishYawCommand(frameYaw, mountConfig)
    local yaw = frameYaw
    if mountConfig.invert_yaw then yaw = -yaw end
    local commandNearCenter = unwrapNear(
        yaw + mountConfig.yaw_offset_deg + runtimeYawTrim,
        mountConfig.yaw_center_deg
    )
    local fromCenter = commandNearCenter - mountConfig.yaw_center_deg
    if fromCenter < mountConfig.min_yaw_from_center_deg
        or fromCenter > mountConfig.max_yaw_from_center_deg then
        return nil, string.format(
            "Yaw outside traverse: %+.2f (allowed %+.1f..%+.1f)",
            fromCenter,
            mountConfig.min_yaw_from_center_deg,
            mountConfig.max_yaw_from_center_deg
        ), frameYaw, fromCenter
    end
    local command = commandNearCenter
    if mountConfig.wrap_yaw_command then
        command = wrap360(commandNearCenter)
        if math.abs(fromCenter) < 1e-9 and mountConfig.yaw_center_deg == 360 then
            command = 360
        end
    end
    return command, nil, frameYaw, fromCenter
end

local function commandYaw(worldYaw, heading, mountConfig, shipRelativeYaw)
    local frameYaw = worldYaw
    if mountConfig.yaw_command_mode == "ship_relative" then
        if type(shipRelativeYaw) == "number" then
            frameYaw = shipRelativeYaw + mountConfig.auto_yaw_offset
        else
            if type(heading) ~= "number" then return nil, "No Sable heading for ship-relative aim" end
            frameYaw = worldYaw - heading + mountConfig.auto_yaw_offset
        end
    end
    return finishYawCommand(frameYaw, mountConfig)
end

local function commandPitch(ballisticPitch, mountConfig)
    if ballisticPitch < mountConfig.min_elevation_deg
        or ballisticPitch > mountConfig.max_elevation_deg then
        return nil, string.format(
            "Elevation outside limits: %+.2f (allowed %+.1f..%+.1f)",
            ballisticPitch,
            mountConfig.min_elevation_deg,
            mountConfig.max_elevation_deg
        )
    end
    local pitch = mountConfig.invert_pitch and -ballisticPitch or ballisticPitch
    pitch = pitch + mountConfig.pitch_offset_deg + runtimePitchTrim
    if pitch < mountConfig.min_command_pitch or pitch > mountConfig.max_command_pitch then
        return nil, string.format(
            "Pitch command outside limits: %.2f (allowed %.1f..%.1f)",
            pitch,
            mountConfig.min_command_pitch,
            mountConfig.max_command_pitch
        )
    end
    return pitch
end

local function worldDirection(worldYaw, ballisticPitch)
    local yaw = worldYaw * math.pi / 180
    local pitch = ballisticPitch * math.pi / 180
    local horizontal = math.cos(pitch)
    return vec(
        math.sin(yaw) * horizontal,
        math.sin(pitch),
        -math.cos(yaw) * horizontal
    )
end

local function rotateWorldToLocal(direction, orientation)
    if not orientation or not orientation.v then return nil end
    -- Sable's quaternion maps contraption-local vectors into world space.
    -- Rotate by its normalized conjugate to recover the complete local vector.
    local w = orientation.a
    local ux, uy, uz = -orientation.v.x, -orientation.v.y, -orientation.v.z
    local tx = 2 * (uy * direction.z - uz * direction.y)
    local ty = 2 * (uz * direction.x - ux * direction.z)
    local tz = 2 * (ux * direction.y - uy * direction.x)
    return vec(
        direction.x + w * tx + (uy * tz - uz * ty),
        direction.y + w * ty + (uz * tx - ux * tz),
        direction.z + w * tz + (ux * ty - uy * tx)
    )
end

local function shipAimAngles(worldYaw, ballisticPitch, orientation)
    local localDirection = rotateWorldToLocal(worldDirection(worldYaw, ballisticPitch), orientation)
    if not localDirection then return nil end
    local horizontal = math.sqrt(localDirection.x * localDirection.x + localDirection.z * localDirection.z)
    if horizontal < 1e-9 then return nil end
    return math.atan2(localDirection.z, localDirection.x) * 180 / math.pi,
        math.atan2(localDirection.y, horizontal) * 180 / math.pi
end

local function aimMountWorld(mount, worldYaw, ballisticPitch)
    if type(worldYaw) ~= "number" or type(ballisticPitch) ~= "number" then return nil, "Invalid aim angles" end
    if not mount then return nil, "Cannon mount offline" end
    local pose = currentPose(mount)
    local mountConfig, profileName = resolvedMountConfig()
    local shipRelativeYaw, localElevation = nil, ballisticPitch
    local attitudeCompensated = false
    if mountConfig.yaw_command_mode == "ship_relative"
        and mountConfig.full_attitude_compensation
        and pose and pose.orientation then
        shipRelativeYaw, localElevation = shipAimAngles(worldYaw, ballisticPitch, pose.orientation)
        attitudeCompensated = type(shipRelativeYaw) == "number"
    end
    local yaw, yawError, frameYaw, yawFromCenter = commandYaw(
        worldYaw, pose and pose.heading, mountConfig, shipRelativeYaw
    )
    if not yaw then return nil, yawError end
    local pitch, pitchError = commandPitch(localElevation, mountConfig)
    if not pitch then return nil, pitchError end
    local ok, errorMessage = pcall(mount.setTargetAngles, yaw, pitch)
    if not ok then return nil, tostring(errorMessage) end
    lastRequestedAim = {mode = "world", worldYaw = worldYaw, ballisticPitch = ballisticPitch}
    lastAimState = {
        mode = "world",
        profileName = profileName,
        worldYaw = worldYaw,
        shipHeading = pose and pose.heading,
        shipRelativeYaw = shipRelativeYaw,
        attitudeCompensated = attitudeCompensated,
        frameYaw = frameYaw,
        yawFromCenter = yawFromCenter,
        commandYaw = yaw,
        ballisticPitch = ballisticPitch,
        localElevation = localElevation,
        commandPitch = pitch,
        mountConfig = mountConfig,
    }
    return {yaw = yaw, pitch = pitch}
end

local function aimMountManual(mount, manualYaw, elevation)
    if type(manualYaw) ~= "number" or type(elevation) ~= "number" then return nil, "Invalid manual aim angles" end
    if not mount then return nil, "Cannon mount offline" end
    local mountConfig, profileName = resolvedMountConfig()
    if manualYaw < mountConfig.min_yaw_from_center_deg
        or manualYaw > mountConfig.max_yaw_from_center_deg then
        return nil, string.format(
            "Manual yaw outside traverse: %+.2f (allowed %+.1f..%+.1f)",
            manualYaw, mountConfig.min_yaw_from_center_deg, mountConfig.max_yaw_from_center_deg
        )
    end
    local mappedYaw = mountConfig.invert_yaw and -manualYaw or manualYaw
    local commandNearCenter = mountConfig.yaw_center_deg + mappedYaw
        + mountConfig.yaw_offset_deg + runtimeYawTrim
    local finalFromCenter = commandNearCenter - mountConfig.yaw_center_deg
    if finalFromCenter < mountConfig.min_yaw_from_center_deg
        or finalFromCenter > mountConfig.max_yaw_from_center_deg then
        return nil, string.format(
            "Manual yaw with trim outside traverse: %+.2f (allowed %+.1f..%+.1f)",
            finalFromCenter, mountConfig.min_yaw_from_center_deg, mountConfig.max_yaw_from_center_deg
        )
    end
    local yaw = commandNearCenter
    if mountConfig.wrap_yaw_command then
        yaw = wrap360(commandNearCenter)
        if math.abs(finalFromCenter) < 1e-9 and mountConfig.yaw_center_deg == 360 then yaw = 360 end
    end
    local pitch, pitchError = commandPitch(elevation, mountConfig)
    if not pitch then return nil, pitchError end
    local ok, errorMessage = pcall(mount.setTargetAngles, yaw, pitch)
    if not ok then return nil, tostring(errorMessage) end
    lastRequestedAim = {mode = "manual", manualYaw = manualYaw, elevation = elevation}
    lastAimState = {
        mode = "manual",
        profileName = profileName,
        yawFromCenter = finalFromCenter,
        commandYaw = yaw,
        ballisticPitch = elevation,
        localElevation = elevation,
        commandPitch = pitch,
        mountConfig = mountConfig,
    }
    return {yaw = yaw, pitch = pitch}
end

local function repeatLastAim(mount)
    if not lastRequestedAim then return nil, "No aim command" end
    if lastRequestedAim.mode == "manual" then
        return aimMountManual(mount, lastRequestedAim.manualYaw, lastRequestedAim.elevation)
    end
    return aimMountWorld(mount, lastRequestedAim.worldYaw, lastRequestedAim.ballisticPitch)
end

local function aimFromMessage(mount, message)
    if CONFIG.battery_role == "bow_chaser" and message.aimMode ~= "manual" then
        return nil, "Bow chaser rejects automatic/world aim"
    end
    if message.aimMode == "manual" then
        return aimMountManual(mount, message.yawFromCenter, message.pitch)
    end
    return aimMountWorld(mount, message.worldYaw, message.pitch)
end

local function sendAck(orderId, ackType, accepted, errorMessage, details)
    if not centralId then return end
    local message = {
        type = "ack",
        version = CONFIG.protocol_version,
        orderId = orderId,
        ackType = ackType,
        accepted = accepted,
        error = errorMessage,
    }
    for key, value in pairs(details or {}) do message[key] = value end
    safeSend(centralId, message)
end

local function acknowledgeLoaderJob(job, accepted, errorMessage)
    local acknowledged = {}
    for _, orderId in ipairs({job.loadOrderId, job.fireOrderId}) do
        if orderId and not acknowledged[orderId] then
            acknowledged[orderId] = true
            sendAck(orderId, "loaded", accepted, errorMessage, {
                projectile = job.projectile,
                loaderState = loaderState,
            })
        end
    end
end

local function failLoaderJob(errorMessage)
    local job = loaderJob
    loaderJob = nil
    loaderState = "ERROR"
    loaderError = tostring(errorMessage)
    lastError = "LOADER: " .. loaderError
    lastCommand = "LOAD FAILED: " .. loaderError
    if job then acknowledgeLoaderJob(job, false, loaderError) end
end

local function queueLoaderOrder(message, mount)
    if not CONFIG.loader_enabled then
        sendAck(message.orderId, "load", false, "Loader disabled in CONFIG")
        return
    end
    local projectile = tostring(message.projectile or "")
    if not PROJECTILE_ITEMS[projectile] then
        sendAck(message.orderId, "load", false,
            "No item mapping for projectile " .. projectile)
        return
    end
    local fireRequested = message.type == "load_fire"
    if fireRequested then
        if completedOrders[message.orderId] then
            sendAck(message.orderId, "fired", true, nil, {projectile = projectile})
            return
        end
        local aimed, aimError = aimFromMessage(mount, message)
        if not aimed then
            sendAck(message.orderId, "load", false, aimError)
            return
        end
    end
    if pendingFire and pendingFire.orderId ~= message.orderId then
        sendAck(message.orderId, "load", false,
            "Another fire order is already armed")
        return
    elseif pendingFire and pendingFire.orderId == message.orderId then
        sendAck(message.orderId, "load", true, nil, {projectile = projectile})
        sendAck(message.orderId, "loaded", true, nil, {projectile = projectile})
        return
    end

    if loadedProjectile then
        if loadedProjectile ~= projectile then
            sendAck(message.orderId, "load", false,
                "Already loaded with " .. loadedProjectile)
            return
        end
        loaderState, loaderError = fireRequested and "ARMED" or "LOADED", nil
        completedLoads[message.orderId] = nowMs()
        sendAck(message.orderId, "load", true, nil, {projectile = projectile})
        sendAck(message.orderId, "loaded", true, nil, {projectile = projectile})
        if fireRequested then
            pendingFire = {
                orderId = message.orderId,
                fireAt = nowMs() + math.max(0, tonumber(message.fireDelayMs) or 0),
            }
            lastCommand = string.format("Loaded; fire in %.2fs",
                math.max(0, (pendingFire.fireAt - nowMs()) / 1000))
        else
            lastCommand = "Already loaded: " .. projectile
        end
        return
    end

    if loaderJob then
        if loaderJob.projectile ~= projectile then
            sendAck(message.orderId, "load", false,
                "Loader busy with " .. loaderJob.projectile)
            return
        end
        if fireRequested then
            loaderJob.fireOrderId = message.orderId
            loaderJob.fireDelayMs = math.max(0, tonumber(message.fireDelayMs) or 0)
            lastCommand = "Load promoted to LOAD+FIRE"
        end
        sendAck(message.orderId, "load", true, nil, {
            projectile = projectile,
            loaderState = loaderState,
        })
        return
    end

    loaderJob = {
        loadOrderId = message.orderId,
        fireOrderId = fireRequested and message.orderId or nil,
        fireDelayMs = math.max(0, tonumber(message.fireDelayMs) or 0),
        projectile = projectile,
        stage = "MOVE_SHELL",
        nextAt = nowMs(),
    }
    loaderState, loaderError = "QUEUED", nil
    lastCommand = "Queued load: " .. projectile
    sendAck(message.orderId, "load", true, nil, {
        projectile = projectile,
        loaderState = loaderState,
    })
end

local function serviceLoader()
    local job = loaderJob
    if not job or nowMs() < job.nextAt then return end
    if job.stage == "MOVE_SHELL" then
        loaderState = "MOVING SHELL"
        local moved, depotOrError = moveOneToDepot(
            PROJECTILE_ITEMS[job.projectile], job.projectile
        )
        if not moved then failLoaderJob(depotOrError) return end
        job.shellDepotName = depotOrError
        job.stage = "WAIT_AFTER_SHELL"
        job.nextAt = nowMs() + CONFIG.loader_shell_delay_s * 1000
        loaderState = "SHELL SENT"
        lastCommand = string.format("Shell -> %s; cartridge in %.1fs",
            job.shellDepotName, CONFIG.loader_shell_delay_s)
    elseif job.stage == "WAIT_AFTER_SHELL" then
        loaderState = "MOVING CARTRIDGE"
        local moved, depotOrError = moveOneToDepot(
            CARTRIDGE_ITEM, "fully loaded big cartridge",
            job.shellDepotName
        )
        if not moved then failLoaderJob(depotOrError) return end
        job.cartridgeDepotName = depotOrError
        job.stage = "WAIT_AFTER_CARTRIDGE"
        job.nextAt = nowMs() + CONFIG.loader_cartridge_delay_s * 1000
        loaderState = "CARTRIDGE SENT"
        lastCommand = string.format("Cartridge -> %s; ready in %.1fs",
            job.cartridgeDepotName, CONFIG.loader_cartridge_delay_s)
    elseif job.stage == "WAIT_AFTER_CARTRIDGE" then
        loadedProjectile = job.projectile
        loaderState, loaderError = "LOADED", nil
        completedLoads[job.loadOrderId] = nowMs()
        if job.fireOrderId then completedLoads[job.fireOrderId] = nowMs() end
        saveLoadedProjectile()
        acknowledgeLoaderJob(job, true)
        loaderJob = nil
        if job.fireOrderId then
            pendingFire = {
                orderId = job.fireOrderId,
                fireAt = nowMs() + job.fireDelayMs,
            }
            loaderState = "ARMED"
            lastCommand = string.format("Loaded; fire in %.2fs",
                math.max(0, (pendingFire.fireAt - nowMs()) / 1000))
        else
            lastCommand = "LOADED " .. loadedProjectile .. "; waiting for FIRE"
        end
    end
end

local function cancelNodeOrder(orderId, emergency)
    if pendingFire and (emergency or not orderId or pendingFire.orderId == orderId) then
        pendingFire = nil
    end
    if loaderJob and (emergency or not orderId
        or loaderJob.loadOrderId == orderId or loaderJob.fireOrderId == orderId) then
        loaderJob = nil
        if loadedProjectile then loaderState = "LOADED" else loaderState = "ABORTED" end
    end
    if emergency then
        emergencyStopRequested = true
        lastCommand = "EMERGENCY ABORT RECEIVED"
        lastError = nil
    else
        lastCommand = "Order cancelled"
    end
end

local function sendHello(mount, mountName)
    if centralId and nowMs() - centralLastSeen >= CONFIG.central_timeout_s * 1000 then
        centralId = nil
        lastCommand = "Central timed out; searching"
    end
    local hardwareError = nil
    if not mount then
        hardwareError = mountOfflineReason()
        lastError = hardwareError
    elseif type(lastError) == "string" and lastError:find("^No cannon mount") then
        lastError = nil
    end
    resolveLoaderInventories(false)
    local pose = currentPose(mount)
    if not pose then
        lastError = "No Sable pose or cannon position"
        local sent = safeBroadcast({
            type = "status",
            version = CONFIG.protocol_version,
            ready = false,
            mountOnline = mount ~= nil,
            error = hardwareError or lastError,
            loaderOnline = loaderOnline,
            loaderState = loaderState,
            loadedProjectile = loadedProjectile,
            loaderSourceName = loaderSourceName,
            loaderDepotName = loaderDepotName,
            loaderDepotNames = {loaderDepotNames[1], loaderDepotNames[2]},
            loaderError = loaderError,
        })
        if sent then lastHelloAt = nowMs() end
        return
    end
    updateVelocity(pose)
    local label = os.getComputerLabel() or ("Gun " .. os.getComputerID())
    local sent = safeBroadcast({
        type = "hello",
        version = CONFIG.protocol_version,
        nodeId = os.getComputerID(),
        label = label,
        position = pose.position,
        velocity = velocity,
        heading = pose.heading,
        positionSource = pose.source,
        sideHint = CONFIG.side_override,
        batteryRole = CONFIG.battery_role,
        deckNumber = CONFIG.deck_number,
        gunNumber = CONFIG.gun_number,
        chaserNumber = CONFIG.chaser_number,
        stationOverride = CONFIG.station_override,
        enabled = CONFIG.gun_enabled,
        mountName = mountName,
        mountOnline = mount ~= nil,
        ready = mount ~= nil,
        error = hardwareError,
        loaderOnline = loaderOnline,
        loaderState = loaderState,
        loadedProjectile = loadedProjectile,
        loaderSourceName = loaderSourceName,
        loaderDepotName = loaderDepotName,
        loaderDepotNames = {loaderDepotNames[1], loaderDepotNames[2]},
        loaderError = loaderError,
    })
    if sent then lastHelloAt = nowMs() end
end

local function cancelPendingForInvalidAim(errorMessage)
    local cancelledOrder = pendingFire and pendingFire.orderId
        or loaderJob and loaderJob.fireOrderId
    if pendingFire then pendingFire = nil end
    if loaderJob and loaderJob.fireOrderId then loaderJob.fireOrderId = nil end
    if not cancelledOrder then return end
    lastCommand = "CANCELLED " .. cancelledOrder .. ": aim outside limits"
    lastError = errorMessage
end

local function handleMessage(sender, message, mount, mountName)
    if type(message) ~= "table" or message.version ~= CONFIG.protocol_version then return end
    if not authenticateIncoming(sender, message) then return end
    receivedPacketCount = receivedPacketCount + 1
    lastReceivedType = tostring(message.type or "?")
    lastReceivedSender = sender
    if message.type == "discover" then
        local now = nowMs()
        if centralId == sender
            and now - centralLastSeen < CONFIG.central_timeout_s * 1000 then
            centralLastSeen = now
            -- A registered node already sends periodic pose/status heartbeats.
            -- Do not turn every background discovery into another registration
            -- burst; only reply if a heartbeat is genuinely overdue.
            if now - lastHelloAt >= CONFIG.discovery_reply_min_s * 1000 then
                sendHello(mount, mountName)
            end
            return
        end
        if centralId and sender ~= centralId
            and now - centralLastSeen < CONFIG.central_timeout_s * 1000 then
            return
        end
        centralId, centralLastSeen = sender, now
        lastCommand = "Central discovered; registering"
        sendHello(mount, mountName)
        return
    end
    if message.type == "welcome" then
        if centralId and sender ~= centralId and nowMs() - centralLastSeen < CONFIG.central_timeout_s * 1000 then return end
        centralId, centralLastSeen = sender, nowMs()
        assignedSide = message.side or assignedSide
        lastCommand = "Registered with central " .. sender
        -- WELCOME is registration/keepalive metadata, not an aim command.
        -- Re-aiming here made every heartbeat perform an extra yielding Sable
        -- and mount call, which could bury real LOAD packets behind tracking.
        return
    end
    if centralId and sender ~= centralId and nowMs() - centralLastSeen < CONFIG.central_timeout_s * 1000 then return end
    centralId, centralLastSeen = sender, nowMs()
    if message.type == "load" or message.type == "load_fire"
        or message.type == "cancel" or message.type == "emergency_abort" then
        receivedOrderCount = receivedOrderCount + 1
        lastReceivedOrderType = message.type
    end

    if message.type == "emergency_abort" then
        cancelNodeOrder(nil, true)
        sendAck(message.orderId, "aborted", true)
    elseif message.type == "load" or message.type == "load_fire" then
        if not CONFIG.gun_enabled then
            sendAck(message.orderId, "load", false, "Gun disabled in node CONFIG")
            return
        end
        if message.validUntil and nowMs() > message.validUntil then
            sendAck(message.orderId, "load", false, "Load order expired")
            return
        end
        queueLoaderOrder(message, mount)
    elseif message.type == "aim" then
        if not CONFIG.gun_enabled then
            sendAck(message.orderId, "aim", false, "Gun disabled in node CONFIG")
            return
        end
        if message.validUntil and nowMs() > message.validUntil then return end
        local result, aimError = aimFromMessage(mount, message)
        lastError = aimError
        if result then
            lastCommand = string.format("Aimed %.2f / %.2f", result.yaw, result.pitch)
            sendAck(message.orderId, "aim", true)
        else
            cancelPendingForInvalidAim(aimError)
            sendAck(message.orderId, "aim", false, aimError)
        end
    elseif message.type == "fire" then
        sendAck(message.orderId, "fire", false,
            "Legacy fire packet disabled; use load_fire")
    elseif message.type == "cancel" then
        cancelNodeOrder(message.orderId, false)
    end
end

local function safeStopFiring(targetMount)
    if not targetMount then return nil, "No cannon mount available for fire-off" end
    local fireMethod = targetMount.fire
    if type(fireMethod) ~= "function" then
        return nil, "Cannon mount has no fire method"
    end
    local ok, errorMessage = pcall(fireMethod, false)
    if not ok then return nil, tostring(errorMessage) end
    return true
end

local function forceFireOff(currentMount, context)
    local signalMount = fireSignalMount or currentMount
    local stopped, stopError = safeStopFiring(signalMount)
    local currentStopped, currentError = true, nil
    if currentMount and currentMount ~= signalMount then
        currentStopped, currentError = safeStopFiring(currentMount)
    end
    if stopped and currentStopped then
        firing, fireOffAt, fireSignalMount = false, nil, nil
        return true
    end
    firing = true
    fireOffAt = nowMs() + CONFIG.control_tick_s * 1000
    lastError = string.format("FIRE-OFF %s FAILED: %s%s",
        tostring(context or ""),
        tostring(stopError or "primary mount unknown"),
        currentError and ("; current mount: " .. tostring(currentError)) or "")
    return nil, lastError
end

local function serviceFire(mount)
    if not pendingFire or firing or nowMs() < pendingFire.fireAt then return end
    local orderId = pendingFire.orderId
    pendingFire = nil
    if not mount then
        lastError = "Cannon mount went offline before firing"
        lastCommand = "MISSED order " .. orderId
        sendAck(orderId, "fired", false, lastError)
        return
    end
    local aimed, aimError = repeatLastAim(mount)
    if not aimed then
        lastError = "MISSED: " .. tostring(aimError)
        lastCommand = "MISSED order " .. orderId
        sendAck(orderId, "fired", false, lastError)
        return
    end
    local fireOnOk, fireOnError = pcall(mount.fire, true)
    if not fireOnOk then
        lastError = tostring(fireOnError)
        sendAck(orderId, "fired", false, lastError)
        return
    end
    firing = true
    fireSignalMount = mount
    fireOffAt = nowMs() + CONFIG.fire_hold_s * 1000
    loadedProjectile = nil
    loaderState = "EMPTY"
    saveLoadedProjectile()
    completedOrders[orderId] = nowMs()

    -- Use the proven artillery.lua pulse semantics directly. This control
    -- coroutine may pause for 0.2 seconds, while the dedicated network and
    -- command coroutines remain responsive. fire(false) is attempted even if
    -- the hold timer itself errors or is interrupted.
    local holdOk, holdError = pcall(sleep, CONFIG.fire_hold_s)
    local stopped = forceFireOff(mount, "after pulse")
    lastCommand = stopped
        and ("FIRED pulse complete " .. orderId)
        or ("FIRED but fire-off retrying " .. orderId)
    if not holdOk then
        lastError = "FIRE HOLD INTERRUPTED: " .. tostring(holdError)
    end
    -- The round has already fired, so acknowledge success even if deassertion
    -- needs watchdog retries. Retrying the order could discharge another round.
    sendAck(orderId, "fired", true)
end

local function processNetworkMessage(sender, message, mount, mountName)
    handleMessage(sender, message, mount, mountName)
    if emergencyStopRequested then
        forceFireOff(mount, "emergency abort")
        emergencyStopRequested = false
    end
end

local function packetPriority(message)
    local messageType = type(message) == "table" and message.type or nil
    if messageType == "emergency_abort" then return 1 end
    if messageType == "cancel" then return 2 end
    if messageType == "load" or messageType == "load_fire"
        or messageType == "fire" then return 3 end
    return 4
end

local function sameQueuedCommand(left, right)
    if not left or not right then return false end
    local leftMessage, rightMessage = left.message, right.message
    if type(leftMessage) ~= "table" or type(rightMessage) ~= "table" then return false end
    return left.sender == right.sender
        and leftMessage.type == rightMessage.type
        and leftMessage.orderId ~= nil
        and leftMessage.orderId == rightMessage.orderId
end

local function insertNetworkCommand(packet)
    -- Retries for the same command replace their queued copy. This prevents a
    -- temporarily slow inventory/mount peripheral from building an old packet
    -- backlog which would delay a later LOAD or emergency abort.
    for index, queued in ipairs(networkInbox) do
        if sameQueuedCommand(queued, packet) then
            networkInbox[index] = packet
            return
        end
    end
    local priority = packetPriority(packet.message)
    local insertAt = #networkInbox + 1
    for index, queued in ipairs(networkInbox) do
        if priority < packetPriority(queued.message) then
            insertAt = index
            break
        end
    end
    if #networkInbox >= NETWORK_QUEUE_LIMIT then
        if priority <= 2 then
            table.remove(networkInbox, #networkInbox)
        else
            networkQueueDrops = networkQueueDrops + 1
            return
        end
    end
    table.insert(networkInbox, insertAt, packet)
end

local function receiveNetworkMessage(sender, message, protocol)
    observedRednetCount = observedRednetCount + 1
    lastObservedSender = sender
    lastObservedProtocolMatches = protocol == CONFIG.protocol
    lastObservedVersion = type(message) == "table" and message.version or nil
    if protocol ~= CONFIG.protocol then return end

    local packet = {sender = sender, message = message}
    local messageType = type(message) == "table" and message.type or nil
    if messageType == "aim" then
        -- Only the newest tracking update matters. Central refreshes automatic
        -- aim periodically, so executing every stale aim can otherwise starve
        -- a load command when Sable or the cannon mount is slow.
        pendingAimPacket = packet
    elseif messageType == "discover" then
        pendingDiscoverPacket = packet
    elseif messageType == "welcome" then
        pendingWelcomePacket = packet
    else
        insertNetworkCommand(packet)
    end
    os.queueEvent(NETWORK_INBOX_EVENT)
end

local function nextNetworkPacket()
    if #networkInbox > 0 then return table.remove(networkInbox, 1) end
    if pendingWelcomePacket then
        local packet = pendingWelcomePacket
        pendingWelcomePacket = nil
        return packet
    end
    if pendingDiscoverPacket then
        local packet = pendingDiscoverPacket
        pendingDiscoverPacket = nil
        return packet
    end
    if pendingAimPacket then
        local packet = pendingAimPacket
        pendingAimPacket = nil
        return packet
    end
    return nil
end

local function pruneCompletedOrders()
    local cutoff = nowMs() - 60000
    for orderId, completedAt in pairs(completedOrders) do
        if completedAt < cutoff then completedOrders[orderId] = nil end
    end
    for orderId, completedAt in pairs(completedLoads) do
        if completedAt < cutoff then completedLoads[orderId] = nil end
    end
end

local function applyNudge(mount, key)
    local changed = true
    if key == keys.left then runtimeYawTrim = runtimeYawTrim - CONFIG.nudge_step_deg
    elseif key == keys.right then runtimeYawTrim = runtimeYawTrim + CONFIG.nudge_step_deg
    elseif key == keys.up then runtimePitchTrim = runtimePitchTrim + CONFIG.nudge_step_deg
    elseif key == keys.down then runtimePitchTrim = runtimePitchTrim - CONFIG.nudge_step_deg
    elseif key == keys.j then runtimeYawTrim = runtimeYawTrim - CONFIG.coarse_nudge_step_deg
    elseif key == keys.l then runtimeYawTrim = runtimeYawTrim + CONFIG.coarse_nudge_step_deg
    elseif key == keys.i then runtimePitchTrim = runtimePitchTrim + CONFIG.coarse_nudge_step_deg
    elseif key == keys.k then runtimePitchTrim = runtimePitchTrim - CONFIG.coarse_nudge_step_deg
    else changed = false end
    if changed and lastRequestedAim then
        local result, aimError = repeatLastAim(mount)
        lastError = aimError
        if result then
            lastCommand = string.format("Trim yaw/pitch %+.1f / %+.1f", runtimeYawTrim, runtimePitchTrim)
        else
            cancelPendingForInvalidAim(aimError)
        end
    end
    return changed
end

local function ensureMonitor(force)
    if monitor and not force then return monitor end
    monitor, monitorName = nil, nil
    local ok, found = pcall(peripheral.find, "monitor")
    if not ok or not found then return nil end
    local nameOk, foundName = pcall(peripheral.getName, found)
    local setupOk = pcall(function()
        found.setTextScale(CONFIG.monitor_text_scale)
        found.setBackgroundColor(colors.black)
        found.setTextColor(colors.white)
    end)
    if not setupOk then return nil end
    monitor, monitorName = found, nameOk and foundName or "monitor"
    return monitor
end

local function appendWrapped(lines, prefix, value, color, width)
    local text = tostring(prefix or "") .. tostring(value or "")
    width = math.max(8, width)
    repeat
        local part = text:sub(1, width)
        if #text > width then
            local splitAt = part:match("^.*()%s+")
            if splitAt and splitAt > math.floor(width * 0.45) then
                part = text:sub(1, splitAt - 1)
                text = text:sub(splitAt + 1)
            else
                text = text:sub(width + 1)
            end
        else
            text = ""
        end
        lines[#lines + 1] = {text = part, color = color or colors.white}
    until text == ""
end

local function drawAttachedMonitor(mount, mountName)
    local display = ensureMonitor(false)
    if not display then return end
    local ok, errorMessage = pcall(function()
        local width, height = display.getSize()
        local lines = {}
        local mountConfig, profileName = resolvedMountConfig()
        local pose = lastPose
        local observedFrom = lastObservedSender and tostring(lastObservedSender) or "-"
        local protocolState = lastObservedProtocolMatches == nil and "-"
            or lastObservedProtocolMatches and "Y" or "N"
        local battery = CONFIG.battery_role == "bow_chaser"
            and string.format("BC-%s-%s",
                CONFIG.side_override == "port" and "P"
                    or CONFIG.side_override == "starboard" and "S" or "?",
                tostring(CONFIG.chaser_number or "?"))
            or string.format("%s-D%s-G%s",
                CONFIG.side_override == "port" and "P"
                    or CONFIG.side_override == "starboard" and "S" or "?",
                tostring(CONFIG.deck_number or "?"),
                tostring(CONFIG.gun_number or "?"))

        appendWrapped(lines, "", "PHOENIX ARTILLERY GUN NODE", colors.cyan, width)
        appendWrapped(lines, "", string.format(
            "Computer %d  Battery %s  Side %s  Mount %s",
            os.getComputerID(), battery, tostring(assignedSide),
            tostring(mount and (mountName or "online") or "OFFLINE")),
            colors.white, width)
        appendWrapped(lines, "", string.format(
            "Central %s | Modems %d | NET %d/%s P:%s V:%s | RX %d/%s | ORD %d/%s | Queue %d Drop %d",
            tostring(centralId or "searching"), #modemNames,
            observedRednetCount, observedFrom, protocolState,
            tostring(lastObservedVersion or "-"), receivedPacketCount,
            tostring(lastReceivedType or "-"),
            receivedOrderCount, tostring(lastReceivedOrderType or "-"),
            #networkInbox + (pendingAimPacket and 1 or 0)
                + (pendingDiscoverPacket and 1 or 0)
                + (pendingWelcomePacket and 1 or 0),
            networkQueueDrops), colors.lightGray, width)
        appendWrapped(lines, "", string.format(
            "Loader %s | Loaded %s | Source %s | Depots %s",
            loaderOnline and loaderState or "OFFLINE",
            tostring(loadedProjectile or "EMPTY"),
            tostring(loaderSourceName or "?"), tostring(loaderDepotName or "?")),
            loaderError and colors.orange or colors.lime, width)
        if loaderJob then
            appendWrapped(lines, "", string.format(
                "Load job %s | Stage %s | Shell depot %s | Cartridge depot %s | Order %s",
                tostring(loaderJob.projectile), tostring(loaderJob.stage),
                tostring(loaderJob.shellDepotName or "-"),
                tostring(loaderJob.cartridgeDepotName or "-"),
                tostring(loaderJob.loadOrderId)), colors.yellow, width)
        end

        -- Errors are deliberately near the top and are never shortened. This
        -- is the commissioning/debug display the small computer terminal lacks.
        if loaderError then
            appendWrapped(lines, "LOADER ERROR: ", loaderError, colors.orange, width)
        end
        if networkHandlerError then
            appendWrapped(lines, "NETWORK ERROR: ", networkHandlerError, colors.red, width)
        end
        if lastError then
            appendWrapped(lines, "ERROR: ", lastError, colors.red, width)
        end
        appendWrapped(lines, "LAST: ", lastCommand, colors.yellow, width)

        if pose then
            appendWrapped(lines, "", string.format(
                "Position %.2f %.2f %.2f | Heading %s | Sable/source %s",
                pose.position.x, pose.position.y, pose.position.z,
                pose.heading and string.format("%.2f", pose.heading) or "N/A",
                tostring(pose.source)), colors.white, width)
        else
            appendWrapped(lines, "", "Position unavailable", colors.orange, width)
        end
        appendWrapped(lines, "", string.format(
            "Profile %s | Yaw %s center %.1f limits %+.1f..%+.1f",
            tostring(profileName), tostring(mountConfig.yaw_command_mode),
            mountConfig.yaw_center_deg, mountConfig.min_yaw_from_center_deg,
            mountConfig.max_yaw_from_center_deg), colors.white, width)
        appendWrapped(lines, "", string.format(
            "Yaw map auto %+.1f invert %s offset %+.1f | trim %+.1f",
            mountConfig.auto_yaw_offset, tostring(mountConfig.invert_yaw),
            mountConfig.yaw_offset_deg, runtimeYawTrim), colors.white, width)
        appendWrapped(lines, "", string.format(
            "Elevation %+.1f..%+.1f | pitch invert %s offset %+.1f | trim %+.1f",
            mountConfig.min_elevation_deg, mountConfig.max_elevation_deg,
            tostring(mountConfig.invert_pitch), mountConfig.pitch_offset_deg,
            runtimePitchTrim), colors.white, width)
        if lastAimState and lastAimState.mode == "manual" then
            appendWrapped(lines, "", string.format(
                "Manual yaw/elev %+.2f/%+.2f | command %.2f/%.2f",
                lastRequestedAim.manualYaw, lastRequestedAim.elevation,
                lastAimState.commandYaw, lastAimState.commandPitch),
                colors.lightBlue, width)
        elseif lastAimState then
            appendWrapped(lines, "", string.format(
                "Aim world %.2f | frame %.2f | local yaw %+.2f | mount %.2f/%.2f | 3D %s",
                lastAimState.worldYaw, lastAimState.frameYaw,
                lastAimState.yawFromCenter, lastAimState.commandYaw,
                lastAimState.commandPitch,
                lastAimState.attitudeCompensated and "ON" or "OFF"),
                colors.lightBlue, width)
        end
        if pendingFire then
            appendWrapped(lines, "", string.format("Pending fire in %.2fs",
                math.max(0, (pendingFire.fireAt - nowMs()) / 1000)),
                colors.red, width)
        end

        display.setBackgroundColor(colors.black)
        display.clear()
        for row = 1, math.min(height, #lines) do
            display.setCursorPos(1, row)
            display.setTextColor(lines[row].color)
            display.write(lines[row].text)
        end
    end)
    if not ok then
        monitor, monitorName = nil, nil
        networkHandlerError = "Monitor draw failed: " .. tostring(errorMessage)
    end
end

local function draw(mount, mountName)
    local width, height = term.getSize()
    -- sendHello refreshes lastPose every heartbeat. Reusing it here avoids
    -- making a yielding Sable peripheral call on every display frame.
    local pose = lastPose or currentPose(mount)
    term.clear(); term.setCursorPos(1, 1)
    print("=== Phoenix Artillery Gun Node ===")
    print(string.format("Computer:%d  Label:%s", os.getComputerID(), os.getComputerLabel() or "none"))
    print("Mount: " .. tostring(mount and (mountName or "online") or "OFFLINE"))
    local observedFrom = lastObservedSender and tostring(lastObservedSender) or "-"
    local protocolState = lastObservedProtocolMatches == nil and "-"
        or lastObservedProtocolMatches and "Y" or "N"
    print(string.format("C:%s M:%s(%d) A:%s NET:%d/%s P:%s V:%s RX:%d/%s ORD:%d/%s",
        tostring(centralId or "searching"), modemName and "ON" or "OFF",
        #modemNames, CONFIG.security_enabled and "ON" or "OFF",
        observedRednetCount, observedFrom, protocolState,
        tostring(lastObservedVersion or "-"), receivedPacketCount,
        tostring(lastReceivedType or "-"), receivedOrderCount,
        tostring(lastReceivedOrderType or "-")))
    local mountConfig, profileName = resolvedMountConfig()
    print(string.format("Broadside:%s Profile:%s Enabled:%s",
        tostring(assignedSide), tostring(profileName), CONFIG.gun_enabled and "YES" or "NO"))
    if CONFIG.battery_role == "bow_chaser" then
        print(string.format("Battery ID:BC-%s-%s  MANUAL ONLY",
            CONFIG.side_override == "port" and "P" or CONFIG.side_override == "starboard" and "S" or "?",
            tostring(CONFIG.chaser_number or "?")))
    else
        print(string.format("Battery ID:%s-D%s-G%s Station:%s",
            CONFIG.side_override == "port" and "P" or CONFIG.side_override == "starboard" and "S" or "?",
            tostring(CONFIG.deck_number or "?"), tostring(CONFIG.gun_number or "?"),
            tostring(CONFIG.station_override or "auto")))
    end
    if pose then
        print(string.format("Position: %.1f %.1f %.1f", pose.position.x, pose.position.y, pose.position.z))
        print(string.format("Heading: %s  Source:%s", pose.heading and string.format("%.1f", pose.heading) or "N/A", pose.source))
    else
        print("Position: unavailable")
    end
    print(string.format("Yaw:%s ctr:%.0f lim:%+.0f..%+.0f",
        mountConfig.yaw_command_mode, mountConfig.yaw_center_deg,
        mountConfig.min_yaw_from_center_deg, mountConfig.max_yaw_from_center_deg))
    print(string.format("Yaw map a:%+.1f inv:%s o:%+.1f",
        mountConfig.auto_yaw_offset,
        tostring(mountConfig.invert_yaw), mountConfig.yaw_offset_deg))
    print(string.format("Elev limits:%+.0f..%+.0f  Pitch inv:%s o:%+.1f",
        mountConfig.min_elevation_deg, mountConfig.max_elevation_deg,
        tostring(mountConfig.invert_pitch), mountConfig.pitch_offset_deg))
    print(string.format("Runtime trim yaw/pitch: %+.1f / %+.1f", runtimeYawTrim, runtimePitchTrim))
    print(string.format("Loader:%s  Source:%s  Depots:%s",
        loaderOnline and loaderState or "OFFLINE",
        tostring(loaderSourceName or "?"), tostring(loaderDepotName or "?")))
    print("Loaded shell: " .. tostring(loadedProjectile or "EMPTY"))
    if loaderJob then
        print(string.format("Load job:%s %s S:%s C:%s",
            loaderJob.projectile, loaderJob.stage,
            tostring(loaderJob.shellDepotName or "-"),
            tostring(loaderJob.cartridgeDepotName or "-")))
    end
    if lastAimState and lastAimState.mode == "manual" then
        print(string.format("Manual yaw/elev %+.2f / %+.2f",
            lastRequestedAim.manualYaw, lastRequestedAim.elevation))
        print(string.format("Command yaw/pitch %.2f / %.2f",
            lastAimState.commandYaw, lastAimState.commandPitch))
    elseif lastAimState then
        print(string.format("World yaw %.2f - heading %s",
            lastAimState.worldYaw,
            lastAimState.shipHeading and string.format("%.2f", lastAimState.shipHeading) or "N/A"))
        print(string.format("Frame %.2f -> yaw %.2f (%+.2f)  3D:%s",
            lastAimState.frameYaw, lastAimState.commandYaw, lastAimState.yawFromCenter,
            lastAimState.attitudeCompensated and "ON" or "OFF"))
        print(string.format("World/local elev %.2f / %.2f -> mount %.2f",
            lastAimState.ballisticPitch, lastAimState.localElevation, lastAimState.commandPitch))
    end
    if pendingFire then print(string.format("Pending fire: %.2fs", math.max(0, (pendingFire.fireAt - nowMs()) / 1000))) end
    print("State: " .. (firing and "FIRING" or "ready"))
    local lastText = "Last: " .. tostring(lastCommand)
    print(#lastText <= width and lastText or lastText:sub(1, width - 1) .. "~")
    if lastError then
        local errorText = "Error: " .. tostring(lastError)
        print(#errorText <= width and errorText or errorText:sub(1, width - 1) .. "~")
    end
    term.setCursorPos(1, height)
    write("Arrows=.1 | IJKL=5 | U=mark empty | Q=quit")
    drawAttachedMonitor(mount, mountName)
end

local function main()
    local startupOk, startupError = ensureStartupLauncher()
    if not startupOk then lastError = "STARTUP INSTALL: " .. tostring(startupError) end
    local batteryOk, batteryError = initializeBatteryIdentity()
    if not batteryOk then error("Battery identity error: " .. tostring(batteryError)) end
    local securityOk, securityError = initializeSecurity()
    if not securityOk then error("Artillery security error: " .. tostring(securityError)) end
    restoreLoadedProjectile()
    local mount, mountName = findMount()
    resolveLoaderInventories(true)
    ensureModem()
    enableMount(mount)
    -- A reboot must never inherit an asserted computer-control fire signal.
    safeStopFiring(mount)
    sendHello(mount, mountName)
    ensureMonitor(true)
    draw(mount, mountName)
    -- Arm the service timer after monitor drawing. Monitor peripheral writes
    -- yield, and a timer armed before a large draw can be consumed before the
    -- control loop resumes, permanently stopping loader/heartbeat service.
    local serviceTimer = os.startTimer(CONFIG.control_tick_s)
    -- Spread a mass boot across the heartbeat interval instead of making every
    -- gun transmit on the same scheduler tick.
    local heartbeatPhase = ((os.getComputerID() * 7919) % 1000) / 1000
    local nextHeartbeatAt = nowMs()
        + CONFIG.heartbeat_s * 1000 * (0.5 + heartbeatPhase)
    local nextDisplayAt = nowMs() + CONFIG.display_refresh_s * 1000

    local function networkLoop()
        while running do
            local _, sender, message, protocol = os.pullEvent("rednet_message")
            -- Reception does no peripheral work. It only records/coalesces the
            -- packet, so Sable, monitor, loader, or mount delays cannot stop
            -- rednet from accepting later orders.
            receiveNetworkMessage(sender, message, protocol)
        end
    end

    local function commandLoop()
        while running do
            os.pullEvent(NETWORK_INBOX_EVENT)
            local packet = nextNetworkPacket()
            while running and packet do
                local ok, commandError = pcall(
                    processNetworkMessage,
                    packet.sender, packet.message, mount, mountName
                )
                if not ok then
                    networkHandlerError = tostring(commandError)
                    lastError = "NETWORK HANDLER: " .. networkHandlerError
                    -- Keep this coroutine alive. A malformed/stale command or
                    -- one failed peripheral call must not silence the gun.
                else
                    networkHandlerError = nil
                end
                packet = nextNetworkPacket()
            end
        end
    end

    local function guardedHeartbeat()
        local ok, heartbeatError = pcall(function()
            local foundMount, foundName = findMount()
            if foundMount ~= mount then
                enableMount(foundMount)
                if not firing then safeStopFiring(foundMount) end
            end
            mount, mountName = foundMount, foundName
            ensureModem()
            sendHello(mount, mountName)
            pruneCompletedOrders()
        end)
        if not ok then
            lastError = "HEARTBEAT: " .. tostring(heartbeatError)
        end
    end

    local function guardedLoaderAndFire()
        local loaderOk, serviceError = pcall(serviceLoader)
        if not loaderOk then
            local failure = "Internal loader error: " .. tostring(serviceError)
            local reportOk = pcall(failLoaderJob, failure)
            if not reportOk then
                loaderJob = nil
                loaderState = "ERROR"
                loaderError = failure
                lastError = "LOADER: " .. failure
            end
        end
        local fireOk, fireError = pcall(serviceFire, mount)
        if not fireOk then lastError = "FIRE SERVICE: " .. tostring(fireError) end
        if firing and fireOffAt and nowMs() >= fireOffAt then
            forceFireOff(mount, "watchdog")
        end
    end

    local function guardedDraw()
        local ok, drawError = pcall(draw, mount, mountName)
        if not ok then
            monitor, monitorName = nil, nil
            lastError = "DISPLAY: " .. tostring(drawError)
        end
    end

    local function controlLoop()
        while running do
            local event, a = os.pullEvent()
            if event == "timer" then
                if a == serviceTimer then
                    local now = nowMs()
                    guardedLoaderAndFire()
                    if now >= nextHeartbeatAt then
                        guardedHeartbeat()
                        nextHeartbeatAt = nowMs() + CONFIG.heartbeat_s * 1000
                    end
                    if now >= nextDisplayAt then
                        guardedDraw()
                        nextDisplayAt = nowMs() + CONFIG.display_refresh_s * 1000
                    end
                    -- Always arm this after all yielding peripheral/display
                    -- work, so the scheduler cannot lose its only service tick.
                    serviceTimer = os.startTimer(CONFIG.control_tick_s)
                end
            elseif event == "peripheral" or event == "peripheral_detach" then
                local ok, peripheralError = pcall(function()
                    local foundMount, foundName = findMount()
                    if foundMount ~= mount then
                        enableMount(foundMount)
                        if not firing then safeStopFiring(foundMount) end
                    end
                    mount, mountName = foundMount, foundName
                    modemName = nil
                    modemNames = {}
                    monitor, monitorName = nil, nil
                    loaderOnline, loaderSourceName, loaderDepotName = false, nil, nil
                    loaderDepotNames = {}
                    ensureModem()
                    ensureMonitor(true)
                    resolveLoaderInventories(true)
                    sendHello(mount, mountName)
                end)
                if not ok then lastError = "PERIPHERAL: " .. tostring(peripheralError) end
                serviceTimer = os.startTimer(CONFIG.control_tick_s)
            elseif event == "key" then
                if a == keys.q then
                    running = false
                    return
                elseif a == keys.u then
                    if loaderJob or pendingFire or firing then
                        lastError = "Cannot mark empty while loader/fire order active"
                    else
                        loadedProjectile = nil
                        loaderState, loaderError = "EMPTY", nil
                        saveLoadedProjectile()
                        lastCommand = "Operator marked cannon EMPTY"
                    end
                else
                    applyNudge(mount, a)
                end
                guardedDraw()
                serviceTimer = os.startTimer(CONFIG.control_tick_s)
            end
        end
    end

    parallel.waitForAny(networkLoop, commandLoop, controlLoop)
    running = false
    safeStopFiring(mount)
    term.clear(); term.setCursorPos(1, 1)
    print("Gun node stopped")
end

main()
