@echo off
:: build-shim.cmd
::
:: Builds Prism (static library, via CMake) and OP1AccessShim.dll, which links
:: Prism in, then deploys the shim to the game's Mods/OP1Access/Scripts folder.
::
:: Dependencies live in tools\ (gitignored; scripts\fetch-deps.ps1 fetches them).
:: Set OP1_TOOLS to use a tools folder elsewhere, e.g. the main checkout's when
:: building from a worktree.
::
:: --no-deploy builds only (CI, release packages): no copy into the game.

setlocal enabledelayedexpansion

set NO_DEPLOY=
if /I "%~1"=="--no-deploy" set NO_DEPLOY=1

set REPO=%~dp0..
if not defined OP1_TOOLS set "OP1_TOOLS=%REPO%\tools"
set LUASRC=%OP1_TOOLS%\ue4ss-src\deps\first\LuaRaw\src
set LUAINC=%OP1_TOOLS%\ue4ss-src\deps\first\LuaRaw\include
set PRISM_SRC=%OP1_TOOLS%\prism-src
:: Prism is pinned to a commit; bump it here and in the fetch hint below.
set PRISM_REF=a5fec84e3409cc466a98dfef77b1ea1eeb18aaa8
set BUILD=%REPO%\build\shim
set PRISM_BUILD=%REPO%\build\prism
set MINHOOK=%OP1_TOOLS%\minhook
set STEAMAUDIO=%OP1_TOOLS%\steamaudio
set MINIAUDIO=%OP1_TOOLS%\miniaudio
set SHIM_OUT=%BUILD%\OP1AccessShim.dll
set GAME_MODS=C:\Program Files (x86)\Steam\steamapps\common\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64\Mods\OP1Access
:: Win64 (game exe dir) -- phonon.dll must live here so the shim's implicit
:: dependency on it resolves at load time (Scripts\ is NOT on the DLL search path).
for %%I in ("%GAME_MODS%\..\..") do set "GAME_BIN=%%~fI"

if not exist "%LUASRC%\lapi.c" (
    echo [build] LuaRaw sources not found at "%LUASRC%". Run the UE4SS source clone first.
    exit /b 1
)
if not exist "%PRISM_SRC%\include\prism.h" (
    echo [build] Prism not found at "%PRISM_SRC%". Fetch it:
    echo         git clone https://github.com/ethindp/prism tools\prism-src
    echo         git -C tools\prism-src checkout %PRISM_REF%
    exit /b 1
)
if not exist "%MINHOOK%\src\hook.c" (
    echo [build] MinHook not found at "%MINHOOK%". Fetch it:
    echo         git clone --depth 1 https://github.com/TsudaKageyu/minhook tools\minhook
    exit /b 1
)
if not exist "%STEAMAUDIO%\lib\windows-x64\phonon.lib" (
    echo [build] Steam Audio SDK not found at "%STEAMAUDIO%". Fetch steamaudio_4.8.1.zip from
    echo         github.com/ValveSoftware/steam-audio/releases and copy its include\ and
    echo         lib\windows-x64\ into tools\steamaudio\.
    exit /b 1
)
if not exist "%MINIAUDIO%\miniaudio.h" (
    echo [build] miniaudio.h not found at "%MINIAUDIO%". Fetch it from
    echo         raw.githubusercontent.com/mackron/miniaudio/master/miniaudio.h
    exit /b 1
)

set VSWHERE=C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe
if not exist "%VSWHERE%" (
    echo [build] vswhere.exe not found.
    exit /b 1
)
for /f "usebackq tokens=*" %%i in (`"%VSWHERE%" -latest -property installationPath`) do set VSPATH=%%i
if "%VSPATH%"=="" (
    echo [build] vswhere reported no VS installation.
    exit /b 1
)
echo [build] Using VS at: %VSPATH%

call "%VSPATH%\VC\Auxiliary\Build\vcvars64.bat" >nul
if errorlevel 1 (
    echo [build] vcvars64 failed.
    exit /b 1
)
:: Visual Studio ships CMake and Ninja; vcvars64 puts both on PATH.
where cmake >nul 2>&1 || (
    echo [build] cmake not found. Install the "C++ CMake tools for Windows" VS component.
    exit /b 1
)

if not exist "%BUILD%" mkdir "%BUILD%"
if not exist "%BUILD%\shim_obj" mkdir "%BUILD%\shim_obj"

:: ---------------------------------------------------------------------
:: Step 1: Build Prism as a static library. /MD (MultiThreadedDLL) to match
:: the shim -- Prism defaults to the static CRT. Prism needs C++23 and
:: bundles all of its dependencies, so no network access is needed.
:: ---------------------------------------------------------------------
echo [build] Building Prism (static)...
cmake -S "%PRISM_SRC%" -B "%PRISM_BUILD%" -G Ninja ^
   -DCMAKE_BUILD_TYPE=Release ^
   -DBUILD_SHARED_LIBS=OFF ^
   -DCMAKE_MSVC_RUNTIME_LIBRARY=MultiThreadedDLL ^
   -DPRISM_IPO=OFF ^
   -DPRISM_ENABLE_GDK_SPEECH_BACKEND=OFF >"%PRISM_BUILD%-configure.log" 2>&1
if errorlevel 1 (
    type "%PRISM_BUILD%-configure.log"
    echo [build] Prism configure failed.
    exit /b 1
)
findstr /C:"Prism backends:" "%PRISM_BUILD%-configure.log"
cmake --build "%PRISM_BUILD%" --target prism
if errorlevel 1 (
    echo [build] Prism build failed.
    exit /b 1
)
echo [build] Built %PRISM_BUILD%\prism.lib

:: ---------------------------------------------------------------------
:: Step 2: Build OP1AccessShim.dll (statically links Lua and Prism).
:: /WHOLEARCHIVE keeps every Prism backend: each one registers itself and
:: nothing references it directly (Prism's own CMake package does the same).
:: ---------------------------------------------------------------------
echo [build] Compiling OP1AccessShim.dll...
pushd "%BUILD%\shim_obj"

set LUASRCS=
for %%F in (lapi.c lauxlib.c lbaselib.c lcode.c lcorolib.c lctype.c ldblib.c ldebug.c ^
            ldo.c ldump.c lfunc.c lgc.c linit.c liolib.c llex.c lmathlib.c lmem.c ^
            loadlib.c lobject.c lopcodes.c loslib.c lparser.c lstate.c lstring.c ^
            lstrlib.c ltable.c ltablib.c ltm.c luauser.c lundump.c lutf8lib.c lvm.c lzio.c) do (
    set LUASRCS=!LUASRCS! "%LUASRC%\%%F"
)

cl /nologo /MD /O2 /EHsc /std:c++20 /DPRISM_STATIC ^
   /I"%LUAINC%" /I"%LUASRC%" /I"%MINHOOK%\include" /I"%MINHOOK%\src\hde" ^
   /I"%STEAMAUDIO%\include" /I"%MINIAUDIO%" ^
   /I"%PRISM_SRC%\include" /I"%PRISM_BUILD%\generated\include" ^
   "%REPO%\src\Shim.cpp" "%REPO%\src\Speech.cpp" "%REPO%\src\SpatialAudio.cpp" %LUASRCS% ^
   "%MINHOOK%\src\buffer.c" "%MINHOOK%\src\hook.c" "%MINHOOK%\src\trampoline.c" ^
   "%MINHOOK%\src\hde\hde32.c" "%MINHOOK%\src\hde\hde64.c" ^
   /link /DLL ^
   /OUT:"%SHIM_OUT%" ^
   /IMPLIB:"%BUILD%\OP1AccessShim.lib" ^
   /WHOLEARCHIVE:"%PRISM_BUILD%\prism.lib" ^
   advapi32.lib user32.lib gdi32.lib ole32.lib oleaut32.lib uuid.lib shell32.lib ^
   onecore.lib runtimeobject.lib uiautomationcore.lib rpcrt4.lib xaudio2.lib powrprof.lib ^
   winhttp.lib "%STEAMAUDIO%\lib\windows-x64\phonon.lib"

if errorlevel 1 (
    echo [build] Shim build failed.
    popd
    exit /b 1
)
echo [build] Built %SHIM_OUT%

:: luac from the same Lua objects: main.lua must at least compile (UE4SS only says so in its
:: log when the game starts).
set LUAOBJS=
for %%F in (%LUASRCS%) do set LUAOBJS=!LUAOBJS! "%%~nF.obj"
cl /nologo /MD /O2 /I"%LUAINC%" /I"%LUASRC%" "%LUASRC%\luac.c" %LUAOBJS% /Fe:"%BUILD%\luac.exe" >"%BUILD%\luac-build.log" 2>&1
if errorlevel 1 (
    type "%BUILD%\luac-build.log"
    echo [build] luac build failed.
    popd
    exit /b 1
)
popd
"%BUILD%\luac.exe" -p "%REPO%\scripts\Mods\OP1Access\Scripts\main.lua"
if errorlevel 1 (
    echo [build] main.lua does not compile.
    exit /b 1
)
echo [build] main.lua compiles.
if defined NO_DEPLOY (
    echo [build] Done ^(--no-deploy^).
    exit /b 0
)

:: ---------------------------------------------------------------------
:: Step 3: Deploy
:: ---------------------------------------------------------------------
copy /Y "%SHIM_OUT%" "%GAME_MODS%\Scripts\OP1AccessShim.dll" >nul || (
    echo [build] Copy SHIM failed.
    exit /b 1
)
copy /Y "%STEAMAUDIO%\lib\windows-x64\phonon.dll" "%GAME_BIN%\phonon.dll" >nul || (
    echo [build] Copy phonon.dll failed.
    exit /b 1
)
:: Speech used to go through Tolk.dll and its bridge DLLs; Prism is linked in now.
for %%D in (Tolk.dll nvdaControllerClient64.dll SAAPI64.dll) do (
    if exist "%GAME_MODS%\Scripts\%%D" del /Q "%GAME_MODS%\Scripts\%%D"
)
:: Prism is MPL-2.0 and bundles third-party code: ship its notices with the mod.
if not exist "%GAME_MODS%\licenses\prism" mkdir "%GAME_MODS%\licenses\prism"
copy /Y "%PRISM_SRC%\LICENSE" "%GAME_MODS%\licenses\prism\LICENSE" >nul
copy /Y "%PRISM_SRC%\NOTICE" "%GAME_MODS%\licenses\prism\NOTICE" >nul
xcopy /E /I /Y /Q "%PRISM_SRC%\LICENSES" "%GAME_MODS%\licenses\prism\LICENSES" >nul
:: Assets folder for custom cue sounds: ensure it exists + ship the README (never clobber user files)
if not exist "%GAME_MODS%\Assets" mkdir "%GAME_MODS%\Assets"
if exist "%REPO%\scripts\Mods\OP1Access\Assets\README.md" copy /Y "%REPO%\scripts\Mods\OP1Access\Assets\README.md" "%GAME_MODS%\Assets\README.md" >nul
echo [build] Deployed to: "%GAME_MODS%\Scripts"
echo [build] Done.
