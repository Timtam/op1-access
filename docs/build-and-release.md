# Build, release and installer

Notes for working on the build, the installer and the release workflows. User-facing instructions
are in the README.

## Dependencies

`scripts/fetch-deps.ps1` fills `tools\` (or `-Tools <folder>`) with everything the build needs,
pinned:

- Lua 5.4: UE4SS's own copy (`deps\first\LuaRaw`, with its `lua_lock`), a sparse checkout of
  RE-UE4SS at commit 265115c. It must be UE4SS's Lua because the shim runs on UE4SS's Lua state.
- Prism at commit a5fec84 (also `PRISM_REF` in `build-shim.cmd`), MinHook at 05c06c5.
- `miniaudio.h` 0.11.25 and the Steam Audio 4.8.1 SDK (only `include\` and `lib\windows-x64\`),
  checked against their SHA-256.
- `UE4SS_v3.0.1.zip` (SHA-256) and the license texts of UE4SS and Steam Audio in `tools\licenses`.

Git sources are fetched at their commit without history. What is there already is kept, so after
changing a pin, delete that folder locally. The workflows cache `tools\` keyed on the script's hash,
so a new pin fetches again there.

## Building

`scripts\build-shim.cmd` builds Prism as a static library (CMake and Ninja from Visual Studio, C++23)
and `OP1AccessShim.dll` with Lua, Prism, MinHook and miniaudio linked in (`phonon.dll` stays a DLL
next to the game EXE). It also links a `luac.exe` from the same Lua objects and runs `luac -p` on
`main.lua`, so a syntax error fails the build. Without arguments it copies the shim, `phonon.dll` and
Prism's notices into the game; `--no-deploy` only builds. `OP1_TOOLS` points it at another
`tools\` folder, for example the main checkout's when building in a worktree.

`Directory.Build.props` holds the version (`ModVersion`) of the mod and the installer and generates a
`BuildInfo` class with `Version` and `RepositorySlug` for the installer. The CI passes
`-p:RepositorySlug=<owner/name>`; local builds have none.

## Release packages

`scripts\build-release.ps1 [-RepositorySlug owner/name] [-Tools <folder>]` runs `fetch-deps.ps1`,
`build-shim.cmd --no-deploy`, builds the installer and runs `scripts\package.ps1`, which writes:

- `dist\OP1Access-<version>.zip`. Its root is the game folder, so everything lands in
  `Octopath_Traveler\Binaries\Win64`: UE4SS 3.0.1 from the pinned release (`dwmapi.dll`,
  `UE4SS.dll`, its settings with `GuiConsoleEnabled = 0` and `Mods\` with the stock mods and
  `OP1Access : 1` in `mods.txt`), `phonon.dll`, and `Mods\OP1Access` with `Scripts\main.lua`,
  `Scripts\OP1AccessShim.dll` (checked to be 64-bit), `Scripts\buildinfo.lua`, the `Assets`, the
  installer, `README.txt`, `LICENSE.txt`, `THIRD-PARTY-NOTICES.txt` and `licenses\` (UE4SS, Steam
  Audio, Lua, MinHook, Prism's LICENSE, NOTICE and LICENSES).
- `dist\OP1AccessInstaller.exe`, always with this name, so that
  `releases/latest/download/OP1AccessInstaller.exe` is the newest installer.
- `dist\SHA256SUMS.txt`.

`Scripts\buildinfo.lua` is `return { version = "x.y.z", repo = "owner/name", ue4ss = "3.0.1" }`. The
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
2. UE4SS is copied if `dwmapi.dll` or `UE4SS.dll` is missing. If they differ from the package's
   (another UE4SS build), they are replaced only after asking (`--replace-ue4ss` in silent mode).
   Stock mods, `UE4SS-settings.ini` and `mods.txt` are only added when missing.
3. `Mods\OP1Access` is replaced. Sounds in `Assets` that the user changed or added stay: the
   installer writes the hashes of the sounds it installed to `Mods\OP1Access\shipped-assets.txt`,
   and on the next update a sound that matches neither that list nor the new package is the
   user's.
4. `phonon.dll` goes next to the game EXE. `UE4SS-settings.ini` gets `GuiConsoleEnabled = 0` in
   `[Debug]` (the console window takes the focus from the game), `mods.txt` the line
   `OP1Access : 1`. Everything else stays as it is.
5. The installer copies itself into `Mods\OP1Access` (unless the package brought a newer one) and
   writes the uninstall entry.

Uninstalling removes `Mods\OP1Access`, `phonon.dll` and the `mods.txt` line, and, if asked, UE4SS
(`dwmapi.dll`, `UE4SS.dll`, its settings, log and the stock mods; folders of other mods stay).

The copy in `Mods\OP1Access` cannot replace or delete itself. It copies itself to
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

Command line:

| Option | Meaning |
| --- | --- |
| `--game <folder>` | The Octopath Traveler folder (with `Octopath_Traveler.exe`) |
| `--zip <file>` | Install this package instead of the release download |
| `--lang de\|en` | Language of the installer (default: Windows display language) |
| `--update [--restart]` | Update window as started by the mod; `--restart` starts the game afterwards |
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

The mod's side of the update can be tested without the game, too: build a `lua.exe` from the LuaRaw
sources, load the shim with `package.loadlib` and run the `Updates` section of `main.lua` with stub
`speak`, `log` and `RegisterKeyBind`, a `buildinfo.lua` naming any repository with releases, and a
program in place of the installer that writes down its command line.
