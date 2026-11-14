# Known issues

Problems noticed in existing features that are not fixed yet. Newest first. When one
gets fixed, delete its entry (the commit message keeps the history).

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
  cue 9). Check the pop's loudness and character against the chime.
- **Ctrl+F9 action names** for enum values 5–7 (Guide/Allure/Inquire) are inferred from
  the event class names, not observed. 8 = Scrutinize is confirmed ("Studieren").

## Menus

- **The save screen at a save point is not read.** Pressing Enter at a save point (the
  book on a lectern, "save point" in the marker category) opens "Speichern", but the
  game runs it inside an event, and the menu poller pauses during events
  (`M.menu_unsafe`, a crash guard). The slots and the cursor stay silent. Escape or
  Backspace leaves it. A fix needs a reader that only uses the active stack and plain
  property reads while an event is up.

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
- **"Inside a building" for someone standing outside the door.** The Wachmann in front of
  the Atlasdam library counts as inside: the library's room box (its `Actor_Room` actors
  plus 250 padding) reaches past the door. A walk to him goes to the library door first.
  Fix idea: also require the target to be on the inner side of the doorway plane
  (`BorderBox`).
- **Room detection only works for some buildings.** "Inside a building" comes from the
  box around a door's `Actor_Room` actors (good for the Atlasdam library). The academy
  rooms list only wall pieces on one line, so for them the doorway-plane fallback is
  used, and only after a route failed ("Probably inside a building"). Checked in-game:
  Russell, Mercedes (library) and the headmaster (office upstairs) all reached.
- **Exit names are only checked in Atlasdam.** "exit 2 of 5: to Palast von Atlasdamm"
  comes from the exit's own labels; all five Palasttor exits had one. An exit without
  labels falls back to its level's town name (never seen yet), and a field or dungeon
  exit has not been tried. The exit to Atlasdamm is story-blocked right now ("Das ist
  wohl nicht der Weg …"), so no walk into another level was compared with its banner.
- **Pathfinder gives up on long routes to another floor.** In the Atlasdam academy hall,
  routing to targets on the upper floor fails from most spots
  (`ROUTE fail traces≈1800 pops≈260` → "No route found"). From one spot it found a
  13-waypoint "traced route, upstairs", so the search budget looks too small for long
  multi-level routes. From a wedged corner it fails at once (`pops=1`: the start cell
  itself counts as blocked). The second, bigger search box (2026-11-14) may help here;
  not tried in the academy hall yet.
- **Premature "Arrived" with a target on another floor.** Seen once in the academy hall:
  "Routing to building, 790" was followed by "Arrived" one second later without getting
  there; the target was on the upper floor. Suspect: the 170-unit arrival radius in
  `nav_walk_watch` compares 2D distance only. (The exit case — "Arrived" 150 short of a
  trigger behind the last waypoint — is fixed: exits are walked through.)
- **Entering a door after "Öffnen, E" can need a sideways step.** At the academy door, E
  opened it but walking up hit the door frame until the character stepped left onto the
  door's center line. The walker stops where the prompt appears, which can be off-center.
- **A menu opening mid-walk should stop the walk** (`M.menu_now` in `nav_drive`) —
  written, not yet seen in-game.
