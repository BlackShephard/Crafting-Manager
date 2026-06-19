-- ============================================================
--  discover.lua  —  Peripheral Discovery Utility
--
--  Run this on ANY computer to print all connected peripherals
--  and their types. Use the output to fill in config.lua.
--
--  Usage:  lua discover.lua
-- ============================================================

-- Try to redirect output to a monitor (much more space than the terminal).
-- Falls back to the terminal if no monitor is found.
local mon = peripheral.find("monitor")
local oldTerm  -- stores original terminal so we can restore it
if mon then
    mon.setTextScale(0.5)
    mon.clear()
    mon.setCursorPos(1, 1)
    oldTerm = term.redirect(mon)
else
    print("(no monitor found, printing to terminal)")
    print()
end

print("=== Connected Peripherals ===")
print()

local names = peripheral.getNames()

if #names == 0 then
    print("  (none found)")
    print()
    print("  Make sure wired modems are placed against each")
    print("  block and that the modem cable is connected.")
    return
end

-- Sort for readability
table.sort(names)

for _, name in ipairs(names) do
    local ptype = peripheral.getType(name)
    print(("  %-36s  %s"):format(name, ptype))

    -- Extra info for inventories
    if peripheral.hasType and peripheral.hasType(name, "inventory") then
        local p   = peripheral.wrap(name)
        local sz  = p.size and p.size() or "?"
        local cnt = 0
        for _ in pairs(p.list()) do cnt = cnt + 1 end
        print(("    \xE2\x94\x94\xE2\x94\x80 inventory: %s slots, %d occupied"):format(sz, cnt))

    -- Extra info for modems
    elseif ptype == "modem" then
        local m = peripheral.wrap(name)
        print("    \xE2\x94\x94\xE2\x94\x80 wireless: " .. tostring(m.isWireless()))
    end

    -- Always print available methods (very useful for unknown peripherals
    -- like Create_RedstoneRequester, Create_Packager, etc.)
    local methods = peripheral.getMethods(name)
    if methods and #methods > 0 then
        table.sort(methods)
        -- Print up to 8 methods per line for readability
        for i = 1, #methods, 8 do
            local chunk = {}
            for j = i, math.min(i + 7, #methods) do
                chunk[#chunk + 1] = methods[j]
            end
            local prefix = (i == 1) and "    methods: " or "             "
            print(prefix .. table.concat(chunk, ", "))
        end
    end
end

print()
print("This computer's ID: " .. os.computerID())
print()
print("Paste the peripheral names you need into config.lua")

if mon then
    -- Restore the terminal so the computer prompt comes back
    -- to the normal screen; output stays on the monitor.
    term.redirect(oldTerm)
    print("discover.lua done \xE2\x80\x94 check your monitor.")
end
