# The walker's router without the game

When the walker says "not reachable" somewhere you can't get to yourself (a player's
report, a save in another chapter), the router can run on that level's own collision,
outside the game: the same search code, cut from `main.lua`, with the traces answered from
the level's files. It found the Mountain Pass bug of 0.1.0 (2026-11-24): the search failed
there just as in the player's log (pops 976 against 843, ledges 226 against 202), and the
one step at fault showed up (an invisible bridge deck, see `nav_ground` in `main.lua`).

## 1. The level's collision

Extract the area level as for `scripts/level-dump.py` (both files, repak from `tools\`):

    tools\repak\repak.exe unpack -q -o <out> -i Octopath_Traveler/Content/Level/Area/Mount/F_Mount_1_1.umap
        -i Octopath_Traveler/Content/Level/Area/Mount/F_Mount_1_1.uexp "<game>\...\Paks\Octopath_Traveler-WindowsNoEditor.pak"

Then build its collision:

    python -I -X utf8 scripts\level-collision.py <out>\...\F_Mount_1_1.umap "<pak>" <dir>\F_Mount_1_1.lua

It extracts the meshes and Blueprints the level uses into `<dir>\assets` (the first run
also lists the pak, about a minute) and writes every solid as convex planes: the ground
and cliff meshes' convex collision, every other mesh's simple collision (boxes, convexes),
the KSMapEditor fence boxes along terrace edges, and the blocking volumes. The file is game
data: keep it out of the repository.

## 2. A search

    build\shim\lua.exe scripts\router-sim\route.lua scripts\Mods\OP1Access\Scripts\main.lua
        <dir>\F_Mount_1_1.lua <sx> <sy> <sfloor> <tx> <ty> <tfloor> [path] [norise] [noch0fences] [verbose]

- Positions come from the session log: `WALLTICK ... pos=(x,y)` every 2 s, `EXIT goal`
  lines, targets' `REACH ... dz=`. A floor is a number, `top` (the highest floor there)
  or `under<z>` (the first floor below z, for a spot under a cliff or a bridge).
- The output line has the numbers of the game's `ROUTE fail` / `ROUTE ok` lines; `path`
  prints the route's cells with their floors, `verbose` the router's own log lines.
- `norise` switches the ledge rule (`NV.rise_ok`) off, `noch0fences` lets channel 0 miss
  the fence boxes: to see which rule a failure hangs on.

Example (the Mountain Pass, from the Cobbleston entrance to the Brigands' Den exit):

    (-2061,-3301) floor 101 -> (4600,2340) floor 2001: found pops=1653 ledges=126 ...
    (0.1.0's main.lua: NOT reachable pops=976 ledges=226 no-room=635 ...)

## What it models, and what not

- Channel 0 (the router's floor and wall traces) sees the meshes and the fence boxes, not
  the blocking volumes; the capsule's profile (`NV_TRACE`) sees everything. A trace that
  starts inside a solid hits at 0, as in the game.
- Only the search: no walking, no people, no doors, no walls learned from bumps, no
  battles. The area box comes from the level's own extent, not from the field objects.
- The router is cut from `main.lua` at the same markers as the mock router tests; when
  one moves, `route.lua` names it.
