# Tolk (vendored)

This directory will hold the Tolk runtime binaries used by OP1Access at
runtime. Tolk is **LGPL-3.0-or-later**; we link dynamically (LoadLibrary at
runtime) and ship the DLLs unmodified, which is the LGPL-compliant pattern.

**The actual DLLs are not committed to git** (see `.gitignore`). Each
contributor downloads them locally during build setup.

## Download

1. Get the latest Tolk release from https://github.com/dkager/tolk/releases
2. Extract `Tolk.dll` and the bundled screen-reader bridge DLLs:
   - `Tolk.dll`
   - `nvdaControllerClient64.dll`
   - `SAAPI64.dll`
   - `dolapi64.dll`
   - `jfwapi64.dll` (optional, JAWS)
   - `ZoomTextNeo.dll` (optional)
3. Place all of them in **two locations**:
   - `third_party/tolk/` (this directory) — for build-time reference
   - `scripts/Mods/OP1Access/dlls/` — for runtime, alongside the shim DLL

## License posture

- Tolk source: https://github.com/dkager/tolk
- License: LGPL-3.0-or-later
- Pointing redistributors at the upstream source satisfies the "users can
  obtain the library source" obligation.
- Do **not** statically link Tolk. Do **not** modify Tolk and ship the
  modification without source. Both would create LGPL obligations we don't
  want to take on for this mod.

See `../../THIRD_PARTY_LICENSES.md` for the full third-party register.
