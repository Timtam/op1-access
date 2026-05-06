-- OP1Access — Octopath Traveler screen-reader mod (Lua entry)
--
-- Architecture:
--   Lua here drives policy (what to speak, when, in response to which game
--   events). The C++ shim (OP1AccessShim.dll) statically links Lua 5.4 and
--   exposes Speak / Silence / IsSpeakingSupported, NVDA-backed.

local M = {}

-- ---------------------------------------------------------------------------
-- Shim load
-- ---------------------------------------------------------------------------
do
    local dlls_dir = "Mods\\OP1Access\\Scripts\\"
    local extra = dlls_dir .. "?.dll"
    if not package.cpath:find(extra, 1, true) then
        package.cpath = extra .. ";" .. package.cpath
    end
end

local shim = nil
do
    local ok, mod = pcall(require, "OP1AccessShim")
    if ok then shim = mod
    else print(string.format("[OP1Access] shim load failed: %s\n", tostring(mod))) end
end

local function log(msg)
    print(string.format("[OP1Access] %s\n", tostring(msg)))
end

local function speak(text, interrupt)
    if not text or text == "" then return end
    text = tostring(text)
    if not (shim and shim.Speak) then
        log("speak (NO SHIM): " .. text)
        return
    end
    log("speak: " .. text)
    pcall(function() shim.Speak(text, interrupt ~= false) end)
end

local function silence()
    if shim and shim.Silence then shim.Silence() end
end

M.speak = speak; M.silence = silence; M.log = log

-- ---------------------------------------------------------------------------
-- Class-name -> friendly speech.
-- Sourced from the object dump under /Game/UI/Title/BP/Scene/. The title
-- screen uses bespoke widgets that don't go through KSUIManager.Open, so
-- we listen on widget construction directly.
-- ---------------------------------------------------------------------------
-- Allowlist: only meaningful top-level menu/screen widgets that represent
-- user-visible state. Decorative parents (TitleBase_C, TitleBackScene_C),
-- visual-only screens (TitleLogo_C, TitleDemo_C), and transient overlays
-- (TitleSystemDataLoad_C) are intentionally absent — they fire alongside
-- the real menus and would steal the spoken slot.
local SCENE_LABELS = {
    -- Title-screen flow
    UIMainTitle_C            = "Title",
    TitleMainMenu_00_C       = "Title main menu",
    TitleMainMenu_01_C       = "Title submenu",
    TitleOptionScene_C       = "Options",
    TitleLoadScene_C         = "Load game",
    TitlePlayerSelect_C      = "Choose your character",
    -- Top-level in-game menus (route via KSUIManager too, kept as fallback)
    MainMenuWidget_C         = "Main menu",
    MainMenuItemListWidget_C = "Items",
    MainMenuAbilityWidget_C  = "Abilities",
    MainMenuJobWidget_C      = "Jobs",
    MainMenuTutorialListWidget_C = "Tutorials",
    MainMenuMissionRecord_C  = "Mission record",
    MainMenuEtcWidget_C      = "Other",
    EquipmentMenuWidget_C    = "Equipment",
    StatusMenuWidget_C       = "Character status",
    JobStatusWidget_C        = "Job status",
    -- Save / load
    MenuSaveLoad_C           = "Save and load",
    -- Options. NB: OptionMenuSteamWBP_C is intentionally NOT here — it
    -- constructs as a sub-widget of MenuSaveLoad_C (Steam Cloud indicator
    -- embedded in the save/load screen), not as a separate menu.
    OptionMenuWBP_C          = "Options",
    -- Battle
    BattleCommandMenu_C      = "Battle command menu",
    BattleResultPanelWidget_C= "Battle results",
    -- Story / dialog / narration
    ChatWidget_C             = "Conversation",
    -- UICommonDialogBP_C is intentionally not in this list: it constructs
    -- alongside the title screen as part of the framework, and its
    -- announcement would steal the slot from the actual title widgets.
    -- Real dialog content is announced via the KSUIManager:OpenDialog hook
    -- with caption + detail + buttons, which is far more useful.
    NarrationWidget_C        = "Narration",
    NarrationMessageWidget_C = "Narration message",
    NarrationNoteWidget_C    = "Narration note",
    -- Misc
    StaffCreditWBP_C         = "Staff credits",
    PartyChat_C              = "Party chat",
}

-- Suppression: avoid speaking very transient / decorative widgets that
-- construct alongside a real menu and would create double-speak. We only
-- speak when the class is in SCENE_LABELS, so a new class is silent by
-- default — but we still log every Construct so we can grow the whitelist.

-- ---------------------------------------------------------------------------
-- EKSUIKind -> friendly name (post-title in-game menus)
-- ---------------------------------------------------------------------------
local UI_KIND_NAMES = {
    [0] = "Title screen", [10] = "Main menu", [11] = "Shop",
    [12] = "Dialog", [13] = "Field actions", [14] = "Purchase",
    [15] = "Provoke", [16] = "Allure", [17] = "Inquire",
    [18] = "Mini map", [19] = "Tutorial", [20] = "Game over",
    [21] = "Narration", [22] = "World map", [23] = "Menu",
    [24] = "Party chat", [25] = "Flashback", [26] = "Notification",
    [27] = "Map notification", [28] = "Party chat available",
    [29] = "Party change", [30] = "Staff credits",
    [50] = "Options", [51] = "Equipment", [52] = "Save and load",
    [53] = "Character status", [54] = "Items", [55] = "Abilities",
    [56] = "Tutorials", [57] = "Change jobs", [58] = "Mission record",
    [59] = "Story select", [60] = "Event battle", [61] = "Party split",
    [62] = "Ability settings", [100] = "Action popup",
    [101] = "Skip event", [102] = "Judge", [103] = "Auto saving",
    [104] = "Help",
}

local UI_KIND_SUPPRESSED = {
    [27] = true, [103] = true, [104] = true,
}

-- ---------------------------------------------------------------------------
-- FText helper
-- ---------------------------------------------------------------------------
local function ftext_to_string(ftext)
    if not ftext then return "" end
    local ok, s = pcall(function() return ftext:ToString() end)
    if ok and s then return tostring(s) end
    return ""
end

-- ---------------------------------------------------------------------------
-- Class-name extraction from a UObject (UE4SS Lua wrapper)
-- ---------------------------------------------------------------------------
local function class_name_of(uobject)
    if not uobject then return nil end
    local name = nil
    pcall(function()
        local cls = uobject:GetClass()
        if cls then
            name = cls:GetFName():ToString()
        end
    end)
    return name
end

-- ---------------------------------------------------------------------------
-- Hook: every UserWidget creation. Uses UE4SS's NotifyOnNewObject (fires on
-- StaticConstructObject_Internal for the class and all subclasses) instead
-- of the BP-implementable Construct UFunction (which doesn't reliably hook
-- through to derived BP classes). Logs every class name; speaks only those
-- in the whitelist.
-- ---------------------------------------------------------------------------
-- Debounced announcement. Widget construction happens in bursts (e.g. on
-- title-screen entry, half a dozen scene widgets construct in <50 ms).
-- We collapse a burst to a single "speak the latest matching widget"
-- after WIDGET_DEBOUNCE_MS of quiet, so users only hear the screen they
-- ended up on, not every transient frame.
local WIDGET_DEBOUNCE_MS = 750
local last_spoken_class  = nil
local pending_label      = nil
local pending_class      = nil
local pending_token      = 0

-- Single point that schedules a debounced "menu became visible" announcement.
-- Called from any signal source: NotifyOnNewObject, UIOpen, SetVisibility.
local function schedule_menu_announce(cls, label)
    pending_label = label
    pending_class = cls
    pending_token = pending_token + 1
    local my_token = pending_token

    ExecuteWithDelay(WIDGET_DEBOUNCE_MS, function()
        if my_token ~= pending_token then return end  -- superseded
        if not pending_label then return end
        if pending_class == last_spoken_class then
            pending_label = nil
            return
        end
        last_spoken_class = pending_class
        local label_to_speak = pending_label
        pending_label = nil
        speak(label_to_speak)
    end)
end

-- Registry of SCENE_LABELS widget instances we've observed. Used by the
-- polling loop to figure out which menu is currently visible. Bounded by
-- cleanup of invalid entries each tick.
local scene_widgets = {}  -- list of {widget_uobject, class_name, label}

-- Forward declaration so on_widget_created can reference poll_player_panel_info
-- (defined later). Without this, the reference would be captured as a *global*
-- at compile time and never see the later local definition.
local poll_player_panel_info

local function on_widget_created(NewObject)
    -- NotifyOnNewObject passes the UObject directly, NOT a hook-style
    -- parameter wrapper. Don't call :get() here.
    if not NewObject then return end
    local cls = class_name_of(NewObject)
    if not cls then return end

    local label = SCENE_LABELS[cls]
    if not label then return end

    log("widget created: " .. cls)

    -- Add to polling registry. The polling tick will walk this to find
    -- whatever scene widget is currently visible — handles back-out
    -- transitions (e.g. closing Save/Load and returning to Title) where
    -- no UIOpen / UIClose fires.
    scene_widgets[#scene_widgets + 1] = {NewObject, cls, label}

    schedule_menu_announce(cls, label)
end

-- ---------------------------------------------------------------------------
-- Hook: KSUIManager (post-title, in-game)
-- ---------------------------------------------------------------------------
local last_kind_spoken = nil
local function on_ui_manager_open(Context, Kind)
    local k = nil
    pcall(function() k = Kind:get() end)
    if not k then return end
    if UI_KIND_SUPPRESSED[k] then return end
    if k == last_kind_spoken then return end
    last_kind_spoken = k
    speak(UI_KIND_NAMES[k] or ("Menu " .. tostring(k)))
end

local function on_ui_manager_close(Context, Kind)
    local k = nil
    pcall(function() k = Kind:get() end)
    if k and k == last_kind_spoken then last_kind_spoken = nil end
end

local function on_ui_manager_open_dialog(Context, InParam)
    pcall(function()
        if not InParam then speak("Dialog"); return end
        local caption, detail, buttons = "", "", {}
        pcall(function() caption = ftext_to_string(InParam.CaptionText) end)
        pcall(function() detail  = ftext_to_string(InParam.DetailText) end)
        pcall(function()
            local arr = InParam.ButtonText
            if arr and arr.ForEach then
                arr:ForEach(function(_, v) buttons[#buttons + 1] = ftext_to_string(v) end)
            end
        end)
        local parts = {}
        if caption ~= "" then parts[#parts + 1] = caption end
        if detail  ~= "" then parts[#parts + 1] = detail end
        if #buttons > 0 then parts[#parts + 1] = "Buttons: " .. table.concat(buttons, ", ") end
        speak(#parts > 0 and table.concat(parts, ". ") or "Dialog")
    end)
end

-- ---------------------------------------------------------------------------
-- Register hooks
-- ---------------------------------------------------------------------------
local function safe_register(path, fn, label)
    local ok, err = pcall(RegisterHook, path, fn)
    log(string.format("RegisterHook %s: %s%s", label, tostring(ok),
        ok and "" or (" (" .. tostring(err) .. ")")))
end

-- Broad: every widget creation, via UE4SS's NotifyOnNewObject. Fires on
-- StaticConstructObject_Internal so BP-derived widgets are also caught.
-- This handles FIRST-time-ever construction. For repeat visits to the same
-- widget (e.g. Title -> Save/Load -> Title), we hook UIOpen below.
local ok_notify, err_notify = pcall(NotifyOnNewObject, "/Script/UMG.UserWidget", on_widget_created)
log(string.format("NotifyOnNewObject UserWidget: %s%s", tostring(ok_notify),
    ok_notify and "" or (" (" .. tostring(err_notify) .. ")")))

-- ---------------------------------------------------------------------------
-- Widget UIOpen hooks — catches *every* "menu shown" event, including
-- repeat visits where the widget is reused from cache.
-- ---------------------------------------------------------------------------

local function on_widget_uiopen(Context)
    local widget = Context and Context:get()
    if not widget then return end
    local cls = class_name_of(widget)
    if not cls then return end
    local label = SCENE_LABELS[cls]
    if not label then return end
    log("UIOpen: " .. cls)
    schedule_menu_announce(cls, label)
end

local function on_widget_uiclose(Context)
    -- Clear last_spoken_class on close so re-entry of the same screen
    -- still announces.
    local widget = Context and Context:get()
    local cls = class_name_of(widget)
    if cls then
        log("UIClose: " .. cls)
        if cls == last_spoken_class then
            last_spoken_class = nil
        end
    end
end

-- Parent hook: catches every widget that does NOT override UIOpen as a
-- Blueprint event.
safe_register("/Script/Octopath_Traveler.KSUserWidgetBase:UIOpen",  on_widget_uiopen,  "KSUserWidgetBase.UIOpen")
safe_register("/Script/Octopath_Traveler.KSUserWidgetBase:UIClose", on_widget_uiclose, "KSUserWidgetBase.UIClose")

-- ---------------------------------------------------------------------------
-- Polling loop: walks the scene_widgets registry on a fixed cadence to
-- detect "menu became visible" transitions that don't fire UIOpen, and
-- "menu became hidden" transitions that don't fire UIClose. Common case is
-- the bespoke Title-screen widgets — they're toggled by visibility flips
-- on a parent switcher rather than via the KS lifecycle.
--
-- Cost is bounded: registry stays small (one entry per scene widget ever
-- constructed; dead entries pruned each tick). No per-frame overhead.
-- ---------------------------------------------------------------------------
-- Poll cadence for menu visibility / item-cursor changes. ~20 Hz feels
-- close to native screen-reader responsiveness for arrow-key navigation,
-- and the work per tick is small (a handful of UFunction calls + property
-- reads).
local POLL_INTERVAL_MS = 50
local last_polled_class = nil

local function widget_is_visible(w)
    -- Use UWidget::IsVisible() — a UFunction that returns true iff the
    -- widget's effective visibility is one of {Visible, HitTestInvisible,
    -- SelfHitTestInvisible}, walking parent visibility too. This is the
    -- single signal that reliably distinguishes the actually-active screen
    -- from the dozens of cached widgets that share the viewport (confirmed
    -- via the diagnostic dumps in the UE4SS log).
    --
    -- pcall every call: a partially-destroyed widget mid-GC can throw, and
    -- a single throw inside the polling loop would silently kill it.
    local visible = false
    pcall(function()
        if not w or not w:IsValid() then return end
        visible = (w:IsVisible() == true)
    end)
    return visible
end

-- Container widgets that are always visible alongside a real sub-screen
-- and shouldn't be announced on their own. The Title root container
-- (UIMainTitle_C) is the only one we know about so far; in-game has its
-- equivalent (TBD when we test more screens).
local CONTAINER_CLASSES = {
    UIMainTitle_C = true,
}

-- Menus where we know the parent exposes a cursor-index `Select` IntProperty
-- alongside arrays we can index for the focused item's display label.
-- Adding a new menu = adding an entry here (paths sourced from the dump).
--
--   list_array       : ArrayProperty of item widgets (UUserWidget refs).
--                      We index this by Select and read item_text_field on
--                      the resulting widget.
--   item_text_field  : Field on each item widget that holds the displayed
--                      text (UTextBlock-ish, has GetText / Text). Optional.
--   text_array       : ArrayProperty of FName / FText fallback labels,
--                      indexed by Select. Used when item_text_field can't
--                      yield a string.
local SELECT_INDEX_MENUS = {
    TitleMainMenu_00_C = {
        list_array      = "ItemList",
        item_text_field = "Text_Content",
        text_array      = "TextLabel",
    },
    TitleMainMenu_01_C = {
        list_array      = "ItemList",
        item_text_field = "Text_Content",
        text_array      = "TextLabel",
    },
    -- TitlePlayerSelect_C is intentionally NOT in this table. It uses a
    -- bespoke poll path (poll_player_panel_info) that reads the localized
    -- name + class straight from the on-screen PlayerPanel_C UTextBlocks
    -- as the game itself updates them. That's the canonical source — the
    -- game already does the localization for us.
}

local last_select_value = nil
local last_select_owner = nil

-- Try multiple ways to read a string from a UE4SS-wrapped value. Different
-- types (FText / FName / FString / raw string) have different access paths.
local function value_to_string(v)
    if v == nil then return nil end
    local s = nil
    -- FText / FName / FString all expose :ToString() on the wrapper.
    pcall(function() s = v:ToString() end)
    if s and s ~= "" then return tostring(s) end
    -- Fall back to plain tostring (catches the value-type case).
    s = tostring(v)
    if s and s ~= "" and s ~= "nil" then return s end
    return nil
end

-- Index a UE4SS TArray wrapper. Tries 1-indexed [] then 0-indexed :Get().
local function tarray_at(arr, sel)
    if not arr then return nil end
    local item = nil
    pcall(function() item = arr[sel + 1] end)
    if item ~= nil then return item end
    pcall(function() item = arr:Get(sel) end)
    return item
end

-- Resolve the label of the menu item at the given selection index using
-- the per-menu config from SELECT_INDEX_MENUS.
local function resolve_menu_item_label(instance, sel, cfg)
    local label = nil

    -- Approach 0: hard-coded index -> label table. Used for menus where
    -- neither the widget tree nor an array yields a usable string at
    -- runtime (TitlePlayerSelect_C — PlayerName is placeholder text).
    if cfg.index_to_label then
        local s = cfg.index_to_label[sel]
        if s and s ~= "" then return s end
    end

    -- Approach 1: list_array[sel] -> item_text_field -> Text. The text
    -- field is typically a UTextBlock displaying the resolved/localized
    -- item label.
    if cfg.item_text_field then
        pcall(function()
            local item_list = instance[cfg.list_array]
            local item = tarray_at(item_list, sel)
            if not item then return end
            local tc = item[cfg.item_text_field]
            if not tc then return end
            local ftext = nil
            pcall(function() ftext = tc:GetText() end)
            if not ftext then pcall(function() ftext = tc.Text end) end
            local s = value_to_string(ftext)
            if s then label = s end
        end)
        if label and label ~= "" then return label end
    end

    -- Approach 2: text_array[sel] — array of FName / FText labels keyed
    -- by selection. Less polished (may be a localization key rather than
    -- the user-facing string) but always meaningful.
    if cfg.text_array then
        pcall(function()
            local arr = instance[cfg.text_array]
            local entry = tarray_at(arr, sel)
            local s = value_to_string(entry)
            if s then label = s end
        end)
    end

    return label
end

local function poll_title_selection(active_cls)
    local cfg = active_cls and SELECT_INDEX_MENUS[active_cls]
    if not cfg then
        last_select_value = nil
        last_select_owner = nil
        return
    end

    -- Find a visible instance of this class.
    local instance = nil
    for i = #scene_widgets, 1, -1 do
        local entry = scene_widgets[i]
        if entry[2] == active_cls then
            local w = entry[1]
            local alive = false
            pcall(function() alive = w and w:IsValid() end)
            if alive and widget_is_visible(w) then
                instance = w
                break
            end
        end
    end
    if not instance then return end

    local sel = nil
    pcall(function() sel = instance.Select end)
    if sel == nil then return end

    local owner_changed = (active_cls ~= last_select_owner)
    local value_changed = (sel ~= last_select_value)
    if not owner_changed and not value_changed then return end

    last_select_owner = active_cls
    last_select_value = sel

    local label = resolve_menu_item_label(instance, sel, cfg)
    log(string.format("Item selection: %s idx=%d label=%s", active_cls, sel, tostring(label)))
    speak(label or ("Item " .. tostring(sel)))
end

local function poll_active_menu()
    local kept = {}
    local best_idx, best_class, best_label = 0, nil, nil

    for i = 1, #scene_widgets do
        local entry = scene_widgets[i]
        local w, cls, label = entry[1], entry[2], entry[3]

        local alive = false
        pcall(function() alive = w and w:IsValid() end)
        if alive then
            kept[#kept + 1] = entry
            if not CONTAINER_CLASSES[cls] and widget_is_visible(w) then
                -- Most-recently-added visible widget wins — the diagnostic
                -- dumps confirmed each title sub-screen is constructed
                -- after the root container, so the highest-index visible
                -- entry is the actual active screen.
                if i >= best_idx then
                    best_idx, best_class, best_label = i, cls, label
                end
            end
        end
    end
    scene_widgets = kept

    if best_class and best_class ~= last_polled_class then
        last_polled_class = best_class
        last_spoken_class = best_class
        speak(best_label)
    elseif not best_class then
        last_polled_class = nil
    end

    -- Per-item polling for menus where we have a selection-index property.
    -- Currently: TitleMainMenu_01_C / TitleMainMenu_00_C expose `Select`
    -- (IntProperty at 0x250). Reading it each tick gives the current cursor
    -- index even though we can't hook the BP-only cursor UFunctions.
    poll_title_selection(best_class)

    -- Bespoke path for TitlePlayerSelect_C — the free-cursor character
    -- map. Reads the localized name + class from PlayerPanel_C's
    -- on-screen UTextBlocks, which the game updates as the cursor hovers.
    poll_player_panel_info(best_class)
end

-- Fire-and-forget polling loop. Wrap each tick in pcall: a Lua error
-- inside LoopAsync would otherwise stop subsequent ticks (or worse).
local ok_loop = pcall(LoopAsync, POLL_INTERVAL_MS, function()
    pcall(poll_active_menu)
end)
log("Polling loop started: " .. tostring(ok_loop))

-- In-game: routed through KSUIManager.
safe_register("/Script/Octopath_Traveler.KSUIManager:Open",       on_ui_manager_open,        "KSUIManager.Open")
safe_register("/Script/Octopath_Traveler.KSUIManager:Close",      on_ui_manager_close,       "KSUIManager.Close")
safe_register("/Script/Octopath_Traveler.KSUIManager:OpenDialog", on_ui_manager_open_dialog, "KSUIManager.OpenDialog")

-- Phase 0 boot announce
log("script loaded; shim=" .. tostring(shim ~= nil))
if shim and shim.IsSpeakingSupported then
    log("IsSpeakingSupported (NVDA running): " .. tostring(shim.IsSpeakingSupported()))
end
speak("OP1 Access loaded")

-- ---------------------------------------------------------------------------
-- Dev key bindings
-- ---------------------------------------------------------------------------
pcall(RegisterKeyBind, Key.F11, { ModifierKey.CONTROL }, function()
    speak("Dumping headers")
    local ok = pcall(GenerateUHTCompatibleHeaders)
    speak(ok and "Dump complete" or "Dump failed")
end)
pcall(RegisterKeyBind, Key.F12, { ModifierKey.CONTROL }, function()
    speak("Dumping objects")
    local ok = pcall(DumpAllObjects)
    speak(ok and "Object dump complete" or "Dump failed")
end)

-- ---------------------------------------------------------------------------
-- Hover-based read of PlayerPanel_C.
--
-- Property of this screen: the game updates `Select` (IntProperty on
-- TitlePlayerSelect_C) when the cursor crosses a character region but
-- does NOT call PlayerPanel_C:SetPlayer itself. So NameText/JobText/etc.
-- stay stuck at whatever the panel was last populated with. We bridge:
-- when Select changes in the poll, we call SetPlayer(Select) and schedule
-- a deferred announcement.
--
-- Why deferred (and not poll-stability): the panel populates its
-- TextBlocks via a typewriter animation. Per-tick stability checks fight
-- NVDA's interrupt-on-new-speak behaviour, producing audibly-truncated
-- announcements. A single ExecuteWithDelay(400ms) gives the typewriter
-- time to finish, then reads and speaks once. NVDA plays one full
-- announcement instead of interrupting partials.
-- ---------------------------------------------------------------------------
local last_panel_speech = nil  -- last full string we spoke
local last_panel_select = nil  -- last Select we observed (for SetPlayer bridge)

local function read_text_block(panel, field)
    local s = nil
    pcall(function()
        local tb = panel[field]
        if not tb then return end
        local ftext = nil
        pcall(function() ftext = tb:GetText() end)
        if not ftext then pcall(function() ftext = tb.Text end) end
        s = value_to_string(ftext)
    end)
    return s and s ~= "" and s or nil
end

-- Build the localized "name. class. path-action. talent." string from a
-- (presumed-settled) PlayerPanel_C instance. Returns nil if the panel
-- hasn't populated its name field at all.
local function build_player_panel_string(panel)
    local name = read_text_block(panel, "NameText")
    if not name then return nil end
    local job        = read_text_block(panel, "JobText")
    local pa_label   = read_text_block(panel, "FieldCommandText")
    local pa_value   = read_text_block(panel, "FieldCommand")
    local spec_label = read_text_block(panel, "SpecificText")
    local spec_value = read_text_block(panel, "Specific")

    local parts = { name }
    if job then parts[#parts + 1] = job end
    if pa_value then
        parts[#parts + 1] = pa_label and (pa_label .. ": " .. pa_value) or pa_value
    end
    if spec_value then
        parts[#parts + 1] = spec_label and (spec_label .. ": " .. spec_value) or spec_value
    end
    return table.concat(parts, ". ")
end

-- Forward-declared so poll_active_menu can call it.
poll_player_panel_info = function(active_cls)
    if active_cls ~= "TitlePlayerSelect_C" then
        last_panel_speech = nil
        last_panel_select = nil
        return
    end

    -- Find the live TitlePlayerSelect_C instance in our registry.
    local instance = nil
    for i = #scene_widgets, 1, -1 do
        local entry = scene_widgets[i]
        if entry[2] == "TitlePlayerSelect_C" then
            local w = entry[1]
            local alive = false
            pcall(function() alive = w and w:IsValid() end)
            if alive and widget_is_visible(w) then
                instance = w; break
            end
        end
    end
    if not instance then return end

    -- (Removed: hover-bridge that auto-announced when Select changed.
    -- After every cycle / F5, the game reverts Select back to whatever
    -- the cursor is parked on. The bridge then fired "Olberic" right
    -- after the cycle/F5 announcement and interrupted it. Cursor-driven
    -- navigation isn't viable on this screen anyway since we can't move
    -- the visual cursor reliably; users navigate via Page Up/Down.)
end

-- ---------------------------------------------------------------------------
-- TitlePlayerSelect cycle helper.
--
-- The character-select screen is a free-cursor map (each traveler is placed
-- at a fixed point in screen space; sighted players move a free cursor
-- around to pick one). Without sight, free movement is unusable. We bind
-- Page Up/Down to the game's own SelectUpMove / SelectDownMove BP
-- functions, which discretely cycle through the 8 travelers and update the
-- visual cursor position so a subsequent confirm picks the announced one.
-- ---------------------------------------------------------------------------

local function find_visible_instance(cls)
    for i = #scene_widgets, 1, -1 do
        local entry = scene_widgets[i]
        if entry[2] == cls then
            local w = entry[1]
            local alive = false
            pcall(function() alive = w and w:IsValid() end)
            if alive and widget_is_visible(w) then return w end
        end
    end
    return nil
end

-- Cycle helper. Calls TitlePlayerSelect_C's own SelectUpMove / SelectDownMove
-- BP functions — those wrap UICursorDecrementLoop / IncrementLoop and also
-- drive the visual cursor on the map, so a confirm press after cycling lands
-- on the announced character. We then poll the panel until the displayed
-- name changes, then speak the full info. The polling generation counter
-- ensures rapid presses cancel earlier polls.
local cycle_poll_gen = 0

local function cycle_player_select(direction)
    if last_polled_class ~= "TitlePlayerSelect_C" then
        speak("Character cycle is only active on character select")
        return
    end
    local instance = find_visible_instance("TitlePlayerSelect_C")
    if not instance then return end

    -- Capture current name so we can detect when the panel actually
    -- updates after SelectDownMove. On the first press the panel is in
    -- a placeholder state ("1234. 剣士. ..."), and the game's Tick
    -- needs an indeterminate number of frames to populate it. Polling
    -- until the name changes is more reliable than picking a fixed delay.
    local panel_initial = nil
    pcall(function() panel_initial = instance.PlayerPanel_147 end)
    local prev_name = panel_initial and read_text_block(panel_initial, "NameText") or nil

    local fn_name = (direction > 0) and "SelectDownMove" or "SelectUpMove"
    local called = false
    pcall(function() instance[fn_name](instance); called = true end)
    if not called then
        log("cycle: " .. fn_name .. " call failed (BP function not callable)")
        speak("Cycle unavailable")
        return
    end

    cycle_poll_gen = cycle_poll_gen + 1
    local my_gen = cycle_poll_gen
    local poll_count = 0

    local function speak_panel(p)
        local combined = p and build_player_panel_string(p) or nil
        if combined and combined ~= "" then
            last_panel_speech = combined
            speak(combined)
        else
            local sel = nil
            pcall(function() sel = instance.Select end)
            speak("Character " .. tostring(sel or "?"))
        end
    end

    local function poll()
        if my_gen ~= cycle_poll_gen then return end  -- superseded by another press
        poll_count = poll_count + 1
        local p = nil
        pcall(function() p = instance.PlayerPanel_147 end)
        local cur_name = p and read_text_block(p, "NameText") or nil
        if cur_name and cur_name ~= prev_name then
            speak_panel(p)
        elseif poll_count >= 10 then  -- 500ms timeout
            speak_panel(p)
        else
            ExecuteWithDelay(50, poll)
        end
    end
    ExecuteWithDelay(50, poll)
end

do
    local up, down = nil, nil
    pcall(function() up   = Key.PAGE_UP   end)
    pcall(function() down = Key.PAGE_DOWN end)
    if up then
        local ok = pcall(RegisterKeyBind, up, function() cycle_player_select(-1) end)
        log("Bound Page Up cycle: " .. tostring(ok))
    end
    if down then
        local ok = pcall(RegisterKeyBind, down, function() cycle_player_select(1) end)
        log("Bound Page Down cycle: " .. tostring(ok))
    end
end

-- Manual "what am I on now" — walks the scene_widgets registry to find
-- which menu is actually visible right now. Falls back to last_spoken_class
-- if visibility detection fails on every entry.
pcall(RegisterKeyBind, Key.F10, { ModifierKey.CONTROL }, function()
    local result_class, result_label = nil, nil
    for i = #scene_widgets, 1, -1 do
        local entry = scene_widgets[i]
        local w, cls, label = entry[1], entry[2], entry[3]
        if widget_is_visible(w) then
            result_class = cls
            result_label = label
            break
        end
    end
    if result_label then
        last_spoken_class = result_class
        last_polled_class = result_class
        speak(result_label)
    elseif last_spoken_class then
        speak(SCENE_LABELS[last_spoken_class] or last_spoken_class)
    else
        speak("No menu detected")
    end
end)

return M
