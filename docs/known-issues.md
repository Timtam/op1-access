# Known issues

Problems noticed in existing features that are not fixed yet. Newest first. When one
gets fixed, delete its entry (the commit message keeps the history).

## Speech and languages

- **English was heard only in a short session.** Since 7d483f2 the mod's own words follow
  the game's text language (Scripts/lang/<language>.po, docs/translations.md); de.po
  covers all 414 texts and a whole German session logged no "I18N missing" line. Since
  59f846a the language comes from the game's own setting (KSGameStatics:GetLanguage); a
  switch in the options is followed within 2-5 s (title options to English, field menu
  options back to German, 2026-11-16). Heard in English: the title and load menus, the
  navigator, the main menu and its lists (also the tutorials), the world map, a shop
  ("Provisioner, 3,756 leaves", "Healing Grape, 50 leaves, On Hand 0"), Kit's side-story
  dialogue, the character select, one battle and the game over. Not heard in English:
  the tavern, path-action screens, event menus. Other languages say English until
  someone adds a .po.
- **Some German words are guesses at the game's own terms**: "Speer" for the polearm
  weakness (the user says "Lanze"), "EXP" and "JP" in the battle result, "HP", "SP" and
  "BP" kept as they are, "Wege-Aktion" from the tutorials. Each is one line in de.po.
- **The speech history keeps the dialogue lines from the pump's PollTalk**: two lines
  within one pump would keep only the last (the shim keeps one line; lines come a key
  press apart, so it wasn't seen). Navigator and menu lines were checked by ear (comma,
  period, Shift+comma, Shift+period); dialogue lines are in the list (a dump after
  Kit's dialogue, 2026-11-16) but weren't listened to through the keys. A line said
  twice in a row is kept once.

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
- **Equipping what you just bought: built, not heard yet.** After buying a weapon or armor
  the game asks "Quarzrute sofort ausrüsten?" (read as a dialog, heard 2026-11-16). After
  "Ja" you choose who gets it on the party panels; that stayed silent (user report). Since
  then the shop's own state is read (GetCurrentState; ESHOPMENU_STATE 10 = the question,
  11 = the choice, names from the game's enum asset, their order checked against the shop
  commands' enum). In state 11 the shop says "Wer soll es ausrüsten?" and the traveler
  under the cursor with what the piece changes for them ("Cyrus: Phys. Angr. 83 auf 94,
  ...", or "kann nicht ausrüsten"), then each traveler you move to; the goods list keeps
  quiet meanwhile and says its row again after. The cursor: the party panel whose
  CursorIcon shows, else QcEqp_CursorPos. Check the log's `SHOP state ... state=11` and
  `SHOP quick equip` lines if it stays silent (the state number is the likely suspect).
  Not seen yet: what the game does after the choice when you bought two.
- **What the inn says after "Bleiben"** wasn't seen.
- The currency word for the ⑳ sign ("3.246 Blätter" heard). The game has no word for
  it, so the mod picks one by the game's text language. Where the words come from:
  - German "Blätter": the user's choice.
  - French: the game's own text.
  - Japanese and Korean: Tressa's skill name.
  - Spanish, Italian and Chinese: guesses.

## Game over

Read since 2026-11-14 (8e180e2) from the object dump and a screenshot of the screen.
Heard on 2026-11-15 (Cyrus alone lost a battle on the flats): "Cyrus down", "Game over",
"Weiter ab letztem Speicherpunkt", Down "Zum Titelbildschirm". Loading a save from the
title after that crashed the game every time until 2b0e87f (kept title widgets touched
after the load freed them); five runs since loaded fine (English and German, the last
with every kept object guarded), the radar idle on the title (0212d98). Since 9d9c1ab
and ec3456c a load says the area and "N Objekte hier" again even at the place you were
("Return to Title" and the same save: was silence), and "Weiter ab letztem
Speicherpunkt" says the object count (a jump to the save point, no banner, so no area).
Since bb11e65 the radar stays idle between "Ja" and the load's fade; since f1ce369 the
area banner waits 2.5 s after a battle and the game over screen marks its text said.

- **A dialog over the world map is untested since dc28732.** After "No" to the fast-travel
  question the menu no longer says "World Map" while the map is still open (review
  finding); the saves had no other town to travel to, so it wasn't heard.
- **The area banner can't tell whether it is on screen.** Its widget keeps Visibility 0
  and IsOpenKeep set after the banner faded (checked against a screenshot), so the mod
  goes by the text changing. A banner shown as a battle began is said up to 2.5 s after
  the battle (f1ce369); the case that put "Atlasdam, Flatlands" between the game over
  items didn't recur in the test after the fix.

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
- **Fast travel on the way: in a unit test only.** Since this change Ctrl+Backspace
  checks the user's wish of 2026-11-17: fast travel to the town nearest the target, then
  walk. The candidates are visited towns: the map icon is not IsUnreached, and
  the place is an eMAP_T_ row with CanFastTravel. The cooked WorldMapTable has the
  flag on all 24 towns and on one path, eMAP_F_Mount_3_2, which is left out. Of
  those, the one with the fewest areas to the target is used if that is fewer than
  from where you stand: "Route nach X: Schnellreise nach T, dann 2 Gebiete: …".
  A visited town as the target: "X: per Schnellreise erreichbar". Ctrl+Backspace
  again within a minute puts the map's cursor on T ("Cursor auf T. Enter für die
  Schnellreise"). Checked on the real map (test_fasttravel.lua: the cooked tables
  and worldlinks.lua; the Maiya caves from Rippeltiden in 2 areas). Not tried in the
  game. Open: the map's own gate (WorldMap_C.FastTravelPossible @ +0x8EB,
  FastTravelRestriction @ +0x920; per the Blueprint, a follower or the scenario can
  forbid fast travel) is only logged (`ROUTE fast travel: …`), not yet said. Where a
  fast travel arrives in a town with several parts is not known: the count starts
  from the town's nearest part.

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
against one Eissentinel in the study dungeon. Weaknesses in the game's tile order
(1c473c0) heard on the flats: "weak to Bogen, 2 unknown", then "weak to Bogen, Eis,
1 unknown". Not yet seen or checked:

- **More than five weaknesses.** The panel has five tiles; an enemy with more is logged
  ("WEAK"). Not seen.
- **Locked weaknesses: in a unit test only.** A boss that calls helpers has its
  weaknesses locked until they are gone (user, 2026-11-17). The tile's WeakLocked flag
  (WeakStatusIcon_C +0x28A) is the game's own. The cooked Blueprint's bytecode sets it in
  SetAttributeIcon(Icon, Lock, Opened, Index) when a tile is made and in
  SetWeakLock(Lock), which plays the Lock or UnLock animation. Keys 1-5 and the target
  cursor said "Schwert blockiert" per tile before; all tiles locked now come out as
  "Schwächen: Schwert, 2 unbekannt, alle blockiert". Since this change the battle poll
  also watches it (every 0.5 s). A change is said with the damage line ("Mikk:
  Schwächen blockiert", "Mikk: Schwächen wieder frei"), and a boss locked from the
  start gets it in the line that names the enemies ("Kampf: Mikk, Schwächen
  blockiert"). Checked against mock panels (test_weaklock.lua). Not seen in a real
  fight yet; log `WEAK lock <name>: <n> of <m> tiles`.
- **Several enemies or party members.** Enemies are numbered in the order of their
  panels (widget order), the turn order lists icons in widget order. Whether both match
  the screen's left-to-right order needs a fight with more than one enemy; four random
  encounters on the flats by Atlasdam (2026-11-16) were all single enemies. Party keys
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
- **Not read at all:** what a boosted command does. The boost help itself
  (BattleCommandBoostHelp_C) only holds the word "Boost" and the key hints O / Q, which
  the mod already knows (object dump, 2026-11-16); there is nothing more in it to read.
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
- **Two level-ups in one battle: in a unit test only.** The user heard only the last one
  (2026-11-17). No saved log ever had two level-ups in one battle. The result
  screen's level-up flag (PlayLevelUp) was only looked at from 1.5 s on. A level-up
  that played earlier was gone by then, if the flag is only up while that character's
  level-up plays (the timing in the logs suggests so). Now level-ups are gathered from the
  first poll on, and a level that rose since the screen opened counts too. A second level
  in one battle is said as well. Checked against a mock result screen
  (test_results.lua: the old code says only the last one there). Not yet heard in the
  game. Every change of a traveler's level or flag on that screen is now logged (`BT
  result 0.3 s: Tressa level 4, level-up true, counting true`), so the next fight with
  two level-ups shows what the game really does.

## Walker (user report 2026-11-14)

- **An arrow stuck after a battle — fixed 2026-11-16, not yet seen in the game.** A random
  encounter stopped a walk ("Walk stopped" as the battle began). The walker let go of "up"
  then, but the game missed that release: after the battle the character walked off alone
  (the pawn's input stayed 1.00) and pushed into a corner, and each new walk said "Walk
  interrupted" a second in, because its "down" against the stuck "up" made no input. Now
  each arrow let go as a battle, a scene, a menu or a fade takes over gets a second
  key-up 0.3 s after the field is back and once more a second later (`NAVWALK key-up
  again` in the log, with the input before it), and a walk without input first lets go
  of the arrows it doesn't hold before it gives up. Mock tests pass (19). Not seen yet:
  a walk into a battle with the new code — the log line should show input 1.00 at the
  first key-up and the character should stand still after the battle. Pressing the stuck
  arrow once also frees it.
- **A chest below an invisible ledge — fixed 2026-11-16, not yet seen in the game.** In the
  North Atlasdam Flats a chest stands a step below a grassy ledge, next to a big rock. From
  above every route took a short "soft" step through the ledge's invisible wall (channel 0
  doesn't see it, the pawn trace does, and such a step cost only 8); the walk got stuck
  about 300 short and planned the same way again, although a way round from below exists
  (found once, 21 cells, before a battle cut it short). Now a walk that gets stuck with the
  pawn trace hitting straight ahead learns a wall 200 long across its way for the area
  (`NAVWALK learned a wall` in the log). No route, straight walk, background check or
  escape step crosses it again, and soft steps cost 30 there after that (not within 250 of
  the target, where its own collision makes them soft). In the mock router a long invisible
  ledge is crossed by a soft step at first and gone round after one learned spot. Not seen
  yet: the walk to that chest should get stuck once, learn the wall and go round.
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

## When the radar comes back

- **After a battle: tried in the game (2026-11-17, Maiya caves).** In a battle the input
  is away from the character all along: 0/0 during actions, 1/0 (MODE_UI) in the
  command menus. It comes back (0/1) in the same moment the battle mode ends. The radar
  came back 0.4 s after the battle ended (before: about 2 s). One bug showed and is
  fixed: the radar went down again for a second right after, because the "the event
  took the input away" mark was cleared when it came back. It is now cleared when the
  next event starts. A load: the controller is new (nil) until the field is there, and
  the radar comes 0.5 s after the character appears, as before. Dialogues and story
  scenes are still to be seen in a log.
- **After a scene: built, not yet tried in the game.** The user (2026-11-17) could press J
  or E again well before the radar came back after a dialogue. In the logs the radar
  came back about 2 s after a battle ended or a menu inside an event closed. The radar
  waited 1.5 s after the game's event flag (IsEventPlaying, IsEventPlayTheater or the
  battle mode) went off, because between two chained events the flag can drop for a
  moment. Its object rescan came 0.3 s after that. The player controller knows whom
  the input goes to (KSPlayerController InputMode @ +0x6C0: 0 MODE_CHARA, 1 MODE_UI, the
  names from the exe; IsPlayerCharacterInput @ +0x6C1), read raw. Now, when an event
  took the input away from the character and it has been back for 0.25 s, the radar
  waits only 0.25 s (M.ev_hold, test_evhold.lua). A controller that never changes, or
  can't be read, keeps the old 1.5 s. Not known yet: whether the input really leaves
  the character in dialogues, scenes and battles; whether it comes back before the
  event flag goes off (then the event flag is the late one); whether it ever comes back
  between two chained events. The new log lines answer all three: `STATE <seconds>
  event …, theater …, battle …, fade …, settling …, input <mode>/<flag>` on every change,
  `RADAR resumed <s> (event off … s ago, wait … s, input with the character … s)`, and
  `STATE … moved … while the radar waited` when you walked before it came back. Other
  signals seen in the dump, not used yet: EventManager.TheaterStatus (EEventTheater:
  NONE, UPDATE, RESTORE, FINISH_PRE, FINISH), EventManagerBP_C's talk blur timers
  (TalkPostTimerNow/Finish), KSGameStatics GetMainMenuEnable / IsFadeEnd.

## Threads

- **Only the talk-hook install still runs off the game thread** (at start, every 2 s
  until armed): it looks up two UFunctions (StaticFindObject) and hands their addresses
  to the shim, no game function is called. Since 74be657 the character select's delayed
  reads (its announce, the cursor, "blocked", the traveler learning) run on the game
  thread too. Since 2026-11-14 everything else does:
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
  found is kept); later openings had no `[mainmenu]` slow run. Every Yes/No question in
  a menu stalled 80-130 ms (`[active]`, the learn dialog's parts searched each time)
  until 40a66e6. Still slow once per opening: the world map (~125 ms, building all 147
  places) and the tavern's story select (~80 ms).
- **UE4SS's c0000264 crash happened once in the middle of play** (2026-11-15, after
  leaving a shop, on the End key; dump `build/user-logs/crash-20261115-130952.dmp`).
  Same signature as the known exit crash: `RtlLeaveCriticalSection` on a lock the thread
  doesn't own, under `HookUStructLink` and nested Lua calls, no shim frames. Since
  05ce7cc the screen polls call GetActiveStack once per run instead of up to 15 times.
- **On arrival the radar stalls the game ~390 ms, after a dialogue ~150 ms.** Each object
  search walks all objects (~78 ms): on arrival all five (chests, exits, doors, shops,
  people). Since 4d88542 a dialogue without a fade keeps the exits, doors and shops
  ("FINDALL 3 fixed lists kept through the scene"), so only chests and people are
  searched again (a scene can move people, a reward can be a new chest). Category
  presses take 0-2 ms (d1f4b25).
- **The game hung once after a won battle** (2026-11-15, H'aanit's new game; dump and
  stacks in `build/user-logs/hang-20261115-1459*`). The game thread waited in
  `RtlEnterCriticalSection` under UE4SS's `process_lua_function`; the lock's
  RecursionCount was -2 and its owner a thread that was asleep. That is the same UE4SS
  lock bookkeeping as the c0000264 crash (one Leave too many), here as a deadlock. No
  shim frames; nothing in the mod can repair the lock. Seen once; the game had to be
  killed.
- **The objective with several travelers was not heard.** Since f4c904f Q and the menu
  take the objective from the story flags (NextPurposeData, KSSaveGame:GetBitFlag), for
  each main party member, leader first, with the traveler's name when several have one
  ("Cyrus: ..."). Tried with Cyrus alone (academy autosave, Slot 1 between chapters,
  both through "Return to Title"). The names are a fixed list (Olberic ... Alfyn), the
  same in German and English.

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

  Since 9d2ebb7 "learned" comes from the row's check mark (RefImg_Strikethrough): with
  too few LBP every skill is greyed, and greyed used to be said "learned" ("Analyse,
  erlernt" at 33 of 100 LBP). Learning tried with 500 LBP set in memory (2026-11-16):
  "Analyse. LBP-Kosten: 100, Aktuelle LBP: 500. Diese Fertigkeit erlernen?", "Ja", the
  game's "Ausweichmanöver. Ihr habt eine neue Hilfsfertigkeit erlernt!", its tutorial,
  then "Analyse, erlernt". In battle the new Analyse revealed a weakness, said in its
  place: "Schwächen: 1 unbekannt, Stab, Dunkelheit".

  Not seen yet:
  - An item for several travelers or for all of them.
  - A secondary job's list (the "sub" path).
- **Support skills: one learned skill, two travelers.** "Hilfsfertigkeiten ausrüsten" is
  read since 2026-11-16 (the user: "the menu is open now and not read"), tried in game
  with Cyrus (Ausweichmanöver) and Ophilia (none learned): the traveler with the four
  slots ("Ausgerüstete Hilfsfertigkeiten: Ausweichmanöver, 3 Plätze frei"), each slot
  with its description and "L: Entfernen", the learned list with descriptions,
  equipping ("Platz 2 von 4. Ausweichmanöver, ausgerüstet" -- the game moves on to the
  next free slot) and taking one off. Not seen yet: a skill that changes a stat (the
  table's "Max. GP 384 to 422" is read after the description), several jobs' skills in
  the list (a secondary job), all four slots full.
- **Equipment: only browsed, nothing equipped.** Read since 2026-11-14 (ef1a374) with
  Cyrus: slots with the worn piece and its bonuses, items with what they would change
  ("Phys. Vert. 82 to 103 …") and "equipped" for the worn one (a row dump confirmed: the
  worn piece is the greyed row, "Stab, 1, ausgerüstet"; Cyrus has no second staff, so
  equipping another piece couldn't be tried). Not tried:
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

- **A save point is no person: in a unit test only.** A save point's book is an NPC in
  the game (its talk is the save menu). Before, saving there made the mod take it as a
  talkable person: it joined the people list and the radar rang for it (user,
  2026-11-17, the Maiya path). Now a person kept only by a talk, with no lines of its own,
  is checked once. Every save point in the saved logs has NPCUniqID 830 (text label
  CN_NP_SYS_000000_0000), or else its talk event is SC_SYS_SA0, and either way it stays
  out of the people and the radar (log `NPC omit: ... (save point)`). It is still in the
  marker list as the save point. Two other kinds of mute "system" people show in the
  logs, unknown what they are: ID 831 (CN_NP_SYS_000000_0010, in towns) and 912
  (…_0020, in dungeons). They still count as people once talked to.
- **The Flammhuld inn: the way in goes round the side. Built, not walked by the walker
  yet.** (2026-11-16) The inn stands on a stone base, its door on a landing 96 over the
  street (you at z 286, on the landing 382; the trigger at (-1140,-1510,415)). In front
  of the base three people stand in a row at x=-1314 (y -1532 "???", -1412 a child,
  -1298 a woman), 115-120 apart: no way between them (tried: stuck with two at 80). The
  way in, found by hand after a sighted check: round the base's left end (y < -1690), then
  right along stairs behind the base onto the landing; "Gasthaus, E" came at
  (-1180,-1608).
  - The walker said "Arrived" 152 away beside the base and went straight at it. Channel 0
    sees neither the base nor the stairs nor the landing (CHPROBE "up ch0=- ch1=28
    prof=28"), so floors and routes took it all for street, and the search took the start
    for the goal (within one cell). The floor check (c38e2eb, below) didn't help for the
    same reason.
  - Since 43c6784 a shop without a keeper (its trigger is the target) is reached only at
    its prompt, also on the way; at the end of the route the walker pushes on to the
    trigger for 2 s. Stuck within 250 of it or no prompt: "Eingang nicht erreicht, dort
    stehen 2 Personen" (people within 220 of the trigger; the follower, a ResidentGame
    actor, doesn't count).
  - Since then the route to such a shop measures floors with the character's own collision
    profile, takes what that profile hits as a wall (but people stay people), allows a
    rise over 45 between cells only on stairs, and takes a cell as the goal only when that
    profile walks in from it to the trigger at knee height (`ROUTE step-in` log lines).
    In a model of the inn (test_inn.lua) the route goes round the left end, up the stairs
    and onto the landing, from beside the base and from down the street; a person on the
    stairs is named. Not tried in the game; the cell grid (130) is coarse for the ~100-deep
    landing, so watch for "not reachable" there.
- **Targets on a terrace: built, not walked yet.** Every "same level" test took heights
  within 200-300 as one level. Since c38e2eb a target's floor counts, not its height: a
  down-trace under it (people and triggers don't block it). Floors over 100 apart are one
  level only along stairs (the floor halfway is about halfway up); a ledge is not. The
  search then looks for the way up, the walk doesn't stop below, and the lists say "höher"
  / "tiefer" for such a target. Where the trace starts inside something solid (a chest, a
  shut door) the old height rule stays. Channel 0 must see the terrace (not so at the
  Flammhuld inn, above). Checked in a unit test only (a mock street, terrace and stairs).
  Not tried: a real terrace, NPCs on steep stairs, exits on stairs. Log lines `ROUTE goal
  floor` and `NAVWALK not at the goal's level`.
- **The radar in the background: built, not heard yet.** Since 7fb543a the radar fades
  out while another window is in front and back in when the game is, the same test the
  game mutes itself by (the front window belongs to the game's process). Not yet heard
  in the game: Alt+Tab, minimizing, and the screen reader's own windows (the NVDA menu
  counts as another window too, for the game as well).
- **New markers: tried with one hidden item.** Since ea8078c the minimap's icons are
  compared every 2 s while you explore, and a new hidden item, objective, side story,
  exit toward the objective or traveler to recruit is said ("New marker: hidden item,
  right, 3872"). Tried in Atlasdam (2026-11-15, twice): Studieren on the tavern guest
  ("Ein verborgenes Objekt") made the game add the "!" at once and create its chest; the
  mod said it 2 s later and the walker led there. In Atlasdam, Studieren reveals a "new
  treasure" with three people (two tavern guests, a girl); the others give discounts or
  cheaper rooms. Not tried: a new side story, objective or traveler marker (the game
  adds them the same way), and a marker that comes up in another part of a level. Not
  said on purpose: what an area shows when you arrive, anything within 6 s of a teleport
  or level change, several icons changing at once.
- **Gone markers: in a unit test only.** On the Maiya path (2026-11-17) the objective was
  a story event's spot. A walk to the exit beside it crossed the spot, the scene played
  (Tressa brings the pirates wine), and the game took the objective's icon off the
  minimap. The marker list still had it, so the walker led to the empty spot and nothing
  happened. Since this fix an icon that is gone in two checks in a row, or at once after
  a scene, menu or battle, makes the marker list stale. The next navigator key rebuilds
  it ("Targets changed" when the selected target was the one that went). An objective,
  side story or traveler marker that goes is said ("Marker gone: objective"). Another
  target selected stays selected, and a paused walk to it goes on. Checked against a
  mock minimap (test_markergone.lua: the scene, a one-check flicker, two checks,
  teleport, level change). Not yet heard in the game. Log lines `MARKER gone:` and `NAV
  list refreshed (markers)`.
- **A picked-up hidden item stays on the minimap.** Its "!" was still there a minute
  later, so the marker list keeps it, as "hidden item, collected" (the chest's open
  flag).
- **The walker's "another side" was needed at one item only.** Since 37a2b95 it waits
  for the prompt at an unopened chest or hidden item and else tries up to three other
  sides ("No prompt here, trying another side"). Tried from behind the ledge at
  Atlasdam's hidden item (dev teleport): it went around and got "Untersuchen, E". At a
  normal chest on the flats the prompt came on arrival ("Öffnen, E", 2026-11-16). Not
  seen: a place where no side works ("No prompt at this item").
- **Side stories are named, not explained.** Since ea8078c the marker list says "Kit,
  side story" (icon type 7, seen on the flats); "traveler to recruit" (17) wasn't seen yet.
  What a side story is about is only in its dialogue.
- **Purple chests: named, but none heard yet.** Since 73ca347 a chest whose mesh wears
  the thief material says "purple" ("violett"); ObjectType 1 is the wood chest, 2 the
  plain one, 3 was seen only where purple chests are (Felsfall, the path to the
  Whisperwood). No purple chest was reachable from the test saves, so only the negative
  case is checked (the flats' two chests). "opened" (252661f) is checked in the study;
  opened chests still sort by distance and still ring in the radar.
- **The whole area is searched before "not reachable": walked once in the game.**
  (2026-11-16, user: a blind player can't first walk a bit the right way on luck until
  the walker takes over.) The router searches the start/goal rectangle plus 9 cells,
  then plus 20 (~2600 units, 6000 more traces); the third try, until then +40 cells and
  20000 traces, is now the whole area: where the level's chests, exits, doors, shops and
  people are, 12 cells round them (at least +40 round start and goal), with ~24 traces per
  cell of that box (40000 to 300000). Last comes a grid shifted by half a cell, over the
  whole area too (a passage 150-210 wide is open on some grid alignments only; the shift
  made chest 1 in the study reachable from the save point). "Not reachable" now means the
  whole area ran out of cells. Running out of traces says "Kein Weg gefunden,
  Suchgrenze erreicht" and leaves the list alone. The walk says "Suche im ganzen Gebiet"
  when the third try starts and "Suche noch den Weg" every 10 s.
  - Speed: the walk's search computes 40 ms of every 100 while you wait (8 until
    2026-11-16: the 105-cell route on the Maiya path waited 2.8 s and computed for 0.24 s
    of it), ~50000 traces a second. The picture stutters during a search; you stand
    still then anyway. In the game (2026-11-16, 22:26): the 132-cell route from the Maiya
    path's entrance to chest 3 (19023 long) came in 0.3 s, its cells traced already by the
    background check.
  - Why: on the path to the Maiya caves (Küstenland) chest 3 lay behind an invisible
    wall; the way round went through the north of the map (105 cells, 14840 long). After
    a battle 300 further along that way, every try ran out of traces (53040 in all) and
    the walk said "not reachable" twice.
  - Once a walk got stuck in an area (a learned wall), every search there takes the
    whole area at once: on the Maiya path three more bumps along the same invisible wall
    came from small boxes that held only routes through it.
  - In mock maps (test_whole.lua) a way round beyond the old +40 box is found (57000
    traces); a target with no way fails on cells after the shifted grid (190000 traces,
    ~4 s in the game at that speed). Not tried in the game: watch how long a failing
    search takes in a big town, and the `ROUTE area from` / `ROUTE whole area` log lines.
  - The +20 box fixed the Palasttor cases (the study and the palace exits, a guard
    up-left: all reachable only via the stairs outside the small box). Atlasdam's
    buildings at ~16000 units and one "2922, above" were "not reachable" with the +40
    box; not tried again.
- **Water and invisible floors: walked in the game.** (2026-11-16, user: "er will immer
  durch das Wasser, er müsste über die Brücke") On the path to the Maiya caves the water is
  filled with invisible blocking volumes (the level file F_Sea_1_1: convex "Box brushes",
  z -475 to 1525), and the bridge's deck is four invisible slabs (z 425 to 507, x 1295 to
  1695, y -1660 to -280) over a volume that ends at 355. Channel 0 sees neither: every
  route waded through the river with "soft" steps, the walk learned 15 walls in a row, and
  no route took the bridge.
  - Now a cell is a place only where the character fits: its knee and head points (55 and
    150 over the floor) not inside anything the character's own collision profile blocks
    (people excepted: the people rules keep away from them). Where channel 0 finds no
    floor, or no room, that profile measures the floor: the bridge's deck. A target
    hovering 150 or more over its channel-0 floor gets its floor by that profile too.
  - Mock river (test_water.lua): the old router waded (9 cells in the river, 10 soft
    steps), the new one crosses on the bridge, also with a person standing on it, and
    reaches a target on the deck. Without the bridge, "not reachable" (the whole area ran
    out of cells), no wading.
  - In the game (2026-11-16, 22:26-22:50, Slot 1 in Rippeltiden, then onto the path):
    from the entrance to chest 3 the route crossed the bridge on its deck (floors 496 to
    541 over the river), went down a slope south of it and back north on the beach to the
    chest under the bridge (floor ~0): "Öffnen, E", no bump, no learned wall, no new route,
    ~30 s of walking with a battle between. From there to chest 4 (920 higher) the same:
    no bump. Log: `no-room=` and `capsule-floors=` in `ROUTE ok` / `ROUTE fail` (they
    count the search's own traces: 0 when the background check traced the cells), and
    `@z` in `ROUTE cells` where the floor changes by more than 40.
  - Gaps between invisible volumes: a straight step now also traces the character's own
    profile 40 to each side (the capsule's radius is ~42). Both hit: narrower than the
    body, no step (one under the bridge's east side looks ~72 wide in the level file); one
    hits: it grazes a wall, a "soft" step, so routes keep off invisible walls as off
    visible ones. Not on step-in routes (the inn's narrow side stairs). Mock: a 70-wide gap
    in an invisible wall is no way, a 160-wide one is. Costs ~20% more traces. Log:
    `too-narrow=` in `ROUTE ok` / `ROUTE fail`.
  - The level files hold all blocking volumes: `scripts/level-dump.py` lists them.
- **After a battle the walk goes on with its route: tried twice.** (2026-11-16)
  A battle, a menu, a speech bubble or a scene stops the walk ("Angehalten"), and the
  route is kept. The next Backspace for the same target walks on with it from where you
  stand ("Gehe los, dieselbe Route wie vorhin, insgesamt ..."), without a new search: if
  you stand within 150 of the rest of the route, in the same area, within 15 minutes,
  and the target (a person) moved less than 100. Otherwise it searches anew, as before.
  Log line `NAVWALK on with the old route`. On the Maiya path after both battles (to chest
  3: "4 from its leg 26 of 43"; to chest 4: "2 from its leg 18 of 26"), each walk then
  reached its chest.
- **The list is checked in the background, but not everything** (user request
  2026-11-13: offer only targets you can reach, or say which you can't). While you
  explore, the walk router checks the open list quietly (40 traces per tick), nearest
  and focused targets first; Palasttor's 5 exits took ~13 s with the big box. Failures
  say "not reachable" and go last when the list is built again. Not checked: targets
  inside a house you're not in (they say "inside a building"; the walk goes to the door)
  and, from inside a house, targets outside it. A result only holds within 600 of where
  you stood, so after walking off the list is checked again on the next build.
  Since 2026-11-16 a check's time limit counts only its own work: it waits while you
  walk or fight, and that wait had used up its 76 s on the Maiya path, so the chest
  said "not reachable" though the walk found the way. It also takes the whole area, as
  the walk does, and running out of traces there gives no verdict (checked again on the
  next list build).
  Also since then the checks from one spot and the walk you start from that spot share
  their traces (the walk never did: a door opened since would still look shut -- so not
  within 150 of a door; E needs you within ~35 of one). The target you have selected is
  checked with 10 ms slices instead of 4, so its cells are often traced before you press
  Backspace. In a mock street (test_share.lua) the walk right after the check needed 508
  new traces instead of 6482, the same route, still clear of a person standing in the
  way. In the game: the walk to chest 4 took over the check's traces ("ROUTE takes over
  the traces of the checks from here", 491 traces, 0.2 s); the one to chest 3 came after
  a finished check (1451 traces, 0.3 s).
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
  game's own flag (IsHouseEnter), see the walker section. Since 2c6c435 triggers that
  only switch the light (the academy's SchoolLighting_Out, _IN, _In_Library:
  ForceHouseOut, no door object) are no buildings at all, and "Leaving the building
  first" needs a door that shuts; by the study's entrance SchoolLighting_Out had sent
  every walk to an unreachable spot a floor up. Other towns' triggers were not dumped.
  Room boxes overlap: in Flammhuld the tavern's box reaches 1600 past its door, over
  House_B, and the first door in the list that held a target won. The walk to the
  Söldner in House_B (its door 116 away) went to the tavern's door and then round House_B's
  walls (user, 2026-11-16). Now every door is weighed: the one nearest the target wins (a
  door on another floor counts farther), unless your own house holds the target and its
  door is about as near. And the walk now goes to the target's door from 60–120 away
  too (before, it routed straight in, failed after 10 s and said "press E" where the
  prompt doesn't show). Only checked with the logged positions in a unit test so far,
  not yet in the game.
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
