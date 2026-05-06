# SDK dump procedure — capturing hook targets

The OP1Access mod includes a Ctrl+F11 keybind that dumps UHT-compatible
headers of all currently-loaded UObjects. The dump is our canonical
reference for hook target discovery (UFunction names, parameter types)
when designing phase 1+ hooks.

## What we want to capture

Game state determines which UObjects are loaded. To get useful coverage we
need to dump while in each state:

| Game state | Captures |
|------------|----------|
| Title screen | Title, SaveLoad, Option widgets |
| Overworld (any town/field) | UIManager, MainMenu, MiniMap, RadarMap, FieldCommand, Chat |
| In a battle | BattleCommandMenu, BattleEnemyStatus, ActionOrder*, BattleDialog, BattleResult* |
| In an NPC dialog | ChatWidget, ChatCaracterPanel |
| In a system prompt | UICommonDialogBP, UICommonDialogItemBP |
| In a town shop | Shop widgets, PurchaseList |
| Reading a sub-story / narration | NarrationWidget, NarrationMessageWidget, NarrationNoteWidget |

## Procedure

1. Launch the game with the OP1Access mod active (UE4SS already injecting).
2. Get into the gameplay state you want to capture.
3. Press **Ctrl+F11**. NVDA should say "Dumping headers", then "Dump complete"
   (typically 5–60 seconds depending on what's loaded).
4. The dump lands in:
   ```
   C:\Program Files (x86)\Steam\steamapps\common\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64\UHTHeaderDump\
   ```
5. Each subsequent press *re-dumps* — the directory is overwritten on each
   trigger (by UE4SS's generator).
6. After you're satisfied, copy the relevant per-package `.h` files into
   `docs/sdk-dump/` in this repo. The full dump can be many MB; only commit
   the headers we actually consult (Battle, MainMenu, Chat, Dialog,
   Narration, FieldCommand, Common — under the game's package, not engine).

## What the headers look like

UHT-style headers list each UClass's UFUNCTIONs with their parameters,
e.g.:

```cpp
UFUNCTION(BlueprintCallable)
void SetText(const FText& InText);

UFUNCTION(BlueprintCallable)
void OnButtonPressed(int32 ButtonIndex);
```

These are the names to feed into UE4SS's `RegisterHook`:

```lua
RegisterHook("/Script/Octopath_Traveler.ChatWidget:SetText", function(self, in_text)
    op1.speak(in_text:get():ToString())
end)
```

(Class path comes from the package + class; the `Octopath_Traveler` package
prefix is what holds the game-specific UClasses.)

## Dump variants we don't currently use

`DumpAllObjects()` produces a flat `UE4SSObjectDump.txt` listing all live
UObjects with addresses. Useful for spelunking via grep but doesn't give
function signatures. Add a second key bind if/when needed.
