# Known issues

Problems noticed in existing features that are not fixed yet. Newest first. When one
gets fixed, delete its entry (the commit message keeps the history).

## Battles

Read since 2026-11-14 (84bfbf6, ece7854): command menus, skill and item lists with
cost or count and help line, boost level, targets, action names, the result screen.
Keys 1-5 read an enemy, 6-9 a party member, 0 the turn order. Tested with Cyrus alone
against one Eissentinel in the study dungeon. Not yet seen or checked:

- **Several enemies or party members.** Enemies are numbered in the order of their
  panels (widget order), the turn order lists icons in widget order. Whether both match
  the screen's left-to-right order needs a fight with more than one enemy. Party keys
  6-9 were only tried with one traveler.
- **"N targets" for an all-enemies skill** was not heard: Feuerball against one enemy
  showed a single target.
- **Status effects are read but untested** (3ad2bc9). Keys 1-9 add buffs, debuffs
  and ailments with turns left, from the `BuffIcon_C` textures. No real effect could be
  caused with a level-1 Cyrus (Verteidigen sets none), so only "no phantom effects" is
  checked. Unused icon copies first gave a false "elemental attack up, 8 turns"; now
  only icons with `IconIN` count.
- **Not read at all:** damage numbers, item drops on the result screen (the reader
  exists, no drop yet), what a boosted command does, and the boost help.
- **The same action twice in a row is said once** (the banner text did not change);
  the actor of an action is not named.
- **Lowering the boost** (the game's key for it is unknown) and whether keys 0-9 do
  anything in OT's own controls were not checked; no side effect was seen in 5 fights.

## Walker (user report 2026-11-14)

- **Freeing itself is written but untested.** When a re-route fails from a wedged spot
  the walker now takes up to 3 steps into open directions before "Step aside"
  ("Trying another way"). No wedge happened in the tests that would have shown it.
- **Wall bumps: mostly fixed, a few checks left.** The cause was OT's invisible walls,
  which the router's channel 0 doesn't see (channel 1 and the capsule's "Pawn" profile
  do, CHPROBE on every bump). Since 2026-11-14:
  - 8-neighbour routes with a cost near walls; a step the Pawn trace calls blocked costs
    8 instead of being a wall (all 7 study chests reachable).
  - Waypoints are pushed off walls before the walker heads for one; a waypoint it gets
    no closer to for 0.35 s is skipped.
  - Steering follows the leg's line, and routes stop 110 short of the target instead
    of running into a chest.

  The study's bump spot, the three chest walks and the Atlasdam walks (library,
  guards, a building upstairs) ran clean. Not checked yet:
  - Counting a waypoint as reached once the walker is past it (within 60); this is meant
    to stop the circling at turns.
  - Long walks in the dungeon: random battles stopped every one of them after 10-15 s.
  - Other towns and dungeons.

  Planning is fast since 2026-11-14: the shim fires the traces natively (0.010 ms each
  instead of 0.087 through UE4SS). The study's long chest route took 0.8 s instead of
  5.6 s, and a town search that failed took 1.5 s instead of up to 16. A grid kept per
  area is no longer needed for speed.
- **Doors from inside: only the open case is checked.** Leaving the Atlasdam library
  works since 2026-11-14 (af2f147). Its door was open every time: the walker walks on
  when 2 s of pushing into the doorway bring no "Öffnen" prompt, and steps through
  first when the route from the threshold fails. A door shut from inside (the library
  on 2026-11-13) should show the prompt and open by itself as from outside, but that
  was not seen again.
- **The side step in front of a person is untested.** When stepping straight toward
  a person behind a counter gets no closer, every other try steps sideways to stand
  square in front (Mercedes is picked at 161 with 26 to the side, not at 166 with 48).
  In the tests the route already ended in front of her.

## Path actions

Tested 2026-11-11 with Cyrus' Scrutinize ("Studieren") only. The hint, the radar gate
and the result reading are verified for that one action.

- **Other path actions' result screens are not read.** Only Scrutinize's panel
  (`FieldCommandSearch_C` → `SearchDetailPartsWidget_C`) is read when its dialog opens.
  Purchase/Steal (`FieldCommandPurchase_C`, item lists), Guide/Allure
  (`FieldCommandLure_C`), Inquire (`FieldCommandJudge_C`?) and Provoke
  (`FieldCommandMonster_C`) need their own readers once a save with those travelers
  exists. The radar gate already covers them (it uses the manager's flags).
- **"Talk, ???" for a figure you cannot talk to** (user report 2026-11-13) — FIXED, not
  confirmed: at the academy entrance the game picked an invisible helper from the
  always-loaded ResidentGame level; Enter did nothing. Without a path action the talk
  hint now needs a character the npc category counts as talkable, and never a hidden one.
  On 2026-11-14 the walker went in and out of the academy door twice without any talk
  hint, but the filter never fired either, so the exact spot was probably not hit.
- **"Talk, <name>" hint and its sound were never heard by a person.** With Cyrus nearly
  every NPC offers Scrutinize, so in testing the path-action chime played every time; the
  talk-only branch only ran for the save point ("Save point" + the generated pop,
  cue 9). By the generator formulas the pop was ~6.5 dB below the chime; since
  2026-11-14 it is ~2.7 dB below (louder, a bit longer). Whether that is right needs ears.
- **Ctrl+F9 action names** for enum values 5–7 (Guide/Allure/Inquire) are inferred from
  the event class names, not observed. 8 = Scrutinize is confirmed ("Studieren").

## Menus

- **Menus inside events are only read for save/load and confirm dialogs.** The save
  point's screen is read since 2026-11-14 ("Save", "Slot 1, empty", "An ausgewähltem
  Speicherplatz abspeichern? Nein") by a reader that runs on the game thread while an
  event is up. Other screens a game event might open (shops, inns) are not known yet;
  if one stays silent, add its class to `M.poll_event_menus`.

## Navigation

- **"Not reachable" can still be wrong for very long detours.** The router searches
  the start/goal rectangle plus 9 cells. When that runs out of cells it searches once
  more with 20 cells (~2600 units) and 6000 more traces. With native traces it then
  tries a third time with 40 cells (~5200 units) and 20000 more (since 2026-11-14).
  The +20 box fixed the Palasttor cases (the study and the palace exits, a guard
  up-left: all reachable only via the stairs outside the small box). A way round that
  leaves the +40 box, or needs more traces, still fails. Atlasdam's buildings at
  ~16000 units and one "2922, above" stay "not reachable"; the town region you can
  walk ends inside that box. A failing search now takes ~1.5-3 s.
- **The list is checked in the background, but not everything** (user request
  2026-11-13: offer only targets you can reach, or say which you can't). While you
  explore, the walk router checks the open list quietly (40 traces per tick), nearest
  and focused targets first; Palasttor's 5 exits took ~13 s with the big box. Failures
  say "not reachable" and go last when the list is built again. Not checked: targets
  inside a house you're not in (they say "inside a building"; the walk goes to the door)
  and, from inside a house, targets outside it. A result only holds within 600 of where
  you stood, so after walking off the list is checked again on the next build.
- **Room detection only works for some buildings.** "Inside a building" comes from the
  box around a door's `Actor_Room` actors (good for the Atlasdam library), and since
  2026-11-14 the target must also be on the inner side of the doorway plane, so people
  standing in front of the door (the Wachmann) no longer count. The academy rooms list
  only wall pieces on one line, so for them the doorway-plane fallback is used after a
  failed search -- which the background check now runs by itself: the headmaster says
  "inside a building" a few seconds after the npc list opens. The padding can still
  catch someone beside a house's side wall. Checked in-game: Russell, Mercedes (library)
  and the headmaster (office upstairs) all reached; the Wachmann is walked to directly.
- **Exit names are only checked in Atlasdam.** "exit 2 of 5: to Palast von Atlasdamm"
  comes from the exit's own labels; all five Palasttor exits had one. An exit without
  labels falls back to its level's town name (never seen yet), and a field or dungeon
  exit has not been tried. The exit to Atlasdamm is story-blocked right now ("Das ist
  wohl nicht der Weg …"), so no walk into another level was compared with its banner.
- **Routing through doors is new and only checked in the academy.** Since 2026-11-14
  the router may cross shut house/room doors (cost 25 cells each) and the walk stops at
  each one for E ("A shut door on the way"). Checked: the door 2353 away behind the
  office door is reached that way. Still "not reachable" from the hall: two doors two
  and three floors up (dz 918 / 1058) -- the search runs out of cells (750-1100 nodes),
  so more doors or another wing lie in between. Not yet needed in a test: the step
  through an open doorway when no route is found from its threshold ("Through the door
  first"), and "Still shut. Öffnen, E, then backspace again" at a door leg. Also: from a
  wedged corner the router fails at once (`pops=1`: the start cell counts as blocked).
