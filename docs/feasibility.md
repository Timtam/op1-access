# Feasibility briefing

Background and prior research that informed the project plan. Captured
2026-05-05 from the initial scoping conversation. Sources cited inline.

## Engine baseline

- **Octopath Traveler 1 (PC, 2019)** runs on **Unreal Engine 4.18**, confirmed
  from `.uproject` in the unpacked retail pak
  (https://andrew.fm/octopath/OctopathMod.html).
- UE4's first-party screen-reader API only landed in 4.23
  (https://docs.unrealengine.com/4.27/en-US/InteractiveExperiences/UMG/UserGuide/ScreenReader/).
  We get nothing from the engine — everything is built from scratch.
- Single ~3 GB pak, **unencrypted**. Standard `UnrealPak` opens it with no
  AES key. Loose-file mods work.
- **Denuvo was removed** post-launch
  (https://www.siliconera.com/octopath-traveler-denuvo-drm-apparently-removed/).
  No EAC/BattlEye. DLL injection is unobstructed.

## Existing modding scene

- **OctomodEditor** (https://github.com/ItsBenOnceAgain/OctomodEditor) has
  decoded the data tables that matter most: `Enemy`, `EnemyGroup`,
  `EncountVolume`, `GameTextEN`, `TalkData_EN`, `Ability`, `Item`. Enemy
  names, dialog text, item names, ability names are reachable as data.
- Multiple translation/localization mods on Nexus prove text is reachable
  and re-injectable.
- **No public UE4SS port for OT1.** UE4SS supports UE 4.12–5.7
  (https://deepwiki.com/UE4SS-RE/RE-UE4SS/12.3-version-compatibility-guide)
  so 4.18 is in range but may need AOB signature work for this specific
  Shipping build. Use the `LessEqual421` build.

## Screen reader integration

**Tolk** (https://github.com/dkager/tolk, LGPLv3) is the standard pattern.
One call, `Tolk_Output(L"text")`, fans out to NVDA / JAWS / Window-Eyes /
SuperNova / System Access / ZoomText / SAPI fallback. Used by
StardewAccess, Reigns-Access, and the FF Pixel Remaster screen-reader mods.

## Hook points (UE4SS)

UE4SS gives us:
- `RegisterHook("/Script/UMG.UserWidget:Construct", fn)` and `:Destruct`.
- Read/write of `FText` and `FString` via `:ToString()` and `FText("...")`.
- `RegisterHook` works on any UFunction (native or Blueprint) with pre/post.
- C++ mod DLLs supported with Lua-callable bindings — perfect for shipping
  `tolk.dll` plus a thin C++ shim that exposes `speak(str)` to Lua.

## The decision-critical unknown

**Are Octopath's menus UMG widgets or custom Slate/canvas-drawn?**

- UMG → tractable. Hook `Construct`/`Destruct`, read text from widgets.
- Custom-drawn (plausible for an HD-2D JRPG ported from Switch) → no widget
  focus events fire; reduced to memory-scanning game state. ~10× harder.

Resolution: unpack the retail pak, grep `Content/` for `WBP_*.uasset` on
menu screens. **One evening of work; gates the entire phase 3 scope.**

## Localization specifics

- Octopath does NOT use standard UE4 `.locres` files. Text is in custom data
  tables baked into uassets (`GameTextEN.uexp`, `TalkData_EN.uexp`).
- Fine for our purposes — we read them as data tables. But the mapping
  "menu currently shows item X" → "lookup string ID for X in GameText"
  requires reading runtime game state, not just text files.

## Difficulty tiers

| Tier | Scope | Effort |
|------|-------|--------|
| Easy | Tolk hooked up; battle-start announcement; HP/SP threshold cues | Weekend → 2 weeks |
| Medium | Full menu read-out (if UMG), combat command/target/turn-order, dialog text-box | Multi-month |
| Hard | Overworld navigation, path actions, save/load, skill-tree | 6–12+ months |
| Probably blocked | Anything needing widget focus events on canvas-drawn UI without a clean state hook | — |

## Prior art

- **Reigns-Access** (https://github.com/leoguimaoficial/Reigns-Access) —
  Tolk + BepInEx. Unity, but architecturally identical pattern.
- **FF Pixel Remaster screen-reader mods** — closest thematic prior art
  (turn-based JRPG, menus, party HP/MP, battle state). Unity/MelonLoader,
  not UE4. https://github.com/bladestorm360/FF5-Screen-Reader,
  https://github.com/BlindGuyNW/FF6ScreenReader.
- **StardewAccess** (https://github.com/stardew-access/stardew-access) —
  best-in-class reference for tile-grid navigation and object trackers.
  XNA/MonoGame, not UE4, but the design patterns transfer.
- **No accessibility mod exists for any UE4 game we could find.** OP1Access
  would plausibly be the first community-built UE4 SR mod. Worth confirming
  with UE4SS Discord.

## Working order

1. Resolve the UMG question (one evening).
2. Get UE4SS attached to OT1 Shipping build; dump SDK.
3. Phase 0: Tolk + minimal Lua mod, prove `speak("hello")` from inside the
   game.
4. Phase 1: battle-start announcement (encounter tables already decoded).
5. Phase 2: dialog read-out (highest value-per-hour after phase 1).
6. Phase 3+: depends on UMG outcome.
