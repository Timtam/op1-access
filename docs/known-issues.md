# Known issues

Problems noticed in existing features that are not fixed yet. Newest first. When one
gets fixed, delete its entry (the commit message keeps the history).

## Needs a save with path actions unlocked

The only test save is the Cyrus autosave at ~27 min, before path actions unlock (the
objective is still "Zur Bibliothek gehen"; J does nothing there). Until there is a
later save, these are untested:

- **Path-action hint** (chime + "Path action, <name>"). It relies on the field-command
  manager's `ActiveCommandList` filling when you get close to an NPC. With path actions
  locked the list stays empty everywhere. Check: `PATHACTION available …` lines in
  `UE4SS.log` next to NPCs. If none appear, the list is not proximity-based and the hint
  needs another signal.
- **Radar during path-action bubbles.** The speech-bubble gate is verified with normal
  NPC dialogue; that path-action conversations use the same `BalloonManager` balloons
  is likely but unconfirmed. Check: `RADAR idle (talk)` while a path-action bubble is up.
- **Path-action result screens** (`FieldCommandSearch_C`, …) only mute the radar while
  they are the focused screen. They are deliberately not registered via `UIOpen`: if
  they still read as visible after closing (some widgets do), the radar would stay
  muted for good.
- **Ctrl+F9 action names** for enum values 5–8 (Guide/Allure/Inquire/Scrutinize) are
  inferred from the event class names, not observed.

## Navigation

- **Pathfinder gives up on long routes to another floor.** In the Atlasdam academy hall,
  routing to targets on the upper floor fails from most spots
  (`ROUTE fail traces≈1800 pops≈260` → "No route found"). From one spot it found a
  13-waypoint "traced route, upstairs", so the search budget looks too small for long
  multi-level routes. From a wedged corner it fails at once (`pops=1`: the start cell
  itself counts as blocked).
- **Premature "Arrived".** Seen once in the academy hall: "Routing to building, 790" was
  followed by "Arrived" one second later without getting there. The target was on the
  upper floor. Suspect: the 170-unit arrival radius in `nav_walk_watch` compares 2D
  distance to a goal on another level, or the route ends at the closest reachable cell.

## Missing read-outs (sighted players get these on screen)

- **Interaction prompts.** Standing right at a door shows "E Öffnen". Nothing tells a
  blind player that the door can be opened, or that E (not Enter) does it.

## Menus

- **"Save and load" is spoken again after confirming a load.** Picking "Ja" in "Die
  ausgewählten Spieldaten laden?" re-announces the load list just before the game
  starts loading.
