# Install layout

What a complete installation puts into the game, as of 2026-11-18 (UE4SS 4.0.0). The
installer and the release ZIP produce exactly this; `docs/build-and-release.md` describes how.

## In the game install

Path: `<Steam library>/steamapps/common/OCTOPATH TRAVELER/Octopath_Traveler/Binaries/Win64/`

```
Octopath_Traveler-Win64-Shipping.exe   ← unchanged, the game's own EXE
dwmapi.dll                             ← UE4SS 4's proxy DLL (this is how it injects)
phonon.dll                             ← Steam Audio, next to the EXE so the shim finds it
ue4ss/
  UE4SS.dll                            ← UE4SS core
  UE4SS-settings.ini                   ← stock settings, GuiConsoleEnabled = 0
  UE4SS.log                            ← UE4SS's log, with every [OP1Access] line
  LICENSE, UE4SS_SDK_Backends/         ← as released
  Mods/
    mods.txt                           ← UE4SS's own mods 0, "OP1Access : 1"
    BPML_GenericFunctions/ BPModLoaderMod/ CheatManagerEnablerMod/ ConsoleCommandsMod/
    ConsoleEnablerMod/ Keybinds/ LineTraceMod/ SplitScreenMod/ shared/   (stock, off)
    OP1Access/                         ← the mod
      enabled.txt
      Scripts/main.lua, worldlinks.lua, buildinfo.lua (releases only)
      Scripts/OP1AccessShim.dll        ← speech (Prism), Steam Audio radar, native hooks
      Scripts/lang/*.po, op1access.pot ← the mod's own texts in other languages
      Assets/                          ← radar sounds (your own ones stay on updates)
      logs/                            ← session-1..3.log (the last three game sessions),
                                         last-report.txt; kept on updates
      OP1AccessInstaller.exe, README.txt, LICENSE.txt, THIRD-PARTY-NOTICES.txt, licenses/
```

With a build that has the Static Forms key, the installer also writes the Start menu entry
*OP1 Access – Problem melden* (*OP1 Access - Report a problem*), in the user's own Start menu
programs folder; uninstalling removes it.

The mod finds its own folder from `main.lua`'s path (`M.MOD_DIR`). It needs UE4SS 4.0.0 or
newer (its game-thread timers); with an older UE4SS it logs that and doesn't start.

## In this repo

```
scripts/Mods/OP1Access/        the mod (Scripts/main.lua, worldlinks.lua, lang/, Assets/)
src/                           the shim (Shim.cpp, Speech.cpp, SpatialAudio.cpp)
installer/OP1AccessInstaller/  the installer (.NET Framework 4.8, WinForms)
scripts/                       build, package and data scripts
tests/lua/                     unit tests of main.lua parts (build-shim.cmd runs them)
installer/OP1AccessInstaller.Tests/  the installer's tests (build-release.ps1 runs them)
tools/                         pinned dependencies (gitignored; scripts/fetch-deps.ps1)
```

## Reversing the install

Use the installer's *Uninstall* (it asks whether to remove UE4SS too), or by hand:

```
$g = '<...>\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64'
Remove-Item "$g\ue4ss\Mods\OP1Access" -Recurse -Force; Remove-Item "$g\phonon.dll" -Force
# and UE4SS itself:
Remove-Item "$g\dwmapi.dll" -Force; Remove-Item "$g\ue4ss" -Recurse -Force
```

The game's own `Octopath_Traveler-Win64-Shipping.exe` is untouched; the install is purely
additive.
