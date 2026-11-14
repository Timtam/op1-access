# Known issues

Problems noticed in existing features that are not fixed yet. Newest first. When one
gets fixed, delete its entry (the commit message keeps the history).

## Battles (user report 2026-11-14)

- **Battle menus are not read at all.** Command menu (Angriff, Gelehrter-Fertigkeiten,
  Objekt, Verteidigen, Fliehen), skills, items, target choice, turn order and the result
  screen are silent; only the battle tutorials are read. In battle the UI manager's
  focused screen is `InputWrapper_C`. The battle UI classes are in the object dump
  (`BattleCommandMenu_C` / `BattleCommandMenuItem_C`, `BattleCommandHelpWindow_C`,
  `BattleTargetCursor_C`, `BattleEnemyStatus_C`, `WeakStatusIcon_C`, `BreakStatusIcon_C`,
  `ActionOrderTimeLine_C`, `BattleResultPanelWidget_C`).
- **Enemy information needs shortcuts:** names, HP if shown, shield points, revealed
  weaknesses, break state, turn order -- on keys, without having to target each enemy.
  (Battles are gated since 2026-11-14: the navigator keys say "In battle".)

## Walker (user report 2026-11-14)

- **Freeing itself is written but untested.** When a re-route fails from a wedged spot
  the walker now takes up to 3 steps into open directions before "Step aside"
  ("Trying another way"). No wedge happened in the tests that would have shown it.
- **Too many re-routes and wall bumps.** Routes hug walls (4-neighbour grid of 130-unit
  cells, the path keeps every corner cell) and the walker cuts corners. Ideas: smooth the
  path by line of sight with the body-wide test, a cost for cells next to walls,
  8-neighbour steps, steering toward the farthest visible waypoint, and a walkability
  grid traced once per area in the background and kept -- then a search is instant, and
  one Dijkstra/BFS flood from the player answers reachability for the whole list at
  once instead of one A* per target.

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
  the start/goal rectangle plus 9 cells, and when that runs out of cells, once more with
  20 cells (~2600 units) and 6000 more traces. That fixed the Palasttor cases (the study
  and the palace exits, a guard up-left: all reachable only via the stairs outside the
  small box). A way round that leaves even the big box, or needs more traces, still
  fails. A failing walk can now take up to ~16 s ("Still routing") instead of ~8.
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
