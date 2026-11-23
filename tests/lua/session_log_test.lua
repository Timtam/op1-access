-- Unit test of the mod's session logs (main.lua, "Session logs" block): rotation of
-- session-1..3.log at the start, every log() line written through, the size limit, and no
-- error without a logs folder.
-- Run with a Lua 5.4 lua.exe (built from UE4SS's LuaRaw, see docs/build-and-release.md):
--   lua.exe tests\lua\session_log_test.lua scripts\Mods\OP1Access\Scripts\main.lua <empty temp folder>

local main_path, dir = arg[1], arg[2]
assert(main_path and dir, "usage: session_log_test.lua <main.lua> <empty temp folder>")
if not dir:match("[\\/]$") then dir = dir .. "\\" end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local s = f:read("a")
    f:close()
    return s
end
local function write(path, text)
    local f = assert(io.open(path, "wb"))
    f:write(text)
    f:close()
end

-- The block from main.lua, run on its own with a fresh M; it gives back M and log.
local source = assert(read(main_path), "can't read " .. main_path)
local block = source:match("(%-%- ===== Session logs.-)%-%- ===== end of session logs =====")
assert(block, "no session log block in main.lua")
OP1_SLOG_TEST = true
local function load_block()
    local printed = {}
    local env = setmetatable({ print = function(s) printed[#printed + 1] = s end }, { __index = _G })
    local chunk = assert(load("local M = {}\n" .. block .. "\nreturn M, log", "=session-log-block", "t", env))
    local M, log = chunk()
    return M, log, printed
end

local failed, passed = 0, 0
local function test(name, fn)
    local ok, err = pcall(fn)
    if ok then passed = passed + 1; print("PASS " .. name)
    else failed = failed + 1; print("FAIL " .. name .. ": " .. tostring(err)) end
end

test("rotation keeps the last three sessions", function()
    write(dir .. "session-1.log", "one\n")
    write(dir .. "session-2.log", "two\n")
    write(dir .. "session-3.log", "three\n")
    local M, log = load_block()
    assert(M.slog_open(dir) == true, "opened")
    assert(read(dir .. "session-3.log") == "two\n", "2 -> 3")
    assert(read(dir .. "session-2.log") == "one\n", "1 -> 2")
    local s1 = read(dir .. "session-1.log")
    assert(s1:match("^%[%d%d:%d%d:%d%d [%d.]+%] OP1 Access session log, started %d%d%d%d%-%d%d%-%d%d %d%d:%d%d:%d%d\n$"),
        "new session-1 with its header: " .. s1)
    M.slog.f:close()
end)

test("rotation with fewer old logs", function()
    os.remove(dir .. "session-2.log")
    os.remove(dir .. "session-3.log")
    write(dir .. "session-1.log", "only\n")
    local M = load_block()
    assert(M.slog_open(dir))
    assert(read(dir .. "session-2.log") == "only\n", "1 -> 2")
    assert(read(dir .. "session-3.log") == nil, "no 3")
    M.slog.f:close()
end)

test("every log line is in the file at once", function()
    local M, log, printed = load_block()
    assert(M.slog_open(dir))
    log("hello")
    log(42)
    -- read while the log is still open (the game keeps it open): flushed per line
    local s1 = read(dir .. "session-1.log")
    assert(s1:find("%] hello\n"), "hello written: " .. s1)
    assert(s1:find("%] 42\n"), "a number written: " .. s1)
    assert(printed[1] == "[OP1Access] hello\n", "also printed for UE4SS.log: " .. tostring(printed[1]))
    M.slog.f:close()
end)

test("a full log starts over with its first lines", function()
    local M, log = load_block()
    assert(M.slog_open(dir))
    M.slog.max, M.slog.head_max = 2000, 3
    log("first")
    log("second")
    for i = 1, 200 do log(string.format("line %03d with some text to fill the log", i)) end
    log("the end")
    local s1 = read(dir .. "session-1.log")
    assert(#s1 <= 2000, "under the limit: " .. #s1)
    assert(s1:find("OP1 Access session log, started"), "header kept")
    assert(s1:find("%] first\n") and s1:find("%] second\n"), "first lines kept")
    assert(s1:find("the session log reached 0 MB: the lines after the first 3 were dropped here", 1, true), "note")
    assert(s1:find("%] the end\n$"), "newest line at the end")
    assert(not s1:find("line 001 "), "old middle lines dropped")
    M.slog.f:close()
end)

test("no logs folder: no session log, no error", function()
    local M, log = load_block()
    assert(M.slog_open(dir .. "missing\\") == false, "not opened")
    log("still fine")
end)

print(string.format("\n%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
