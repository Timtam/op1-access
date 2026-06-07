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

-- Forward declarations so functions defined later in the file can be referenced
-- from earlier code without being captured as globals at compile time.
local poll_character_select
local poll_dialog
local find_visible_instance

-- A constructed TitlePlayerSelect_C, captured by on_widget_created (just below)
-- as a fallback candidate. The actual live on-screen instance is chosen each
-- poll by cs_live_instance() -- the one whose cursor position reads back -- so
-- this is only a backstop in case the registry is missing it.
local cs_instance = nil
local cs_last_err = nil  -- last distinct error from the char-select announcer (logged once)
-- Confirm-dialog (UICommonDialogBP_C) tracking. Instances are captured at
-- construction below; poll_dialog detects when one is actually on-screen.
local dialog_widgets = {}    -- all constructed UICommonDialogBP_C instances
local dlg_visible    = false -- was a dialog on-screen last tick (open/close edge)
local dlg_last_focus = nil   -- last announced answer index
-- Mute char-select coordinate read-outs briefly after a more-important
-- announce (screen name, character) so coords don't step on them. Declared
-- here (before poll_active_menu) so the screen-name announce can set it.
local CS_COORD_MUTE  = 30    -- ~1.5s at 50ms/poll
local cs_coord_mute  = 0     -- polls remaining

local function on_widget_created(NewObject)
    -- NotifyOnNewObject passes the UObject directly, NOT a hook-style
    -- parameter wrapper. Don't call :get() here.
    if not NewObject then return end
    local cls = class_name_of(NewObject)
    if not cls then return end

    -- Capture confirm-dialog widgets (not a SCENE_LABEL; handled by poll_dialog).
    if cls == "UICommonDialogBP_C" then
        dialog_widgets[#dialog_widgets + 1] = NewObject
    end

    local label = SCENE_LABELS[cls]
    if not label then return end

    log("widget created: " .. cls)

    -- Add to polling registry. The polling tick will walk this to find
    -- whatever scene widget is currently visible — handles back-out
    -- transitions (e.g. closing Save/Load and returning to Title) where
    -- no UIOpen / UIClose fires.
    scene_widgets[#scene_widgets + 1] = {NewObject, cls, label}
    if cls == "TitlePlayerSelect_C" then cs_instance = NewObject end

    -- Do NOT announce on construction. At launch the game builds dozens of menu
    -- widgets up-front (cached, never shown), which produced spurious launch
    -- speech like "Staff credits" / "Other". A screen is announced only when it
    -- actually becomes visible -- by the poll loop below, or the UIOpen hook.
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
    -- bespoke poll path (poll_character_select) that reads the localized
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
    -- Some menus' Select is a UObject, not an index; %d-formatting it later
    -- threw every tick in-game. Only proceed for a real numeric index.
    if type(sel) ~= "number" then return end

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

    -- A modal confirm dialog (UICommonDialogBP) takes priority: poll_dialog
    -- announces it and we suppress the underlying screen while it is open.
    if poll_dialog and poll_dialog() then return end

    if best_class and best_class ~= last_polled_class then
        last_polled_class = best_class
        last_spoken_class = best_class
        speak(best_label)
        cs_coord_mute = CS_COORD_MUTE   -- don't let coords step on the new screen name
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
    -- Wrapped so a throw inside surfaces in the log (the outer LoopAsync pcall
    -- would otherwise swallow it). Log each distinct error once. Guarded because
    -- the loop can tick once before poll_character_select is assigned at load.
    if poll_character_select then
        local cs_ok, cs_err = pcall(poll_character_select)
        if not cs_ok and cs_err ~= cs_last_err then
            cs_last_err = cs_err
            log("CS ERR: " .. tostring(cs_err))
        end
    end
end

-- Fire-and-forget polling loop. Wrap each tick in pcall: a Lua error
-- inside LoopAsync would otherwise stop subsequent ticks (or worse).
local talk_dbg = 0
local ok_loop = pcall(LoopAsync, POLL_INTERVAL_MS, function()
    pcall(poll_active_menu)
    -- Speak each story/dialogue line captured by the native GetTalkText hook.
    if shim and shim.PollTalk then
        local t = shim.PollTalk()
        if t and t ~= "" then log("STORY: " .. t) end  -- spoken by the native hook; loop only logs
    end
    -- DIAGNOSTIC (~2s): GetTalkText hook fire-count, so I can tell loop-alive +
    -- hook-firing from "didn't reach the prologue".
    talk_dbg = talk_dbg + 1
    if talk_dbg % 40 == 0 and shim and shim.TextCounts then
        local g = shim.TextCounts()
        log("GTT fired: " .. tostring(g))
    end
end)
log("Polling loop started: " .. tostring(ok_loop))

-- In-game: routed through KSUIManager.
safe_register("/Script/Octopath_Traveler.KSUIManager:Open",       on_ui_manager_open,        "KSUIManager.Open")
safe_register("/Script/Octopath_Traveler.KSUIManager:Close",      on_ui_manager_close,       "KSUIManager.Close")
-- KSUIManager:OpenDialog announce is disabled: UICommonDialogBP dialogs (title
-- confirm AND in-game prompts) are now handled uniformly by poll_dialog, which
-- detects them by visibility, adds answer-focus read-out, and avoids the
-- double-speak that registering both paths would cause.
-- safe_register("/Script/Octopath_Traveler.KSUIManager:OpenDialog", on_ui_manager_open_dialog, "KSUIManager.OpenDialog")

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
-- PlayerPanel_C read helpers. The panel shows the focused traveler's
-- localized name / job / path-action / talent as on-screen UTextBlocks.
-- Shared by the Page Up/Down cycle and the poll-driven announcer below.
-- ---------------------------------------------------------------------------

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

-- ---------------------------------------------------------------------------
-- Character-select (TitlePlayerSelect_C) announcer.
--
-- Free-cursor world map: a cursor glides around (the game eases
-- PlayerPositionMoved, an FVector2D) over 8 travelers at fixed points.
--
-- Hard-won facts from runtime logs:
--   * FindingPlayer (bool) IS the reliable on/off-traveler signal: true while
--     the cursor is on a traveler, false in empty space. (It looked dead in an
--     earlier pass only because those samples were taken after the cursor had
--     already left the traveler.)
--   * NameText is correct while FindingPlayer is true, but STICKY afterwards
--     (keeps the last name in empty space), so it must be gated by FindingPlayer.
--   * ItemPlayerPosition currently reads back as all-(0,0) and PlayerName as
--     opaque wrappers, so the "direction to nearest traveler" hint isn't
--     possible yet (deferred); empty space just reports coordinates. The
--     cs_load_positions / cs_nearest_* helpers below are kept for that future.
--
-- Announce model: on a traveler, speak the panel immediately (on name change).
-- In empty space, speak coordinates once the cursor SETTLES (same rounded cell
-- for CS_SETTLE_TICKS polls) -- one readout per pause, not a stream while
-- easing and not throttled away. Identical messages dedup. Driven by the 50ms
-- poll, gated on cs_live_instance().
-- ---------------------------------------------------------------------------

local CS_SETTLE_TICKS = 2    -- polls the cursor cell must hold before speaking coords (~100ms)
local CS_GAP_TICKS    = 8    -- max polls between coord readouts during a sustained sweep (~400ms)

-- Y-axis sense of the cursor space (for the deferred direction hint).
local CS_MAP_Y_DOWN = true

-- Announcer state, reset on leaving the screen.
local cs_last_char      = nil  -- last traveler name announced (don't repeat it)
local cs_last_cell      = nil  -- last coordinate cell announced (dedup)
local cs_settle_key     = nil  -- cell currently waiting to settle
local cs_settle_n       = 0    -- consecutive polls cs_settle_key has held
local cs_gap            = 0    -- polls since the last coordinate readout (sweep throttle)
local cs_lastlog_key    = nil  -- last diagnostic key logged (one line per change)
local cs_hb             = 0    -- heartbeat throttle counter (diagnostic)
local cs_item_positions = nil  -- (deferred hint) cached anchors, currently all (0,0)
local cs_pos_diag       = nil  -- (deferred hint) bounding-box diagonal
local cs_min_sep        = nil  -- (deferred hint) min pairwise distance
local cs_learned_names  = {}   -- (deferred hint) traveler index -> name
local cs_known          = {}   -- learned traveler name -> {sx,sy,n} position centroid
-- Anchor (ItemPlayerPosition) <-> cursor-space mapping. Measured from a full
-- cycle-through: the anchor frame is the cursor frame point-reflected (180 deg)
-- about an offset, i.e. cursor = (bx - anchor.x, by - anchor.y). Each anchor's
-- PlayerName (ePLAYABLE_CHARA_NAME_0X) gives the enum index -> traveler.
local CS_ANCHOR_NAME = { [0] = "Ophilia", [1] = "Cyrus", [2] = "Tressa", [3] = "Olberic",
                         [4] = "Primrose", [5] = "Alfyn", [6] = "Therion", [7] = "H'aanit" }
local CS_NAME_IDX = {}; for i, n in pairs(CS_ANCHOR_NAME) do CS_NAME_IDX[n] = i end
local CS_DEF_BX, CS_DEF_BY = 90, -79   -- default offset; refined at runtime from hovers

local function is_placeholder_name(name)
    return not name or name == "" or name == "1234"
end

-- Read the travelers' fixed map anchors WITHOUT visiting each: ItemPlayerPosition
-- (FVector2D[]) for positions, PlayerName (FName[]) for names. This read came
-- back all-zeros earlier (likely before the screen finished placing travelers),
-- so we RETRY every call and cache ONLY once the values look real (>=3 entries
-- with actual spread). Diagnostic-logged so a run shows if the game exposes them.
local cs_anchor_try = 0
local function cs_load_positions(instance)
    if cs_item_positions then return cs_item_positions end
    cs_anchor_try = cs_anchor_try + 1
    local names = {}
    pcall(function()
        local arr = instance.PlayerName
        if arr and arr.ForEach then
            arr:ForEach(function(_, v)
                local s
                pcall(function() s = v:get():ToString() end)   -- FName element
                if not s or s == "" then s = value_to_string(v) end
                names[#names + 1] = s
            end)
        end
    end)
    local positions, idx, sample = {}, 0, nil
    pcall(function()
        local arr = instance.ItemPlayerPosition
        if arr and arr.ForEach then
            arr:ForEach(function(_, v)
                idx = idx + 1
                local vx, vy
                pcall(function() local e = v:get(); vx, vy = e.X, e.Y end)
                if type(vx) ~= "number" then pcall(function() vx, vy = v.X, v.Y end) end
                if not sample then sample = string.format("x=%s,y=%s", tostring(vx), tostring(vy)) end
                if type(vx) == "number" and type(vy) == "number" then
                    local raw = names[idx]
                    local ei = tonumber(tostring(raw):match("(%d+)%s*$"))
                    positions[#positions + 1] = {
                        x = vx, y = vy, idx = ei,
                        name = (ei ~= nil and CS_ANCHOR_NAME[ei]) or raw,
                    }
                end
            end)
        end
    end)
    local minx, miny, maxx, maxy
    for _, p in ipairs(positions) do
        minx = math.min(minx or p.x, p.x); maxx = math.max(maxx or p.x, p.x)
        miny = math.min(miny or p.y, p.y); maxy = math.max(maxy or p.y, p.y)
    end
    local spread = maxx and ((maxx - minx) + (maxy - miny)) or 0
    if cs_anchor_try <= 15 then
        log(string.format("CS anchors try %d: n=%d spread=%.1f sample(%s) name1=%s",
            cs_anchor_try, #positions, spread, sample or "none", tostring(names[1])))
    end
    if #positions >= 3 and spread > 5 then
        cs_item_positions = positions
        for _, p in ipairs(positions) do
            log(string.format("CS anchor: %s at (%.1f, %.1f)", tostring(p.name), p.x, p.y))
        end
        return cs_item_positions
    end
    return nil   -- not populated yet; retry on a later call
end

-- Index (and distance) of the traveler nearest (x, y); nil if none loaded.
local function cs_nearest_index(positions, x, y)
    local bi, bd
    for i, p in ipairs(positions) do
        local dx, dy = p.x - x, p.y - y
        local d = dx * dx + dy * dy
        if not bd or d < bd then bi, bd = i, d end
    end
    if not bi then return nil end
    return bi, math.sqrt(bd)
end

-- (dx, dy) cursor->target -> 8-point compass word. Honors CS_MAP_Y_DOWN.
local function cs_direction_word(dx, dy)
    if not CS_MAP_Y_DOWN then dy = -dy end  -- normalize so +dy points south
    local ax, ay = math.abs(dx), math.abs(dy)
    if ax < 0.5 and ay < 0.5 then return "here" end
    local horiz = (dx >= 0) and "east" or "west"
    local vert  = (dy >= 0) and "south" or "north"
    if ax > ay * 2.5 then return horiz end
    if ay > ax * 2.5 then return vert end
    return vert .. "-" .. horiz
end

-- Distance word relative to the map's own scale; nil => mid-range, omitted.
local function cs_distance_word(d)
    if not cs_pos_diag then return nil end
    local frac = d / cs_pos_diag
    if frac < 0.10 then return "very near"
    elseif frac < 0.22 then return "near"
    elseif frac >= 0.45 then return "far" end
    return nil
end

-- "Ophilia south-east, near" for the traveler nearest (x, y); nil if unknown.
-- Prefers the localized name learned while hovering; falls back to PlayerName.
local function cs_nearest_hint(instance, x, y)
    local positions = cs_load_positions(instance)
    if not positions then return nil end
    local i, d = cs_nearest_index(positions, x, y)
    if not i then return nil end
    local p = positions[i]
    local nm = cs_learned_names[i]
    if not nm or nm == "" then nm = (p.name and p.name ~= "" and p.name) or "Traveler" end
    local s = nm .. " " .. cs_direction_word(p.x - x, p.y - y)
    local dist = cs_distance_word(d)
    if dist then s = s .. ", " .. dist end
    return s
end

-- Pick the LIVE, on-screen TitlePlayerSelect_C and its cursor position. Several
-- instances of this class get constructed; only the genuinely-active one
-- exposes a readable PlayerPositionMoved (the construction-captured duplicate
-- looks readable-once but its cursor struct never reads back -- that was the
-- silent bug). We require BOTH: the widget is on-screen (widget_is_visible --
-- otherwise arrow keys on the TITLE MENU would trigger char-select coordinate
-- read-outs, since the cached widget stays readable) AND a readable cursor
-- position (picks the live instance among duplicates). Returns instance,x,y/nil.
local function cs_live_instance()
    local seen = {}
    local function probe(w)
        if not w or seen[w] then return nil end
        seen[w] = true
        local ok = false
        pcall(function() ok = w:IsValid() end)
        if not ok then return nil end
        if not widget_is_visible(w) then return nil end   -- must be on-screen now
        local x, y
        pcall(function() local p = w.PlayerPositionMoved; if p then x, y = p.X, p.Y end end)
        if type(x) ~= "number" then
            pcall(function() local p = w.PlayerPositionMoved; if p then local g = p:get(); x, y = g.X, g.Y end end)
        end
        if type(x) == "number" and type(y) == "number" then return w, x, y end
        return nil
    end
    for i = #scene_widgets, 1, -1 do
        local e = scene_widgets[i]
        if e[2] == "TitlePlayerSelect_C" then
            local w, x, y = probe(e[1])
            if w then return w, x, y end
        end
    end
    return probe(cs_instance)
end

-- Forward-declared poll_dialog. The character-select confirmation (and other
-- title / system prompts) is a shared UICommonDialogBP_C, shown via the widget's
-- own OpenDialog -- NOT KSUIManager:OpenDialog -- so the old hook never saw it.
-- Detect it by visibility, read caption + answers (Answer_01..04) + the focused
-- answer (FocusIndex), and announce focus changes so moving Yes/No is spoken.
-- Returns true while a dialog is open so poll_active_menu suppresses the
-- underlying screen. Requires real content (caption/answers) so a cached,
-- hidden dialog widget can't false-trigger and mute everything.
poll_dialog = function()
    local inst, kept = nil, {}
    for i = 1, #dialog_widgets do
        local w = dialog_widgets[i]
        local alive = false
        pcall(function() alive = w and w:IsValid() end)
        if alive then
            kept[#kept + 1] = w
            if widget_is_visible(w) then inst = w end   -- last visible wins
        end
    end
    dialog_widgets = kept
    if not inst then
        dlg_visible, dlg_last_focus = false, nil
        return false
    end

    -- Real content comes from NowParam (a KSUICommonDialogParam: caption /
    -- detail / buttons), NOT the widget's CaptionText block, which holds a stale
    -- design default ("購入"). A cached launch dialog has an empty NowParam (no
    -- buttons), which also kills the launch false-trigger.
    local caption, detail, buttons, default = "", "", {}, 0
    pcall(function()
        local p = inst.NowParam
        if p then
            caption = ftext_to_string(p.CaptionText)
            detail  = ftext_to_string(p.DetailText)
            pcall(function() default = p.DefaultButton or 0 end)
            local arr = p.ButtonText
            if arr and arr.ForEach then
                arr:ForEach(function(_, v) local s = ftext_to_string(v); if s ~= "" then buttons[#buttons + 1] = s end end)
            end
        end
    end)
    -- Fallback for the buttons if the NowParam array doesn't marshal: read the
    -- Answer_01..04 widgets (these read fine before), skipping "000" placeholders.
    if #buttons == 0 then
        for i = 1, 4 do
            local t
            pcall(function() local item = inst["Answer_0" .. i]; if item then t = read_text_block(item, "Text") end end)
            if t and t ~= "" and t ~= "000" then buttons[#buttons + 1] = t end
        end
    end
    if #buttons == 0 then               -- no real answer buttons -> not a dialog we read
        dlg_visible, dlg_last_focus = false, nil
        return false
    end

    local focus = nil
    pcall(function() focus = inst.FocusIndex end)
    -- Effective selection: the live FocusIndex if valid, else the param's
    -- DefaultButton (FocusIndex reads -1 the instant the dialog opens), else 0.
    local ef = ((focus and focus >= 0) and focus)
        or ((default and default >= 0) and default) or 0
    local focused = buttons[ef + 1]

    if not dlg_visible then
        dlg_visible, dlg_last_focus = true, ef
        -- If the dialog is over the character-select screen, read the focused
        -- traveler's full description (PlayerPanel.PlayerDetail, a KSTextBlock)
        -- so the confirm reads e.g. "You are Ophilia, a Cleric... Begin? Yes".
        local desc = nil
        local cinst = cs_live_instance()
        if cinst then
            local panel
            pcall(function() panel = cinst.PlayerPanel_147 end)
            if panel then desc = read_text_block(panel, "PlayerDetail") end
        end
        log(string.format("DLG open: caption=%s detail=%s buttons=[%s] focus=%s default=%s ef=%s desc=%s",
            tostring(caption), tostring(detail), table.concat(buttons, "|"),
            tostring(focus), tostring(default), tostring(ef), tostring(desc)))
        local parts = {}
        if desc and desc ~= "" then parts[#parts + 1] = desc end
        if caption ~= "" then parts[#parts + 1] = caption end
        if detail  ~= "" then parts[#parts + 1] = detail end
        if focused and focused ~= "" then parts[#parts + 1] = focused end  -- only the selected answer
        if #parts > 0 then speak(table.concat(parts, ". ")) end
    elseif focus and focus >= 0 and focus ~= dlg_last_focus then
        dlg_last_focus = focus
        log(string.format("DLG focus -> %s = %s", tostring(focus), tostring(focused)))
        if focused and focused ~= "" then speak(focused) end
    end
    return true
end

-- Forward-declared (poll_character_select) so poll_active_menu can call it.
-- Runs every poll tick; gates on cs_live_instance() (readable cursor position),
-- NOT on the flaky widget-visibility/registry signals that kept starving it.
--
-- FindingPlayer and Select proved dead here (stuck at false/0 even while
-- hovering Ophilia -- they track the discrete Page Up/Down path, not the free
-- cursor), so on/off-traveler is decided geometrically from ItemPlayerPosition
-- vs the live PlayerPositionMoved. Candidate signals are still logged so the
-- next pass can confirm.
poll_character_select = function()
    local instance, x, y = cs_live_instance()

    -- Heartbeat (~1/s) so the log shows the gating truth even when silent:
    -- how many candidates exist, how many are visible, how many readable.
    cs_hb = cs_hb + 1
    if cs_hb >= 20 then
        cs_hb = 0
        if not cs_item_positions then cs_load_positions(instance) end  -- retry anchors
        local n, vis, rd = 0, 0, 0
        for i = 1, #scene_widgets do
            if scene_widgets[i][2] == "TitlePlayerSelect_C" then
                n = n + 1
                local w = scene_widgets[i][1]
                if widget_is_visible(w) then vis = vis + 1 end
                local px
                pcall(function() local p = w.PlayerPositionMoved; if p then px = p.X end end)
                if px ~= nil then rd = rd + 1 end
            end
        end
        if n > 0 or instance then
            log(string.format("CS hb: cands=%d vis=%d readable=%d picked=%s",
                n, vis, rd, tostring(instance ~= nil)))
        end
    end

    if not instance or not x or not y then
        cs_last_char, cs_last_cell, cs_settle_key, cs_settle_n, cs_lastlog_key, cs_gap = nil, nil, nil, 0, nil, 0
        cs_item_positions, cs_pos_diag, cs_min_sep, cs_learned_names = nil, nil, nil, {}
        cs_coord_mute = 0
        return
    end

    if cs_coord_mute > 0 then cs_coord_mute = cs_coord_mute - 1 end

    local finding = false
    pcall(function() finding = (instance.FindingPlayer == true) end)
    local panel
    pcall(function() panel = instance.PlayerPanel_147 end)
    local name = panel and read_text_block(panel, "NameText") or nil

    local cx, cy = math.floor(x + 0.5), math.floor(y + 0.5)
    local cell = string.format("%d,%d", cx, cy)

    -- (Cursor slow-down via writing InputScale was REVERTED: writing that live
    -- property every tick froze input and crashed the game. Don't write live
    -- UObject properties from the poll loop. The cursor stays at native speed;
    -- the periodic coordinate readout below softens the fast glides instead.)

    -- One diagnostic line per cell change (+ confirmable-signal candidates).
    if cell ~= cs_lastlog_key then
        cs_lastlog_key = cell
        local selC, selP, dec
        pcall(function() selC = instance.SelectCharacter end)
        pcall(function() selP = instance.SelectPlayer end)
        pcall(function() dec  = instance.IsDecide end)
        log(string.format("CS: pos=(%.1f,%.1f) find=%s selC=%s selP=%s dec=%s name=%s",
            x, y, tostring(finding), tostring(selC), tostring(selP), tostring(dec), tostring(name)))
    end

    -- Character: announce immediately on arrival at / change of traveler. The
    -- panel is read only while FindingPlayer is true (NameText is sticky
    -- otherwise). FindingPlayer spans a sizable zone, so coordinates below must
    -- still run while on a traveler, or it becomes a silent dead spot.
    if finding and not is_placeholder_name(name) then
        -- Learn this traveler's map position (centroid of its FindingPlayer
        -- zone) so the nearest-character guide can point to it later. NameText
        -- is reliable while FindingPlayer is true, so `name` is correct here.
        local kk = cs_known[name]
        if not kk then kk = { sx = 0, sy = 0, n = 0 }; cs_known[name] = kk end
        kk.sx, kk.sy, kk.n = kk.sx + x, kk.sy + y, kk.n + 1
        if name ~= cs_last_char then
            cs_last_char = name
            local s = build_player_panel_string(panel) or name
            if s and s ~= "" then
                speak(s)
                -- Don't let the arrival cell's coords interrupt the character.
                cs_last_cell, cs_gap = cell, 0
                cs_settle_key, cs_settle_n = cell, CS_SETTLE_TICKS
                cs_coord_mute = CS_COORD_MUTE
            end
        end
    else
        cs_last_char = nil  -- empty space / panel not ready: re-announce on return
    end

    -- Coordinates: speak when the cell changed AND either the cursor just
    -- settled (you paused -> one clean readout per move) or it's been a while
    -- mid-sweep (so holding a key gives periodic updates instead of silence
    -- between the start and end of a long glide).
    cs_gap = cs_gap + 1
    if cell ~= cs_settle_key then
        cs_settle_key, cs_settle_n = cell, 0
    else
        cs_settle_n = cs_settle_n + 1
    end
    if cs_coord_mute <= 0 and cell ~= cs_last_cell
        and (cs_settle_n == CS_SETTLE_TICKS or cs_gap >= CS_GAP_TICKS) then
        cs_last_cell, cs_gap = cell, 0
        speak(string.format("%d, %d", cx, cy))
    end
end

-- (No Tick hook: RegisterHook on the title BP's Tick returns false -- the BP
-- class isn't loaded at script-init time, so the hook can't bind. Liveness is
-- handled by cs_live_instance() in the poll loop instead.)

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

find_visible_instance = function(cls)
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
-- drive the visual cursor on the map, so a confirm press after cycling
-- lands on the announced character.
--
-- Speech: read the panel synchronously and speak immediately if the data
-- is real. This keeps Page Up/Down latency near zero on the common path.
-- We then stamp the poll-driven announcer's settle key with this traveler
-- so it skips re-announcing the same change (otherwise we'd double-speak on
-- every press). If the panel still has the "1234" placeholder (only happens
-- on the first press after entering the screen), we leave the announcement
-- to the poll loop, which will pick it up once the game's Tick finishes
-- populating the data.
local function cycle_player_select(direction)
    if last_polled_class ~= "TitlePlayerSelect_C" then
        speak("Character cycle is only active on character select")
        return
    end
    local instance = find_visible_instance("TitlePlayerSelect_C")
    if not instance then return end

    local fn_name = (direction > 0) and "SelectDownMove" or "SelectUpMove"
    local called = false
    pcall(function() instance[fn_name](instance); called = true end)
    if not called then
        log("cycle: " .. fn_name .. " call failed (BP function not callable)")
        speak("Cycle unavailable")
        return
    end

    local panel = nil
    pcall(function() panel = instance.PlayerPanel_147 end)
    local name = panel and read_text_block(panel, "NameText") or nil
    if is_placeholder_name(name) then return end  -- defer to poll loop

    local combined = build_player_panel_string(panel)
    if not combined or combined == "" then return end

    speak(combined)

    -- Mark this traveler as announced so the poll-driven announcer doesn't
    -- immediately repeat it, and mute coords so the cursor's jump onto the
    -- traveler doesn't read out over the character name.
    cs_last_char = name
    cs_coord_mute = CS_COORD_MUTE
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

-- Arrow keybinds. Jobs: (1) diagnostic KEY log; (2) NO-OP FEEDBACK with a
-- reason -- the cursor has momentum, so reversing direction stalls ~3-4 presses
-- (and map edges block it). When a press moves the cursor zero distance we say
-- "reversing" (the press was opposite the last steady direction) or "blocked"
-- (otherwise) plus the held coordinate, so a dead press is never silent and you
-- know WHY; (3) learn each arrow's world direction from steady runs, for the
-- nearest-character guide. Reads only; debounced; does not consume the key.
local CS_OPP = { UP_ARROW = "DOWN_ARROW", DOWN_ARROW = "UP_ARROW",
                 LEFT_ARROW = "RIGHT_ARROW", RIGHT_ARROW = "LEFT_ARROW" }
local cs_press_n    = 0
local cs_press_last = nil  -- pos string at the previous press, to flag "no move"
local cs_noop_gen   = 0
local cs_prev_key   = nil  -- previous arrow press
local cs_move_key   = nil  -- last arrow that produced steady movement
local cs_pp_x, cs_pp_y = nil, nil  -- previous press cursor pos (numbers)
local cs_key_delta  = {}   -- arrow -> {dx,dy} sign of the world movement it causes
local function on_arrow_log(kname)
    if dlg_visible then return end          -- a confirm dialog owns the keys; stay quiet
    local inst, x, y = cs_live_instance()
    if not inst or not x or not y then return end
    cs_press_n = cs_press_n + 1
    local here = string.format("%.1f,%.1f", x, y)
    local moved = (cs_press_last == nil) or (here ~= cs_press_last)
    log(string.format("KEY %s #%d pos=(%s) movedSinceLastPress=%s",
        kname, cs_press_n, here, tostring(moved)))

    -- Learn this arrow's direction from a steady run (same key as the previous
    -- press AND the cursor actually moved -> not an overshoot/switch press).
    if cs_prev_key == kname and moved and cs_pp_x then
        local dx, dy = x - cs_pp_x, y - cs_pp_y
        if math.abs(dx) > math.abs(dy) and math.abs(dx) >= 0.5 then
            cs_key_delta[kname] = { dx = (dx > 0 and 1 or -1), dy = 0 }; cs_move_key = kname
        elseif math.abs(dy) >= 0.5 then
            cs_key_delta[kname] = { dx = 0, dy = (dy > 0 and 1 or -1) }; cs_move_key = kname
        end
    end
    cs_prev_key = kname
    cs_pp_x, cs_pp_y = x, y
    cs_press_last = here

    -- No-op feedback (debounced): if the cursor hasn't moved ~250ms later, say
    -- why + the held coordinate, so a dead press is never silent.
    local px, py, pressed = math.floor(x + 0.5), math.floor(y + 0.5), kname
    cs_noop_gen = cs_noop_gen + 1
    local mygen = cs_noop_gen
    ExecuteWithDelay(250, function()
        if mygen ~= cs_noop_gen then return end          -- superseded by a newer press
        if dlg_visible then return end                   -- a dialog opened during the wait
        local i2, x2, y2 = cs_live_instance()
        if not i2 or not x2 or not y2 then return end
        local cx2, cy2 = math.floor(x2 + 0.5), math.floor(y2 + 0.5)
        if cx2 == px and cy2 == py then                  -- cursor never moved
            local label = (cs_move_key and pressed == CS_OPP[cs_move_key]) and "reversing" or "blocked"
            speak(string.format("%s, %d, %d", label, cx2, cy2))
        end
    end)
end
do
    for _, kn in ipairs({ "UP_ARROW", "DOWN_ARROW", "LEFT_ARROW", "RIGHT_ARROW" }) do
        local k = nil
        pcall(function() k = Key[kn] end)
        if k then
            local ok = pcall(RegisterKeyBind, k, function() on_arrow_log(kn) end)
            log("Bound diag key " .. kn .. ": " .. tostring(ok))
        end
    end
end

-- Nearest-character guide (bound to N). Points at the closest traveler whose
-- position we've learned (by hovering it, or cycling Page Up/Down which moves
-- the cursor onto each). It speaks the ARROW KEYS to press to get there --
-- learned from your own movement, so it's correct regardless of the map's odd
-- axis orientation -- plus the traveler's coordinates.
local CS_KEYWORD = { UP_ARROW = "up", DOWN_ARROW = "down",
                     LEFT_ARROW = "left", RIGHT_ARROW = "right" }
-- Default arrow->direction mapping measured from the logs (UP=+Y, DOWN=-Y,
-- LEFT=+X, RIGHT=-X). Used until your movement learns it (cs_key_delta, which
-- overrides) so the guide always has real directions -- never "move toward".
local CS_KEY_DEFAULT = { UP_ARROW = { dx = 0, dy = 1 }, DOWN_ARROW = { dx = 0, dy = -1 },
                         LEFT_ARROW = { dx = 1, dy = 0 }, RIGHT_ARROW = { dx = -1, dy = 0 } }
local function cs_key_toward(axis, want)
    for kn, d in pairs(cs_key_delta) do             -- learned (authoritative)
        if axis == "x" and d.dx == want then return kn end
        if axis == "y" and d.dy == want then return kn end
    end
    for kn, d in pairs(CS_KEY_DEFAULT) do            -- observed-default fallback
        if axis == "x" and d.dx == want then return kn end
        if axis == "y" and d.dy == want then return kn end
    end
    return nil
end
local function announce_nearest()
    local inst, cx, cy = cs_live_instance()
    if not inst or not cx or not cy then return end

    -- Offset b for cursor = (bx - anchor.x, by - anchor.y): start from the
    -- measured default, refine by averaging over any travelers actually hovered
    -- (matched to their anchor by enum index). Self-corrects if the default is
    -- off this session.
    local bx, by, bn = 0, 0, 0
    if cs_item_positions then
        for nm, k in pairs(cs_known) do
            local ei = CS_NAME_IDX[nm]
            if ei ~= nil and k.n > 0 then
                for _, a in ipairs(cs_item_positions) do
                    if a.idx == ei then
                        bx = bx + (k.sx / k.n + a.x); by = by + (k.sy / k.n + a.y); bn = bn + 1
                        break
                    end
                end
            end
        end
    end
    if bn > 0 then bx, by = bx / bn, by / bn else bx, by = CS_DEF_BX, CS_DEF_BY end

    -- Candidates: every anchor transformed into cursor space (known up-front, no
    -- hovering). Fall back to hovered centroids if anchors have not loaded yet.
    local cand = {}
    if cs_item_positions then
        for _, a in ipairs(cs_item_positions) do
            cand[#cand + 1] = { x = bx - a.x, y = by - a.y, name = a.name }
        end
    else
        for nm, k in pairs(cs_known) do
            if k.n > 0 then cand[#cand + 1] = { x = k.sx / k.n, y = k.sy / k.n, name = nm } end
        end
    end
    if #cand == 0 then
        speak("No characters mapped yet. Give it a second, then try again.")
        return
    end

    local bN, bD, tx, ty
    for _, c in ipairs(cand) do
        local d = math.sqrt((c.x - cx) ^ 2 + (c.y - cy) ^ 2)
        if not bD or d < bD then bN, bD, tx, ty = c.name, d, c.x, c.y end
    end
    local who = (bN and bN ~= "" and bN ~= "nil") and bN or "Character"
    if bD < 30 then speak(who .. ", here"); return end
    local dx, dy = tx - cx, ty - cy
    local parts = {}
    if math.abs(dy) >= 20 then local kw = cs_key_toward("y", dy > 0 and 1 or -1); if kw then parts[#parts + 1] = CS_KEYWORD[kw] end end
    if math.abs(dx) >= 20 then local kw = cs_key_toward("x", dx > 0 and 1 or -1); if kw then parts[#parts + 1] = CS_KEYWORD[kw] end end
    if #parts > 0 then
        speak(string.format("%s, %s. At %d, %d", who,
            table.concat(parts, " and "), math.floor(tx + 0.5), math.floor(ty + 0.5)))
    else
        speak(string.format("%s, at %d, %d", who, math.floor(tx + 0.5), math.floor(ty + 0.5)))
    end
end
do
    local k = nil
    pcall(function() k = Key.N end)
    local ok = k and pcall(RegisterKeyBind, k, announce_nearest)
    log("Bound nearest-character (N): " .. tostring(ok))
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

-- Install the native GetTalkText hook (in C++, via the shim) so story/dialogue
-- text is spoken in the player's language. Lua locates the UFunction; the shim
-- hooks its native exec (UFunction::Func at +0xB0) and reads the localized
-- OutText struct by offset -- the only path that works, since UE4SS's Lua
-- RegisterHook crashes on this function's struct out-param. A short delay lets
-- KSTextStatics finish loading.
-- RETRY until armed: dialogue reading was intermittent per-launch (works on a
-- later try), consistent with the UFunction / reflection not being ready at one
-- fixed delay. Re-attempt every 2s until the hook arms, then stop.
local function install_talk_hook(attempt)
    local armed = false
    local ok, uf = pcall(StaticFindObject, "/Script/Octopath_Traveler.KSTextStatics:GetTalkText")
    if ok and uf and uf:IsValid() and shim and shim.InstallTalkHook then
        armed = shim.InstallTalkHook(uf:GetAddress()) and true or false
    end
    log(string.format("GetTalkText hook attempt %d: armed=%s found=%s", attempt, tostring(armed),
        tostring(ok and uf ~= nil)))
    if not armed and attempt < 15 then
        ExecuteWithDelay(2000, function() install_talk_hook(attempt + 1) end)
    end
end
ExecuteWithDelay(2000, function() install_talk_hook(1) end)

return M
