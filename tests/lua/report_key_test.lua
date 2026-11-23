-- Unit test of F1 twice (main.lua, "Problem reports" block): the first press asks, the second
-- starts OP1AccessInstaller.exe --report --game <folder>; a build without the form key says so.
-- Run with a Lua 5.4 lua.exe:
--   lua.exe tests\lua\report_key_test.lua scripts\Mods\OP1Access\Scripts\main.lua

local main_path = assert(arg[1], "usage: report_key_test.lua <main.lua>")
local f = assert(io.open(main_path, "rb"))
local source = f:read("a")
f:close()
local block = source:match("(%-%- ===== Problem reports.-)\nM%.fast_steps")
assert(block, "no problem report block in main.lua")

local GAME = "C:\\Games\\OCTOPATH TRAVELER"
local function setup(build, start_ok)
    local said, started, clock = {}, {}, 100
    local env = setmetatable({
        speak = function(text, interrupt) said[#said + 1] = text end,
        tr = function(s) return s end,
        log = function() end,
        shim = {
            StartProcess = function(exe, args)
                started[#started + 1] = { exe = exe, args = args }
                if start_ok then return true end
                return false, 2
            end,
        },
        RegisterKeyBind = function() return true end,
        Key = { F1 = 0x70 },
        os = setmetatable({ clock = function() return clock end }, { __index = os }),
    }, { __index = _G })
    local M = {
        build = build,
        bin_dir = function() return GAME .. "\\Octopath_Traveler\\Binaries\\Win64" end,
        mod_dir_abs = function() return GAME .. "\\Octopath_Traveler\\Binaries\\Win64\\ue4ss\\Mods\\OP1Access\\" end,
    }
    env.M = M
    local chunk = assert(load(block, "=report-block", "t", env))
    chunk()
    return M, said, started, function(t) clock = t end
end

local failed, passed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

test("first press asks, second opens the window", function()
    local M, said, started, set_clock = setup({ report = true }, true)
    M.report_key()
    assert(#started == 0, "nothing started yet")
    assert(said[1]:find("press F1 again", 1, true), said[1])
    set_clock(105)
    M.report_key()
    assert(#started == 1, "started once")
    assert(started[1].exe == GAME .. "\\Octopath_Traveler\\Binaries\\Win64\\ue4ss\\Mods\\OP1Access\\OP1AccessInstaller.exe", started[1].exe)
    assert(started[1].args == '--report --game "' .. GAME .. '"', started[1].args)
    assert(said[2] == "Opening the problem report window", said[2])
end)

test("the second press must come within 10 seconds", function()
    local M, said, started, set_clock = setup({}, true)
    M.report_key()
    set_clock(111)
    M.report_key()
    assert(#started == 0, "too late: asks again")
    assert(said[2]:find("press F1 again", 1, true), said[2])
end)

test("a build without the form key says so", function()
    local M, said, started = setup({ report = false }, true)
    M.report_key()
    M.report_key()
    assert(#started == 0, "nothing started")
    assert(said[1] == "Problem reports are not available in this build" and said[2] == said[1], tostring(said[1]))
end)

test("no installer in the mod folder", function()
    local M, said, started, set_clock = setup({}, false)
    M.report_key()
    set_clock(101)
    M.report_key()
    assert(#started == 1, "tried")
    assert(said[2] == "Could not open the problem report window", said[2])
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
