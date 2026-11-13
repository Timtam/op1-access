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
  yet tested in-game: at the academy entrance the game picked an invisible helper from
  the always-loaded ResidentGame level; Enter did nothing. Without a path action the talk
  hint now needs a character the npc category counts as talkable, and never a hidden one.
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

- **Most markers could not be walked to** (user log 2026-11-13: "No route found" for
  Russell, Mercedes, the "!" hidden item and the objective exit from one floor down).
  Three causes:
  1. *Wrong floor for markers without an actor* — FIXED, not yet tested in-game:
     icons carry X/Y only, so the target got the player's own height and the router
     (goal accepted only within ±300 in z) searched the wrong floor. The chest category
     reached the same "!" spot fine. Markers are now pinned to the chest / exit trigger
     actor next to the icon, which gives the real height.
  2. *Targets behind a door.* Russell and Mercedes are inside the library, the
     headmaster probably behind the office door upstairs. The router walks the open map
     only and cannot pass a door that needs E. Idea: `HouseEnterTriggerBP_C.BorderBox`
     likely bounds the room; a target inside it → walk to that building's door and say
     so ("inside a building"). Needs an in-game check of BorderBox.
  3. *Search box.* The router only searches the rectangle spanned by start and goal
     plus 9 cells (~1200 units); detours around a block or to far stairs fail even when
     a path exists.
- **The navigator lists targets it cannot reach** (user request 2026-11-13: markers,
  buildings etc. should only be offered if reachable). After fixing 1–2 above: run the
  router as a quiet background check over the category's list and skip or mark the
  targets it cannot reach.
- **Exits don't say where they lead** (user request 2026-11-13). Data found in the
  object dump: each exit `LevelTrigger_C` has `MyTriggerID`/`NextTriggerID`; the
  minimap icon for it carries `LevelTriggerID` + `NextFieldName` (e.g. `T_Plain_L_A`);
  `/Game/Level/Database/LevelTable` (`LevelInfoData`: `LevelName`, `AreaID`, `TownLabel`,
  `SubTownLabel`, `WorldMapRegion`), `TownTable` (`TownLabel`/`TownName` text labels)
  and `LevelTriggerTable` look like the way from the next field to its area name
  (GetGameTextString). Needs an in-game check that the labels resolve.
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
