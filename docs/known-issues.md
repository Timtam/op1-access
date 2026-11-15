# Known issues

Problems noticed in existing features that are not fixed yet. Newest first. When one
gets fixed, delete its entry (the commit message keeps the history).

## Shops, inns and the tavern

Read since 2026-11-14 (9d527b9, d5c749f, 0b87f8e, 31b89bf, 2f44879, 990724e). Heard in
the game:
- the title and the money, the goods ("Heiltraube, 50 Blätter, Zur Hand 0"), the amount
  picker, the buy dialog, the shop names in the navigator (the tavern counter "Wirtshaus");
- selling ("Alte Münze, 1.500 Blätter, Zur Hand 1", then "Anzahl: 1, Gesamtwert: 1.500
  Blätter");
- the tavern keeper's menu ("Gruppe wechseln, Ausrüstung, Geschichte lauschen, Ruf
  wiederherstellen, Weiterreisen"), its equipment screen, and since bfd782e "Gruppe
  wechseln" and "Geschichte lauschen";
- in a weapon and armor shop, what the piece changes for each traveler (ebe05b3: "Cyrus:
  Phys. Angr. 78 to 85, ..."; "can't equip" for a glaive).

Open:

- **The walk to a tavern now ends at the barkeep — checked in Atlasdam only.** User
  report 2026-11-15: the walk to the "Wirtshaus" went in at the door and stopped there.
  A shop's ShopTriggerBP_C is a 40-unit box just inside the entrance; the barkeep stands
  ~520 farther in, behind the bar. A shop's target is now its keeper: the person whose
  talk event is a system one (PlacementData.EventLabel "SC_SYS_BA0_*" for a tavern's
  barkeep, "SC_SYS_SH0_*" for a shopkeeper), nearest to the trigger. Heard: door opened,
  "Arrived" beside the "Wirtshaus-Wirt", his talk hint up. The inn, the armorer and the
  merchants of Atlasdam have no such person: their trigger is the counter and says "<name>,
  E" there, so they keep the trigger (the walk to the Gasthaus ended at "Gasthaus, E").
  Other towns' shops weren't checked; a shop with a keeper "SC_SYS_SH0" wasn't seen.
- **Opening "Geschichte lauschen" stalls the game once for ~80 ms** ("FAST polls slow:
  [tavern=80]"), each time it opens. The reader's own part takes under 20 ms; a "TAVERN
  story read" line breaks it down when it is slow.
- **The story select when you enter a town** (where a traveler's chapter can begin) is
  the same screen, but wasn't seen there. Party change with more than one traveler (the
  waiting ones, "chosen") wasn't tried: Cyrus is alone.
- **Buying equipment**: the question to equip what you bought wasn't seen (nothing was
  bought).
- **What the inn says after "Bleiben"** wasn't seen.
- The currency word for the ⑳ sign ("3.246 Blätter" heard). The game has no word for
  it, so the mod picks one by the game's text language. Where the words come from:
  - German "Blätter": the user's choice.
  - French: the game's own text.
  - Japanese and Korean: Tressa's skill name.
  - Spanish, Italian and Chinese: guesses.

## Game over

Read since 2026-11-14 (8e180e2) from the object dump and a screenshot of the screen
("Weiter ab letztem Speicherpunkt", "Zum Titelbildschirm"), but **not heard in the game
yet**: there was no second defeat in the test. The "GAMEOVER items=[...]" log line shows
what it found.

## World map, route finder and danger levels

Since 2026-11-14 (ac9584a, a053db5, e6b92ef, 0442d86), tested from the user's save in the
Östliche Atlasdamm-Ebenen after Cyrus' chapter 1 (11 places): Page Up/Down moved the
cursor to Atlasdamm and Enter offered the fast travel; the route to Kammbruch (9 areas) and
"on the way to Kammbruch" at the right exit. Since 2026-11-15 (bfe7faa) Home and End go
through the eight regions with all 147 places. Tested from the academy autosave:
Flachland 16 places, Küstenland and Frostland 19 each, back to the shown places. A route
to a place not discovered yet also worked (Der Pfeifende Wald, 3 areas). Open:

- **A region's places are ordered by distance**, not by the roads between them.
- (Ctrl+Backspace closed the map only in tests: the key guard lets synthetic keys
  through on purpose, `LLKHF_INJECTED`, so the game saw the test's Backspace. A real key
  press is swallowed.)

- **The route ignores story locks.** It is the fewest exits by the level files
  (`Scripts/worldlinks.lua`); an exit the story still keeps shut (LevelTriggerTable flags)
  counts as open, and an exit whose destination the level file doesn't store wasn't
  found. Only one route was checked, and not walked.
- **The route goal is forgotten** when the game restarts (pick it again on the map).
- **Distances are map units** (Kammbruch "west, 947" from the flats by Atlasdam).
- **Which number is "the" level.** Exits, the banner and the map say DangerLevel of the
  encounter entry for the story progress (1/4/7/11 in the flats by Atlasdam over
  progress 0-4; progress 1 now). The banner itself shows DisplayLevel as icons (1-2
  there). The banner logs the encounter manager's own DangerLevel/EncounterLevel
  ("AREA encounters"), but no area was entered in the test, so they weren't compared.
- **Story destinations list all of a town's chapters**, also of travelers not in the
  party: Kammbruch said "Tressa, chapter 2; Cyrus, chapter 2" with Cyrus alone.
  `DestinationFlag` is set on every unvisited town, not only on the next goal.
- **Marker type 7** (seen at an NPC on the flats, 2026-11-14) is read as "marker type 7".

## Installer and updates

Since 2026-11-14 (92e6dc0 and the installer commits): the release ZIP, the installer and
the update check with F5 (see docs/build-and-release.md). Not yet checked:

- **No GitHub repository yet**, so no release exists: the CI and release workflows have
  never run, and the installer never downloaded a real package. `build-release.ps1`
  built the ZIP and the installer locally. The mod's side (check, announcement, F5
  twice, installer command line, fallback to the release page, 404 and network errors)
  passed outside the game with a stand-in repository and a stand-in installer. Against a
  fake game folder, the silent install, update (own sounds, `mods.txt` lines and other
  mods stay), another UE4SS build, a running game, detect and both uninstalls passed, as
  did the relaunch from `%TEMP%`. The window opened and closed; `--update --zip`
  installed and asked to start the game.
- **Not tried in the game:** the check at load, F5 and the close after 1.5 s
  (`shim.CloseGame` posts `WM_CLOSE` to the game window; quitting via
  `CloseMainWindow` in tests worked the same way).
- **The installer window** (focus, live region, message boxes) wasn't tried with a
  screen reader.

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
- **Damage numbers** are read since 2026-11-14 (8aad812), together with healing and
  shield changes: "Eissentinel 55 weak, Eissentinel broken", "Cyrus 26", "Cyrus +500
  HP", "Eissentinel recovers, shield 1". Checked against one enemy. Not yet heard: SP
  and BP recovery, misses ("miss"), criticals (their DamageType is unknown: only
  0/3/4/5 were seen, 3 and 5 say "weak").
- **Not read at all:** what a boosted command does, and the boost help.
- **Who acts is guessed for several enemies** (0e0e5d7). An action right after your
  own input is your character's; otherwise it is the only enemy's, or the one whose
  turn-order icon fades (IsFade, seen once). Not tried with two or more enemies or
  with more party members. Battle-start messages get no name.
- **Keys 0-9** in OT's own controls were not checked; no side effect showed in about
  10 fights. Q (lower the boost) no longer reads the objective in battle.
- **H'aanit's beasts and the capture** (new game, 2026-11-15). A called beast's attack
  is said with the beast's name ("Linde: Anspringen", before it came out as the enemy's),
  the capture message has no name in front, and the result line says the money in the
  game's language ("Victory. 20 Blätter"). The capture picks its target without a target
  cursor; the enemy whose success rate shows ("Erfolgschance 60 %") now counts as the
  target and its line includes the rate. Heard for stealing in battle (Therion,
  2026-11-15): "Flach-Froggen I, shield 1, weak to Licht, 2 unknown, Erfolgschance 5 %",
  then "Therion: Stehlen", "Ihr konntet nichts stehlen ...". Not heard for H'aanit's
  capture yet.
- **Item drops and knock-outs heard** (2026-11-15): "Victory. 24 Blätter, 4 EXP, 4 JP.
  Items: Anregende Pflaume 1". A party member going down is said with the damage line
  since 744e09a ("Olberic 4, Olberic down"); "back up" after a revival wasn't seen.

## Walker (user report 2026-11-14)

- **The first step of a route on the shifted grid can bump.** Since 2026-11-14
  (bc28ced) a failed search runs again on a grid shifted by half a cell, and the walk
  then goes from where you stand to that grid's start first. Twice that first waypoint
  was skipped after a short bump ("wp 2 skipped at 52 (no closer)"); the walk went on
  both times. The shifted start only needs a clear centre line, not the full body
  width.
- **Freeing itself works, but no real wedge was found to try it on.** When a re-route
  fails, or a first route dies at the start (<= 3 cells), the walker takes up to 3
  steps into open directions, each with a new route ("Trying another way"), before
  "Step aside" (0fa43cb). Forced once with a test flag: three diagonal steps and a new
  route from each new spot. A real corner (walls at 30 up and left) did not box the
  router in at all, so it was not needed there.
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
  guards, a building upstairs) ran clean. Counting a waypoint as reached once the
  walker is past it (f5d23e7) works: in about 45 walks since, no waypoint was skipped
  for "no closer" (before: 2 in a handful). Not checked yet:
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
- **"Leaving the building first" outside a house — FIXED 2026-11-15.** After Therion's
  intro, outside the pub in lower Felsfall, the walker said
  "Leaving the building first" and led to the door of another house 1100 away. That
  house's doorway box sits 10 units OUTSIDE its door, so the street in front counted as
  its inside. Now the inner side comes from the room's own parts (their mean, when it is
  150 or more off the doorway), and "you are in this house" from the game's own flag
  `HouseEnterTriggerBP_C.IsHouseEnter` (+0x4B2). Checked: false at every door outside
  (the walk went straight on), true inside a house in Felsfall ("Leaving the building
  first. Routing to its door, 406"), false again in the doorway, then on to the exit.
- **Narrow stairs — FIXED 2026-11-15, one town checked.** Lower Felsfall's long stairs up
  to Felsfall are about 118 wide between their walls (wall tick: right 30, left 88). The
  router needs a corridor 84 wide around a cell centre and cells are 130 apart, so only
  a 34-wide strip of centres fits; neither the grid nor the half-shifted one hit it, and
  the exit was "not reachable". Now a straight step whose centre line is clear may slide
  its corridor sideways by 22 or 44 (with a side step first when it enters from open
  ground); slid steps the player's own collision profile calls blocked are left out.
  In a mock test passages 118 wide are found at any offset (56-65 by the shifted grid),
  a 70-wide gap stays shut, an open street is unchanged. In the game: pub -> exit up
  (planned in 0.8 s, walked 5460 in one go), the stairs down and up again. Routes near
  walls now cost more traces (3500-7000 instead of 1500-3500 here; still under 1 s).
  Not checked in other towns or dungeons yet.
- **People in the way — FIXED 2026-11-15, a few walks checked.** The router's traces
  don't see people (only the player's own collision profile does), so routes went right
  through them and the walk bumped; in lower Felsfall the Armer stands in House_A's
  doorway, in Felsfall an old man in another house's door. Now walks and directions keep
  70 from everyone in the area except the person walked to. When that leaves no way, the
  same search runs without people, and if that finds one the walk names who is in the
  way. A way to a door also checks its last step. Heard: "Armer is in the way" (to the
  villager in House_A and to its door), "Alter Mann is in the way" (Felsfall). Walks with
  2 and 13 people around (pub -> Felsfall, across Felsfall to the Ravus gate, to the
  Alte Frau) ran clean. Open:
  - People who walk around are taken where they stood at the start; a walk that bumps
    into one routes again from the new positions.
  - The list's background check leaves people out (they move), so a target behind
    someone still says nothing until you walk.
  - Such doors are probably shut by design: nothing tells whether the person ever
    moves.
- **The side step in front of a person is untested.** When stepping straight toward
  a person behind a counter gets no closer, every other try steps sideways to stand
  square in front (Mercedes is picked at 161 with 26 to the side, not at 166 with 48).
  In 6 walks to people the route already ended in front of them, and the talk range was
  reached each time without it.

## Path actions

All eight were tried in the game on 2026-11-15 (e46c615). A test session put the other
travelers into the party in memory, without saving: the party lists in
`KSSaveGameBP_C.PlayerParty` were set while still in the flats, then fast travel to
Atlasdamm made the game set up the new party's path actions. Heard: the hint ("Path
action, Wache: Studieren; Kaufen; Stehlen; Herausfordern"), the J menu, Purchase and
Steal (list, item, price or chance, description, question, cancel), the questions of
Challenge, Provoke, Guide and Allure with the person's panel ("Wache. Stärke 4 of 10.
Fertigkeiten: Verteidigungshaltung. Rufbereit 9"), a successful Guide and Allure, a
failed Allure, the question to swap followers ("Now: … New: …") and Inquire's result.
Open:

- **Tried in new games (2026-11-15):** H'aanit (Provoke with its battle, the beasts list
  in battle "Waldfuchs, 5 left", the capture question and a capture), Tressa (a real
  purchase: "Flasche mit Wein, 50 Blätter, bought") and Therion (a real theft:
  "Händler. Feuerseelenstein. Erfolgschance: 100 %. Diebstahl versuchen?", then
  "Feuerseelenstein, Erfolgsrate 100 %, stolen"). Each new game needs its intro pressed
  through (5-8 minutes of Enter).
- **Tried with a test party in Atlasdam (2026-11-15):** a failed theft (Therion at level
  3: "Lebhafter Ohrring, Erfolgsrate 15 %", the question with "(Euer Ruf in dieser Stadt
  wird sich verschlechtern, wenn dies misslingt.)", then "Wache: Heda! Was glaubt Ihr, wo
  Ihr hier seid?!" and the tutorial about the town's reputation), and Olberic's duel
  against a guard ("Wache. Stärke 4 of 10. Diese Person zu einem Duell herausfordern?",
  the whole fight read). Olberic lost; the mod says no "lost" of its own, the game's line
  "Olberic: ... Ein bedauerliches Resultat." tells it.
- **Not tried:** the haggling message "Erfolgreich gefeilscht", releasing a beast,
  parting from a follower, and the follower's own entries in the J menu.
- **The balloon's cross ("not possible")** showed for the tavern keeper's Scrutinize and
  for a child's Provoke, Guide and Allure. A level lock shows nothing: Olberic's
  Challenge only said "Ihr müsst mindestens Stufe 7 erreicht haben …" when tried.
- **Opening a path-action list stalls ~80 ms once** (`[fcscreens=88]`), like the tavern's
  story select.
- **Inquire's header "Alfyn: Erkundigen" isn't said**; its result is read like
  Scrutinize's.
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

## Threads

- **A few ExecuteWithDelay callbacks still call game functions off the game thread**
  (title screen: the char-select anchors and announce, the talk-hook install). Since
  2026-11-14, everything else runs on the game thread:
  - work queued for it (11c8ce1); UE4SS 3.0.1 ran that inside whichever thread called a
    UFunction next, and it crashed the game once in the learn-skill dialog;
  - the key binds (8cda17b);
  - the screen polls (8ed1351), now that they no longer walk every object each tick.

  On the game thread a slow run stalls the game, so a run over 20 ms is logged ("FAST
  polls slow: 55 ms [active=55]"). From boot to a loaded save there were 3: the
  UI-manager search at boot, and one search when the load dialog opened. Work another
  thread still takes is logged as "GT: queued work on a foreign thread"; none happened
  after the polls moved.
  Opening the main menu stalled the game for 75-86 ms every time: the objective reader
  searched all objects. Since c4502cc the search runs once per session (the list it
  found is kept); later openings had no `[mainmenu]` slow run. Still slow once per
  opening: the world map (~125 ms, building all 147 places), a dialog over the map
  (~90 ms `[active]`) and the tavern's story select (~80 ms).
- **UE4SS's c0000264 crash happened once in the middle of play** (2026-11-15, after
  leaving a shop, on the End key; dump `build/user-logs/crash-20261115-130952.dmp`).
  Same signature as the known exit crash: `RtlLeaveCriticalSection` on a lock the thread
  doesn't own, under `HookUStructLink` and nested Lua calls, no shim frames. Since
  05ce7cc the screen polls call GetActiveStack once per run instead of up to 15 times.
- **The game hung once after a won battle** (2026-11-15, H'aanit's new game; dump and
  stacks in `build/user-logs/hang-20261115-1459*`). The game thread waited in
  `RtlEnterCriticalSection` under UE4SS's `process_lua_function`; the lock's
  RecursionCount was -2 and its owner a thread that was asleep. That is the same UE4SS
  lock bookkeeping as the c0000264 crash (one Leave too many), here as a deadlock. No
  shim frames; nothing in the mod can repair the lock. Seen once; the game had to be
  killed.
- **Q says "No objective" until the menu was opened once.** The objective comes from
  the menu's party panel (`PartyCharacterList_C.NowPlayingStoryPanel`), which is filled
  when the menu opens. After a load, Q in the field had nothing to read; after opening
  and closing the menu it read "Objective: Zum unterirdischen Studierzimmer gehen."
  The game picks it from /Game/Mission/Database/NextPurposeData by story flags
  (IsEventFlagCheck, ShowStartFlag/ShowEndFlag); reading those flags from Lua would mean
  calling Blueprint functions with out parameters, which crashed before. Between
  chapters there is no objective at all (Slot 1 after Cyrus' chapter 1).

## Menus

- **Key names in tutorials: one heard.** Since e41f695 the circled letters the game uses
  for keys ("Drückt die Ⓞ-Taste", "Ⓙ drücken", "ⒶⒹ") are said as plain letters. Heard in
  the radar tutorial: "Drückt die O-Taste, um das Radar ein- und auszuschalten". Other
  key signs (⑤, ⑥ in the battle's boost help, probably gamepad buttons) are left as they
  are.
- **The radar has no map to read.** Sighted players mentioned a town minimap with the
  walkable paths. Octopath Traveler II has one; this game's radar is a cloudy circle with
  icons only (checked on screenshots and in the game files). A minimap with a top-down
  camera and a "road" material exists in the files (/Game/UI/MiniMap), but no level uses
  it. Where you can walk is only in each level's collision (a combined collision mesh
  and BlockingVolume actors), which the walker's traces already see.
- **Inventory and abilities: only one traveler and no purchase checked.** Read since
  2026-11-14 (e0d8fd5), tested with Cyrus alone (Slot 1):
  - Inventory: tabs, rows with count and description, greyed items, and whom an item is
    for.
  - Abilities: the job, LBP and next price, the support-skill rows, each skill with
    cost and description, learned and locked skills.
  - The learn dialog with its LBP lines; it was always cancelled.

  Not seen yet:
  - Learning a skill ("Ja"); the row should then say "learned".
  - An item for several travelers or for all of them.
  - "Hilfsfertigkeiten ausrüsten" (still locked).
  - A secondary job's list (the "sub" path).
- **Equipment: only browsed, nothing equipped.** Read since 2026-11-14 (ef1a374) with
  Cyrus: slots with the worn piece and its bonuses, items with what they would change
  ("Phys. Vert. 82 to 103 …") and "equipped" for the worn one. Not tried:
  - Equipping (Enter on an item); the slot row should then name the new piece.
  - "Optimieren" and "Alles ablegen".
  - Accessories with a special effect.
  - Several travelers (the tab should say "Olberic, tab 2 of 4").
  - A greyed category's "can't equip": the cursor skips those rows.
- **Menus inside events: only the known ones are read.** The save point's screen
  ("Save", "Slot 1, empty", "An ausgewähltem Speicherplatz abspeichern? Nein") is read by
  `M.poll_event_menus` on the game thread while an event is up. The tavern keeper's menu
  also runs inside his talk event; it and its screens (equipment, party change, story
  select) are read by the normal screen polls, which run in events too. Other screens a
  game event might open are not known yet; if one stays silent, check its class in the
  "EVENT screen:" log line.

## Navigation

- **Chests: opened or not is said, the purple ones are not told apart.** Since
  2026-11-14 (252661f) the list says "opened" and the category counts them, from the
  chest's own IsOpenFlag; checked in the study, with Slot 1 (all open), the older
  autosave (none) and one chest opened in between. Opened chests still sort by
  distance and still ring in the radar. Purple (thief) chests, which need a certain
  traveler, aren't named: the chest's ObjectType was 1 or 2 in the study, meaning
  unknown (logged as "CHESTS opened/type").
- **"Not reachable" can still be wrong for very long detours.** The router searches
  the start/goal rectangle plus 9 cells. When that runs out of cells (or, since
  bc28ced, of traces) it searches once more with 20 cells (~2600 units) and 6000 more
  traces. With native traces it then tries a third time with 40 cells (~5200 units) and
  20000 more (since 2026-11-14), and last on a grid shifted by half a cell. A passage
  150-210 wide is open on some grid alignments only; the shift made chest 1 in the
  study reachable from the save point.
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
  Since 2026-11-15 (c62c659) the inner side of a doorway comes from the room's parts
  when they lie clearly on one side, and whether YOU are in a house comes from the
  game's own flag (IsHouseEnter), see the walker section.
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
  first"), and "Still shut. Öffnen, E, then backspace again" at a door leg. A search
  that dies at the start (`pops <= 3`, seen once in the academy) now makes the walker
  step free and try again (0fa43cb); a plain corner did not cause it.
