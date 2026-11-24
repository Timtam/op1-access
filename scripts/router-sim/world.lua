-- A level's collision (scripts/level-collision.py) as the traces the router makes:
-- line_blocked(ksl, p, sx, sy, sz, ex, ey, ez, ch) -> ok, hit, { Distance }, like main.lua's.
-- ch "pawn" is the capsule's own profile (sees everything); anything else is channel 0,
-- which doesn't see blocking volumes. A trace that starts inside a solid hits at 0, as the
-- game's do (the router's "no room to stand" test relies on it).
local W = {}

function W.load(path, opts)
  opts = opts or {}
  local S = dofile(path)
  local G, GS = {}, 200          -- solids by 200x200 column
  local bx0, bx1, by0, by1 = math.huge, -math.huge, math.huge, -math.huge
  for i, s in ipairs(S) do
    for gx = math.floor(s[2] / GS), math.floor(s[3] / GS) do
      for gy = math.floor(s[4] / GS), math.floor(s[5] / GS) do
        local k = gx * 100000 + gy
        local l = G[k]
        if not l then l = {}; G[k] = l end
        l[#l + 1] = i
      end
    end
    if s[1] & 1 ~= 0 and s[1] & 4 == 0 then   -- the level's own extent: its meshes
      bx0, bx1 = math.min(bx0, s[2]), math.max(bx1, s[3])
      by0, by1 = math.min(by0, s[4]), math.max(by1, s[5])
    end
  end
  local w = { solids = S, bounds = { bx0, by0, bx1, by1 }, ntraces = 0 }
  local seen, stamp = {}, 0
  local floor, min, max, sqrt = math.floor, math.min, math.max, math.sqrt
  local ch0_fences = opts.ch0_fences ~= false
  function w.line_blocked(ksl, p, sx, sy, sz, ex, ey, ez, ch)
    w.ntraces = w.ntraces + 1
    local mask = (ch == "pawn") and 2 or 1
    local dx, dy, dz = ex - sx, ey - sy, ez - sz
    local lx0, lx1, ly0, ly1 = min(sx, ex), max(sx, ex), min(sy, ey), max(sy, ey)
    local lz0, lz1 = min(sz, ez), max(sz, ez)
    stamp = stamp + 1
    local best
    for gx = floor(lx0 / GS), floor(lx1 / GS) do
      for gy = floor(ly0 / GS), floor(ly1 / GS) do
        local l = G[gx * 100000 + gy]
        if l then
          for n = 1, #l do
            local i = l[n]
            if seen[i] ~= stamp then
              seen[i] = stamp
              local s = S[i]
              local f = s[1]
              local vis = (f & mask) ~= 0
              if vis and mask == 1 and (f & 4) ~= 0 and not ch0_fences then vis = false end
              if vis and s[2] <= lx1 and s[3] >= lx0 and s[4] <= ly1 and s[5] >= ly0 and s[6] <= lz1 and s[7] >= lz0 then
                -- the segment clipped by the solid's face planes (Cyrus-Beck)
                local t0, t1 = 0, 1
                local pl = s[8]
                local miss = false
                for j = 1, #pl, 4 do
                  local nx, ny, nz, d = pl[j], pl[j + 1], pl[j + 2], pl[j + 3]
                  local dist = nx * sx + ny * sy + nz * sz - d
                  local den = nx * dx + ny * dy + nz * dz
                  if den == 0 then
                    if dist > 0 then miss = true; break end
                  else
                    local t = -dist / den
                    if den < 0 then
                      if t > t0 then t0 = t end
                    elseif t < t1 then
                      t1 = t
                    end
                    if t0 > t1 then miss = true; break end
                  end
                end
                if not miss and (not best or t0 < best) then best = t0 end
              end
            end
          end
        end
      end
    end
    if best then return true, true, { Distance = best * sqrt(dx * dx + dy * dy + dz * dz) } end
    return true, false, nil
  end
  -- the floor at (x, y) under height `from` on the capsule's profile, or nil
  function w.floor(x, y, from)
    local ok, hit, oh = w.line_blocked(nil, nil, x, y, from, x, y, -100000, "pawn")
    return hit and (from - oh.Distance) or nil
  end
  return w
end

return W
