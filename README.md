# OP1Access — Octopath Traveler screen-reader accessibility mod

A UE4SS-based mod that adds screen-reader output and audio cues to Octopath
Traveler (PC, 2019, UE 4.18). Targets NVDA, JAWS, Narrator and SAPI fallback
through the Tolk abstraction.

**Status:** pre-alpha scaffolding. Nothing works yet.

## Phased scope

| Phase | Features | Status |
|------|----------|--------|
| 0 | Toolchain — UE4SS attached, SDK dumped, Tolk speaks "hello" | in progress (UE4SS deployed; Tolk pending) |
| 1 | Battle-start announcement, HP/SP thresholds | planned |
| 2 | Dialog text-box read-out (uses decoded `TalkData_EN`) | planned |
| 3 | Menu read-out — UI confirmed UMG, scope is in | planned |
| 4 | Overworld proximity beacons, path-actions, sub-stories | future |

## Open questions

1. ~~**Are menus UMG or custom Slate?**~~ ✅ Resolved 2026-05-05 — UMG.
   See `docs/investigation-umg.md`.
2. **Does UE4SS attach cleanly to OT1's 4.18 Shipping build?** Verification
   harness in `scripts/verify-attach.ps1`. Run it, then launch the game.
3. **Is the dialog-display path a clean hookable UFunction with an ID
   parameter?** Suspected yes based on `TalkData_EN` table structure;
   confirmed when phase 2 work begins.

See `docs/feasibility.md` for full background and `docs/install-state.md`
for what's currently deployed.

## Verifying the install (task #2)

```
powershell -ExecutionPolicy Bypass -File scripts/verify-attach.ps1
```

In another window: launch Octopath Traveler from Steam. The verifier should
report `[verify] Log appeared` and then highlight any green `[OP1Access]`
lines from the UE4SS log.

## Build / install (once phase 0 lands)

Prerequisites:
- Octopath Traveler on Steam (Windows)
- UE4SS (latest release, the `LessEqual421` build for UE 4.18)
- Visual Studio 2022 with C++ desktop workload
- xmake (UE4SS's build system)

Install steps will be filled in as phase 0 lands. For now this repo only
contains scaffolding.

## Repo layout

```
docs/         design docs and feasibility briefing
src/          C++ mod source (Tolk shim, called from Lua)
scripts/      Lua mod that loads into UE4SS
third_party/  Tolk DLLs (vendored — LGPLv3, see THIRD_PARTY_LICENSES.md)
```

## License

Mod code: MIT (see LICENSE).
Tolk: LGPLv3, vendored unmodified — see `third_party/tolk/` and
`THIRD_PARTY_LICENSES.md`.
