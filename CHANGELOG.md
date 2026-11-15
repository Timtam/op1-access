# Changelog

All notable changes to OP1 Access. Write new entries under "Unreleased"; the release workflow
turns that section into the next version and uses it as the release notes.

## [Unreleased]

The first release. OP1 Access reads Octopath Traveler (Steam) with your screen reader.

### Speech

- Speech and braille through Prism: NVDA, JAWS and other screen readers, or Windows' own voices
  (OneCore, SAPI) when none runs. Restarting the screen reader while the game runs is fine.
- Money is said as a word in the game's language ("50 Blätter", "50 leaves"). The game only
  shows its own ⑳ sign, which screen readers can't read.
- Keys the tutorials name as circled letters ("Drückt die Ⓞ-Taste", "Ⓙ drücken") are said
  as plain letters ("O-Taste", "J").

### Menus

- Title screen, character select, save and load (also at save points), options and confirm
  dialogs.
- Main menu: categories, the current objective (also with Q), inventory (tabs, items with count
  and description, whom an item is for), abilities (learning skills with costs, support skills),
  equipment (slots, items and what they would change) and the tutorials.
- World map: the place under the cursor (town, path or dungeon, region, danger level, not
  visited) and the chapters recommended there; Page Up and Page Down go through every place,
  nearest first, with its direction from where you are, and move the cursor there for fast
  travel. Home and End go through the eight regions; Page Up and Page Down then name every
  place of that region, also those not discovered yet. Ctrl+Backspace says the route to
  that place area by area; in the field the exit on that route says "on the way to …".
- The game over menu.
- Shops and inns: the shop's name and your money, its commands, the goods with price and how
  many you have, the amount to buy or sell with the total, and for weapons and armor what
  they would change for each traveler.
- The tavern: the keeper's menu, the equipment screen, changing the party and choosing whose
  story to continue.

### Story and exploration

- Dialogue with speaker names, area names, door and action prompts.
- Path actions (J): facing someone tells you which path actions you can use on them and
  whether one is done already or not possible yet; the J menu says the same. The screens
  of all eight travelers' path actions are read: what a person carries with price or
  chance (Purchase, Steal), the person's strength, skills and how often they can be called
  (Challenge, Provoke, Guide, Allure, also when you swap followers), H'aanit's monsters,
  and what Scrutinize and Inquire find out.
- A 3D radar (Steam Audio) for chests, exits, people, buildings and shops, a wall radar and
  bump sounds.
- A navigator: categories with Home and End, targets with Page Up and Page Down, Ctrl+Backspace
  for directions. It says which chests are opened, which targets can't be reached, where exits
  lead and how dangerous the area behind them is, and what kind of shop a shop is.
- A walker: Backspace walks to the target over a computed route, also up and down narrow
  stairs, opens doors on the way and frees itself when stuck.

### Battles

- Commands, skills and items with costs, targets, the boost level, actions with their actor,
  damage and healing, breaks, status effects and the results. Keys 1 to 5 read an enemy (shield,
  weaknesses), 6 to 9 a party member, 0 the turn order.

### Installation

- An installer that finds the game, installs UE4SS 3.0.1 with the mod, and removes both again.
- Update notices in the game; F5 twice installs an update.
