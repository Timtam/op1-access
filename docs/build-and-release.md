# Build, release and installer

Notes for working on the build, the installer and the release workflows. User-facing instructions
are in the README.

## Dependencies

`scripts/fetch-deps.ps1` fills `tools\` (or `-Tools <folder>`) with everything the build needs,
pinned:

- Lua 5.4.7: UE4SS's own copy (`deps\first\LuaRaw`, with its `lua_lock`), a sparse checkout of
  RE-UE4SS at the v4.0.0 release (30afe5f). It must be UE4SS's Lua because the shim runs on UE4SS's
  Lua state. UE4SS's `lua_lock` is one critical section for all its Lua states; the shim's copy has
  its own, so the shim's functions never raise a Lua error (that would leave UE4SS's lock
  unbalanced: c0000264), and under UE4SS 4 the mod runs all its Lua on the game thread.
- Prism at commit a5fec84 (also `PRISM_REF` in `build-shim.cmd`), MinHook at 05c06c5.
- `miniaudio.h` 0.11.25 and the Steam Audio 4.8.1 SDK (only `include\` and `lib\windows-x64\`),
  checked against their SHA-256.
- `UE4SS_v4.0.0.zip` (SHA-256) and the license texts of UE4SS and Steam Audio in `tools\licenses`.

Git sources are fetched at their commit without history. What is there already is kept, so after
changing a pin, delete that folder locally. The workflows cache `tools\` keyed on the script's hash,
so a new pin fetches again there.

## Building

`scripts\build-shim.cmd` builds Prism as a static library (CMake and Ninja from Visual Studio, C++23)
and `OP1AccessShim.dll` with Lua, Prism, MinHook and miniaudio linked in (`phonon.dll` stays a DLL
next to the game EXE). It also links a `luac.exe` from the same Lua objects and runs `luac -p` on
`main.lua`, so a syntax error fails the build. Without arguments it copies the shim, `phonon.dll` and
Prism's notices into the game (`Win64\ue4ss\Mods\OP1Access`; `GAME_BIN` sets another Win64
folder); `--no-deploy` only builds.
`OP1_TOOLS` points it at another `tools\` folder, for example the main checkout's when building in
a worktree.

`Directory.Build.props` holds the version (`ModVersion`) of the mod and the installer and generates a
`BuildInfo` class with `Version` and `RepositorySlug` for the installer. The CI passes
`-p:RepositorySlug=<owner/name>`; local builds have none.

The installer's Static Forms key for problem reports comes from the environment variable
`OP1_STATICFORMS_KEY` at build time, never from a file of the repository: set it on your own
computer (user environment variables) to build with it; the release workflow sets it from the
repository secret `STATICFORMS_KEY`. `OP1AccessInstaller.csproj` writes it, scrambled, into
`obj\...\ReportKey.g.cs` (ignored by git, like any `ReportKey.g.cs`); the build log only says
"Problem reports: form key built in" or "no form key". Without it the report function is off:
the installer's button is greyed out with a line saying why, `--report` says so in a message box,
and `package.ps1` writes `report = false` into `buildinfo.lua`, so the mod's F1 says so too.

Tests: `build-shim.cmd` also links a `lua.exe` and runs `tests\lua\*.lua` (parts of `main.lua`
loaded on their own with stubs); `build-release.ps1` builds and runs
`installer\OP1AccessInstaller.Tests` (a console program: the ALTCHA solver, the Static Forms
client against a stand-in server on 127.0.0.1, cleaning and packing of the attachments). Run in
the same environment as the build, its key test checks that the built-in key matches
`OP1_STATICFORMS_KEY` and is not readable as plain text in the EXE (it never prints the key).

## Game data the mod ships

`Scripts/worldlinks.lua` holds which area leads where, for the world map's route finder:
level name -> the level IDs its exits lead to. The game has no such table; every exit is a
LevelTrigger in its level with `m_nNextMapID`. `scripts/level-links.py` reads them from the
cooked area levels after extracting `Octopath_Traveler/Content/Level/Area` with repak (the
script's header has both commands). Only numbers and level names, no game text. Run it
again if a game update changes the levels.

## Release packages

`scripts\build-release.ps1 [-RepositorySlug owner/name] [-Tools <folder>]` runs `fetch-deps.ps1`,
`build-shim.cmd --no-deploy`, builds the installer and runs `scripts\package.ps1`, which writes:

- `dist\OP1Access-<version>.zip`. Its root is the game folder, so everything lands in
  `Octopath_Traveler\Binaries\Win64`: UE4SS 4.0.0 from the pinned release (`dwmapi.dll` there,
  and `ue4ss\` with `UE4SS.dll`, its settings with `GuiConsoleEnabled = 0` and `Mods\` with the
  stock mods switched off and `OP1Access : 1` in `mods.txt`), `phonon.dll`, and
  `ue4ss\Mods\OP1Access` with `Scripts\main.lua`,
  `Scripts\OP1AccessShim.dll` (checked to be 64-bit), `Scripts\buildinfo.lua`, the `Assets`, the
  installer, `README.txt`, `LICENSE.txt`, `THIRD-PARTY-NOTICES.txt` and `licenses\` (UE4SS, Steam
  Audio, Lua, MinHook, Prism's LICENSE, NOTICE and LICENSES).
- `dist\OP1AccessInstaller.exe`, always with this name, so that
  `releases/latest/download/OP1AccessInstaller.exe` is the newest installer.
- `dist\SHA256SUMS.txt`.

`Scripts\buildinfo.lua` is `return { version = "x.y.z", repo = "owner/name", ue4ss = "4.0.0" }`. The
mod checks for updates only when it exists and names a repository, so development copies stay quiet.
The installer reads the installed version from it ("dev" if only `main.lua` is there).

`scripts\release-prepare.ps1` sets the version and rolls the changelog (see "Releasing" in the
README). `-Root` lets it work on a copy.

## Installer

.NET Framework 4.8 and WinForms, one EXE, no administrator rights: Steam libraries are writable for
the user, and the uninstall entry is per user (HKCU, `...\Uninstall\OP1Access`). Only standard
controls. The window has the dialog role, so screen readers read its texts when it opens. Progress
goes to a label that is a UIA live region. Questions and results are message boxes. English and
German, after the Windows display language or `--lang`.

Game folder: `--game`, else the folder of the last installation (value `GameFolder` of the uninstall
entry), else the Steam libraries (registry, `libraryfolders.vdf`, `appmanifest_921570.acf`), else
the user selects `Octopath_Traveler.exe`.

Installing:

1. The package is the `--zip` file, else the newer of the latest release's ZIP (downloaded) and an
   `OP1Access-*.zip` next to the installer.
2. UE4SS 4 is copied if `dwmapi.dll` or `ue4ss\UE4SS.dll` is missing. Another UE4SS 4 build is
   replaced only after asking (`--replace-ue4ss` in silent mode); if it stays, the mod goes into
   its `ue4ss\Mods` folder all the same. Stock mods, `UE4SS-settings.ini` and `mods.txt` are only
   added when missing. A UE4SS 3 (`UE4SS.dll` right in `Win64`) isn't looked for: the mod needs
   UE4SS 4.
3. `ue4ss\Mods\OP1Access` is replaced. Sounds
   in `Assets` that the user changed or added stay: the installer writes the hashes of the sounds
   it installed to `shipped-assets.txt` in the mod folder, and on the next update a sound that
   matches neither that list nor the new package is the user's.
4. `phonon.dll` goes next to the game EXE. `ue4ss\UE4SS-settings.ini` gets `GuiConsoleEnabled = 0`
   in `[Debug]` (the console window takes the focus from the game), `mods.txt` the line
   `OP1Access : 1`. Everything else stays as it is.
5. The installer copies itself into the mod folder (unless the package brought a newer one) and
   writes the uninstall entry.

Uninstalling removes the mod folder (`ue4ss\Mods\OP1Access`), `phonon.dll` and the `mods.txt`
line, and, if asked, UE4SS (`dwmapi.dll`, the `ue4ss` folder's `UE4SS.dll`, settings, log and
stock mods; folders of other mods stay).

After changing `GameInstall.cs`, try it on a fake game folder (a dummy `Octopath_Traveler.exe`
and an `Octopath_Traveler\Binaries\Win64` folder): `--silent --install --game <folder> --zip
<package> --no-registry`, once fresh, once again (with a sound of your own in the mod's
`Assets`), once over another UE4SS build (a changed `ue4ss\UE4SS.dll`, with and without
`--replace-ue4ss`), then `--silent --uninstall`, with and without `--remove-ue4ss`.

The copy in the mod folder cannot replace or delete itself. It copies itself to
`%TEMP%\OP1AccessInstaller\` and starts that copy with the same arguments plus `--relaunched`. If
the latest release has a newer installer, the installer downloads it and hands over
(`--no-self-update` prevents loops). The game counts as running only if
`Octopath_Traveler-Win64-Shipping.exe` or `Octopath_Traveler.exe` from the chosen folder runs.

Updating from the game: when the mod loads, it asks
`api.github.com/repos/<repo>/releases/latest` on a shim thread (WinHTTP) and announces a newer
`tag_name`. F5 checks again; F5 twice starts
`OP1AccessInstaller.exe --update --restart --game <folder>` and closes the game 1.5 s later (a shim
thread posts `WM_CLOSE` to the game window). The installer downloads the release, waits until the
game has ended (the *Close game* button helps), installs, and starts the game with
`steam://rungameid/921570`. If something fails, it asks whether to start the game anyway. Without
the installer, the mod opens the release page.

Problem reports: `--report` (F1 twice in the game; the installer's *Report a problem* button; the
Start menu entry, written on installation by builds with the key) opens `ReportForm`: a
description, an optional e-mail address (sent as `replyTo`), a checked list of attachments, a
note on privacy, the system information that goes along (versions, Windows, languages, the speech
backend from the session log) and *Send*. Standard controls; progress in a live region.

- Attachments (`ProblemReport.Collect`): `ue4ss\UE4SS.log` (readable while the game runs:
  `FileShare.ReadWrite`), the mod's `logs\session-1..3.log`, `%TEMP%\OP1AccessInstaller.log` (a
  report run adds to it instead of starting it over), and the game's crash reports
  (`Documents\My Games\Octopath_Traveler\Crashes\UE4CC-Windows-*\UE4Minidump.dmp` with
  `CrashContext.runtime-xml`) newer than `logs\last-report.txt` (else of the last 14 days), the
  newest three, not checked at first. UE4SS's own `Win64\crash_*.dmp` (about 25 MB) are left out.
- Cleaning (`Scrubber`): profile paths `X:\Users\<name>` in every spelling, the user name and the
  computer name as words, Steam IDs (17 digits starting with 7656119) and the crash context's
  `MachineId`, `LoginId`, `EpicAccountId` and `UserName`. Dumps can't be cleaned.
- Packing (`ProblemReport.Build`): `report.txt` (everything of the report) and the attachments in
  one ZIP of at most 4,000,000 bytes (Static Forms takes 4.5 MB per submission). A long log keeps
  its first 128 KB and as much of its end as fits (from 6 MB down to 160 KB, with a note where
  lines are missing); then the oldest attachments are left out, and the report says which.
- Sending (`StaticFormsClient`): the challenge from
  `https://www.staticforms.dev/api/altcha/challenge?apiKey=<key>` (10 a minute per key), solved by
  `Altcha` (classic ALTCHA, as the ALTCHA widget 2.x on Static Forms' page: the number n up to
  `maxnumber` with hex(SHA-256(salt + n)) = `challenge`, on all cores, about half a second for a
  million), then `multipart/form-data` to `https://api.staticforms.dev/submit` with `apiKey`,
  `subject`, `message`, `replyTo`, `system`, `attachments`, `altchaToken` (base64 of
  `{"algorithm","challenge","number","salt","signature","took"}`) and the ZIP as `report`, with
  `Accept: application/json`. Errors come as `{"error": ...}`: 400 refused, 401 wrong key, 403
  spam protection or domain restriction (keep the form's domain restriction off: a desktop
  program sends no Origin), 413 too large, 429 too many (20 a minute, 100 an hour on the Pro
  plan). A form without ALTCHA gets the report without a token. Newer ALTCHA challenges (key
  derivation, `parameters`) are refused with a clear message.
- After sending, `logs\last-report.txt` holds the time, so the next report offers only newer
  crashes. The installer keeps the `logs` folder on updates.

Command line:

| Option | Meaning |
| --- | --- |
| `--game <folder>` | The Octopath Traveler folder (with `Octopath_Traveler.exe`) |
| `--zip <file>` | Install this package instead of the release download |
| `--lang de\|en` | Language of the installer (default: Windows display language) |
| `--update [--restart]` | Update window as started by the mod; `--restart` starts the game afterwards |
| `--report` | The *Report a problem* window (the mod starts it with F1 twice, the Start menu entry too) |
| `--uninstall` | Uninstall with two questions (mod, UE4SS), used by Installed apps |
| `--silent --install` / `--uninstall` / `--detect` / `--check` | Without a window, output on stdout |
| `--remove-ue4ss`, `--replace-ue4ss` | Answers for `--silent` |
| `--no-registry` | No uninstall entry (tests) |
| `--repo <owner/name>` | Another repository for the release check |

Silent exit codes: 0 done, 1 failed, 2 wrong arguments or no game folder, 3 the game is running.
A silent run of the copy in `Mods\OP1Access` returns at once, because the copy in `%TEMP%` does the
work. The log is `%TEMP%\OP1AccessInstaller.log`.

Testing without the game: make a folder with an empty `Octopath_Traveler.exe` and
`Octopath_Traveler\Binaries\Win64\`, and run
`--silent --install --game <folder> --zip dist\OP1Access-<version>.zip --no-registry`, then
`--detect`, `--uninstall` and `--uninstall --remove-ue4ss`. The window itself (focus, live region
announcements, message boxes) needs a person with a screen reader to test it.

A real report needs the key and lands in the developer's mailbox: send one only on purpose. The
tests cover the client without it; the window itself (focus, live region, message boxes) needs a
person with a screen reader.

The mod's side of the update can be tested without the game, too: build a `lua.exe` from the LuaRaw
sources, load the shim with `package.loadlib` and run the `Updates` section of `main.lua` with stub
`speak`, `log` and `RegisterKeyBind`, a `buildinfo.lua` naming any repository with releases, and a
program in place of the installer that writes down its command line.
