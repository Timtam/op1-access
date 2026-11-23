OP1 Access {VERSION}
====================

A screen reader accessibility mod for the Steam version of Octopath Traveler.
Instructions, keys and updates: {PROJECT_URL}

Files in this folder
- Scripts\main.lua: the mod (a UE4SS Lua mod). Scripts\worldlinks.lua: the links between the
  areas, for the world map's route finder. Scripts\lang: the mod's texts in other languages
  (German so far); the mod follows the game's text language.
- Scripts\OP1AccessShim.dll: speech and braille through your screen reader (Prism), the 3D radar
  sounds (Steam Audio) and the game hooks. Scripts\buildinfo.lua holds the version.
- Assets: the radar sounds. You can put your own there, see Assets\README.md; the installer keeps
  them on updates.
- OP1AccessInstaller.exe: installs, updates and removes the mod. The mod starts it when you press
  F5 twice to install an update, and when you press F1 twice to report a problem.
- logs: the mod's logs of the last three game sessions, for problem reports (see logs\README.txt).
- LICENSE.txt: the license of OP1 Access (MIT).
- THIRD-PARTY-NOTICES.txt and the licenses folder: licenses of the software that comes with the
  mod.

Requirements
- Octopath Traveler from Steam, on Windows 10 or 11.
- A screen reader (NVDA, JAWS and others), or Windows' own voices.
- The Microsoft Visual C++ Redistributable (x64); Steam installs it with the game.

Manual installation
Extract OP1Access-{VERSION}.zip into the Octopath Traveler folder, the one with
Octopath_Traveler.exe. In Steam, open the context menu of Octopath Traveler and choose Manage,
Browse local files to find it. Everything lands in Octopath_Traveler\Binaries\Win64: UE4SS
{UE4SS_VERSION} (dwmapi.dll there, and the folder ue4ss with UE4SS.dll, UE4SS-settings.ini and
Mods), phonon.dll, and the mod in ue4ss\Mods\OP1Access. If UE4SS 4 is installed already,
ue4ss\Mods\OP1Access and phonon.dll are enough; add the line "OP1Access : 1" to
ue4ss\Mods\mods.txt and set "GuiConsoleEnabled = 0" in ue4ss\UE4SS-settings.ini (UE4SS's console
window would take the focus away from the game).
Start the game with your screen reader running. You hear "OP1 Access loaded" ("OP1 Access
geladen" when the game's text language is German).

Updates
The mod tells you when a new version is out. Press F5 twice to install it: the game closes, the
installer updates the mod and starts the game again.

Reporting a problem
Press F1 twice in the game, or choose "Report a problem" in the installer or "OP1 Access - Report
a problem" in the Start menu. Describe what happened and choose what to attach: the mod's session
logs, UE4SS.log and, if you want, the game's crash dumps. Your Windows user name, computer name
and Steam ID are removed from the logs first; crash dumps can't be cleaned, so they only go along
when you check them. The report goes by e-mail to the developer through the form service Static
Forms (staticforms.dev).

Uninstalling
Use "OP1 Access" in Installed apps, or start OP1AccessInstaller.exe and choose Uninstall. By hand:
delete the folder ue4ss\Mods\OP1Access and phonon.dll in Octopath_Traveler\Binaries\Win64. To
remove UE4SS as well, delete dwmapi.dll and the folder ue4ss there.

License
Copyright (c) 2026 OP1Access contributors. OP1 Access is free software under the MIT License,
without any warranty; see LICENSE.txt. The source code is at {PROJECT_URL}.
Octopath Traveler is a game by Square Enix. OP1 Access is unofficial and not affiliated with it.
