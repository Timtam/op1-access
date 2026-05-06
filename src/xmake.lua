-- xmake build for the OP1Access C++ shim DLL.
--
-- This mirrors the structure UE4SS expects for a CppUserMod (see
-- https://docs.ue4ss.com/guides/installing-a-c++-mod.html). Concretely, the
-- expected layout is for this directory to live inside an UE4SS source tree
-- under `UE4SS/Mods/OP1AccessShim/`, where the parent xmake.lua for the
-- whole UE4SS solution adds it via `includes("Mods/OP1AccessShim")`.
--
-- For now this file is the structural skeleton — it will not build standalone
-- until phase 0 lands the UE4SS-tree integration. The TODO at the bottom
-- tracks the missing pieces.

target("OP1AccessShim")
    set_kind("shared")
    set_languages("cxx20")

    add_files("Shim.cpp")

    -- These dependencies come from the UE4SS source tree. They resolve when
    -- this target is added to the parent UE4SS xmake project. Standalone
    -- build is intentionally not supported.
    -- add_deps("UE4SS")
    -- add_packages("Helpers", "DynamicOutput", "LuaMadeSimple")

    -- DLL search-path quality of life: ensure Tolk.dll sitting next to
    -- our DLL is found at runtime. UE4SS already adds the mod folder to
    -- the search path, so no extra work needed here.

    -- TODO(phase-0):
    --   1. Drop this directory into <UE4SS>/Mods/OP1AccessShim/.
    --   2. Add `includes("Mods/OP1AccessShim")` to UE4SS/xmake.lua.
    --   3. Vendor Tolk.dll + Tolk_dotnet.dll + SAAPI64.dll + nvdaControllerClient64.dll
    --      into ../scripts/Mods/OP1Access/dlls/ (gitignored binaries — see
    --      third_party/tolk/README.md for download instructions).
    --   4. xmake f -m Release && xmake build OP1AccessShim.
target_end()
