# Third-party components

## Tolk

- Source: https://github.com/dkager/tolk
- License: LGPL-3.0-or-later
- Use: redistributed unmodified as a DLL alongside the mod. Source code for
  Tolk is available at the upstream repository above. If you redistribute
  this mod with the Tolk DLLs, you must comply with LGPLv3 — in practice
  that means linking dynamically (we do) and pointing users at upstream
  source (we do, here).
- Vendored files will live under `third_party/tolk/` once downloaded.
  See `third_party/tolk/README.md`.

## UE4SS

- Source: https://github.com/UE4SS-RE/RE-UE4SS
- License: MIT
- Use: NOT vendored. Users install UE4SS themselves. The mod's Lua scripts
  and compiled C++ DLL drop into a UE4SS install.

## NVDAControllerClient (optional, future)

- Source: https://github.com/nvaccess/nvda
- License: LGPL-2.1
- Use: not currently used; Tolk is sufficient. If we ever bypass Tolk for
  NVDA-specific features (e.g. braille routing), revisit.
