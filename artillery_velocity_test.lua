-- Desktop Lua test harness for artillery.lua interior-ballistics math.
-- Run with:
--   lua artillery_velocity_test.lua
--   lua artillery_velocity_test.lua projectile=he charge=4 rifled=6 unrifled=0 chambers=2

local ROBINS_K = 606.8568
local POWDER_MASS = 121.593455168150
local CHARGE_LENGTH = 1.0

local PROJECTILES = {
    he = {
        name = "HE Shell",
        mass = 3519.5,
        charge_multiplier = 1.0,
    },
    shell_holder_mk5 = {
        name = "Shell Holder MkV",
        mass = 3519.5,
        -- Matched from Going Ballistic launch debug:
        -- raw chargeEquivalent 4.0 -> launch chargeEquivalent 3.3674774169921875
        charge_multiplier = 0.8418693542480469,
    },
}

local defaults = {
    projectile = "shell_holder_mk5",
    raw_charge_equivalent = 4.0,
    rifled_barrels = 6,
    unrifled_barrels = 0,
    chambers = 2,
    rifled_velocity_multiplier = 0.985,
    expected_velocity = 172.5386601850819,
}

local aliases = {
    projectile = "projectile",
    proj = "projectile",
    charge = "raw_charge_equivalent",
    raw_charge = "raw_charge_equivalent",
    charge_equivalent = "raw_charge_equivalent",
    rifled = "rifled_barrels",
    unrifled = "unrifled_barrels",
    chambers = "chambers",
    chamber = "chambers",
    rifled_mult = "rifled_velocity_multiplier",
    expected = "expected_velocity",
}

local function copyDefaults()
    local t = {}
    for k, v in pairs(defaults) do
        t[k] = v
    end
    return t
end

local function parseArgs()
    local cfg = copyDefaults()
    for _, arg in ipairs(arg or {}) do
        local key, value = arg:match("^([^=]+)=(.+)$")
        if key and value then
            key = aliases[key] or key
            if key == "projectile" then
                cfg.projectile = value
            elseif cfg[key] ~= nil then
                local n = tonumber(value)
                if not n then
                    error("Expected numeric value for " .. key .. ", got " .. value)
                end
                cfg[key] = n
            else
                error("Unknown option: " .. key)
            end
        else
            error("Expected key=value argument, got: " .. tostring(arg))
        end
    end
    return cfg
end

local function calcMuzzleVelocity(chargeEq, barrelBlocks, projMass, velMult)
    if barrelBlocks <= chargeEq then
        return nil, string.format("barrel too short: length %.6f <= charge %.6f", barrelBlocks, chargeEq)
    end

    local p = chargeEq * POWDER_MASS
    local L = barrelBlocks * CHARGE_LENGTH
    local c = chargeEq * CHARGE_LENGTH
    local v2 = (p / (projMass + p / 3)) * math.log(L / c)

    if v2 <= 0 then
        return nil, "invalid interior-ballistics inputs"
    end

    return ROBINS_K * (velMult or 1.0) * math.sqrt(v2), nil, {
        powder_mass = p,
        barrel_length = L,
        charge_length = c,
        v2 = v2,
    }
end

local function main()
    local cfg = parseArgs()
    local projectile = PROJECTILES[cfg.projectile]
    if not projectile then
        error("Unknown projectile: " .. tostring(cfg.projectile))
    end

    local launchChargeEq = cfg.raw_charge_equivalent * projectile.charge_multiplier
    local barrelLength = cfg.rifled_barrels + cfg.unrifled_barrels + cfg.chambers
    local cannonVelocityMultiplier = cfg.rifled_velocity_multiplier ^ cfg.rifled_barrels

    local rawVelocity, rawErr, rawInfo = calcMuzzleVelocity(
        launchChargeEq,
        barrelLength,
        projectile.mass,
        1.0
    )
    if not rawVelocity then
        error(rawErr)
    end

    local finalVelocity, finalErr = calcMuzzleVelocity(
        launchChargeEq,
        barrelLength,
        projectile.mass,
        cannonVelocityMultiplier
    )
    if not finalVelocity then
        error(finalErr)
    end

    print("=== Artillery Velocity Test ===")
    print(string.format("Projectile: %s", projectile.name))
    print(string.format("Mass: %.12f kg", projectile.mass))
    print(string.format("Raw charge equivalent: %.12f", cfg.raw_charge_equivalent))
    print(string.format("Projectile charge multiplier: %.15f", projectile.charge_multiplier))
    print(string.format("Launch charge equivalent: %.15f", launchChargeEq))
    print(string.format("Powder mass: %.12f kg", rawInfo.powder_mass))
    print(string.format("Rifled barrels: %.0f", cfg.rifled_barrels))
    print(string.format("Unrifled barrels: %.0f", cfg.unrifled_barrels))
    print(string.format("Chambers: %.0f", cfg.chambers))
    print(string.format("Mounted barrel length: %.12f m", barrelLength))
    print(string.format("Rifled velocity multiplier: %.15f", cfg.rifled_velocity_multiplier))
    print(string.format("Cannon velocity multiplier: %.15f", cannonVelocityMultiplier))
    print(string.format("Raw Robins velocity: %.12f m/s", rawVelocity))
    print(string.format("Final muzzle velocity: %.12f m/s", finalVelocity))
    print(string.format("Final muzzle velocity: %.12f blocks/tick", finalVelocity / 20.0))

    if cfg.expected_velocity then
        local delta = finalVelocity - cfg.expected_velocity
        print(string.format("Expected velocity: %.12f m/s", cfg.expected_velocity))
        print(string.format("Delta: %.12f m/s", delta))
    end
end

main()
