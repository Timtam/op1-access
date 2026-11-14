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
- **Damage numbers** are read since 2026-11-14 (8aad812), together with healing and
  shield changes: "Eissentinel 55 weak, Eissentinel broken", "Cyrus 26", "Cyrus +500
  HP", "Eissentinel recovers, shield 1". Checked against one enemy. Not yet heard: SP
  and BP recovery, misses ("miss"), criticals (their DamageType is unknown: only
  0/3/4/5 were seen, 3 and 5 say "weak").
- **Not read at all:** item drops on the result screen (the reader exists, no drop
  yet), what a boosted command does, and the boost help.
- **Who acts is guessed for several enemies** (0e0e5d7). An action right after your
  own input is your character's; otherwise it is the only enemy's, or the one whose
  turn-order icon fades (IsFade, seen once). Not tried with two or more enemies or
  with more party members. Battle-start messages get no name.
- **Keys 0-9** in OT's own controls were not checked; no side effect showed in about
  10 fights. Q (lower the boost) no longer reads the objective in battle.

## Walker (user report 2026-11-14)

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
- **The side step in front of a person is untested.** When stepping straight toward
  a person behind a counter gets no closer, every other try steps sideways to stand
  square in front (Mercedes is picked at 161 with 26 to the side, not at 166 with 48).
  In 6 walks to people the route already ended in front of them, and the talk range was
  reached each time without it.

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

## Threads

- **Some code still calls game functions off the game thread.** Since 2026-11-14
  (11c8ce1) work queued for the game thread never runs anywhere else. UE4SS 3.0.1 ran it
  inside whichever thread called a UFunction next, and that crashed the game once in the
  learn-skill dialog. Still off the game thread on purpose:
  - **The title and menu polls of the fast async loop.** Each FindFirstOf of a screen
    that isn't open walks every object, 45-80 ms. Moved to the game thread, they froze
    the start.
  - **Most key binds.** They run under UE4SS's lock, which stops the game thread at its
    next ProcessEvent, but not inside Blueprint code.

  Moving them needs cheaper lookups first (cached screen widgets, GetActiveStack). Work
  that still lands on a foreign thread is logged ("GT: queued work on a foreign thread
  (#n), deferred"); it happened 5 times during a load and not after that. The crash was
  a race, so one clean screenshot in the same dialog proves little.

## Menus

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
  - Other screens built on the same list widget (equipment, shops).
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
  first"), and "Still shut. Öffnen, E, then backspace again" at a door leg. A search
  that dies at the start (`pops <= 3`, seen once in the academy) now makes the walker
  step free and try again (0fa43cb); a plain corner did not cause it.
