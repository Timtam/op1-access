# Changelog

All notable changes to OP1 Access. Write new entries under "Unreleased"; the release workflow
turns that section into the next version and uses it as the release notes.

## [Unreleased]

### Exploring

- The walker and the guide keep out of other exits' trigger zones: on the North S'warkii
  Trail the way to the Western Trail no longer leads into the town.

## [0.1.2] - 2026-11-24

### Exploring

- A guide: Shift + Backspace plans the route to the selected target like the walker,
  but you walk, following a sound at the route's next point (the target's own sound).
  The other radar sounds pause meanwhile; press again to stop.
- Chests have a sound of their own on the radar (`chest.flac`) instead of a plain beep.
- An opened chest is silent on the radar, so a chest you hear is one still to open. The
  navigator still lists opened chests.

### Story

- A story or flashback page or a tutorial that has waited 20 seconds for a key says which
  one goes on (“Continue with Enter”); a letter says at once that Backspace closes it.

### Menus

- While the game saves, the mod no longer says a “Yes” that isn't there (“Now saving...
  Please wait...”); “Save successful” has only its OK.
- Browsing the journal fast, the mod says the entry the cursor lands on, and then its
  text, also when you come back to an entry.
- Tutorials say their page (“Page 1 of 3”); Backspace shows the next page or closes the
  tutorial (Enter does nothing there).

## [0.1.1] - 2026-11-24

### Speech

- The mod speaks Simplified Chinese too, when the game's text language is Simplified
  Chinese.

### Exploring

- The game's radar key (O) turns the mod's object and wall sounds off and on too. The
  game keeps the setting in the save game, so it stays after a restart.
- The walker crosses the rope bridge in the Mountain Pass again, on the way to the
  Brigands' Den in Olberic's chapter 1. In 0.1.0 it said the way up couldn't be reached.

## [0.1.0] - 2026-11-23

The first release. OP1 Access makes Octopath Traveler (Steam) playable with a screen reader.

### Speech

- Speech and braille through Prism to NVDA, JAWS and other screen readers, or Windows' own
  voices (OneCore, SAPI) when none is running.
- The mod speaks German or English, following the game's text language. More languages are
  one gettext file each (docs/translations.md).
- Money is said as a word, and the key caps the game draws in tutorials and menu footers are
  said by name.
- A speech history: Comma and Period go back and forward through the last 100 lines,
  dialogue included.

### Menus

- Title screen, character select, save and load, options, confirm dialogs and the game over
  screen.
- The main menu: inventory, abilities and support skills, equipment with what a piece would
  change, status, journal, tutorials and Miscellaneous; the current objective, also with Q.
- The world map: places, regions, danger levels and recommended chapters, a place finder
  (Page Up / Down, Home / End) and a route finder with fast travel (Ctrl + Backspace).
- Shops, inns and taverns: goods with price and stock, amount and total, what a weapon or
  armor would change, equipping right after buying, changing the party and the story select.

### Story and exploration

- Dialogue with speaker names, scenes and tutorials; area names with region and danger level;
  door and action prompts, with Enter as the key; notifications such as your reputation in a
  town; a hint when a scene can be skipped.
- Path actions: what you can do with the person in front of you, and the path-action screens
  of all eight travelers.
- A 3D audio radar (Steam Audio) for chests, exits, people, buildings and shops, with a wall
  radar and bump sounds.
- A navigator: what is around you by category, nearest first, with direction and distance,
  opened chests, unreachable targets, where exits lead, the minimap's markers and where
  optional bosses wait.
- A walker: Backspace walks to the selected target over a computed route, through doors and
  around people, and says when a target can't be reached.

### Battles

- Commands, skills and items with costs, targets, boost, actions, damage and healing, breaks,
  status effects, results and level-ups.
- Keys 1 to 5 read an enemy (shield, weaknesses in the game's order), 6 to 9 a party member,
  0 the turn order with the enemies' positions.
- Capture and steal chances, followers called into battle, blocked weaknesses.

### Installation, updates and problem reports

- An installer that finds the game and installs or removes UE4SS 4.0.0 and the mod.
- Update notices in the game; F5 twice installs an update.
- F1 twice in the game, the installer or the Start menu open a window to report a problem.
  It sends the mod's logs of the last three sessions, UE4SS.log and, if you choose, the
  game's crash dumps, with your user name, computer name and Steam ID removed from the logs.
