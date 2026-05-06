# Investigation: UMG vs custom Slate menus — RESOLVED

**Status:** ✅ Resolved 2026-05-05. **Octopath Traveler 1's UI is UMG.**
Phase 3 (menu read-out) is unblocked.

## Method

Unpacked-listing approach (no full extraction needed):

```
repak.exe info  Octopath_Traveler-WindowsNoEditor.pak
repak.exe list  Octopath_Traveler-WindowsNoEditor.pak  > pak_listing.txt
```

Pak metadata: V4 format, **unencrypted index**, Zlib compression, 107,227
file entries — confirms the andrew.fm writeup.

## Findings

The game does **not** use the `WBP_` prefix convention — instead UMG widget
blueprints carry the `Widget` suffix. Surveying
`Octopath_Traveler/Content/UI/` produced 4,319 UI-related assets, with UMG
widget blueprints organised under per-subsystem `BP/` directories:

| Subsystem | Key widgets (representative) |
|-----------|------------------------------|
| Battle | `BattleCommandMenu`, `BattleCommandMenuItem`, `BattleCommandHelpWindow`, `BattleActionInfo`, `BattleDialog`, `BattleMonsterCaption`, `BattleEnemyStatus`, `BattleSelectPlayerStatus`, `BattleTargetCursor`, `BattleTargetFrame`, `ActionOrderTimeLine`, `ActionCharacterPanel`, `BattleResultPanelWidget`, `BattleBonusWidget`, `BattleDropItemWidget` |
| MainMenu | `MainMenuWidget`, `MainMenuItemListWidget`, `MainMenuAbilityWidget`, `MainMenuJobWidget`, `MainMenuTutorialListWidget`, `EquipmentMenuWidget`, `StatusMenuWidget`, `JobStatusWidget` |
| Chat (NPC dialog) | `ChatWidget`, `ChatCaracterPanel` |
| Dialog (system) | `UICommonDialogBP`, `UICommonDialogItemBP` |
| Common (shared) | `ListWidget`, `ListItemWidget`, `ListCategoryWidget`, `SingleMenuWidget`, `MapDangerWidget`, `MapNamenotificationWidget`, `PartySplitWidget`, `SelectItemNumWidget`, `HelpWindowWBP` |
| Narration | `NarrationWidget`, `NarrationMessageWidget`, `NarrationNoteWidget` |
| Other (also UMG) | BarMenu, FieldCommand, GameOver, Loading, MiniMap, Option, PartyChat, RadarMap, SaveLoad, Shop, StaffRoll, Title, Tutorial, worldmap |

Central orchestration: `UIManagerBP`, `UIControllerBP`,
`UIControlInterface` — UI state is driven by blueprints, hookable from
UE4SS Lua via `RegisterHook`.

State-enum assets — `EDIALOG_STATE`, `ELISTWIDGET_STATE`,
`ECOMMON_NOTIFICATION_STATE`, `ELIST_EVENT_TYPE`, `ENARRATION_STATE`,
`EPARTY_SPLIT_STATE` — exist as `.uasset` files. These are state-machine
enums driving widget transitions; their existence as separate assets means
the state changes go through nameable functions we can hook.

Full asset list saved to `docs/ui_assets.txt` (4,319 lines, gitignore-safe).

## Implications for the phased plan

- **Phase 1 (battle alerts)**: hook `BattleCommandMenu:Construct` for combat
  start; read enemy IDs via `BattleEnemyStatus`; combine with already-decoded
  `EnemyGroupData` for names.
- **Phase 2 (dialog read-out)**: hook `ChatWidget` for NPC dialog;
  `UICommonDialogBP` for system prompts; `NarrationMessageWidget` for the
  game's narrator/storybook text. Three different surfaces — likely all
  similar pattern (text setter UFunction).
- **Phase 3 (menu read-out)**: now in scope. `MainMenuWidget` and
  `EquipmentMenuWidget`/`StatusMenuWidget`/`JobStatusWidget` cover the
  pause-menu surface. `ListWidget`/`ListItemWidget` are the shared list
  primitive — hooking the focus-changed event there gets you most menu
  navigation read-outs in one shot.
- **Phase 4**: `Shop`, `SaveLoad`, `Option`, `Title`, `Tutorial`, `Map`,
  `worldmap` — all UMG.

## Remaining unknown

The widget blueprints exist as assets — we still need to confirm at runtime
that UE4SS can hook their `Construct`/`Destruct` UFunctions on this
specific Shipping build. Resolved by task #2 (verify UE4SS attaches).
