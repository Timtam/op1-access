# OP1Access — Octopath Traveler screen-reader accessibility mod

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)-based mod that makes
**Octopath Traveler** (PC / Steam, 2019, Unreal Engine 4.18) playable with a screen
reader. It speaks the menus, the dialogue, the battles and the path actions, and it
adds what you need to explore without sight: a 3D audio radar, a navigator that names
and points to everything around you, and a walker that takes you there.

Speech and braille go through [Prism](https://github.com/ethindp/prism) to NVDA,
JAWS, ZoomText and other screen readers, or to Windows' own voices (OneCore / SAPI)
when none is running. The mod speaks German or English and follows the game's text
language.

> **Status:** early but playable. `CHANGELOG.md` lists what is there,
> [docs/known-issues.md](docs/known-issues.md) what is open or not tested yet.
> Expect rough edges, especially in places and fights nobody has tried yet.

## Install

You need Octopath Traveler from Steam on Windows 10 or 11, and a screen reader
(NVDA, JAWS and others) or Windows' own voices. The Microsoft Visual C++
Redistributable (x64) is needed too; Steam installs it with the game. For the radar,
use headphones: its sounds come from the direction of what they stand for.

### With the installer

1. Download `OP1AccessInstaller.exe` from the
   [latest release](../../releases/latest).
2. Start it. Windows may warn that the file is not signed: choose *More info*,
   then *Run anyway*.
3. The installer finds Octopath Traveler in your Steam libraries. If it cannot,
   choose *Choose folder* and select `Octopath_Traveler.exe` in the game folder. The
   window shows the installed and the latest version.
4. Choose *Install*. The installer downloads the latest release and installs
   UE4SS 4.0.0 (unless it is there already) and the mod. It also turns off
   UE4SS's console window, which would take the focus away from the game, and
   UE4SS's own mods (consoles, cheat manager, Blueprint mod loader, key binds),
   which OP1 Access doesn't need. An installation with UE4SS 3.0.1 from an
   earlier version is moved over; sounds you put into `Assets` stay.
5. Start the game with your screen reader running. You hear
   **“OP1 Access loaded”**. From then on the mod speaks the game's text language
   (“OP1 Access geladen” when the game is set to German).

The installer is a plain Windows dialog that works with screen readers:
progress is announced, and questions and results come as message boxes. It adds
OP1 Access to *Installed apps* in the Windows settings and puts a copy of itself
into the mod folder, which the mod uses for updates.

### Manual installation

1. Find the game folder: in Steam, open the context menu of Octopath Traveler
   and choose *Manage*, then *Browse local files*. The folder contains
   `Octopath_Traveler.exe`.
2. Download `OP1Access-<version>.zip` from the
   [latest release](../../releases/latest) and extract it into the game folder.
   Everything lands in `Octopath_Traveler\Binaries\Win64`: UE4SS 4.0.0
   (`dwmapi.dll` there, and the `ue4ss` folder with `UE4SS.dll`,
   `UE4SS-settings.ini` and `Mods`), `phonon.dll`, and the mod in
   `ue4ss\Mods\OP1Access`.
   If UE4SS 4 is installed already, `ue4ss\Mods\OP1Access` and `phonon.dll` are
   enough; then add the line `OP1Access : 1` to `ue4ss\Mods\mods.txt` and set
   `GuiConsoleEnabled = 0` in `ue4ss\UE4SS-settings.ini`. An older UE4SS 3 has
   `UE4SS.dll` right in `Win64`: remove it first (`UE4SS.dll`,
   `UE4SS-settings.ini` and the `Mods` folder there), or let the installer do it.
3. Start the game with your screen reader running.

See `docs/install-state.md` for the exact deployed layout.

## Updates

When the game starts, the mod asks GitHub whether a newer version is out and
tells you if there is one. **F5** checks again at any time. To install an
update, press **F5 twice**: the mod closes the game (without saving), and the
installer downloads and installs the new version and starts the game again.
This needs `OP1AccessInstaller.exe` in `ue4ss\Mods\OP1Access`, where the installer and
the ZIP put it; without it, F5 opens the download page instead. You can also run
the installer again at any time; it updates the mod and itself. The check sends
one request to the GitHub API and nothing else.

## Uninstalling

Open *Installed apps* in the Windows settings and uninstall *OP1 Access*, or
start the installer and choose *Uninstall*. You are asked whether to remove
UE4SS as well; keep it if you use other UE4SS mods for Octopath Traveler.

By hand: in `Octopath_Traveler\Binaries\Win64`, delete the folder
`ue4ss\Mods\OP1Access` and `phonon.dll`. To remove UE4SS as well, delete
`dwmapi.dll` and the folder `ue4ss`.

## Keys

The game's own keys stay as they are: arrow keys to move, **Enter** to confirm and to
talk, **E** to open doors and chests and to examine, **J** for the path-action menu,
**Escape** for the main menu, **Backspace** to go back in menus. The mod adds these:

### Everywhere

| Key | Action |
|-----|--------|
| **Comma / Period** | Speech history: back / forward through the last 100 lines, dialogue included; the first Comma repeats the newest line |
| **Shift + Comma / Shift + Period** | Speech history: the first / the last line |
| **Q** | The current objective (not in battle, where Q lowers the boost) |
| **Ctrl + F10** | Say the screen you are on |
| **Ctrl + F7** | Sound test, press repeatedly: a tone on your right, left, in front and behind you, the same placed on the map around your character, the wall bump, then off — to check your headphones |
| **F5** | Check for an update; press twice to install it |

### Exploring

| Key | Action |
|-----|--------|
| **Home / End** or **Ctrl + Left / Right** | Navigator: previous / next category — chests, exits, buildings, shops, people, markers |
| **Page Up / Page Down** or **Ctrl + Up / Down** | Navigator: previous / next target in that category, nearest first |
| **Ctrl + Backspace** | The target's direction, distance and floor, and the way there step by step |
| **Backspace** | Walk to the target; press again to stop |
| **Ctrl + Enter** | Walk to the target or stop, like Backspace |
| **Ctrl + F9** | What you can do in front of you right now: talk, and which path actions |

### In battle

| Key | Action |
|-----|--------|
| **1 to 5** | Enemy 1 to 5: name, shield, weaknesses, status effects |
| **6 to 9** | Party member 1 to 4: HP, SP, BP, status effects |
| **0** | The turn order: this round and the next |

### On the world map (main menu, *Weltkarte*)

| Key | Action |
|-----|--------|
| **Page Up / Page Down** | Every place the map shows, nearest first, with its direction; the map's cursor goes there, so Enter fast travels to a visited town |
| **Home / End** | The eight regions (and back to the places the map shows); Page Up / Down then name every place of that region, also the ones not discovered yet |
| **Ctrl + Backspace** | The route to the place picked with Page Up / Down, area by area; in the field the exit on that route then says “on the way to …” |

### Character select

**Page Up / Page Down**, the **arrow keys** and **N**, see
[Character select](#character-select-choose-your-character) below.

### Developer keys

| Key | Action |
|-----|--------|
| **Ctrl + F2** | Screenshot of the game window to `Win64\op1access_shot.bmp` |
| **Ctrl + F3** | Dump the battle widgets to `UE4SS.log` |
| **Ctrl + F4** | Wall scan around the player |
| **Ctrl + F5** | Dump the main menu's lists to `UE4SS.log` |
| **Ctrl + F6** | Probe the collision trace channels |
| **Ctrl + F8** | The nearest object of any kind, raw |
| **Ctrl + F11** | Dump UHT-compatible headers to `UHTHeaderDump/` |
| **Ctrl + F12** | Dump all live objects to `UE4SS_ObjectDump.txt` |

## What you hear

### Speech and languages

- Every screen is named as it opens, and the focused entry is read as you move.
  Confirm dialogs are read with their question and the selected answer.
- The mod's own words follow the game's text language, also when you change it in the
  game's options: German and English for now. More languages are one text file each,
  see [docs/translations.md](docs/translations.md).
- Money is said as a word in the game's language (“50 Blätter”, “50 leaves”); the game
  itself only shows a ⑳ sign, which screen readers can't read. Keys the tutorials show
  as circled letters (“Drückt die Ⓞ-Taste”) are said as plain letters (“O-Taste”).
- Dialogue is read with the speaker's name, story scenes and tutorials too.

### Exploring

- **The radar** is on whenever you can walk around, and quiet in menus, scenes and
  battles; like the game, it also goes silent while another window is in front.
  Chests, exits, people, buildings and shops each have their own sound, which comes
  from where the thing is (Steam Audio, 3D) and repeats faster the closer you get. A
  wall radar sounds the walls ahead and to the sides, a thud plays when you walk into
  one, and a chirp when you pass through a door. You can put your own sounds in
  `Mods\OP1Access\Assets` (see the `README.md` there).
- **On arrival** you hear the area, its region and how dangerous it is (“Nördliche
  Atlasdamm-Ebenen, Flachland, Gefahrenstufe 1”) and how many objects the radar found.
  Door and action prompts are said as they come up (“Öffnen, E”).
- **The navigator** lists what is around you by category, nearest first, with direction
  and distance (“Ausgang 1 von 3: nach Nördliche Atlasdamm-Ebenen, Gefahrenstufe 1,
  oben, 1486”). It says which chests are opened or purple, which targets can't be
  reached, which are inside a building, where exits lead and how dangerous the area
  behind them is, and what kind of shop a shop is.
- **Markers** are the minimap's icons: side stories with the person's name, hidden
  items, the objective, the exit toward it, save points, travelers to recruit. A new
  one is said when it comes up (“Neue Markierung: verborgenes Objekt, rechts, 3872”).
- **The walker** takes you to the target over a computed route: around walls and
  people, up and down narrow stairs, and through doors, which it opens itself. When
  someone blocks the only way it says who (“Armer is in the way”), and at a chest or a
  hidden item it waits for the game's prompt and tries another side when none comes.

### Path actions

Facing someone, you hear which path actions you can use on them, and whether one is
done already or not possible. The J menu says the same. The screens of all eight
travelers' path actions are read: what a person carries with its price or chance
(Purchase, Steal), a person's strength and skills (Challenge, Provoke, Guide, Allure,
also when you swap followers), H'aanit's monsters, and what Scrutinize and Inquire find
out.

### Menus

- Title screen, character select, save and load (also at save points), the options and
  the game over screen.
- The main menu: its categories (the ones you can't open yet say so), the inventory with
  counts, descriptions and whom an item is for, the skills (learning them with their LBP
  costs; equipping support skills: each traveler's four slots, the learned ones with
  their descriptions, and the key to take one off), the equipment with what a piece would
  change, the tutorials and
  the Miscellaneous submenu. Coming back from a list, the options or a dialog, the menu
  says where you are again.
- The objective is read when the menu opens, and with Q at any time.
- The world map: the place under the cursor (town, path or dungeon, region, danger
  level, whether you have been there) and the chapters recommended there. See the world
  map keys above.
- Shops and inns: the shop's name and your money, the goods with price and how many you
  have, the amount to buy or sell with the total, and for weapons and armor what they
  would change for each traveler. The tavern: the keeper's menu, the party change and the
  story select.

### Battles

The commands, skills and items with their costs, the targets, the boost level, who does
what, damage and healing, breaks, knock-outs, status effects and the results with drops.
Weaknesses come in the game's own tile order, with the unknown ones in place (“weak to
2 unknown, Dunkelheit”), so you can tell what an unknown one can still be.

## Character select (“Choose your character”)

This is the opening screen where you pick your starting traveler. It is a
free-cursor world map with the eight travelers placed around it. There are two
ways to get around, and they work together.

### Cycling — the reliable way to choose

| Key | Action |
|-----|--------|
| **Page Down** | Jump to the next traveler |
| **Page Up** | Jump to the previous traveler |

Each press snaps directly onto a traveler and reads their **name, job, path
action, and talent** (e.g. *“Ophilia. Cleric. Path action: Guide. Talent:
Summon”*). This is the dependable way to land exactly on someone — then confirm
with the game's normal accept button. If you only want to pick a character,
use this.

### Free cursor — spatial exploration

| Key | Action |
|-----|--------|
| **Arrow keys** | Move the cursor around the map |
| **N** | Guide to the **nearest** traveler |

- As you move, it speaks your **coordinates** when the cursor settles, and a
  traveler's full info when the cursor lands on one.
- **N** announces the closest traveler, **the arrow keys to press to reach
  them**, and their coordinates — e.g. *“Cyrus, up and left. At -70, 40.”* This
  works for all eight from the start; passing over a traveler refines it.
- If a press does **not** move the cursor, it tells you why — **“reversing”**
  (you changed direction and the cursor is bleeding off momentum — keep
  pressing) or **“blocked”** (e.g. a map edge) — followed by your coordinates,
  so a press is never silent.

### Known limitations

- The cursor is **momentum-driven**: reversing direction stalls for ~3–4 presses
  before it turns, and it moves in large steps. Precise free-cursor positioning
  is therefore difficult — for actually selecting a traveler, prefer
  **Page Up / Page Down**.
- The "up / down / left / right" guidance assumes the default arrow→map mapping
  and self-corrects as you move; if a direction ever comes out reversed, it will
  fix itself after you move that way once.

## How it works

- **UE4SS** injects into the game (via a `dwmapi.dll` proxy) and hosts Lua mods.
- All policy — *what* to speak and *when* — lives in Lua at
  `scripts/Mods/OP1Access/Scripts/main.lua`. It finds the focused screen through the
  game's UI manager (its active stack), reads the widgets' fields, and hooks a few
  game functions (`KSUIManager:Open`, the battle's damage numbers and action banner).
  Its screen polls run every 50 ms; everything that calls into the game runs on the
  game's own thread.
- **`OP1AccessShim.dll`** is a small Lua C extension with **Prism** (MPL-2.0) linked
  in. It sends text (speech + braille) to whichever screen reader is running, uses
  OneCore/SAPI speech when there is none, and switches over if you start or restart
  your screen reader while the game runs. Speech runs on its own thread, so a busy
  screen reader never stalls the game. The shim also plays the radar through
  **Steam Audio** (`phonon.dll`), hooks the game's dialogue text natively (MinHook),
  fires the walker's collision traces and reads game memory where Lua can't reach,
  each read guarded so a stale address can't crash the game.
- The mod's own texts are English in the code; `Scripts/lang/<language>.po` holds the
  translations (gettext), and `Scripts/worldlinks.lua` the links between the areas that
  the world map's route finder uses.

Without the shim the mod still runs and writes everything it *would* speak
to `UE4SS.log` (lines prefixed `[OP1Access]`) — useful for development.

## Building from source

Requirements: Visual Studio 2022 or newer with the C++ workload (it brings
CMake and Ninja; Prism needs a C++23 compiler), Git, PowerShell 7, the
.NET 8 SDK for the installer, and Python 3 for the translation tool.

1. Fetch the pinned dependencies into `tools\`:
   ```
   pwsh scripts\fetch-deps.ps1
   ```
2. Install UE4SS 4.0.0 into the game (the installer does it, or extract
   `tools\UE4SS_v4.0.0.zip` into `Octopath_Traveler\Binaries\Win64`) and add
   `OP1Access : 1` to `Win64\ue4ss\Mods\mods.txt`.
3. Build the shim and copy it into the game. The game must be closed:
   ```
   scripts\build-shim.cmd
   ```
   This builds Prism as a static library and `OP1AccessShim.dll`, checks that
   `main.lua` compiles, and copies the shim, `phonon.dll` and Prism's license
   notices into the game.
4. Copy the mod's folder into place; the build script does **not** deploy the Lua
   scripts, the translations or the sounds:
   ```
   xcopy /E /I /Y scripts\Mods\OP1Access "…\Win64\ue4ss\Mods\OP1Access"
   ```

A copy built like this has no `buildinfo.lua`, so it doesn't check for updates.
To build a release the way the CI does, run `pwsh scripts\build-release.ps1`.
It writes `dist\OP1Access-<version>.zip`, `dist\OP1AccessInstaller.exe` and
`dist\SHA256SUMS.txt`. More about the build, the installer and the packages is
in [docs/build-and-release.md](docs/build-and-release.md).

### Texts and translations

Every text the mod says itself goes through `tr()` / `trf()` / `trn()` in
`main.lua`. After adding or changing one, update the template and the translations:
```
python scripts\i18n.py update
python scripts\i18n.py check
```
then translate the new entries in `Scripts\lang\de.po`. How to add a language is in
[docs/translations.md](docs/translations.md).

## Releasing

1. While you work, add your changes under `## [Unreleased]` in `CHANGELOG.md`.
2. On GitHub, open *Actions*, choose *Release* and *Run workflow* on the default
   branch. Choose the part of the version to raise (patch, minor or major) or
   type an exact version. A version in `Directory.Build.props` that has not been
   released yet, like 0.1.0 for the first release, is used as it is.
3. The workflow moves the "Unreleased" entries into a section for the new
   version, sets the version in `Directory.Build.props`, builds everything,
   commits "Release vX.Y.Z", tags it and publishes a GitHub release. The
   changelog section becomes the release notes; the ZIP, the installer and
   `SHA256SUMS.txt` become its downloads.

The mod and the installer look for updates in the latest release of the
repository they were built from. The *CI* workflow builds every push to the
default branch and every pull request and keeps the ZIP and the installer as
artifacts of the run. If the default branch is protected, the release workflow
needs permission to push to it.

## Development notes

- `UE4SS.log` in `Win64\ue4ss` has everything the mod says (`speak: …`) and what it saw:
  `ACTIVE screen`, `RADAR`, `AREA`, `ROUTE`, `NAVWALK`, `BATTLE`, `DLG`, `FINDALL`
  and more. Setting `M.trace = true` in `main.lua` also logs every step of the polls,
  so after a crash the last line names the step that was running.
- [docs/known-issues.md](docs/known-issues.md) lists what is open or untested, by area;
  fixed entries are deleted (the commits keep the history).
- The flat object dump (`UE4SS_ObjectDump.txt`, Ctrl + F12) is the source of truth for
  Blueprint property names, offsets and types; `docs/sdk-dump-procedure.md` covers
  capturing hook targets.
- Two rules keep the game from crashing: game objects the mod keeps between polls are
  stored as handles and checked with the shim's guarded reads before UE4SS touches them
  again (`M.handle`, `M.kept`), and calls into the game run on the game thread
  (`M.in_gt`).
- `build-shim.cmd` links a `luac.exe` (`build\shim\luac.exe`) from UE4SS's
  Lua sources and checks `main.lua` with it; run it again by hand after editing
  (`build\shim\luac.exe -p scripts\Mods\OP1Access\Scripts\main.lua`).

## Repo layout

```
docs/         known issues, translations, build and release, install state, investigations
src/          C++ shim source (Lua 5.4 and Prism linked in; Speech.cpp, SpatialAudio.cpp)
scripts/      the mod (Mods/OP1Access/: Scripts/main.lua, worldlinks.lua, lang/, Assets/),
              build-shim.cmd, the release scripts, i18n.py and level-links.py
installer/    OP1AccessInstaller (.NET Framework 4.8, WinForms)
packaging/    README and third-party notices of the release ZIP
.github/      CI and release workflows
tools/        build dependencies from fetch-deps.ps1 (gitignored)
dist/         release builds (gitignored)
```

## License

Mod code: **MIT** (see `LICENSE`). The release also contains UE4SS (MIT), and the shim
links Prism (**MPL-2.0**, built unmodified from upstream), Lua (MIT), MinHook
(BSD 2-Clause) and miniaudio (public domain / MIT-0); `phonon.dll` is Steam Audio
(Apache 2.0). Details: `THIRD_PARTY_LICENSES.md`.

Octopath Traveler is a game by Square Enix. OP1 Access is unofficial and not affiliated
with it.
