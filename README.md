# OP1Access — Octopath Traveler screen-reader accessibility mod

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS)-based mod that adds
screen-reader output to **Octopath Traveler** (PC / Steam, 2019, Unreal Engine
4.18). Menus, system dialogs and the **character-select screen** are spoken
through [Prism](https://github.com/ethindp/prism), so it works with NVDA, JAWS,
ZoomText and other screen readers, and falls back to Windows' own voices
(OneCore / SAPI) when none is running.

> **Status:** early but functional. The title-screen flow, menu/screen
> announcements, system dialogs, and the character-select screen are spoken.
> Battle and overworld support are still in progress. Expect rough edges.

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

1. Install **UE4SS** into
   `…/OCTOPATH TRAVELER/Octopath_Traveler/Binaries/Win64/`. The stock v3.0.1
   release attaches to the 4.18 Shipping build with no patching.
2. Add `OP1Access : 1` to `Win64/Mods/mods.txt`.
3. Build and deploy the speech shim:
   ```
   scripts\build-shim.cmd
   ```
   This builds Prism as a static library (CMake + Ninja, both ship with Visual
   Studio; Prism needs a C++23 compiler) and `OP1AccessShim.dll`, then copies
   the shim into `Win64/Mods/OP1Access/Scripts/` and Prism's license notices
   into `Win64/Mods/OP1Access/licenses/prism/`. No other speech DLLs are
   needed. The script tells you how to fetch any missing dependency into
   `tools\` (Prism goes to `tools\prism-src`, pinned to a commit). Players
   need the current Microsoft Visual C++ Redistributable (x64).
4. Copy the Lua mod into place — it is **not** auto-deployed by the build
   script:
   ```
   copy scripts\Mods\OP1Access\Scripts\main.lua "…\Win64\Mods\OP1Access\Scripts\main.lua"
   ```
5. Launch the game with your screen reader running. You should hear
   **“OP1 Access loaded.”**

See `docs/install-state.md` for the exact deployed layout and how to reverse the
install.

## Hotkeys

### Global

| Key | Action |
|-----|--------|
| **Ctrl + F10** | Announce the menu / screen you are currently on |
| **Ctrl + F11** | *(dev)* Dump UHT-compatible headers to `UHTHeaderDump/` |
| **Ctrl + F12** | *(dev)* Dump all live objects to `UE4SS_ObjectDump.txt` |

Everything else is automatic: screens and menus are announced as they open, the
highlighted entry is read as you move through title menus, and system dialogs
are read out (caption, body, and button labels).

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

## Development notes

- The Lua mod currently emits **verbose diagnostic logging** to `UE4SS.log`
  (`CS:` cursor traces, `KEY` press logs, anchor reads, etc.). This is
  intentional while the character-select work is being tuned and will be quieted
  later.
- `docs/sdk-dump-procedure.md` covers capturing hook targets; the flat object
  dump (`UE4SS_ObjectDump.txt`) is the source of truth for Blueprint property
  names, offsets, and types.
- There is no standalone Lua interpreter in the repo, but a `luac` can be built
  from the bundled Lua 5.4.7 sources to syntax-check `main.lua` before
  deploying (`luac -p main.lua`).

## Repo layout

```
docs/         design docs, investigation reports, install state
src/          C++ shim source (statically links Lua 5.4 and Prism; Speech.cpp)
scripts/      the Lua mod (Mods/OP1Access/) + build-shim.cmd
tools/        UE4SS distribution and build inputs, incl. prism-src (gitignored)
```

## License

Mod code: **MIT** (see `LICENSE`).
Prism: **MPL-2.0**, built unmodified from upstream and statically linked — see
`THIRD_PARTY_LICENSES.md`.
