# Third-party components

`scripts/fetch-deps.ps1` fetches all of them into `tools\` at pinned versions and
checks the downloads against their SHA-256. `scripts/package.ps1` puts their license
texts into the release ZIP (`Mods/OP1Access/licenses/`) and lists them in
`THIRD-PARTY-NOTICES.txt` (from `packaging/THIRD-PARTY-NOTICES.txt`).

## UE4SS

- Source: https://github.com/UE4SS-RE/RE-UE4SS (release 3.0.1)
- License: MIT
- Use: the release ZIP and the installer ship the official UE4SS 3.0.1 files
  (`dwmapi.dll`, `UE4SS.dll`, `UE4SS-settings.ini`, the `Mods` folder) unchanged,
  except `GuiConsoleEnabled = 0` in the settings. The installer leaves an existing
  UE4SS 3.0.1 in place. The mod's Lua scripts and `OP1AccessShim.dll` run inside it.

## Prism

- Source: https://github.com/ethindp/prism (pinned commit: `PRISM_REF` in
  `scripts/build-shim.cmd`, `$PrismCommit` in `scripts/fetch-deps.ps1`)
- License: MPL-2.0. Prism bundles code under other permissive licenses (fmt,
  simdutf, Highway, concurrentqueue, dr_wav, moderncom, parts of NVGT) and the
  NVDA Controller Client RPC interface, which its copyright holder relicensed
  to Prism under MPL-2.0. Details are in Prism's `NOTICE` and `LICENSES/`.
- Use: built from unmodified upstream source as a static library and linked
  into `OP1AccessShim.dll`. MPL-2.0 is file-level copyleft, so linking it into
  the MIT-licensed shim is fine. What it asks of us when we distribute the
  shim: point recipients to Prism's source (the repository above, at the
  pinned commit) and ship its notices. `build-shim.cmd` copies `LICENSE`,
  `NOTICE` and `LICENSES/` to `Mods/OP1Access/licenses/prism/` on deploy, and the
  release ZIP has them in the same place. If we ever patch Prism, the changed files
  must be published under MPL-2.0 too.
- Prism replaced Tolk (LGPL-3.0), which had to stay a separate DLL and needed
  `nvdaControllerClient64.dll` / `SAAPI64.dll` next to it.

## Steam Audio

- Source: https://github.com/ValveSoftware/steam-audio (SDK 4.8.1)
- License: Apache 2.0
- Use: the shim links `phonon.lib` and loads `phonon.dll`, which ships unchanged from
  the official SDK next to the game's exe (`Binaries/Win64`). It places the radar's
  sounds in 3D (HRTF).

## Lua 5.4

- Source: UE4SS's own copy (`deps/first/LuaRaw` in the UE4SS sources, pinned commit
  in `scripts/fetch-deps.ps1`). It has to be UE4SS's Lua, with its `lua_lock`, because
  the shim runs on UE4SS's Lua state.
- License: MIT
- Use: compiled into `OP1AccessShim.dll`; `build-shim.cmd` also builds `luac.exe`
  from it to check `main.lua`.

## MinHook

- Source: https://github.com/TsudaKageyu/minhook (pinned commit in
  `scripts/fetch-deps.ps1`)
- License: BSD 2-Clause
- Use: compiled into `OP1AccessShim.dll` to hook game functions natively (the
  dialogue text, which Lua hooks can't read).

## miniaudio

- Source: https://github.com/mackron/miniaudio (0.11.25, `miniaudio.h`)
- License: public domain or MIT No Attribution, at your choice
- Use: compiled into `OP1AccessShim.dll`; it plays the radar's sounds.
