-- The walker's router (cut from main.lua) on a level's real collision, without the game:
-- one search from a start to a goal, as the walk would make it, with the ROUTE numbers
-- the game logs (pops, ledges, no-room, capsule-floors). See docs/router-sim.md.
--
-- Usage: lua route.lua <main.lua> <world.lua> <sx> <sy> <sfloor> <tx> <ty> <tfloor> [options]
--   a floor is a number, "top" (the highest floor there) or "under<z>" (the first floor
--   below z, e.g. under450). Options: path (print the route's cells), norise (without the
--   ledge rule, NV.rise_ok), noch0fences (channel 0 doesn't see the KSMapEditor fence
--   boxes), verbose (the router's log lines).
-- Exit code 0 = found, 1 = not reachable.
local function dirof(p)
  for i = #p, 1, -1 do
    local c = p:sub(i, i)
    if c == "/" or c == string.char(92) then return p:sub(1, i) end
  end
  return ""
end
if #arg < 8 then
  io.stderr:write("usage: lua route.lua <main.lua> <world.lua> <sx> <sy> <sfloor> <tx> <ty> <tfloor> [path] [norise] [noch0fences] [verbose]\n")
  os.exit(2)
end
local f = assert(io.open(arg[1], "rb"))
local src = f:read("a")
f:close()
local function cut(a_pat, b_pat)
  local a = assert(src:find(a_pat, 1, true), "main.lua changed: no '" .. a_pat .. "'")
  local b = assert(src:find(b_pat, a, true), "main.lua changed: no '" .. b_pat .. "'")
  return src:sub(a, b - 1)
end
local opt = {}
for i = 9, #arg do opt[arg[i]] = true end
local World = dofile(dirof(arg[0]) .. "world.lua")
local W = World.load(arg[2], { ch0_fences = not opt.noch0fences })

-- what the router needs from the mod around it
local M = { door_list = function() return {} end, tr_native = true, area_said = "sim", pfoot = 82,
  level_id = function() return 1 end, handle_ok = function(h) return h ~= nil end }
-- the "whole area" box comes from the field objects: the level's own extent here
local b = W.bounds
local OBJECTS = { { x = b[1], y = b[2] }, { x = b[3], y = b[4] } }
M.fa_cache = setmetatable({}, { __index = function(_, cls)
  if cls ~= "TreasureBoxBP_C" then return nil end
  return { key = 1, list = OBJECTS, hs = { true, true } }
end })
local env = setmetatable({ line_blocked = W.line_blocked, NV_TRACE = "pawn", M = M,
  read_actor_pos = function(o) return o.x, o.y, 0 end,
  StaticFindObject = function() return {} end, get_player_obj = function() return {} end,
  class_name_of = function(a) return a and a.cls end,
  LOG = function(s) if opt.verbose then print(s) end end }, { __index = _G })
-- the same cut as the mock router tests (tests of 2026-11-14 on): the grid A*, floors,
-- the ledge rule, slides, the search box and its retries
local code = "local NV = { STEP = 130 }\nlocal M = M\nlocal function log(s) LOG(s) end\n"
  .. "local line_blocked = line_blocked\nlocal LEVEL_THRESH = 250\n"
  .. cut("local function cellkey(", "local function nav_route_finish(")
  .. cut("-- FLOORS, NOT HEIGHTS", "-- A body-wide straight corridor")
  .. cut("NV.heap_push = function(", "NV.route_job = function(")
  .. cut("NV.route_job = function(", "-- The first shut door a found route goes through")
  .. cut("-- Second try in a bigger box", "-- Why a route died at its start")
  .. cut("NV.SLIDES = {", "local function nav_route_step()")
  .. "\nreturn NV\n"
local NV = assert(load(code, "router", "t", env))()
NV.DIRS8 = NV.DIRS8 or { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
NV.walls_here = function() return {} end
NV.people_scan = function() return {} end
if opt.norise then NV.rise_ok = function() return true end end

local function floor_of(x, y, spec)
  local n = tonumber(spec)
  if n then return n end
  if spec == "top" then return W.floor(x, y, 100000) end
  local z = tonumber((spec or ""):match("^under(-?%d+)$"))
  if z then return W.floor(x, y, z) end
  error("a floor is a number, top or under<z>: " .. tostring(spec))
end
local sx, sy, tx, ty = tonumber(arg[3]), tonumber(arg[4]), tonumber(arg[6]), tonumber(arg[7])
local sz, tz = floor_of(sx, sy, arg[5]), floor_of(tx, ty, arg[8])
assert(sz and tz, "no floor at the start or the goal")

local c0 = os.clock()
NV.abox = nil
local R = NV.route_job("walk", tx, ty, tz, sx, sy, sz + 82)
local res, node
while true do
  res, node = NV.route_slice(R, 1e9, 1e9, nil)
  if res == "found" then break end
  if res == "fail" then
    local Wn = (node == "box" or node == "cap") and (NV.route_widen(R) or NV.route_shift(R, node))
    if not Wn then break end
    R = Wn
  end
end
print(string.format("(%d,%d) floor %.0f -> (%d,%d) floor %.0f: %s pops=%d ledges=%d no-room=%d capsule-floors=%d traces=%d %.1fs",
  sx, sy, sz, tx, ty, tz, res == "found" and "found" or "NOT reachable", R.pops or 0, R.nledge or 0, R.nroom or 0,
  R.npawn or 0, W.ntraces, os.clock() - c0))
if res == "found" and opt.path then
  local pts, nd = {}, node
  while nd do
    pts[#pts + 1] = string.format("(%.0f,%.0f,%.0f)", R.px + nd.x * NV.STEP + (nd.ox or 0), R.py + nd.y * NV.STEP + (nd.oy or 0), nd.z)
    if nd.k == R.startk then break end
    nd = R.came[nd.k]
  end
  for i = #pts, 1, -1 do print(pts[i]) end
end
os.exit(res == "found" and 0 or 1)
