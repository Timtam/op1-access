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

- **The router's search box.** It only searches the rectangle spanned by start and goal
  plus 9 cells (~1200 units); detours around a block or to far stairs fail even when a
  path exists. Such targets now say "not reachable" after one failed try (see below),
  which can be wrong for them.
- **The navigator still lists targets it cannot reach** (user request 2026-11-13:
  markers, buildings etc. should only be offered if reachable). Now: a target inside a
  building says "inside a building" and the walk leads to its door; a target the router
  failed on says "not reachable" from then on (from about the same spot). Not done: a
  quiet background check of the whole list before you ever try a target.
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
  itself counts as blocked).
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
