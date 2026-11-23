# Changelog

All notable changes to OP1 Access. Write new entries under "Unreleased"; the release workflow
turns that section into the next version and uses it as the release notes.

## [Unreleased]

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
