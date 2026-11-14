-- OP1Access — Octopath Traveler screen-reader mod (Lua entry)
--
-- Architecture:
--   Lua here drives policy (what to speak, when, in response to which game
--   events). The C++ shim (OP1AccessShim.dll) statically links Lua 5.4 and
--   exposes Speak / Silence / IsSpeakingSupported, backed by Prism (NVDA,
--   JAWS, ... or OneCore/SAPI when no screen reader runs).

local M = {}

-- The eight travelers' display names (identical in the English and German text). A
-- dialogue line spoken by one of them is the PLAYER's party talking, never an NPC.
M.TRAVELER = { Ophilia = true, Cyrus = true, Tressa = true, Olberic = true, Primrose = true,
               Alfyn = true, Therion = true, ["H'aanit"] = true, ["H\u{2019}aanit"] = true }

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

-- Speak a focused MENU ITEM with the right interrupt behaviour. When a menu opens,
-- poll_active_menu speaks the screen NAME and sets M.await_first_item; the first item then
-- QUEUES after the name (interrupt=false) so you hear "Menu name, first option" in order.
-- Every later item (cursor move) INTERRUPTS so fast navigation doesn't pile up. The item
-- readers also HOLD their first announce until await_first_item is set (see their hold
-- checks), so the name always comes out first.
M.say_item = function(text)
    if not text or text == "" then return end
    if M.await_first_item then
        M.await_first_item = false
        speak(text, false)   -- queue after the screen name
    else
        speak(text, true)    -- interrupt (navigation)
    end
end

-- Focus gate. When the game window loses focus its main thread stops ticking, so calling
-- ANY game UFunction (line traces, position reads, nav steering, hook callbacks) from our
-- pump / loops / RegisterHook callbacks then faults uncatchably and crashes the game
-- (repro: alt-tab while standing on the map). Every periodic driver AND every registered
-- hook gates on this; logs the in<->out transition once so the cause is visible.
-- (hung off M to avoid the main-chunk 200-local limit; last-state is a closure upvalue)
do
    local last = true
    M.fg_ok = function()
        if not (shim and shim.IsForeground) then return true end
        local fg = true; pcall(function() fg = shim.IsForeground() end)
        if fg ~= last then last = fg; log("FOCUS: " .. (fg and "in" or "OUT -- game calls suspended")) end
        return fg
    end
    -- Wrap a RegisterHook / NotifyOnNewObject callback so it no-ops while unfocused.
    M.fg_guard = function(fn) return function(...) if not M.fg_ok() then return end return fn(...) end end
end

-- Run fn on the GAME thread. Doing game-object work (FindAllOf, IsValid, ProcessEvent,
-- position reads) from our async LoopAsync / keybind threads races the game freeing
-- actors (streaming as you walk, mass-freed on window focus-loss) -> uncatchable
-- IsA/ProcessEvent crashes. ExecuteInGameThread serializes us with the game's frame so
-- actors are never half-freed under us. Falls back to direct call if unavailable.
M.in_gt = function(fn)
    if ExecuteInGameThread then ExecuteInGameThread(fn) else fn() end
end
log("game-thread exec driver: " .. (ExecuteInGameThread and "ExecuteInGameThread" or "DIRECT (fallback -- not available!)"))

-- Hook enablement (globals, not chunk locals, to dodge the main-chunk 200-local limit).
-- These are the conclusion of isolating the focus-out crash:
--   OP1_NO_CREATED = true  -- NotifyOnNewObject (every widget construction) is THE focus-
--     out crash: UE4SS's IsA class-match faults on a half-built widget during the
--     focus-change HUD rebuild, before our callback, so pcall can't catch it. Removed for
--     good; menu detection is now event-driven (UIOpen) + KSUIManager:GetActiveStack.
--   OP1_NO_UICLOSE = true  -- the close hooks are unneeded (poll_active_menu / poll_dialog
--     handle close + re-announce) and a teardown-dispatch risk, so leave them off.
-- The rest are safe and ON.
OP1_NO_UICLOSE = true   -- KSUserWidgetBase:UIClose + KSUIManager:Close (off)
OP1_NO_UIOPEN  = false  -- KSUserWidgetBase:UIOpen + KSUIManager:Open (on)
OP1_NO_CREATED = true   -- NotifyOnNewObject widget-created (off -- was the crash)
OP1_NO_TICK = false     -- EventManagerBP:ReceiveTick (pump driver, on)
OP1_NO_TALK = false     -- NPC Talk hook (on)
OP1_NO_CS   = false     -- char-select OnCursor (on)

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
    TitleMainMenu_00_C       = "Press any button",
    TitleMainMenu_01_C       = "Title menu",
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
    -- Options. On this (Steam) build the ACTUAL options screen the UI manager focuses is
    -- OptionMenuSteamWBP_C (confirmed via GetActiveStack); OptionMenuWBP_C is the non-Steam
    -- variant. Both carry the option-menu fields directly (IsActive/CursorIndex/
    -- OptItemVerticalBox/TitleText/OptionKindArray) and are read the same way in poll_options.
    OptionMenuWBP_C          = "Options",
    OptionMenuSteamWBP_C     = "Options",
    -- Field command (the path-action menu opened with J near an NPC/object)
    FieldCommandMenu_C       = "Path action",
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
    [0]  = true,  -- "Title screen": KSUIManager fires it spuriously during loads;
                  -- the real title is the bespoke UIMainTitle (poll loop -> "Title").
    [27] = true, [103] = true, [104] = true,
}

-- Auto-radar menu gate. In-game menu / battle / shop / conversation widget CLASSES
-- whose VISIBLE presence means "not free exploration" (radar must go quiet).
-- Detected by a visibility scan of scene_widgets in the pump: KSUIManager:Open never
-- fires for this build, and per-widget UIOpen/UIClose don't reliably balance -- but
-- UWidget:IsVisible() cleanly distinguishes the active screen from the dozens of
-- cached widgets (same signal the title poll trusts). Dialogue / cutscene / flashback
-- / narration are caught separately by IsEventPlaying, so they're not listed here.
-- NOTE: JobStatusWidget_C and MainMenuEtcWidget_C are deliberately ABSENT -- they
-- report IsVisible()==true even while cached/closed on the field (a default
-- visibility quirk; the other sub-panels read hidden correctly). Both are reached
-- through the main menu, so MainMenuWidget_C (the root, which reads correctly)
-- covers them when actually open. Add a class here only after confirming via the
-- MENUVIS log that it reads hidden on the map.
local BLOCKING_CLASSES = {
    MainMenuWidget_C = true,  MainMenuItemListWidget_C = true, MainMenuAbilityWidget_C = true,
    MainMenuJobWidget_C = true, MainMenuTutorialListWidget_C = true, MainMenuMissionRecord_C = true,
    EquipmentMenuWidget_C = true, StatusMenuWidget_C = true,
    MenuSaveLoad_C = true,  OptionMenuWBP_C = true, OptionMenuSteamWBP_C = true,
    BattleCommandMenu_C = true, BattleResultPanelWidget_C = true,
    ChatWidget_C = true, PartyChat_C = true,
    FieldCommandMenu_C = true,   -- path-action menu (J): mute radar / no wall-bump while open
    -- path-action RESULT scenes (Study/Search, Purchase/Steal, Allure/Lure, Inquire/Judge,
    -- Provoke/Monster) -- dialog-like, read fine, but the radar must stay silent during them
    FieldCommandSearch_C = true, FieldCommandPurchase_C = true, FieldCommandLure_C = true,
    FieldCommandJudge_C = true, FieldCommandMonster_C = true,
    -- focused while a path action plays out (user log 2026-11-10): the bubble manager
    -- during the speech bubbles, the common dialog for the result boxes ("Ihr habt
    -- neue Informationen gewonnen!") -- the radar came back between the boxes.
    -- Active-stack only (not in SCENE_LABELS), so a cached copy can't block.
    BalloonManagerBP_C = true, UICommonDialogBP_C = true,
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
local scene_widgets = {}  -- list of {widget_uobject, class_name, label, addr}

-- Forward declarations so functions defined later in the file can be referenced
-- from earlier code without being captured as globals at compile time.
local poll_character_select
local poll_dialog
local find_visible_instance
local cs_live_instance
-- The poll loop's "currently-shown screen" (set in poll_active_menu). Hoisted
-- here so the construction hook can dedup its char-select screen-name announce
-- against the loop.
local last_polled_class

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

-- Add a widget to the scene_widgets registry, deduped by its live MEMORY ADDRESS
-- against the current registry (NOT a permanent per-class flag). This matters because
-- some title widgets (TitleMainMenu_*) have transient boot-time instances that get
-- freed and replaced -- a register-once flag locks in the dead instance and the live
-- one never gets added (poll_active_menu prunes the dead one, leaving nothing). Address
-- dedup lets a fresh instance register once the old one has been pruned, while still
-- ignoring repeat sightings of a still-live one. Shared by the title scan and UIOpen.
M.reg_add = function(w, cls, label)
    local addr
    pcall(function() if w and w:IsValid() then addr = w:GetAddress() end end)
    if not addr or addr == 0 then return end
    for i = 1, #scene_widgets do
        if scene_widgets[i][4] == addr then return end   -- already registered + live
    end
    scene_widgets[#scene_widgets + 1] = { w, cls, label, addr }
    if cls == "TitlePlayerSelect_C" then cs_instance = w end
end

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
    if cls == "TitlePlayerSelect_C" then
        cs_instance = NewObject
        -- "Choose your character" normally comes from the poll loop's visibility
        -- check -- but that loop intermittently dies after a level load. So also
        -- announce it event-driven here, gated so cached/never-shown instances
        -- built at launch stay silent: after a short delay, only if the screen is
        -- actually on-screen (cs_live_instance reads a live cursor) and the loop
        -- hasn't already named it.
        ExecuteWithDelay(500, function()
            if last_polled_class == "TitlePlayerSelect_C" then return end
            if not cs_live_instance or not cs_live_instance() then return end
            last_polled_class = "TitlePlayerSelect_C"
            last_spoken_class = "TitlePlayerSelect_C"
            cs_coord_mute = CS_COORD_MUTE
            speak(label)
        end)
    end

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
    -- Only announce KNOWN kinds. The old "Menu <n>" fallback for unmapped kinds was just
    -- a meaningless number and fired spuriously (e.g. kind 1 on the save/load -> title
    -- escape -> "Menu 1"). Real menus are read by poll_active_menu + the item readers;
    -- if a useful menu turns out to be unmapped, add its kind to UI_KIND_NAMES instead.
    local nm = UI_KIND_NAMES[k]
    if nm then speak(nm) end
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
    local off
    if label:find("Close") then off = OP1_NO_UICLOSE
    elseif label:find("Open") then off = OP1_NO_UIOPEN end
    if off then log("hook disabled by config: " .. label); return end
    local ok, err = pcall(RegisterHook, path, M.fg_guard(fn))
    log(string.format("RegisterHook %s: %s%s", label, tostring(ok),
        ok and "" or (" (" .. tostring(err) .. ")")))
end

-- Broad: every widget creation, via UE4SS's NotifyOnNewObject. Fires on
-- StaticConstructObject_Internal so BP-derived widgets are also caught.
-- This handles FIRST-time-ever construction. For repeat visits to the same
-- widget (e.g. Title -> Save/Load -> Title), we hook UIOpen below.
local ok_notify, err_notify = (not OP1_NO_CREATED) and pcall(NotifyOnNewObject, "/Script/UMG.UserWidget", M.fg_guard(on_widget_created)) or false
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
    -- Populate the registry event-driven (this replaces on_widget_created's job for
    -- in-game menus, which DO fire UIOpen). The pump's radar gate + poll_active_menu
    -- read scene_widgets. Address-deduped, so a reused cached widget isn't re-added.
    -- Runs on the game thread like the old construction hook (cross-thread shape unchanged).
    M.reg_add(widget, cls, label)
    -- in-game the save/load screen opens at a save point inside an event: its name
    -- ("Save") comes from the event reader (M.poll_event_menus), with its first slot
    if cls == "MenuSaveLoad_C" and M.field_player then return end
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

-- Screen-announce debounce: a screen SWITCH flickers best_class through several
-- transient "visible" widgets (cached menus read IsVisible=true the instant
-- they're constructed during a load/transition), which announced wrong screens
-- ("Other", "Job status", "Narration message"...). Require best_class to hold
-- steady for POLL_ANNOUNCE_SETTLE ticks before announcing -- collapsing a switch
-- to a single announce of the screen it actually lands on.
local POLL_ANNOUNCE_SETTLE = 4   -- ~200ms at 50ms/tick
local pending_polled_class = nil
local pending_polled_n     = 0

-- The poll loop announces ONLY these bespoke title-screen widgets, which are
-- visibility-toggled with no KS lifecycle event, so nothing else can detect them.
-- Every in-game menu is announced by the KSUIManager:Open hook instead -- keeping
-- those OUT of the loop is what stops freshly-constructed cached in-game widgets
-- from being read out during loads/transitions (the spurious-announce bug).
local TITLE_FLOW = {
    -- UIMainTitle_C is intentionally absent: it's the title ROOT, on screen only
    -- for the boot logo and the (visual-less) load into the prologue -- announcing
    -- it just produced a stray "Title". The real screens below are what matter.
    TitleMainMenu_00_C  = true,
    TitleMainMenu_01_C  = true,
    TitleOptionScene_C  = true,
    OptionMenuSteamWBP_C = true,  -- the actual focused options screen on the Steam build
    OptionMenuWBP_C     = true,   -- non-Steam options variant
    TitleLoadScene_C    = true,
    TitlePlayerSelect_C = true,
    MenuSaveLoad_C      = true,   -- reachable from the title (Continue / Load)
}

local function widget_is_visible(w)
    -- During the widget-teardown window (screen fade up / cutscene) a scene widget can
    -- be alive (IsValid true) yet have a half-freed slot/parent tree, so IsVisible()
    -- (a ProcessEvent UFunction) AVs walking it -- uncatchable by pcall. M.menu_unsafe
    -- (set by the pump) marks exactly that window; bail instead of poking the tree.
    if M.menu_unsafe then return false end
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

-- The UI manager's active-stack TOP is the single screen the game currently has focused
-- -- authoritative, unlike a visibility scan over the title's multiple flickering widget
-- copies (which made detection pick the wrong instance, esp. returning from a dialog).
-- KSUIManager:GetActiveStack() returns it. Cached manager handle, re-found if it dies.
-- On M (not a chunk local) to stay under the main-chunk 200-local limit.
M.get_active_screen = function()
    local kuim = M.ui_manager
    local ok = false
    if kuim then pcall(function() ok = kuim:IsValid() end) end
    if not ok then
        M.ui_manager = nil
        pcall(function() local x = FindFirstOf("KSUIManager"); if x and x:IsValid() then M.ui_manager = x end end)
        kuim = M.ui_manager
    end
    if not kuim then return nil, nil end
    local w = nil
    pcall(function() w = kuim:GetActiveStack() end)
    if not w then return nil, nil end
    local okw = false
    pcall(function() okw = w:IsValid() end)
    if not okw then return nil, nil end
    return w, class_name_of(w)
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

    -- On OPEN (owner_changed), hold until poll_active_menu has spoken the screen name
    -- (M.await_first_item), so the option comes out AFTER the name, not before it.
    if owner_changed and not M.await_first_item then return end

    last_select_owner = active_cls
    last_select_value = sel

    local label = resolve_menu_item_label(instance, sel, cfg)
    log(string.format("Item selection: %s idx=%d label=%s", active_cls, sel, tostring(label)))
    M.say_item(label or ("Item " .. tostring(sel)))
end

local function poll_active_menu()
    -- Skip the whole IsValid/IsVisible sweep during a fade/cutscene: the scene widgets
    -- may be mid-teardown and the UFunction calls AV uncatchably (the ProcessEvent
    -- crash). This runs on the async loop, which can't see world_susp; M.menu_unsafe is
    -- the pump's fade/event flag (false on the stable title, so title menus still read).
    if M.menu_unsafe then return end
    local kept = {}
    local best_idx, best_class, best_label = 0, nil, nil

    for i = 1, #scene_widgets do
        local entry = scene_widgets[i]
        local w, cls, label = entry[1], entry[2], entry[3]

        local alive = false
        pcall(function() alive = w and w:IsValid() end)
        if alive then
            kept[#kept + 1] = entry
            if TITLE_FLOW[cls] and widget_is_visible(w) then
                -- Most-recently-added visible widget wins — each title sub-screen
                -- is constructed after the root, so the highest-index visible entry
                -- is the active screen.
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

    -- Debounced announce (see POLL_ANNOUNCE_SETTLE): only speak once best_class
    -- has held steady, so a screen switch's transient widgets aren't each read out.
    if best_class == last_polled_class then
        pending_polled_class, pending_polled_n = nil, 0        -- already announced; stable
    elseif not best_class then
        last_polled_class = nil                                -- nothing visible; allow re-announce
        M.await_first_item = false                             -- void any stale "first item" flag
        pending_polled_class, pending_polled_n = nil, 0
    else
        -- A NEW screen is pending. Void the PREVIOUS screen's "first item" flag now (it may
        -- have set it without an item reader consuming it, e.g. "Press any button" before the
        -- title menu) so the item readers HOLD until THIS screen's name is spoken below.
        M.await_first_item = false
        if M.dlg_closed_t and os.clock() - M.dlg_closed_t < 1.5 then
            -- a confirm dialog just closed: wait before re-reading the screen under it.
            -- "Ja" on a load / quit prompt starts a fade within that time (this poller
            -- then pauses on M.menu_unsafe), so the old screen isn't announced again
            -- just before it goes away ("Save and load" twice after loading)
            pending_polled_class, pending_polled_n = nil, 0
        elseif best_class == pending_polled_class then
            pending_polled_n = pending_polled_n + 1
        else
            pending_polled_class, pending_polled_n = best_class, 1
        end
        if pending_polled_n >= POLL_ANNOUNCE_SETTLE then
            last_polled_class = best_class
            last_spoken_class = best_class
            speak(best_label)              -- screen name (interrupts)
            M.await_first_item = true      -- the next item queues after this name (open)
            cs_coord_mute = CS_COORD_MUTE   -- don't let coords step on the new screen name
            pending_polled_class, pending_polled_n = nil, 0
        end
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

-- Talkable-NPC learning: no static data distinguishes talkable NPCs from set
-- dressing (NPCInfoData, event arrays and trigger collision all read identical),
-- so talkability is LEARNED: when dialogue text arrives via the native talk
-- hook, the nearest NPC gets marked. The radar pings only learned NPCs.
local npc_learned = {}        -- actor address -> record {learned?, name, namedone} (this session)
local npc_talking = nil       -- {addr,cat,t}: the EXACT actor whose Talk just fired
local learn_talk_npc          -- assigned later (needs the overworld helpers)

-- Precise talkable detection: hook the NPC Talk function. It takes no params, so
-- a Lua RegisterHook is safe (no struct marshalling). The context object IS the
-- NPC being talked to -- exact, not a "nearest" guess (which kept marking mute
-- bystanders 100+ units away). Also logs the real CLASS, so we learn what
-- talkable NPCs actually are (suspected: NOT KSFieldNPCCharacter_C).
local function on_talk_hook(ctx)
    pcall(function()
        local o = ctx
        if type(o) == "userdata" and o.get then local g = o:get(); if g then o = g end end
        if not (o and o.GetAddress) then return end
        local addr = o:GetAddress()
        if not addr or addr == 0 then return end
        local cls = "?"
        pcall(function() cls = o:GetClass():GetFName():ToString() end)
        local full = "?"
        pcall(function() full = o:GetFullName() end)
        npc_talking = { addr = addr, t = os.clock() }
        local rec = npc_learned[addr]
        if type(rec) ~= "table" then rec = {} ; npc_learned[addr] = rec end
        rec.learned = true; rec.keep = true
        log(string.format("TALKHOOK class=%s addr=%X full=%s", cls, addr, full))
    end)
end
-- RegisterHook fails at mod load (the NPC Blueprint class isn't loaded at the
-- title screen). Re-attempt from the radar pump until it takes -- same
-- load-timing lesson as the dialogue + cursor hooks.
local talk_hook_armed = false
local function arm_talk_hook()
    if OP1_NO_TALK then return end
    if talk_hook_armed then return end
    for _, path in ipairs({
        "/Game/Character/BP/Type/KSFieldNPCCharacter.KSFieldNPCCharacter_C:Talk",
        "/Game/Character/BP/Type/KSFieldCharacter.KSFieldCharacter_C:Talk",
    }) do
        local ok, id = pcall(RegisterHook, path, M.fg_guard(on_talk_hook))
        if ok and id ~= nil then
            talk_hook_armed = true
            log("Talk hook ARMED: " .. path)
        end
    end
end

-- Fire-and-forget polling loop. Wrap each tick in pcall: a Lua error
-- inside LoopAsync would otherwise stop subsequent ticks (or worse).
-- Save/Load menu reader. MenuSaveLoad_C.CursorIndex is the focused slot; SlotItems
-- is the slot-widget array; each MenuSaveLoadSlot_C exposes its on-screen text
-- (TextMap/TextArea/TextTopLevel/TextTopLevelName/TextDate/TextTime, already
-- localized) plus IsEnabled (used vs empty) and the SaveSlotData struct (PlayTime
-- in seconds). Announce the focused slot on open and on every cursor move.
-- State lives in a do-block; the fn hangs off M (no new chunk local -- cap is 200).
do
    local sl_menu, sl_idx
    M.saveload_reset = function() sl_idx = nil end
    -- evw: the menu handed over by M.poll_event_menus when it is open INSIDE an event
    -- (the save point's "Speichern"): then no visibility walk, property reads only, and
    -- the screen name is said here (the normal menu pollers stand down during events).
    M.poll_saveload = function(evw)
        local m = evw or sl_menu
        if not evw then
            -- inside an event the event reader owns this menu: the visibility test below
            -- fails then (M.menu_unsafe) and reset the cursor every tick -- "Save, Auto
            -- save" over and over (2026-11-14)
            if M.ev_now then return end
            local alive = false
            if m then pcall(function() alive = m:IsValid() end) end
            if not alive then
                m = nil
                pcall(function() local f = FindFirstOf("MenuSaveLoad_C"); if f and f:IsValid() then m = f end end)
                sl_menu = m
            end
            if not m or not widget_is_visible(m) then sl_idx = nil; return end
        end
        -- Gate on the menu actually accepting input: while it opens it sweeps the
        -- cursor through every slot (which would voice all 24), and AcceptControl is
        -- false during that. Once ready, announce each focus change immediately.
        local ready = false
        pcall(function() ready = m.AcceptControl and true or false end)
        if not ready then sl_idx = nil; return end
        local ci = nil
        pcall(function() ci = m.CursorIndex end)
        if ci == nil or ci == sl_idx then return end
        if sl_idx == nil then
            if evw then
                local save = false
                pcall(function() save = (m.IsSaveMode == true) end)
                log("SAVELOAD in event: save mode=" .. tostring(save))
                speak(save and "Save" or "Load")
                M.await_first_item = true      -- the slot queues after the name
            elseif not M.await_first_item then
                -- On OPEN (first focused slot), hold until poll_active_menu has spoken
                -- "Save and load" (M.await_first_item) so the slot comes AFTER the name.
                return
            end
        end
        sl_idx = ci
        local slot = nil
        pcall(function()
            local items = m.SlotItems
            if items then
                slot = items[ci + 1]                                   -- Lua arrays are 1-based
                if slot == nil and items.get then slot = items:get(ci) end  -- fallback: 0-based getter
            end
        end)
        -- The slot's name from what it IS, not from the cursor index: loading, the list
        -- starts with the autosave (SlotAuto); saving, the autosave is left out and index
        -- 0 is the first manual slot -- read as "Auto save" at the save point, every
        -- slot one off (2026-11-14). So: SlotAuto, else its place in NormalSlots.
        local label
        if slot then
            local sa = 0
            pcall(function() sa = slot:GetAddress() end)
            pcall(function()
                local a = m.SlotAuto
                if a and a:GetAddress() == sa then label = "Auto save" end
            end)
            if not label then
                pcall(function()
                    local n = 0
                    m.NormalSlots:ForEach(function(_, v)
                        n = n + 1
                        local o = v:get()
                        if not label and o and o:GetAddress() == sa then label = "Slot " .. n end
                    end)
                end)
            end
        end
        label = label or ((ci == 0) and "Auto save" or ("Slot " .. tostring(ci)))
        if not slot then M.say_item(label); return end
        -- IsEnabled = selectable, not "has a save": loading, empty slots are off; saving,
        -- the autosave is off (it can't be overwritten) though it holds a save. So
        -- "empty" comes from the save's play time (IsEnabled only if that is unreadable),
        -- and a filled but disabled slot says "can't be chosen" (the save point's
        -- "Auto save, empty" was wrong, 2026-11-14).
        local en = false
        pcall(function() en = slot.IsEnabled and true or false end)
        local secs = nil; pcall(function() secs = slot.SaveSlotData.PlayTime end)
        local has = en
        if type(secs) == "number" then has = secs > 0 end
        if not has then M.say_item(label .. ", empty"); return end
        local function gt(name)                                       -- localized text of a bound widget
            local r = nil
            pcall(function()
                local w = slot[name]
                if not w then return end
                -- in an event: the Text property, no UFunction call on the widget
                local t = evw and w.Text or w:GetText()
                if t then r = t:ToString() end
            end)
            if r == "" then r = nil end
            return r
        end
        local pt = nil
        if type(secs) == "number" and secs > 0 then
            local h, mn = math.floor(secs / 3600), math.floor((secs % 3600) / 60)
            pt = (h > 0 and (h .. " hours ") or "") .. mn .. " minutes"
        end
        local map, area = gt("TextMap"), gt("TextArea")
        local lvl, leader = gt("TextTopLevel"), gt("TextTopLevelName")
        local date, tm = gt("TextDate"), gt("TextTime")
        local parts = { label }
        if map then parts[#parts + 1] = map end
        if area then parts[#parts + 1] = area end
        if leader then parts[#parts + 1] = leader .. (lvl and (" level " .. lvl) or "") end
        if pt then parts[#parts + 1] = pt end
        if date then parts[#parts + 1] = date .. (tm and (" " .. tm) or "") end
        if not en then parts[#parts + 1] = "can't be chosen" end
        log(string.format("SAVELOAD slot %d enabled=%s map=%s pt=%s", ci, tostring(en), tostring(map), tostring(pt)))
        M.say_item(table.concat(parts, ", "))
    end
end

-- Current objective reader. The menu's "current story" panel lives at
-- PartyCharacterList_C.NowPlayingStoryPanel.characterName (a KSTextBlock holding the
-- objective text, e.g. "Zur Bibliothek gehen."). queue=true appends after the category
-- on menu open; queue=false (the Q keybind) interrupts and reads on demand.
M.read_objective = function(queue)
    local txt
    local lst; pcall(function() lst = FindAllOf("PartyCharacterList_C") end)
    if lst then for _, w in ipairs(lst) do
        local ok = false; pcall(function() ok = w:IsValid() end)
        if ok then
            pcall(function()
                local p = w.NowPlayingStoryPanel
                if p then local t = p.characterName
                    if t then local g = t:GetText(); if g then
                        local s = g:ToString()
                        if s and s ~= "" and s ~= "1234" then txt = s end
                    end end
                end
            end)
            if txt then break end
        end
    end end
    if txt then speak("Objective: " .. txt, not queue)
    elseif not queue then speak("No objective") end
end
pcall(RegisterKeyBind, Key.Q, function() M.read_objective(false) end)

-- Main (pause) menu category-list reader. The Escape menu's left list (Weltkarte /
-- Journal / Inventar / Ausruestung / ... / Status / Verschiedenes) lives in
-- MainMenuWidget_C.MainMenuList (a MainMenuList_C): CursorPosition is the selected
-- category; MainMenuPanel is a UMG VerticalBox of MainMenuItemPanel_C buttons, each with
-- a MenuText text block carrying the localized label. So: GetChildAt(cursor).MenuText.
-- Announce the selected category on open + each move (interrupt behaviour via say_item).
do
    local mm_idx
    M.poll_mainmenu = function()
        local mw
        for i = 1, #scene_widgets do
            local e = scene_widgets[i]
            if e[2] == "MainMenuWidget_C" then
                local vis = false; pcall(function() vis = e[1]:IsValid() and e[1]:IsVisible() end)
                if vis then mw = e[1] end
            end
        end
        if not mw then mm_idx = nil; return end
        local list; pcall(function() list = mw.MainMenuList end)
        if not list then mm_idx = nil; return end
        local ci; pcall(function() ci = list.CursorPosition end)
        if type(ci) ~= "number" or ci == mm_idx then return end
        local opening = (mm_idx == nil)   -- first announce since the menu opened
        mm_idx = ci
        -- MainMenuPanel child[0] is a non-category header (no MenuText), so the categories
        -- are children [1..N] and cursor ci maps to child[ci+1]. Disabled categories carry
        -- IsUnEnable (some, like locked features, have a "???" placeholder label).
        local label, un = nil, false
        pcall(function()
            local btn = list.MainMenuPanel and list.MainMenuPanel:GetChildAt(ci + 1)
            if btn then
                pcall(function() un = btn.IsUnEnable and true or false end)
                local t = btn.MenuText; if t then local g = t:GetText(); if g then label = g:ToString() end end
            end
        end)
        local say
        if not label or label == "" or label == "???" then
            say = un and "Unavailable" or ("Category " .. tostring(ci))
        else
            say = un and (label .. ", disabled") or label
        end
        M.say_item(say)
        -- On open, also read the current objective (queued after the category). Q re-reads
        -- it on demand. (Both requested.)
        if opening and M.read_objective then M.read_objective(true) end
    end
end

-- Tutorial pop-up reader. The pop-up's active widget is UITutorial_C; its current page
-- is UITutorial_C.NowPageTemplate (a UITutorialTemplateNN_C), whose PageText array holds
-- the page's text-block widgets (title, body, captions -- order varies per template, so
-- we read every non-empty entry). Announced when the text changes, which covers both the
-- pop-up appearing and paging forward/back through a multi-page tutorial.
do
    local last_tut
    M.poll_tutorial = function()
        local w, cls = M.get_active_screen()
        if cls ~= "UITutorial_C" then last_tut = nil; return end
        local tmpl; pcall(function() tmpl = w.NowPageTemplate end)
        if not tmpl then return end
        local arr; pcall(function() arr = tmpl.PageText end)
        if not arr or not arr.ForEach then return end
        local parts = {}
        pcall(function() arr:ForEach(function(_, v)
            local o = v; pcall(function() if v.get then o = v:get() end end)
            local s; pcall(function() local g = o:GetText(); if g then s = g:ToString() end end)
            if s and s ~= "" then parts[#parts + 1] = s end
        end) end)
        if #parts == 0 then return end
        local say = table.concat(parts, ". ")
        if say ~= last_tut then last_tut = say; speak(say) end
    end
end

-- Field-command (path-action) menu reader. Opened with J near an NPC/object; the focused
-- screen is FieldCommandMenu_C, CurrentCursor is the selected action, ShowVerticalBox is
-- the action buttons (FieldCommandMenuItemPanel_C) -- GetChildAt(cursor).Text is the label
-- ("Studieren"/Study, etc.). No header offset. Announce the action on open + each move.
do
    local fc_idx
    M.poll_fieldcommand = function()
        local w, cls = M.get_active_screen()
        if cls ~= "FieldCommandMenu_C" then fc_idx = nil; return end
        local ci; pcall(function() ci = w.CurrentCursor end)
        if type(ci) ~= "number" or ci == fc_idx then return end
        fc_idx = ci
        local label
        pcall(function()
            local box = w.ShowVerticalBox
            local btn = box and box:GetChildAt(ci)
            if btn then local t = btn.Text; if t then local g = t:GetText(); if g then label = g:ToString() end end end
        end)
        speak(label or ("Action " .. tostring(ci)))
    end
end

-- Options menu reader (title-screen flow). The live content is reached via the
-- VISIBLE TitleOptionScene_C.RefOptionMenu (NOT FindFirstOf -- that returns a
-- template that freezes on traversal). Focused row = OptItemVerticalBox child at
-- CursorIndex (a ListItemWidget_Opt*_C); label = its TitleWidget > child0
-- (ListColumnWidget_Col1_2_C) > Column1_Title; value = ExWidget read by control
-- class. Announce when the label+value string changes (covers row moves, category
-- switches, and live value edits). Gated on IsActive to skip the open/transition.
do
    local lastCat, lastRow, lastEntered, optDT
    -- The OptionItemData DataTable is the master, kind-keyed label store (groups -> items
    -- with OptionKind + ItemText1). The runtime TextLabel maps are incomplete (e.g. the
    -- audio gauges' captions are custom-drawn and absent), so caption-less rows resolve
    -- their label here via shim.OptionLabelForKind. Cache the table's address per session.
    local function optdt_get()
        if optDT then return optDT end
        local dt
        pcall(function() dt = StaticFindObject("/Game/UI/Option/Database/OptionItemData.OptionItemData") end)
        if not dt then
            pcall(function()
                local all = FindAllOf("DataTable")
                if all then for _, o in ipairs(all) do
                    local nm = ""; pcall(function() nm = o:GetFullName() end)
                    if nm:find("OptionItemData") and not nm:find("Steam") then dt = o; break end
                end end
            end)
        end
        if dt then pcall(function() optDT = dt:GetAddress() end) end
        return optDT
    end
    M.poll_options = function()
        local m2
        for i = 1, #scene_widgets do
            local e = scene_widgets[i]
            if e[2] == "TitleOptionScene_C" then
                local vis = false; pcall(function() vis = e[1]:IsValid() and e[1]:IsVisible() end)
                if vis then pcall(function() m2 = e[1].RefOptionMenu end) end
            elseif e[2] == "OptionMenuWBP_C" or e[2] == "OptionMenuSteamWBP_C" then
                -- The active-stack instance is the REAL option menu (not the FindFirstOf
                -- template the note warns about), so it's read directly. OptionMenuSteamWBP_C
                -- is the screen the UI manager actually focuses on this build; it carries
                -- the same option-menu fields, so the rest of this reader works unchanged.
                local vis = false; pcall(function() vis = e[1]:IsValid() and e[1]:IsVisible() end)
                if vis and not m2 then m2 = e[1] end
            end
        end
        if not m2 then lastCat, lastRow, lastEntered = nil, nil, nil; return end
        local active = false; pcall(function() active = m2.IsActive and true or false end)
        if not active then lastCat, lastRow, lastEntered = nil, nil, nil; return end
        -- On OPEN (nothing announced yet), hold until poll_active_menu has spoken the
        -- screen name (M.await_first_item), so "Options" comes out before the category.
        if lastCat == nil and lastRow == nil and not M.await_first_item then return end
        -- category name = the menu's TitleText header (e.g. "Spieloptionen")
        local cat; pcall(function() local t = m2.TitleText; if t then local g = t:GetText(); if g then cat = g:ToString() end end end)
        -- focused row: entered-flag (its CursorIcon is visible only INSIDE the rows,
        -- not while on the category list) + label (caption) + value (read by class)
        local entered, label, val = false, nil, nil
        local ci; pcall(function() ci = m2.CursorIndex end)
        if type(ci) == "number" then
            local row; pcall(function() row = m2.OptItemVerticalBox:GetChildAt(ci) end)
            if row then
                pcall(function() local c = row.CursorIcon; if c then entered = (c:IsVisible() == true) end end)
                pcall(function() local col = row.TitleWidget:GetChildAt(0); local ct = col and col.Column1_Title
                    if ct then local g = ct:GetText(); if g then label = g:ToString() end end end)
                local ex, isGauge = nil, false
                pcall(function() ex = row.ExWidget end)
                if ex then
                    local exc; pcall(function() exc = ex:GetClass():GetFName():ToString() end)
                    if exc == "ToggleButtonWBP_C" then
                        local on; pcall(function() on = ex.ToggleSwitch end)
                        pcall(function() local tw = on and ex.Text_True or ex.Text_False; if tw then local g = tw:GetText(); if g then val = g:ToString() end end end)
                    elseif exc == "IntGaugeWBP_C" then
                        isGauge = true
                        pcall(function() val = tostring(ex.CurrentValue) end)
                    else
                        -- generic: Arrow / DescAndSelect / TempButton / KeyConfig all expose a .Text
                        pcall(function() local t = ex.Text; if t then local g = t:GetText(); if g then val = g:ToString() end end end)
                    end
                    if (not label or label == "") then   -- some controls carry their own caption
                        pcall(function() local d = ex.DescriptionText; if d then local g = d:GetText(); if g then label = g:ToString() end end end)
                    end
                end
                -- gauges' caption is custom-drawn AND the first gauge in a group instead
                -- carries the group header ("Lautstärke") in Column1_Title -- so for gauges
                -- ALWAYS take the per-item label from the master OptionItemData DataTable
                -- (keyed by OptionKind). Other caption-less rows use it as a fallback too.
                if (isGauge or not label or label == "") and shim and shim.OptionLabelForKind then
                    local k; pcall(function() local ka = m2.OptionKindArray; if ka then k = ka[ci + 1] end end)
                    local dt = optdt_get()
                    if type(k) == "number" and dt then
                        pcall(function() local s = shim.OptionLabelForKind(dt, k); if s and s ~= "" then label = s end end)
                    end
                end
            end
        end
        local say
        if label and label ~= "" then say = label .. (val and val ~= "" and (", " .. val) or "")
        elseif val and val ~= "" then say = val end
        -- The focused row's CursorIcon is the only readable "inside the rows vs on the
        -- category list" signal, so drive everything off it:
        --  * category list (not entered) -> speak ONLY the category name on change
        --  * Enter (entered flips false->true) -> read the first option
        --  * moving rows while entered -> read each row (incl. live value edits)
        --  * Escape (entered true->false) -> re-announce the category for orientation
        if not entered then
            if cat and cat ~= lastCat then lastCat = cat; M.say_item(cat)
            elseif lastEntered then if cat then M.say_item(cat) end end
            lastRow = nil
        else
            if not lastEntered then
                if say and say ~= "" then lastRow = say; M.say_item(say) end
            elseif say and say ~= lastRow then
                lastRow = say; M.say_item(say)
            end
            if cat then lastCat = cat end
        end
        lastEntered = entered
    end
end

-- MENUS INSIDE AN EVENT: the save point's "Speichern" screen and its confirm dialog
-- open while IsEventPlaying is true, so the normal menu pollers stand down
-- (M.menu_unsafe, the cutscene-teardown crash guard) and the screen stayed silent
-- (known issue since 2026-11-11). While an in-game event -- never a fade -- is up, at
-- most 10x a second: ask the UI manager for the focused screen (one getter on a
-- persistent object, no widget-tree walk) and read a save/load menu or a confirm
-- dialog on top with property reads.
-- Runs on the GAME thread (M.in_gt from M.event_menus_tick): called straight from the
-- async loop, its GetActiveStack calls raced the game's own UI changes -- after idling
-- some minutes in the save point's menu the game crashed with a null read inside UE4SS
-- on that loop's thread (crash_2026_11_14_01_00_24.dmp).
M.poll_event_menus = function()
    if not (M.ev_now and not M.fade_now) then return end
    local w, cls = M.get_active_screen()
    if cls ~= M.evm_cls then
        log("EVENT screen: " .. tostring(cls))
        if cls ~= "MenuSaveLoad_C" and cls ~= "UICommonDialogBP_C" then pcall(M.saveload_reset) end
        M.evm_cls = cls
    end
    M.evm_active = true
    if cls == "MenuSaveLoad_C" or cls == "UICommonDialogBP_C" or dlg_visible then
        pcall(poll_dialog)      -- a dialog on top, or its close
    end
    if cls == "MenuSaveLoad_C" then pcall(M.poll_saveload, w) end
    M.evm_active = false
end
-- From the async loop: at most 10x a second, one call in flight, queue the reader onto
-- the game thread; outside events just forget the screen (no game calls here).
M.event_menus_tick = function()
    if not (M.ev_now and not M.fade_now) then
        if M.evm_cls then M.evm_cls = nil; pcall(M.saveload_reset) end
        return
    end
    local now = os.clock()
    if M.evm_queued and now - M.evm_queued < 2.0 then return end
    if now - (M.evm_t or 0) < 0.1 then return end
    M.evm_t, M.evm_queued = now, now
    M.in_gt(function()
        M.evm_queued = nil
        pcall(M.poll_event_menus)
    end)
end

local ok_loop = pcall(LoopAsync, POLL_INTERVAL_MS, function()
    if not M.fg_ok() then return end   -- unfocused: skip menu polls (game calls fault)
    pcall(M.event_menus_tick)
    -- Capture title widgets on THIS fast loop (20Hz) so the title menu reads immediately;
    -- the game-thread pump only ticks ~5Hz, which made it read seconds late. Pre-game only
    -- (not M.field_player) -- there are no streamed field actors to fault FindAllOf, same
    -- as poll_saveload's FindFirstOf which has run here since launch -- and never mid-fade
    -- (M.menu_unsafe). The find-once guard means it's a cheap registry walk once captured.
    if M.scan_scene and not M.field_player and not M.menu_unsafe then pcall(M.scan_scene) end
    pcall(poll_active_menu)
    pcall(M.poll_saveload)
    pcall(M.poll_options)
    pcall(M.poll_mainmenu)
    pcall(M.poll_tutorial)
    pcall(M.poll_fieldcommand)
    -- The native GetTalkText hook speaks dialogue directly (independent of this
    -- loop, which can die after a level load). The loop just logs the line.
    -- (dialogue polling moved into the radar pump: this loop dies intermittently
    -- after loads, and talkable-NPC learning must not die with it)
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
    local backend = shim.DetectScreenReader and shim.DetectScreenReader()
    log("speech backend: " .. tostring(backend) .. ", can speak: " .. tostring(shim.IsSpeakingSupported()))
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
local cs_cursor_pos            -- forward decl (defined below; Page Up/Down learns via it)
-- Anchor (ItemPlayerPosition) -> cursor-space mapping. Measured from a full
-- cycle-through (all 8 travelers): the anchor frame equals the cursor frame
-- shifted by a CONSTANT, i.e. cursor = (anchor.x + 12, anchor.y - 24). Delta x
-- was exactly +12 for every traveler, delta y -24/-25 -- so the anchors ARE the
-- travelers' cursor-space positions plus the cursor's fixed resting offset. This
-- is why the nearest guide can know all 8 at screen-open with no navigation.
-- Each anchor's PlayerName (ePLAYABLE_CHARA_NAME_0X) gives enum index -> traveler.
local CS_ANCHOR_NAME = { [0] = "Ophilia", [1] = "Cyrus", [2] = "Tressa", [3] = "Olberic",
                         [4] = "Primrose", [5] = "Alfyn", [6] = "Therion", [7] = "H'aanit" }
local CS_NAME_IDX = {}; for i, n in pairs(CS_ANCHOR_NAME) do CS_NAME_IDX[n] = i end
local CS_ANCHOR_OFF_X, CS_ANCHOR_OFF_Y = 12, -24  -- cursor = anchor + this (measured, all 8)

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
cs_live_instance = function()
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
    -- Detect a dialog by the FOCUSED screen (KSUIManager active stack), NOT by
    -- widget_is_visible on the cached dialog widget: that widget stays "visible" after
    -- the dialog closes, so the old check stayed stuck-open and wedged the menu
    -- underneath silent ("reading stops" after Quit -> No). The active stack is
    -- authoritative -- it returns the dialog only while it's truly up.
    local inst, acls = M.get_active_screen()
    if acls ~= "UICommonDialogBP_C" then inst = nil end
    if not inst then
        -- Dialog CLOSE edge: the screen underneath is unchanged (same class + cursor as
        -- before the dialog), so the screen/item pollers would dedup it and stay silent.
        -- Clear their dedup so it re-announces.
        if dlg_visible then
            last_polled_class = nil
            last_select_owner, last_select_value = nil, nil
            M.dlg_closed_t = os.clock()
        end
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
        -- a path-action result panel under the dialog (Scrutinize: the NPC's age,
        -- statement and the information gained) -- the dialog itself only says "OK"
        -- (not inside an event: that reader runs FindAllOf)
        if not desc and M.fc_result_text and not M.evm_active then
            local okr, r = pcall(M.fc_result_text, inst)
            if okr then desc = r end
        end
        log(string.format("DLG open: caption=%s detail=%s buttons=[%s] focus=%s default=%s ef=%s desc=%s",
            tostring(caption), tostring(detail), table.concat(buttons, "|"),
            tostring(focus), tostring(default), tostring(ef), tostring(desc)))
        local parts = {}
        if desc and desc ~= "" then parts[#parts + 1] = desc end
        if caption ~= "" then parts[#parts + 1] = caption end
        if detail  ~= "" then parts[#parts + 1] = detail end
        if focused and focused ~= "" then parts[#parts + 1] = focused end  -- only the selected answer
        if #parts > 0 then speak(M.join_sentences(parts)) end
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

    -- Character / coordinate announce is now handled by the OnCursor* hooks
    -- (correct instance, event-driven). Skip the poll-driven announce to avoid
    -- double-speak / wrong-instance reads. (Heartbeat + anchor load above still
    -- run, for the nearest-character guide.)
    do return end

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
    -- Detect char-select via cs_live_instance() (the instance whose cursor reads
    -- back) -- NOT last_polled_class, which the poll loop sets. When the loop dies
    -- after a load, the old gate left Page Up/Down dead even on the screen.
    local instance = cs_live_instance()
    if not instance then
        speak("Character cycle is only active on character select")
        return
    end

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

    -- Page Up/Down lands the cursor ON the cycled-to traveler, so this doubles as
    -- the position-learning pass for the N-key nearest guide: once the jump
    -- settles, record the cursor position under this traveler's name. Paging
    -- through the roster once teaches N everyone -- no manual map hunting. Guard
    -- with the name (skip if the user has already paged on) so fast paging never
    -- files a mid-jump position under the wrong traveler.
    local learn_name = name
    ExecuteWithDelay(300, function()
        local live = cs_live_instance()
        if not live then return end
        local panel2 = nil
        pcall(function() panel2 = live.PlayerPanel_147 end)
        local now_name = panel2 and read_text_block(panel2, "NameText") or nil
        if now_name ~= learn_name then return end
        local x, y = cs_cursor_pos(live)
        if not x or not y then return end
        local kk = cs_known[learn_name]
        if not kk then kk = { sx = 0, sy = 0, n = 0 }; cs_known[learn_name] = kk end
        kk.sx, kk.sy, kk.n = kk.sx + x, kk.sy + y, kk.n + 1
    end)
end

-- Page Up/Down serve TWO features from ONE binding (double-registering a key in
-- UE4SS is undefined): traveler cycling in char-select, nav-target cycling in the
-- field. The nav section (later in the file) installs its handler into nav_keys;
-- when it claims the press (returns true), char-select cycling is skipped.
nav_keys = nav_keys or {}
do
    local up, down = nil, nil
    pcall(function() up   = Key.PAGE_UP   end)
    pcall(function() down = Key.PAGE_DOWN end)
    if up then
        local ok = pcall(RegisterKeyBind, up, function()
            if nav_keys.obj and nav_keys.obj(-1) then return end
            cycle_player_select(-1)
        end)
        log("Bound Page Up cycle: " .. tostring(ok))
    end
    if down then
        local ok = pcall(RegisterKeyBind, down, function()
            if nav_keys.obj and nav_keys.obj(1) then return end
            cycle_player_select(1)
        end)
        log("Bound Page Down cycle: " .. tostring(ok))
    end
end

-- Shared one-shot char-select announce: speaks the hovered traveler (when on
-- one), else the cursor cell. Deduped via cs_last_char/cs_last_cell so it can be
-- driven by BOTH the poll loop and the arrow keys with no double-speak -- and so
-- the arrow keys keep char-select working when the poll loop has died. Carries no
-- loop-tick state (no settle/gap, no cs_coord_mute), so it is safe from a keybind.
local function cs_announce(instance, x, y)
    if not instance or not x or not y then return end
    local finding = false
    pcall(function() finding = (instance.FindingPlayer == true) end)
    local panel
    pcall(function() panel = instance.PlayerPanel_147 end)
    local name = panel and read_text_block(panel, "NameText") or nil
    local cx, cy = math.floor(x + 0.5), math.floor(y + 0.5)
    local cell = string.format("%d,%d", cx, cy)
    if finding and not is_placeholder_name(name) then
        -- Learn this traveler's cursor position (in the current cursor space) so the
        -- nearest-character guide (N) can point to it. Averaged over visits.
        local kk = cs_known[name]
        if not kk then kk = { sx = 0, sy = 0, n = 0 }; cs_known[name] = kk end
        kk.sx, kk.sy, kk.n = kk.sx + x, kk.sy + y, kk.n + 1
        if name ~= cs_last_char then
            cs_last_char = name
            cs_last_cell = cell          -- don't read the arrival coords over the name
            local s = build_player_panel_string(panel) or name
            if s and s ~= "" then speak(s) end
        end
    else
        cs_last_char = nil
        if cell ~= cs_last_cell then
            cs_last_cell = cell
            speak(string.format("%d, %d", cx, cy))
        end
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
local radar_pump   -- forward decl: assigned in the radar-pump section (field radar driver)
local bump_arrow_t   = 0.0   -- last arrow keypress time (bump detection, any screen)
local bump_arrow_key = nil   -- which arrow ("UP_ARROW", ...)
local wall_blocked   = {}    -- wall radar's latest blocked dirs (up/down/left/right -> true)
local beacon_rescan_at = nil -- set after a door/transition; beacon_step rescans the new area then
local beacon_rescan_say = false -- speak the object count after the next rescan? (area change: yes; menu close: no)
local world_susp  = false    -- radar pump's scene guard (true during events/transitions)
local function on_arrow_log(kname)
    bump_arrow_t = os.clock(); bump_arrow_key = kname
    -- on the game thread: keybind callbacks run on a UE4SS thread, and the pump reads actors
    if radar_pump then M.in_gt(function() pcall(radar_pump, "key") end) end
    do return end   -- superseded by the OnCursor* hooks (correct instance + event-driven)
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
        else
            cs_announce(i2, x2, y2)       -- moved: announce where we landed (works w/o the loop)
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
-- Arrow->direction mapping for the full-map cursor space (cs_cursor_pos = on-screen
-- cursor MINUS map scroll, which negates BOTH axes vs the raw scroll the old table
-- was measured against): RIGHT=+X, LEFT=-X, DOWN=+Y, UP=-Y. Confirmed live --
-- pressing Left took the cursor x from 17 to -33, i.e. Left decreases x.
local CS_KEY_DEFAULT = { UP_ARROW = { dx = 0, dy = -1 }, DOWN_ARROW = { dx = 0, dy = 1 },
                         LEFT_ARROW = { dx = -1, dy = 0 }, RIGHT_ARROW = { dx = 1, dy = 0 } }
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
-- Full-map cursor position = on-screen cursor (PlayerSelectCursor_41 render
-- transform, clamped +/-100) minus the map scroll (PlayerPositionMoved). Both the
-- cursor announce and the N guide use this so they share one coordinate space.
cs_cursor_pos = function(inst)
    if not inst then return nil, nil end
    local cx, cy, mx, my
    pcall(function() local t = inst.PlayerSelectCursor_41.RenderTransform.Translation; cx = t.X; cy = t.Y end)
    pcall(function() local p = inst.PlayerPositionMoved; mx = p.X; my = p.Y end)
    if type(cx) ~= "number" or type(cy) ~= "number" then return nil, nil end
    return cx - (type(mx) == "number" and mx or 0), cy - (type(my) == "number" and my or 0)
end

local function announce_nearest()
    local inst = cs_live_instance()
    if not inst then return end
    local cx, cy = cs_cursor_pos(inst)   -- same full-map cursor space as the announce
    if not cx or not cy then return end

    -- Travelers in cursor space, known from screen-open with NO navigation:
    -- anchor (ItemPlayerPosition, populates shortly after open) + the measured
    -- constant offset that maps the anchor frame onto the cursor frame. Page
    -- Up/Down's learned centroids (cs_known) override per-traveler with the exact
    -- measured spot, so the guide self-corrects if the offset is ever off.
    cs_load_positions(inst)            -- retry until the anchors populate
    local by_name = {}
    if cs_item_positions then
        for _, a in ipairs(cs_item_positions) do
            if a.name then
                by_name[a.name] = { x = a.x + CS_ANCHOR_OFF_X, y = a.y + CS_ANCHOR_OFF_Y, name = a.name }
            end
        end
    end
    for nm, k in pairs(cs_known) do
        if k.n > 0 then by_name[nm] = { x = k.sx / k.n, y = k.sy / k.n, name = nm } end
    end
    local cand = {}
    for _, c in pairs(by_name) do cand[#cand + 1] = c end
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

-- ===== Overworld (phase 4): field-command interaction read-out =====
-- FieldCommandManagerBP_C.ActiveCommandType (byte[] of KSFIeldCommandType) lists
-- what you can DO at your current spot -- talk/examine plus path actions (steal,
-- inquire, purchase, ...). ActiveCommandList holds the matching FieldCommandEvent
-- objects (which carry the target). PROBE: a key that reads + speaks the types, to
-- confirm the data path before wiring an automatic "you can interact" announce.
-- Ctrl+F9 chosen for zero game-control conflict; we'll pick an ergonomic key once
-- it's proven.
-- KSFIeldCommandType (UE4SS_ObjectDump): eGeneric=0, ePurchase=1, eSteal=2, eBattle=3,
-- eMonster=4, eBlessing=5, eLure=6, eExamination=7, eSearch=8. The traveler names are
-- inferred from the FieldCommandEvent* classes (Lead/Lure/Hear/Search/...); the J menu
-- reads the game's own localized labels, these English names only serve this probe.
local FIELD_CMD_NAME = {
    [0] = "Talk", [1] = "Purchase", [2] = "Steal", [3] = "Challenge",
    [4] = "Provoke", [5] = "Guide", [6] = "Allure", [7] = "Inquire", [8] = "Scrutinize",
}
local fcmd_mgr = nil
local function get_fcmd_mgr()
    if fcmd_mgr and fcmd_mgr:IsValid() then return fcmd_mgr, "cache" end
    fcmd_mgr = nil
    pcall(function()
        local cdo = StaticFindObject("/Script/Octopath_Traveler.Default__FieldCommandManager")
        if cdo then fcmd_mgr = cdo:GetInstance() end
    end)
    if fcmd_mgr and fcmd_mgr:IsValid() then return fcmd_mgr, "GetInstance" end
    fcmd_mgr = nil
    pcall(function() fcmd_mgr = FindFirstOf("FieldCommandManagerBP_C") end)
    if fcmd_mgr and fcmd_mgr:IsValid() then return fcmd_mgr, "FindFirstOf" end
    fcmd_mgr = nil
    return nil, "none"
end
local function read_active_commands(mgr)
    local names, raw = {}, {}
    pcall(function()
        local arr = mgr.ActiveCommandType
        if arr and arr.ForEach then
            arr:ForEach(function(_, v)
                local b
                pcall(function() b = v:get() end)
                if type(b) ~= "number" then pcall(function() b = v end) end
                if type(b) == "number" then
                    raw[#raw + 1] = b
                    names[#names + 1] = FIELD_CMD_NAME[b] or ("command " .. b)
                end
            end)
        end
    end)
    return names, raw
end
local function announce_interactions()
    local mgr, how = get_fcmd_mgr()
    if not mgr then log("FCMD: no manager"); speak("No interaction here"); return end
    local names, raw = read_active_commands(mgr)
    log(string.format("FCMD via %s: n=%d types=[%s]", how, #raw, table.concat(raw, ",")))
    if #names == 0 then speak("Nothing to interact with"); return end
    speak(table.concat(names, ", "))
end
do
    local ok = pcall(RegisterKeyBind, Key.F9, { ModifierKey.CONTROL }, announce_interactions)
    log("Bound interaction query (Ctrl+F9): " .. tostring(ok))
end

-- ===== Overworld foundations probe (phase 4): player + object positions =====
-- Proves the data path for spatial beacons + pathfinding BEFORE building the Steam
-- Audio engine: get the player object (KSCharacterFunction/Manager:GetPlayerObject
-- -> KSCharacterBase, an OBJECT return so no struct-marshalling wall), read its
-- world position via RootComponent.RelativeLocation (a PROPERTY read -- the safe
-- path that worked for char-select), enumerate a couple of object categories
-- on-demand via FindAllOf(SPECIFIC class) (never per-frame), read their positions,
-- and speak the nearest one's direction + distance. The direction frame + distance
-- scale are UNCALIBRATED here -- the log prints raw player/nearest deltas so we can
-- calibrate from one field test (same way the char-select axes were fixed). Ctrl+F8.
local NAV_CLASSES = {
    { cls = "TreasureBoxBP_C",       name = "chest" },
    { cls = "LevelTrigger_C",        name = "exit" },     -- area transitions (the BP, not the C++ base)
    { cls = "HouseEnterTriggerBP_C", name = "building" },  -- enter a house
    { cls = "ShopTriggerBP_C",       name = "shop" },
    { cls = "KSFieldNPCCharacter_C", name = "npc" },       -- townsfolk (moves -> read live)
    -- minimap markers (M.minimap_markers): the story NPCs the objective points at, other
    -- marked NPCs, and the exit glowing green toward the objective. No class to scan
    -- (cls = nil): the beacon / probe loops skip it.
    { markers = true,                name = "marker" },
}
local function read_actor_pos(obj)
    if not obj then return nil end
    -- Read the location inside the shim under SEH (shim.ActorLoc): a streamed-out /
    -- freed actor returns nil instead of crashing. A Lua obj:K2_GetActorLocation() or
    -- obj.RootComponent read on a dead object faults NATIVELY (ProcessEvent AV), which
    -- pcall cannot catch -> it took the whole game down (the recurring radar crash).
    local addr; pcall(function() addr = obj:GetAddress() end)
    if addr and shim and shim.ActorLoc then
        local x, y, z = shim.ActorLoc(addr)
        if type(x) == "number" then return x, y, z, "shim" end
        return nil
    end
    -- fallback only if the shim is somehow unavailable (then the radar can't read
    -- positions anyway); avoid the K2_GetActorLocation path entirely.
    local x, y, z
    pcall(function()
        local rc = obj.RootComponent
        if rc then local l = rc.RelativeLocation; x, y, z = l.X, l.Y, l.Z end
    end)
    if type(x) == "number" then return x, y, z, "rootcomp" end
    return nil
end
local function get_player_obj()
    local p = nil
    pcall(function()
        local cdo = StaticFindObject("/Script/Octopath_Traveler.Default__KSCharacterFunction")
        if cdo then p = cdo:GetPlayerObject() end
    end)
    if p and p:IsValid() then return p, "charfunc" end
    p = nil
    pcall(function()
        local cdo = StaticFindObject("/Script/Octopath_Traveler.Default__KSCharacterManager")
        if cdo then local mgr = cdo:GetInstance(); if mgr then p = mgr:GetPlayerObject() end end
    end)
    if p and p:IsValid() then return p, "charmgr" end
    return nil, "none"
end

-- (The Ctrl+F3 move probe that calibrated bump detection was removed once its
-- findings were baked in -- the main chunk lives at Lua's 200-local limit.)

-- Wall-bump feedback: input held (GetLastMovementInputVector) but velocity ~0 means
-- the player is pushing into a wall. Play a one-shot bump cue (type 6, Assets/bump.*)
-- on each fresh bump, with a short cooldown so holding gives a gentle repeat, not a
-- buzz. Driven by radar_pump whenever audio is initialized, radar on or off.
local BUMP_CUE = 6
local DOOR_CUE = 7
-- Stuck detection uses POSITION DISPLACEMENT between pumps, not velocity: most
-- pumps run inside the game's frame tick (EventManagerBP hook), where the
-- engine's velocity value is mid-update and reads as "moving" even against a
-- wall (that intermittently reset the old streak counter, killing retriggers).
-- Displacement is phase-immune: walking covers ~670 u/s, blocked is ~0.
local KEYDIR = { UP_ARROW = "up", DOWN_ARROW = "down", LEFT_ARROW = "left", RIGHT_ARROW = "right" }
local bump_px, bump_py, bump_pt          -- previous pump's position + time
local bump_pass0    = nil                -- hold-streak window start
local bump_lastpass = 0.0                -- last pump that saw "pushing + not moving"
local bump_inp_t    = 0.0                -- last time any pump saw movement input
local bump_snap     = nil                -- press-synchronized check: {t, x, y, key}
local bump_seen_press = 0.0              -- last bump_arrow_t already snapshotted
local bump_lastfire = 0.0
local bump_lastlog  = 0.0
local function bump_fire(now, why)
    if now - bump_lastfire < 0.35 then return end
    bump_lastfire = now
    log("BUMP fire (" .. why .. ")")
    pcall(function() shim.AudioPlayCue(BUMP_CUE) end)
end
local function bump_step()
    local p = get_player_obj()
    if not p then bump_px = nil; bump_snap = nil; return end
    local px, py = read_actor_pos(p)
    if not px then bump_px = nil; bump_snap = nil; return end
    local now = os.clock()
    local inpMag = 0
    pcall(function() local iv = p:GetLastMovementInputVector(); inpMag = math.sqrt(iv.X * iv.X + iv.Y * iv.Y) end)
    if inpMag > 0.5 then bump_inp_t = now end

    -- (1) press-synchronized check, DETERMINISTIC per tap: the keybind stamps every
    -- arrow press; the next pump snapshots the position; a pump 0.15-0.8s later
    -- measures how far we actually got. A blocked press moves ~0 units. This does
    -- not depend on the input vector, whose mid-frame reads miss most taps.
    if bump_arrow_t > bump_seen_press then
        bump_seen_press = bump_arrow_t
        -- only FRESH presses: a field press pumps at once (on_arrow_log), so it is seen
        -- within ~0.1 s. An older one was made in a menu/dialog (e.g. Up to "Ja" in the
        -- load dialog) and must not thud when the field comes back.
        -- (not the walker's own "face the target" tap after Arrived: M.face_t)
        if now - bump_arrow_t < 0.35 and not (M.face_t and now - M.face_t < 1.0) then
            bump_snap = { t = now, x = px, y = py, key = bump_arrow_key }
        end
    elseif bump_snap then
        local age = now - bump_snap.t
        if age > 0.8 then
            bump_snap = nil
        elseif age >= 0.15 then
            local moved = math.sqrt((px - bump_snap.x) ^ 2 + (py - bump_snap.y) ^ 2)
            local dirname = bump_snap.key and KEYDIR[bump_snap.key]
            -- gate against menu/dialog arrow presses (those move nothing either):
            -- need EITHER movement input seen recently (we're really steering the
            -- character) OR the wall radar's independent "that direction is blocked"
            local infield = (now - bump_inp_t) < 0.8
            local atwall  = (dirname and wall_blocked[dirname]) and true or false
            -- blocked presses measure EXACTLY 0 (log-verified); even the lightest
            -- real tap moves 15+. 6 units = blocked + tiny corner slides only.
            if moved < 6 and (infield or atwall) then
                bump_fire(now, string.format("press %s moved=%.0f", dirname or "?", moved))
            end
            bump_snap = nil
        end
    end

    -- (2) sustained-hold streak (time-window; one context-poisoned pump can't reset
    -- it -- only 0.45s without a passing pump does)
    local lx, ly, lt = bump_px, bump_py, bump_pt
    bump_px, bump_py, bump_pt = px, py, now
    if not (lx and lt) then return end
    local dt = now - lt
    local moved = math.sqrt((px - lx) ^ 2 + (py - ly) ^ 2)
    -- door / transition = a TELEPORT: displacement RATE far above any movement
    -- speed (in-building doors hop only a few hundred units, so distance alone
    -- can't tell them from walking -- but walking never exceeds ~1000 u/s while a
    -- hop between two pumps reads as 2000+). The absolute clause catches big map
    -- loads, where a long loading gap makes the rate small but the distance huge.
    local rate = moved / math.max(dt, 0.08)
    if (moved > 250 and rate > 2200) or moved > 1200 then
        log(string.format("DOOR jump=%.0f dt=%.2f rate=%.0f", moved, dt, rate))
        pcall(function() shim.AudioPlayCue(DOOR_CUE) end)
        if beacon_on then beacon_rescan_at = now + 0.7 end
        bump_snap = nil
        return
    end
    if dt < 0.05 or dt > 0.6 then return end      -- odd pump gap: just re-sample
    -- 25 u/s: pressed-against-wall is ~0 u/s, while even slow TAP-walking averages
    -- 100+ u/s (the old 120 u/s threshold made careful tapping read as "stuck")
    if inpMag > 0.5 and moved < 25 * dt then      -- pushing, but ~not moving
        if (not bump_pass0) or (now - bump_lastpass > 0.45) then bump_pass0 = now end
        bump_lastpass = now
        if now - bump_lastlog > 1.0 then
            bump_lastlog = now
            log(string.format("BUMP stuck %.2fs inp=%.2f moved=%.0f dt=%.2f", now - bump_pass0, inpMag, moved, dt))
        end
        if now - bump_pass0 >= 0.10 and now - bump_lastfire > 0.7 then
            bump_fire(now, "hold")
        end
    end
end

-- Calibrated 2026-06-07 (held each arrow ~2s, watched the world delta): movement
-- is world-axis-aligned, and the axes are SWAPPED vs screen intuition --
-- world X = the UP/DOWN arrow axis (UP=+X, DOWN=-X); world Y = the LEFT/RIGHT
-- arrow axis (RIGHT=+Y, LEFT=-Y). So a target's world (dx,dy) maps straight to the
-- arrow keys to press.
local function nav_dir(dx, dy)
    local ax, ay = math.abs(dx), math.abs(dy)
    local parts = {}
    if ax >= 0.4 * ay then parts[#parts + 1] = (dx > 0) and "up" or "down" end
    if ay >= 0.4 * ax then parts[#parts + 1] = (dy > 0) and "right" or "left" end
    if #parts == 0 then return "here" end
    return table.concat(parts, " ")
end
local nav_last_px, nav_last_py = nil, nil
local LEVEL_THRESH = 250  -- |dz| beyond this = another floor (one floor measured ~502 units; 250 clears same-floor jitter)
local function nav_probe()
    if world_susp then speak("Scene running"); return end
    local p, phow = get_player_obj()
    if not p then log("NAV: no player object"); speak("No player position"); return end
    local px, py, pz, pposhow = read_actor_pos(p)
    if not px then log("NAV: player pos unreadable (" .. phow .. ")"); speak("Player position unreadable"); return end
    log(string.format("NAV player via %s/%s = (%.0f, %.0f, %.0f)", phow, pposhow or "?", px, py, pz))
    if nav_last_px then
        log(string.format("NAVDELTA since last Ctrl+F8: dX=%.0f dY=%.0f", px - nav_last_px, py - nav_last_py))
    end
    nav_last_px, nav_last_py = px, py
    -- camera/facing yaw diagnostics: if some maps rotate the camera, the arrow-key
    -- frame rotates with it and the radar's world->ear mapping must follow. Compare
    -- these on a "consistent" map vs a "diagonal-feeling" map.
    do
        local yp, yc, ycam = "-", "-", "-"
        pcall(function() local r = p:K2_GetActorRotation(); yp = string.format("%.0f", r.Yaw) end)
        pcall(function() local r = p:GetControlRotation();  yc = string.format("%.0f", r.Yaw) end)
        pcall(function()
            local cams = FindAllOf("PlayerCameraManager")
            if cams then
                for _, c in pairs(cams) do
                    local okv = false; pcall(function() okv = c and c:IsValid() end)
                    if okv then local r = c:GetCameraRotation(); ycam = string.format("%.0f", r.Yaw); break end
                end
            end
        end)
        log(string.format("YAW pawn=%s ctrl=%s cam=%s", yp, yc, ycam))
    end
    local bestd, bestcat, bdx, bdy, bdz
    for _, c in ipairs(NAV_CLASSES) do
        local list = nil
        pcall(function() list = c.cls and FindAllOf(c.cls) end)
        local n, near = 0, nil
        if list then
            for _, o in pairs(list) do
                local okv = false
                pcall(function() okv = o and o:IsValid() end)
                if okv then
                    local ox, oy, oz = read_actor_pos(o)
                    if ox then
                        n = n + 1
                        local dx, dy = ox - px, oy - py
                        local d = math.sqrt(dx * dx + dy * dy)
                        if not near or d < near then near = d end
                        if not bestd or d < bestd then bestd, bestcat, bdx, bdy, bdz = d, c.name, dx, dy, (oz - pz) end
                    end
                end
            end
        end
        log(string.format("NAV %s: list=%s readable=%d nearest=%s", c.name,
            list and "ok" or "nil", n, near and string.format("%.0f", near) or "-"))
    end
    if not bestd then speak("No objects found"); return end
    log(string.format("NAV nearest=%s d=%.0f dx=%.0f dy=%.0f dz=%.0f", bestcat, bestd, bdx, bdy, bdz or 0))
    local lvl = ""
    if bdz and bdz > LEVEL_THRESH then lvl = ", above"
    elseif bdz and bdz < -LEVEL_THRESH then lvl = ", below" end
    speak(string.format("%s%s, %s, distance %d", bestcat, lvl, nav_dir(bdx, bdy), math.floor(bestd + 0.5)))
end
do
    local ok = pcall(RegisterKeyBind, Key.F8, { ModifierKey.CONTROL }, nav_probe)
    log("Bound nav probe (Ctrl+F8): " .. tostring(ok))
end

-- Screenshot key (Ctrl+F2): user-triggered window capture via the shim's own
-- PrintWindow grab (NOT the engine's high-res path, which crashes this build).
-- Writes a BMP next to the log; a helper converts it to PNG for inspection.
-- Inline in the closure (no chunk local: main chunk is at Lua's 200-local cap).
do
    local SHOT_PATH = "C:/Program Files (x86)/Steam/steamapps/common/OCTOPATH TRAVELER/Octopath_Traveler/Binaries/Win64/op1access_shot.bmp"
    -- ON THE GAME THREAD: PrintWindow sends WM_PRINT to the window's thread (the game
    -- thread). Called from the keybind thread it waited for the game thread while
    -- holding the Lua lock the game thread needed -> the game froze (2026-11-11).
    local ok = pcall(RegisterKeyBind, Key.F2, { ModifierKey.CONTROL }, function()
        ExecuteInGameThread(function()
            local done = false
            pcall(function() if shim and shim.Screenshot then done = shim.Screenshot(SHOT_PATH) end end)
            speak(done and "Screenshot saved" or "Screenshot failed")
            log("SCREENSHOT (shim) -> " .. tostring(done))
        end)
    end)
    log("Bound screenshot (Ctrl+F2): " .. tostring(ok))
end

-- ===== Spatial-audio test (phase 4 / Pillar A): isolate HRTF direction =====
-- Ctrl+F7 cycles a continuous test tone right -> left -> front -> back -> off via
-- the shim's Steam Audio engine. Confirms audio comes out of the shim in-process
-- AND that the direction is audible, before we drive sources from object positions.
local audio_inited = false
-- Ctrl+F7 test cycle. Phases 1-4 test the RENDERER alone (listener-space dirs,
-- bypassing the world mapping). Phases 5-8 place a real pinging source 300 units
-- away in WORLD space -- the end-to-end ground truth for the radar's axis mapping
-- ("world right" = the right-arrow side and MUST sound in the right ear). Phase 9
-- = off. Run with the radars off (the world test borrows beacon slot 0).
local audio_test_phase = 0
local AUDIO_TESTS = {
    { say = "engine right",                       sa = 0 },
    { say = "engine left",                        sa = 1 },
    { say = "engine front",                       sa = 2 },
    { say = "engine behind",                      sa = 3 },
    { say = "world right, the right arrow side",  dx = 0,    dy = 300 },
    { say = "world left, the left arrow side",    dx = 0,    dy = -300 },
    { say = "world front, the up arrow side",     dx = 300,  dy = 0 },
    { say = "world behind, the down arrow side",  dx = -300, dy = 0 },
    { say = "bump sound",                         bump = true },   -- direct one-shot playback check
}
local function audio_test_cycle()
    if not (shim and shim.AudioInit) then speak("Audio module not loaded"); return end
    if not audio_inited then
        local ok = false
        pcall(function() ok = shim.AudioInit() end)
        audio_inited = ok and true or false
        local st = "?"; pcall(function() st = shim.AudioStatus() end)
        log("AudioInit: " .. tostring(ok) .. " status=" .. tostring(st))
        if not audio_inited then speak("Audio init failed: " .. tostring(st)); return end
        load_cues()
    end
    audio_test_phase = (audio_test_phase % (#AUDIO_TESTS + 1)) + 1
    pcall(function() shim.AudioTest(4) end)                          -- engine test off
    pcall(function() shim.AudioSetSource(0, false, 0, 0, 0, 0) end)  -- world test off
    local t = AUDIO_TESTS[audio_test_phase]
    if not t then speak("test off"); return end
    if t.bump then
        pcall(function() shim.AudioPlayCue(BUMP_CUE) end)
    elseif t.sa then
        pcall(function() shim.AudioTest(t.sa) end)
    else
        local p = get_player_obj()
        local px, py, pz
        if p then px, py, pz = read_actor_pos(p) end
        if not px then speak("No player position"); return end
        pcall(function() shim.AudioSetListener(px, py, pz) end)
        pcall(function() shim.AudioSetSource(0, true, px + t.dx, py + t.dy, pz, 2) end)
    end
    speak(t.say)
end
do
    local ok = pcall(RegisterKeyBind, Key.F7, { ModifierKey.CONTROL }, audio_test_cycle)
    log("Bound audio test (Ctrl+F7): " .. tostring(ok))
end

-- ===== Live beacon (phase 4 / Pillar A milestone 2): nearest object tracks you =====
-- Ctrl+F6 toggles a beacon on the nearest chest/exit. On start we enumerate the
-- categories once (objects are static, so cache their positions); an ExecuteWithDelay
-- self-loop (~120ms, generation-guarded so toggling cancels cleanly) feeds the
-- player position as the Steam Audio listener and the nearest object as source 0,
-- so the cue pans + swells as you walk. Re-toggle after a map change to rescan.
local beacon_on  = false
local beacon_objs = {}
local beacon_slotof = {}   -- stable beacon_objs index -> shim slot (declick: one object, one slot)
-- Range model: ping EVERY object within a FIXED radius (no density filter), so an
-- object's presence + loudness map STEADILY to its distance. A radius that grew/
-- shrank with crowding could hide a nearby object just because the area was busy,
-- which breaks the distance estimation blind players rely on. HARDCAP is only a
-- slot-safety limit (the shim has 32 source slots).
local BEACON_RANGE   = 500      -- fixed audible radius (world units; ~500 each direction)
local BEACON_HARDCAP = 28       -- object beacons use slots 0..27; 28..31 reserved for wall radar
local CAT_CUE = { chest = 0, exit = 1, npc = 2, building = 3, shop = 4 }  -- category -> shim cue/freq

-- Custom cue assets: drop chest/exit/npc/building/shop/wall .flac|.mp3|.wav into the
-- mod's Assets/ folder and they replace the generated tones (played at the same
-- distance-driven ping rate). Missing files fall back to tones. Loaded once, lazily.
local ASSET_DIR = "C:\\Program Files (x86)\\Steam\\steamapps\\common\\OCTOPATH TRAVELER\\Octopath_Traveler\\Binaries\\Win64\\Mods\\OP1Access\\Assets\\"
local CUE_FILE  = { [0] = "chest", [1] = "exit", [2] = "npc", [3] = "building", [4] = "shop", [5] = "wall", [6] = "bump", [7] = "door",
                    [8] = "pathaction", [9] = "talk" }
local CUE_EXTS  = { "flac", "mp3", "wav" }   -- preference order; FLAC/MP3 keep files small
local cues_loaded = false
local function load_cues()
    if cues_loaded then return end
    if not (shim and shim.AudioLoadCue) then return end
    cues_loaded = true   -- once per session; changed files need a game restart
    for ct = 0, 9 do
        for _, ext in ipairs(CUE_EXTS) do
            local ok = false
            pcall(function() ok = shim.AudioLoadCue(ct, ASSET_DIR .. CUE_FILE[ct] .. "." .. ext) end)
            if ok then log("CUE " .. CUE_FILE[ct] .. " <- " .. ext); break end
        end
    end
end

-- RADAR rule for NPCs: LEARNED-ONLY. Every static field (NPCInfoData, the
-- EventID/EvetName arrays, trigger collision -- tcol=3 across all 17) reads
-- identical for talkable NPCs and set dressing, so talkability is learned at
-- runtime: when dialogue opens, learn_talk_npc marks the nearest NPC. The radar
-- starts quiet and grows as you meet people; targeting still lists everyone.
-- An NPC is real if its PLACEMENT DATA carries dialogue or event wiring: the
-- map's spawn table (GetPlacementData) holds TextLabel (the key the talk-text
-- database is queried with -- the exact linkage the talk boxes use), five
-- EventLabel slots, and the path-action IDs. Set dressing has none of them.
-- Session-learning (dialogue actually opened nearby) stays as a supplement.
-- npc_interesting -> keep, why, name. Decided by the NATIVE probe (shim
-- NpcProbe): GetPlacementData via ProcessEvent (Lua cannot touch BP struct
-- out-params -- that hard-crashed), TextLabel looked up in the talk database
-- silently, speaker name resolved to the localized display name. Results are
-- cached per actor in npc_learned (true = learned by real dialogue;
-- table = probe result).
-- Talkable detection by DIRECT PROPERTY READS (no Blueprint calls -> safe). The
-- NPC is stamped at spawn with its placement identity -- NPCUniqID + NPCLabel +
-- a cached PlacementData struct -- which keys /Game/Character/Database/
-- PlacementInfoList. A talkable NPC carries a non-empty TextLabel / NPCLabel;
-- set dressing carries None. Learning (a real Talk) always overrides.
local function fname_to_str(v)
    local s = nil
    pcall(function() s = v:ToString() end)
    if s == nil then pcall(function() s = tostring(v) end) end
    return s or ""
end
local function npc_interesting(o)
    local addr = nil
    pcall(function() addr = o:GetAddress() end)
    local rec = addr and npc_learned[addr]
    local learned = (rec == true) or (type(rec) == "table" and rec.learned) or false
    local lname = (type(rec) == "table" and rec.name) or nil

    local uniq, label, ptext = nil, "", ""
    pcall(function() uniq = o.NPCUniqID end)
    pcall(function() local f = o.NPCLabel; if f then label = fname_to_str(f) end end)
    pcall(function()
        local pd = o.PlacementData
        if pd then local f = pd.TextLabel; if f then ptext = fname_to_str(f) end end
    end)
    -- TextLabel is CN_NP_<TYPE>_<dialogueID>_<sub>. A zero dialogue ID (..._000000_..)
    -- means no lines (the COM_000000 placeholder); TEST_* are editor dummies. So:
    -- talkable iff the placement TextLabel carries a non-zero dialogue ID.
    local id = 0
    do local a = ptext:match("_(%d+)_%d+$"); if a then id = tonumber(a) or 0 end end
    local istest = label:find("^TEST_") ~= nil

    local keep = learned or (not istest and id > 0)
    local dbg = string.format("uniq=%s label=%s ptext=%s id=%d learned=%s",
        tostring(uniq), label == "" and "-" or label, ptext == "" and "-" or ptext, id, tostring(learned))
    return keep, dbg, lname
end


learn_talk_npc = function(ox, oy)
    -- dialogue raises the scene guard, so scanning is forbidden exactly when
    -- dialogue text arrives: QUEUE the player's last pre-dialogue position (the
    -- bump tracker freezes during suspension) and the pump processes it after
    -- the guard lifts.
    if world_susp then
        if not npc_learned._pend and bump_px then
            npc_learned._pend = { x = bump_px, y = bump_py, t = os.clock() }
        end
        return
    end
    local now = os.clock()
    -- precise path: the Talk hook already pinned the EXACT actor -- just attach
    -- the resolved speaker name to it, no proximity guessing
    if npc_talking and (now - npc_talking.t) < 30 then
        local nm = nil
        pcall(function() if shim and shim.LastSpeakerName then nm = shim.LastSpeakerName() end end)
        if nm and M.TRAVELER[nm] then nm = nil end   -- our own traveler spoke, not the NPC
        local rec = npc_learned[npc_talking.addr]
        if type(rec) ~= "table" then rec = {}; npc_learned[npc_talking.addr] = rec end
        rec.learned = true; rec.keep = true; rec.name = nm or rec.name
        log("LEARNED (talk hook) name=" .. tostring(rec.name))
        return
    end
    if not ox then
        -- a couple of lines arrive per dialogue box; one scan per few seconds is plenty
        if now - (npc_learned._t or 0) < 3.0 then return end
        npc_learned._t = now
    end
    local p = get_player_obj()
    if not p then return end
    local px, py, pz = read_actor_pos(p)
    if not px then return end
    if ox then px, py = ox, oy end
    local list = nil
    pcall(function() list = FindAllOf("KSFieldNPCCharacter_C") end)
    if not list then return end
    local best, bd = nil, 350      -- speakers stand close; same level only
    for _, o in pairs(list) do
        local okv = false
        pcall(function() okv = o and o:IsValid() end)
        if okv then
            local ox, oy, oz = read_actor_pos(o)
            if ox and math.abs((oz or pz) - pz) <= LEVEL_THRESH then
                local d = math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2)
                if d < bd then best, bd = o, d end
            end
        end
    end
    if best then
        local addr = nil
        pcall(function() addr = best:GetAddress() end)
        local nm = nil
        pcall(function() if shim and shim.LastSpeakerName then nm = shim.LastSpeakerName() end end)
        -- a line spoken by one of OUR travelers (Cyrus' path-action bubbles) must not
        -- name the nearest NPC "Cyrus" -- learn the NPC, leave its name to the static data
        if nm and M.TRAVELER[nm] then nm = nil end
        local cur = npc_learned[addr]
        if addr and not (type(cur) == "table" and cur.learned and cur.name) then
            -- real dialogue OVERRIDES any cached probe verdict, and carries the
            -- speaker's resolved display name (from the talk hook)
            npc_learned[addr] = { learned = true, keep = true, name = nm, dbg = "learned" }
            log(string.format("LEARNED talkable npc, d=%.0f name=%s", bd, tostring(nm)))
        end
    end
end
local function beacon_rescan()
    beacon_objs = {}
    beacon_slotof = {}
    for _, c in ipairs(NAV_CLASSES) do
        local list = nil
        pcall(function() list = c.cls and FindAllOf(c.cls) end)
        if list then
            for _, o in pairs(list) do
                local okv = false
                pcall(function() okv = o and o:IsValid() end)
                -- store the ACTOR (not a fixed position): NPCs wander, so the tick
                -- reads each one's live position. Cap defends against huge towns.
                if okv and #beacon_objs < 128 then
                    local keep = true
                    if c.name == "npc" then
                        local why, nm
                        keep, why, nm = npc_interesting(o)
                        log("NPC " .. (keep and "keep" or "omit") .. ": " .. why .. (nm and (" name=" .. nm) or ""))
                    end
                    if keep then
                        beacon_objs[#beacon_objs + 1] = { actor = o, cat = c.name }
                    end
                end
            end
        end
    end
    log("BEACON rescan: " .. #beacon_objs .. " objects")
end
local function beacon_step()   -- driven by radar_pump while beacon_on
    -- pending post-door rescan: silence everything, re-enumerate the NEW area's
    -- actors (the old handles died with the old map), report the fresh count
    if beacon_rescan_at then
        if os.clock() < beacon_rescan_at then
            -- a transition invalidated the cached handles: NEVER read the old
            -- actors while the rescan is pending (that was the door crash) --
            -- silence the slots and sit tight
            for i = 0, BEACON_HARDCAP - 1 do pcall(function() shim.AudioSetSource(i, false, 0, 0, 0, 0) end) end
            return
        end
        beacon_rescan_at = nil
        beacon_rescan()
        if beacon_rescan_say and #beacon_objs > 0 then
            -- only when the AREA changed: an NPC dialogue is a "scene" too, and
            -- "23 objects here" after every conversation was noise. Changed = the
            -- player is far from where exploring stopped (M.idle_from, set by the
            -- radar pump), or the object count differs from back then.
            local x, y
            local pl = get_player_obj()
            if pl then x, y = read_actor_pos(pl) end
            local o = M.idle_from
            local far = not (o and x) or math.sqrt((x - o.x) ^ 2 + (y - o.y) ^ 2) > 600
            if far or #beacon_objs ~= o.n then
                speak(string.format("%d objects here", #beacon_objs))
            end
        end
        beacon_rescan_say = false
    end
    local p = get_player_obj()
    local px, py, pz
    if p then px, py, pz = read_actor_pos(p) end
    if px then
        pcall(function() shim.AudioSetListener(px, py, pz) end)
        -- which tracked objects are in range right now, keyed by their STABLE index.
        -- SAME LEVEL ONLY: objects a floor above/below are unreachable and their
        -- mostly-vertical direction reads as vague/drifting left-right -- on
        -- multi-level maps (prologue building!) they just pollute the panorama.
        -- Crossing stairs changes pz, so the audible set re-filters itself live.
        -- Ctrl+F8 still reports off-level objects explicitly ("below"/"above").
        local r2 = BEACON_RANGE * BEACON_RANGE
        local inrange = {}
        for idx, o in ipairs(beacon_objs) do
            -- NO o.actor:IsValid() here: on a cached actor that the game freed/streamed
            -- out (e.g. on focus-loss) that call faults at UObjectBase::IsA, which pcall
            -- CANNOT catch -> it crashes the game. read_actor_pos goes through the shim's
            -- SEH-guarded ActorLoc, so a dead actor just yields nil and we skip it.
            local ox, oy, oz = read_actor_pos(o.actor)
            if ox then
                local dx, dy = ox - px, oy - py
                if dx * dx + dy * dy <= r2 and math.abs((oz or pz) - pz) <= LEVEL_THRESH then
                    inrange[idx] = { x = ox, y = oy, z = oz, cat = o.cat }
                end
            end
        end
        -- free slots whose object left range; remember which slots stay used
        local used = {}
        for idx, slot in pairs(beacon_slotof) do
            if not inrange[idx] then
                pcall(function() shim.AudioSetSource(slot, false, 0, 0, 0, 0) end)
                beacon_slotof[idx] = nil
            else
                used[slot] = true
            end
        end
        -- give each in-range object a STABLE slot (no rank-shuffle -> no position-jump
        -- click) and refresh its position
        for idx, info in pairs(inrange) do
            local slot = beacon_slotof[idx]
            if not slot then
                for s = 0, BEACON_HARDCAP - 1 do
                    if not used[s] then slot = s; used[s] = true; beacon_slotof[idx] = s; break end
                end
            end
            if slot then
                pcall(function() shim.AudioSetSource(slot, true, info.x, info.y, info.z, CAT_CUE[info.cat] or 0) end)
            end
        end
    end
end
local function beacon_deactivate_all()
    for i = 0, BEACON_HARDCAP - 1 do
        pcall(function() shim.AudioSetSource(i, false, 0, 0, 0, 0) end)
    end
    beacon_slotof = {}
end
-- (Ctrl+F6 beacon toggle removed: the radar is now always-on, auto-gated by the
-- exploration state in the pump -- see the AUTO RADAR block in radar_pump.)

-- ===== Wall-radar probe (phase 4 / A6): validate engine line-tracing =====
-- Before building the wall radar we must confirm we can cast a collision ray from
-- Lua. KismetSystemLibrary:LineTraceSingle is a normal ray-cast; FVector *params*
-- (as opposed to struct *returns*) marshal fine in UE4SS Lua. Ctrl+F5 traces the 4
-- cardinal directions from the player and reports which are blocked. If this works,
-- the radar is just "trace each tick -> panned tone for blocked dirs"; if it
-- crashes/fails we fall back to a C++ ProcessEvent trace. Trace channel 0 =
-- TraceTypeQuery1 (usually Visibility) -- tune if it doesn't see walls.
local WALL_DIRS = {
    { name = "up",    dx = 1,  dy = 0 },   -- world +X (screen up)
    { name = "down",  dx = -1, dy = 0 },
    { name = "right", dx = 0,  dy = 1 },   -- world +Y (screen right)
    { name = "left",  dx = 0,  dy = -1 },
}
-- Working LineTraceSingle call form (confirmed): colon syntax, OutHit passed as a
-- {} placeholder at param 8, returns the hit bool. Trace channel 0 = TraceTypeQuery1.
local TRACE_COL = { R = 0, G = 0, B = 0, A = 1 }
-- ch = ETraceTypeQuery (default 0 = TraceTypeQuery1/Visibility, used by the
-- pathfinder for ground/clearance). The wall radar passes 1+ because OT's invisible
-- collision walls (non-enterable archways, map fences) IGNORE channel 0 but BLOCK
-- channels 1-5 -- channel 0 literally cannot see them (confirmed via CHPROBE).
local function line_blocked(ksl, p, sx, sy, sz, ex, ey, ez, ch)
    local outHit = {}
    local ok, hit = pcall(function()
        return ksl:LineTraceSingle(p, { X = sx, Y = sy, Z = sz }, { X = ex, Y = ey, Z = ez },
            ch or 0, false, {}, 0, outHit, true, TRACE_COL, TRACE_COL, 0.0)
    end)
    return ok, hit, outHit
end
local function wall_probe()
    if world_susp then speak("Scene running"); return end
    local p = get_player_obj()
    if not p then speak("No player"); return end
    local px, py, pz = read_actor_pos(p)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not (ksl and px) then speak("No Kismet/pos"); return end
    local LEN = 230
    local blocked = {}
    for _, d in ipairs(WALL_DIRS) do
        local ok, hit, oh = line_blocked(ksl, p,
            px + d.dx * 30,  py + d.dy * 30,  pz + 30,
            px + d.dx * LEN, py + d.dy * LEN, pz + 30)
        local dist = "-"
        if type(oh) == "table" then pcall(function() if oh.Distance then dist = string.format("%.0f", oh.Distance) end end) end
        log(string.format("WALL %s: ok=%s hit=%s dist=%s", d.name, tostring(ok), tostring(hit), dist))
        if ok and hit then blocked[#blocked + 1] = d.name end
    end
    if #blocked == 0 then speak("No walls near") else speak("Blocked: " .. table.concat(blocked, ", ")) end
end
-- ===== Wall radar (phase 4 / A6): continuous panned wall tones =====
-- Each tick, trace the 4 cardinals; a blocked direction gets a subtle continuous
-- low hum placed in that direction (shim cue type 5 = wall, continuous + quiet).
-- Dedicated source slots 28..31 so it coexists with the object beacon. Ctrl+F5
-- toggles it; Ctrl+F4 is the one-shot speech scan.
local wall_on   = false
local wall_ticks = 0
local WALL_SLOT = { 28, 29, 30, 31 }   -- one shim source per WALL_DIRS entry
local WALL_CUE  = 5
local WALL_LEN  = 175   -- only detect walls within ~a few steps (avoid panorama clutter)
local function wall_step()   -- driven by radar_pump while wall_on
    wall_ticks = wall_ticks + 1
    -- function-local (avoids the chunk's 200-local cap). One knee-height ray per
    -- cardinal, on trace channel CH=1: channel 0 is blind to OT's invisible
    -- collision walls (confirmed -- the archway/fence barriers BLOCK ch 1-5, IGNORE
    -- ch 0), while ch 1 catches both those and normal vertical walls. Start close in
    -- (12u; the trace ignores self) so a wall you're pressed against isn't skipped.
    local OFF, KNEE, CH = 12, 30, 1
    pcall(function()
        local p = get_player_obj()
        local px, py, pz
        if p then px, py, pz = read_actor_pos(p) end
        local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        if not (px and ksl) then
            if wall_ticks % 16 == 0 then log(string.format("WALLTICK #%d no px/ksl", wall_ticks)) end
            return
        end
        pcall(function() shim.AudioSetListener(px, py, pz) end)
        local nblk = 0
        local dbg = {}
        for i, d in ipairs(WALL_DIRS) do
            local ok, hit, oh = line_blocked(ksl, p,
                px + d.dx * OFF,      py + d.dy * OFF,      pz + KNEE,
                px + d.dx * WALL_LEN, py + d.dy * WALL_LEN, pz + KNEE, CH)
            local slot = WALL_SLOT[i]
            if ok and hit then
                nblk = nblk + 1
                wall_blocked[d.name] = true        -- shared with bump detection
                local hd = 120
                if type(oh) == "table" then pcall(function() if type(oh.Distance) == "number" and oh.Distance >= 1 then hd = oh.Distance end end) end
                if hd < 30 then hd = 30 elseif hd > WALL_LEN then hd = WALL_LEN end
                pcall(function() shim.AudioSetSource(slot, true, px + d.dx * hd, py + d.dy * hd, pz, WALL_CUE) end)
                dbg[#dbg + 1] = string.format("%s%.0f", d.name:sub(1, 1), hd)
            else
                wall_blocked[d.name] = nil
                pcall(function() shim.AudioSetSource(slot, false, 0, 0, 0, WALL_CUE) end)
            end
        end
        if wall_ticks % 16 == 0 then
            log(string.format("WALLTICK #%d pos=(%.0f,%.0f) blk=%d %s", wall_ticks, px, py, nblk, table.concat(dbg, " ")))
        end
    end)
end
-- (Ctrl+F5 wall-radar toggle removed: always-on, auto-gated in the pump.)
do
    local ok4 = pcall(RegisterKeyBind, Key.F4, { ModifierKey.CONTROL }, wall_probe)
    log("Bound wall scan (Ctrl+F4): " .. tostring(ok4))
    -- (Ctrl+F5 wall-radar toggle removed: radar is always-on, auto-gated in the pump.)
end

-- ===== Pillar B v1: target selection + auto-walk =====
-- Ctrl+Left/Right cycles categories, Ctrl+Up/Down cycles that category's targets
-- (sorted nearest-first), Ctrl+Backspace speaks details + the walk path,
-- Ctrl+Enter walks there (press again to stop; any manual arrow press cancels).
-- Paths come from the engine navmesh when available (NavigationSystem:
-- FindPathToLocationSynchronously); otherwise a straight line. The walk driver
-- feeds AddMovementInput once per FRAME (from the tick hooks) -- exactly like
-- real player input, so collisions, triggers and random encounters behave
-- naturally.
local nav_walking = false             -- read by the radar pump
local nav_drive, nav_tick             -- assigned in the do-block; called by hooks/pump
local nav_guard_dispatch              -- combo id -> handler (set when the key guard arms)
-- everything else lives in a do-block: the main chunk is near Lua's 200-local limit
do
-- single state table: the main chunk is hard against Lua's 200-local limit
local NV = {
    cat = 1,            -- selected category index (NAV_CLASSES)
    list = {},          -- targets of that category, nearest first
    idx = 0,            -- selected target
    path = nil,         -- walk waypoints {x,y} ([1] = start)
    wp = 2,             -- current waypoint index
    started = 0.0,      -- walk start time
    prog = nil,         -- {t,x,y} last progress sample (stuck/battle watch)
    drive_t = 0.0,      -- per-frame driver throttle
    ctrlkey_t = 0.0,    -- last nav hotkey press (its plain-arrow echo must not cancel)
    route = nil,        -- active A* routing job, sliced across pump ticks
    STEP = 130,         -- routing grid cell size (world units)
}

-- Resolve a talkable NPC's display name from STATIC data (no contact needed): the
-- name handle IS the placement TextLabel, so shim.NpcName reads actor+0xA10 and
-- runs it through GetGameTextString. Cheap (same as a speaker-name resolve), but
-- still cached per actor in npc_learned and called per-focus (not a list sweep) so
-- a stall can never accumulate. pcall-wrapped; a field on NV (main chunk is at the
-- 200-local cap). namedone marks "tried, none" so we don't re-probe blanks.
NV.resolve_name = function(o)
    if not (o and shim and shim.NpcName) then return nil end
    local addr = nil
    pcall(function() addr = o:GetAddress() end)
    if not addr then return nil end
    local rec = npc_learned[addr]
    if type(rec) == "table" and rec.name then return rec.name end
    if type(rec) == "table" and rec.namedone then return nil end
    local nm = nil
    pcall(function() nm = shim.NpcName(addr) end)
    local r = (type(rec) == "table") and rec or {}
    r.name = nm or r.name
    r.namedone = true
    npc_learned[addr] = r
    return r.name
end

-- A target is an actor (read live: NPCs wander) or, for minimap markers without a
-- matching actor, a fixed position. Returns x, y, z (z may be nil).
NV.tpos = function(t)
    if t.actor then
        local x, y, z = read_actor_pos(t.actor)
        if x then return x, y, z end
    end
    if t.pos then return t.pos.x, t.pos.y, t.pos.z end
    return nil
end

local function nav_target()
    local t = NV.list[NV.idx]
    if not t then return nil end
    local okv = false
    pcall(function() okv = t.actor and t.actor:IsValid() end)
    if not okv then
        if not t.pos then return nil end
        t.actor = nil          -- marker whose actor streamed out: keep its position
    end
    return t
end

local function nav_build_list()
    NV.list = {}
    local c = NAV_CLASSES[NV.cat]
    if not c then return end
    local p = get_player_obj()
    local px, py, pz = 0, 0, 0
    if p then local x, y, z = read_actor_pos(p); px, py, pz = x or 0, y or 0, z or 0 end
    if c.markers then
        local ok, ms = pcall(M.minimap_markers, pz)
        if ok and ms then
            for _, m in ipairs(ms) do
                if #NV.list < 60 then
                    NV.list[#NV.list + 1] = { actor = m.actor, pos = { x = m.x, y = m.y, z = m.z },
                        cat = c.name, name = m.label, walkcat = m.walkcat, known = true,
                        d = math.sqrt((m.x - px) ^ 2 + (m.y - py) ^ 2) }
                end
            end
        end
        NV.list_done(px, py)
        return
    end
    local list = nil
    pcall(function() list = FindAllOf(c.cls) end)
    if not list then return end
    -- NPC category: list ONLY talkable NPCs (property-detected or learned). Other
    -- categories list everything. A throttled per-NPC log surfaces the property
    -- values so we can verify the discriminator.
    local dolog = (c.name == "npc") and (os.clock() - (NV.npc_logt or 0) > 5)
    if dolog then NV.npc_logt = os.clock() end
    for _, o in pairs(list) do
        local okv = false
        pcall(function() okv = o and o:IsValid() end)
        if okv and #NV.list < 60 then
            local ox, oy = read_actor_pos(o)
            if ox then
                local keep, nm = true, nil
                if c.name == "npc" then
                    local ok2, k, why, n = pcall(npc_interesting, o)
                    if ok2 then keep, nm = k, n else keep = false end
                    if dolog and ok2 then log("NPC " .. (keep and "keep " or "omit ") .. tostring(why)) end
                end
                if keep then
                    NV.list[#NV.list + 1] = { actor = o, cat = c.name, known = true, name = nm,
                        d = math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2) }
                end
            end
        end
    end
    NV.list_done(px, py)
end
-- Nearest first, but targets known to be unreachable from here (a failed walk or the
-- background check) last; then queue the list for the background check.
NV.list_done = function(px, py)
    for _, t in ipairs(NV.list) do
        local key = NV.tkey(t)
        t.unreach = (key and NV.is_noroute(key, px, py) and not NV.noroute[key].door) and true or false
    end
    table.sort(NV.list, function(a, b)
        if a.unreach ~= b.unreach then return b.unreach end
        return a.d < b.d
    end)
    pcall(NV.bg_queue)
end

-- ===== Reachability: targets inside buildings, and targets the router failed on =====
-- OT1 houses are built IN PLACE: the door trigger (HouseEnterTriggerBP_C, the "building"
-- category) swaps the facade (Actor_Def) for the room (Actor_Room) when you walk in. A
-- target inside a house the player is not in can't be routed to -- the closed door
-- blocks every trace: Russell and Mercedes in the Atlasdam library gave "No route
-- found" every time (user, 2026-11-13). Such a walk goes to the house's door first;
-- after E opens it, Backspace again walks inside.
-- Which house: the padded box around the door's Actor_Room actors ("room"). BorderBox
-- is NOT the house -- it is a thin plane in the doorway (+-3 deep, seen 2026-11-13)
-- whose offset from the door actor points INTO the house; with allow_plane (only after
-- the router failed) a target behind that plane, within 1500, also counts ("plane").
-- The padded box also reaches past the door: the Wachmann standing in front of the
-- library counted as inside (2026-11-14). So a target (and, for "leave the house
-- first", the player) must also be on the inner side of the doorway plane, when that
-- plane is clear (box offset >= 3 from the door actor).
-- Returns door, how -- or nil. Room boxes are cached per door until the area changes.
M.house_cache, M.plane_cache, M.house_cache_area = {}, {}, nil
-- The doorway plane of a door (its BorderBox): center and the unit normal pointing INTO
-- the house. The box's thin axis is the normal, turned with the component; the box
-- sits a few units inside the door actor, which gives the side. nil if unreadable.
M.house_plane = function(door, daddr, dx, dy)
    local pl = M.plane_cache[daddr]
    if pl ~= nil then return pl or nil end
    pl = false
    pcall(function()
        local bb = door.BorderBox
        local c = bb:K2_GetComponentLocation()
        local e = bb:GetScaledBoxExtent()
        local v
        pcall(function() v = (e.X < e.Y) and bb:GetForwardVector() or bb:GetRightVector() end)
        local nx, ny = 1, 0
        if v and type(v.X) == "number" then nx, ny = v.X, v.Y
        elseif e.X >= e.Y then nx, ny = 0, 1 end
        local nl = math.sqrt(nx * nx + ny * ny)
        if nl < 0.1 then return end
        nx, ny = nx / nl, ny / nl
        local off = (c.X - dx) * nx + (c.Y - dy) * ny
        if off < 0 then nx, ny, off = -nx, -ny, -off end
        pl = { cx = c.X, cy = c.Y, cz = c.Z, nx = nx, ny = ny, off = off }
    end)
    M.plane_cache[daddr] = pl
    return pl or nil
end
M.house_door_for = function(tx, ty, tz, px, py, pz, dolog, allow_plane)
    if M.house_cache_area ~= M.area_said then
        M.house_cache, M.plane_cache, M.house_cache_area = {}, {}, M.area_said
    end
    local list
    pcall(function() list = FindAllOf("HouseEnterTriggerBP_C") end)
    if not list then return nil end
    local best, bestd, besthow = nil, 1e9, nil
    local pbest, pbestd = nil, 1e9
    for _, door in pairs(list) do
        local okv = false
        pcall(function() okv = door:IsValid() end)
        local daddr = 0
        if okv then pcall(function() daddr = door:GetAddress() end) end
        if daddr ~= 0 then
            local dx, dy, dz = read_actor_pos(door)
            -- the room box: Actor_Room actor positions, padded (cached)
            local box = M.house_cache[daddr]
            if box == nil and dx then
                box = false
                local n = 0
                local b = { minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9, minz = 1e9, maxz = -1e9 }
                pcall(function()
                    door.Actor_Room:ForEach(function(_, v)
                        local a = v:get()
                        if a then
                            local ax, ay, az = read_actor_pos(a)
                            -- only room parts near the door: some rooms also list actors
                            -- 16000 away (academy "IvonRoom"), which made a box that
                            -- swallowed the whole hall
                            if ax and math.sqrt((ax - dx) ^ 2 + (ay - dy) ^ 2) < 2000 then
                                n = n + 1
                                b.minx, b.maxx = math.min(b.minx, ax), math.max(b.maxx, ax)
                                b.miny, b.maxy = math.min(b.miny, ay), math.max(b.maxy, ay)
                                b.minz, b.maxz = math.min(b.minz, az), math.max(b.maxz, az)
                            end
                        end
                    end)
                end)
                -- a box that is flat in X or Y is a wall/facade plane (the academy rooms'
                -- parts all sit on one line), not the room: don't use it
                if n > 0 and b.maxx - b.minx >= 200 and b.maxy - b.miny >= 200 then b.n = n; box = b end
                M.house_cache[daddr] = box
            end
            local function inroom(x, y, z)
                return box and x >= box.minx - 250 and x <= box.maxx + 250 and y >= box.miny - 250
                    and y <= box.maxy + 250 and (z or box.minz) >= box.minz - 300 and (z or box.minz) <= box.maxz + 300
            end
            local pl = dx and M.house_plane(door, daddr, dx, dy)
            -- distance in front of (> 0: inside) the doorway plane
            local function along(x, y) return (x - pl.cx) * pl.nx + (y - pl.cy) * pl.ny end
            local function inner(x, y)     -- not clearly outside the door
                return not (pl and pl.off >= 3) or along(x, y) > -40
            end
            local ipb = inroom(px, py, pz)        -- in the padded box: inside or at the door
            local it, how = inroom(tx, ty, tz) and inner(tx, ty), "room"
            local ip = ipb and inner(px, py)      -- really inside
            -- fallback: the doorway plane alone, only after a failed route
            if not it and allow_plane and pl then
                local side = math.abs((tx - pl.cx) * pl.ny - (ty - pl.cy) * pl.nx)
                if along(tx, ty) > 60 and along(tx, ty) < 2500 and side < 1500
                    and math.abs((tz or pl.cz) - pl.cz) < 800 and along(px, py) < 0 then
                    it, how = true, "plane"
                end
            end
            if dolog and dx and math.sqrt((dx - tx) ^ 2 + (dy - ty) ^ 2) < 3000 then
                local nm = "?"
                pcall(function() nm = door:GetFName():ToString() end)
                log(string.format("HOUSE %s door=(%.0f,%.0f,%.0f) room=%s plane=%s target_in=%s(%s) player_in=%s/%s",
                    nm, dx, dy, dz or 0,
                    box and string.format("%d actors x%.0f..%.0f y%.0f..%.0f z%.0f..%.0f", box.n, box.minx, box.maxx,
                        box.miny, box.maxy, box.minz, box.maxz) or "none",
                    pl and string.format("n(%.2f,%.2f) off=%.0f t%.0f p%.0f", pl.nx, pl.ny, pl.off, along(tx, ty),
                        along(px, py)) or "none",
                    tostring(it), how, tostring(ipb), tostring(ip)))
            end
            -- a house's door is near its room: ignore doors far from the target (a door
            -- 17000 away whose room actors spread over half the map matched Russell)
            local dt = dx and math.sqrt((dx - tx) ^ 2 + (dy - ty) ^ 2) or 1e9
            local dp = dx and math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2) or 1e9
            if it and ipb and dt < 2500 then
                -- the player is in the target's house ("same"), or just outside its door
                -- ("atdoor", with the door: it may still be shut -- the walk goes to it
                -- first when it's more than 250 away)
                if ip then return nil, "same" end
                return door, "atdoor"
            end
            if it and not ipb and dt < 2500 and dt < bestd then
                best, bestd, besthow = door, dt, how                -- the door nearest the TARGET
            end
            if ip and not it and dp < 2500 and dp < pbestd then
                pbest, pbestd = door, dp                            -- the house the PLAYER is in
            end
        end
    end
    -- third result: the door of the house the player is in (and the target is not):
    -- house doors close behind you, so leaving needs E at that door first (library)
    return best, besthow, pbest
end

-- A target's identity for the "router failed" memory: actor address, else position.
NV.tkey = function(t)
    local a = 0
    if t.actor then pcall(function() a = t.actor:GetAddress() end) end
    if a ~= 0 then return a end
    if t.pos then return string.format("%d:%d", math.floor(t.pos.x / 50), math.floor(t.pos.y / 50)) end
    return nil
end
-- Failed routes, remembered per target with where you stood and the area: the list then
-- says "not reachable", and walking there again from about the same spot doesn't make
-- you wait for the same 3-second failure. Moving 600+ away (or another area) forgets it.
NV.noroute = {}
NV.is_noroute = function(key, px, py)
    local r = key and NV.noroute[key]
    if not r then return false end
    if r.area ~= M.area_said then return false end
    return math.sqrt((px - r.x) ^ 2 + (py - r.y) ^ 2) < 600
end

local function nav_announce(prefix)
    local t = nav_target()
    if not t then speak("No target"); return end
    pcall(NV.bg_front, t)   -- the background check looks at this one next
    local p = get_player_obj(); if not p then speak("No player"); return end
    local px, py, pz = read_actor_pos(p); if not px then speak("No position"); return end
    local ox, oy, oz = NV.tpos(t)
    if not ox then speak("Target lost"); return end
    local dx, dy, dz = ox - px, oy - py, (oz or pz) - pz
    local d = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    local lvl = ""
    if dz > LEVEL_THRESH then lvl = ", above" elseif dz < -LEVEL_THRESH then lvl = ", below" end
    -- reachability note: inside a building you're not in, or the router failed here,
    -- or the background check found the way only through a shut door
    local key = NV.tkey(t)
    local noted = false
    if t.cat ~= "building" then
        local okd, door, how = pcall(M.house_door_for, ox, oy, oz or pz, px, py, pz)
        if okd and (door or how == "atdoor") then lvl = lvl .. ", inside a building"; noted = true
        elseif NV.is_noroute(key, px, py) then
            lvl = lvl .. (NV.noroute[key].door and ", inside a building" or ", not reachable"); noted = true
        end
    elseif NV.is_noroute(key, px, py) then
        lvl = lvl .. ", not reachable"; noted = true
    end
    local rr = key and NV.reach[key]
    if not noted and rr and rr.ok and rr.viadoor and NV.bg_valid(key, px, py) then
        lvl = lvl .. ", behind a door"
    end
    -- Name the focused NPC: first from the learned cache (talked-to NPCs), then
    -- from STATIC data (NV.resolve_name -> placement label via GetGameTextString)
    -- so names show up WITHOUT having to talk first. Per-focus only, cached.
    if t.cat == "npc" and not t.name and t.actor then
        local a = nil
        pcall(function() a = t.actor:GetAddress() end)
        local r = a and npc_learned[a]
        if type(r) == "table" and r.name then t.name = r.name
        elseif NV.resolve_name then t.name = NV.resolve_name(t.actor) end
        -- no name: the save point's book is an NPC too (it was "npc 1 of 7: up left,
        -- 156" by the save point, 2026-11-14) -- its minimap marker names it
        if not t.name then
            local okk, kind = pcall(M.marker_kind_of, t.actor)
            if okk and kind then t.name = kind end
        end
    end
    -- an exit says where it leads (M.exit_dest: the game's level tables), per focus
    if t.cat == "exit" and t.name == nil and t.actor then
        local okd, dest = pcall(M.exit_dest, t.actor)
        t.name = (okd and dest) and ("to " .. dest) or false
    end
    local who = t.name and (t.name .. ", ") or ""
    speak(string.format("%s%s %d of %d: %s%s, %d%s",
        prefix or "", t.cat, NV.idx, #NV.list, who, nav_dir(dx, dy), d, lvl))
end

local function nav_cat_cycle(delta)
    NV.ctrlkey_t = os.clock()
    if world_susp then speak("Scene running"); return end
    for _ = 1, #NAV_CLASSES do
        NV.cat = ((NV.cat - 1 + delta) % #NAV_CLASSES) + 1
        nav_build_list()
        if #NV.list > 0 then
            NV.idx = 1
            nav_announce(string.format("%s, %d targets. ", NAV_CLASSES[NV.cat].name, #NV.list))
            return
        end
    end
    speak("No targets in any category")
end

local function nav_obj_cycle(delta)
    NV.ctrlkey_t = os.clock()
    if world_susp then speak("Scene running"); return end
    if #NV.list == 0 then nav_build_list() end
    if #NV.list == 0 then speak("No targets here, control left or right for categories"); return end
    NV.idx = ((NV.idx - 1 + delta) % #NV.list) + 1
    nav_announce()
end

local function nav_find_path(p, sx, sy, sz, ex, ey, ez)
    -- the engine query failed every time on this game (no navmesh shipped);
    -- after a couple of confirmations stop asking
    if (NV.nomesh or 0) >= 2 then return nil end
    local pts, why = nil, "call failed"
    pcall(function()
        local nav = StaticFindObject("/Script/Engine.Default__NavigationSystem")
        if not nav then why = "no NavigationSystem CDO"; return end
        local po = nav:FindPathToLocationSynchronously(p,
            { X = sx, Y = sy, Z = sz }, { X = ex, Y = ey, Z = ez }, nil, nil)
        if not po then why = "nil path object"; return end
        local pp = po.PathPoints
        local n = #pp
        why = "PathPoints=" .. tostring(n)
        if n >= 2 then
            pts = {}
            for i = 1, n do
                local v = pp[i]
                pts[#pts + 1] = { x = v.X, y = v.Y, z = v.Z }
            end
        end
    end)
    if not pts then NV.nomesh = (NV.nomesh or 0) + 1 end
    log("NAVMESH query: " .. why)
    return pts
end

local function nav_describe_path(pts)
    -- collapse waypoint deltas into runs named by their dominant arrow direction
    local segs = {}
    for i = 2, #pts do
        local dx, dy = pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y
        local dirname
        if math.abs(dx) >= math.abs(dy) then dirname = (dx >= 0) and "up" or "down"
        else dirname = (dy >= 0) and "right" or "left" end
        local len = math.sqrt(dx * dx + dy * dy)
        if #segs > 0 and segs[#segs].dir == dirname then
            segs[#segs].len = segs[#segs].len + len
        else
            segs[#segs + 1] = { dir = dirname, len = len }
        end
    end
    local parts, total = {}, 0
    for i, s in ipairs(segs) do
        total = total + s.len
        if i <= 8 then parts[#parts + 1] = string.format("%s %d", s.dir, math.floor(s.len / 10 + 0.5) * 10) end
    end
    if #segs > 8 then parts[#parts + 1] = "and more" end
    return table.concat(parts, ", "), math.floor(total + 0.5)
end

local function nav_walk_begin_path(pts, label)
    NV.path = pts
    NV.wp = 2
    nav_walking = true
    NV.prompt_at_start = M.popup_said   -- a door prompt already up (nav_walk_watch)
    NV.started = os.clock()
    NV.prog = { t = NV.started, x = pts[1].x, y = pts[1].y }
    NV.attempt_start = { x = pts[1].x, y = pts[1].y }
    NV.unwedged = false
    NV.unwedge = nil
    local total = 0
    for i = 2, #pts do
        total = total + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2)
    end
    log(string.format("NAVWALK start mode=%s wps=%d total=%d", label, #pts, math.floor(total)))
    speak(string.format("Walking, %s, total %d", label, math.floor(total + 0.5)))
end

-- ===== Trace-grid A*: own pathfinding, since the game ships no navmesh =====
-- Grid of NV.STEP cells around the player; an edge is walkable if a line trace
-- between the two cell centers (at knee height, like the wall radar) hits
-- nothing. The search is SLICED: ~70 traces per pump tick so the game never
-- hitches; typical indoor routes resolve in a second or two.
local function cellkey(ix, iy) return ix * 8192 + iy end

-- The grid is a HEIGHTFIELD: each cell's ground height comes from a down-trace,
-- and a step between neighbors is walkable when the ground changes GENTLY
-- (stairs and ramps are exactly that) and no wall blocks at knee height. Floors
-- are layers: the same x,y can exist upstairs AND downstairs as separate route
-- nodes, so routes can take staircases between levels.
local function zlayer(R, z) return math.floor((z - R.pz) / 200 + 0.5) end
local function key3(x, y, zl) return (x * 8192 + y) * 131 + zl end

-- ground height at cell (bx,by) approached from height za (down-trace from
-- za+160 to za-240; false = void / too big a drop). Cached per cell + band.
local function nav_ground(R, ksl, p, bx, by, za)
    local gk = cellkey(bx, by) .. "@" .. math.floor((za - R.pz) / 200 + 0.5)
    local c = R.gcache[gk]
    if c ~= nil then return c, 0 end
    local wx, wy = R.px + bx * NV.STEP, R.py + by * NV.STEP
    R.traces = R.traces + 1
    local ok, hit, oh = line_blocked(ksl, p, wx, wy, za + 160, wx, wy, za - 240)
    local z = false
    if ok and hit then
        local dist
        pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
        z = dist and (za + 160 - dist) or za
    end
    R.gcache[gk] = z
    return z, 1
end

local function nav_route_finish(goalnode)
    local R = NV.route
    NV.route = nil
    if not R then return end
    if not goalnode then
        log(string.format("ROUTE fail traces=%d pops=%d %.1fs", R.traces, R.pops, os.clock() - R.started))
        if R.mode == "walk" then
            -- NO blind straight-line fallback (it marched endlessly into walls):
            -- walk direct only if a body-width corridor is genuinely clear
            local clear = false
            local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            local p = get_player_obj()
            if ksl and p then
                local ddx, ddy = R.ox - R.px, R.oy - R.py
                local dl = math.sqrt(ddx * ddx + ddy * ddy)
                local pox, poy = 0, 0
                if dl > 1 then pox, poy = ddy / dl * 42, -ddx / dl * 42 end
                clear = true
                for _, off in ipairs({ 0, 1, -1 }) do
                    local ok, hit = line_blocked(ksl, p,
                        R.px + pox * off, R.py + poy * off, R.pz + 30,
                        R.ox + pox * off, R.oy + poy * off, R.pz + 30)
                    if not (ok and not hit) then clear = false; break end
                end
            end
            if clear then
                nav_walk_begin_path({ { x = R.px, y = R.py }, { x = R.ox, y = R.oy } }, "direct")
            else
                -- standing in an OPEN doorway with the target beyond it: the room
                -- behind may not be solid yet seen from outside (the game swaps it in
                -- as you enter) -- from the threshold of the academy office there was
                -- "no route" (2026-11-14). Step through, then route again from inside.
                local thr = NV.through_door and NV.through_door(R.px, R.py, R.pz, R.ox, R.oy)
                if thr and NV.goal then
                    log(string.format("NAVWALK step through door %s", tostring(thr.door.name)))
                    NV.goal = { x = thr.x2, y = thr.y2, z = R.pz, cat = "through", key = NV.goal.key }
                    speak("Through the door first")
                    nav_walk_begin_path({ { x = R.px, y = R.py }, { x = thr.x1, y = thr.y1 },
                        { x = thr.x2, y = thr.y2 } }, "through the door")
                    return
                end
                -- no route: maybe behind a house door (doorway-plane test, see
                -- M.house_door_for) -- then walk to that door instead; else remember
                -- the failure so the list says "not reachable" from here on
                local g = NV.goal
                if g and g.samehouse then
                    -- at (or in) the target's house: the shut door blocked the search
                    speak("The door is shut. Open it with E, then backspace again")
                    return
                end
                if (NV.retries or 0) > 0 then
                    -- a RE-route after getting stuck: the target was reachable a moment
                    -- ago, this spot is just wedged -- not a "not reachable" target
                    speak("Stuck, no way on from here. Step aside, then backspace again")
                    return
                end
                if g and g.key and g.cat ~= "door" then
                    local okd, door, dx, dy, dz = false, nil, nil, nil, nil
                    if g.cat ~= "exit" then   -- an exit is its own way out, never "in a house"
                        okd, door = pcall(M.house_door_for, g.x, g.y, g.z, R.px, R.py, R.pz, true, true)
                    end
                    if okd and door then dx, dy, dz = read_actor_pos(door) end
                    NV.noroute[g.key] = { x = R.px, y = R.py, area = M.area_said, door = dx and door or nil }
                    if dx and math.sqrt((dx - R.px) ^ 2 + (dy - R.py) ^ 2) > NV.ATDOOR and NV.route_begin then
                        NV.goal = { x = dx, y = dy, z = dz or R.pz, cat = "door", key = g.key }
                        speak("Probably inside a building. Routing to its door")
                        NV.route_begin("walk", dx, dy, dz or R.pz)
                        return
                    end
                end
                speak("Not reachable, no route found")
            end
        else
            speak("No route found")
        end
        return
    end
    -- goal -> start node chain (parent pointers), then waypoints, runs merged
    local chain = {}
    local n = goalnode
    while n and n.k ~= R.startk do
        chain[#chain + 1] = n
        n = R.came[n.k]
    end
    local raw = { { x = R.px, y = R.py } }
    for i = #chain, 1, -1 do
        raw[#raw + 1] = { x = R.px + chain[i].x * NV.STEP, y = R.py + chain[i].y * NV.STEP }
    end
    raw[#raw + 1] = { x = R.ox, y = R.oy }
    -- a SHUT DOOR on the way: walk to the first one only. There the door leg's usual
    -- ending applies (push to its center until "Öffnen, E", "then backspace again");
    -- the next Backspace routes on through the opened door, door by door.
    local door, cut = NV.route_first_door(R, goalnode)
    if door then
        log(string.format("ROUTE through door %s at (%.0f,%.0f)", tostring(door.name), door.x, door.y))
        if R.mode == "walk" then
            local tr = {}
            for j = 1, math.max(1, cut - 1) do tr[#tr + 1] = raw[j] end
            tr[#tr + 1] = { x = door.x, y = door.y }
            raw = tr
            NV.goal = { x = door.x, y = door.y, z = door.z, cat = "door", key = NV.goal and NV.goal.key }
        end
    end
    local pts = { raw[1] }
    for i = 2, #raw - 1 do
        local a, b, c = pts[#pts], raw[i], raw[i + 1]
        local d1x, d1y = b.x - a.x, b.y - a.y
        local d2x, d2y = c.x - b.x, c.y - b.y
        if d1x * d2y - d1y * d2x ~= 0 or (d1x * d2x + d1y * d2y) < 0 then
            pts[#pts + 1] = b      -- keep corners and reversals, drop straight runs
        end
    end
    pts[#pts + 1] = raw[#raw]
    local floorword = ""
    local ez = (door and R.mode == "walk") and (door.z or R.oz) or R.oz   -- the walk's end
    if ez - R.pz < -250 then floorword = ", downstairs"
    elseif ez - R.pz > 250 then floorword = ", upstairs" end
    log(string.format("ROUTE ok cells=%d wps=%d traces=%d %.1fs", #chain, #pts, R.traces, os.clock() - R.started))
    if R.mode == "walk" then
        if door then speak("A shut door on the way") end
        nav_walk_begin_path(pts, (door and "to the door" or "traced route") .. floorword)
    else
        local desc, total = nav_describe_path(pts)
        speak(string.format("Path: %s. Total %d%s%s.", desc, total, floorword, door and ", through a door" or ""))
    end
end

-- Doors the router may plan THROUGH: every house/room door (HouseEnterTriggerBP_C) with
-- a readable doorway plane. A shut door is a wall to the traces, so rooms behind rooms
-- (the academy's upper doors) were "not reachable" (2026-11-14). Cached per area.
M.door_list = function()
    if M.house_cache_area ~= M.area_said then
        M.house_cache, M.plane_cache, M.house_cache_area = {}, {}, M.area_said
    end
    if M.door_list_area == M.area_said and M.door_list_cache then return M.door_list_cache end
    local out = {}
    pcall(function()
        local list = FindAllOf("HouseEnterTriggerBP_C")
        if not list then return end
        for _, door in pairs(list) do
            local okv = false
            pcall(function() okv = door:IsValid() end)
            local daddr = 0
            if okv then pcall(function() daddr = door:GetAddress() end) end
            if daddr ~= 0 then
                local dx, dy, dz = read_actor_pos(door)
                local pl = dx and M.house_plane(door, daddr, dx, dy)
                if pl then
                    local nm = "?"
                    pcall(function() nm = door:GetFName():ToString() end)
                    out[#out + 1] = { actor = door, name = nm, x = dx, y = dy, z = dz or pl.cz,
                        cx = pl.cx, cy = pl.cy, cz = pl.cz, nx = pl.nx, ny = pl.ny }
                end
            end
        end
    end)
    M.door_list_cache, M.door_list_area = out, M.area_said
    return out
end

-- The open door the player stands in (within 160 of its center, no "Öffnen" prompt up)
-- with the target on its other side: { x1, y1 = doorway center, x2, y2 = 170 beyond
-- it toward the target, door }. nil otherwise. For the step-through after "no route".
NV.through_door = function(px, py, pz, ox, oy)
    if M.popup_said then return nil end          -- a prompt is up: that door is shut
    local okd, doors = pcall(M.door_list)
    if not okd or type(doors) ~= "table" then return nil end
    local best, bd, bat = nil, 1e9, 0
    for _, d in ipairs(doors) do
        local dist = math.sqrt((d.x - px) ^ 2 + (d.y - py) ^ 2)
        if dist < 160 and math.abs((d.z or pz) - pz) < 300 and dist < bd then
            local ap = (px - d.cx) * d.nx + (py - d.cy) * d.ny
            local at = (ox - d.cx) * d.nx + (oy - d.cy) * d.ny
            if ap * at < 0 then best, bd, bat = d, dist, at end
        end
    end
    if not best then return nil end
    local s = (bat > 0) and 1 or -1
    return { x1 = best.cx, y1 = best.cy, x2 = best.cx + best.nx * s * 170, y2 = best.cy + best.ny * s * 170,
             door = best }
end

-- A routing job (the walk router's NV.route, or a background check's NV.bg.R): the
-- search box is the start/goal rectangle plus `pad` cells (9); it fails after maxtr
-- traces or maxt seconds. doors / via: see the door edges in NV.route_slice.
NV.route_job = function(mode, ox, oy, oz, px, py, pz, pad)
    pad = pad or 9
    local gx = math.floor((ox - px) / NV.STEP + 0.5)
    local gy = math.floor((oy - py) / NV.STEP + 0.5)
    local startk = key3(0, 0, 0)
    local okd, doors = pcall(M.door_list)
    return {
        mode = mode, ox = ox, oy = oy, oz = oz, pad = pad,
        px = px, py = py, pz = pz, gx = gx, gy = gy, startk = startk,
        open = { { x = 0, y = 0, z = pz, k = startk, g = 0, f = math.abs(gx) + math.abs(gy) } },
        came = {}, gbest = { [startk] = 0 }, closed = {}, via = {},
        doors = (okd and type(doors) == "table") and doors or {},
        ecache = {}, gcache = {}, traces = 0, pops = 0, started = os.clock(),
        maxtr = 5200, maxt = 8,
        minx = math.min(0, gx) - pad, maxx = math.max(0, gx) + pad,
        miny = math.min(0, gy) - pad, maxy = math.max(0, gy) + pad,
    }
end
-- The first shut door a found route goes through (in walking order), and the index in
-- the raw waypoint list (start = 1) of the first cell behind it. nil: no door.
NV.route_first_door = function(R, goalnode)
    local chain = {}
    local n = goalnode
    while n and n.k ~= R.startk do chain[#chain + 1] = n; n = R.came[n.k] end
    for i = #chain, 1, -1 do
        local di = R.via and R.via[chain[i].k]
        if di and R.doors[di] then return R.doors[di], #chain - i + 2 end
    end
    return nil
end
-- Second try in a bigger box (+20 cells) after the first one ran out of cells: a way
-- round may leave the small box. From the academy door the guard up-left counted as
-- unreachable -- the stairs down lay outside the box -- yet from below he stood in a
-- straight line (2026-11-14). The traces done so far stay cached (same start cell).
NV.route_widen = function(R)
    if R.pad >= 20 then return nil end
    local W = NV.route_job(R.mode, R.ox, R.oy, R.oz, R.px, R.py, R.pz, 20)
    W.gcache, W.ecache = R.gcache, R.ecache
    W.traces, W.pops, W.started, W.saidlong = R.traces, R.pops, R.started, R.saidlong
    W.maxtr, W.maxt = R.traces + 6000, R.maxt + 8
    log(string.format("ROUTE widen: box +20 cells after %d traces", R.traces))
    return W
end
-- A body-wide straight corridor (3 knee-high lines, center and +-42) is clear.
NV.corridor_clear = function(ksl, p, px, py, pz, ox, oy)
    local ddx, ddy = ox - px, oy - py
    local dl = math.sqrt(ddx * ddx + ddy * ddy)
    local pox, poy = 0, 0
    if dl > 1 then pox, poy = ddy / dl * 42, -ddx / dl * 42 end
    for _, off in ipairs({ 0, 1, -1 }) do
        local ok, hit = line_blocked(ksl, p,
            px + pox * off, py + poy * off, pz + 30,
            ox + pox * off, oy + poy * off, pz + 30)
        if not (ok and not hit) then return false end
    end
    return true
end

-- One slice of the A* search on job R: at most `budget` traces and `itercap` loop
-- turns. Returns "found", node | "fail", why ("box" = no cells left in the box,
-- "cap" = out of traces / time) | nil (not done, call again next tick).
NV.route_slice = function(R, budget, itercap)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local p = get_player_obj()
    if not (ksl and p) then return "fail", "player" end
    -- HARD per-tick iteration cap. budget counts TRACES, but nav_ground / the edge
    -- wall-check return used=0 on a cache hit -- so over warm cache budget stops
    -- decrementing and the loop below would spin (O(open) min-scan each iteration)
    -- until the 8s route deadline, ALL IN ONE TICK = a multi-second game freeze.
    -- Cap iterations so a warm-cache tick yields to the next pump instead.
    local iters = 0
    while budget > 0 do
        iters = iters + 1
        if iters > itercap then return nil end   -- yield; routing resumes next tick
        local bi, best
        for i, n in ipairs(R.open) do
            if not best or n.f < best.f then bi, best = i, n end
        end
        if not best then return "fail", "box" end
        table.remove(R.open, bi)
        if not R.closed[best.k] then
            R.closed[best.k] = true
            R.pops = R.pops + 1
            -- Reached when WITHIN ONE CELL of the goal, not on the exact goal cell:
            -- solid targets (chests, NPCs) occupy their own cell and block the knee-height
            -- clearance trace into it, so the A* can never enter it (-> "No route found")
            -- even though you can stand adjacent and interact. The built path still appends
            -- the real goal position, so the walker finishes the last ~1 cell and arrives.
            if math.abs(best.x - R.gx) <= 1 and math.abs(best.y - R.gy) <= 1
                and math.abs(best.z - R.oz) <= 300 then
                return "found", best
            end
            for _, d in ipairs({ { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }) do
                local nx, ny = best.x + d[1], best.y + d[2]
                if nx >= R.minx and nx <= R.maxx and ny >= R.miny and ny <= R.maxy then
                    local zb, used = nav_ground(R, ksl, p, nx, ny, best.z)
                    budget = budget - used
                    if zb and math.abs(zb - best.z) <= 200 then
                        local nk = key3(nx, ny, zlayer(R, zb))
                        if not R.closed[nk] then
                            -- wall check at knee height between the two ground points
                            local ekey = best.k .. ">" .. nk
                            local w = R.ecache[ekey]
                            if w == nil then
                                -- CAPSULE-WIDTH clearance: 3 parallel knee-height
                                -- lines (center and +-42 units). A single ray can
                                -- thread banister gaps the character cannot fit
                                -- through -- that wedged the stair walks.
                                local pox, poy = d[2] * 42, -d[1] * 42
                                local ax0, ay0 = R.px + best.x * NV.STEP, R.py + best.y * NV.STEP
                                local bx0, by0 = R.px + nx * NV.STEP, R.py + ny * NV.STEP
                                w = true
                                for _, off in ipairs({ 0, 1, -1 }) do
                                    R.traces = R.traces + 1
                                    budget = budget - 1
                                    local ok2, hit2 = line_blocked(ksl, p,
                                        ax0 + pox * off, ay0 + poy * off, best.z + 55,
                                        bx0 + pox * off, by0 + poy * off, zb + 55)
                                    if not (ok2 and not hit2) then w = false; break end
                                end
                                -- blocked: maybe by a SHUT DOOR -- the step crosses a
                                -- doorway plane within its width. Then it is a door edge
                                -- (w = the door's index): passable, but dearer, and the
                                -- walk stops there for E (nav_route_finish).
                                if not w and R.doors then
                                    local mx, my = (ax0 + bx0) / 2, (ay0 + by0) / 2
                                    for di, dd in ipairs(R.doors) do
                                        local sa = (ax0 - dd.cx) * dd.nx + (ay0 - dd.cy) * dd.ny
                                        local sb = (bx0 - dd.cx) * dd.nx + (by0 - dd.cy) * dd.ny
                                        local tm = math.abs((mx - dd.cx) * dd.ny - (my - dd.cy) * dd.nx)
                                        if sa * sb <= 0 and tm < 100 and math.abs(best.z - dd.cz) < 300 then
                                            w = di
                                            break
                                        end
                                    end
                                end
                                R.ecache[ekey] = w
                            end
                            -- never through the TARGET's own door: a door is reached in
                            -- front of it ("through Room4" to Room4 made no sense). Per
                            -- job, so not in the (shared) cache.
                            if type(w) == "number" then
                                local dd = R.doors[w]
                                if not dd or math.sqrt((dd.x - R.ox) ^ 2 + (dd.y - R.oy) ^ 2) <= 100 then w = false end
                            end
                            if w then
                                local isdoor = type(w) == "number"
                                -- a door costs a stop and an E press: open ways up to
                                -- 25 cells longer win (at +6 the router took a door to a
                                -- target it also reached in the open)
                                local ng = best.g + (isdoor and 25 or 1)
                                if ng < (R.gbest[nk] or 1e9) then
                                    R.gbest[nk] = ng
                                    R.came[nk] = best
                                    R.via[nk] = isdoor and w or nil
                                    R.open[#R.open + 1] = { x = nx, y = ny, z = zb, k = nk, g = ng,
                                        f = ng + math.abs(R.gx - nx) + math.abs(R.gy - ny) }
                                end
                            end
                        end
                    end
                end
            end
        end
        if R.traces > R.maxtr or os.clock() - R.started > R.maxt then return "fail", "cap" end
    end
    return nil
end

local function nav_route_step()
    local R = NV.route
    if not R then return end
    local res, node = NV.route_slice(R, 110, 800)   -- 110 traces per tick keeps frames smooth
    if res == "found" then nav_route_finish(node); return end
    if res == "fail" then
        local W = (node == "box") and NV.route_widen(R)
        if W then NV.route = W; return end
        nav_route_finish(nil); return
    end
    if os.clock() - R.started > 2 and not R.saidlong then
        R.saidlong = true
        speak("Still routing")
    end
end

local function nav_route_begin(mode, ox, oy, oz)
    local p = get_player_obj(); if not p then speak("No player"); return end
    local px, py, pz = read_actor_pos(p); if not px then speak("No position"); return end
    oz = oz or pz
    local samelevel = math.abs(oz - pz) <= 200
    local gx = math.floor((ox - px) / NV.STEP + 0.5)
    local gy = math.floor((oy - py) / NV.STEP + 0.5)
    if gx == 0 and gy == 0 and samelevel then
        if mode == "walk" then
            nav_walk_begin_path({ { x = px, y = py }, { x = ox, y = oy } }, "close by")
        else
            speak("Right here")
        end
        return
    end
    -- direct-line shortcut (same level only): if a BODY-WIDTH corridor (3 lines,
    -- center +-42) to the target is clear, skip the search entirely
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if ksl and samelevel and NV.corridor_clear(ksl, p, px, py, pz, ox, oy) then
        if mode == "walk" then
            nav_walk_begin_path({ { x = px, y = py }, { x = ox, y = oy } }, "direct")
        else
            local d = math.floor(math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2) + 0.5)
            speak(string.format("Path: straight ahead, %d", d))
        end
        return
    end
    NV.route = NV.route_job(mode, ox, oy, oz, px, py, pz)
end
NV.route_begin = nav_route_begin   -- for nav_route_finish (defined above it)

-- ===== Quiet background reachability check =====
-- The list says "not reachable" BEFORE you try a target (user request 2026-11-13: offer
-- only targets you can reach, or at least say which you can't). While you explore and
-- no walk or route runs, the walk router's own A* checks the current list, nearest
-- first and the focused target before the rest, gently: 40 traces per pump tick instead
-- of 110. Same router, same search box, so a target it fails on fails for the walk too.
-- A failure goes into NV.noroute, so the list (", not reachable", or ", inside a
-- building" via the doorway plane) and the walk ("Not reachable from here") behave as
-- after a failed walk; the next list build puts such targets last. Targets inside a
-- house you're not in (or outside the house you're in) are skipped: the walk leads
-- through the door. A result holds in the same area within 600 of where you stood.
NV.reach, NV.bgq, NV.bg = {}, {}, nil
NV.bg_valid = function(key, px, py)
    local r = key and NV.reach[key]
    if not r or r.area ~= M.area_said then return nil end
    if math.sqrt((px - r.x) ^ 2 + (py - r.y) ^ 2) >= 600 then return nil end
    return r.ok
end
NV.bg_queue = function()     -- the current list, nearest first (nav_build_list)
    NV.bgq = {}
    local keep = false
    for _, t in ipairs(NV.list) do
        NV.bgq[#NV.bgq + 1] = t
        if NV.bg and NV.tkey(t) == NV.bg.key then keep = true end
    end
    if not keep then NV.bg = nil end   -- a check for another list's target: drop it
end
NV.bg_front = function(t)    -- the focused target goes first (nav_announce)
    if not t then return end
    for i, q in ipairs(NV.bgq) do
        if q == t then table.remove(NV.bgq, i); break end
    end
    table.insert(NV.bgq, 1, t)
end
NV.bg_record = function(job, ok, how, viadoor)
    NV.reach[job.key] = { ok = ok, x = job.px, y = job.py, area = job.area, viadoor = viadoor }
    if ok then
        NV.noroute[job.key] = nil
    else
        -- maybe behind a house door after all (doorway plane, as after a failed walk)
        local door = nil
        if job.cat ~= "exit" and job.cat ~= "building" then
            local okd, d = pcall(M.house_door_for, job.tx, job.ty, job.tz, job.px, job.py, job.pz, false, true)
            if okd and d then door = d end
        end
        NV.noroute[job.key] = { x = job.px, y = job.py, area = job.area, door = door }
    end
    log(string.format("REACH %s %s d=%.0f dz=%.0f: %s (%s, traces=%d, pops=%d, %.1fs)", tostring(job.cat),
        tostring(job.name or job.key), math.sqrt((job.tx - job.px) ^ 2 + (job.ty - job.py) ^ 2), job.tz - job.pz,
        ok and "ok" or "NOT reachable", how or "route", job.R and job.R.traces or 0, job.R and job.R.pops or 0,
        job.R and (os.clock() - job.R.started) or 0))
end
-- Set up the check of target t from the player's spot; nil = nothing to search
-- (gone, already known, behind a house door, or settled by a straight line).
NV.bg_new = function(t, p, px, py, pz)
    local okv = true
    if t.actor then okv = false; pcall(function() okv = t.actor:IsValid() end) end
    if not okv and not t.pos then return nil end
    local tx, ty, tz = NV.tpos(t)
    if not tx then return nil end
    tz = tz or pz
    local key = NV.tkey(t)
    if not key or NV.bg_valid(key, px, py) ~= nil or NV.is_noroute(key, px, py) then return nil end
    local job = { key = key, cat = t.cat, name = t.name, tx = tx, ty = ty, tz = tz,
                  px = px, py = py, pz = pz, area = M.area_said }
    if t.cat ~= "building" then
        -- behind a door: the walk leads there via the door. Standing just outside the
        -- target's door, its shut door failed the search: Russell "not reachable" at the
        -- library door (2026-11-14)
        local okd, door, how, pdoor = pcall(M.house_door_for, tx, ty, tz, px, py, pz)
        if okd and (door or pdoor or how == "atdoor") then return nil end
    else
        -- a house door as the target: from inside another house the shut door would
        -- fail every search
        local okd, _, _, pdoor = pcall(M.house_door_for, tx, ty, tz, px, py, pz)
        if okd and pdoor then return nil end
    end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not ksl then return nil end
    local gx = math.floor((tx - px) / NV.STEP + 0.5)
    local gy = math.floor((ty - py) / NV.STEP + 0.5)
    if math.abs(tz - pz) <= 200 and ((gx == 0 and gy == 0) or NV.corridor_clear(ksl, p, px, py, pz, tx, ty)) then
        NV.bg_record(job, true, "straight")
        return nil
    end
    job.R = NV.route_job("bg", tx, ty, tz, px, py, pz)
    job.R.maxt = 60          -- slower slices: same trace budget, more time
    -- checks from the same spot share their ground / wall caches (each one re-traced
    -- the same cells otherwise); the walk router never uses them -- a door opened in
    -- between would still look shut
    local c = NV.bg_cache
    if c and c.x == px and c.y == py and c.z == pz and os.clock() - c.t < 30 then
        job.R.gcache, job.R.ecache = c.g, c.e
    else
        NV.bg_cache = { x = px, y = py, z = pz, t = os.clock(), g = job.R.gcache, e = job.R.ecache }
    end
    return job
end
NV.bg_step = function()      -- nav_tick, only while no walk or route runs
    if nav_walking or NV.route or world_susp or M.explore_now == false or M.menu_now then return end
    local job = NV.bg
    if job and job.area ~= M.area_said then NV.bg, NV.bgq, job = nil, {}, nil end   -- area changed
    if not job then
        if #NV.bgq == 0 then return end
        local p = get_player_obj(); if not p then return end
        local px, py, pz = read_actor_pos(p); if not px then return end
        for _ = 1, 3 do      -- a few set-ups per tick (each costs a house test + 3 traces)
            local t = table.remove(NV.bgq, 1)
            if not t then return end
            job = NV.bg_new(t, p, px, py, pz)
            if job then break end
        end
        if not job then return end
        NV.bg = job
    end
    local res, why = NV.route_slice(job.R, 40, 100)
    if res == "fail" and why == "box" then
        local W = NV.route_widen(job.R)
        if W then job.R = W; return end
    end
    if res then
        NV.bg = nil
        local door = (res == "found") and NV.route_first_door(job.R, why) or nil
        NV.bg_record(job, res == "found", (job.R.pad > 9 and "wide route" or "route")
            .. (door and (", door " .. tostring(door.name)) or ""), door ~= nil)
    end
end

local function nav_info()
    NV.ctrlkey_t = os.clock()
    local t = nav_target()
    if not t then speak("No target selected. Home and end pick a category, page up and down a target."); return end
    local p = get_player_obj(); if not p then speak("No player"); return end
    local px, py, pz = read_actor_pos(p)
    local ox, oy, oz = NV.tpos(t)
    if not (px and ox) then speak("Target lost"); return end
    oz = oz or pz
    local dx, dy, dz = ox - px, oy - py, (oz or pz) - pz
    local d = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    local lvl = "same level"
    if dz > LEVEL_THRESH then lvl = "above" elseif dz < -LEVEL_THRESH then lvl = "below" end
    local base = string.format("%s %d of %d, %s, %d, %s. ", t.cat, NV.idx, #NV.list, nav_dir(dx, dy), d, lvl)
    local pts = nav_find_path(p, px, py, pz, ox, oy, oz)
    if pts then
        local desc, total = nav_describe_path(pts)
        speak(base .. string.format("Path: %s. Total %d.", desc, total))
    else
        speak(base .. "Routing.")
        nav_route_begin("info", ox, oy, oz)
    end
end

local function nav_walk_stop(msg)
    nav_walking = false
    NV.path = nil
    NV.held = nil
    pcall(function() if shim and shim.HoldKeys then shim.HoldKeys(false, false, false, false) end end)
    if msg then speak(msg) end
end

-- After "Arrived": one short step toward the target (0.18 s, nav_drive plays it), so
-- talking / the save point / a chest work with Enter right away. The walker stops
-- facing its last step, which may point past the target, and up to 170 away -- the
-- headmaster at 158 gave no talk hint; a 60 ms tap moved nothing. Not exits / doors.
NV.face_goal = function()
    local g = NV.goal
    if not g or g.cat == "exit" or g.cat == "door" or g.cat == "building" then return end
    local p = get_player_obj(); if not p then return end
    local px, py = read_actor_pos(p); if not px then return end
    local tx, ty = g.x, g.y
    local t = nav_target()
    if t and g.key and NV.tkey(t) == g.key then   -- a wandering NPC: where it is now
        local x, y = NV.tpos(t)
        if x then tx, ty = x, y end
    end
    local dx, dy = tx - px, ty - py
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 25 then return end
    -- 8 directions like the walk itself: a target up-left needs up AND left (one axis
    -- missed the headmaster at "up left, 143"; a tap up then gave "Path action")
    local nx, ny = dx / dl, dy / dl
    local u, d, r, l = nx > 0.38, nx < -0.38, ny > 0.38, ny < -0.38
    log(string.format("NAVWALK face target d=%.0f keys=%s%s%s%s", dl, u and "U" or "", d and "D" or "",
        l and "L" or "", r and "R" or ""))
    M.face_t = os.clock()   -- bump_step: this tap is ours, no wall thud
    NV.face = { till = os.clock() + 0.18, u = u, d = d, l = l, r = r,
        held = { UP_ARROW = u or nil, DOWN_ARROW = d or nil, LEFT_ARROW = l or nil, RIGHT_ARROW = r or nil } }
end

-- Standing "at a door": the walk's door leg is skipped within this distance of the door
-- actor. The "Öffnen, E" prompt shows only ~35 in front of the door's center; with 250,
-- someone 240 away (at the Wachmann, outside the library) was told to press E there.
NV.ATDOOR = 120
local function nav_walk_start(quiet)
    NV.ctrlkey_t = os.clock()
    -- plain Backspace is also the GAME's cancel key ("Rück Zurück"): pressed in a menu,
    -- a dialog or a scene it must do nothing here -- no walk, no "Scene running"
    if quiet and (world_susp or M.explore_now == false) then return end
    if nav_walking then nav_walk_stop("Walk stopped"); return end
    if NV.route then NV.route = nil; speak("Routing cancelled"); return end
    if world_susp then speak("Scene running, try again after"); return end
    local t = nav_target()
    if not t then speak("No target selected"); return end
    local p = get_player_obj(); if not p then speak("No player"); return end
    local px, py, pz = read_actor_pos(p)
    local ox, oy, oz = NV.tpos(t)
    if not (px and ox) then speak("Target lost"); return end
    oz = oz or pz
    local key = NV.tkey(t)
    NV.goal = { x = ox, y = oy, z = oz, cat = t.walkcat or t.cat, key = key }
    NV.push = nil
    NV.retries = 0
    NV.bestgoal = nil
    NV.noimprove = 0
    -- INSIDE A BUILDING you're not in: walk to its door first (the closed door blocks
    -- every route). At the door the game says "Öffnen, E"; after E, Backspace again
    -- walks inside (then you stand at the door, so this leg is skipped).
    local samehouse = false
    if t.cat ~= "building" then
        local okd, door, how, pdoor = pcall(M.house_door_for, ox, oy, oz, px, py, pz, true)
        -- you are in (or at the door of) the target's house: route straight in. If the
        -- door is still shut that fails -- then say "open the door", not "not reachable"
        samehouse = okd and (how == "same" or how == "atdoor")
        NV.goal.samehouse = samehouse
        -- LEAVING a house first: its door closes behind you and opens only with E, from
        -- inside too (the walk out of the library wedged at the shut door, 2026-11-13)
        if okd and pdoor and not samehouse then
            local dx, dy, dz = read_actor_pos(pdoor)
            if dx and math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2) > NV.ATDOOR then
                NV.goal = { x = dx, y = dy, z = dz or pz, cat = "door", key = key }
                speak(string.format("Leaving the building first. Routing to its door, %d",
                    math.floor(math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2) + 0.5)))
                nav_route_begin("walk", dx, dy, dz or pz)
                return
            end
            NV.goal.samehouse = true   -- at the door: a failed route means "open it first"
            samehouse = true
        end
        -- or a door found earlier after the router failed (doorway-plane test)
        if not samehouse and not (okd and door) and NV.is_noroute(key, px, py) and NV.noroute[key].door then
            local okv = false
            pcall(function() okv = NV.noroute[key].door:IsValid() end)
            if okv then okd, door = true, NV.noroute[key].door end
        end
        if okd and door then
            local dx, dy, dz = read_actor_pos(door)
            if dx and math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2) > NV.ATDOOR then
                NV.goal = { x = dx, y = dy, z = dz or pz, cat = "door", key = key }
                local who = t.name and t.name:match("^[^,]+") or t.cat
                speak(string.format("%s is inside a building. Routing to its door, %d", who,
                    math.floor(math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2) + 0.5)))
                nav_route_begin("walk", dx, dy, dz or pz)
                return
            end
        end
    end
    -- the router already failed for this target from about here: say so right away
    -- (a second press within 4 s tries anyway)
    if not samehouse and NV.is_noroute(key, px, py)
        and not (NV.retry_key == key and os.clock() - (NV.retry_t or -10) < 4) then
        NV.retry_key, NV.retry_t = key, os.clock()
        speak("Not reachable from here. Press again to try anyway")
        return
    end
    -- navmesh first (free + instant if the game has it), else our traced A*
    local pts = nav_find_path(p, px, py, pz, ox, oy, oz)
    if pts then
        nav_walk_begin_path(pts, "navmesh path")
        return
    end
    local d = math.floor(math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2) + 0.5)
    speak(string.format("Routing to %s, %d", t.cat, d))
    nav_route_begin("walk", ox, oy, oz)
end

nav_drive = function()   -- per FRAME from the tick hooks: steer by holding arrow keys
    -- a menu / dialog / speech bubble came up (M.menu_now, from the pump): held arrow
    -- keys would now move a menu cursor -- stop like for a scene
    if world_susp or M.menu_now then
        -- scene/transition: end any walk or routing NOW and release the keys.
        -- (The driver runs outside the pump's gate, so it must check itself --
        -- it once kept keys held through a whole cutscene and the character
        -- marched through a door into the next crash.)
        if nav_walking or NV.route then
            local waswalking = nav_walking
            nav_walking = false
            NV.path = nil
            NV.route = nil
            NV.unwedge = nil
            NV.held = nil
            pcall(function() shim.HoldKeys(false, false, false, false) end)
            -- walking INTO an exit ends in its transition fade: that is the arrival,
            -- and the new area announces itself -- say nothing then
            local into_exit = NV.goal and NV.goal.cat == "exit" and (NV.push or (NV.lastgd or 1e9) < 450)
            if waswalking and not into_exit then speak("Walk stopped") end
            if into_exit then log("NAVWALK through exit") end
        end
        return
    end
    if NV.face then
        -- after "Arrived": a short tap toward the target so the character faces it --
        -- the save point said "Save point" only after a manual tap left (2026-11-14)
        if os.clock() < NV.face.till then
            NV.held_t = NV.held_t or {}
            for k in pairs(NV.face.held) do NV.held_t[k] = os.clock() end
            pcall(function() shim.HoldKeys(NV.face.u, NV.face.d, NV.face.l, NV.face.r) end)
        else
            NV.face = nil
            pcall(function() shim.HoldKeys(false, false, false, false) end)
        end
        return
    end
    if not nav_walking then return end
    local now = os.clock()
    if now - NV.drive_t < 0.012 then return end
    NV.drive_t = now
    -- unwedge sidestep phase: hold the perpendicular key briefly, then re-route
    if NV.unwedge then
        if now < NV.unwedge.till then
            NV.held = NV.unwedge.held
            NV.held_t = NV.held_t or {}
            for k in pairs(NV.held or {}) do NV.held_t[k] = now end
            pcall(function() shim.HoldKeys(NV.unwedge.u, NV.unwedge.d, NV.unwedge.l, NV.unwedge.r) end)
            return
        end
        NV.unwedge = nil
        nav_walking = false
        NV.path = nil
        NV.held = nil
        pcall(function() shim.HoldKeys(false, false, false, false) end)
        if NV.goal and (NV.retries or 0) < 4 then
            NV.retries = (NV.retries or 0) + 1
            speak("Rerouting")
            nav_route_begin("walk", NV.goal.x, NV.goal.y, NV.goal.z)
        else
            speak("Walk interrupted, backspace to resume")
        end
        return
    end
    if not NV.path then return end
    local p = get_player_obj()
    local px, py
    if p then px, py = read_actor_pos(p) end
    if not px then
        -- world unstable (transition in progress): stop NOW, never idle with keys held
        nav_walking = false
        NV.path = nil
        NV.held = nil
        pcall(function() shim.HoldKeys(false, false, false, false) end)
        return
    end
    local wp = NV.path[NV.wp]
    while wp do
        local dx, dy = wp.x - px, wp.y - py
        local reach = (NV.wp == #NV.path) and 110 or 40   -- small turn radius: no corner cutting
        if math.sqrt(dx * dx + dy * dy) >= reach then break end
        NV.wp = NV.wp + 1
        wp = NV.path[NV.wp]
    end
    local dx, dy
    if not wp then
        local gcat = NV.goal and NV.goal.cat
        if gcat == "through" then          -- stepped through a doorway: route on
            nav_walk_stop()
            NV.resume_walk = true
            return
        end
        if gcat ~= "exit" and gcat ~= "door" then
            nav_walk_stop("Arrived")
            pcall(NV.face_goal)
            return
        end
        -- EXIT: its trigger volume can sit past the last waypoint (the palace hall
        -- door: "Arrived" 150 short of it, nothing happened). Keep walking on along
        -- the approach direction for up to 2 s; the transition fade then ends the
        -- walk silently (see the scene check above). No transition -> stop.
        -- DOOR (first leg to a target inside a building): head for the door's center
        -- until its "Öffnen, E" prompt shows -- stopping 60 units off to the side left
        -- you without the prompt (library door, 2026-11-13).
        if not NV.push then
            local ax, ay
            if gcat == "door" then
                ax, ay = NV.goal.x - px, NV.goal.y - py
            else
                local n = #NV.path
                ax = NV.path[n].x - (NV.path[n - 1] or NV.path[n]).x
                ay = NV.path[n].y - (NV.path[n - 1] or NV.path[n]).y
                if math.sqrt(ax * ax + ay * ay) < 1 then ax, ay = NV.goal.x - px, NV.goal.y - py end
            end
            NV.push = { till = now + 2.0, x = ax, y = ay }
            log("NAVWALK push to " .. gcat)
        end
        if gcat == "door" then
            NV.push.x, NV.push.y = NV.goal.x - px, NV.goal.y - py   -- keep aiming at the door
        end
        if M.popup_said then
            -- the game shows the door's prompt ("Öffnen, E", spoken by
            -- poll_action_popup) and waits for the key -- stop at the door
            NV.push = nil
            nav_walk_stop()   -- silent: the prompt speech says what to do
            -- a prompt that was up before the walk wasn't spoken now: say it again
            if NV.prompt_at_start then speak("Still shut. " .. (M.popup_text or "press E") .. ", then backspace again")
            elseif gcat == "door" then speak("then backspace again", false) end
            return
        end
        if now > NV.push.till then
            NV.push = nil
            nav_walk_stop(gcat == "door" and "At the door. Open it, then backspace again"
                or "At the exit, no way through")
            return
        end
        dx, dy = NV.push.x, NV.push.y
    else
        dx, dy = wp.x - px, wp.y - py
    end
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return end
    dx, dy = dx / d, dy / d
    -- NATIVE input: hold the real arrow keys (8-way) via the shim -- the game
    -- walks the character itself: true speed, footsteps, animations, encounters.
    local u  = dx > 0.38
    local dn = dx < -0.38
    local r  = dy > 0.38
    local l  = dy < -0.38
    NV.held = { UP_ARROW = u or nil, DOWN_ARROW = dn or nil, LEFT_ARROW = l or nil, RIGHT_ARROW = r or nil }
    -- remember WHEN each key was last ours: the keybind echo of a synthetic press can
    -- arrive after we already let go again (a waypoint turn, or a diagonal flickering
    -- around the 0.38 threshold) -- nav_walk_watch must not take that for the player
    NV.held_t = NV.held_t or {}
    for k in pairs(NV.held) do NV.held_t[k] = now end
    pcall(function() shim.HoldKeys(u, dn, l, r) end)
end

local function nav_walk_watch()   -- cancel/stuck/door supervision while walking
    if not nav_walking then return end
    local now = os.clock()
    -- manual override: an arrow press for a key WE are not synthetically holding
    -- means the player intervened (our own HoldKeys transitions echo into the
    -- keybinds too, so held keys must not cancel). The echo can lag behind our
    -- release, so a key we held within the last 0.75 s also counts as ours --
    -- otherwise routed walks cancelled themselves about a second in.
    if bump_arrow_t > NV.started + 0.5 and math.abs(bump_arrow_t - NV.ctrlkey_t) > 0.25 then
        local held = NV.held or {}
        local last = bump_arrow_key and NV.held_t and NV.held_t[bump_arrow_key]
        local ours = bump_arrow_key and (held[bump_arrow_key] or (last and bump_arrow_t - last < 0.75))
        if not ours then
            log(string.format("NAVWALK cancel: key=%s held=%s last_ours=%s", tostring(bump_arrow_key),
                tostring(held[bump_arrow_key or ""]), last and string.format("%.2fs ago", bump_arrow_t - last) or "never"))
            nav_walk_stop("Walk cancelled")
            return
        end
    end
    local p = get_player_obj(); if not p then return end
    local px, py, pz = read_actor_pos(p); if not px then return end
    -- arrival forgiveness: within interaction range of the GOAL counts as
    -- arrived, even when the exact spot is blocked (counters, furniture) --
    -- chasing the unreachable final meters caused endless circling
    if NV.goal then
        local gd = math.sqrt((px - NV.goal.x) ^ 2 + (py - NV.goal.y) ^ 2)
        NV.lastgd = gd
        if NV.goal.cat == "exit" then
            -- exits are walked THROUGH (nav_drive pushes on past the last waypoint).
            -- A seamless exit (same map, no fade) shows the new area banner instead:
            -- that is the arrival -- stop quietly, the banner speaks for itself.
            if (M.area_t or 0) > NV.started + 0.3 then
                log("NAVWALK through exit (new area)")
                nav_walk_stop()
                return
            end
            -- a DOOR exit: near it the game shows its prompt ("Öffnen, E", already
            -- spoken) and only the key opens it -- pushing on just wedges into the
            -- door and re-routes (seen 2026-11-11 at the academy door). Stop there.
            if M.popup_said and gd < 450 then
                log("NAVWALK at door exit (prompt)")
                nav_walk_stop()   -- silent: "Arrived" would cut off the prompt speech
                -- ...unless the prompt was up already when the walk began: the door is
                -- still shut (an E press that didn't take) -- the walk ended without a
                -- word after "Walking, total 161" (2026-11-14). Say the prompt again.
                if NV.prompt_at_start then speak("Still shut. " .. (M.popup_text or "press E")) end
                return
            end
        elseif NV.goal.cat == "through" then
            -- the step through an open doorway: once beyond it, route on to the
            -- real target from inside (nav_tick restarts the walk)
            if gd < 70 then
                log("NAVWALK through the door, routing on")
                nav_walk_stop()
                NV.resume_walk = true
                return
            end
        elseif NV.goal.cat == "door" then
            -- first leg to a target inside a building: stop where the door prompt
            -- shows (nav_drive pushes on to the door's center until it does); the
            -- prompt itself says "Öffnen, E" -- add how to go on
            if M.popup_said and gd < 450 then
                log("NAVWALK at building door")
                nav_walk_stop()
                if NV.prompt_at_start then
                    speak("Still shut. " .. (M.popup_text or "press E") .. ", then backspace again")
                else
                    speak("then backspace again", false)
                end
                return
            end
        elseif gd < 170 and math.abs(pz - (NV.goal.z or pz)) < LEVEL_THRESH then
            -- (not when the goal is a floor up or down: in the academy hall a walk to
            -- a door upstairs said "Arrived" passing beneath it)
            nav_walk_stop("Arrived"); pcall(NV.face_goal); return
        end
    end
    local jump = math.sqrt((px - NV.prog.x) ^ 2 + (py - NV.prog.y) ^ 2)
    if jump > 900 then nav_walk_stop("Walk ended, went through a door"); return end
    if jump > 40 then
        NV.prog = { t = now, x = px, y = py }
    elseif now - NV.prog.t > 2.0 and not NV.unwedge then
        -- stuck: wedged on geometry, a blocker, a battle, or a cutscene.
        -- If we hold keys but the pawn reports no movement input, the game has
        -- taken input away (cutscene/battle): stop quietly, never fight it.
        local inpMag = 0
        pcall(function() local iv = p:GetLastMovementInputVector(); inpMag = math.sqrt(iv.X * iv.X + iv.Y * iv.Y) end)
        if NV.held and inpMag < 0.3 then
            nav_walk_stop("Walk interrupted")
            return
        end
        if not NV.unwedged and NV.path then
            -- one automatic SIDESTEP perpendicular to travel (the manual recovery
            -- that worked on the stairs), then re-route from the freed spot
            NV.unwedged = true
            local wp = NV.path[NV.wp]
            local vx, vy = 0, 0
            if wp then
                vx, vy = wp.x - px, wp.y - py
                local vl = math.sqrt(vx * vx + vy * vy)
                if vl > 1 then vx, vy = vx / vl, vy / vl end
            end
            local cands = { { -vy, vx }, { vy, -vx } }
            local pick = nil
            local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
            if ksl then
                for _, c in ipairs(cands) do
                    local ok, hit = line_blocked(ksl, p, px, py, pz + 30,
                        px + c[1] * 170, py + c[2] * 170, pz + 30)
                    if ok and not hit then pick = c; break end
                end
            end
            pick = pick or cands[1]
            local u  = pick[1] > 0.38
            local dn = pick[1] < -0.38
            local r  = pick[2] > 0.38
            local l  = pick[2] < -0.38
            NV.unwedge = { till = now + 0.4, u = u, d = dn, l = l, r = r,
                held = { UP_ARROW = u or nil, DOWN_ARROW = dn or nil, LEFT_ARROW = l or nil, RIGHT_ARROW = r or nil } }
            NV.prog = { t = now, x = px, y = py }
            return
        end
        local prog = NV.attempt_start
            and math.sqrt((px - NV.attempt_start.x) ^ 2 + (py - NV.attempt_start.y) ^ 2) or 0
        local gd = NV.goal and math.sqrt((px - NV.goal.x) ^ 2 + (py - NV.goal.y) ^ 2) or -1
        log(string.format("WALKSTUCK at (%.0f,%.0f) goalDist=%.0f prog=%.0f best=%.0f",
            px, py, gd, prog, NV.bestgoal or -1))
        nav_walking = false
        NV.path = nil
        NV.held = nil
        pcall(function() if shim and shim.HoldKeys then shim.HoldKeys(false, false, false, false) end end)
        -- CONVERGENCE-based give-up (replaces the blind retry cap that let the
        -- walker orbit an unreachable NPC). Track the closest we've ever gotten
        -- to the GOAL; a reroute is only worth it if it's still meaningfully
        -- improving that. Otherwise stop -- gracefully "arrived" if we're within
        -- a body's reach, else honestly "can't reach, closest N".
        if gd >= 0 and (NV.bestgoal == nil or gd < NV.bestgoal - 40) then
            NV.bestgoal = gd
            NV.noimprove = 0
        else
            NV.noimprove = (NV.noimprove or 0) + 1
        end
        local gdz = (NV.goal and NV.goal.z) and math.abs(pz - NV.goal.z) or 0
        if gd >= 0 and gd < 220 and gdz < LEVEL_THRESH then
            speak("Arrived")                       -- close enough to interact
            pcall(NV.face_goal)
        elseif NV.goal and (NV.noimprove or 0) < 2 and (NV.retries or 0) < 5 then
            NV.retries = (NV.retries or 0) + 1
            speak("Rerouting")
            nav_route_begin("walk", NV.goal.x, NV.goal.y, NV.goal.z)
        else
            speak(string.format("Can't reach, closest %d", math.floor((NV.bestgoal or gd) + 0.5)))
        end
    end
end

nav_tick = function()   -- ~10 Hz from the pump: routing slices + walk supervision
    if NV.route then
        local ok, err = pcall(nav_route_step)
        if not ok then
            local msg = tostring(err)
            if msg ~= NV.lasterr then
                NV.lasterr = msg
                log("ROUTE ERR: " .. msg)
            end
        end
    end
    if nav_walking then pcall(nav_walk_watch) end
    if NV.resume_walk and not nav_walking and not NV.route then
        NV.resume_walk = nil
        pcall(nav_walk_start, true)   -- after a step through a doorway: on to the target
    end
    if not NV.route and not nav_walking then
        local ok, err = pcall(NV.bg_step)   -- quiet reachability check of the list
        if not ok and tostring(err) ~= NV.bgerr then
            NV.bgerr = tostring(err)
            log("REACH ERR: " .. NV.bgerr)
        end
    end
end

-- Laptop-friendly keys (no numpad in the target audience's baseline):
--   Home / End           = category prev / next
--   Page Up / Page Down  = target prev / next (shared binding: char-select keeps
--                          its traveler cycling; the field gets target cycling)
--   Ctrl+Backspace       = target info + path
--   Ctrl+Enter           = walk / stop
do
    local function bind(kn, mods, fn, label)
        local k = nil
        pcall(function() k = Key[kn] end)
        if not k then return false end
        local ok
        if mods then ok = pcall(RegisterKeyBind, k, mods, fn)
        else ok = pcall(RegisterKeyBind, k, fn) end
        log("Bound " .. label .. " (" .. (mods and "Ctrl+" or "") .. kn .. "): " .. tostring(ok))
        return ok and true or false
    end
    local function bindany(names, mods, fn, label)
        for _, kn in ipairs(names) do
            if bind(kn, mods, fn, label) then return true end
        end
        log("Bind FAILED: " .. label)
        return false
    end
    bindany({ "HOME" }, nil, function() pcall(nav_cat_cycle, -1) end, "nav category prev")
    bindany({ "END" },  nil, function() pcall(nav_cat_cycle, 1) end,  "nav category next")
    -- BACKSPACE is the walk key (pairs with Ctrl+Backspace = info). In the field the
    -- game ignores it, but it is the game's CANCEL key in menus and dialogs ("Rück
    -- Zurück"), so the plain binding only acts while exploring (nav_walk_start quiet).
    -- (Enter was unusable: Ctrl+Enter in front of an NPC opened their dialogue.)
    bindany({ "BACKSPACE", "BACK" }, nil, function()
        -- if UE4SS also fires plain binds while Ctrl is down, a Ctrl+Backspace
        -- (info) press must not ALSO start a walk: skip when a Ctrl-nav action
        -- just ran
        if os.clock() - NV.ctrlkey_t < 0.35 then return end
        pcall(nav_walk_start, true)   -- quiet outside exploration (Backspace = game cancel)
    end, "nav walk")
    bindany({ "BACKSPACE", "BACK" }, { ModifierKey.CONTROL }, function() pcall(nav_info) end,       "nav info")
    bindany({ "RETURN", "ENTER" },   { ModifierKey.CONTROL }, function() pcall(nav_walk_start) end, "nav walk alt")
    -- claim Page Up/Down in the field: with a live field player we handle the
    -- press (return true); otherwise char-select keeps it
    nav_keys.obj = function(delta)
        local p = get_player_obj()
        if not p then return false end
        pcall(nav_obj_cycle, delta)
        return true
    end

    -- KEY GUARD: the shim's low-level keyboard hook swallows these combos
    -- BEFORE the game's input layer -- Ctrl+arrows no longer step the
    -- character, Ctrl+Enter no longer opens NPC dialogue -- and queues them;
    -- the radar pump polls and dispatches. The Home/End/PageUp/PageDown/
    -- Backspace keys stay bound as alternates.
    if shim and shim.GuardCombo and shim.GuardPoll then
        local VK = { LEFT = 0x25, UP = 0x26, RIGHT = 0x27, DOWN = 0x28, RETURN = 0x0D, BACK = 0x08 }
        local ok = pcall(function()
            shim.GuardCombo(1, VK.LEFT,   true, false, false)
            shim.GuardCombo(2, VK.RIGHT,  true, false, false)
            shim.GuardCombo(3, VK.UP,     true, false, false)
            shim.GuardCombo(4, VK.DOWN,   true, false, false)
            shim.GuardCombo(5, VK.BACK,   true, false, false)
            shim.GuardCombo(6, VK.RETURN, true, false, false)
        end)
        if ok then
            nav_guard_dispatch = {
                [1] = function() nav_cat_cycle(-1) end,   -- Ctrl+Left:  previous category
                [2] = function() nav_cat_cycle(1) end,    -- Ctrl+Right: next category
                [3] = function() nav_obj_cycle(-1) end,   -- Ctrl+Up:    previous target
                [4] = function() nav_obj_cycle(1) end,    -- Ctrl+Down:  next target
                [5] = function() nav_info() end,          -- Ctrl+Backspace: info + path
                [6] = function() nav_walk_start() end,    -- Ctrl+Enter: walk / stop
            }
        end
        log("Key guard armed: " .. tostring(ok))
    end
end
end   -- nav do-block

-- ===== Radar pump: one update step, three independent drivers =====
-- ExecuteWithDelay self-rescheduling chains silently die mid-session in this game
-- (the frozen wall radar / beacon / bump of 2026-06-11), while keybinds, hooks and
-- boot-created LoopAsyncs keep firing. So every periodic field job above is a plain
-- step function, and this pump runs them all, throttled, from THREE independent
-- drivers -- any one alive keeps the radar updating:
--   1) LoopAsync(100) created here at mod load (same pattern as the talk poll),
--   2) a per-frame hook on EventManagerBP:ReceiveTick (armed lazily -- the BP loads
--      with the field map -- and re-tried from the pump until it arms),
--   3) every arrow-key press via on_arrow_log (keybinds are the most reliable
--      driver, and movement is exactly when updates matter).
-- Multi-driving is harmless: the pump no-ops if called within PUMP_MIN_DT of the
-- last run.
local pump_count  = 0
local pump_lastt  = 0.0
local PUMP_MIN_DT = 0.09
local pump_n      = { hook = 0, loop = 0, key = 0 }   -- per-driver pump counts (diagnostics)
local pump_loop_t = 0.0                               -- last LoopAsync tick (liveness)
local pump_heals  = 0
-- Per-frame tick hooks. EventManagerBP turned out to tick only DURING events on
-- some maps, so the map-local BPs (triggers/chests -- something is on every
-- field map) are required: without them the pump starves the moment the
-- LoopAsync dies (post-prologue: routing froze, the walker stood still, bump
-- could not get its second sample). Teardown safety now comes from the scene
-- guard, not from avoiding these hooks.
-- ONLY persistent actors here. Hooking ReceiveTick on DESTROYABLE/streamed actors
-- (chests, house/level triggers) crashes the game: when the game ticks such an actor
-- while tearing it down (streaming out, or mass-freed on window focus-loss), UE4SS's
-- hook DISPATCH does an IsA on the half-freed context BEFORE our Lua callback runs ->
-- uncatchable AV at UObjectBase::IsA. EventManagerBP is a persistent per-map manager
-- (not streamed), so its tick dispatch is safe. The pump's other drivers (the
-- boot-created LoopAsync + arrow keys) cover the gaps when EventManagerBP isn't ticking.
local PUMP_TICK_HOOKS = {
    "/Game/Event/BP/EventManagerBP.EventManagerBP_C:ReceiveTick",
}
local pump_hooked = {}
local function arm_pump_tickhook()
    if OP1_NO_TICK then return end
    for _, path in ipairs(PUMP_TICK_HOOKS) do
        if not pump_hooked[path] then
            local ok = pcall(RegisterHook, path, function()
                if not M.fg_ok() then return end   -- unfocused: game thread idle, skip ALL game calls
                pcall(nav_drive)   -- per-frame walk driver (cheap no-op when not walking)
                if radar_pump then pcall(radar_pump, "hook") end
            end)
            if ok then pump_hooked[path] = true; log("Pump tick hook armed: " .. path) end
        end
    end
end
local function start_pump_loop()
    return pcall(LoopAsync, 100, function()
        pump_loop_t = os.clock()
        if not M.fg_ok() then return false end   -- unfocused: skip nav_drive + pump (game calls fault)
        -- run on the game thread (this LoopAsync is a background thread; reading actors
        -- here races the game's actor frees -> uncatchable crash)
        M.in_gt(function() pcall(nav_drive); pcall(radar_pump, "loop") end)
        return false
    end)
end
-- SCENE GUARD: the crash at a cutscene's end came from world-poking (traces /
-- actor reads) continuing through the level teardown. The game itself is the
-- discriminator: EventFunction:IsEventPlaying() is true during cutscenes (and
-- scripted events), so the radar suspends exactly then -- standing around
-- thinking keeps the radar fully alive. Event end and teleports get a short
-- grace so the teardown/loading moments pass before world-poking resumes.
local WS = { px = nil, py = nil, ev_t = 0.0, hold = 0.0, susp = false }
local audio_autotry = false   -- one-shot lazy audio init (bump works without radar toggles)

-- ---------------------------------------------------------------------------
-- Scene-widget registry rebuild (replaces on_widget_created / NotifyOnNewObject, which
-- was the focus-out crash: UE4SS's IsA class-match faults on a half-built widget during
-- the focus-change HUD rebuild, before our callback, so pcall can't catch it).
-- scene_widgets feeds menu announce (poll_active_menu), options (poll_options),
-- char-select (cs_instance) AND the radar's menu gate (BLOCKING_CLASSES scan).
--
-- TWO sources, both cheap (the old broad NotifyOnNewObject is gone for good):
--   * in-game menus -> on_widget_uiopen adds them on open (event-driven).
--   * the focused screen (title menus + whatever is on top) -> this scan, via
--     KSUIManager:GetActiveStack -- the SINGLE authoritative screen the game has focused.
--     This replaced FindAllOf, which returned the title's multiple flickering widget
--     copies and made detection pick the wrong instance (wrong cursor / wrong screen
--     after a dialog). One cheap UFunction call; M.reg_add is address-deduped.
local function scan_scene_registry()
    local w, cls = M.get_active_screen()
    if w and cls and SCENE_LABELS[cls] then
        M.reg_add(w, cls, SCENE_LABELS[cls])
    end
end
-- Exposed so the fast async ok_loop (20Hz) can drive title capture for an immediate read,
-- instead of the ~5Hz game-thread pump (which made the title menu read seconds late).
M.scan_scene = scan_scene_registry

-- SPEECH BUBBLES: path-action dialogue plays in balloons (BalloonManager) WITHOUT the
-- event system, so IsEventPlaying stays false and the radar kept ringing under the
-- conversation. A balloon in use (UseBalloons, not ended) = a conversation is on
-- screen. EBalloonType is NORMAL/ANGER/THINKING/DEEP_THINKING only -- the "..." talk
-- hint over NPCs is an emotion icon, not a balloon, so walking past NPCs stays live.
-- The manager is a persistent UI widget; cached, re-found at most every 2 s. Only
-- called from the pump's gate when the world isn't suspended (never mid-fade).
M.balloon_active = function()
    local bm = M.balloon_mgr
    local okb = false
    if bm then pcall(function() okb = bm:IsValid() end) end
    if not okb then
        M.balloon_mgr = nil
        local now = os.clock()
        if now - (M.balloon_find_t or -10) < 2.0 then return false end
        M.balloon_find_t = now
        pcall(function()
            local x = FindFirstOf("BalloonManagerBP_C")
            if not (x and x:IsValid()) then x = FindFirstOf("BalloonManager") end
            if x and x:IsValid() then M.balloon_mgr = x end
        end)
        bm = M.balloon_mgr
        if not bm then return false end
    end
    local n = 0
    pcall(function()
        bm.UseBalloons:ForEach(function(_, v)
            local b = v:get()
            if b and b:IsValid() and not b.EndFlag then n = n + 1 end
        end)
    end)
    return n > 0
end

-- Nearest kept (talkable) NPC to the player within maxd units, same level. Exploring
-- only (reads actor positions).
M.nearest_npc = function(maxd)
    local p = get_player_obj(); if not p then return nil end
    local px, py, pz = read_actor_pos(p); if not px then return nil end
    local best, bd = nil, maxd or 250
    for _, b in ipairs(beacon_objs) do
        if b.cat == "npc" then
            local ox, oy, oz = read_actor_pos(b.actor)
            if ox and math.abs((oz or pz) - pz) <= LEVEL_THRESH then
                local d = math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2)
                if d < bd then best, bd = b.actor, d end
            end
        end
    end
    return best, bd
end

-- AREA NAME: entering an area shows a banner (MapNameNotificationWidget_C with
-- TextRegionName "Flachland" + TextAreaName "Königliche Akademie von Atlasdamm").
-- Speak "<area>, <region>" whenever that text changes -- also right after loading.
-- Read from the pump only while the world isn't suspended (never mid-fade); the
-- widget is cached and re-found at most every 2 s.
M.poll_area_name = function()
    local w = M.area_widget
    local ok = false
    if w then pcall(function() ok = w:IsValid() end) end
    if not ok then
        M.area_widget = nil
        local now = os.clock()
        if now - (M.area_find_t or -10) < 2.0 then return end
        M.area_find_t = now
        pcall(function()
            local x = FindFirstOf("MapNameNotificationWidget_C")
            if x and x:IsValid() then M.area_widget = x end
        end)
        w = M.area_widget
        if not w then return end
    end
    -- plain property reads (TextBlock.Text): lighter than calling GetText() on the
    -- banner every few pumps. (A test run where the game seemed to stop taking input
    -- after GetText() polling turned out to be the keyboard focus sitting in another
    -- window, not this code.)
    local area, region
    pcall(function() area = w.TextAreaName.Text:ToString() end)
    pcall(function() region = w.TextRegionName.Text:ToString() end)
    if not area or area == "" then return end
    -- the banner's separator is part of the region text ("Flachland –"); strip a
    -- trailing dash as a whole UTF-8 sequence (byte classes would eat umlauts)
    if region then
        region = region:gsub("%s+$", "")
        for _, sep in ipairs({ "\u{2013}", "\u{2014}", "-" }) do
            if region:sub(-#sep) == sep then region = region:sub(1, -#sep - 1):gsub("%s+$", ""); break end
        end
    end
    local key = area .. "|" .. (region or "")
    if key == M.area_said then return end
    M.area_said = key
    M.area_t = os.clock()   -- a walk into an exit ends here (nav_walk_watch)
    log("AREA: " .. key)
    -- the banner's GameText labels and the level ID, to compare with the EXIT lines
    -- (an exit's strNextAreaName / strNextMapName is the label the banner shows)
    pcall(function()
        local lm, id = FindFirstOf("LevelManagerBP_C"), nil
        if lm and lm:IsValid() then id = lm.CurrentLevelID end
        local ml, rl = "?", "?"
        pcall(function() ml = w.MapNameLabel:ToString() end)
        pcall(function() rl = w.RegionNameLabel:ToString() end)
        log(string.format("AREA level=%s labels=%s/%s", tostring(id), ml, rl))
    end)
    speak((region and region ~= "") and (area .. ", " .. region) or area, false)
end

-- ACTION PROMPT: standing right at a door (and similar) shows a prompt such as
-- "[E] Öffnen" (ActionPopupWidget_C, one shared instance). Visible = isEnable and
-- Visibility 0; ShowHorizontalBox holds the key glyph (Image_Text, a circled letter
-- like "Ⓔ") and the action text ("Öffnen"). Speak "Öffnen, E" when it appears or
-- changes; nothing when it goes away. Property reads only, cached widget.
M.poll_action_popup = function()
    local w = M.popup_widget
    local ok = false
    if w then pcall(function() ok = w:IsValid() end) end
    if not ok then
        M.popup_widget = nil
        local now = os.clock()
        if now - (M.popup_find_t or -10) < 2.0 then return end
        M.popup_find_t = now
        pcall(function()
            local x = FindFirstOf("ActionPopupWidget_C")
            if x and x:IsValid() then M.popup_widget = x end
        end)
        w = M.popup_widget
        if not w then return end
    end
    local shown = false
    pcall(function() shown = (w.isEnable == true) and (w.Visibility == 0) end)
    if not shown then M.popup_said = nil; return end
    local keyglyph, action = nil, nil
    pcall(function() keyglyph = w.Image_Text.Text:ToString() end)
    pcall(function()
        w.ShowHorizontalBox.Slots:ForEach(function(_, s)
            if action then return end
            local t
            pcall(function() t = s:get().Content.Text:ToString() end)
            if t and t ~= "" and t ~= keyglyph then action = t end
        end)
    end)
    if not action then return end
    -- circled letters/digits are the key captions (Ⓔ = E); other glyphs (gamepad
    -- buttons) are skipped rather than read as symbols
    local key
    pcall(function()
        local cp = utf8.codepoint(keyglyph or "", 1)
        if cp >= 0x24B6 and cp <= 0x24CF then key = string.char(cp - 0x24B6 + 65)
        elseif cp >= 0x2460 and cp <= 0x2468 then key = tostring(cp - 0x2460 + 1) end
    end)
    local sig = action .. "|" .. (key or "")
    if sig == M.popup_said then return end
    M.popup_said = sig
    M.popup_text = key and (action .. ", " .. key) or action   -- as spoken ("Still shut. ...")
    log("PROMPT: " .. sig)
    speak(key and (action .. ", " .. key) or action, false)
end

-- INTERACTION HINT (talk + path action). The game picks ONE character you would talk
-- to: player.refTalkChara, set while you stand close to an NPC and FACE them (nil when
-- you turn away). For that same pick the field-command manager fills ActiveCommandList
-- with the path actions on offer (type 0 = plain talk; verified 2026-11-11: it fills
-- the moment you face the NPC, ~2 s before J is pressed). Both settle in the same
-- frame, so they are announced TOGETHER, once per NPC, after the pick held 0.25 s:
--   talk only         -> cue 9 (Assets/talk.*, else a soft pop)   + "Talk, <name>"
--   path action too   -> cue 8 (Assets/pathaction.*, else a chime) + "Path action, <name>"
-- (every NPC with a path action can also be talked to, so the chime covers both).
-- Not repeated while the pick stays, nor for an NPC announced < 4 s ago (turning back
-- and forth); a path action that shows up later for the same NPC upgrades the hint
-- once. A pick that was gone for > 2 s is announced again. Exploring only.
M.PATH_CUE, M.TALK_CUE = 8, 9   -- on M: the main chunk is near Lua's 200-local limit
M.interact_poll = function()
    local now = os.clock()
    local taddr, tobj = 0, nil
    local p = get_player_obj()
    if p then pcall(function()
        local o = p.refTalkChara
        if o and o:IsValid() then taddr = o:GetAddress(); tobj = o end
    end) end
    local raw = {}
    local mgr = get_fcmd_mgr()
    if mgr then local _; _, raw = read_active_commands(mgr) end
    local has_path = false
    for _, b in ipairs(raw) do if b ~= 0 then has_path = true; break end end
    -- the path target is the talk pick; without one (rare), the nearest NPC
    local addr = taddr
    if addr == 0 and has_path then
        local npc = M.nearest_npc and M.nearest_npc(250)
        if npc then pcall(function() addr = npc:GetAddress() end) end
    end
    local sig = string.format("%X:%s", addr, has_path and table.concat(raw, ",") or "-")
    if sig ~= M.ia_sig then
        M.ia_sig, M.ia_t = sig, now
        log(addr ~= 0 and string.format("INTERACT %X talk=%s path=%s", addr, tostring(taddr ~= 0),
            has_path and table.concat(raw, ",") or "none") or "INTERACT none")
    end
    if addr == 0 then
        if M.ia_said and now - M.ia_t > 2.0 then M.ia_said = nil end
        return
    end
    if now - M.ia_t < 0.25 then return end
    local s = M.ia_said
    if s and s.addr == addr and (s.path or not has_path) then return end
    local upgrade = s and s.addr == addr
    M.ia_at = M.ia_at or {}
    local recent = (not upgrade) and M.ia_at[addr] and (now - M.ia_at[addr] < 4.0)
    M.ia_said = { addr = addr, path = has_path }
    M.ia_at[addr] = now
    if recent then return end
    local nm
    pcall(function() nm = shim.NpcName(addr) end)
    if (not nm or nm == "") and tobj and M.marker_kind_of then
        -- no NPC name: maybe a minimap-marked object -- the save point's book is
        -- the talk pick at a save point (Enter opens "Speichern")
        local okk, kind = pcall(M.marker_kind_of, tobj)
        if okk and kind == "save point" then
            if audio_inited then pcall(function() shim.AudioPlayCue(M.TALK_CUE) end) end
            speak("Save point", false)
            return
        end
    end
    if not has_path and tobj then
        -- the game also picks figures you cannot really talk to: an invisible helper
        -- from the always-loaded ResidentGame level by the academy entrance gave
        -- "Talk, ???" and Enter did nothing (user report 2026-11-13). Without a path
        -- action, announce only characters the npc category counts as talkable
        -- (placement dialogue ID or learned by talking), and never a hidden actor.
        local hidden = false
        pcall(function() hidden = (tobj.bHidden == true) end)
        local okt, keep = pcall(npc_interesting, tobj)
        if hidden or not (okt and keep) then
            log(string.format("INTERACT %X not talkable (hidden=%s), no hint", addr, tostring(hidden)))
            return
        end
    end
    if nm == "???" then nm = nil end   -- the game's placeholder for a name not known yet
    if audio_inited then
        pcall(function() shim.AudioPlayCue(has_path and M.PATH_CUE or M.TALK_CUE) end)
    end
    local what = has_path and "Path action" or "Talk"
    speak((nm and nm ~= "") and (what .. ", " .. nm) or what, false)
end

-- PATH ACTION IN PROGRESS: the field-command manager's own state, polled by the radar
-- gate so the radar stays silent for the WHOLE action (bubbles, result boxes and the
-- gaps between them), not just while one of its screens has focus. Traced through a
-- full Scrutinize on 2026-11-11 (FCSTATE log):
--   menu choice       event=T start=T (play=T for a moment)   type=8
--   result panel      event=F start=T                         type=8
--   FinishFieldCommand event=T start=F, then bubbles + "new information" box
--   last box closed   event=F start=F                         type=0
-- so "IsFieldCommandEvent OR StartEventMode" spans exactly the action. PlayingCommand
-- stays set afterwards (unusable). The FCSTATE line logs every change of these flags.
M.fc_busy = function()
    local mgr = get_fcmd_mgr()
    if not mgr then return false end
    local busy, st = false, ""
    pcall(function()
        local a, c = mgr.IsFieldCommandEvent, mgr.StartEventMode
        st = string.format("event=%s start=%s type=%s", tostring(a), tostring(c),
            tostring(mgr.ExecFieldCommandType))
        busy = (a == true) or (c == true)
    end)
    if st ~= M.fc_state then M.fc_state = st; log("FCSTATE " .. st) end
    return busy
end

-- Join spoken parts into sentences without doubling punctuation ("gewonnen!." /
-- "Akademie.."): a part that already ends in . ! ? : is followed by a space only.
M.join_sentences = function(parts)
    local out = ""
    for i, p in ipairs(parts) do
        if i > 1 then out = out .. (out:match("[%.!?:]%s*$") and " " or ". ") end
        out = out .. p
    end
    return out
end

-- PATH-ACTION RESULT PANEL. Scrutinize / Inquire show FieldCommandSearch_C under the
-- shared confirm dialog: the NPC's age, their statement and the information gained.
-- The dialog's NowParam only carries the "In Ordnung" button, so poll_dialog asks
-- this for the panel text: "<name>. Alter: 41. Aussage: ... Information erhalten: ..."
-- (SearchDetailPartsWidget_C via FieldCommandSearch_C.SearchDetail). Read once when
-- the dialog opens -- never polled.
M.fc_result_text = function(dlg)
    local pick
    local daddr = 0
    pcall(function() daddr = dlg:GetAddress() end)
    pcall(function()
        local all = FindAllOf("FieldCommandSearch_C")
        if not all then return end
        for _, w in pairs(all) do
            local ok = false
            pcall(function() ok = w:IsValid() end)
            if ok then
                local ta = 0
                pcall(function() local td = w.TmpDialog; if td and td:IsValid() then ta = td:GetAddress() end end)
                if ta ~= 0 and ta == daddr then pick = w; return end
                if not pick and widget_is_visible(w) then pick = w end
            end
        end
    end)
    if not pick then return nil end
    local sd
    pcall(function() sd = pick.SearchDetail end)
    if not sd then return nil end
    local parts = {}
    local mgr = get_fcmd_mgr()
    if mgr then pcall(function()
        local t = mgr.TargetCharacter
        if t and t:IsValid() then
            local nm = shim.NpcName(t:GetAddress())
            if nm and nm ~= "" then parts[#parts + 1] = nm end
        end
    end) end
    local function shown(field)        -- root widget not Collapsed(1) / Hidden(2)
        local v = 0
        pcall(function() v = sd[field].Visibility end)
        return v ~= 1 and v ~= 2
    end
    local agecap, age = read_text_block(sd, "NPCAgeText"), read_text_block(sd, "NPCAge")
    if age and shown("AgeRoot") then parts[#parts + 1] = (agecap and (agecap .. " ") or "") .. age end
    local hist = read_text_block(sd, "HistoryText")
    if hist then parts[#parts + 1] = hist end
    local infos = {}
    for i, f in ipairs({ "InformationText01", "InformationText02" }) do
        local t = read_text_block(sd, f)
        if t and shown("Information0" .. i) then infos[#infos + 1] = t end
    end
    if #infos > 0 then
        local cap = read_text_block(sd, "InformationCaptionText")
        parts[#parts + 1] = (cap and (cap .. ": ") or "") .. table.concat(infos, ", ")
    end
    local out = M.join_sentences(parts)
    return out ~= "" and out or nil
end

-- MINIMAP MARKERS: what sighted players read off the radar map (bottom right).
-- RadarMap_C.RadarIconList holds one RadarMapIconWidgets_C per icon; IconParam gives
-- the type (ERADARMAP_ICON_TYPE), the WORLD position (X,Y), the actor it is pinned to
-- (RegistObjectName = the actor's object name) and, for exits, the next field.
-- Identified 2026-11-11 in Atlasdam from full-resolution screenshots of the minimap:
--   5  = white "!"  -- a hidden item revealed by a path action (the old woman's
--        Scrutinize gave "Ein verborgenes Objekt"; the "!" appeared at that spot)
--   6  = green star with a ripple -- an NPC the current objective points at (the
--        same NPCs wear the green speech bubble, PlayEmotionType 15)
--   14 = the exit drawn green (toward the objective)
--   15 = plain exits (white house / mountain) -- skipped, the "exit" category has them
--   16 = quill -- a save point (book on a lectern; Enter opens "Speichern")
--   0  = unused slot
-- Called on demand (category cycling), exploring only.
M.MARKER_KIND = { [5] = "hidden item", [6] = "objective", [14] = "exit toward objective",
                  [16] = "save point" }

-- The marker kind pinned to an actor (by its object name), or nil. Used to name the
-- talk pick when it has no NPC name (a save point's book). Scans the ~16 icons.
M.marker_kind_of = function(actor)
    local rm = M.radarmap
    local ok = false
    if rm then pcall(function() ok = rm:IsValid() end) end
    if not ok then
        rm = nil
        pcall(function() local x = FindFirstOf("RadarMap_C"); if x and x:IsValid() then rm = x end end)
        M.radarmap = rm
    end
    if not (rm and actor) then return nil end
    local fname
    pcall(function() fname = actor:GetFName():ToString() end)
    if not fname then return nil end
    local kind
    pcall(function()
        rm.RadarIconList:ForEach(function(_, v)
            if kind then return end
            local w = v:get()
            if not (w and w:IsValid()) then return end
            local reg, t
            pcall(function() reg = w.IconParam.RegistObjectName:ToString() end)
            pcall(function() t = w.IconParam.IconType end)
            if reg == fname then kind = M.MARKER_KIND[t] end
        end)
    end)
    return kind
end
M.minimap_markers = function(pz)
    local rm = M.radarmap
    local ok = false
    if rm then pcall(function() ok = rm:IsValid() end) end
    if not ok then
        rm = nil
        pcall(function() local x = FindFirstOf("RadarMap_C"); if x and x:IsValid() then rm = x end end)
        M.radarmap = rm
    end
    if not rm then return {} end
    local icons = {}
    pcall(function()
        rm.RadarIconList:ForEach(function(_, v)
            local w = v:get()
            if not (w and w:IsValid()) then return end
            local t, vis, green, reg, x, y = 0, false, false, "", nil, nil
            pcall(function() t = w.IconParam.IconType end)
            pcall(function() vis = w.IconParam.IsVisibility end)
            pcall(function() green = w.IsGreen end)
            pcall(function() reg = w.IconParam.RegistObjectName:ToString() end)
            pcall(function() x = w.IconParam.Position.X; y = w.IconParam.Position.Y end)
            if type(t) ~= "number" or t == 0 or not vis or not x then return end
            if t == 15 and not green then return end
            icons[#icons + 1] = { type = t, green = green, reg = reg, x = x, y = y }
        end)
    end)
    if #icons == 0 then return {} end
    -- Pin every icon to an actor: NPCs by object name (they wander; the icon follows
    -- them), hidden items and exits by name or else the nearest chest / exit trigger.
    -- The actor gives the REAL height. With the player's own z (icons carry X/Y only)
    -- the router searched the wrong floor: "No route found" to the "!" one floor down
    -- (user log 2026-11-13), while the chest category reached the very same spot.
    local byname, npcs, pool = {}, {}, { chest = {}, exit = {} }
    for _, spec in ipairs({ { "KSFieldNPCCharacter_C", "npc" }, { "TreasureBoxBP_C", "chest" },
                            { "LevelTrigger_C", "exit" } }) do
        pcall(function()
            local list = FindAllOf(spec[1])
            if not list then return end
            for _, o in pairs(list) do
                local okv = false
                pcall(function() okv = o:IsValid() end)
                if okv then
                    pcall(function() byname[o:GetFName():ToString()] = o end)
                    if spec[2] == "npc" then
                        pcall(function() npcs[o:GetAddress()] = true end)
                    else
                        local ax, ay = read_actor_pos(o)
                        if ax then local t = pool[spec[2]]; t[#t + 1] = { o = o, x = ax, y = ay } end
                    end
                end
            end
        end)
    end
    local out = {}
    for _, ic in ipairs(icons) do
        local actor = (ic.reg ~= "" and ic.reg ~= "None") and byname[ic.reg] or nil
        if not actor then
            local cands = (ic.type == 5 and pool.chest) or ((ic.type == 14 or ic.type == 15) and pool.exit) or nil
            local bd = (ic.type == 5) and 300 or 600
            for _, c in ipairs(cands or {}) do
                local d = math.sqrt((c.x - ic.x) ^ 2 + (c.y - ic.y) ^ 2)
                if d < bd then actor, bd = c.o, d end
            end
        end
        local x, y, z = ic.x, ic.y, pz
        if actor then
            local ax, ay, az = read_actor_pos(actor)
            if ax then x, y, z = ax, ay, az else actor = nil end
        end
        local kind = M.MARKER_KIND[ic.type] or ((ic.type == 14 or ic.type == 15) and "exit toward objective")
            or ("marker type " .. ic.type)
        local label = kind
        local aaddr = 0
        if actor then pcall(function() aaddr = actor:GetAddress() end) end
        if npcs[aaddr] then
            -- names only for NPCs: NpcName reads the NPC placement label at a fixed
            -- offset -- on a chest or trigger that would be garbage (and a bad FName
            -- can hang GetGameTextString)
            local nm
            pcall(function() nm = shim.NpcName(aaddr) end)
            if nm and nm ~= "" and nm ~= "???" then label = nm .. ", " .. kind end
        end
        if actor and (ic.type == 14 or ic.type == 15) and not npcs[aaddr] then
            local okd, dest = pcall(M.exit_dest, actor)
            if okd and dest then label = kind .. ", to " .. dest end
        end
        out[#out + 1] = { actor = actor, x = x, y = y, z = z, label = label,
            walkcat = (ic.type == 14 or ic.type == 15) and "exit" or nil }
    end
    return out
end

-- ===== Exit destinations =====
-- Where an exit leads (user request 2026-11-13), checked in Atlasdam 2026-11-14. An exit
-- (LevelTrigger_C; C++ base LevelTriggerActor) carries GameText labels for its
-- destination: strNextMapName names the level ("T_Plain_L_C" -> "Palast von Atlasdamm",
-- "D_Plain_1_1" -> "Unterirdisches Studierzimmer"), and strNextAreaName, set on exits
-- between two parts of one level, names that part ("T_Plain_L_B_AreaB" -> "Königliche
-- Akademie von Atlasdamm"). The area banner after the walk shows exactly that label:
-- leaving the academy (area label T_Plain_L_B_AreaA) it said "Palasttor Atlasdamm".
-- Fallback for an exit without labels: m_nNextMapID is the destination level's ID, a row
-- name of /Game/Level/Database/LevelTable (LevelInfoData: LevelName FName @8, LevelKind
-- u8 @0x10, AreaID u8 @0x11, TownLabel i32 @0x14, SubTownLabel i32 @0x18), and TownTable
-- (TownInfoData: ID i32 @8, TownName FName @0x18) names the town by TownLabel. (The
-- WorldMapTable's RefLevelName lists held none of the Atlasdam level names.) The shim
-- only reads memory here (DtRowAt / DtFind / Peek), plus GetGameTextString for the text.
M.dt_addr = function(name)
    M.dt_addrs = M.dt_addrs or {}
    local a = M.dt_addrs[name]
    if a then return a end
    pcall(function()
        local o = StaticFindObject("/Game/Level/Database/" .. name .. "." .. name)
        if o and o:IsValid() then a = o:GetAddress() end
    end)
    if a and a ~= 0 then M.dt_addrs[name] = a; return a end
    return nil
end
-- FName(s) as (cmp, num). UE splits a trailing "_<digits>" off into the Number (not when
-- the digits start with 0, unless just "0"); GetComparisonIndex names the rest.
M.fname_of = function(s)
    if type(s) ~= "string" or s == "" or s == "None" then return nil end
    local cmp
    pcall(function()
        local f
        if EFindName and EFindName.FNAME_Find then f = FName(s, EFindName.FNAME_Find) else f = FName(s) end
        cmp = f:GetComparisonIndex()
    end)
    if type(cmp) ~= "number" or cmp <= 0 then return nil end
    local num = 0
    local digits = s:match("_(%d+)$")
    if digits and #digits <= 9 and (digits:sub(1, 1) ~= "0" or #digits == 1) then num = tonumber(digits) + 1 end
    return cmp, num
end
-- an FName (cmp, num) as text, for the log
M.fname_str = function(cmp, num)
    if not cmp or cmp == 0 then return "None" end
    local s = "#" .. cmp
    pcall(function() s = FName(cmp):ToString() end)
    if num and num > 0 then s = s .. "_" .. (num - 1) end
    return s
end
M.gametext = function(cmp, num)
    if not (cmp and cmp > 0 and shim and shim.GameTextFName) then return nil end
    local ok, s = pcall(shim.GameTextFName, cmp, num or 0)
    if ok and type(s) == "string" and s ~= "" and s ~= "None" then return s end
    return nil
end
-- TownTable: town ID -> TownName label (cmp, num), read once.
M.town_names = function()
    if M.town_idx then return M.town_idx end
    local idx, n = {}, 0
    local tt = shim and shim.DtCount and M.dt_addr("TownTable")
    if tt then
        for i = 0, (shim.DtCount(tt) or 0) - 1 do
            local _, _, row = shim.DtRowAt(tt, i)
            local id = row and shim.Peek(row + 0x08, "i32")
            if id then
                local c, nn = shim.PeekFName(row + 0x18)
                if c and c > 0 then idx[id] = { c, nn }; n = n + 1 end
            end
        end
    end
    log(string.format("DEST towns=%d (table %s)", n, tostring(tt)))
    if n > 0 then M.town_idx = idx end   -- table not loaded yet: try again next time
    return idx
end
-- Level ID -> { name = town name, level = level name } (or nil). Cached, logged once.
M.dest_cache = {}
M.level_dest = function(id)
    if type(id) ~= "number" or id <= 0 or not (shim and shim.DtFind) then return nil end
    local c = M.dest_cache[id]
    if c ~= nil then return c or nil end
    local res = false
    pcall(function()
        local lt = M.dt_addr("LevelTable")
        local kc, kn = M.fname_of(tostring(id))
        local row = lt and kc and shim.DtFind(lt, kc, kn)
        if not row then
            log(string.format("DEST level %d: no LevelTable row (table=%s key=%s)", id, tostring(lt), tostring(kc)))
            return
        end
        local lc, ln = shim.PeekFName(row + 0x08)
        local kind, area = shim.Peek(row + 0x10, "u8"), shim.Peek(row + 0x11, "u8")
        local town, sub = shim.Peek(row + 0x14, "i32"), shim.Peek(row + 0x18, "i32")
        local tn = town and M.town_names()[town]
        local tname = tn and M.gametext(tn[1], tn[2])
        res = { name = tname, level = M.fname_str(lc, ln) }
        log(string.format("DEST level %d = %s kind=%s area=%s town=%s(%s) sub=%s", id, res.level, tostring(kind),
            tostring(area), tostring(town), tostring(tname), tostring(sub)))
    end)
    M.dest_cache[id] = res
    return res or nil
end
-- Exit actor -> the name of the area behind it, or nil.
M.exit_logged = {}
M.exit_dest = function(actor)
    if not actor then return nil end
    local id, smap, sarea, my, nx
    pcall(function() id = actor.m_nNextMapID end)
    pcall(function() smap = actor.strNextMapName:ToString() end)
    pcall(function() sarea = actor.strNextAreaName:ToString() end)
    pcall(function() my = actor.MyTriggerID; nx = actor.NextTriggerID end)
    -- the part of the level first (what the banner will say), then the level, then the town
    local narea = M.gametext(M.fname_of(sarea))
    local nmap = M.gametext(M.fname_of(smap))
    local name = narea or nmap
    if not name then
        local d = M.level_dest(id)
        name = d and d.name
    end
    local addr = 0
    pcall(function() addr = actor:GetAddress() end)
    if not M.exit_logged[addr] then
        M.exit_logged[addr] = true
        local on = "?"
        pcall(function() on = actor:GetFName():ToString() end)
        log(string.format("EXIT %s my=%s next=%s map=%s strMap='%s'(%s) strArea='%s'(%s) -> %s", on, tostring(my),
            tostring(nx), tostring(id), tostring(smap), tostring(nmap), tostring(sarea), tostring(narea), tostring(name)))
    end
    return name
end

radar_pump = function(src)
    local now = os.clock()
    if now - pump_lastt < PUMP_MIN_DT then return end
    pump_lastt = now
    if not M.fg_ok() then return end   -- unfocused: game thread idle, skip all radar work
    pump_count = pump_count + 1
    -- Publish "is there a field player" for the async ok_loop (which can't see WS.px):
    -- false on the title/boot, true in-game. The ok_loop uses it to scan title widgets
    -- only pre-game (where async FindAllOf is safe -- no streamed field actors to free).
    M.field_player = (WS.px ~= nil)
    -- In-game registry upkeep: confirm-dialog capture + a slow fallback title scan. The
    -- find-once guard in scan_scene_registry makes this cheap (no FindAllOf once held).
    -- Fade-gated so FindAllOf never iterates GUObjectArray during a streamed-actor teardown.
    if pump_count % 10 == 3 then
        local fading = false
        if WS.fade then pcall(function() fading = WS.fade:IsFadeVisible() end) end
        if not fading then scan_scene_registry() end
    end
    local s = src or "key"
    pump_n[s] = (pump_n[s] or 0) + 1
    if not talk_hook_armed and pump_count % 20 == 7 then pcall(arm_talk_hook) end
    -- dialogue capture rides the pump (multi-driven, survives loads): log the
    -- line and feed talkable-NPC learning. The native hook already SPOKE it.
    if shim and shim.PollTalk then
        local t
        pcall(function() t = shim.PollTalk() end)
        if t and t ~= "" then
            log("STORY: " .. t)
            if learn_talk_npc then pcall(learn_talk_npc) end
        end
    end
    do
        local ev = false
        pcall(function()
            local ef = StaticFindObject("/Script/Octopath_Traveler.Default__EventFunction")
            if ef then
                ev = ef:IsEventPlaying() and true or false
                if not ev then ev = ef:IsEventPlayTheater() and true or false end
            end
        end)
        if ev then WS.ev_t = now end
        local settling = false
        if not ev then
            -- position reads PAUSE during events (scenes teleport the player step by
            -- step; freezing WS.px makes the whole displacement register as ONE jump).
            local p = get_player_obj()
            if not p then
                WS.present_since = nil        -- no field player: title / load in progress
                settling = true
            else
                if not WS.present_since then WS.present_since = now end
                -- TRANSITION GATE -- the readable "central gate" for load/exit safety.
                -- KSFade:IsFadeVisible() is true whenever the screen fade is up: the
                -- initial load AND walking through an exit, exactly when the player
                -- actor is mid-teardown and read_actor_pos AVs UE4SS (the crash). KSFade
                -- is a PERSISTENT manager, so reading it is safe mid-transition (unlike
                -- the streamed player actor). Cached; only re-found if the handle dies.
                local kf = WS.fade
                local okf = false; if kf then pcall(function() okf = kf:IsValid() end) end
                if not okf then
                    WS.fade = nil
                    pcall(function() local x = FindFirstOf("KSFade"); if x and x:IsValid() then WS.fade = x end end)
                    kf = WS.fade
                end
                local faded = nil
                if kf then pcall(function() faded = kf:IsFadeVisible() end) end
                if faded ~= false then
                    settling = true              -- fade up / unreadable / no mgr -> don't poke the world
                elseif now - WS.present_since < 0.5 then
                    settling = true              -- tiny buffer right after the player first appears
                else
                    local px, py = read_actor_pos(p)
                    if px then
                        if WS.px then
                            local dm = math.sqrt((px - WS.px) ^ 2 + (py - WS.py) ^ 2)
                            if dm > 900 then WS.hold = now + 1.0 end
                        end
                        WS.px, WS.py = px, py
                    end
                end
            end
        end
        local susp = ev or settling or (now - WS.ev_t < 1.5) or (now < WS.hold)
        -- menu-read danger flag for the async menu pollers (poll_active_menu /
        -- widget_is_visible). Fade up OR event = scene widgets mid-teardown -> their
        -- IsVisible() ProcessEvent AVs. Deliberately NOT "no field player": the title
        -- screen is stable and its menus must read, so this is fade/event-specific
        -- (narrower than world_susp). WS.fade is nil on the title -> false there.
        local fade_now = false
        if WS.fade then pcall(function() fade_now = (WS.fade:IsFadeVisible() == true) end) end
        -- A screen fade is always a teardown window. An EVENT is only one IN-GAME
        -- (cutscene) -- on the TITLE screen IsEventPlaying is true (boot/title sequence)
        -- but the menus are stable and must read, so qualify ev with "a field player
        -- exists" (WS.px). Without this the title menu never announces.
        M.menu_unsafe = fade_now or (ev and WS.px ~= nil)
        M.fade_now, M.ev_now = fade_now, (ev and WS.px ~= nil) and true or false   -- M.poll_event_menus
        world_susp = susp   -- update BEFORE the transition handling below: the
                            -- deferred learn there must see the world as RESUMED
                            -- (it used to re-queue itself forever on stale state)
        if susp ~= WS.susp then
            WS.susp = susp
            log(susp and "RADAR suspended (event/transition)" or "RADAR resumed")
            if susp then
                -- MUTE the whole soundscape: suspended sources otherwise keep
                -- ringing their last state straight through scene dialogue
                -- (engine-side calls only -- no world access)
                for i = 0, 31 do
                    pcall(function() shim.AudioSetSource(i, false, 0, 0, 0, 0) end)
                end
            else
                -- deferred talk-learning first: dialogue arrived while the
                -- guard was up; mark the NPC nearest the player's talk spot
                if npc_learned._pend then
                    local pd = npc_learned._pend
                    npc_learned._pend = nil
                    if now - pd.t < 60 and learn_talk_npc then
                        pcall(learn_talk_npc, pd.x, pd.y)
                    end
                end
                -- the scene may have swapped the map behind us: never reuse the
                -- old actor handles -- rescan shortly after the world settles
                if beacon_on then beacon_rescan_at = now + 1.0 end
            end
        end
    end
    -- dispatch combos the shim's keyboard guard swallowed for us (handlers carry
    -- their own scene checks, so this stays outside the suspension gate)
    if nav_guard_dispatch then
        local q
        pcall(function() q = shim.GuardPoll() end)
        if q then
            for _, id in ipairs(q) do
                local fn = nav_guard_dispatch[id]
                if fn then pcall(fn) end
            end
        end
    end
    -- AUTO RADAR (always-on, no manual toggle): the radar is live whenever
    -- free-roam exploration is possible -- a field player exists (WS.px), no
    -- event/transition (world_susp, = cutscene/dialogue/load), and no blocking
    -- menu visible (the scan below). Entering exploration re-enumerates the area;
    -- leaving it (menu OR scene) mutes the whole soundscape so nothing rings
    -- underneath. beacon_on/wall_on are kept in sync so the existing
    -- rescan-on-move / heartbeat references still work.
    -- menu gate: any known blocking menu widget currently VISIBLE. Scanned only when
    -- the world isn't suspended (so widgets are stable, never mid-load), breaking on
    -- the first hit. IsVisible() is false for the many cached-but-hidden menu widgets,
    -- so this fires only for the screen actually on display.
    local menu_open, talk_open = false, false
    if not world_susp then
        if pump_count % 3 == 0 then pcall(M.poll_area_name) end
        if pump_count % 2 == 1 then pcall(M.poll_action_popup) end
        -- Immediate check: the focused screen (active stack) being a blocking menu mutes
        -- the radar at once -- the scene_widgets scan below only sees it after the ~5Hz
        -- registry scan runs, which left a lag (e.g. the J path-action menu kept the radar
        -- running + arrow keys wall-bumping for a beat after opening).
        local _, acls = M.get_active_screen()
        if acls ~= M.last_acls then   -- one log line per focused-screen change
            M.last_acls = acls
            log("ACTIVE screen: " .. tostring(acls) .. (acls and BLOCKING_CLASSES[acls] and " (blocking)" or ""))
        end
        if acls and BLOCKING_CLASSES[acls] then menu_open = true end
        -- choosing an action in the J menu leaves ~1 s with no focused screen before
        -- the first bubble: keep the radar down across that gap
        if acls == "FieldCommandMenu_C" then M.fc_menu_t = now end
        if not menu_open and now - (M.fc_menu_t or -10) < 1.5 then menu_open = true end
        -- the field-command manager's own "a path action is playing" flag covers the
        -- whole action, gaps between its boxes included (M.fc_busy). Failsafe: a flag
        -- that never clears must not mute the radar for good -- after 30 s it is ignored.
        do
            local okf, busy = pcall(M.fc_busy)
            if okf and busy then
                M.fc_busy_since = M.fc_busy_since or now
                if not menu_open and now - M.fc_busy_since < 30 then menu_open = true end
            else
                M.fc_busy_since = nil
            end
        end
        if not menu_open then
            for i = 1, #scene_widgets do
                local e = scene_widgets[i]
                if BLOCKING_CLASSES[e[2]] and widget_is_visible(e[1]) then menu_open = true; break end
            end
        end
        -- speech-bubble conversation (path actions run without IsEventPlaying). Between
        -- two lines the balloon is briefly gone (<1 s, seen with NPC dialogue): hold the
        -- gate 1 s past the last bubble so the radar doesn't blip between lines.
        if not menu_open then
            local okb, act = pcall(M.balloon_active)
            if okb and act then M.balloon_t = now end
            talk_open = (now - (M.balloon_t or -10)) < 1.0
        end
        if talk_open ~= (M.last_talk or false) then
            M.last_talk = talk_open
            log("BALLOON " .. (talk_open and "active" or "none"))
        end
    end
    local explore = (WS.px ~= nil) and (not world_susp) and (not menu_open) and (not talk_open)
    beacon_on, wall_on = explore, explore
    M.explore_now = explore                  -- the Backspace walk key acts only while exploring
    M.menu_now = menu_open or talk_open      -- nav_drive: a menu/bubble stops a running walk
    if explore ~= WS.explore then
        WS.explore = explore
        log("RADAR " .. (explore and "live (exploring)"
            or ("idle (" .. (menu_open and "menu" or (talk_open and "talk" or "scene")) .. ")")))
        if explore then
            beacon_rescan_at  = now + 0.3                    -- re-enumerate this area
            beacon_rescan_say = (WS.idle_reason ~= "menu")   -- announce count on area change, not menu close
        else
            -- a bubble conversation ends like a menu: no object count afterwards
            WS.idle_reason = (menu_open or talk_open) and "menu" or "scene"
            -- where + with how many objects exploring stopped: the post-scene rescan
            -- only announces the count if the area changed in between
            M.idle_from = WS.px and { x = WS.px, y = WS.py, n = #beacon_objs } or nil
            pcall(beacon_deactivate_all)
            wall_blocked = {}
            for _, slot in ipairs(WALL_SLOT) do
                pcall(function() shim.AudioSetSource(slot, false, 0, 0, 0, WALL_CUE) end)
            end
        end
    end
    if explore then
        -- lazy audio bring-up on the first field pump
        if WS.px and not audio_inited and not audio_autotry and shim and shim.AudioInit then
            audio_autotry = true
            local okA = false
            pcall(function() okA = shim.AudioInit() end)
            audio_inited = okA and true or false
            if audio_inited then pcall(load_cues) end
            log("Audio auto-init: " .. tostring(okA))
        end
        if audio_inited then
            pcall(bump_step)
            pcall(beacon_step)
            pcall(wall_step)
        end
        pcall(nav_tick)
        pcall(M.interact_poll)   -- talk / path-action hint
    end
    if pump_count % 30 == 1 then pcall(arm_pump_tickhook) end
    -- self-heal: LoopAsyncs can die on level load; if ours has gone quiet, start a
    -- fresh one (multi-driving is throttled-safe, dead loops just stay dead)
    if src ~= "loop" and pump_loop_t > 0 and now - pump_loop_t > 5.0 and pump_heals < 30 then
        pump_heals = pump_heals + 1
        pump_loop_t = now
        local ok = start_pump_loop()
        log("Pump loop re-armed (#" .. pump_heals .. "): " .. tostring(ok))
    end
    if (beacon_on or wall_on) and pump_count % 64 == 0 then
        log(string.format("PUMP #%d hook=%d loop=%d key=%d", pump_count,
            pump_n.hook or 0, pump_n.loop or 0, pump_n.key or 0))
    end
end
do
    local okl = start_pump_loop()
    pump_loop_t = os.clock()
    pcall(arm_pump_tickhook)
    local armed = 0
    for _ in pairs(pump_hooked) do armed = armed + 1 end
    log(string.format("Radar pump: loop=%s tickhooks=%d (+arrow keys)", tostring(okl), armed))
end

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
    -- Speaker-name resolver: hand GetGameTextString's UFunction to the shim so it
    -- can locate the native impl that turns speaker handles into localized names.
    local gok, gf = pcall(StaticFindObject, "/Script/Octopath_Traveler.KSTextStatics:GetGameTextString")
    if gok and gf and gf:IsValid() and shim and shim.InstallGameTextResolver then
        log("GameText resolver: " .. tostring(shim.InstallGameTextResolver(gf:GetAddress())))
    end
    if not armed and attempt < 15 then
        ExecuteWithDelay(2000, function() install_talk_hook(attempt + 1) end)
    end
end
ExecuteWithDelay(2000, function() install_talk_hook(1) end)

-- Char-select cursor: hook the game's OnCursor{Up,Down,Left,Right} input events.
-- The callback's Context is the LIVE instance the game is driving (fixes the old
-- wrong-instance read), and it fires via ProcessInternal -- independent of the
-- poll loop (the decoupling). The move lands a frame later (UpdateInputMove in
-- Tick), so we read the settled position after a short delay, then announce the
-- hovered traveler / cursor cell, or report a no-move (blocked / reversing).
local cs_cursor_hooked = false
local cs_cursor_gen    = 0
local function on_cursor_hook(dir)
    return function(Context)
        local inst = Context and Context:get()
        if not inst then return end
        cs_cursor_gen = cs_cursor_gen + 1
        local mygen = cs_cursor_gen
        ExecuteWithDelay(140, function()
            if mygen ~= cs_cursor_gen then return end        -- superseded by a newer press
            if dlg_visible then return end                    -- a dialog owns input
            -- Full-map cursor position (on-screen cursor minus map scroll; see
            -- cs_cursor_pos). Announce the hovered traveler / cursor cell.
            local x, y = cs_cursor_pos(inst)
            if x and y then cs_announce(inst, x, y) end
        end)
    end
end
local function try_hook_cursor()
    if OP1_NO_CS then return end
    if cs_cursor_hooked then return end
    if not cs_instance then ExecuteWithDelay(1000, try_hook_cursor); return end  -- wait for the BP to load
    cs_cursor_hooked = true
    for _, dir in ipairs({ "Up", "Down", "Left", "Right" }) do
        pcall(RegisterHook, "/Game/UI/Title/BP/Scene/TitlePlayerSelect.TitlePlayerSelect_C:OnCursor" .. dir, M.fg_guard(on_cursor_hook(dir)))
    end
    log("char-select cursor hooks registered")
end
ExecuteWithDelay(3000, try_hook_cursor)

return M
