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
- Keys the game draws as key caps, in the tutorials and in the menus' footers, are said by
  name: "Drückt die Ⓞ-Taste" as "O-Taste", "┣: Zurück" as "Rücktaste: Zurück", and so on
  for the arrows, Shift, Ctrl, the number pad, F1 to F12, the mouse and gamepad buttons,
  also with a German, Italian, Spanish or French keyboard.
- The mod's own words follow the game's text language, also when you change it in the
  options: German and English for now ("Truhe 1 von 5", "chest 1 of 5"). More languages are
  a text file each (gettext .po, see docs/translations.md).
- A speech history: comma and period read the last 100 lines again (back and forward), the
  dialogue too; Shift+comma and Shift+period jump to the first and the last.

### Menus

- Title screen, character select, save and load (also at save points), options and confirm
  dialogs.
- Main menu: categories, the current objective (also with Q, in the field and in the menu's
  list; in the menu's other screens Q stays the game's own key), inventory (tabs, items with count
  and description, whom an item is for), abilities (learning skills with costs, support skills),
  equipment (slots, items and what they would change), the tutorials and the
  Miscellaneous submenu (settings, tutorial, back to the title, quit). Back from a list, the
  options or a dialog, the menu says where you are again.
- World map: the place under the cursor (town, path or dungeon, region, danger level, not
  visited) and the chapters recommended there; Page Up and Page Down go through every place,
  nearest first, with its direction from where you are, and move the cursor there for fast
  travel. Home and End go through the eight regions; Page Up and Page Down then name every
  place of that region, also those not discovered yet. Ctrl+Backspace says the route to
  that place area by area; in the field the exit on that route says "on the way to …".
  When a town you have visited is nearer to the place than you are, the route starts
  there ("fast travel to Rippeltiden, then 2 areas"); Ctrl+Backspace again puts the
  cursor on that town, and Enter travels.
- The game over menu.
- The status screen: each traveler's name, level, jobs, the weapons they carry, job
  points, stats, EXP to the next level, path action and talent; Up and Down switch
  travelers.
- The journal: the travelers' stories and the regions' side stories with their progress,
  and the keys to switch between them (Q and O, from the screen's footer); each list
  with its title and its entries (chapter and entry, new or finished) and their text:
  who asked, the story so far, the result. Moving past travelers whose story isn't open
  yet says only the one you stop at.
- Shops and inns: the shop's name and your money, its commands, the goods with price and how
  many you have, the amount to buy or sell with the total, and for weapons and armor what
  they would change for each traveler. After buying a weapon or armor and choosing to
  equip it right away, the traveler you pick it for and what it changes for them.
- The tavern: the keeper's menu, the equipment screen, changing the party and choosing whose
  story to continue.

### Story and exploration

- Dialogue with speaker names, area names, door and action prompts. A prompt that belongs
  to a person names them ("Dörfler: Untersuchen, E"), so it isn't taken for a chest's.
- The game's notifications at the screen's edge are read. Above all the reputation: a
  failed Scrutinize, Steal, Allure or Provoke says how many more failures the town takes
  ("Scheitert noch 4 Mal, und Euer Ruf in der Stadt wird leiden."), then that it is ruined
  ("Euer Ruf in Klarach hat gelitten.") and, after the tavern restored it, that it is
  better again.
- A scene you can skip says so as it starts: "Hold Backspace to skip". The game itself
  shows that hint only after a key press.
- Path actions (J): facing someone tells you which path actions you can use on them and
  whether one is done already or not possible yet; the J menu says the same. Someone
  without any (a tavern guest) gets no such hint. The screens
  of all eight travelers' path actions are read: what a person carries with price or
  chance (Purchase, Steal), the person's strength, skills and how often they can be called
  (Challenge, Provoke, Guide, Allure, also when you swap followers), H'aanit's monsters,
  and what Scrutinize and Inquire find out.
- A 3D radar (Steam Audio) for chests, exits, people, buildings and shops, a wall radar and
  bump sounds. Objects are heard from three times as far as before (1500 units, about 11
  of the walker's grid steps), quieter and pinging slower the farther they are, 6 dB
  quieter with each doubling of the distance; walls up to 450 units, from loud right next
  to one down to quiet, instead of only loud or very loud within 175. With more objects
  in range than the radar's 28 voices, the nearest ones sound. Like the game, it goes silent while another window is in front. A save
  point's book is no person, also after you saved there: it is in the marker list. After
  a dialogue, a scene or a battle the radar comes back as soon as the game gives you the
  controls again, more than a second sooner than before.
- A navigator: categories with Home and End, targets with Page Up and Page Down, Ctrl+Backspace
  for directions. It says which chests are opened or purple, which targets are higher or lower
  than you (a floor, or a terrace a few steps up), which can't be reached, where exits
  lead and how dangerous the area behind them is, and what kind of shop a shop is. A
  tavern leads to its barkeep, not to the door. Everyone you can talk to or use a path
  action on is on the radar and in the people list from the start: also the village
  chiefs, barkeeps and many side-story people, who used to show up only after you had
  talked to them. The crowds you can do neither with (tavern guests, passers-by) stay
  out of the list; the walker still goes round them. People are listed by the game's own names
  for them: a line said by someone else no longer renames the person you just talked to,
  and a person in the next area no longer takes on the name of one you met before.
- The minimap's markers: what each one is (side story with the person's name, hidden item,
  objective, exit toward the objective, save point, traveler to recruit) and whether a
  hidden item was picked up already. A new marker is said when it comes up, for example
  when Scrutinize reveals a hidden item: "New marker: hidden item, right, 3872"; the radar
  rings for it right away. A marker the game takes away leaves the list too, and a goal
  is said when it goes ("Marker gone: objective", for example after the objective's
  scene). Your selected target stays selected when another marker goes.
- A walker: Backspace walks to the target over a computed route, also up and down narrow
  stairs and around people, opens doors on the way and frees itself when stuck. When
  someone blocks the only way, it says who ("Armer is in the way"). Someone walking about
  who steps into the way, like the guards on patrol in Sonnschatt, is waited for ("Warte
  auf Tunichtgut"), up to three times, before the walk looks for another way; it used to
  plan a new way at once, which the guard walked into again, and a new way could even
  start right behind the person next to you. At a chest or a hidden
  item it waits for the game's prompt and tries another side when none comes; only the
  item's own prompt counts -- a villager lying before a chest, with his own "Untersuchen,
  E", used to end the walk at him -- and only where E reaches the item: with the save
  point's book or a person picked as well, E talks to them first, so the walk tries a
  side where they aren't in front of you ("Hier spricht E Speicherpunkt an, versuche eine
  andere Seite"). A person it
  can't get close enough to talk to (Mercedes behind the counter of Atlasdamm's library)
  gets the same: up to two other sides, each square in front of them, then "Mercedes ist
  nicht in Reichweite"; it used to stop without a word, and J then offered the follower's
  menu. When the game already offers the person as you arrive, no last step spoils it. A shop
  that opens at its entrance (no keeper) counts as reached only when its prompt shows;
  the route there follows the character's own collision, so it finds side stairs the
  other traces miss. Otherwise the walker says the entrance wasn't reached and how many
  people stand there. Before a target counts as not reachable, the search takes in the
  whole area, however far round the way goes. After a battle (or a menu), Backspace
  walks on along the same route. The route search is several times faster, most of all
  for a target you have just picked. Routes keep out of water and other places only
  invisible walls close off, and take invisible floors such as the bridge on the path to
  the Maiya caves. A chest beyond a fence or a railing is no longer walked at through
  it: the route takes the way round. Exits are walked to the line where they really
  take you on, not to a point that can stand behind an invisible wall (from the Östliche
  to the Südliche Sonnschatt-Sandwüste the walk got stuck just short of it).
  Whether a person or a chest is inside a building now comes from the game itself:
  Alfyn, waiting by Zeph's house in Klarach, was taken for inside it, and the walk went
  to Zeph's door, where Zeph stands ("Zeph steht im Weg"). A chest in a house's side
  room is now said to be inside a building, and the walk leads to that house's door.
  Routes no longer go over tables and other ledges: in Ravus manor's library the walk
  climbed onto the tables in its plan and bumped into them for minutes; a step up or down
  between two spots now counts only where stairs or a ramp lead there.

### Battles

- Commands, skills and items with costs, targets, the boost level, actions with their actor,
  damage and healing, breaks, status effects and the results. Keys 1 to 5 read an enemy (shield,
  weaknesses), 6 to 9 a party member, 0 the turn order from the current turn on ("Jetzt:
  Therion. Nächste Runde: ..."), not the ones who have acted already. Key 0 names every
  enemy with its position, the number key that reads it ("Majesto-Murmeltier auf 2"), so
  you can tell two of the same name apart and break the one that still has to act; a
  target that shares its name with another enemy says its position too.
- Capturing with H'aanit (and stealing in battle): the success chance comes right after
  the target's name ("Majesto-Murmeltier, Erfolgschance 100 %, gebrochen, ..."); it used
  to come last and was cut off. The capture question says the target and its chance
  again, and the command row ("Fangen") no longer cuts the question off.
- The weapon Attack uses ("Angriff, Speer"), and the new one when Left or Right switch it.
- A follower you call into the fight (a person Ophilia guides or Primrose allures, with
  "Rufen") is named with its actions ("Meryls Mutter: Physischer Boost"), also in the
  turns of its own it gets right after its caller's, and with the damage it takes; its
  actions used to be said as the last enemy's.
- A defeated enemy is said ("Räuber defeated") and leaves keys 1 to 5, which count only
  the enemies still fighting.
- The result screen waits until the EXP count-up is over (or skipped) and then says the
  totals, every level-up and the items in one line, so the key that skips the count-up
  no longer cuts it off; also when two travelers level up in one battle or one gains two
  levels.
- Blocked weaknesses: when a boss's helpers block its weaknesses, and when they are free
  again, it is said ("Mikk: weaknesses locked"); a boss blocked from the start has it in
  the battle's first line.
- Weaknesses come in the game's own tile order with the unknown ones in place ("weak to
  2 unknown, Dunkelheit"), so you can tell what an unknown one can still be.

### Installation

- An installer that finds the game, installs UE4SS 4.0.0 with the mod, and removes both again.
  UE4SS's own mods (consoles, cheat manager, Blueprint mod loader, key binds) are switched
  off; OP1 Access doesn't need them. On updates, sounds you put into `Assets` stay.
- Update notices in the game; F5 twice installs an update.

### Stability

- Two faults are fixed that could crash or freeze the game now and then (also when
  closing it) or let the radar and menus go silent: the mod's speech and sound part
  upset UE4SS's Lua lock, and UE4SS ran parts of the mod on two threads at once. With
  UE4SS 4.0.0 the mod does all its work on the game's main thread.
