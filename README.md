# OP1Access — Octopath Traveler screen-reader accessibility mod

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)-based mod that adds
screen-reader output to **Octopath Traveler** (PC / Steam, 2019, Unreal Engine
4.18). Menus, system dialogs and the **character-select screen** are spoken
through [Prism](https://github.com/ethindp/prism), so it works with NVDA, JAWS,
ZoomText and other screen readers, and falls back to Windows' own voices
(OneCore / SAPI) when none is running.

> **Status:** early but functional. Menus, dialogue, exploration (a 3D radar,
> a navigator and a walker) and battles are spoken; `CHANGELOG.md` lists what
> is there. Expect rough edges.

## How it works

- **UE4SS** injects into the game (via a `dwmapi.dll` proxy) and hosts Lua mods.
- All policy — *what* to speak and *when* — lives in Lua at
  `scripts/Mods/OP1Access/Scripts/main.lua`. It hooks the game's UI lifecycle
  (`KSUIManager`, `KSUserWidgetBase`) and polls widget state on a 50 ms loop.
- Speech is emitted by **`OP1AccessShim.dll`**, a small Lua C extension with
  **Prism** (MPL-2.0) linked in. It sends text (speech + braille) to whichever
  screen reader is running, uses OneCore/SAPI speech when there is none, and
  switches over if you start or restart your screen reader while the game runs.
  Speech runs on its own thread, so a busy screen reader never stalls the game.

Without the shim the mod still runs and writes everything it *would* speak
to `UE4SS.log` (lines prefixed `[OP1Access]`) — useful for development.

## Install

You need Octopath Traveler from Steam on Windows 10 or 11, and a screen reader
(NVDA, JAWS and others) or Windows' own voices. The Microsoft Visual C++
Redistributable (x64) is needed too; Steam installs it with the game.

### With the installer

1. Download `OP1AccessInstaller.exe` from the
   [latest release](../../releases/latest).
2. Start it. Windows may warn that the file is not signed: choose *More info*,
   then *Run anyway*.
3. The installer finds Octopath Traveler in your Steam libraries. If it cannot,
   choose *Choose folder* and select `Octopath_Traveler.exe` in the game folder. The
   window shows the installed and the latest version.
4. Choose *Install*. The installer downloads the latest release and installs
   UE4SS 3.0.1 (unless it is there already) and the mod. It also turns off
   UE4SS's console window, which would take the focus away from the game.
5. Start the game with your screen reader running. You hear
   **“OP1 Access loaded.”**

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
   Everything lands in `Octopath_Traveler\Binaries\Win64`: UE4SS 3.0.1
   (`dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and the `Mods` folder),
   `phonon.dll` and the mod in `Mods\OP1Access`.
   If UE4SS 3.0.1 is installed already, `Mods\OP1Access` and `phonon.dll` are
   enough; then add the line `OP1Access : 1` to `Mods\mods.txt` and set
   `GuiConsoleEnabled = 0` in `UE4SS-settings.ini`.
3. Start the game with your screen reader running.

See `docs/install-state.md` for the exact deployed layout.

## Updates

When the game starts, the mod asks GitHub whether a newer version is out and
tells you if there is one. **F5** checks again at any time. To install an
update, press **F5 twice**: the mod closes the game (without saving), and the
installer downloads and installs the new version and starts the game again.
This needs `OP1AccessInstaller.exe` in `Mods\OP1Access`, where the installer and
the ZIP put it; without it, F5 opens the download page instead. You can also run
the installer again at any time; it updates the mod and itself. The check sends
one request to the GitHub API and nothing else.

## Uninstalling

Open *Installed apps* in the Windows settings and uninstall *OP1 Access*, or
start the installer and choose *Uninstall*. You are asked whether to remove
UE4SS as well; keep it if you use other UE4SS mods for Octopath Traveler.

By hand: in `Octopath_Traveler\Binaries\Win64`, delete the folder
`Mods\OP1Access` and `phonon.dll`. To remove UE4SS as well, delete
`dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini` and the folder `Mods`.

## Hotkeys

### Global

| Key | Action |
|-----|--------|
| **F5** | Check for an update; press twice to install a newer version |
| **Page Up / Page Down** | On the world map (main menu, Weltkarte): every place the map shows, nearest first, with its direction; the map's cursor goes there, so Enter fast travels to a visited town |
| **Home / End** | On the world map: go through the eight regions (and back to the places the map shows); Page Up/Down then name every place of that region, also the ones not discovered yet |
| **Ctrl + Backspace** | On the world map: the route to the place picked with Page Up/Down, area by area; in the field the exit on that route then says "on the way to …" |
| **Ctrl + F10** | Announce the menu / screen you are currently on |
| **Ctrl + F11** | *(dev)* Dump UHT-compatible headers to `UHTHeaderDump/` |
| **Ctrl + F12** | *(dev)* Dump all live objects to `UE4SS_ObjectDump.txt` |

Everything else is automatic: screens and menus are announced as they open, the
highlighted entry is read as you move through title menus, and system dialogs
are read out (caption, body, and button labels). Shops and inns are read too. When you
face someone, you hear which path actions you can use on them and whether one is done
already; the path-action screens of all eight travelers are read.
Money is spoken as a word in the game's language ("50 Blätter"). The game itself
only shows a ⑳ sign, which screen readers can't read.

## Main menu (pause menu)

Open it with the game's menu button (Escape). The left-hand **category list**
(Map, Journal, Inventory, Equipment, Status, Other, …) is read as you move
through it; categories you can't open are announced as **“disabled”** (or
**“Unavailable”** for ones still locked/unrevealed).

The current **objective** — the “Aufgabe” panel shown on the menu — is read
automatically when the menu opens (right after the first category), and you can
re-read it at any time with the hotkey below.

| Key | Action |
|-----|--------|
| **Q** | Read the current objective |

## Character-select screen ("Choose your character")

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

## Building from source

Requirements: Visual Studio 2022 or newer with the C++ workload (it brings
CMake and Ninja; Prism needs a C++23 compiler), Git, PowerShell 7, and the
.NET 8 SDK for the installer.

1. Fetch the pinned dependencies into `tools\`:
   ```
   pwsh scripts\fetch-deps.ps1
   ```
2. Install UE4SS 3.0.1 into the game (the installer does it, or extract
   `tools\UE4SS_v3.0.1.zip` into `Octopath_Traveler\Binaries\Win64`) and add
   `OP1Access : 1` to `Win64\Mods\mods.txt`.
3. Build the shim and copy it into the game. The game must be closed:
   ```
   scripts\build-shim.cmd
   ```
   This builds Prism as a static library and `OP1AccessShim.dll`, checks that
   `main.lua` compiles, and copies the shim, `phonon.dll` and Prism's license
   notices into the game.
4. Copy the Lua mod into place; the build script does **not** deploy it:
   ```
   copy scripts\Mods\OP1Access\Scripts\main.lua "…\Win64\Mods\OP1Access\Scripts\main.lua"
   ```

A copy built like this has no `buildinfo.lua`, so it doesn't check for updates.
To build a release the way the CI does, run `pwsh scripts\build-release.ps1`.
It writes `dist\OP1Access-<version>.zip`, `dist\OP1AccessInstaller.exe` and
`dist\SHA256SUMS.txt`. More about the build, the installer and the packages is
in [docs/build-and-release.md](docs/build-and-release.md).

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

- The Lua mod currently emits **verbose diagnostic logging** to `UE4SS.log`
  (`CS:` cursor traces, `KEY` press logs, anchor reads, etc.). This is
  intentional while the character-select work is being tuned and will be quieted
  later.
- `docs/sdk-dump-procedure.md` covers capturing hook targets; the flat object
  dump (`UE4SS_ObjectDump.txt`) is the source of truth for Blueprint property
  names, offsets, and types.
- `build-shim.cmd` links a `luac.exe` (`build\shim\luac.exe`) from UE4SS's
  Lua sources and checks `main.lua` with it; run it again by hand after editing
  (`build\shim\luac.exe -p scripts\Mods\OP1Access\Scripts\main.lua`).

## Repo layout

```
docs/         design docs, investigation reports, install state, build and release
src/          C++ shim source (statically links Lua 5.4 and Prism; Speech.cpp)
scripts/      the Lua mod (Mods/OP1Access/), build-shim.cmd and the release scripts
installer/    OP1AccessInstaller (.NET Framework 4.8, WinForms)
packaging/    README and third-party notices of the release ZIP
.github/      CI and release workflows
tools/        build dependencies from fetch-deps.ps1 (gitignored)
dist/         release builds (gitignored)
```

## License

Mod code: **MIT** (see `LICENSE`).
Prism: **MPL-2.0**, built unmodified from upstream and statically linked — see
`THIRD_PARTY_LICENSES.md`.
