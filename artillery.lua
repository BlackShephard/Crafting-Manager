-- artillery.lua
-- Direct cannon_mount artillery computer (no gear server).
-- Uses Sable pose first (if available), with mount position fallback.

local CONFIG = {
    gravity = 9.81,
    drag_enabled = true,
    drag_air_density = 1.225,
    drag_coefficient = 0.47,
    projectile_diameter_m = 0.754441738242,
    drag_step_s = 0.05,
    drag_max_time_s = 120.0,
    drag_pitch_scan_step_deg = 2.0,
    drag_bisect_steps = 18,
    update_interval_s = 0.10,
    fire_hold_s = 0.20,
    velocity_alpha = 0.70,

    -- World yaw definition:
    -- "mc" -> 0=N(-Z), 90=E(+X), 180=S(+Z), 270=W(-X)
    -- "xz" -> 0=+X, 90=+Z, 180=-X, 270=-Z
    world_yaw_mode = "mc",

    -- Cannon mount setup:
    -- "vertical"   -> cannon assembled vertically; old working setup with -90 pitch offset
    -- "horizontal" -> cannon assembled horizontally; command solved elevation directly
    mount_profile = "vertical",

    -- Command mode for cannon mount yaw:
    -- "world"         -> setTargetAngles(yaw_world, pitch)
    -- "ship_relative" -> setTargetAngles(yaw_world - heading + auto_yaw_offset, pitch)
    yaw_command_mode = "ship_relative",
    auto_yaw_offset = 270,

    -- Command mode for cannon mount pitch:
    -- "elevation"  -> command the solved elevation angle directly
    -- "complement" -> command 90 - solved elevation, useful for some vertical mount frames
    pitch_command_mode = "elevation",

    yaw_offset_deg = 0,
    pitch_offset_deg = 0,
    invert_yaw = false,
    invert_pitch = false,

    -- Arrow-key nudge step while on the firing screen.
    nudge_step_deg = 0.1,

    min_pitch = -90,
    max_pitch = 85,
    default_arc = "low",

    -- Set nonzero only if Sable coordinates are wrapped/offset from world coords.
    -- Leave at 0 (default) -- Sable logical pose is used directly like arty3.
    coord_wrap_xz = 0,

    -- Manual additive offset for Sable coordinates.
    -- Use C key in runtime to calibrate from known current world position.
    sable_offset_x = 0,
    sable_offset_y = 0,
    sable_offset_z = 0,
}

-- Robins interior-ballistics constants from cbc_going_ballistic defaults.json
local ROBINS_K = 606.8568
local POWDER_MASS = 121.593455168150
local CHARGE_LENGTH = 1.0

local CANNON = {
    -- Effective length is the path in front of the shell:
    -- barrel blocks plus any empty chamber blocks ahead of the loaded charges.
    barrels = 6,
    chambers = 2,
    manual_effective_barrels = nil,
}

local MOUNT_PROFILES = {
    vertical = {
        yaw_command_mode = "ship_relative",
        pitch_command_mode = "elevation",
        yaw_offset_deg = 0,
        pitch_offset_deg = -90,
        invert_yaw = false,
        invert_pitch = false,
    },

    horizontal = {
        yaw_command_mode = "world",
        pitch_command_mode = "elevation",
        yaw_offset_deg = 0,
        pitch_offset_deg = 0,
        invert_yaw = false,
        invert_pitch = false,
    },
}

local PROJECTILES = {
    {name = "Solid Shot",       mass = 3519.5},
    {name = "AP Shot",          mass = 3455.5},
    {name = "Shrapnel Shell",   mass = 3410.6},
    {name = "AP Shell",         mass = 3159.9},
    {name = "HE Shell",         mass = 2922.4},
    {name = "Shell Holder MkV",  mass = 2922.4, velocity_multiplier = 1.02},
    {name = "Fluid Shell",      mass = 2400.0},
    {name = "Drop Mortar Shell", mass = 2255.5},
    {name = "Mortar Stone",     mass = 1162.3},
    {name = "Smoke Shell",      mass = 1037.0},
    {name = "Grapeshot Shell",  mass = 731.1},
}

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local function wrap360(a)
    return ((a % 360) + 360) % 360
end

local function readNumber(prompt, default)
    while true do
        write(prompt)
        local s = read()
        if s == "" and default ~= nil then return default end
        local n = tonumber(s)
        if n then return n end
        print("  Enter a number")
    end
end

local function readYesNo(prompt, defaultYes)
    while true do
        write(prompt)
        local s = string.lower(read())
        if s == "" then return defaultYes end
        if s == "y" or s == "yes" then return true end
        if s == "n" or s == "no" then return false end
        print("  Enter y or n")
    end
end

local function v(x, y, z)
    return {x = x, y = y, z = z}
end

local function vsub(a, b)
    return v(a.x - b.x, a.y - b.y, a.z - b.z)
end

local function vadd(a, b)
    return v(a.x + b.x, a.y + b.y, a.z + b.z)
end

local function vmul(a, s)
    return v(a.x * s, a.y * s, a.z * s)
end

local function vdot(a, b)
    return a.x * b.x + a.y * b.y + a.z * b.z
end

local function vlen(a)
    return math.sqrt(vdot(a, a))
end

local function vnorm(a)
    local m = vlen(a)
    if m < 1e-9 then return nil end
    return v(a.x / m, a.y / m, a.z / m)
end

local function roundNearest(x)
    if x >= 0 then
        return math.floor(x + 0.5)
    end
    return math.ceil(x - 0.5)
end

local function unwrapNear(value, reference, wrap)
    if not wrap or wrap <= 0 then return value end
    return value - roundNearest((value - reference) / wrap) * wrap
end

local function normalizeShooterToTarget(shooterPos, targetPos)
    local w = CONFIG.coord_wrap_xz
    if not w or w <= 0 then return shooterPos end
    return v(
        unwrapNear(shooterPos.x, targetPos.x, w),
        shooterPos.y,
        unwrapNear(shooterPos.z, targetPos.z, w)
    )
end

local function getMount()
    local m = peripheral.find("cannon_mount")
    if not m then error("No cannon_mount peripheral found") end
    return m
end

local function quatHeadingDegrees(o)
    local w = o.a
    local x = o.v.x
    local y = o.v.y
    local z = o.v.z
    local vx, vy, vz = 1, 0, 0
    local tx = 2 * (y * vz - z * vy)
    local ty = 2 * (z * vx - x * vz)
    local tz = 2 * (x * vy - y * vx)
    local fx = vx + w * tx + (y * tz - z * ty)
    local fz = vz + w * tz + (x * ty - y * tx)
    return wrap360(math.atan2(fx, -fz) * 180 / math.pi)
end

local function getSablePose()
    if not sublevel or type(sublevel.getLogicalPose) ~= "function" then
        return nil
    end
    local ok, p = pcall(sublevel.getLogicalPose)
    if not ok then
        return nil
    end
    if not p or not p.position or not p.orientation then
        return nil
    end
    return {
        pos = v(
            p.position.x + CONFIG.sable_offset_x,
            p.position.y + CONFIG.sable_offset_y,
            p.position.z + CONFIG.sable_offset_z
        ),
        heading = quatHeadingDegrees(p.orientation),
    }
end

local function vectorFromPositionTable(t)
    if type(t) ~= "table" then return nil end
    local x = t.x or t.X or t[1]
    local y = t.y or t.Y or t[2]
    local z = t.z or t.Z or t[3]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then
        return nil
    end
    return v(x, y, z)
end

local function getMountPosition(info)
    if type(info) ~= "table" then return nil end
    return vectorFromPositionTable(info.position)
        or vectorFromPositionTable(info.pos)
        or vectorFromPositionTable(info)
end

local function getMountInfo(mount)
    if type(mount.getInfo) ~= "function" then
        return {}
    end
    local ok, info = pcall(mount.getInfo)
    if not ok or type(info) ~= "table" then
        return {}
    end
    return info
end

local function calibrateSableOffset(currentPos)
    term.clear()
    term.setCursorPos(1, 1)
    print("=== Sable Calibration ===")
    print("Enter your actual current world position:")
    print(string.format("Current Sable: (%.2f, %.2f, %.2f)", currentPos.x, currentPos.y, currentPos.z))
    print("")
    local realX = readNumber("Actual X: ")
    local realY = readNumber("Actual Y: ")
    local realZ = readNumber("Actual Z: ")

    CONFIG.sable_offset_x = CONFIG.sable_offset_x + (realX - currentPos.x)
    CONFIG.sable_offset_y = CONFIG.sable_offset_y + (realY - currentPos.y)
    CONFIG.sable_offset_z = CONFIG.sable_offset_z + (realZ - currentPos.z)

    term.clear()
    term.setCursorPos(1, 1)
    print("Sable offsets updated:")
    print(string.format("  x = %.2f", CONFIG.sable_offset_x))
    print(string.format("  y = %.2f", CONFIG.sable_offset_y))
    print(string.format("  z = %.2f", CONFIG.sable_offset_z))
    sleep(1.0)
end

local function calcEffectiveBarrels(chargeMeters)
    if CANNON.manual_effective_barrels then
        return CANNON.manual_effective_barrels, "manual"
    end
    local emptyChambersAhead = math.max(0, CANNON.chambers - chargeMeters)
    return CANNON.barrels + emptyChambersAhead, "auto"
end

local function calcMuzzleVelocity(chargeEq, barrelBlocks, projMass, velMult)
    -- chargeEq drives both propellant energy (p) and column length (c).
    -- Going Ballistic derives chargeEq from CBC chargePower / 2.
    if barrelBlocks <= chargeEq then
        return nil, string.format("barrel too short (need > %.2f)", chargeEq)
    end
    local p  = chargeEq * POWDER_MASS
    local L  = barrelBlocks * CHARGE_LENGTH
    local c  = chargeEq * CHARGE_LENGTH
    local v2 = (p / (projMass + p / 3)) * math.log(L / c)
    if v2 <= 0 then return nil, "invalid interior-ballistics inputs" end
    return ROBINS_K * (velMult or 1.0) * math.sqrt(v2), nil
end

local function worldYawFromUnit(u)
    if CONFIG.world_yaw_mode == "xz" then
        return wrap360(math.atan2(u.z, u.x) * 180 / math.pi)
    end
    return wrap360(math.atan2(u.x, -u.z) * 180 / math.pi)
end

local function dragAccelScale(projectileMass, dragMultiplier)
    if not projectileMass or projectileMass <= 0 then return nil end
    local radius = CONFIG.projectile_diameter_m * 0.5
    local area = math.pi * radius * radius
    return 0.5 * CONFIG.drag_air_density * CONFIG.drag_coefficient * area * (dragMultiplier or 1.0) / projectileMass
end

local function simulateDragToRange(range, dy, forwardVel, verticalVel, projectileMass, dragMultiplier)
    local k = dragAccelScale(projectileMass, dragMultiplier)
    if not k then return nil, "missing projectile mass for drag" end

    local x, y = 0, 0
    local vx, vy = forwardVel, verticalVel
    local lastX, lastY, lastT = x, y, 0
    local dt = CONFIG.drag_step_s
    local t = 0

    while t < CONFIG.drag_max_time_s do
        local speed = math.sqrt(vx * vx + vy * vy)
        local ax, ay = 0, -CONFIG.gravity
        if speed > 1e-6 then
            ax = ax - k * speed * vx
            ay = ay - k * speed * vy
        end

        vx = vx + ax * dt
        vy = vy + ay * dt
        lastX, lastY, lastT = x, y, t
        x = x + vx * dt
        y = y + vy * dt
        t = t + dt

        if x >= range then
            local denom = x - lastX
            local a = (denom > 1e-9) and ((range - lastX) / denom) or 0
            local hitY = lastY + (y - lastY) * a
            local hitT = lastT + (t - lastT) * a
            return hitY - dy, hitT
        end

        if y < dy - 2000 and vy < 0 then
            return nil, "fell below target before reaching range"
        end
    end

    return nil, "target out of range with drag"
end

local function solveBallisticWithDrag(target, shooterPos, shooterVel, muzzleSpeed, arc, projectileMass, dragMultiplier)
    local r = vsub(target, shooterPos)
    local range = math.sqrt(r.x * r.x + r.z * r.z)
    if range < 1e-6 then return nil, "target too close for drag solver" end

    local horiz = v(r.x / range, 0, r.z / range)
    local worldYaw = worldYawFromUnit(horiz)
    local shooterForwardVel = vdot(shooterVel, horiz)
    local shooterVerticalVel = shooterVel.y

    local function heightError(pitchDeg)
        local pr = pitchDeg * math.pi / 180
        local forwardVel = muzzleSpeed * math.cos(pr) + shooterForwardVel
        local verticalVel = muzzleSpeed * math.sin(pr) + shooterVerticalVel
        if forwardVel <= 0 then return nil, "projectile not moving toward target" end
        return simulateDragToRange(range, r.y, forwardVel, verticalVel, projectileMass, dragMultiplier)
    end

    local brackets = {}
    local step = CONFIG.drag_pitch_scan_step_deg
    local lastPitch, lastErr = nil, nil
    local p = CONFIG.min_pitch
    while p <= CONFIG.max_pitch do
        local err = heightError(p)
        if err then
            if lastErr and lastErr * err <= 0 then
                brackets[#brackets + 1] = {lo = lastPitch, hi = p}
            end
            lastPitch, lastErr = p, err
        end
        p = p + step
    end

    if #brackets == 0 then
        return nil, "target out of range with drag"
    end

    local bracket = (arc == "high") and brackets[#brackets] or brackets[1]
    local lo, hi = bracket.lo, bracket.hi
    local errLo = heightError(lo)
    local bestPitch, bestErr, bestTof = lo, math.abs(errLo or 1e9), nil

    for _ = 1, CONFIG.drag_bisect_steps do
        local mid = 0.5 * (lo + hi)
        local errMid, tofMid = heightError(mid)
        if errMid then
            if math.abs(errMid) < bestErr then
                bestPitch, bestErr, bestTof = mid, math.abs(errMid), tofMid
            end
            if errLo and errLo * errMid <= 0 then
                hi = mid
            else
                lo = mid
                errLo = errMid
            end
        else
            hi = mid
        end
    end

    local finalErr, finalTof = heightError(bestPitch)
    bestTof = finalTof or bestTof

    return {
        worldYaw = worldYaw,
        pitch = bestPitch,
        tof = bestTof or 0,
        range = range,
        dy = r.y,
        drag = true,
        missY = finalErr,
    }
end

local function solveBallistic(target, shooterPos, shooterVel, muzzleSpeed, arc)
    local r = vsub(target, shooterPos)
    local gVec = v(0, -CONFIG.gravity, 0)

    local function f(t)
        local a = vsub(vsub(r, vmul(shooterVel, t)), vmul(gVec, 0.5 * t * t))
        return vdot(a, a) - (muzzleSpeed * t) * (muzzleSpeed * t)
    end

    local roots = {}
    local dt = 0.02
    local tMax = 120.0
    local t0 = 0.02
    local f0 = f(t0)
    local t = t0 + dt

    while t <= tMax do
        local f1 = f(t)
        if f0 == 0 or (f0 * f1 < 0) then
            local a = t - dt
            local b = t
            local fa = f0
            for _ = 1, 40 do
                local m = 0.5 * (a + b)
                local fm = f(m)
                if math.abs(fm) < 1e-8 then
                    a, b = m, m
                    break
                end
                if fa * fm <= 0 then
                    b = m
                else
                    a = m
                    fa = fm
                end
            end
            roots[#roots + 1] = 0.5 * (a + b)
            if #roots >= 6 then break end
        end
        t0 = t
        f0 = f1
        t = t + dt
    end

    if #roots == 0 then return nil, "target out of range" end
    local tof = (arc == "high") and roots[#roots] or roots[1]

    local a = vsub(vsub(r, vmul(shooterVel, tof)), vmul(gVec, 0.5 * tof * tof))
    local u = vnorm(vmul(a, 1 / (muzzleSpeed * tof)))
    if not u then return nil, "degenerate solution" end

    local worldYaw = worldYawFromUnit(u)
    local pitch = math.asin(clamp(u.y, -1, 1)) * 180 / math.pi

    return {
        worldYaw = worldYaw,
        pitch = pitch,
        tof = tof,
        range = math.sqrt(r.x * r.x + r.z * r.z),
        dy = r.y,
    }
end

local function toCommandYaw(worldYaw, shipHeading)
    local yaw = worldYaw
    if CONFIG.yaw_command_mode == "ship_relative" and shipHeading then
        yaw = worldYaw - shipHeading + CONFIG.auto_yaw_offset
    end
    if CONFIG.invert_yaw then yaw = -yaw end
    yaw = yaw + CONFIG.yaw_offset_deg
    return wrap360(yaw)
end

local function toCommandPitch(pitchDeg)
    local p = pitchDeg
    if CONFIG.pitch_command_mode == "complement" then
        p = 90 - pitchDeg
    end
    if CONFIG.invert_pitch then p = -p end
    p = p + CONFIG.pitch_offset_deg
    return clamp(p, CONFIG.min_pitch, CONFIG.max_pitch)
end

local function applyMountProfile()
    local profile = MOUNT_PROFILES[CONFIG.mount_profile]
    if not profile then
        error("Unknown mount_profile: " .. tostring(CONFIG.mount_profile))
    end
    for key, value in pairs(profile) do
        CONFIG[key] = value
    end
end

local function setComputerControl(mount)
    if type(mount.setComputerControl) == "function" then
        mount.setComputerControl(true)
    end
    if type(mount.assemble) == "function" then
        mount.assemble(true)
    end
end

local function chooseProjectileMass()
    print("")
    print("Projectile mass:")
    print("  1) From table")
    print("  2) Custom")
    local mode = readNumber("Mode [1/2] (default 1): ", 1)
    if mode == 2 then
        return readNumber("Mass (kg): ", 2922.4), "Custom", 1.0, 1.0
    end
    for i, p in ipairs(PROJECTILES) do
        local dragText = p.drag_multiplier and string.format(" drag x%.2f", p.drag_multiplier) or ""
        local velText = p.velocity_multiplier and string.format(" vel x%.2f", p.velocity_multiplier) or ""
        print(string.format("  %2d) %-18s %.1f kg%s%s", i, p.name, p.mass, velText, dragText))
    end
    local idx = math.floor(clamp(readNumber("Select [5=HE Shell]: ", 5), 1, #PROJECTILES))
    return PROJECTILES[idx].mass,
        PROJECTILES[idx].name,
        PROJECTILES[idx].drag_multiplier or 1.0,
        PROJECTILES[idx].velocity_multiplier or 1.0
end

local CHARGE_TYPES = {
    {name = "Standard",          equiv_per_slot = 1.00},
    {name = "Enhanced Mk1",      equiv_per_slot = 1.25},
    {name = "Enhanced Mk2",      equiv_per_slot = 1.50},
    {name = "Enhanced Mk3",      equiv_per_slot = 1.75},
    {name = "Enhanced Mk4",      equiv_per_slot = 2.00},
    {name = "Enhanced Mk5",      equiv_per_slot = 2.25},
    {name = "Custom (manual)",   equiv_per_slot = nil },
}

local function chooseChargeLoad()
    print("")
    print("Charge type:")
    for i, c in ipairs(CHARGE_TYPES) do
        if c.equiv_per_slot then
            print(string.format("  %d) %-20s (%.2f eq/slot)", i, c.name, c.equiv_per_slot))
        else
            print(string.format("  %d) %s", i, c.name))
        end
    end
    local idx = math.floor(clamp(readNumber("Type [1=Standard]: ", 1), 1, #CHARGE_TYPES))
    local ct = CHARGE_TYPES[idx]

    local slots = math.floor(readNumber("Number of charges loaded: ", 1))

    local equivPerSlot
    if ct.equiv_per_slot then
        equivPerSlot = ct.equiv_per_slot
    else
        equivPerSlot = readNumber("Charge equivalents per charge: ", 1.0)
    end

    local chargeEq = slots * equivPerSlot
    local chargeMeters = slots * CHARGE_LENGTH
    print(string.format("  -> %d x %.2f eq = %.3f total equiv", slots, equivPerSlot, chargeEq))
    print(string.format("  -> %.2f m loaded charge length", chargeMeters))
    return chargeEq, chargeMeters
end

local function chooseMuzzleVelocity()
    print("")
    print("Velocity mode:")
    print("  1) Direct velocity")
    print("  2) Robins (charges + cannon config)")
    local mode = readNumber("Mode [1/2] (default 1): ", 1)
    if mode == 1 then
        local v0 = readNumber("Muzzle velocity (m/s): ", 180)
        return v0, {
            mode = "manual",
            projectileName = "manual",
            projectileMass = nil,
            dragMultiplier = nil,
            projectileVelocityMultiplier = nil,
            chargeEq = nil,
            chargeMeters = nil,
            mountedLength = nil,
            velMult = nil,
        }
    end

    local projMass, projName, projDragMult, projVelMult = chooseProjectileMass()
    local chargeEq, chargeMeters = chooseChargeLoad()
    local eff, effMode = calcEffectiveBarrels(chargeMeters)

    print(string.format("Cannon config: barrels=%s chambers=%s", tostring(CANNON.barrels), tostring(CANNON.chambers)))
    print(string.format("Effective barrel length (%s): %.2f m", effMode, eff))

    write(string.format("Override effective length [%.2f m]: ", eff))
    local s = read()
    local barrelBlocks = eff
    if s ~= "" then
        local n = tonumber(s)
        if n then barrelBlocks = n end
    end
    while barrelBlocks <= chargeEq do
        print(string.format("Need effective length > %.2f m", chargeEq))
        barrelBlocks = readNumber("Effective length: ", eff)
    end

    local userVelMult = readNumber("Velocity multiplier [1.0]: ", 1.0)
    local velMult = userVelMult * projVelMult
    local v0, err = calcMuzzleVelocity(chargeEq, barrelBlocks, projMass, velMult)
    if not v0 then
        print("Robins error: " .. tostring(err))
        local v0f = readNumber("Enter velocity manually (m/s): ", 180)
        return v0f, {
            mode = "manual",
            projectileName = projName,
            projectileMass = projMass,
            dragMultiplier = projDragMult,
            projectileVelocityMultiplier = projVelMult,
            chargeEq = chargeEq,
            chargeMeters = chargeMeters,
            mountedLength = barrelBlocks,
            velMult = velMult,
            userVelMult = userVelMult,
        }
    end

    print(string.format("Projectile: %s (%.1f kg)", projName, projMass))
    if projVelMult ~= 1.0 then
        print(string.format("Projectile velocity multiplier: %.2f", projVelMult))
    end
    print(string.format("Computed v0: %.2f m/s", v0))
    return v0, {
        mode = "robins",
        projectileName = projName,
        projectileMass = projMass,
        dragMultiplier = projDragMult,
        projectileVelocityMultiplier = projVelMult,
        chargeEq = chargeEq,
        chargeMeters = chargeMeters,
        mountedLength = barrelBlocks,
        velMult = velMult,
        userVelMult = userVelMult,
    }
end

local function promptTarget()
    print("")
    local tx = readNumber("Target X: ")
    local ty = readNumber("Target Y: ")
    local tz = readNumber("Target Z: ")
    write("Arc low/high [" .. CONFIG.default_arc .. "]: ")
    local a = string.lower(read())
    local arc = (a == "high") and "high" or "low"
    return v(tx, ty, tz), arc
end

local function promptTargetOnly(currentTarget)
    print("")
    local tx = readNumber(string.format("Target X [%.2f]: ", currentTarget.x), currentTarget.x)
    local ty = readNumber(string.format("Target Y [%.2f]: ", currentTarget.y), currentTarget.y)
    local tz = readNumber(string.format("Target Z [%.2f]: ", currentTarget.z), currentTarget.z)
    return v(tx, ty, tz)
end

local function quickChangeProjectile(speedCfg)
    if speedCfg.mode ~= "robins" then
        print("Quick projectile swap needs Robins mode (V to reconfigure).")
        sleep(1.0)
        return nil
    end

    local newMass, newName, newDragMult, newVelMult = chooseProjectileMass()
    local v0, err = calcMuzzleVelocity(
        speedCfg.chargeEq,
        speedCfg.mountedLength,
        newMass,
        (speedCfg.userVelMult or 1.0) * newVelMult
    )
    if not v0 then
        print("Recompute error: " .. tostring(err))
        sleep(1.0)
        return nil
    end

    speedCfg.projectileMass = newMass
    speedCfg.projectileName = newName
    speedCfg.dragMultiplier = newDragMult
    speedCfg.projectileVelocityMultiplier = newVelMult
    speedCfg.velMult = (speedCfg.userVelMult or 1.0) * newVelMult
    return v0
end

local pendingFire = false
local running = true

local function main()
    applyMountProfile()

    local mount = getMount()
    setComputerControl(mount)

    local target, arc = promptTarget()
    local muzzleSpeed, speedCfg = chooseMuzzleVelocity()
    local compensateMotion = readYesNo("Compensate ship motion? [Y/n]: ", true)

    local pendingRetarget = false
    local pendingArcToggle = false
    local pendingVelocityReconfig = false
    local pendingProjectileSwap = false
    local pendingCalibrate = false

    local lastTime = os.epoch("utc") / 1000
    local lastShipPos = nil
    local lastGoodSablePos = nil
    local velEst = v(0, 0, 0)

    local function controlLoop()
        while running do
            if pendingRetarget then
                pendingRetarget = false
                target = promptTargetOnly(target)
            end
            if pendingArcToggle then
                pendingArcToggle = false
                arc = (arc == "low") and "high" or "low"
            end
            if pendingVelocityReconfig then
                pendingVelocityReconfig = false
                muzzleSpeed, speedCfg = chooseMuzzleVelocity()
            end
            if pendingProjectileSwap then
                pendingProjectileSwap = false
                local vNew = quickChangeProjectile(speedCfg)
                if vNew then muzzleSpeed = vNew end
            end

            local now = os.epoch("utc") / 1000
            local dt = math.max(1e-3, now - lastTime)

            local info = getMountInfo(mount)

            local pose = getSablePose()
            local source = "unknown"
            local shipHeading = nil
            local shooterPos = nil
            local shooterVel = v(0, 0, 0)

            if pose then
                source = "sable"
                shipHeading = pose.heading
                shooterPos = pose.pos
                lastGoodSablePos = pose.pos

                if lastShipPos then
                    local rawVel = vmul(vsub(pose.pos, lastShipPos), 1 / dt)
                    velEst = v(
                        CONFIG.velocity_alpha * velEst.x + (1 - CONFIG.velocity_alpha) * rawVel.x,
                        CONFIG.velocity_alpha * velEst.y + (1 - CONFIG.velocity_alpha) * rawVel.y,
                        CONFIG.velocity_alpha * velEst.z + (1 - CONFIG.velocity_alpha) * rawVel.z
                    )
                end
                lastShipPos = pose.pos
                shooterVel = compensateMotion and velEst or v(0, 0, 0)
            else
                local mountPos = getMountPosition(info)
                shooterPos = mountPos or lastGoodSablePos
                if shooterPos then
                    source = mountPos and "mount" or "last-sable"
                end
                lastShipPos = nil
                velEst = v(0, 0, 0)
            end

            if not shooterPos then
                term.clear(); term.setCursorPos(1,1)
                print("Waiting for cannon position...")
                print("No Sable ship pose and mount.getInfo() has no position.")
                sleep(CONFIG.update_interval_s)
                goto continue
            end

            local calibratedNow = false
            if pendingCalibrate and pose then
                pendingCalibrate = false
                calibrateSableOffset(pose.pos)
                lastShipPos = nil
                calibratedNow = true
            elseif pendingCalibrate then
                pendingCalibrate = false
            end

            -- Use shooter position directly from Sable (same as arty3).
            local shooterPosNorm = shooterPos

            local sol, err = nil, nil
            local cmdYaw, cmdPitch = nil, nil
            if not calibratedNow then
                if CONFIG.drag_enabled and speedCfg.projectileMass then
                    sol, err = solveBallisticWithDrag(
                        target,
                        shooterPosNorm,
                        shooterVel,
                        muzzleSpeed,
                        arc,
                        speedCfg.projectileMass,
                        speedCfg.dragMultiplier
                    )
                else
                    sol, err = solveBallistic(target, shooterPosNorm, shooterVel, muzzleSpeed, arc)
                end
                if sol then
                    cmdYaw = toCommandYaw(sol.worldYaw, shipHeading)
                    cmdPitch = toCommandPitch(sol.pitch)
                    mount.setTargetAngles(cmdYaw, cmdPitch)
                end

                if pendingFire then
                    pendingFire = false
                    mount.fire(true)
                    sleep(CONFIG.fire_hold_s)
                    mount.fire(false)
                end
            else
                err = "Sable calibration updated"
            end

            term.clear()
            term.setCursorPos(1, 1)
            print("=== Artillery (Direct cannon_mount) ===")
            print(string.format("Source:%s  Arc:%s  v0:%.2f (%s)", source, arc, muzzleSpeed, speedCfg.mode))
            print(string.format("Drag  : %s", (CONFIG.drag_enabled and speedCfg.projectileMass) and "on" or "off"))
            print(string.format("Mount : %s", CONFIG.mount_profile))
            print(string.format("Yaw mode: %s / %s", CONFIG.world_yaw_mode, CONFIG.yaw_command_mode))
            print(string.format("Pitch mode: %s", CONFIG.pitch_command_mode))
            print(string.format("Sable off: (%.1f, %.1f, %.1f)", CONFIG.sable_offset_x, CONFIG.sable_offset_y, CONFIG.sable_offset_z))
            print(string.format("Target: (%.2f, %.2f, %.2f)", target.x, target.y, target.z))
            print(string.format("Shootr: (%.2f, %.2f, %.2f)", shooterPosNorm.x, shooterPosNorm.y, shooterPosNorm.z))
            print(string.format("Vel   : (%.2f, %.2f, %.2f)", shooterVel.x, shooterVel.y, shooterVel.z))
            if speedCfg.projectileName then
                local m = speedCfg.projectileMass
                if m then
                    print(string.format("Proj  : %s (%.1f kg)", speedCfg.projectileName, m))
                    if speedCfg.projectileVelocityMultiplier and speedCfg.projectileVelocityMultiplier ~= 1.0 then
                        print(string.format("Vel x : %.2f", speedCfg.projectileVelocityMultiplier))
                    end
                    if speedCfg.dragMultiplier and speedCfg.dragMultiplier ~= 1.0 then
                        print(string.format("Drag x: %.2f", speedCfg.dragMultiplier))
                    end
                else
                    print(string.format("Proj  : %s", speedCfg.projectileName))
                end
            end
            if shipHeading then
                print(string.format("Heading: %.2f", shipHeading))
            else
                print("Heading: N/A")
            end
            if sol then
                print(string.format("Sol yaw/pitch: %.2f / %.2f  TOF: %.2f", sol.worldYaw, sol.pitch, sol.tof))
                print(string.format("Cmd yaw/pitch: %.2f / %.2f", cmdYaw, cmdPitch))
            else
                print("No solution: " .. tostring(err))
            end
            print(string.format("Trim  yaw/pitch: %+.2f / %+.2f  (arrows to nudge)",
                CONFIG.yaw_offset_deg, CONFIG.pitch_offset_deg))
            print("")
            print("F=fire A=arc T=retarget P=proj V=vel C=cal arrows=trim Q=quit")

            lastTime = now
            sleep(CONFIG.update_interval_s)
            ::continue::
        end
    end

    local function keyLoop()
        while running do
            local _, key = os.pullEvent("key")
            if key == keys.f then
                pendingFire = true
            elseif key == keys.a then
                pendingArcToggle = true
            elseif key == keys.t then
                pendingRetarget = true
            elseif key == keys.p then
                pendingProjectileSwap = true
            elseif key == keys.v then
                pendingVelocityReconfig = true
            elseif key == keys.c then
                pendingCalibrate = true
            elseif key == keys.up then
                CONFIG.pitch_offset_deg = CONFIG.pitch_offset_deg + CONFIG.nudge_step_deg
            elseif key == keys.down then
                CONFIG.pitch_offset_deg = CONFIG.pitch_offset_deg - CONFIG.nudge_step_deg
            elseif key == keys.right then
                CONFIG.yaw_offset_deg = CONFIG.yaw_offset_deg + CONFIG.nudge_step_deg
            elseif key == keys.left then
                CONFIG.yaw_offset_deg = CONFIG.yaw_offset_deg - CONFIG.nudge_step_deg
            elseif key == keys.q then
                running = false
            end
        end
    end

    parallel.waitForAny(controlLoop, keyLoop)
    term.clear()
    term.setCursorPos(1, 1)
    print("Artillery stopped")
end

main()
