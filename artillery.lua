-- artillery.lua
-- Direct cannon_mount artillery computer (no gear server).
-- Uses Sable pose first (if available), with mount position fallback.

local CONFIG = {
    gravity = 48.5,
    update_interval_s = 0.10,
    fire_hold_s = 0.20,
    velocity_alpha = 0.70,

    -- World yaw definition:
    -- "mc" -> 0=N(-Z), 90=E(+X), 180=S(+Z), 270=W(-X)
    -- "xz" -> 0=+X, 90=+Z, 180=-X, 270=-Z
    world_yaw_mode = "mc",

    -- Command mode for cannon mount yaw:
    -- "world"         -> setTargetAngles(yaw_world, pitch)
    -- "ship_relative" -> setTargetAngles(yaw_world - heading + auto_yaw_offset, pitch)
    yaw_command_mode = "world",
    auto_yaw_offset = 270,

    yaw_offset_deg = 0,
    pitch_offset_deg = 0,
    invert_yaw = false,
    invert_pitch = false,

    min_pitch = -10,
    max_pitch = 85,
    default_arc = "low",

    -- Some Sable/VS environments expose coordinates in wrapped shipyard space.
    -- If nonzero, shooter X/Z are unwrapped to the nearest equivalent near target.
    coord_wrap_xz = 20480000,

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
    barrels = 8,
    chambers = 2,
    manual_effective_barrels = nil,
}

local PROJECTILES = {
    {name = "Solid Shot",       mass = 3519.5},
    {name = "AP Shot",          mass = 3455.5},
    {name = "Shrapnel Shell",   mass = 3410.6},
    {name = "AP Shell",         mass = 3159.9},
    {name = "HE Shell",         mass = 2922.4},
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

local function getMountPos(info)
    return v(tonumber(info.x) or 0, tonumber(info.y) or 0, tonumber(info.z) or 0)
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
    local p = sublevel.getLogicalPose()
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

local function calcEffectiveBarrels(chargeEq)
    if CANNON.manual_effective_barrels then
        return CANNON.manual_effective_barrels, "manual"
    end
    local freeChambers = math.max(0, CANNON.chambers - chargeEq)
    return CANNON.barrels + freeChambers, "auto"
end

local function calcMuzzleVelocity(chargeEq, barrelBlocks, projMass, velMult)
    if barrelBlocks <= chargeEq then
        return nil, string.format("barrel too short (need > %.2f)", chargeEq)
    end
    local p = chargeEq * POWDER_MASS
    local L = barrelBlocks * CHARGE_LENGTH
    local c = chargeEq * CHARGE_LENGTH
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
    local p = CONFIG.invert_pitch and -pitchDeg or pitchDeg
    p = p + CONFIG.pitch_offset_deg
    return clamp(p, CONFIG.min_pitch, CONFIG.max_pitch)
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
        return readNumber("Mass (kg): ", 2922.4), "Custom"
    end
    for i, p in ipairs(PROJECTILES) do
        print(string.format("  %2d) %-18s %.1f kg", i, p.name, p.mass))
    end
    local idx = math.floor(clamp(readNumber("Select [5=HE Shell]: ", 5), 1, #PROJECTILES))
    return PROJECTILES[idx].mass, PROJECTILES[idx].name
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
            chargeEq = nil,
            effectiveBarrels = nil,
            velMult = nil,
        }
    end

    local projMass, projName = chooseProjectileMass()
    local chargeEq = readNumber("Loaded charge equivalents: ", 2)
    local eff, effMode = calcEffectiveBarrels(chargeEq)

    print(string.format("Cannon config: barrels=%s chambers=%s", tostring(CANNON.barrels), tostring(CANNON.chambers)))
    print(string.format("Effective barrels (%s): %.2f", effMode, eff))

    write(string.format("Override effective barrels [%.2f]: ", eff))
    local s = read()
    local barrelBlocks = eff
    if s ~= "" then
        local n = tonumber(s)
        if n then barrelBlocks = n end
    end
    while barrelBlocks <= chargeEq do
        print(string.format("Need effective barrels > %.2f", chargeEq))
        barrelBlocks = readNumber("Effective barrels: ", eff)
    end

    local velMult = readNumber("Velocity multiplier [1.0]: ", 1.0)
    local v0, err = calcMuzzleVelocity(chargeEq, barrelBlocks, projMass, velMult)
    if not v0 then
        print("Robins error: " .. tostring(err))
        local v0f = readNumber("Enter velocity manually (m/s): ", 180)
        return v0f, {
            mode = "manual",
            projectileName = projName,
            projectileMass = projMass,
            chargeEq = chargeEq,
            effectiveBarrels = barrelBlocks,
            velMult = velMult,
        }
    end

    print(string.format("Projectile: %s (%.1f kg)", projName, projMass))
    print(string.format("Computed v0: %.2f m/s", v0))
    return v0, {
        mode = "robins",
        projectileName = projName,
        projectileMass = projMass,
        chargeEq = chargeEq,
        effectiveBarrels = barrelBlocks,
        velMult = velMult,
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

    local newMass, newName = chooseProjectileMass()
    local v0, err = calcMuzzleVelocity(
        speedCfg.chargeEq,
        speedCfg.effectiveBarrels,
        newMass,
        speedCfg.velMult
    )
    if not v0 then
        print("Recompute error: " .. tostring(err))
        sleep(1.0)
        return nil
    end

    speedCfg.projectileMass = newMass
    speedCfg.projectileName = newName
    return v0
end

local pendingFire = false
local running = true

local function main()
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
    local velEst = v(0, 0, 0)
    local mountOffset = nil

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

            local info = mount.getInfo()
            local rawMountPos = getMountPos(info)

            local pose = getSablePose()
            local source = "mount"
            local shipHeading = nil
            local shooterPos = rawMountPos
            local shooterVel = v(0, 0, 0)

            if pose then
                source = "sable"
                shipHeading = pose.heading

                if not mountOffset then
                    mountOffset = vsub(rawMountPos, pose.pos)
                end
                shooterPos = vadd(pose.pos, mountOffset)

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
            end

            local calibratedNow = false
            if pendingCalibrate and pose then
                pendingCalibrate = false
                calibrateSableOffset(pose.pos)
                lastShipPos = nil
                mountOffset = nil
                calibratedNow = true
            elseif pendingCalibrate then
                pendingCalibrate = false
            end

            -- Normalize wrapped ship-space coordinates into the nearest world
            -- equivalent around target to avoid false "out of range" results.
            local shooterPosNorm = normalizeShooterToTarget(shooterPos, target)

            local sol, err = nil, nil
            local cmdYaw, cmdPitch = nil, nil
            if not calibratedNow then
                sol, err = solveBallistic(target, shooterPosNorm, shooterVel, muzzleSpeed, arc)
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
            print(string.format("Yaw mode: %s / %s", CONFIG.world_yaw_mode, CONFIG.yaw_command_mode))
            print(string.format("Sable off: (%.1f, %.1f, %.1f)", CONFIG.sable_offset_x, CONFIG.sable_offset_y, CONFIG.sable_offset_z))
            print(string.format("Target: (%.2f, %.2f, %.2f)", target.x, target.y, target.z))
            print(string.format("Shootr: (%.2f, %.2f, %.2f)", shooterPosNorm.x, shooterPosNorm.y, shooterPosNorm.z))
            print(string.format("Vel   : (%.2f, %.2f, %.2f)", shooterVel.x, shooterVel.y, shooterVel.z))
            if speedCfg.projectileName then
                local m = speedCfg.projectileMass
                if m then
                    print(string.format("Proj  : %s (%.1f kg)", speedCfg.projectileName, m))
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
            print("")
            print("F=fire  A=arc  T=retarget  P=projectile  V=velocity  C=calibrate  Q=quit")

            lastTime = now
            sleep(CONFIG.update_interval_s)
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
