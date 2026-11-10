# Third-party components

## Prism

- Source: https://github.com/ethindp/prism (pinned commit: `PRISM_REF` in
  `scripts/build-shim.cmd`)
- License: MPL-2.0. Prism bundles code under other permissive licenses (fmt,
  simdutf, Highway, concurrentqueue, dr_wav, moderncom, parts of NVGT) and the
  NVDA Controller Client RPC interface, which its copyright holder relicensed
  to Prism under MPL-2.0. Details are in Prism's `NOTICE` and `LICENSES/`.
- Use: built from unmodified upstream source as a static library and linked
  into `OP1AccessShim.dll`. MPL-2.0 is file-level copyleft, so linking it into
  the MIT-licensed shim is fine. What it asks of us when we distribute the
  shim: point recipients to Prism's source (the repository above, at the
  pinned commit) and ship its notices. `build-shim.cmd` copies `LICENSE`,
  `NOTICE` and `LICENSES/` to `Mods/OP1Access/licenses/prism/` on deploy. If
  we ever patch Prism, the changed files must be published under MPL-2.0 too.
- Prism replaced Tolk (LGPL-3.0), which had to stay a separate DLL and needed
  `nvdaControllerClient64.dll` / `SAAPI64.dll` next to it.

## UE4SS

- Source: https://github.com/UE4SS-RE/RE-UE4SS
- License: MIT
- Use: NOT vendored. Users install UE4SS themselves. The mod's Lua scripts
  and compiled C++ DLL drop into a UE4SS install.
