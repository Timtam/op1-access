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
      OP1AccessInstaller.exe, README.txt, LICENSE.txt, THIRD-PARTY-NOTICES.txt, licenses/
```

UE4SS 3.0.1 (earlier versions of the mod) had everything in `Win64` itself: `UE4SS.dll`,
`UE4SS-settings.ini`, `UE4SS.log` and `Mods/` with the mod in `Mods/OP1Access`. The installer
moves such an installation over. The mod finds its own folder either way (`M.MOD_DIR`, from
`main.lua`'s path).

## In this repo

```
scripts/Mods/OP1Access/        the mod (Scripts/main.lua, worldlinks.lua, lang/, Assets/)
src/                           the shim (Shim.cpp, Speech.cpp, SpatialAudio.cpp)
installer/OP1AccessInstaller/  the installer (.NET Framework 4.8, WinForms)
scripts/                       build, package and data scripts
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
