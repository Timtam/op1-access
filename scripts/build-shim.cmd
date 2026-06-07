@echo off
:: build-shim.cmd
::
:: Builds Tolk.dll and OP1AccessShim.dll, then deploys both plus the
:: required screen-reader bridge DLLs to the game's Mods/OP1Access/Scripts
:: folder.

setlocal enabledelayedexpansion

set REPO=%~dp0..
set LUASRC=%REPO%\tools\ue4ss-src\deps\first\LuaRaw\src
set LUAINC=%REPO%\tools\ue4ss-src\deps\first\LuaRaw\include
set TOLKSRC=%REPO%\tools\tolk-src\src
set BUILD=%REPO%\build\shim
set MINHOOK=%REPO%\tools\minhook
set TOLK_OUT=%BUILD%\Tolk.dll
set SHIM_OUT=%BUILD%\OP1AccessShim.dll
set GAME_MODS=C:\Program Files (x86)\Steam\steamapps\common\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64\Mods\OP1Access
set NVDA_DLL=%REPO%\tools\tolk-src\libs\x64\nvdaControllerClient64.dll
set SAAPI_DLL=%REPO%\tools\tolk-src\libs\x64\SAAPI64.dll

if not exist "%LUASRC%\lapi.c" (
    echo [build] LuaRaw sources not found at "%LUASRC%". Run the UE4SS source clone first.
    exit /b 1
)
if not exist "%TOLKSRC%\Tolk.cpp" (
    echo [build] Tolk sources not found at "%TOLKSRC%".
    exit /b 1
)
if not exist "%NVDA_DLL%" (
    echo [build] nvdaControllerClient64.dll missing at "%NVDA_DLL%".
    exit /b 1
)
if not exist "%MINHOOK%\src\hook.c" (
    echo [build] MinHook not found at "%MINHOOK%". Fetch it:
    echo         git clone --depth 1 https://github.com/TsudaKageyu/minhook tools\minhook
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

if not exist "%BUILD%" mkdir "%BUILD%"
if not exist "%BUILD%\tolk_obj" mkdir "%BUILD%\tolk_obj"
if not exist "%BUILD%\shim_obj" mkdir "%BUILD%\shim_obj"

:: ---------------------------------------------------------------------
:: Step 1: Build Tolk.dll
:: ---------------------------------------------------------------------
echo [build] Compiling Tolk.dll...
pushd "%TOLKSRC%"
cl /nologo /O2 /EHsc /LD /Gw /D_EXPORTING /DUNICODE ^
   /Fo"%BUILD%\tolk_obj\\" ^
   Tolk.cpp ^
   ScreenReaderDriverJAWS.cpp ScreenReaderDriverNVDA.cpp ^
   ScreenReaderDriverSA.cpp ScreenReaderDriverSNova.cpp ^
   ScreenReaderDriverWE.cpp ScreenReaderDriverZT.cpp ^
   ScreenReaderDriverSAPI.cpp ^
   fsapi.c wineyes.c zt.c ^
   /link /OUT:"%TOLK_OUT%" /IMPLIB:"%BUILD%\Tolk.lib" ^
   User32.Lib Ole32.Lib OleAut32.Lib
if errorlevel 1 (
    echo [build] Tolk build failed.
    popd
    exit /b 1
)
popd
echo [build] Built %TOLK_OUT%

:: ---------------------------------------------------------------------
:: Step 2: Build OP1AccessShim.dll (statically links Lua, dynamically
:: loads Tolk.dll at runtime via LoadLibrary).
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

cl /nologo /MD /O2 /EHsc /std:c++20 ^
   /I"%LUAINC%" /I"%LUASRC%" /I"%MINHOOK%\include" ^
   "%REPO%\src\Shim.cpp" %LUASRCS% ^
   "%MINHOOK%\src\buffer.c" "%MINHOOK%\src\hook.c" "%MINHOOK%\src\trampoline.c" ^
   "%MINHOOK%\src\hde\hde32.c" "%MINHOOK%\src\hde\hde64.c" ^
   /link /DLL ^
   /OUT:"%SHIM_OUT%" ^
   /IMPLIB:"%BUILD%\OP1AccessShim.lib" ^
   advapi32.lib user32.lib

if errorlevel 1 (
    echo [build] Shim build failed.
    popd
    exit /b 1
)
popd
echo [build] Built %SHIM_OUT%

:: ---------------------------------------------------------------------
:: Step 3: Deploy
:: ---------------------------------------------------------------------
copy /Y "%SHIM_OUT%" "%GAME_MODS%\Scripts\OP1AccessShim.dll" >nul || (
    echo [build] Copy SHIM failed.
    exit /b 1
)
copy /Y "%TOLK_OUT%" "%GAME_MODS%\Scripts\Tolk.dll" >nul || (
    echo [build] Copy Tolk failed.
    exit /b 1
)
copy /Y "%NVDA_DLL%" "%GAME_MODS%\Scripts\nvdaControllerClient64.dll" >nul
if exist "%SAAPI_DLL%" copy /Y "%SAAPI_DLL%" "%GAME_MODS%\Scripts\SAAPI64.dll" >nul
echo [build] Deployed to: "%GAME_MODS%\Scripts"
echo [build] Done.
