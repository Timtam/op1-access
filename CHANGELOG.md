# Changelog

All notable changes to OP1 Access. Write new entries under "Unreleased"; the release workflow
turns that section into the next version and uses it as the release notes.

## [Unreleased]

The first release. OP1 Access reads Octopath Traveler (Steam) with your screen reader.

### Speech

- Speech and braille through Prism: NVDA, JAWS and other screen readers, or Windows' own voices
  (OneCore, SAPI) when none runs. Restarting the screen reader while the game runs is fine.

### Menus

- Title screen, character select, save and load (also at save points), options and confirm
  dialogs.
- Main menu: categories, the current objective (also with Q), inventory (tabs, items with count
  and description, whom an item is for), abilities (learning skills with costs, support skills),
  equipment (slots, items and what they would change) and the tutorials.

### Story and exploration

- Dialogue with speaker names, area names, door and action prompts, path actions (J).
- A 3D radar (Steam Audio) for chests, exits, people, buildings and shops, a wall radar and
  bump sounds.
- A navigator: categories with Home and End, targets with Page Up and Page Down, Ctrl+Backspace
  for directions. It says which chests are opened and which targets can't be reached.
- A walker: Backspace walks to the target over a computed route, opens doors on the way and
  frees itself when stuck.

### Battles

- Commands, skills and items with costs, targets, the boost level, actions with their actor,
  damage and healing, breaks, status effects and the results. Keys 1 to 5 read an enemy (shield,
  weaknesses), 6 to 9 a party member, 0 the turn order.

### Installation

- An installer that finds the game, installs UE4SS 3.0.1 with the mod, and removes both again.
- Update notices in the game; F5 twice installs an update.
