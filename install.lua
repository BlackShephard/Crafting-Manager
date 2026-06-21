-- install.lua
-- Downloads all CC files from a HTTP server or GitHub raw URL.
--
-- Usage:
--   install.lua http://192.168.x.x:8080          (LAN / local server)
--   install.lua https://raw.githubusercontent.com/YOU/REPO/main/computercraft
--
-- The base URL is printed when you run serve.py on your PC.
-- Pastebin this file (it's tiny) then on each CC computer:
--   pastebin get <CODE> install.lua
--   install.lua http://<IP>:8080

local base = ...   -- argument passed on command line
if not base then
    print("Usage: install.lua <base_url>")
    print("Example:")
    print("  install.lua http://192.168.1.10:8080")
    return
end
base = base:gsub("/$", "")  -- strip trailing slash

-- Files to download. Edit this list if you only want some of them.
local files = {
    "server.lua",
    "station.lua",
    "processing_station.lua",
    "saw_station.lua",
    "casing_station.lua",
    "recipes.lua",
    "processing.lua",
    "config_server.lua",
    "config_station.lua",
    "config_processing_station.lua",
    "config_saw_station.lua",
    "config_casing_station.lua",
}

print("Installing from: " .. base)
print()

local ok, fail = 0, 0
for _, name in ipairs(files) do
    io.write("  " .. name .. " ... ")
    local resp, err = http.get(base .. "/" .. name)
    if resp then
        local data = resp.readAll()
        resp.close()
        local f = fs.open(name, "w")
        f.write(data)
        f.close()
        print(("OK  (%d KB)"):format(math.ceil(#data / 1024)))
        ok = ok + 1
    else
        print("FAIL  (" .. tostring(err) .. ")")
        fail = fail + 1
    end
end

print()
print(("Done: %d downloaded, %d failed."):format(ok, fail))
if fail == 0 then
    print()
    print("Next steps:")
    print("  Home computer (ID 7):  rename config_server.lua -> config.lua")
    print("                         run server.lua")
    print("  Station computer (ID 6): rename config_station.lua -> config.lua")
    print("                           run station.lua")
    print("  Processing station:      rename config_processing_station.lua -> config.lua")
    print("                           run processing_station.lua")
    print("  Saw station:             rename config_saw_station.lua -> config.lua")
    print("                           run saw_station.lua")
    print("  Casing station:          rename config_casing_station.lua -> config.lua")
    print("                           run casing_station.lua")
end
