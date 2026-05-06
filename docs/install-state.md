# Current install state

Snapshot of what's been placed where, as of 2026-05-05.

## In this repo (`C:/scripts/op1-accessibility/`)

```
docs/                          design docs, investigation reports, asset listings
src/Shim.cpp                   C++ shim source (placeholder; not yet built)
src/xmake.lua                  build skeleton
scripts/Mods/OP1Access/        canonical copy of the Lua mod
scripts/verify-attach.ps1      task #2 verification harness
third_party/tolk/              Tolk vendor dir (DLLs not yet downloaded)
tools/UE4SS/                   UE4SS v3.0.1 distribution (build artefacts; gitignored)
tools/repak/                   repak v0.2.3 CLI (gitignored)
tools/pak_listing.txt          full 107k-file pak listing (gitignored)
```

## In the game install (deployed; reversible)

Path: `C:/Program Files (x86)/Steam/steamapps/common/OCTOPATH TRAVELER/Octopath_Traveler/Binaries/Win64/`

```
Octopath_Traveler-Win64-Shipping.exe   ← unchanged, the game's own EXE
UE4SS.dll                              ← UE4SS core
dwmapi.dll                             ← UE4SS proxy DLL (this is how it injects)
UE4SS-settings.ini                     ← stock settings
Mods/                                  ← UE4SS mod directory
  mods.txt                             ← mod load list (added: "OP1Access : 1")
  ConsoleEnablerMod/   (default, on)
  ConsoleCommandsMod/  (default, on)
  CheatManagerEnablerMod/ (default, on)
  BPModLoaderMod/      (default, on)
  BPML_GenericFunctions/ (default, on)
  Keybinds/            (default, on)
  ActorDumperMod/      (default, off)
  LineTraceMod/        (default, off)
  SplitScreenMod/      (default, off)
  jsbLuaProfilerMod/   (default, off)
  shared/              (default UE4SS helpers)
  OP1Access/           ← our mod (Scripts/main.lua, enabled.txt)
```

## What's NOT installed yet

- **Tolk DLLs** — `third_party/tolk/` is empty (`.gitignore`'d). Phase 0
  task: download from upstream and copy to
  `Mods/OP1Access/dlls/` in the game install.
- **OP1AccessShim.dll** (the C++ shim) — Phase 0 task: build via xmake
  inside an UE4SS source tree and drop next to Tolk.dll.

The Lua mod runs in "log-only" mode without the shim — it'll write
`[OP1Access]` lines to `UE4SS.log` but won't speak yet. That's the
intended state for task #2.

## Reversing the install

To remove everything we've added to the game folder:

```
$g = 'C:\Program Files (x86)\Steam\steamapps\common\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64'
Remove-Item "$g\dwmapi.dll", "$g\UE4SS.dll", "$g\UE4SS-settings.ini" -Force
Remove-Item "$g\Mods" -Recurse -Force
```

The game's own `Octopath_Traveler-Win64-Shipping.exe` is untouched — the
install is purely additive.
