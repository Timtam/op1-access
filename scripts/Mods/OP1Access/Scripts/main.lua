-- OP1Access — Octopath Traveler screen-reader mod (Lua entry)
--
-- Architecture:
--   Lua here drives policy (what to speak, when, in response to which game
--   events). The C++ shim (OP1AccessShim.dll) statically links Lua 5.4 and
--   exposes Speak / Silence / IsSpeakingSupported, backed by Prism (NVDA,
--   JAWS, ... or OneCore/SAPI when no screen reader runs).

-- THE WHOLE MOD RUNS ON THE GAME THREAD (UE4SS 4.0.0, 2026-11-17). UE4SS runs LoopAsync
-- and ExecuteWithDelay callbacks on its async thread and RegisterKeyBind callbacks on its
-- own thread, hooks and ExecuteInGameThread work on the game thread -- all in this one
-- Lua state. Lua itself is guarded by UE4SS's lock, but the shim's C functions run
-- outside it (the shim has its own copy of Lua), so two threads in this state broke it:
-- in the first 4.0.0 test "Ref was not function" every minute or two, then a crash after
-- 12 minutes in a Lua table lookup. So this file runs once on UE4SS's thread only to
-- queue itself, and then for real on the game thread; its loops are game-thread timers
-- (LoopInGameThreadWithDelay), its delays too, and its keys are read on the game thread
-- (M.key_poll). An older UE4SS without the game-thread timers doesn't start the mod.
if not (LoopInGameThreadWithDelay and ExecuteInGameThreadWithDelay and ExecuteInGameThread) then
    print("[OP1Access] needs UE4SS 4.0.0 or newer (game-thread timers): not started\n")
    return
end
if OP1_BOOT == nil then
    OP1_BOOT = "queued"
    local src = debug and debug.getinfo and debug.getinfo(1, "S")
    local path = src and type(src.source) == "string" and src.source:match("^@(.+)$")
    local chunk, err = nil, "no path"
    if path then chunk, err = loadfile(path) end
    if chunk then
        ExecuteInGameThreadWithDelay(250, function()
            OP1_BOOT = "game thread"
            local ok, e = pcall(chunk)
            if not ok then print(string.format("[OP1Access] start failed: %s\n", tostring(e))) end
        end)
        print("[OP1Access] start queued for the game thread\n")
        return
    end
    print(string.format("[OP1Access] no start on the game thread (%s): starting here\n", tostring(err)))
    OP1_BOOT = "here"
end

local M = {}

-- UE4SS's LoopAsync / ExecuteWithDelay / ExecuteAsync become game-thread timers here (see
-- above), so every later caller gets those.
LoopAsync = function(ms, fn)
    local h
    h = LoopInGameThreadWithDelay(ms, function()
        if fn() == true and h then CancelDelayedAction(h) end
    end)
    return h
end
ExecuteWithDelay = function(ms, fn) return ExecuteInGameThreadWithDelay(ms, fn) end
ExecuteAsync = function(fn) return ExecuteInGameThread(fn) end

-- The mod's own folder (ue4ss\Mods\OP1Access\), from this file's own path -- relative to
-- Win64 (the game's working folder) or absolute.
M.MOD_DIR = (function()
    local s = debug and debug.getinfo and debug.getinfo(1, "S")
    local p = s and type(s.source) == "string" and s.source:match("^@(.-)[Ss]cripts[/\\][^/\\]+%.lua$")
    if p and p ~= "" then return (p:gsub("/", "\\")) end
    return "ue4ss\\Mods\\OP1Access\\"
end)()

-- The eight travelers' display names (identical in the English and German text). A
-- dialogue line spoken by one of them is the PLAYER's party talking, never an NPC.
M.TRAVELER = { Ophilia = true, Cyrus = true, Tressa = true, Olberic = true, Primrose = true,
               Alfyn = true, Therion = true, ["H'aanit"] = true, ["H\u{2019}aanit"] = true }

-- ===== Session logs (2026-11-23) =====
-- UE4SS empties UE4SS.log at every start, so after a crash the crashed session's log is
-- gone as soon as the game starts again. So every log() line also goes to
-- logs\session-1.log in the mod folder, written through at once (a crash loses nothing
-- written before it), and the last three sessions stay: at each start session-2 becomes
-- session-3 and session-1 session-2. The problem report window (F1 twice, or the
-- installer) attaches them. A session log that reaches M.slog.max starts over with its
-- first lines (versions, speech, language) and a note, so a runaway log can't fill the
-- disk. The logs folder comes with the mod (release ZIP, installer); without it there are
-- no session logs.
M.slog = { max = 32 * 1024 * 1024, head_max = 200, head = {}, size = 0 }
M.slog_line = function(msg)
    return string.format("[%s %.3f] %s\n", os.date("%H:%M:%S"), os.clock(), tostring(msg))
end
M.slog_open = function(dir)
    local S = M.slog
    os.remove(dir .. "session-3.log")
    os.rename(dir .. "session-2.log", dir .. "session-3.log")
    os.rename(dir .. "session-1.log", dir .. "session-2.log")
    local f = io.open(dir .. "session-1.log", "wb")
    if not f then return false end
    S.f, S.path, S.size, S.head = f, dir .. "session-1.log", 0, {}
    M.slog_write(string.format("OP1 Access session log, started %s", os.date("%Y-%m-%d %H:%M:%S")))
    return true
end
M.slog_write = function(msg)
    local S = M.slog
    if not S.f then return end
    local line = M.slog_line(msg)
    if #S.head < S.head_max then S.head[#S.head + 1] = line end
    if S.size + #line > S.max then
        -- start over: the first lines again, a note, then on
        S.f:close()
        S.f = io.open(S.path, "wb")
        if not S.f then return end
        S.size = 0
        local note = M.slog_line(string.format(
            "(the session log reached %d MB: the lines after the first %d were dropped here)",
            S.max // (1024 * 1024), #S.head))
        for _, l in ipairs(S.head) do S.f:write(l); S.size = S.size + #l end
        S.f:write(note)
        S.size = S.size + #note
    end
    S.f:write(line)
    S.f:flush()
    S.size = S.size + #line
end

local function log(msg)
    print(string.format("[OP1Access] %s\n", tostring(msg)))
    if M.slog.f then pcall(M.slog_write, msg) end
end
-- (not in the unit tests, which load the block above on its own)
if not OP1_SLOG_TEST then
    local ok, opened = pcall(M.slog_open, M.MOD_DIR .. "logs\\")
    if not (ok and opened) then
        print(string.format("[OP1Access] no session log (no logs folder in the mod folder?) %s\n", ok and "" or tostring(opened)))
    end
end
-- ===== end of session logs =====

-- ---------------------------------------------------------------------------
-- Shim load
-- ---------------------------------------------------------------------------
do
    local dlls_dir = M.MOD_DIR .. "Scripts\\"
    local extra = dlls_dir .. "?.dll"
    if not package.cpath:find(extra, 1, true) then
        package.cpath = extra .. ";" .. package.cpath
    end
end

local shim = nil
do
    local ok, mod = pcall(require, "OP1AccessShim")
    if ok then shim = mod
    else log("shim load failed: " .. tostring(mod)) end
end

-- The game's Win64 folder (absolute, UTF-8) and the mod's folder as an absolute path
-- (M.MOD_DIR can be relative to Win64), for the shim's file paths and the installer.
M.bin_dir = function()
    local exe = shim and shim.GameExePath and shim.GameExePath()
    return exe and exe:match("^(.*)\\[^\\]+$")
end
M.mod_dir_abs = function()
    if M.MOD_DIR:match("^%a:[\\/]") or M.MOD_DIR:match("^\\\\") then return M.MOD_DIR end
    local bin = M.bin_dir()
    return bin and (bin .. "\\" .. M.MOD_DIR) or M.MOD_DIR
end

local function speak(text, interrupt)
    if not text or text == "" then return end
    text = tostring(text)
    if M.money_text then
        local okm, t2 = pcall(M.money_text, text)
        if okm and t2 then text = t2 end
    end
    if M.key_glyphs then
        local okk, t3 = pcall(M.key_glyphs, text)
        if okk and t3 then text = t3 end
    end
    if not (shim and shim.Speak) then
        log("speak (NO SHIM): " .. text)
        return
    end
    log("speak: " .. text)
    if M.hist_add then pcall(M.hist_add, text) end
    pcall(function() shim.Speak(text, interrupt ~= false) end)
end

-- SPEECH HISTORY (user request 2026-11-15): the last 100 lines said -- the mod's own and
-- the dialogue the shim speaks (added from the pump's PollTalk) -- to read again at any
-- time: comma = back (the first press says the newest), period = forward, Shift+comma =
-- the first (oldest), Shift+period = the last (newest). A replay is said, not added;
-- the same line twice in a row is kept once.
M.hist = { list = {}, pos = nil, key_t = -9 }
M.hist_add = function(text)
    local H = M.hist
    if type(text) ~= "string" or text == "" then return end
    H.pos = nil   -- the next "back" starts at the newest line again
    if H.list[#H.list] == text then return end
    H.list[#H.list + 1] = text
    if #H.list > 100 then table.remove(H.list, 1) end
end
M.hist_say = function(i)
    local H = M.hist
    local n = #H.list
    local text
    if n == 0 then
        text = tr("No messages yet")
    else
        if i < 1 then i = 1 elseif i > n then i = n end
        H.pos = i
        text = H.list[i]
    end
    log(string.format("HIST %s/%d: %s", tostring(H.pos), n, text))
    if shim and shim.Speak then pcall(function() shim.Speak(text, true) end) end
end
-- dir: -1 back, 1 forward, "first", "last". UE4SS may fire a plain key's bind with
-- Shift held as well as the Shift bind: a second call within 0.15 s is dropped.
M.hist_key = function(dir)
    local H = M.hist
    local now = os.clock()
    if now - H.key_t < 0.15 then return end
    H.key_t = now
    local n = #H.list
    if dir == "first" then return M.hist_say(1) end
    if dir == "last" or H.pos == nil then return M.hist_say(n) end
    return M.hist_say(H.pos + dir)
end

local function silence()
    if shim and shim.Silence then shim.Silence() end
end

-- THE CURRENCY SIGN (user report 2026-11-14: screen readers don't read it). The game
-- writes money with its own glyph "⑳" (U+2473; GameText eMONEY_UNIT in every language:
-- "Ein Zimmer kostet Euch ⑳10.", the shop's "3.756 ⑳"). It never names the currency in
-- words -- the German text has no "Blätter" at all -- so the word comes from this table,
-- by the game's text language (the user wants it in the game's language; M.game_lang
-- below). Every spoken line goes through M.money_text.
M.MONEY_SIGN = "\226\145\179"
M.MONEY_WORDS = {
    en = { "leaf", "leaves" }, de = { "Blatt", "Blätter" }, fr = { "feuille", "feuilles" },
    es = { "hoja", "hojas" }, it = { "foglia", "foglie" }, ja = { "リーフ", "リーフ" },
    ko = { "리프", "리프" }, zh_cn = { "叶", "叶" }, zh_tw = { "葉", "葉" },
}
M.LANG_BY_NONE = { ["None"] = "en", ["Keine"] = "de", ["Rien"] = "fr", ["Nada"] = "es",
    ["Nessuno"] = "it", ["なし"] = "ja", ["없음"] = "ko", ["无"] = "zh_cn", ["無"] = "zh_tw" }
-- The game's own setting first: KSGameStatics:GetLanguage() -> EKSLanguage (the option
-- "Textsprache"; it switches the text at once). The text of BASIC_COMMAND_001 alone missed
-- the switch to English (2026-11-16: the mod stayed German). Every 5 s, every 2 s until
-- known.
M.LANG_BY_ENUM = { [0] = "ja", [1] = "en", [2] = "it", [3] = "fr", [4] = "de", [5] = "es",
    [6] = "zh_tw", [7] = "zh_cn", [8] = "ko" }
do
    local lang, lang_t, gs, unknown = nil, -99, nil, {}
    M.game_lang = function()
        local now = os.clock()
        if now - lang_t < (lang and 5 or 2) then return lang or M.lang_last or "en" end
        lang_t = now
        local l
        pcall(function()
            if not gs then gs = StaticFindObject("/Script/Octopath_Traveler.Default__KSGameStatics") end
            if gs and gs:IsValid() then
                local v = gs:GetLanguage()
                l = M.LANG_BY_ENUM[tonumber(v)]
                if not l and not unknown[tostring(v)] then
                    unknown[tostring(v)] = true
                    log("LANG: GetLanguage() gave " .. tostring(v) .. " (" .. type(v) .. ")")
                end
            end
        end)
        if not l then
            local s
            if M.gt_label then s = M.gt_label("BASIC_COMMAND_001") end
            l = s and M.LANG_BY_NONE[s]
            if s and not l and not unknown[s] then
                unknown[s] = true
                log("LANG: BASIC_COMMAND_001 is '" .. s .. "' (not in the table)")
            end
        end
        if l and l ~= lang then
            log("LANG: game text language " .. l)
            if l ~= M.lang_last and M.lang_save then pcall(M.lang_save, l) end
        end
        lang = l or lang
        return lang or M.lang_last or "en"
    end
end

-- ===== LOCALIZATION (user request 2026-11-15) =====
-- All of the mod's own words go through tr("English text") / trf("English %s", x) /
-- trn("1 thing", "%d things", n) -- English is the key, like gettext. The translations
-- are gettext .po files, Scripts/lang/<language>.po (de.po; Poedit or any text editor),
-- made from Scripts/lang/op1access.pot, which scripts/i18n.py extracts from this file.
-- The language follows the game's text language (M.game_lang, re-read every 5 s);
-- English, or a language without a .po, says the English text. The last language seen
-- is kept in lang/last.txt, so the first lines after a start ("OP1 Access loaded") are
-- in it too. N_("text") only marks a text for the .pot (tables of labels: translated
-- where they are said). A translation whose %-codes don't fit falls back to English.
M.LANG_DIR = M.MOD_DIR .. "Scripts\\lang\\"
M.i18n = { cats = {}, missing = {} }
M.po_unescape = function(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" elseif c == "t" then return "\t" elseif c == "r" then return "\r" end
        return c   -- \" \\ and anything else: the character itself
    end))
end
-- .po text -> { msgid = msgstr, msgid = { singular, plural } }; fuzzy and empty entries
-- are left out (they stay English)
M.po_parse = function(text)
    local cat = {}
    local cur, field = {}, nil
    local function flush()
        if cur.msgid and cur.msgid ~= "" and not cur.fuzzy then
            if cur.plural then
                if cur.str0 and cur.str0 ~= "" then cat[cur.msgid] = { cur.str0, cur.str1 ~= "" and cur.str1 or cur.str0 } end
            elseif cur.str and cur.str ~= "" then
                cat[cur.msgid] = cur.str
            end
        end
        cur, field = {}, nil
    end
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
        line = line:gsub("\r$", "")
        if line:match("^%s*$") then
            flush()
        elseif line:match("^#,") then
            if line:find("fuzzy", 1, true) then cur.fuzzy = true end
        elseif line:match("^#") then
            -- a comment, a source reference or an obsolete entry (#~)
        else
            local key, rest = line:match('^(msg[%w_%[%]]+)%s+"(.*)"%s*$')
            if key then
                local names = { msgid = "msgid", msgid_plural = "plural", msgstr = "str",
                    ["msgstr[0]"] = "str0", ["msgstr[1]"] = "str1", msgctxt = "ctxt" }
                field = names[key]
                if key == "msgid" and cur.msgid and (cur.str or cur.str0) then flush(); field = "msgid" end
                if field then cur[field] = M.po_unescape(rest) end
            else
                local cont = line:match('^%s*"(.*)"%s*$')
                if cont and field then cur[field] = (cur[field] or "") .. M.po_unescape(cont) end
            end
        end
    end
    flush()
    return cat
end
-- the catalog of the game's language, or nil (English, or no .po for it)
M.i18n_cat = function()
    local l = M.game_lang and M.game_lang() or "en"
    if l == "en" then return nil end
    local c = M.i18n.cats[l]
    if c == nil then
        c = false
        local f = io.open(M.LANG_DIR .. l .. ".po", "rb")
        if f then
            local text = f:read("a")
            f:close()
            local ok, cat = pcall(M.po_parse, text)
            if ok and cat then
                c = cat
                local n = 0
                for _ in pairs(cat) do n = n + 1 end
                log(string.format("I18N %s.po: %d translations", l, n))
            else
                log("I18N " .. l .. ".po unreadable: " .. tostring(cat))
            end
        end
        M.i18n.cats[l] = c
    end
    return c or nil
end
M.i18n_miss = function(s)   -- one log line per text without a translation
    if not M.i18n.missing[s] then
        M.i18n.missing[s] = true
        log("I18N missing: " .. s)
    end
end
function tr(s)
    if type(s) ~= "string" then return s end
    local c = M.i18n_cat()
    if not c then return s end
    local t = c[s]
    if type(t) == "string" then return t end
    if type(t) == "table" then return t[1] end
    M.i18n_miss(s)
    return s
end
function trf(fmt, ...)
    local t = tr(fmt)
    if t ~= fmt then
        local ok, s = pcall(string.format, t, ...)
        if ok then return s end
        log("I18N bad format in the translation of: " .. fmt)
    end
    return string.format(fmt, ...)
end
-- n = 1: the singular, else the plural. Formatted with the extra arguments, or with n
-- alone when there are none: trn("%d hour", "%d hours", h), trn("%s, %d target. ",
-- "%s, %d targets. ", n, name, n)
function trn(s, p, n, ...)
    local c = M.i18n_cat()
    local t = c and c[s]
    local fmt = (n == 1) and s or p
    local args = table.pack(...)
    if args.n == 0 then args = table.pack(n) end
    if type(t) == "table" then
        local tt = (n == 1) and t[1] or t[2]
        local ok, out = pcall(string.format, tt, table.unpack(args, 1, args.n))
        if ok then return out end
        log("I18N bad format in the translation of: " .. s)
    elseif c then
        M.i18n_miss(s)
    end
    return string.format(fmt, table.unpack(args, 1, args.n))
end
function N_(s) return s end
M.lang_save = function(l)
    M.lang_last = l
    local f = io.open(M.LANG_DIR .. "last.txt", "wb")
    if f then f:write(l); f:close() end
end
do
    local f = io.open(M.LANG_DIR .. "last.txt", "rb")
    if f then
        local l = (f:read("a") or ""):match("^%s*([%w_]+)")
        f:close()
        if l and M.MONEY_WORDS[l] then M.lang_last = l end
    end
end
M.money_text = function(s)
    if not s:find(M.MONEY_SIGN, 1, true) then return s end
    local w = M.MONEY_WORDS[M.game_lang()] or M.MONEY_WORDS.en
    local function word(n) return (n == "1") and w[1] or w[2] end
    -- "⑳10." / "⑳ 1.200": the number first ("10 Blätter."; a full stop stays at the end)
    s = s:gsub(M.MONEY_SIGN .. "%s*(%d[%d%.,]*)", function(n)
        local num, tail = n:match("^(.-)([%.,]*)$")
        return num .. " " .. word(num) .. tail
    end)
    -- "3.756 ⑳", "{0}⑳"
    s = s:gsub("(%d[%d%.,]*)%s*" .. M.MONEY_SIGN, function(n) return n .. " " .. word(n) end)
    -- the sign alone: "(⑳)", "⑳ Wurf"
    s = s:gsub(M.MONEY_SIGN, w[2])
    return s
end

-- KEY GLYPHS: tutorials and the battle's boost help name keyboard keys as circled
-- letters, which the game's font draws as key caps: "Drückt die Ⓞ-Taste, um das Radar
-- ein- und auszuschalten", "Versucht, vor einem Stadtbewohner Ⓙ zu drücken!", "mit den
-- Richtungsknöpfen ⒶⒹ" (U+24B6-24CF, ⓐ-ⓩ U+24D0-24E9). Screen readers name the
-- character or skip it, so the letter is said instead; keys side by side get a space
-- ("A D"). Every spoken line goes through it (2026-11-15).
-- The other key caps, from the game's own table (UI/Common_PC CommonKeyConfigDataTable,
-- 2026-11-18: the journal's footer said "┣: Zurück"): letters are Ⓐ-Ⓩ, digits ⑴-⑼ and
-- ⑽, the number pad ⑾-⒆ and ⒇, F1-F12 ⒈-⒓. The small circled letters are NO letters:
-- arrows (ⓑ right, ⓒ left, ⓓ up, ⓔ down), modifiers and gamepad buttons; German,
-- Italian, Spanish and French keyboards draw their Backspace, Space, Shift ... as
-- box-drawing characters (┣ ┟ ┠ ...). Where the table gives one glyph to two keys, the
-- one a default binding uses is named (ⓛ is also the number pad's +, ⓒ the French
-- Backspace). Punctuation keys and what the table leaves unsure are kept as they are.
M.KEY_CAPS = {
    [0x24F3] = N_("Tab"), [0x24F4] = N_("Enter"), [0x24F0] = N_("Escape"), [0x24EE] = N_("Space"),
    [0x24F1] = N_("Page Up"), [0x24F2] = N_("Page Down"), [0x24EC] = N_("Home"), [0x24ED] = N_("End"),
    [0x24D1] = N_("Right arrow"), [0x24D2] = N_("Left arrow"), [0x24D3] = N_("Up arrow"), [0x24D4] = N_("Down arrow"),
    [0x24B2] = N_("Insert"), [0x24EB] = N_("Delete"), [0x24EF] = N_("Backspace"),
    [0x24DA] = N_("Shift"), [0x24D9] = N_("Right Shift"), [0x24D8] = N_("Ctrl"), [0x24D7] = N_("Right Ctrl"),
    [0x24D6] = N_("Alt"), [0x24D5] = N_("Right Alt"), [0x2514] = N_("AltGr"), [0x2547] = N_("Right Ctrl"),
    [0x24AF] = N_("Caps Lock"), [0x24B3] = N_("Pause"), [0x24B4] = N_("Num Lock"), [0x24B1] = N_("Scroll Lock"),
    [0x2546] = N_("Menu key"),
    [0x2496] = N_("Numpad multiply"), [0x2499] = N_("Numpad minus"), [0x249A] = N_("Numpad decimal"),
    [0x2495] = N_("Numpad divide"),
    -- German
    [0x2523] = N_("Backspace"), [0x251F] = N_("Space"), [0x2520] = N_("Shift"), [0x2521] = N_("Right Shift"),
    [0x2525] = N_("Alt"), [0x2548] = N_("Ctrl"), [0x2515] = N_("Home"), [0x2516] = N_("Page Up"),
    [0x2517] = N_("Page Down"), [0x2519] = N_("Delete"), [0x251A] = N_("Insert"), [0x2522] = N_("Caps Lock"),
    [0x251D] = N_("Numpad divide"), [0x251E] = N_("Numpad multiply"), [0x249B] = N_("Numpad decimal"),
    -- Italian
    [0x2526] = N_("Insert"), [0x2527] = N_("Home"), [0x252B] = N_("Page Up"), [0x2528] = N_("Delete"),
    [0x2529] = N_("End"), [0x252C] = N_("Page Down"), [0x252D] = N_("Backspace"), [0x252F] = N_("Caps Lock"),
    [0x2530] = N_("Shift"), [0x2531] = N_("Right Shift"), [0x252A] = N_("Space"),
    -- Spanish
    [0x253E] = N_("Home"), [0x253F] = N_("Page Up"), [0x2541] = N_("Delete"), [0x2540] = N_("Page Down"),
    [0x2543] = N_("Backspace"), [0x2544] = N_("Caps Lock"),
    -- French
    [0x2538] = N_("Home"), [0x253A] = N_("Page Up"), [0x2537] = N_("Delete"), [0x2535] = N_("End"),
    [0x253B] = N_("Page Down"), [0x2534] = N_("Caps Lock"), [0x2532] = N_("Shift"), [0x2533] = N_("Right Shift"),
    [0x2536] = N_("Space"),
    -- mouse
    [0x250D] = N_("left mouse button"), [0x250E] = N_("right mouse button"), [0x250F] = N_("middle mouse button"),
    [0x2512] = N_("mouse button 4"), [0x2511] = N_("mouse button 5"),
    -- gamepad (by the Xbox names)
    [0x24DB] = N_("A button"), [0x24DC] = N_("B button"), [0x24DD] = N_("X button"), [0x24DE] = N_("Y button"),
    [0x24E3] = N_("LB"), [0x24E5] = N_("RB"), [0x24E1] = N_("LT"), [0x24E2] = N_("RT"),
    [0x24E6] = N_("left stick"), [0x24E7] = N_("right stick"), [0x2513] = N_("View button"),
    [0x2509] = N_("Menu button"), [0x24E0] = N_("Back button"), [0x24DF] = N_("Start button"),
}
M.key_glyphs = function(s)
    if not s:find("\226[\145-\149]") then return s end
    local function key(n) return "\1" .. n .. "\2" end
    s = s:gsub("\226[\145-\149][\128-\191]", function(c)
        local cp = utf8.codepoint(c)
        if cp >= 0x24B6 and cp <= 0x24CF then return key(string.char(65 + cp - 0x24B6)) end
        if cp >= 0x2474 and cp <= 0x247C then return key(tostring(cp - 0x2473)) end
        if cp == 0x247D then return key("0") end
        if cp >= 0x247E and cp <= 0x2487 then return key(trf("Numpad %s", tostring((cp - 0x247D) % 10))) end
        if cp >= 0x2488 and cp <= 0x2493 then return key("F" .. (cp - 0x2487)) end
        local n = M.KEY_CAPS[cp]
        if n then return key(tr(n)) end
        return c
    end)
    return (s:gsub("\2\1", " "):gsub("[\1\2]", ""))
end

-- One spoken line from text pieces that may hold line breaks: a skill's help is
-- "Kosten: 8 FP\nFügt allen Gegnern Blitzschaden zu.". A piece ending without
-- punctuation before one that doesn't start in lower case gets ". " (a pause);
-- otherwise a plain space, so a sentence wrapped mid-way stays whole and a tutorial's
-- "behalten!" isn't followed by another ".". German nouns start in upper case, so a
-- break INSIDE a piece after a word in lower case is a wrap too: "auf ein gewisses\n
-- Herrenhaus" was read "gewisses. Herrenhaus" (2026-11-15).
M.ends_lower_word = function(s)
    local w = s:match("(%S+)$")
    if not w then return false end
    w = w:gsub("^[%(%[\"']+", ""):gsub("^\226\128[\152\156\158]", "")
    return w:find("^%l") ~= nil or w:find("^\195[\159-\191]") ~= nil
end
M.join_text = function(parts)
    local out = ""
    for _, part in ipairs(parts) do
        local inner = false        -- a later line of this same piece
        for line in (tostring(part) .. "\n"):gmatch("(.-)\r?\n") do
            line = line:gsub("^%s+", ""):gsub("%s+$", "")
            if line ~= "" then
                if out == "" then
                    out = line
                -- (also after a sentence closed in brackets, "... misslingt.)", and before a
                -- bracket that goes on the line before: "Nach Atlasdamm\n(Flachland) reisen?")
                elseif out:find("[%.!%?:;,]$") or out:find("[%.!%?]%)$") or out:find("\226\128\166$")
                    or line:find("^%l") or line:find("^\195[\159-\191]")
                    or (inner and (M.ends_lower_word(out) or line:find("^%("))) then
                    out = out .. " " .. line
                else
                    out = out .. ". " .. line
                end
                inner = true
            end
        end
    end
    return out
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

-- Run fn in UE4SS's next game-thread run (ExecuteInGameThread): after the callback, hook
-- or key that asks for it, between two of the game's frames. Game-object work (FindAllOf,
-- IsValid, ProcessEvent, position reads) beside the game thread raced the game freeing
-- actors (streaming as you walk, mass-freed on window focus-loss) -> uncatchable
-- IsA/ProcessEvent crashes; the whole mod runs on the game thread now (see the top of
-- this file), and this queue still lets a handler put its slow part after itself.
M.gt_pending = {}
-- Work queued while such a run is going (M.gt_depth > 0) runs right after it, in the
-- same run, instead of a nested ExecuteInGameThread (UE4SS iterates its queue meanwhile).
-- One round only: what arrives meanwhile waits for the next run, so a busy queue can't
-- keep the game thread in our code (that froze the game once).
M.gt_depth = 0
M.gt_drain = function()
    if #M.gt_pending == 0 then return end
    local l = M.gt_pending
    M.gt_pending = {}
    for _, f in ipairs(l) do
        local ok, err = pcall(f)
        if not ok then log("GT: queued work failed: " .. tostring(err)) end
    end
end
M.in_gt = function(fn)
    if M.gt_depth > 0 then M.gt_pending[#M.gt_pending + 1] = fn; return end
    ExecuteInGameThread(function()
        M.gt_depth = M.gt_depth + 1
        pcall(M.gt_drain)
        local ok, err = pcall(fn)
        if not ok then log("GT: queued work failed: " .. tostring(err)) end
        pcall(M.gt_drain)
        M.gt_depth = M.gt_depth - 1
    end)
end

-- KEYS READ ON THE GAME THREAD (2026-11-17). UE4SS's key-bind thread would run our Lua
-- beside the game thread's (see the top of this file). So here RegisterKeyBind only
-- records the bind, and M.key_poll -- every frame, on the game thread -- looks at the
-- bound keys (shim.KeyScan: GetAsyncKeyState, as UE4SS does) with UE4SS's rules: a bind
-- fires when its key goes down while exactly its modifiers (Ctrl, Shift, Alt) are held,
-- and only while the game window is in front. Its callback runs right there; work it
-- queues itself (M.in_gt) runs right after it. (M.key_t: when the last key fired, for
-- the log)
M.keys = { list = {}, vks = {}, known = {}, down = {} }
M.KEY_MODBIT = { [0x11] = 1, [0x10] = 2, [0x12] = 4 }   -- ModifierKey CONTROL, SHIFT, ALT
M.key_register = function(key, a, b)
    local mods, fn = a, b
    if type(a) == "function" then mods, fn = nil, a end
    if type(key) ~= "number" or type(fn) ~= "function" then error("RegisterKeyBind: bad arguments") end
    local mask = 0
    for _, m in ipairs(mods or {}) do mask = mask | (M.KEY_MODBIT[m] or 0) end
    local K = M.keys
    K.list[#K.list + 1] = { vk = key, mask = mask, fn = fn }
    if not K.known[key] then
        K.known[key] = true
        K.vks[#K.vks + 1] = key
    end
    return true
end
M.key_poll = function()
    local K = M.keys
    if #K.vks == 0 then return end
    if not M.fg_ok() then return end
    local ok, mask = pcall(shim.KeyScan, K.vks)
    if not ok or type(mask) ~= "number" then return end
    local fired
    for i, vk in ipairs(K.vks) do
        local isdown = ((mask >> (i - 1)) & 1) == 1
        if isdown and not K.down[vk] then
            fired = fired or {}
            fired[#fired + 1] = vk
        end
        K.down[vk] = isdown
    end
    if not fired then return end
    local c, s, a = shim.KeyModifiers()
    local mm = (c and 1 or 0) | (s and 2 or 0) | (a and 4 or 0)
    for _, vk in ipairs(fired) do
        for _, b in ipairs(K.list) do
            if b.vk == vk and b.mask == mm then
                M.key_t = os.clock()
                local okf, err = pcall(b.fn)
                if not okf then log(string.format("KEY %d failed: %s", vk, tostring(err))) end
            end
        end
    end
end
RegisterKeyBind = M.key_register
if shim and shim.KeyScan and shim.KeyModifiers then
    local okp, h
    if EngineTickAvailable and LoopInGameThreadAfterFrames then
        okp, h = pcall(LoopInGameThreadAfterFrames, 1, M.key_poll)
    else
        okp, h = pcall(LoopInGameThreadWithDelay, 10, M.key_poll)
    end
    log("keys: read on the game thread (" .. ((EngineTickAvailable and "every frame") or "every 10 ms") ..
        "): " .. tostring(okp and h))
else
    log("keys: the shim can't read keys (no KeyScan): the mod's keys are off")
end

-- Hook enablement (globals, not chunk locals, to dodge the main-chunk 200-local limit).
-- These are the conclusion of isolating the focus-out crash:
--   OP1_NO_CREATED = true  -- NotifyOnNewObject (every widget construction) is THE focus-
--     out crash: UE4SS's IsA class-match faults on a half-built widget during the
--     focus-change HUD rebuild, before our callback, so pcall can't catch it. Removed for
--     good; menu detection is KSUIManager:GetActiveStack + the polls.
-- The rest are safe and ON.
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
    UIMainTitle_C            = N_("Title"),
    TitleMainMenu_00_C       = N_("Press any button"),
    TitleMainMenu_01_C       = N_("Title menu"),
    TitleOptionScene_C       = N_("Options"),
    TitleLoadScene_C         = N_("Load game"),
    TitlePlayerSelect_C      = N_("Choose your character"),
    -- Top-level in-game menus (route via KSUIManager too, kept as fallback)
    MainMenuWidget_C         = N_("Main menu"),
    MainMenuItemListWidget_C = N_("Items"),
    MainMenuAbilityWidget_C  = N_("Abilities"),
    MainMenuJobWidget_C      = N_("Jobs"),
    MainMenuTutorialListWidget_C = N_("Tutorials"),
    MainMenuMissionRecord_C  = N_("Mission record"),
    MainMenuEtcWidget_C      = N_("Other"),
    EquipmentMenuWidget_C    = N_("Equipment"),
    StatusMenuWidget_C       = N_("Character status"),
    JobStatusWidget_C        = N_("Job status"),
    -- Save / load
    MenuSaveLoad_C           = N_("Save and load"),
    -- Options. On this (Steam) build the ACTUAL options screen the UI manager focuses is
    -- OptionMenuSteamWBP_C (confirmed via GetActiveStack); OptionMenuWBP_C is the non-Steam
    -- variant. Both carry the option-menu fields directly (IsActive/CursorIndex/
    -- OptItemVerticalBox/TitleText/OptionKindArray) and are read the same way in poll_options.
    OptionMenuWBP_C          = N_("Options"),
    OptionMenuSteamWBP_C     = N_("Options"),
    -- Field command (the path-action menu opened with J near an NPC/object)
    FieldCommandMenu_C       = N_("Path action"),
    -- Battle
    BattleCommandMenu_C      = N_("Battle command menu"),
    BattleResultPanelWidget_C= N_("Battle results"),
    -- Story / dialog / narration
    ChatWidget_C             = N_("Conversation"),
    -- UICommonDialogBP_C is intentionally not in this list: it constructs
    -- alongside the title screen as part of the framework, and its
    -- announcement would steal the slot from the actual title widgets.
    -- Dialogs are read by poll_dialog with caption + detail + buttons, which is
    -- far more useful.
    NarrationWidget_C        = N_("Narration"),
    NarrationMessageWidget_C = N_("Narration message"),
    NarrationNoteWidget_C    = N_("Narration note"),
    -- Misc
    StaffCreditWBP_C         = N_("Staff credits"),
    PartyChat_C              = N_("Party chat"),
}

-- Suppression: avoid speaking very transient / decorative widgets that
-- construct alongside a real menu and would create double-speak. We only
-- speak when the class is in SCENE_LABELS, so a new class is silent by
-- default — but we still log every Construct so we can grow the whitelist.

-- ---------------------------------------------------------------------------
-- EKSUIKind (KSUIManager:Open / GetList): 0 title screen, 10 main menu, 11 shop,
-- 12 dialog, 13 field actions, 14 purchase, 15 provoke, 16 allure, 17 inquire,
-- 18 mini map, 19 tutorial, 20 game over, 21 narration, 22 world map, 23 menu,
-- 24 party chat, 25 flashback, 26 notification, 27 map notification, 28 party chat
-- available, 29 party change, 30 staff credits, 50 options, 51 equipment, 52 save and
-- load, 53 character status, 54 items, 55 abilities, 56 tutorials, 57 change jobs,
-- 58 mission record, 59 story select, 60 event battle, 61 party split, 62 ability
-- settings, 100 action popup, 101 skip event, 102 judge, 103 auto saving, 104 help.
-- (The screens are found by the polls: KSUIManager:GetActiveStack and the widgets.)
-- ---------------------------------------------------------------------------

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
    BattleCommandMenu_C = true, BattleResultPanelWidget_C = true, UIGameOver_C = true,
    ShopMenuWidget_C = true,   -- shops and inns (the radar kept playing in a shop, 2026-11-14)
    -- a menu's list or amount picker focused on its own (inside a shop, the equipment)
    ListWidget_C = true, SelectItemNumWidget_C = true,
    ChatWidget_C = true, PartyChat_C = true,
    FieldCommandMenu_C = true,   -- path-action menu (J): mute radar / no wall-bump while open
    -- path-action RESULT scenes (Study/Search, Purchase/Steal, Allure/Lure, Inquire/Judge,
    -- Provoke/Monster) -- dialog-like, read fine, but the radar must stay silent during them
    FieldCommandSearch_C = true, FieldCommandPurchase_C = true, FieldCommandLure_C = true,
    FieldCommandJudge_C = true, FieldCommandMonster_C = true,
    -- their lists focused on their own (Purchase / Steal, H'aanit's monsters)
    PurchaselistWidget_C = true, MonsterListWidget_C = true,
    -- the tavern's party change and story select (the latter also on entering a town)
    ListCharacterWidget_C = true, BarMenuStorySelect_C = true,
    -- focused while a path action plays out (user log 2026-11-10): the bubble manager
    -- during the speech bubbles, the common dialog for the result boxes ("Ihr habt
    -- neue Informationen gewonnen!") -- the radar came back between the boxes.
    -- Active-stack only (not in SCENE_LABELS), so a cached copy can't block.
    BalloonManagerBP_C = true, UICommonDialogBP_C = true,
    -- a tutorial pop-up (2026-11-16: the radar played under it, and the Backspace that
    -- closes it also started a walk to the selected target). Active-stack only too.
    UITutorial_C = true,
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
-- in the whitelist. (Off: OP1_NO_CREATED)
-- ---------------------------------------------------------------------------
-- The screen named last (poll_active_menu), so it isn't named twice.
local last_spoken_class  = nil

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
-- ignoring repeat sightings of a still-live one. Used by the screen scan
-- (scan_scene_registry).
M.reg_add = function(w, cls, label)
    local addr
    pcall(function() if w and w:IsValid() then addr = w:GetAddress() end end)
    if not addr or addr == 0 then return end
    for i = 1, #scene_widgets do
        if scene_widgets[i][4] == addr then return end   -- already registered + live
    end
    -- [5]: a handle (M.handle) -- the polls check it with the shim before UE4SS touches
    -- the widget again (see poll_active_menu)
    scene_widgets[#scene_widgets + 1] = { w, cls, label, addr, M.handle and M.handle(w) or nil }
    if cls == "TitlePlayerSelect_C" then cs_instance = w end
end
-- An entry UE4SS may touch: its handle still shows the same object in the shim's guarded
-- reads. A freed widget handed to UE4SS faults in IsA, past any pcall (the load crash of
-- 2026-11-15 was poll_active_menu; the other readers of this list had no check at all).
M.sw_ok = function(e)
    return e ~= nil and (e[5] == nil or M.handle_ok(e[5]))
end
-- Drop the entries whose widget is gone: the fast polls' first step, during a fade too
-- (only the shim's reads), so no reader after it in that run sees a freed widget.
M.sw_prune = function()
    for i = #scene_widgets, 1, -1 do
        local e = scene_widgets[i]
        if not M.sw_ok(e) then
            if M.trace then log("TR widget gone: " .. tostring(e[2])) end
            if e[1] == cs_instance then cs_instance = nil end
            table.remove(scene_widgets, i)
        end
    end
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
    scene_widgets[#scene_widgets + 1] = { NewObject, cls, label, nil, M.handle and M.handle(NewObject) or nil }
    if cls == "TitlePlayerSelect_C" then
        cs_instance = NewObject
        -- "Choose your character" normally comes from the poll loop's visibility
        -- check -- but that loop intermittently dies after a level load. So also
        -- announce it event-driven here, gated so cached/never-shown instances
        -- built at launch stay silent: after a short delay, only if the screen is
        -- actually on-screen (cs_live_instance reads a live cursor) and the loop
        -- hasn't already named it.
        -- (the widget reads on the game thread, like the screen polls: M.in_gt)
        ExecuteWithDelay(500, function() M.in_gt(function()
            if last_polled_class == "TitlePlayerSelect_C" then return end
            if not cs_live_instance or not cs_live_instance() then return end
            last_polled_class = "TitlePlayerSelect_C"
            last_spoken_class = "TitlePlayerSelect_C"
            cs_coord_mute = CS_COORD_MUTE
            speak(tr(label))
        end) end)
    end

    -- Do NOT announce on construction. At launch the game builds dozens of menu
    -- widgets up-front (cached, never shown), which produced spurious launch
    -- speech like "Staff credits" / "Other". A screen is announced only when it
    -- actually becomes visible -- by the poll loop below.
end

-- (No hooks on KSUIManager:Open/Close or KSUserWidgetBase:UIOpen/UIClose: these are native
-- functions, and UE4SS 4 hooks them with a native hook whose thunk walks the calling
-- Blueprint frame's out-parameter list until NULL; in UE 4.18 that list isn't always
-- NULL-terminated, and the walk spun forever on the game thread: the game froze for good
-- when a traveler's story began (2026-11-18, dump hang-20261118-063458: UIManagerBP_C:
-- PlayAfterFadeOut -> KSUIManager:Open, its list ran into the UClass "Class", whose class
-- is itself). Never register a native (/Script/) hook. The screens are read by the polls.)

-- Broad: every widget creation, via UE4SS's NotifyOnNewObject. Fires on
-- StaticConstructObject_Internal so BP-derived widgets are also caught.
-- This handles FIRST-time-ever construction.
local ok_notify, err_notify = (not OP1_NO_CREATED) and pcall(NotifyOnNewObject, "/Script/UMG.UserWidget", M.fg_guard(on_widget_created)) or false
log(string.format("NotifyOnNewObject UserWidget: %s%s", tostring(ok_notify),
    ok_notify and "" or (" (" .. tostring(err_notify) .. ")")))

-- ---------------------------------------------------------------------------
-- Polling loop: walks the scene_widgets registry on a fixed cadence to
-- detect "menu became visible" and "menu became hidden" transitions. Common
-- case is the bespoke Title-screen widgets — they're toggled by visibility flips
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
-- Every in-game menu is read by its own reader instead -- keeping
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
    -- inside one run of the fast screen polls the screen can't change: one GetActiveStack
    -- call per run instead of one per reader (2026-11-15: fewer UFunction calls from game-
    -- thread jobs, after a c0000264 in UE4SS's hook machinery mid-session)
    local fr = M.fast_run
    if fr and fr.done then return fr.w, fr.cls end
    local w, cls = M.get_active_screen_raw()
    if fr then fr.w, fr.cls, fr.done = w, cls, true end
    return w, cls
end
M.get_active_screen_raw = function()
    local kuim = M.ui_manager
    local ok = false
    -- (the kept manager only while the shim's reads show the same object: M.handle_ok)
    if kuim and (not M.handle_ok or M.handle_ok(M.ui_manager_h)) then pcall(function() ok = kuim:IsValid() end) end
    if not ok then
        M.ui_manager, M.ui_manager_h = nil, nil
        -- FindFirstOf walks every object (~45 ms) while no manager exists yet (boot):
        -- at most once a second, not on every call of every reader
        local now = os.clock()
        if now - (M.uim_tried or -9) < 1.0 then return nil, nil end
        M.uim_tried = now
        pcall(function()
            local x = FindFirstOf("KSUIManager")
            if x and x:IsValid() then
                M.ui_manager = x
                M.ui_manager_h = M.handle and M.handle(x) or nil
            end
        end)
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
        if entry[2] == active_cls and M.sw_ok(entry) then
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
    M.say_item(label or trf("Item %s", tostring(sel)))
end

local function poll_active_menu()
    -- Skip the whole IsValid/IsVisible sweep during a fade/cutscene: the scene widgets
    -- may be mid-teardown and the UFunction calls AV uncatchably (the ProcessEvent
    -- crash). This runs on the async loop, which can't see world_susp; M.menu_unsafe is
    -- the pump's fade/event flag (false on the stable title, so title menus still read).
    if M.menu_unsafe then return end
    local kept = {}
    local best_idx, best_class, best_label = 0, nil, nil
    if M.trace then log("TR active loop " .. #scene_widgets) end

    for i = 1, #scene_widgets do
        local entry = scene_widgets[i]
        local w, cls, label = entry[1], entry[2], entry[3]

        -- The shim's guarded reads first (entry[5], M.handle): a title widget freed
        -- while a save loads from the title after a game over took the game down in
        -- UE4SS's IsA, past any pcall, twice (2026-11-15; the trace's last line was
        -- this poll). Only a handle that still matches may be touched by UE4SS.
        local alive = false
        if entry[5] and M.handle_ok(entry[5]) then
            pcall(function() alive = w and w:IsValid() end)
        end
        if not alive and w == cs_instance then cs_instance = nil end
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
    if M.trace then log("TR active dialog") end
    if poll_dialog and poll_dialog() then return end
    if M.trace then log("TR active title") end

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
            M.scr_said_t = os.clock()
            speak(tr(best_label))          -- screen name (interrupts)
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
    if M.trace then log("TR active cs") end

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
local npc_learned = {}        -- actor address -> record {lbl, learned?, name, sname, sdone} (this session)
local npc_talking = nil       -- {addr,t,named}: the EXACT actor whose Talk just fired
local learn_talk_npc          -- assigned later (needs the overworld helpers)
-- The record of one NPC actor. npc_learned is keyed by ADDRESS and lives all session:
-- an actor of the next map at a reused address inherited the old one's name and
-- talkability. So the record keeps the NPC's placement label (NPCLabel, unique per map
-- spot: NPC_TMntS_N014C) and starts over when the actor at that address has another.
M.npc_rec = function(o, addr)
    local lbl
    pcall(function() lbl = o.NPCLabel:ToString() end)
    if lbl == "" or lbl == "None" then lbl = nil end
    local rec = npc_learned[addr]
    if rec == true then rec = { learned = true, keep = true } end   -- (the old form)
    if type(rec) ~= "table" or (lbl and rec.lbl and rec.lbl ~= lbl) then
        rec = { lbl = lbl }
        npc_learned[addr] = rec
    elseif npc_learned[addr] ~= rec then
        rec.lbl = rec.lbl or lbl
        npc_learned[addr] = rec
    elseif lbl and not rec.lbl then
        rec.lbl = lbl
    end
    return rec
end

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
        local rec = M.npc_rec(o, addr)
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
    local sl_menu, sl_idx, sl_h
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
            if m and M.kept(sl_h) then alive = true end   -- (the shim's reads first)
            if not alive then
                -- the screen is the focused one while it's up (title "Fortsetzen" too; in
                -- an event the event reader hands it over). FindFirstOf walked every
                -- object 20x a second while no such menu existed.
                m = nil
                local aw, acls = M.get_active_screen()
                if acls == "MenuSaveLoad_C" then m = aw end
                sl_menu = m
                sl_h = m and M.handle(m) or nil
            end
            if not m or not widget_is_visible(m) then sl_idx = nil; return end
        end
        -- Gate on the menu actually accepting input: while it opens it sweeps the
        -- cursor through every slot (which would voice all 24), and AcceptControl is
        -- false during that. Once ready, announce each focus change immediately.
        local ready = false
        pcall(function() ready = m.AcceptControl and true or false end)
        if not ready then sl_idx = nil; return end
        -- (save or load, and when: the dialog reader tells a confirmed load by it)
        pcall(function() M.sl_save_mode = (m.IsSaveMode == true) end)
        M.sl_seen_t = os.clock()
        local ci = nil
        pcall(function() ci = m.CursorIndex end)
        if ci == nil or ci == sl_idx then return end
        if sl_idx == nil then
            if evw then
                local save = false
                pcall(function() save = (m.IsSaveMode == true) end)
                log("SAVELOAD in event: save mode=" .. tostring(save))
                speak(save and tr("Save") or tr("Load"))
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
                if a and a:GetAddress() == sa then label = tr("Auto save") end
            end)
            if not label then
                pcall(function()
                    local n = 0
                    m.NormalSlots:ForEach(function(_, v)
                        n = n + 1
                        local o = v:get()
                        if not label and o and o:GetAddress() == sa then label = trf("Slot %d", n) end
                    end)
                end)
            end
        end
        label = label or ((ci == 0) and tr("Auto save") or trf("Slot %s", tostring(ci)))
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
        if not has then M.say_item(trf("%s, empty", label)); return end
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
            pt = (h > 0 and (trn("%d hour", "%d hours", h) .. " ") or "") .. trn("%d minute", "%d minutes", mn)
        end
        local map, area = gt("TextMap"), gt("TextArea")
        local lvl, leader = gt("TextTopLevel"), gt("TextTopLevelName")
        local date, tm = gt("TextDate"), gt("TextTime")
        local parts = { label }
        if map then parts[#parts + 1] = map end
        if area then parts[#parts + 1] = area end
        if leader then parts[#parts + 1] = lvl and trf("%s level %s", leader, lvl) or leader end
        if pt then parts[#parts + 1] = pt end
        if date then parts[#parts + 1] = date .. (tm and (" " .. tm) or "") end
        if not en then parts[#parts + 1] = tr("can't be chosen") end
        log(string.format("SAVELOAD slot %d enabled=%s map=%s pt=%s", ci, tostring(en), tostring(map), tostring(pt)))
        M.say_item(table.concat(parts, ", "))
    end
end

-- THE OBJECTIVE FROM THE STORY FLAGS (2026-11-16; Q said "No objective" until the menu
-- had been opened once, and a pressed Q before that kept the menu from reading it). Done
-- the way the menu's story panel does it (object dump: NowPlayingStoryPanel_C:
-- SetPlayingStory, EventFunctionBP_C:IsEventFlagCheck): the DataTable NextPurposeDataList,
-- row "<traveler ID 1-8>", lists NextPurposeData rows (ShowStartFlag @0xC, ShowEndFlag
-- @0x10, TextLabel @0x18); the first whose start flag is set (or 0) and whose end flag is
-- not (or 0) -- KSSaveGame:GetBitFlag -- names the text. Checked in game: Cyrus in the
-- academy, "Speak with the Royal Academy's headmaster.", as the menu showed it.
-- Travelers by the party's 0-based IDs (the save's PlayerParty lists).
M.TRAVELERS = { [0] = "Olberic", "Tressa", "Cyrus", "Primrose", "H'aanit", "Therion", "Ophilia", "Alfyn" }
M.PARTY_MAIN = "MainMemberID_26_B4144D6B4009D87793E65DB3D8FD1F30"
-- the active save game (KSSaveDataManagerBP_C.SaveGame; the manager found once, ~50 ms,
-- its class default object skipped), or nil
M.save_game = function()
    local m = M.kept(M.savemgr_h)   -- (a handle: checked with the shim first)
    if not m then
        M.savemgr_h = nil
        local now = os.clock()
        if now - (M.savemgr_t or -99) < 5 then return nil end
        M.savemgr_t = now
        pcall(function()
            for _, o in pairs(FindAllOf("KSSaveDataManagerBP_C") or {}) do
                local fn = ""
                pcall(function() fn = o:GetFullName() end)
                if o:IsValid() and not fn:find("Default__", 1, true) then m = o; break end
            end
        end)
        M.savemgr_h = m and M.handle(m) or nil
    end
    local sg
    if m then pcall(function() sg = m.SaveGame end) end
    return sg
end
-- The objective of traveler id1 (1-8): its text, or nil and why -- "none" (the flags say
-- there is none) or "unreadable" (a table, a flag or the text couldn't be read: then the
-- caller asks the menu's panel; review 2026-11-16, a failure used to say "No objective").
M.objective_of = function(sg, id1)
    if not (sg and shim and shim.DtFind and shim.PeekFName and M.dt_addr) then return nil, "unreadable" end
    local lst = M.dt_addr("/Game/Mission/Database/NextPurposeDataList")
    local dat = M.dt_addr("/Game/Mission/Database/NextPurposeData")
    if not (lst and dat) then return nil, "unreadable" end
    local kc, kn = M.fname_of(tostring(id1))
    if not kc then return nil, "unreadable" end
    local row = shim.DtFind(lst, kc, kn)
    if not row then return nil, "none" end   -- (no list for this traveler)
    local data, n = shim.Peek(row, "ptr"), shim.Peek(row + 8, "i32")
    if n == 0 then return nil, "none" end
    if not data or data == 0 or type(n) ~= "number" or n < 0 or n > 1000 then return nil, "unreadable" end
    local function flag(i)   -- true / false, nil if it can't be read
        local ok, v = pcall(function() return sg:GetBitFlag(i) end)
        if ok then return v == true end
        return nil
    end
    for j = 0, n - 1 do
        local lc, ln = shim.PeekFName(data + j * 8)
        local r = lc and lc > 0 and shim.DtFind(dat, lc, ln)
        if r then
            local st, en = shim.Peek(r + 0x0C, "i32"), shim.Peek(r + 0x10, "i32")
            if type(st) ~= "number" or type(en) ~= "number" then return nil, "unreadable" end
            local fs, fe
            if st ~= 0 then fs = flag(st) end
            if en ~= 0 then fe = flag(en) end
            if (st ~= 0 and fs == nil) or (en ~= 0 and fe == nil) then return nil, "unreadable" end
            if (st == 0 or fs == true) and (en == 0 or fe == false) then   -- (the panel stops here)
                local tc, tn = shim.PeekFName(r + 0x18)
                local text = tc and tc > 0 and M.gametext(tc, tn)
                if text and text ~= "" then return text end
                return nil, "unreadable"
            end
        end
    end
    return nil, "none"
end
-- { {name, text}... } for the party's main members, leader first, and how many there are
M.party_objectives = function()
    local sg = M.save_game()
    if not sg then return nil end
    local ids = {}
    pcall(function()
        local a = sg.PlayerParty[M.PARTY_MAIN]
        for i = 1, 4 do
            local v = a[i]
            if type(v) == "number" and v >= 0 and v <= 7 then ids[#ids + 1] = v end
        end
    end)
    local out, unreadable = {}, false
    for _, id in ipairs(ids) do
        local ok, t, why = pcall(M.objective_of, sg, id + 1)
        if ok and t then out[#out + 1] = { name = M.TRAVELERS[id] or tostring(id + 1), text = t }
        elseif not ok or why ~= "none" then unreadable = true end
    end
    log(string.format("OBJECTIVE flags: party=%d with one=%d%s", #ids, #out, unreadable and ", some unreadable" or ""))
    return out, #ids, unreadable
end

-- Current objective reader. The menu's "current story" panel lives at
-- PartyCharacterList_C.NowPlayingStoryPanel.characterName (a KSTextBlock holding the
-- objective text, e.g. "Zur Bibliothek gehen."). queue=true appends after the category
-- on menu open; queue=false (the Q keybind) interrupts and reads on demand. The story
-- flags come first (M.party_objectives); the panel is the fallback.
M.read_objective = function(queue)
    local okf, objs, nparty, unreadable = pcall(M.party_objectives)
    if okf and objs and #objs > 0 then
        local parts = {}
        for _, o in ipairs(objs) do
            parts[#parts + 1] = (#objs > 1) and trf("%s: %s", o.name, o.text) or o.text
        end
        speak(trf("Objective: %s", table.concat(parts, " ")), not queue)
        return
    end
    -- The flags were read and no traveler has one (between chapters): no objective, as
    -- the menu shows it. The panel below keeps an old text across a load (2026-11-16:
    -- Slot 1 got the autosave's objective after "Return to Title"), so it is only asked
    -- when the flags can't be read.
    if okf and objs and (nparty or 0) > 0 and not unreadable then
        if not queue then speak(tr("No objective")) end
        return
    end
    local txt
    local function from(lst)
        for _, w in ipairs(lst or {}) do
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
                if txt then return w end
            end
        end
    end
    -- The FindAllOf search walks every object and stalled the game 75-86 ms each time the
    -- menu opened (known issue 2026-11-14). The list that had the text is kept, so on menu
    -- open the search runs once per session; Q searches again while none is known.
    local kept = M.kept(M.obj_list_h)   -- (a handle: the list may be gone after a load)
    if kept then from({ kept }) end
    if not txt and (not queue or not M.obj_searched) then
        M.obj_searched = true
        local lst
        pcall(function() lst = FindAllOf("PartyCharacterList_C") end)
        local w = from(lst)
        if w then
            M.obj_list_h = M.handle(w)
            log(string.format("OBJECTIVE from party list %X (%d lists)", M.addr_of(w) or 0, #(lst or {})))
        end
    end
    if txt then speak(trf("Objective: %s", txt), not queue)
    elseif not queue then speak(tr("No objective")) end
end
-- (not in battle: there Q is the game's "lower the boost" key -- it said "No objective")
-- Nor in a menu screen of its own: Q is the game's LB there too (the journal's switch to
-- the main story said "Kein Ziel" over it, 2026-11-18). In the field the active stack is
-- empty (nil), in the menu's category list it is MainMenuWidget_C, in a talk the balloons.
M.Q_OBJECTIVE_SCREENS = { MainMenuWidget_C = true, BalloonManagerBP_C = true }
M.q_objective_ok = function()
    if M.battle_now then return false end
    local _, acls = M.get_active_screen()
    return acls == nil or M.Q_OBJECTIVE_SCREENS[acls] == true
end
pcall(RegisterKeyBind, Key.Q, function() if M.q_objective_ok() then M.read_objective(false) end end)

-- Main (pause) menu category-list reader. The Escape menu's left list (Weltkarte /
-- Journal / Inventar / Ausruestung / ... / Status / Verschiedenes) lives in
-- MainMenuWidget_C.MainMenuList (a MainMenuList_C): CursorPosition is the selected
-- category; MainMenuPanel is a UMG VerticalBox of MainMenuItemPanel_C buttons, each with
-- a MenuText text block carrying the localized label. So: GetChildAt(cursor).MenuText.
-- Announce the selected category on open + each move (interrupt behaviour via say_item).
do
    local mm_idx, sub_idx, mm_away
    -- back from a sub-screen that left the list as it was (the world map): say the
    -- selected category again, without the objective
    M.mainmenu_reannounce = function() mm_idx = nil; sub_idx = nil; M.mm_no_objective = true end
    M.poll_mainmenu = function()
        local mw
        for i = 1, #scene_widgets do
            local e = scene_widgets[i]
            if e[2] == "MainMenuWidget_C" and M.sw_ok(e) then
                local vis = false; pcall(function() vis = e[1]:IsValid() and e[1]:IsVisible() end)
                if vis then mw = e[1] end
            end
        end
        -- (the "no objective" flag goes with the menu: it outlived a "Return to Title"
        -- from the submenu and skipped the objective after the next load -- review)
        if not mw then mm_idx = nil; sub_idx = nil; mm_away = nil; M.mm_no_objective = nil; return end
        -- Another screen on top (an item list, the options, a dialog): nothing to say here.
        -- Back on the menu, its selected entry again, without the objective. Not while the
        -- world map is open: a dialog over it (fast travel? "No") is no way back to the
        -- list, and "World Map" then sounded as if the map had closed; the map's own reader
        -- says the entry again when it closes (M.mainmenu_reannounce).
        local _, acls = M.get_active_screen()
        if acls and acls ~= "MainMenuWidget_C" then
            if not mm_away then log("MAINMENU under " .. acls) end
            mm_away = acls
            return
        end
        if mm_away and acls == "MainMenuWidget_C" then
            log("MAINMENU back from " .. tostring(mm_away))
            mm_away = nil
            if not (M.WM and M.WM.open) then
                mm_idx, sub_idx = nil, nil
                M.mm_no_objective = true
            end
        end
        -- The "Verschiedenes" submenu (2026-11-16: it was silent): MainMenuEtcWidget_C
        -- (object dump: CursorSelect @0x260 indexes SubItemList @0x250, MainMenuSubItemPanel_C
        -- items with MenuText and IsUnEnable: Einstellungen, Tutorial, Zum Titelbildschirm,
        -- Spiel beenden). Open while MainMenuWidget_C.MainState is 13 (0 = the list, seen in
        -- game); the widget itself stays Visible after it closes, so that can't tell.
        local ms, etc
        pcall(function() ms = mw.MainState end)
        if ms == 13 then pcall(function() etc = mw.MainMenuEtcWidget end) end
        if etc then
            local ci; pcall(function() ci = etc.CursorSelect end)
            if type(ci) ~= "number" or ci == sub_idx then return end
            local opening = (sub_idx == nil)
            sub_idx = ci
            local items, dis = {}, {}
            pcall(function()
                etc.SubItemList:ForEach(function(_, v)
                    local it, s, un = v:get(), nil, false
                    pcall(function() s = it.MenuText:GetText():ToString() end)
                    pcall(function() un = it.IsUnEnable and true or false end)
                    items[#items + 1] = s or ""
                    dis[#items] = un
                end)
            end)
            if opening then log(string.format("MAINMENU sub items=[%s] cursor=%d", table.concat(items, "|"), ci)) end
            local label = items[ci + 1]
            if not label or label == "" then label = trf("Item %s", tostring(ci + 1)) end
            M.say_item(dis[ci + 1] and trf("%s, disabled", label) or label)
            return
        end
        if sub_idx ~= nil then   -- back from the submenu: the category again, no objective
            -- ... but only on the list (MainState 0): any other state is a screen of the
            -- menu opening (Settings from the submenu left 13 a moment before the active
            -- stack had the options, and "Verschiedenes" was said in passing)
            if ms ~= nil and ms ~= 0 then return end
            sub_idx = nil
            mm_idx = nil
            M.mm_no_objective = true
        end
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
            say = un and tr("Unavailable") or trf("Category %s", tostring(ci))
        else
            say = un and trf("%s, disabled", label) or label
        end
        M.say_item(say)
        -- On open, also read the current objective (queued after the category). Q re-reads
        -- it on demand. (Both requested.)
        if opening and M.read_objective and not M.mm_no_objective then M.read_objective(true) end
        M.mm_no_objective = nil
    end
end

-- STATUS SCREEN (user 2026-11-18: it said nothing). StatusMenuWidget_C on the active
-- stack shows one traveler; Up/Down step through the party (OnCursorUp/DownRepeat ->
-- Up/DownCategory: SelectedCharacterIndex over the tabs, CategoryDisplayedNum of them;
-- then UpdateCategory, in the same frame). What it fills (bytecode): BaseStatus --
-- TitleText the name, LvNum the level, NextExpText/NextExpNum the EXP to the next one;
-- Equipment -- Job_10/Job_10_Name the first job, Job_20/Job_20_Name the second (collapsed
-- without one), KSTextBlock_2/_3/_4 the job points; Params -- ListItemParamWidget_63
-- .Param_01..param_10 (ParamName; ValueBefore = base plus equipment: HP, SP, ...);
-- Special_Action -- ActionCommand/ActionText the path action and ActionFieldText what it
-- does, SpecificText/SpecificActionName the talent and SpecificActionText. The designer's
-- dummies ("Name", "999", full-width digits) are skipped. Said when the traveler changes:
-- name, which of how many and level at once; the rest queued.
M.STATUS_DUMMY = { ["Name"] = true, ["999"] = true, ["99999"] = true, ["0000"] = true }
M.status_text = function(w, name)
    local tb
    pcall(function() tb = w[name] end)
    if not tb then return nil end
    local v = M.wvis(tb)
    if v == 1 or v == 2 then return nil end
    local s = M.wtext(tb)
    if not s or M.placeholder(s) or M.STATUS_DUMMY[s] or s:find("^\239\188[\144-\153]") then return nil end
    return s
end
-- -> the line said at once and the rest, or nil (no name yet)
M.status_lines = function(w)
    local function t(n) return M.status_text(w, n) end
    local name = t("TitleText")
    if not name then return nil end
    local idx, num
    pcall(function() idx, num = w.SelectedCharacterIndex, w.CategoryDisplayedNum end)
    local head = name
    if type(idx) == "number" and type(num) == "number" and num > 1 then
        head = head .. ", " .. trf("%d of %d", idx + 1, num)
    end
    local lv = t("LvNum")
    if lv then head = head .. ", " .. trf("level %s", lv) end
    local rest = {}
    local function add(s) if s and s ~= "" then rest[#rest + 1] = s end end
    local function pair(label, value)
        if not value then return nil end
        return label and (label .. ": " .. value) or value
    end
    add(pair(t("Job_10"), t("Job_10_Name")))
    add(pair(t("Job_20"), t("Job_20_Name")))
    -- the weapons worn: a picture each, no text (in game 2026-11-18 "Waffe" was left
    -- out). Bytecode (Equipment): for each weapon slot in use (sword, lance, dagger, axe,
    -- bow, rod) the next of Job_Icon3..8 shows eqp_part_icon_<kind>, the texture
    -- UiTX_Common_ListIcon_<Sword|Spear|Dagger|Ax|Arrow|Cane>; "weapon" is the label.
    local wl, raw = {}, {}
    for k = 3, 8 do
        local ic
        pcall(function() ic = w["Job_Icon" .. k] end)
        local v = ic and M.wvis(ic)
        if v == 0 or v == 3 or v == 4 then
            local tn
            pcall(function() tn = ic.Brush.ResourceObject:GetFName():ToString() end)
            raw[#raw + 1] = tostring(tn)
            local key = tn and tn:match("ListIcon_(%a+)$")
            key = key and key:lower()
            if key and M.WEAK_DE and M.WEAK_DE[key] then wl[#wl + 1] = tr(M.WEAK_DE[key]) end
        end
    end
    M.status_icons = table.concat(raw, ",")
    if #wl > 0 then add((t("weapon") or tr("Weapon")) .. ": " .. table.concat(wl, ", ")) end
    local jp = t("KSTextBlock_3")
    if jp then
        -- "LBP erhalten: 398 LBP"
        local a, b = t("KSTextBlock_2"), t("KSTextBlock_4")
        local lab = (a and a ~= b) and (a:match(":%s*$") and (a .. " ") or (a .. ": ")) or ""
        add(lab .. jp .. (b and (" " .. b) or ""))
    end
    local stats, pl = {}, nil
    pcall(function() pl = w.ListItemParamWidget_63 end)
    for n = 1, pl and 10 or 0 do
        local p, val
        pcall(function() p = pl[(n == 10) and "param_10" or string.format("Param_%02d", n)] end)
        if p then pcall(function() val = p.ValueBefore end) end
        local pn = p and M.wtext(p.ParamName)
        if type(val) == "number" and pn and not M.placeholder(pn) and not M.STATUS_DUMMY[pn] then
            stats[#stats + 1] = pn .. " " .. string.format("%d", val)
        end
    end
    if #stats > 0 then add(table.concat(stats, ", ")) end
    add(pair(t("NextExpText"), t("NextExpNum")))
    local act = pair(t("ActionCommand"), t("ActionText"))
    if act then
        local d = t("ActionFieldText")
        add(d and (act .. ". " .. d) or act)
    end
    local tal = pair(t("SpecificText"), t("SpecificActionName"))
    if tal then
        local d = t("SpecificActionText")
        add(d and (tal .. ". " .. d) or tal)
    end
    return head, (#rest > 0) and M.join_text(rest) or nil
end
do
    local S = {}
    M.poll_status = function()
        local w, cls = M.get_active_screen()
        if cls ~= "StatusMenuWidget_C" or not w then S.sig, S.t0 = nil, nil; return end
        local idx
        pcall(function() idx = w.SelectedCharacterIndex end)
        local sig = tostring(idx) .. "|" .. tostring(M.status_text(w, "TitleText"))
        if sig == S.sig then return end
        local now = os.clock()
        if S.sig == nil then   -- just opened: a moment for the screen to fill its texts
            S.t0 = S.t0 or now
            if now - S.t0 < 0.25 then return end
        end
        local okl, head, rest = pcall(M.status_lines, w)
        if not (okl and head) then return end
        S.sig = sig
        log(string.format("STATUS %s: %s | %s (icons %s)", tostring(idx), head, tostring(rest), tostring(M.status_icons)))
        speak(head, true)
        if rest then speak(rest, false) end
    end
end

-- JOURNAL (user 2026-11-18: it said nothing). MainMenuMissionRecord_C on the active stack.
-- Status by value (EMAINMENU_SEQ_MISSIONRECORD, from the enum's names table; the bytecode
-- agrees): 2 the travelers' stories, 3 a story's list, 4 the regions' side stories, 5
-- their list, 6 the cursor moving, 7 switching stories / side stories, 8 "watch again?".
-- Left/Right move SelectPos over GaugeList (MainMenuMissionRecordGaugeMain_C / ...Sub_C:
-- GaugeText the traveler's or region's name, MaxGaugePercent the progress 0..1,
-- IsUnEnable not open yet); LB/RB switch the two (IsOpenMainMission). The caption says
-- which (TmpHeaderUI.CaptionText: eMAINMENU_CAPTION_MISSION_MAIN / _SUB), the footer what
-- to do (TmpFooterUI.HelpText). Decide opens the list, a ListWidget_C pushed active: the
-- list reader says its rows (M.ml_screen "journal") and the text beside it as the help
-- line (M.journal_text).
M.journal_gauge = function(w)
    local pos
    pcall(function() pos = w.SelectPos end)
    if type(pos) ~= "number" then return nil end
    local gs = {}
    pcall(function() w.GaugeList:ForEach(function(_, e) gs[#gs + 1] = e:get() end) end)
    local g = gs[pos + 1]
    if not g then return nil end
    local name = M.wtext(g.GaugeText)
    if not name then pcall(function() name = M.wtext(g.BaseTextBlock) end) end
    if not name or M.placeholder(name) then return nil end
    if name:match("^[%?%s]+$") then name = tr("Unknown") end
    local un, pct = false, nil
    pcall(function() un = g.IsUnEnable and true or false end)
    pcall(function() pct = g.MaxGaugePercent end)
    local s = name
    if un then s = trf("%s, not available yet", s)
    elseif type(pct) == "number" then s = s .. ", " .. trf("%d percent", math.floor(pct * 100 + 0.5)) end
    if #gs > 1 then s = s .. ", " .. trf("%d of %d", pos + 1, #gs) end
    return s, un
end
-- A row of the journal's list: col1 the title, col2 a story's chapter ("" for a side
-- story), and a marker glyph in the last column (bytecode: GetAreaListItemData,
-- CreateMainMissionListItem): "1" a side story finished (MissionState >= 2), "0" a new
-- entry. Said "Titel, Kapitel 2, neu" -- not "Titel, 1".
-- The journal's rows are ListItemWidget_Col1_2_C, whose SetItemData puts those two
-- values elsewhere (in game 2026-11-18: no Col2/Col3, only the title was said): the
-- chapter into ProgressText ("I-17", chapter I, entry 17; ProgressRoot shown), the
-- marker as a picture: NewIcon (the blue "!", "0") or Compicon (the tick, "1").
-- prog/new/done: what M.journal_marks read from such a row.
M.ROMAN = { I = 1, II = 2, III = 3, IV = 4, V = 5, VI = 6 }
M.journal_prog = function(p)
    if not p or M.placeholder(p) then return nil end
    local r, n = p:match("^%s*([IVX]+)%s*[^%w%s]+%s*(%d+)%s*$")
    if r and M.ROMAN[r] then return trf("chapter %d, entry %s", M.ROMAN[r], n) end
    return p
end
M.journal_row = function(c1, c2, c3, prog, new, done)
    local mark = (c3 == "1" or c3 == "0") and c3 or ((c2 == "1" or c2 == "0") and c2) or nil
    if done then mark = "1" elseif new and not mark then mark = "0" end
    local say = c1
    if c2 and c2 ~= mark and not M.placeholder(c2) then say = say .. ", " .. c2 end
    local pr = M.journal_prog(prog)
    if pr then say = say .. ", " .. pr end
    if mark == "1" then say = trf("%s, finished", say)
    elseif mark == "0" then say = trf("%s, new", say) end
    return say
end
-- -> the row's ProgressText (when shown), whether its NewIcon and its Compicon show
M.journal_marks = function(row)
    local function shown(x)
        if not x then return false end
        local v = M.wvis(x)
        return v == 0 or v == 3 or v == 4
    end
    local pr, pt, ni, ci
    pcall(function() pr = row.ProgressRoot end)
    pcall(function() pt = row.ProgressText end)
    pcall(function() ni = row.NewIcon end)
    pcall(function() ci = row.Compicon end)
    local prog = (pt and (not pr or shown(pr)) and shown(pt)) and M.wtext(pt) or nil
    return prog, shown(ni), shown(ci)
end
-- The list's title: "Tagebuch von Ophilia", "Aufzeichnungen in Küstenland:\nRippeltiden"
M.journal_list_title = function(w)
    local t
    pcall(function() t = M.wtext(w.TitleText) end)
    if not t or M.placeholder(t) then return nil end
    return (t:gsub("%s*\n%s*", " "))
end
-- The keys a menu's footer offers, as the game shows them (a MenuFooter_C's
-- MenuGuideItem00..07: ButtonGuideText_00 the key caps, GuideText_00 the action; speak()
-- says a key cap as its letter): "Q O: Wechseln, E: Auswählen" or nil. The journal's
-- Left/Right only go through the travelers; switching to the side stories is LB/RB
-- (Q / O in DefaultInput.ini), which only the footer tells (user 2026-11-18).
M.footer_guides = function(f)
    if not f then return nil end
    local out = {}
    for k = 0, 7 do
        local it
        pcall(function() it = f["MenuGuideItem0" .. k] end)
        if not it then break end
        local iv = M.wvis(it)
        if iv == 0 or iv == 3 or iv == 4 then
            local t, g = M.wtext(it.GuideText_00), M.wtext(it.ButtonGuideText_00)
            if t and g and not M.placeholder(t) and not M.placeholder(g) then out[#out + 1] = g .. ": " .. t end
        end
    end
    return #out > 0 and table.concat(out, ", ") or nil
end
-- The text beside the journal's list (ListItemTextArea_C): who asked (side stories), the
-- story so far, the result; the parts its view mode hides are left out.
M.journal_text = function(owner)
    local ta
    pcall(function() ta = owner.ListItemTextArea end)
    if not ta then return nil end
    local function shown(part)
        local a
        pcall(function() a = ta[part] end)
        if not a then return true end
        local v = M.wvis(a)
        return v ~= 1 and v ~= 2
    end
    local function txt(f)
        local s
        pcall(function() s = M.wtext(ta[f]) end)
        if s and not M.placeholder(s) then return s end
        return nil
    end
    local parts = {}
    if shown("OrdererArea") then
        local on, ol = txt("OrdererName"), txt("OrdererText")
        if on then parts[#parts + 1] = ol and (ol .. ": " .. on) or on end
    end
    if shown("StoryArea") then parts[#parts + 1] = txt("StoryText") end
    if shown("ResultArea") then parts[#parts + 1] = txt("ResultText") end
    local out = {}
    for _, p in ipairs(parts) do if p then out[#out + 1] = p end end
    return #out > 0 and M.join_text(out) or nil
end
do
    local J = {}
    M.poll_journal = function()
        local w, cls = M.get_active_screen()
        if cls ~= "MainMenuMissionRecord_C" or not w then
            -- its list or the "watch again?" dialog on top: the gauge again when back
            if cls == "ListWidget_C" or cls == "UICommonDialogBP_C" then
                if J.sig then J.away = true end
            else
                J.sig, J.mode, J.t0, J.away = nil, nil, nil, nil
                M.journal_title_said = nil
            end
            return
        end
        if J.away then J.away, J.sig = nil, nil end
        M.journal_title_said = nil   -- (a list opened again says its title again)
        local st, mainm
        pcall(function() st, mainm = w.Status, w.IsOpenMainMission end)
        if st ~= 2 and st ~= 4 and st ~= 6 then return end
        local now = os.clock()
        if J.mode == nil then   -- just opened: a moment for the gauges to fill
            J.t0 = J.t0 or now
            if now - J.t0 < 0.3 then return end
        end
        local okg, line, un = pcall(M.journal_gauge, w)
        if not (okg and line) then return end
        -- the cursor on its way (6) over travelers or regions not open yet: only where it
        -- stops is said (in game: "Unbekannt, noch nicht verfügbar" for each one passed)
        if st == 6 and un then return end
        local mode = mainm and "main" or "sub"
        local sig = mode .. "|" .. line
        if sig == J.sig then return end
        local first = J.mode ~= mode
        J.sig, J.mode, J.t0 = sig, mode, nil
        log(string.format("JOURNAL status %s %s: %s", tostring(st), mode, line))
        if first then
            -- which of the two, then (queued) what to do there and the footer's keys
            local cap, help, keys
            pcall(function() cap = M.wtext(w.TmpHeaderUI.CaptionText) end)
            pcall(function() help = M.wtext(w.TmpFooterUI.HelpText) end)
            pcall(function() keys = M.footer_guides(w.TmpFooterUI) end)
            if cap and M.placeholder(cap) then cap = nil end
            if help and M.placeholder(help) then help = nil end
            speak(cap and (cap .. ". " .. line) or line, true)
            local tail = {}
            if help then tail[#tail + 1] = help end
            if keys then tail[#tail + 1] = keys end
            if #tail > 0 then speak(M.join_text(tail), false) end
        else
            speak(line, true)
        end
    end
end

-- GAME OVER (user report 2026-11-14: after the party fell, the menu was silent).
-- UIGameOver_C, on the active stack (object dump): NowCursorPos @0x2D0 indexes CursorList
-- @0x2C0, the GameoverItemWidget_C items Save @0x288 ("Weiter ab letztem Speicherpunkt")
-- and Title @0x2A8 ("Zum Titelbildschirm"), each showing its label in Text_Content;
-- BackToTitleOnly @0x2D4. "Spiel vorbei" itself is a picture.
do
    local go = { idx = nil }
    M.poll_gameover = function()
        local w, cls = M.get_active_screen()
        if cls ~= "UIGameOver_C" then
            -- left with "Weiter ab letztem Speicherpunkt" (the first item): no load with a
            -- fade but a jump to the save point (tried 2026-11-16) -- the object count is
            -- said again right away (see M.load_pending in poll_dialog). The area is not:
            -- the game shows no banner there, and the banner may still hold the text of
            -- where the battle was (marked said when the screen opened)
            -- It is also a teleport (the bump watch saw it once, not always): the minimap's
            -- icons come back with new actors ("Neue Markierung: Nebengeschichte" for Kit,
            -- who was there all along -- 2026-11-16), and the navigator's list is stale.
            if go.idx == 0 then M.load_resay = true; M.jump_t = os.clock() end
            go.idx = nil
            return
        end
        local ci
        pcall(function() ci = w.NowCursorPos end)
        if type(ci) ~= "number" or ci == go.idx then return end
        local opening = (go.idx == nil)
        go.idx = ci
        local items = {}
        pcall(function()
            w.CursorList:ForEach(function(_, v)
                local it = v:get()
                local s
                pcall(function() s = it.Text_Content:GetText():ToString() end)
                items[#items + 1] = s or ""
            end)
        end)
        if #items == 0 then   -- the two items by name
            for _, f in ipairs({ "Save", "Title" }) do
                local s
                pcall(function() s = w[f].Text_Content:GetText():ToString() end)
                if s and s ~= "" then items[#items + 1] = s end
            end
        end
        local label = items[ci + 1]
        if not label or label == "" then label = trf("Item %s", tostring(ci + 1)) end
        if opening then
            log(string.format("GAMEOVER items=[%s] cursor=%d", table.concat(items, "|"), ci))
            -- the area banner's text counts as said (poll_area_name, mark_only)
            pcall(M.poll_area_name, true)
            speak(tr("Game over"), true)
            M.await_first_item = true
        end
        M.say_item(label)
    end
end

-- SHOP (user report 2026-11-14: in a shop the menu wasn't recognized -- the radar kept
-- playing -- nor read). ShopMenuWidget_C, on the active stack (object dump): the top
-- menu TopMenu_00..09 (MainMenuItemPanel_C, MenuText: "Kaufen", "Verkaufen",
-- "Verlassen") with its cursor TopMenuSelectId; the title PartsMenuHeader.CaptionText
-- ("Händler"); the money PartsPartyList.PlayerStatusPanel.TextHaveMoney/TextMoneyUnit;
-- ProductList, a ListWidget_C (the goods: the list reader says them, M.ml_screen
-- "shop"); SelectItemNum, a SelectItemNumWidget_C (itemNum, ItemPrice; texts Number,
-- Price, MoneyUnit; labels PurchaseQuantity "Anzahl:", PurchasePrice "Gesamtkosten:") for
-- how many to buy or sell: Collapsed (1) until a row is chosen, Visible (0) while it asks
-- (log 2026-11-14). Inns use the same screen.
-- The top menu shows only the shop's commands: TopShopCommands (TArray<uint8> @0x318) lists
-- them, TopMenuSelectId indexes that list. A command is what ShopMode becomes when it runs
-- (ESHOPMENU_MODE); its text is GameText eSHOP_CONTENT_xx, panel TopMenu_xx, in another
-- order: sh.CONTENT. Found 2026-11-14 from what each command opened in a tavern (3
-- EquipmentMenuWidget_C, 4 ListCharacterWidget_C, 5 BarMenuStorySelect_C, 6 the
-- reputation dialog) and a screenshot of it ("Gruppe wechseln, Ausrüstung, Geschichte
-- lauschen, Ruf wiederherstellen, Weiterreisen" for [4 3 5 6 9]); the shop [0 1 7] and the
-- inn [2 8] end in "Verlassen" (04 "leave the shop", 05 "leave the inn" in Japanese).
-- Taking TopMenu_<cursor> read "Kaufen" for an inn's "Bleiben", taking the command as the
-- text's number read "Verlassen" twice in the tavern.
-- SHOP NAMES for the navigator (user request 2026-11-14: say what a shop is before
-- talking to it): ShopTriggerBP_C.ShopLabel @0x370 ("Plain_L_A_SHOP_00") is a row of
-- /Game/Shop/Database/ShopInfo (ShopInfoData: ShopName FName @0 = a GameText label,
-- eSHOP_NAME_TEMP_03 "Gasthaus"; ShopType u8 @8), the title the shop menu shows.
M.shop_name = function(actor)
    if not (shim and shim.DtFind and shim.PeekFName) then return nil end
    local a
    pcall(function() a = actor:GetAddress() end)
    if not a or a == 0 then return nil end
    local c, n = shim.PeekFName(a + 0x370)
    local dt = M.dt_addr("/Game/Shop/Database/ShopInfo")
    local row = dt and c and c > 0 and shim.DtFind(dt, c, n)
    if not row or row == 0 then
        log(string.format("SHOPNAME %s: no row (table %s)", M.fname_str(c, n), tostring(dt)))
        return nil
    end
    local nc, nn = shim.PeekFName(row)
    local s = M.gametext(nc, nn)
    -- the generic names eSHOP_NAME_TEMP_00..04 (Plattner, Händler, Krämer, Gasthaus,
    -- Wirtshaus) follow ShopType 0..4, except that Atlasdam's tavern counter
    -- (Plain_L_A_SHOP_Pu, type 4) says "Gasthaus" -- the tavern's own menu is "Wirtshaus":
    -- a generic name goes by the type
    local ty = shim.Peek(row + 8, "u8")
    local raw = M.fname_str(nc, nn)
    if raw:match("^eSHOP_NAME_TEMP_%d+$") and type(ty) == "number" and ty <= 4 then
        s = M.gt_label(string.format("eSHOP_NAME_TEMP_%02d", ty)) or s
    end
    log(string.format("SHOPNAME %s -> %s, type %s = %s", M.fname_str(c, n), raw, tostring(ty), tostring(s)))
    return s
end
-- a shop trigger's ShopType from the ShopInfo row (0 Plattner, 1 Händler, 2 Krämer,
-- 3 Gasthaus, 4 Wirtshaus), or nil
M.shop_type = function(actor)
    if not (shim and shim.DtFind and shim.PeekFName and shim.Peek) then return nil end
    local a
    pcall(function() a = actor:GetAddress() end)
    if not a or a == 0 then return nil end
    local c, n = shim.PeekFName(a + 0x370)
    local dt = M.dt_addr("/Game/Shop/Database/ShopInfo")
    local row = dt and c and c > 0 and shim.DtFind(dt, c, n)
    if not row or row == 0 then return nil end
    local ty = shim.Peek(row + 8, "u8")
    return type(ty) == "number" and ty or nil
end
do
    local sh = {}
    -- command (ESHOPMENU_MODE) -> eSHOP_CONTENT_xx: 0 Kaufen, 1 Verkaufen, 2 Bleiben, 3
    -- Ausrüstung, 4 Gruppe wechseln, 5 Geschichte lauschen, 6 Ruf wiederherstellen, 7
    -- Verlassen (shop), 8 Verlassen (inn), 9 Weiterreisen
    sh.CONTENT = { [0] = 0, [1] = 1, [2] = 2, [3] = 3, [4] = 6, [5] = 7, [6] = 8, [7] = 4, [8] = 5, [9] = 9 }
    -- the shop's top menu: { { cmd, text, off }, ... } in menu order (nil: not readable)
    sh.commands = function(w)
        if not (shim and shim.Peek) then return nil end
        local wa
        pcall(function() wa = w:GetAddress() end)
        if not wa or wa == 0 then return nil end
        local arr, cnt = shim.Peek(wa + 0x318, "ptr"), shim.Peek(wa + 0x320, "i32")
        if not arr or arr == 0 or type(cnt) ~= "number" or cnt <= 0 or cnt > 10 then return nil end
        local out = {}
        for i = 0, cnt - 1 do
            local k = shim.Peek(arr + i, "u8")
            local c = type(k) == "number" and sh.CONTENT[k]
            if not c then return nil end
            local p, t, off
            pcall(function() p = w[string.format("TopMenu_%02d", c)] end)
            if p then
                t = M.wtext(p.MenuText)
                pcall(function() off = p.IsUnEnable end)
            end
            if not t or M.placeholder(t) then t = M.gt_label(string.format("eSHOP_CONTENT_%02d", c)) end
            out[#out + 1] = { cmd = k, text = t, off = off == true }
        end
        return out
    end
    -- the menu's own panel list, by name (logged on open: is it the shown order?)
    sh.panels = function(w)
        local names = {}
        pcall(function()
            w.TopMenuItemList:ForEach(function(_, e)
                local nm = "?"
                pcall(function() nm = e:get():GetFName():ToString() end)
                names[#names + 1] = nm
            end)
        end)
        return table.concat(names, " ")
    end
    M.shop_money = function(w)
        local m, u
        pcall(function()
            local p = w.PartsPartyList.PlayerStatusPanel
            m, u = M.wtext(p.TextHaveMoney), M.wtext(p.TextMoneyUnit)
        end)
        if m and not M.placeholder(m) then
            return m .. ((u and not M.placeholder(u)) and (" " .. u) or "")
        end
        return nil
    end
    M.poll_shop = function()
        local w, cls = M.get_active_screen()
        if cls == "ShopMenuWidget_C" then
            sh.w = w
        elseif sh.open and (cls == "ListWidget_C" or cls == "SelectItemNumWidget_C") and sh.w then
            -- its goods list or amount picker focused on its own: still the shop
            local okv = false
            pcall(function() okv = sh.w:IsValid() end)
            if not okv then sh.w = nil; return end
            w = sh.w
        else
            -- (a dialog over the shop, "Kaufen?": keep the state, it comes back)
            if cls ~= "UICommonDialogBP_C" then
                sh.top, sh.num, sh.open, sh.st, sh.w, sh.cmds = nil, nil, nil, nil, nil, nil
                sh.qe, M.shop_qe_on = nil, nil
            end
            return
        end
        if not sh.open then
            sh.open = true
            local title
            pcall(function() title = M.wtext(w.PartsMenuHeader.CaptionText) end)
            local money = M.shop_money(w)
            local mode, label
            pcall(function() mode = w.ShopMode end)
            pcall(function() label = w.ShopLabel:ToString() end)
            -- the header is shared: back from "Geschichte lauschen" it still said "Abenteuer
            -- in Atlasdamm" (user log 2026-11-14), so a shop keeps the title it opened with
            sh.titles = sh.titles or {}
            if label and sh.titles[label] then title = sh.titles[label]
            elseif label and title and not M.placeholder(title) then sh.titles[label] = title end
            local okc, cmds = pcall(sh.commands, w)
            sh.cmds = okc and cmds or nil
            local ct = {}
            for _, c in ipairs(sh.cmds or {}) do
                ct[#ct + 1] = string.format("%d=%s%s", c.cmd, tostring(c.text), c.off and "(off)" or "")
            end
            local okp, panels = pcall(sh.panels, w)
            log(string.format("SHOP open: %s mode=%s label=%s money=%s commands=[%s] panels=[%s]", tostring(title),
                tostring(mode), tostring(label), tostring(money), table.concat(ct, " "), tostring(okp and panels)))
            speak(((title and not M.placeholder(title)) and title or tr("Shop")) .. (money and (", " .. money) or ""), true)
            M.await_first_item = true
        end
        -- what the shop shows now (logged on change, to tell its states apart)
        local mode, act, pv = nil, false, nil
        local sn, gst
        pcall(function() mode = w.ShopMode end)
        pcall(function() act = w.ProductList.ActiveFlag end)
        pcall(function() sn = w.SelectItemNum end)
        pcall(function() gst = w:GetCurrentState() end)   -- ESHOPMENU_STATE (M.shop_quick_equip)
        if sn then pv = M.wvis(sn) end
        -- (the party panels' cursor icons too: the other sign of the quick equip, logged)
        local icons = ""
        pcall(function()
            local pl = w.PartsPartyList
            for k = 0, 3 do
                local cv
                pcall(function() cv = M.wvis(pl[string.format("PartyCharacter_%02d", k)].CursorIcon) end)
                icons = icons .. (cv and tostring(cv) or "-")
            end
        end)
        local st = string.format("mode=%s list=%s picker=%s state=%s icons=%s", tostring(mode), tostring(act),
            tostring(pv), tostring(gst), icons)
        if st ~= sh.st then sh.st = st; log("SHOP state " .. st) end
        -- choosing who gets what was just bought ("... sofort ausrüsten?" -> Ja)
        if gst == M.SHOP_QUICK_EQUIP then
            M.shop_qe_on = true
            local okq, err = pcall(M.shop_quick_equip, w, sh)
            if not okq then log("SHOP quick equip error: " .. tostring(err)) end
            return
        end
        if sh.qe and M.ml then M.ml.said, M.ml.help_said = nil, nil end   -- back at the goods: say the row again
        sh.qe, M.shop_qe_on = nil, nil
        -- how many: the amount picker while it shows ("Anzahl: 1, Gesamtkosten: 50
        -- Blätter", then "2, 100 Blätter" per step). The goods list stays active under it.
        if pv == 0 or pv == 3 or pv == 4 then
            local n, num, price, lq, lp
            pcall(function() n = sn.itemNum end)
            pcall(function() num, price = M.wtext(sn.Number), M.wtext(sn.Price) end)
            pcall(function() lq, lp = M.wtext(sn.PurchaseQuantity), M.wtext(sn.PurchasePrice) end)
            if not num or M.placeholder(num) then num = (type(n) == "number") and tostring(n) or nil end
            if price and M.placeholder(price) then price = nil end
            local key = tostring(num) .. "|" .. tostring(price)
            if num and key ~= sh.num then
                local first = sh.num == nil
                sh.num = key
                local cost = price and (price .. " " .. M.MONEY_SIGN) or nil
                local s
                if first then
                    log(string.format("SHOP picker: %s %s / %s %s (itemNum %s)", tostring(lq), tostring(num), tostring(lp),
                        tostring(price), tostring(n)))
                    if not lq or M.placeholder(lq) then lq = M.gt_label("eSHOP_BUY_NUMBER") or "Quantity:" end
                    if not lp or M.placeholder(lp) then lp = M.gt_label("eSHOP_BUY_TOTAL_PRICE") or "Total:" end
                    s = lq .. " " .. num .. (cost and (", " .. lp .. " " .. cost) or "")
                else
                    s = num .. (cost and (", " .. cost) or "")
                end
                M.say_item(s)
            end
            return
        end
        sh.num = nil
        -- the goods list in use: the list reader speaks
        if act then sh.top = nil; return end
        local ci
        pcall(function() ci = w.TopMenuSelectId end)
        if type(ci) ~= "number" or ci == sh.top then return end
        sh.top = ci
        local c = sh.cmds and sh.cmds[ci + 1]
        local t = c and c.text
        if not c then
            -- the command list unreadable: the panel by the cursor (right for shops
            -- that show every command from the first on)
            pcall(function() t = M.wtext(w[string.format("TopMenu_%02d", ci)].MenuText) end)
        end
        t = (t and not M.placeholder(t)) and t or trf("Item %s", ci + 1)
        if c and c.off then t = trf("%s, unavailable", t) end
        M.say_item(t)
    end
end

-- THE TAVERN'S OWN SCREENS (user log 2026-11-14: both stayed silent). They open from the
-- keeper's menu inside the talk event; the fast polls read them (game thread, property
-- reads only), never in a fade.
-- PARTY CHANGE, "Gruppe wechseln" (ListCharacterWidget_C): the party in
-- PartyCharacterList.PartyCharacter_00..03, the travelers waiting in the tavern in
-- CharacterPanel_01..08 -- all PartyCharacterPanel_C, the panels M.ml_member reads
-- ("Cyrus, level 5, HP 259 of 284, SP 56 of 64"). IsSelectMainType: the cursor is in the
-- party, else among the waiting ones; MainSelectCursorIndex / SubSelectCursorIndex;
-- the member picked to swap: DeclsionMainCursorIndex / DeclsionSubCursorIndex.
M.TAV = {}
-- Both read their texts only when the cursor moved, after a question, or once a second
-- (texts filled late): a full read of the story entry took ~90 ms on the game thread
-- (2026-11-15), each tick would stall the game.
M.tav_due = function(T, quick)
    local now = os.clock()
    if quick == T.quick and T.said and now - (T.read_t or 0) < 1.0 then return false end
    T.quick, T.read_t = quick, now
    return true
end
M.poll_party_change = function(w)
    local T = M.TAV
    local main = M.fc_get(w, "IsSelectMainType")
    local mi, si = M.fc_get(w, "MainSelectCursorIndex"), M.fc_get(w, "SubSelectCursorIndex")
    local dm0, ds0 = M.fc_get(w, "DeclsionMainCursorIndex"), M.fc_get(w, "DeclsionSubCursorIndex")
    if not M.tav_due(T, string.format("P%s/%s/%s/%s/%s", tostring(main), tostring(mi), tostring(si), tostring(dm0),
        tostring(ds0))) then return end
    local idx = (main and mi or si) or 0
    -- leaving, the cursor drops to -1 for a moment ("Waiting 0: empty, chosen")
    if idx < 0 then return end
    local pc, n
    if main then
        pc = M.fc_get(M.fc_get(w, "PartyCharacterList"), string.format("PartyCharacter_%02d", idx))
        n = M.fc_get(w, "MainCharacterMaxCount")
    else
        pc = M.fc_get(w, string.format("CharacterPanel_%02d", idx + 1))
        n = M.fc_get(w, "SubCharacterMaxCount")
    end
    local who = (pc and M.fc_shown(pc)) and M.ml_member(pc) or nil
    local s = (type(n) == "number" and n > 0)
        and (main and trf("Party %d of %d: %s", idx + 1, n, who or tr("empty"))
            or trf("Waiting %d of %d: %s", idx + 1, n, who or tr("empty")))
        or (main and trf("Party %d: %s", idx + 1, who or tr("empty")) or trf("Waiting %d: %s", idx + 1, who or tr("empty")))
    local dm, ds = M.fc_get(w, "DeclsionMainCursorIndex"), M.fc_get(w, "DeclsionSubCursorIndex")
    if (main and dm == idx) or ((not main) and ds == idx) then s = trf("%s, chosen", s) end   -- (idx >= 0)
    local sig = "P" .. s
    if sig == T.said then return end
    if not T.opened then
        log(string.format("TAVERN party change: main=%s idx=%s/%s max=%s/%s chosen=%s/%s error=%s", tostring(main),
            tostring(mi), tostring(si), tostring(M.fc_get(w, "MainCharacterMaxCount")),
            tostring(M.fc_get(w, "SubCharacterMaxCount")), tostring(dm), tostring(ds), tostring(M.fc_get(w, "ErrorNo"))))
        local t = M.fc_txt(w, "TitleText")
        if t then s = t .. ". " .. s end
    end
    T.said, T.opened = sig, true
    speak(s, true)
end
-- STORY SELECT, "Geschichte lauschen" (BarMenuStorySelect_C; the same screen asks when
-- you enter a town where a traveler's chapter can begin, eBAR_MENU_STORYSELECT_HEADER
-- "Eine Geschichte fortsetzen"): up to three entries StorySelectItem00..02
-- (BarMenuStorySelectItem_C: StoryCharacterName, StoryChapter "Kapitel 1", StoryText,
-- the recommended level RecomandationText + RecomandationLV, the state overlays
-- StoryProccess1..3 with StoryProccesstext1..3 "Im Gange" / "Unterbrochen" /
-- "Abgeschlossen"; ItemEnable), CursorPos the focused one. Its question ("Pfad von Cyrus,
-- Kapitel 1. Die Geschichte beginnen?") is a common dialog.
M.poll_story_select = function(w)
    local T = M.TAV
    local tp = os.clock()
    local cp = M.fc_get(w, "CursorPos") or 0
    if not M.tav_due(T, string.format("S%s/%s", tostring(cp), tostring(M.fc_get(w, "Status")))) then
        -- the entry's description (help window) a moment after it
        if T.help_at and os.clock() >= T.help_at then
            T.help_at = nil
            local h = M.ml_help and M.ml_help()
            if h and h ~= T.help_said then T.help_said = h; speak(h, false) end
        end
        return
    end
    local t0 = os.clock()
    local n = 0
    for i = 0, 2 do
        if M.fc_shown(M.fc_get(w, string.format("StorySelectItem%02d", i))) then n = n + 1 end
    end
    local item = M.fc_get(w, string.format("StorySelectItem%02d", cp))
    if not item then return end
    local f, raw = {}, {}
    for _, k in ipairs({ "StoryCharacterName", "StoryChapter", "StoryText", "RecomandationText", "RecomandationLV",
        "Level", "StoryProccesstext1", "StoryProccesstext2", "StoryProccesstext3" }) do
        f[k] = M.fc_txt(item, k)
        raw[#raw + 1] = k .. "=" .. tostring(f[k])
    end
    local en = M.fc_get(item, "ItemEnable")
    local t1 = os.clock()
    local parts = {}
    for _, k in ipairs({ "StoryCharacterName", "StoryChapter", "StoryText" }) do
        if f[k] then parts[#parts + 1] = f[k] end
    end
    if f.RecomandationLV and M.fc_shown(M.fc_get(item, "RecomandationRoot")) then
        parts[#parts + 1] = (f.RecomandationText or tr("recommended level")) .. " " .. f.RecomandationLV
    end
    for i = 1, 3 do
        local t = f["StoryProccesstext" .. i]
        if t and M.fc_shown(M.fc_get(item, "StoryProccess" .. i)) then parts[#parts + 1] = t end
    end
    if #parts == 0 then return end
    local s = (n > 1 and trf("%d of %d: ", cp + 1, n) or "") .. M.join_text(parts)
    if en == false then s = trf("%s, unavailable", s) end
    local sig = "S" .. s
    if sig == T.said then return end
    local key = table.concat(raw, " ")
    if key ~= T.logged then
        T.logged = key
        log(string.format("TAVERN story %d/%d enable=%s mode=%s status=%s: %s", cp + 1, n, tostring(en),
            tostring(M.fc_get(w, "BarMenuMode")), tostring(M.fc_get(w, "Status")), key))
    end
    if not T.opened then
        local h = M.gt_label("eBAR_MENU_STORYSELECT_HEADER")
        if h then s = h .. ". " .. s end
    end
    local t2 = os.clock()
    T.said, T.opened, T.help_at = sig, true, os.clock() + 0.4
    speak(s, true)
    local t3 = os.clock()
    -- (opening the screen stalls ~80 ms once, but this part took < 20 ms: logged to find it)
    if t3 - tp > 0.02 then
        log(string.format("TAVERN story read %.0f ms: cursor %.0f, widgets %.0f, texts %.0f, speak %.0f",
            (t3 - tp) * 1000, (t0 - tp) * 1000, (t1 - t0) * 1000, (t2 - t1) * 1000, (t3 - t2) * 1000))
    end
end
M.poll_tavern = function()
    if M.fade_now then return end
    local w, cls = M.get_active_screen()
    if cls == "ListCharacterWidget_C" then pcall(M.poll_party_change, w)
    elseif cls == "BarMenuStorySelect_C" then pcall(M.poll_story_select, w)
    elseif cls ~= "UICommonDialogBP_C" then
        if M.TAV.opened then M.TAV = {} end
    else
        -- a question over the screen: afterwards the entry is said again
        M.TAV.said, M.TAV.quick = nil, nil
    end
end

-- WORLD MAP (main menu -> Weltkarte; user request 2026-11-14: "no overview at all").
-- The screen is WorldMap_C, which the main menu holds (MainMenuWidget_C.WorldMap); it is
-- not on the UI manager's active stack ("ACTIVE screen: nil" while it is open). From the
-- object dump:
--   WorldMap_C: WorldMapAreaLabel (the name plate at the cursor), IconList (one
--     WorldMapIcon_C per place), IconRecommendationList, CursorPosition, IsFocus,
--     WorldMapState.
--   WorldMapAreaLabel_C: TextAreaName / TextRegionName (the shown texts), IsUnreached,
--     AttachWorldMapIcon (the place under the cursor), NowWorldMapTable @0x258 = its row.
--   WorldMapIcon_C: DataRowName (row of /Game/Level/Database/WorldMapTable), IconPosition,
--     NowLocationFlag (you are here), IsUnreached, RecommendationList.
--   WorldMapTable row: Kind @0, IconType @4, RefLevelName TArray<FName> @0x10 (the level
--     IDs, "79_0"), RegionName @0x20, MapName @0x28 (GameText labels), CanFastTravel
--     @0x58, TownDBID @0x70. A row name says the kind: eMAP_T_ town, _F_ path, _D_ dungeon.
--   The levels' encounters give the level (M.level_danger).
--   WorldMapIconRecommendation_C: CapterValue, LevelValue, CharacterNameLabel.
-- Announces the place under the cursor when it changes (name, region, recommended level,
-- not visited, you are here, the chapters recommended there); Page Up / Page Down step
-- through every place, nearest to where you are first, with its direction.
M.WM = { list = nil, idx = 0, open = false }
-- A WorldMapTable row (raw, by address) -> { name, region, kind, lmin, lmax, refs, town, fast }
M.wm_row_info = function(r)
    if not (r and r ~= 0 and shim and shim.Peek) then return nil end
    local info = { kind = shim.Peek(r, "i32"), icon = shim.Peek(r + 0x04, "i32"),
        town = shim.Peek(r + 0x70, "i32"), fast = shim.Peek(r + 0x58, "u8") }
    local c, n = shim.PeekFName(r + 0x28)
    info.name = M.gametext(c, n)
    c, n = shim.PeekFName(r + 0x20)
    info.region = M.gametext(c, n)
    -- RefLevelName: the place's levels, as level IDs ("79_0" = LevelTable row 79); their
    -- encounters give the level (M.level_danger), lowest to highest over all of them
    local arr, cnt = shim.Peek(r + 0x10, "ptr"), shim.Peek(r + 0x18, "i32")
    info.refs = {}
    if arr and arr ~= 0 and cnt and cnt > 0 and cnt < 32 then
        for i = 0, cnt - 1 do
            local lc, ln = shim.PeekFName(arr + i * 8)
            if lc and lc > 0 then
                local s = M.fname_str(lc, ln)
                info.refs[#info.refs + 1] = s
                local d = M.level_danger(tonumber(s:match("^(%d+)") or ""))
                if d then
                    info.lmin = math.min(info.lmin or d.danger, d.danger)
                    info.lmax = math.max(info.lmax or d.danger, d.danger)
                end
            end
        end
    end
    return info
end
-- the row name's kind: eMAP_T_ town, eMAP_F_ a path (field), eMAP_D_ dungeon
M.wm_what = function(row)
    local k = type(row) == "string" and row:match("^eMAP_(%u)_")
    return (k == "T" and N_("town")) or (k == "F" and N_("path")) or (k == "D" and N_("dungeon")) or nil
end
M.wm_find = function()
    local w = M.kept(M.wm_widget_h)   -- (a handle: checked with the shim first)
    if w then return w end
    M.wm_widget, M.wm_widget_h = nil, nil
    for i = 1, #scene_widgets do
        local e = scene_widgets[i]
        if e[2] == "MainMenuWidget_C" and M.sw_ok(e) then
            pcall(function()
                local x = e[1].WorldMap
                if x and x:IsValid() then M.wm_widget = x end
            end)
            if M.wm_widget then break end
        end
    end
    M.wm_widget_h = M.wm_widget and M.handle(M.wm_widget) or nil
    return M.wm_widget
end
-- The story chapters a town hosts, from the TownTable (TownInfoData, object dump: ID @8,
-- MainEvent1CharacterID @0x60, MainEvent1Capter @0x64, MainEvent2CharacterID @0x90,
-- MainEvent2Capter @0x94): { "Cyrus, chapter 2", ... }. The IDs count from 1 (Olberic,
-- Tressa, Cyrus, Primrose, H'aanit, Therion, Ophilia, Alfyn: Atlasdamm has 3, chapter 1),
-- one above the GameText labels ePLAYABLE_CHARA_NAME_00..07 that name them.
M.town_events = function(town)
    if type(town) ~= "number" or town <= 0 then return {} end
    if not M.town_rows then
        local idx, n = {}, 0
        local tt = shim and shim.DtCount and M.dt_addr("TownTable")
        if tt then
            for i = 0, (shim.DtCount(tt) or 0) - 1 do
                local _, _, row = shim.DtRowAt(tt, i)
                local id = row and shim.Peek(row + 0x08, "i32")
                if id then idx[id] = row; n = n + 1 end
            end
        end
        if n == 0 then return {} end
        M.town_rows = idx
    end
    local row = M.town_rows[town]
    if not row then return {} end
    local out, raw = {}, {}
    for _, o in ipairs({ 0x60, 0x90 }) do
        local who, ch = shim.Peek(row + o, "i32"), shim.Peek(row + o + 4, "i32")
        raw[#raw + 1] = string.format("%s/%s", tostring(who), tostring(ch))
        if type(who) == "number" and who >= 1 and who <= 8 and type(ch) == "number" and ch > 0 then
            local name = M.gametext(M.fname_of(string.format("ePLAYABLE_CHARA_NAME_%02d", who - 1)))
            out[#out + 1] = trf("%s, chapter %d", name or trf("traveler %d", who), ch)
        end
    end
    M.town_logged = M.town_logged or {}
    if not M.town_logged[town] then
        M.town_logged[town] = true
        log(string.format("WORLDMAP town %d events (who/chapter): %s -> %s", town, table.concat(raw, " "),
            table.concat(out, "; ")))
    end
    return out
end
-- the chapters recommended at a place: "Ophilia, chapter 1, level 1"
M.wm_recs = function(icon)
    local out = {}
    pcall(function()
        local rl = icon.RecommendationList
        if not (rl and rl:IsValid()) then return end
        local n = rl.ActiveCount or 0
        rl.RecommendationWidget:ForEach(function(i, v)
            if i > n then return end
            local w = v:get()
            if not (w and w:IsValid()) then return end
            local who, lbl
            pcall(function() lbl = w.CharacterNameLabel:ToString() end)
            pcall(function() who = M.gametext(M.fname_of(lbl)) end)
            local ch, lv = w.CapterValue, w.LevelValue
            -- the shown texts too: Kammbruch's (Cyrus' chapter 2) had no name label and
            -- no values, "Recommended: someone" (2026-11-14)
            local tx = {}
            for _, f in ipairs({ "CharacterText", "CapterText", "LevelText", "RecommendationText" }) do
                local s
                pcall(function() s = w[f]:GetText():ToString() end)
                tx[#tx + 1] = f .. "=" .. tostring(s)
                if s and s ~= "" then tx[f] = s end
            end
            M.rec_logged = M.rec_logged or {}
            local lk = tostring(lbl) .. tostring(ch) .. tostring(lv) .. table.concat(tx, ";")
            if not M.rec_logged[lk] then
                M.rec_logged[lk] = true
                log(string.format("WORLDMAP rec %d/%d: label=%s chapter=%s level=%s %s", i, n, tostring(lbl), tostring(ch),
                    tostring(lv), table.concat(tx, " ")))
            end
            -- an unused widget keeps its design texts ("オフィーリア, 第1章, 99"): no name
            -- label and no chapter -- not a recommendation (Kammbruch, 2026-11-14)
            if (not lbl or lbl == "None" or lbl == "") and not (type(ch) == "number" and ch > 0) then return end
            if not who and tx.CharacterText then who = tx.CharacterText end
            local s = (who or tr("someone"))
            if type(ch) == "number" and ch > 0 then s = trf("%s, chapter %d", s, ch)
            elseif tx.CapterText then s = s .. ", " .. tx.CapterText end
            if type(lv) == "number" and lv > 0 then s = trf("%s, level %d", s, lv)
            elseif tx.LevelText then s = s .. ", " .. tx.LevelText end
            out[#out + 1] = s
        end)
    end)
    return out
end
-- One place: a WorldMapIcon_C -> { name, region, ..., x, y, here, unreached, recs }
M.wm_icon_info = function(icon)
    local rowname
    pcall(function() rowname = icon.DataRowName:ToString() end)
    local info
    local tbl = M.dt_addr and M.dt_addr("WorldMapTable")
    if rowname and tbl and shim.DtFind then
        local c, n = M.fname_of(rowname)
        local r = c and shim.DtFind(tbl, c, n)
        info = r and M.wm_row_info(r)
    end
    info = info or {}
    info.row = rowname
    info.what = M.wm_what(rowname)
    pcall(function() info.x = icon.IconPosition.X; info.y = icon.IconPosition.Y end)
    pcall(function() info.here = icon.NowLocationFlag and true or false end)
    pcall(function() info.unreached = icon.IsUnreached and true or false end)
    pcall(function() info.visible = icon.IsVisiblity and not icon.HideFlag end)
    pcall(function() info.dest = icon.DestinationFlag and true or false end)
    info.recs = M.wm_recs(icon)
    -- a story destination without a recommendation of its own (Kammbruch after Cyrus'
    -- chapter 1, 2026-11-14): the chapters the town hosts say why
    if info.dest and #info.recs == 0 then
        local ok, ev = pcall(M.town_events, info.town)
        info.story = ok and ev or {}
    end
    return info
end
-- "Kammbruch, town, Flachland, levels 10 to 15, not visited. Recommended: ..."
-- (noregion: in a region's own list the region goes unsaid)
M.wm_describe = function(info, where, noregion)
    local parts = { info.name or info.row or tr("unknown place") }
    if info.what then parts[#parts + 1] = tr(info.what) end
    if info.region and info.region ~= info.name and not noregion then parts[#parts + 1] = info.region end
    if where then parts[#parts + 1] = where end
    if info.lmin then
        parts[#parts + 1] = (info.lmax and info.lmax > info.lmin)
            and trf("danger level %d to %d", info.lmin, info.lmax)
            or trf("danger level %d", info.lmin)
    end
    if info.here then parts[#parts + 1] = tr("you are here") end
    -- a place the map does not show yet (only a region's list has those)
    local hidden = info.visible == false
    if hidden then parts[#parts + 1] = tr("not discovered")
    elseif info.unreached then parts[#parts + 1] = tr("not visited") end
    local s = table.concat(parts, ", ")
    if hidden then return s end
    if info.recs and #info.recs > 0 then s = trf("%s. Recommended: %s", s, table.concat(info.recs, "; "))
    elseif info.dest then
        -- every story destination is marked; with no recommendation, say whose chapters
        s = (info.story and #info.story > 0) and trf("%s. Story destination: %s", s, table.concat(info.story, "; "))
            or trf("%s. Story destination", s)
    end
    return s
end
-- the places the map shows, nearest to where you are first. The map holds an icon for
-- each of its 147 places (WorldMap_C.IconList); it shows only the visited ones and the
-- story destinations (11 of them in Cyrus' chapter 1, user report 2026-11-15: "only one
-- region"). All of them, sorted the same way, go to M.WM.all for the region lists.
M.wm_build_list = function(wm)
    local list, all, here = {}, {}, nil
    pcall(function()
        wm.IconList:ForEach(function(_, v)
            local icon = v:get()
            if not (icon and icon:IsValid()) then return end
            local info = M.wm_icon_info(icon)
            info.icon = icon
            if info.here then here = info end
            all[#all + 1] = info
        end)
    end)
    local hx, hy = here and here.x, here and here.y
    for _, e in ipairs(all) do
        e.d = (hx and e.x) and math.sqrt((e.x - hx) ^ 2 + (e.y - hy) ^ 2) or 0
    end
    table.sort(all, function(a, b) return a.d < b.d end)
    for _, e in ipairs(all) do
        if e.visible ~= false then list[#list + 1] = e end
    end
    M.WM.all, M.WM.shown = all, list
    log(string.format("WORLDMAP list: %d places shown of %d, here=%s", #list, #all, tostring(here and here.name)))
    for i, e in ipairs(list) do
        pcall(M.town_events, e.town)   -- (logs each town's chapters once)
        if i <= 60 then
            log(string.format("WORLDMAP place %d: %s row=%s kind=%s what=%s pos=(%.0f,%.0f) here=%s dest=%s unreached=%s lv=%s-%s refs=%s town=%s recs=%d",
                i, tostring(e.name), tostring(e.row), tostring(e.kind), tostring(e.what), e.x or -1, e.y or -1,
                tostring(e.here), tostring(e.dest), tostring(e.unreached), tostring(e.lmin), tostring(e.lmax),
                table.concat(e.refs or {}, "+"), tostring(e.town), #(e.recs or {})))
        end
    end
    return list, here
end
-- direction on the map (north up): from where you are to a place
M.I18N_DIRS = { N_("north"), N_("south"), N_("east"), N_("west"), N_("north-east"), N_("north-west"),
    N_("south-east"), N_("south-west") }   -- (for scripts/i18n.py: the words wm_dir says)
M.wm_dir = function(dx, dy)
    local d = math.sqrt(dx * dx + dy * dy)
    if d < 1 then return tr("here") end
    local ns = (dy < -0.38 * d) and "north" or ((dy > 0.38 * d) and "south" or "")
    local ew = (dx > 0.38 * d) and "east" or ((dx < -0.38 * d) and "west" or "")
    if ns ~= "" and ew ~= "" then return tr(ns .. "-" .. ew) end
    return tr(ns ~= "" and ns or ew)
end
-- Send the map's cursor to a place, so Enter there fast travels to a visited town (user
-- request 2026-11-14). WorldMap_C moves its cursor to MoveTargetPos when
-- MoveTargetPosRequest is set (object dump); poll_worldmap checks it moved, else sets
-- CursorPosition itself. The area label then announces the same place: that one is
-- skipped (WM.skip).
M.wm_jump = function(wm, e)
    if not (e.x and e.y) then return end
    local cx, cy
    pcall(function() cx, cy = wm.CursorPosition.X, wm.CursorPosition.Y end)
    local ok = pcall(function()
        if cx then wm.MoveStartPos.X = cx; wm.MoveStartPos.Y = cy end
        wm.MoveTargetPos.X = e.x
        wm.MoveTargetPos.Y = e.y
        wm.MoveTargetPosMoveNowTime = 0.0
        wm.MoveTargetPosRequest = true
    end)
    M.WM.jump = { t = os.clock(), x = e.x, y = e.y, tries = 1 }
    M.WM.skip = e.name
    log(string.format("WORLDMAP jump to %s (%.0f,%.0f) from cursor (%s,%s): request set=%s", tostring(e.name), e.x, e.y,
        tostring(cx), tostring(cy), tostring(ok)))
end
M.wm_jump_check = function(wm)
    local j = M.WM.jump
    if not j or os.clock() - j.t < 0.8 then return end
    local cx, cy
    pcall(function() cx, cy = wm.CursorPosition.X, wm.CursorPosition.Y end)
    local d = (cx and cy) and math.sqrt((cx - j.x) ^ 2 + (cy - j.y) ^ 2) or -1
    log(string.format("WORLDMAP jump try %d: cursor now (%s,%s), %.0f from the target", j.tries, tostring(cx),
        tostring(cy), d))
    if d >= 0 and d < 15 then M.WM.jump = nil; return end
    if j.tries >= 2 then M.WM.jump, M.WM.skip = nil, nil; return end
    j.tries, j.t = 2, os.clock()
    local ok = pcall(function()
        wm.CursorPosition.X = j.x
        wm.CursorPosition.Y = j.y
    end)
    log("WORLDMAP jump: set CursorPosition itself: " .. tostring(ok))
end
M.wm_cycle = function(delta)
    local WM = M.WM
    if M.explore_now == true then WM.open = false end   -- back in the field (fast travel)
    if not WM.open then return false end
    local wm = M.wm_find()
    if not wm then return false end
    if not WM.list then
        -- (built when the map opened; again only if that failed)
        if WM.shown then WM.list = WM.shown else WM.list, WM.here = M.wm_build_list(wm) end
        WM.idx = 0
    end
    local n = #WM.list
    if n == 0 then speak((WM.reg or 0) > 0 and tr("No places") or tr("No places on the map")); return true end
    if WM.idx < 1 then WM.idx = (delta > 0) and 1 or n   -- the first press: first or last
    else WM.idx = ((WM.idx - 1 + delta) % n) + 1 end
    local e = WM.list[WM.idx]
    local where
    if WM.here and e ~= WM.here and e.x and WM.here.x then
        where = string.format("%s, %d", M.wm_dir(e.x - WM.here.x, e.y - WM.here.y), math.floor(e.d + 0.5))
    end
    speak(trf("%d of %d: %s", WM.idx, n, M.wm_describe(e, where, (WM.reg or 0) > 0)), true)
    -- the cursor goes only to places the map shows: on a hidden one its name plate would
    -- name whatever shown place is nearest
    if e.visible ~= false then pcall(M.wm_jump, wm, e) end
    return true
end
-- THE EIGHT REGIONS (user request 2026-11-15: "there are 8 regions, many seem to be
-- missing"). The map shows only what you have found, so Home / End on the map go through
-- the regions in the game's order (GameText eAREA_NAME_00..07: Frostland, Flachland,
-- Küstenland, Hochland, Sonnenland, Flussland, Klippenland, Waldland) and back to the
-- places the map shows; Page Up / Page Down then go through EVERY place of that region,
-- nearest first, the ones the map doesn't show yet as "not discovered" (their danger
-- level is known all the same). The first press goes to the region you are in.
M.wm_regions = function()
    local out = {}
    for i = 0, 7 do
        local nm = M.gt_label(string.format("eAREA_NAME_%02d", i))
        if nm and nm ~= "" then out[#out + 1] = nm end
    end
    return out
end
-- a region's places, nearest first; a place the table has twice (two versions of one
-- dungeon, "_A"/"_B") once, the shown copy if there is one
M.wm_region_list = function(region)
    local out, at = {}, {}
    for _, e in ipairs(M.WM.all or {}) do
        if e.region == region then
            local k = tostring(e.name or e.row) .. "|" .. tostring(e.what)
            local i = at[k]
            if not i then
                out[#out + 1] = e
                at[k] = #out
            elseif out[i].visible == false and e.visible ~= false then
                out[i] = e
            end
        end
    end
    return out
end
M.wm_region_cycle = function(delta)
    local WM = M.WM
    if M.explore_now == true then WM.open = false end
    if not WM.open then return false end
    local wm = M.wm_find()
    if not wm then return false end
    if not WM.all then WM.list, WM.here = M.wm_build_list(wm); WM.idx = 0 end
    local regs = M.wm_regions()
    if #regs == 0 then speak(tr("No regions")); return true end
    -- 0 = the places the map shows, 1..8 the regions
    local cur = WM.reg or 0
    if cur == 0 and WM.here and WM.here.region then
        local mine
        for i, r in ipairs(regs) do if r == WM.here.region then mine = i end end
        cur = mine or ((delta > 0) and 1 or #regs)
    else
        cur = (cur + delta) % (#regs + 1)
    end
    WM.reg, WM.idx = cur, 0
    if cur == 0 then
        WM.list = WM.shown or {}
        speak(trf("Places on the map, %d", #WM.list), true)
        return true
    end
    WM.list = M.wm_region_list(regs[cur])
    local shown = 0
    for _, e in ipairs(WM.list) do if e.visible ~= false then shown = shown + 1 end end
    log(string.format("WORLDMAP region %s: %d places, %d shown", regs[cur], #WM.list, shown))
    speak(trf("%s, %d places, %d of them on your map", regs[cur], #WM.list, shown), true)
    return true
end
nav_keys = nav_keys or {}
nav_keys.wm = function(delta) return M.wm_cycle(delta) end
M.poll_worldmap = function()
    local WM = M.WM
    local wm = M.wm_find()
    if not wm then WM.open = false; return end
    local vis, focus, state = false, nil, nil
    pcall(function() vis = wm:IsVisible() and true or false end)
    pcall(function() focus = wm.IsFocus end)
    pcall(function() state = wm.WorldMapState end)
    local sig = string.format("%s/%s/%s", tostring(vis), tostring(focus), tostring(state))
    if sig ~= WM.sig then WM.sig = sig; log("WORLDMAP state vis/focus/state = " .. sig) end
    -- After a fast travel the map keeps IsVisible and IsFocus, WorldMapState 3 (1 is the
    -- travel question), until the main menu opens again: Page Up/Down read the map's places
    -- in the town, and every scene or path action "opened" it ("World map. You are at ...,
    -- Atlasdamm", user reports 2026-11-14). So: never in state 3 or while exploring, and it
    -- only OPENS while the main menu is the focused screen (the map is part of it); once
    -- open, a dialog over it (the travel question) keeps it open.
    local _, acls = M.get_active_screen()
    local ctx = (acls == "MainMenuWidget_C") or (WM.open and (acls == nil or acls == "UICommonDialogBP_C"))
    local open = vis and (focus == nil or focus == true) and state ~= 3 and M.explore_now ~= true and ctx
    if not open then
        if WM.open then
            log("WORLDMAP closed")
            -- back in the main menu: say where (not after a fast travel: in the field)
            if M.explore_now ~= true and acls == "MainMenuWidget_C" then pcall(M.mainmenu_reannounce) end
        end
        WM.open, WM.list, WM.area = false, nil, nil
        WM.reg, WM.all, WM.shown = nil, nil, nil
        return
    end
    local lbl
    pcall(function() lbl = wm.WorldMapAreaLabel end)
    local area, region
    pcall(function() area = lbl.TextAreaName:GetText():ToString() end)
    pcall(function() region = lbl.TextRegionName:GetText():ToString() end)
    if not WM.open then
        WM.open, WM.list, WM.idx, WM.jump, WM.skip, WM.reg = true, nil, 0, nil, nil, nil
        local cx, cy
        pcall(function() cx, cy = wm.CursorPosition.X, wm.CursorPosition.Y end)
        log(string.format("WORLDMAP opened, cursor (%s,%s)", tostring(cx), tostring(cy)))
        local _, here = M.wm_build_list(wm)
        WM.here = here
        speak((here and here.name) and trf("World map. You are at %s", here.name) or tr("World map"), true)
        M.await_first_item = true   -- the place under the cursor goes after it
    end
    pcall(M.wm_jump_check, wm)
    local key = tostring(area) .. "|" .. tostring(region)
    if key == WM.area or not area or area == "" then return end
    WM.area = key
    -- the place Page Up/Down just sent the cursor to: already said
    if WM.skip and area == WM.skip then WM.skip = nil; return end
    -- the place under the cursor: its icon (recommendations, you are here) and table row
    local info
    pcall(function()
        local icon = lbl.AttachWorldMapIcon
        if icon and icon:IsValid() then info = M.wm_icon_info(icon) end
    end)
    if not info or not info.name then
        local a = 0
        pcall(function() a = lbl:GetAddress() end)
        local row = (a ~= 0) and M.wm_row_info(a + 0x258) or nil
        info = info or {}
        if row then for k, v in pairs(row) do if info[k] == nil then info[k] = v end end end
    end
    pcall(function() if lbl.IsUnreached then info.unreached = true end end)
    info.name = area
    info.region = (region and region ~= "") and region or info.region
    log(string.format("WORLDMAP cursor: %s | %s row=%s kind=%s refs=%s lv=%s-%s here=%s unreached=%s recs=%d",
        tostring(area), tostring(region), tostring(info.row), tostring(info.kind), table.concat(info.refs or {}, "+"),
        tostring(info.lmin), tostring(info.lmax), tostring(info.here), tostring(info.unreached), #(info.recs or {})))
    M.say_item(M.wm_describe(info))
end

-- ROUTE FINDER (user request 2026-11-14): fast travel works only to towns visited once,
-- so the way to a new town is walked area by area. Ctrl+Backspace on the world map says
-- the areas from here to the place Page Up/Down picked, and keeps it as the route goal:
-- in the field the navigator then names the exit that leads on along that route.
-- The game has no table of which area leads where: every exit is a LevelTrigger in its
-- level, m_nNextMapID its destination. scripts/level-links.py read them once from the
-- game's area levels into Scripts\worldlinks.lua (level name -> destination level IDs);
-- the LevelTable turns the names into IDs (row name = ID, LevelName @8). The search runs
-- over levels; the WorldMapTable's places (RefLevelName = their levels) name the steps.
-- (Its DestinationStart / DestinationFinish are story flags, not links.)
M.wm_graph = function()
    if M.wm_g then return M.wm_g end
    local tbl = M.dt_addr and M.dt_addr("WorldMapTable")
    local lt = M.dt_addr and M.dt_addr("LevelTable")
    if not (tbl and lt and shim and shim.DtCount) then return nil end
    local okd, links = pcall(require, "worldlinks")
    if not okd or type(links) ~= "table" then log("ROUTE: no worldlinks.lua: " .. tostring(links)); return nil end
    local g = { nodes = {}, bylevel = {}, byrow = {}, adj = {} }
    for i = 0, (shim.DtCount(tbl) or 0) - 1 do
        pcall(function()
            local rc, rn, row = shim.DtRowAt(tbl, i)
            if not row then return end
            local rname = M.fname_str(rc, rn)
            local info = M.wm_row_info(row) or {}
            local nd = { row = rname, name = info.name or rname, region = info.region, what = M.wm_what(rname),
                lmin = info.lmin, lmax = info.lmax, levels = {} }
            for _, s in ipairs(info.refs or {}) do
                local id = tonumber(s:match("^(%d+)") or "")
                if id then nd.levels[#nd.levels + 1] = id; g.bylevel[id] = g.bylevel[id] or nd end
            end
            g.byrow[rname] = nd
            g.nodes[#g.nodes + 1] = nd
        end)
    end
    -- level name -> ID from the LevelTable, then the exits as level -> level links
    local idof, nlev = {}, 0
    for i = 0, (shim.DtCount(lt) or 0) - 1 do
        pcall(function()
            local rc, rn, row = shim.DtRowAt(lt, i)
            local id = row and tonumber(M.fname_str(rc, rn))
            local lc, ln = shim.PeekFName(row + 0x08)
            if id and lc and lc > 0 then idof[M.fname_str(lc, ln)] = id; nlev = nlev + 1 end
        end)
    end
    local nlinks, unknown = 0, 0
    for name, dsts in pairs(links) do
        local src = idof[name]
        if src then
            g.adj[src] = g.adj[src] or {}
            for _, d in ipairs(dsts) do
                if d ~= src and not g.adj[src][d] then g.adj[src][d] = true; nlinks = nlinks + 1 end
            end
        else
            unknown = unknown + 1
        end
    end
    log(string.format("ROUTE graph: %d places, %d levels, %d exit links (%d level names not in the LevelTable)",
        #g.nodes, nlev, nlinks, unknown))
    if #g.nodes > 0 and nlinks > 0 then M.wm_g = g end
    return g
end
-- The current level ID (LevelManagerBP_C, found once)
M.current_level = function()
    local id
    pcall(function()
        local lm = M.kept(M.levelmgr_h)   -- (shared with M.level_id)
        if not lm then
            M.levelmgr_h = nil
            local x = FindFirstOf("LevelManagerBP_C")
            if x and x:IsValid() then lm = x; M.levelmgr_h = M.handle(x) end
        end
        id = lm.CurrentLevelID
    end)
    return type(id) == "number" and id or nil
end
-- Fewest exits from level `from` into any level of place `to`: the level IDs (both ends
-- included), or nil
M.wm_level_route = function(g, from, to)
    if not (g and from and to) then return nil end
    local goal = {}
    for _, l in ipairs(to.levels) do goal[l] = true end
    if goal[from] then return { from } end
    local prev, q, head = { [from] = from }, { from }, 1
    while head <= #q do
        local cur = q[head]; head = head + 1
        for nxt in pairs(g.adj[cur] or {}) do
            if not prev[nxt] then
                prev[nxt] = cur
                if goal[nxt] then
                    local path, x = {}, nxt
                    while x ~= from do table.insert(path, 1, x); x = prev[x] end
                    table.insert(path, 1, from)
                    return path
                end
                q[#q + 1] = nxt
            end
        end
    end
    return nil
end
-- The places along a level route, in order, without the one you start in and without
-- repeats (a town's parts are one place; levels of no place are passed over)
M.wm_route_places = function(g, path)
    local out, last = {}, g.bylevel[path[1]]
    for i = 2, #path do
        local nd = g.bylevel[path[i]]
        if nd and nd ~= last then out[#out + 1] = nd; last = nd end
    end
    return out
end
-- "4 areas: Nördliche Atlasdamm-Ebenen, path, danger level 1; ...; Kammbruch"
M.wm_route_text = function(places)
    local parts = {}
    for _, nd in ipairs(places) do
        local s = nd.name or nd.row
        if nd.what and nd.what ~= "town" then s = s .. ", " .. tr(nd.what) end
        if nd.lmin then s = s .. ", " .. trf("danger level %d", nd.lmin) end
        parts[#parts + 1] = s
    end
    return trn("%d area: %s", "%d areas: %s", #places, #places, table.concat(parts, "; "))
end
-- FAST TRAVEL ON THE WAY (user request 2026-11-17: the town nearest to the target, to
-- fast travel there and walk on). Fast travel goes only to towns you have visited: the
-- map's icon is not IsUnreached, and the town's WorldMapTable row has CanFastTravel (all
-- 24 eMAP_T_ rows; one path, eMAP_F_Mount_3_2, too -- left out, towns only). Of those, the
-- one with the fewest areas on to the target. `places` = M.WM.all (the map's icons).
-- -> { node, path, n = areas from there, e = its icon entry } or nil
M.wm_fast_from = function(g, to, places)
    local best
    for _, e in ipairs(places or {}) do
        local nd = e.row and g.byrow[e.row]
        if nd and nd.what == "town" and (e.fast or 0) ~= 0 and not e.unreached and e.visible ~= false then
            for _, l in ipairs(nd.levels) do
                local path = M.wm_level_route(g, l, to)
                if path then
                    local n = (#path == 1) and 0 or #M.wm_route_places(g, path)
                    if not best or n < best.n or (n == best.n and #path < #best.path) then
                        best = { node = nd, path = path, n = n, e = e }
                    end
                end
            end
        end
    end
    return best
end
-- The map's cursor to a place of the list (a town to fast travel to); the Page Up/Down
-- selection goes there too
M.wm_fast_cursor = function(e)
    local wm = M.wm_find()
    if not (wm and e) then return false end
    for i, x in ipairs(M.WM.list or {}) do
        if x.row == e.row then M.WM.idx = i; break end
    end
    M.wm_jump(wm, e)
    speak(trf("Cursor on %s. Enter for fast travel.", tostring(e.name)))
    return true
end
-- Ctrl+Backspace on the world map: the route to the place Page Up/Down picked -- from a
-- town you can fast travel to when that is fewer areas than from here (M.wm_fast_from);
-- pressed again within a minute it puts the map's cursor on that town.
M.wm_route_say = function()
    local WM = M.WM
    local e = WM.list and WM.list[WM.idx]
    if not e then speak(tr("Pick a place with page up and page down first")); return end
    local g = M.wm_graph()
    if not g then speak(tr("No route data")); return end
    local to = e.row and g.byrow[e.row]
    local from = M.current_level()
    if not (from and to) then
        log(string.format("ROUTE from level %s to %s: unknown", tostring(from), tostring(e.row)))
        speak(tr("Can't tell where you are on the map"))
        return
    end
    local fs = WM.fast_said
    WM.fast_said = nil
    if fs and fs.goal == to and os.clock() - fs.t < 60 and M.wm_fast_cursor(fs.e) then return end
    local path = M.wm_level_route(g, from, to)
    if path and #path == 1 then speak(tr("You are there")); return end
    local fast = M.wm_fast_from(g, to, WM.all)
    local n_here = path and #M.wm_route_places(g, path) or nil
    do   -- (WorldMap_C.FastTravelPossible read false in the Maiya caves while Enter on a
         -- visited town offered the fast travel, 2026-11-17: no gate, only logged)
        local fp, fr
        pcall(function() local wm = M.wm_find(); fp, fr = wm.FastTravelPossible, wm.FastTravelRestriction end)
        log(string.format("ROUTE fast travel: %s with %s areas, from here %s; map FastTravelPossible=%s Restriction=%s",
            fast and fast.node.row or "none", fast and tostring(fast.n) or "-", tostring(n_here), tostring(fp), tostring(fr)))
    end
    if fast and (not n_here or fast.n < n_here) then
        M.route_goal = to
        WM.fast_said = { goal = to, e = fast.e, t = os.clock() }
        log("ROUTE levels " .. table.concat(fast.path, " > ") .. " to " .. to.row .. " from " .. fast.node.row)
        if fast.n == 0 then
            speak(trf("%s: you can fast travel there. Control backspace again puts the cursor on it.", to.name), true)
        else
            speak(trf("Route to %s: fast travel to %s, then %s. Control backspace again puts the cursor on %s.", to.name,
                fast.node.name, M.wm_route_text(M.wm_route_places(g, fast.path)), fast.node.name), true)
        end
        return
    end
    if not path then
        log(string.format("ROUTE from level %d to %s (levels %s): none", from, to.row, table.concat(to.levels, ",")))
        speak(trf("No route known to %s", tostring(to.name)))
        return
    end
    M.route_goal = to
    log("ROUTE levels " .. table.concat(path, " > ") .. " to " .. to.row)
    speak(trf("Route to %s, %s. In each area the exit on the way says so.", to.name,
        M.wm_route_text(M.wm_route_places(g, path))), true)
end
-- The exit that leads on along the route to M.route_goal: its destination is the next
-- level of the route from here. "on the way to Kammbruch"
M.route_exit_note = function(actor)
    local goal = M.route_goal
    if not (goal and actor) then return nil end
    local g = M.wm_graph()
    local here = M.current_level()
    local path = g and here and M.wm_level_route(g, here, goal)
    if not path or #path < 2 then return nil end
    local id
    pcall(function() id = actor.m_nNextMapID end)
    if id == path[2] then return trf("on the way to %s", tostring(goal.name)) end
    return nil
end

-- Tutorial pop-up reader. The pop-up's active widget is UITutorial_C; its current page
-- is UITutorial_C.NowPageTemplate (a UITutorialTemplateNN_C), whose PageText array holds
-- the page's text-block widgets (title, body, captions -- order varies per template, so
-- we read every non-empty entry). Announced when the text changes, which covers both the
-- pop-up appearing and paging forward/back through a multi-page tutorial.
do
    local last_tut, tut_t, tut_hinted
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
        local say = M.join_text(parts)
        local now = os.clock()
        if say ~= last_tut then
            -- the page, at once ("Page 1 of 3."); its key only when nothing was pressed for
            -- a while (M.HINT_DELAY)
            last_tut, tut_t, tut_hinted = say, now, false
            local i, n = M.tutorial_pages(w)
            speak((n and n > 1) and (say .. " " .. trf("Page %d of %d.", i + 1, n)) or say)
        elseif not tut_hinted and now - (tut_t or now) >= M.HINT_DELAY then
            tut_hinted = true
            speak(M.tutorial_key(w))
        end
    end
end
-- KEY HINTS COME LATE (user 2026-11-24: said every time, "Continue with Enter" and the
-- like were too much). A tutorial, a story page or a letter that waits for a key says
-- which one only after this long with nothing pressed.
M.HINT_DELAY = 20
-- HOW TO GO ON (player report 2026-11-24: nothing said how to close a tutorial, though
-- the screen shows it). The pop-up takes only the cancel key -- Backspace, Escape, B; its
-- bytecode: OnMenuCancel -> ChangeNextImage, Enter does nothing -- which shows the next
-- page, or closes it after the last (PageDataList has no page after ShowPageIndex).
-- Read raw: ShowPageIndex @0x238, PageDataList @0x2B0 (its Num at +8). -> the page
-- (0-based) and the count, or nil
M.TUT_PAGE, M.TUT_PAGES = 0x238, 0x2B0 + 8
M.tutorial_pages = function(w)
    local i, n
    if shim and shim.Peek then
        local a = 0
        pcall(function() a = w:GetAddress() end)
        if a ~= 0 then i, n = shim.Peek(a + M.TUT_PAGE, "i32"), shim.Peek(a + M.TUT_PAGES, "i32") end
    end
    if type(i) ~= "number" or type(n) ~= "number" or n < 1 or n > 50 or i < 0 or i >= n then return nil end
    return i, n
end
M.tutorial_key = function(w)
    local i, n = M.tutorial_pages(w)
    if not i then return tr("Go on with Backspace.") end
    if i + 1 < n then return tr("Next page with Backspace.") end
    return tr("Close with Backspace.")
end

-- WHEN A STORY PAGE WAITS (player report 2026-11-24: in stories and flashbacks the lines
-- come by themselves, then the game waits for a key, with nothing to tell). Their window,
-- NarrationWidget_C (cooked bytecode): State (@0x2B8) 2 draws a page's lines one by one
-- (each is said as it comes, GetTalkText), 7 = all drawn and WAITING -- only Decide
-- (Enter, E) goes on: the next page, or after the last one the end. A letter or note
-- (NoteMode @0xCE8, its whole text at once) waits in State 2 for Cancel (Backspace),
-- which closes it. Said once per wait, and only after M.HINT_DELAY with nothing pressed
-- (the page done at once is the usual case); M.narr_waited is cleared by every other
-- state (and by another event screen, M.poll_event_menus).
M.NARR_STATE, M.NARR_NOTE, M.NARR_PAGE = 0x2B8, 0xCE8, 0x2D0
M.poll_narration = function(w)
    if not (shim and shim.Peek) then return end
    local a = 0
    pcall(function() a = w:GetAddress() end)
    if a == 0 then return end
    local st, note = shim.Peek(a + M.NARR_STATE, "u8"), shim.Peek(a + M.NARR_NOTE, "u8")
    local key
    if note == 0 and st == 7 then
        key = "page" .. tostring(shim.Peek(a + M.NARR_PAGE, "i32"))
    elseif note and note ~= 0 and st == 2 then
        key = "note"
    end
    if not key then M.narr_waited = nil; return end
    local now = os.clock()
    if key ~= M.narr_waited then
        M.narr_waited, M.narr_wait_t, M.narr_hinted = key, now, false
        log("NARRATION waits: " .. key)
        return
    end
    if M.narr_hinted or now - (M.narr_wait_t or now) < M.HINT_DELAY then return end
    M.narr_hinted = true
    speak(key == "note" and tr("Close with Backspace.") or tr("Continue with Enter."))
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
        local label, btn
        pcall(function()
            local box = w.ShowVerticalBox
            btn = box and box:GetChildAt(ci)
            if btn then local t = btn.Text; if t then local g = t:GetText(); if g then label = g:ToString() end end end
        end)
        -- done already / not possible / not usable on this person (M.fc_item_state)
        local okx, extra = pcall(M.fc_item_state, btn, label)
        speak((label or trf("Action %s", tostring(ci))) .. ((okx and extra) and (", " .. extra) or ""))
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
            if not M.sw_ok(e) then
                -- gone (the shim's reads): not touched
            elseif e[2] == "TitleOptionScene_C" then
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
    if M.battle_now and M.poll_battle then
        local t0 = os.clock()
        pcall(M.poll_battle)
        local ms = (os.clock() - t0) * 1000
        if ms > 60 then
            M.bt_slow = (M.bt_slow or 0) + 1
            if M.bt_slow <= 20 or M.bt_slow % 50 == 0 then
                log(string.format("BATTLE poll slow: %.0f ms (#%d)", ms, M.bt_slow))
            end
        end
    end
    if cls == "BattleResultPanelWidget_C" and M.poll_battle_result then pcall(M.poll_battle_result, w) end
    if cls == "NarrationWidget_C" then pcall(M.poll_narration, w) else M.narr_waited = nil end
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
        if M.trace then log("TR evmenus") end
        pcall(M.poll_event_menus)
    end)
end

-- ===== BATTLE UI (2026-11-14) =====
-- A TextBlock's text (GetText, else its Text property), or nil.
M.wtext = function(tb)
    local s
    pcall(function() s = tb:GetText():ToString() end)
    if not s or s == "" then pcall(function() s = tb.Text:ToString() end) end
    if s == "" then s = nil end
    return s
end
M.wvis = function(w)   -- ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden, 3/4 hit-test-less
    local v
    pcall(function() v = w:GetVisibility() end)
    return v
end
-- Exploration dump of the battle widgets (Ctrl+F3, on the game thread): command
-- menus with their items, help line, target cursor, enemy panels with shield and
-- weakness icons, party status, the action name banner.
M.battle_dump = function()
    local function each(cls, fn)
        local list
        pcall(function() list = FindAllOf(cls) end)
        if not list then log("BDUMP " .. cls .. ": none"); return end
        for i, w in ipairs(list) do
            local ok = false
            pcall(function() ok = w:IsValid() end)
            if ok then pcall(fn, w, i) end
        end
    end
    each("BattleCommandMenu_C", function(w, i)
        local items = {}
        for k = 0, 7 do
            local it
            pcall(function() it = w["MenuItem0" .. k] end)
            if it then
                local u, dis, foc
                pcall(function() u, dis, foc = it.CommandUseable, it.CommandDisable, it.IsCommandFocus end)
                items[#items + 1] = string.format("%d:%s[%s]%s%s%s v%s", k, tostring(M.wtext(it.TextCommandFocus)),
                    tostring(M.wtext(it.TextAddInfo)), u and "" or " nouse", dis and " dis" or "", foc and " FOCUS" or "",
                    tostring(M.wvis(it)))
            end
        end
        local ci, oi, mx, fl, open, sub
        pcall(function() ci, oi, mx, fl, open = w.CursorIndex, w.OffsetIndex, w.MenuItemMax, w.FloorIndex, w.MenuOpen end)
        pcall(function() sub = w.SubMenuName:ToString() end)
        log(string.format("BDUMP menu#%d vis=%s open=%s cur=%s off=%s max=%s floor=%s sub=%s | %s", i,
            tostring(M.wvis(w)), tostring(open), tostring(ci), tostring(oi), tostring(mx), tostring(fl), tostring(sub),
            table.concat(items, " | ")))
    end)
    each("BattleCommandHelpWindow_C", function(w, i)
        log(string.format("BDUMP help#%d vis=%s text=%s", i, tostring(M.wvis(w)), tostring(M.wtext(w.HelpText))))
    end)
    -- NEVER ask a battle character pointer for its name (GetFName/GetFullName): the
    -- unused turn-order icons hold stale ones, and reading the name of one FROZE the
    -- game (2026-11-14, like an out-of-range FName). Addresses only.
    each("BattleTargetCursor_C", function(w, i)
        local cv, tn
        pcall(function() cv = w.CursorVisible end)
        pcall(function() tn = string.format("%X", M.peekp(w, 0x208) or 0) end)   -- TargetCharacter
        log(string.format("BDUMP cursor#%d vis=%s cv=%s target=%s", i, tostring(M.wvis(w)), tostring(cv), tostring(tn)))
    end)
    each("BattleEnemyStatus_C", function(w, i)
        local sh, en, nweak
        pcall(function() sh = M.wtext(w.BreakStatusIcon.Text_BreakGauge) end)
        pcall(function() en = string.format("%X", M.peekp(w, 0x2C8) or 0) end)   -- Enemy
        pcall(function() nweak = w.EnableWeakIconNum end)
        local weaks = {}
        for k = 0, 4 do
            pcall(function()
                local ic = w["WeakStatusIcon_0" .. k]
                local res = M.icon_tex(ic, 0x248) or "?"   -- AttributeIcon
                weaks[#weaks + 1] = string.format("%d:a%s o%s l%s s%s v%s %s", k, tostring(ic.AttributeIndex),
                    tostring(ic.IconOpened), tostring(ic.WeakLocked), tostring(ic.IsSetup), tostring(M.wvis(ic)), res)
            end)
        end
        log(string.format("BDUMP enemy#%d vis=%s name=%s shield=%s weakN=%s enemy=%s | %s", i, tostring(M.wvis(w)),
            tostring(M.wtext(w.characterName)), tostring(sh), tostring(nweak), tostring(en), table.concat(weaks, " | ")))
    end)
    each("BattleSelectPlayerStatus_C", function(w, i)
        local dead
        pcall(function() dead = w.IsDead end)
        local g = {}
        for k = 0, 5 do
            pcall(function()
                local gp = w["Gauge0" .. k]
                g[#g + 1] = string.format("%d:e%s m%s v%s", k, tostring(gp.BoostEnable), tostring(gp.BoostMax), tostring(M.wvis(gp)))
            end)
        end
        log(string.format("BDUMP player#%d vis=%s name=%s hp=%s/%s sp=%s/%s dead=%s | %s", i, tostring(M.wvis(w)),
            tostring(M.wtext(w.CharaName)), tostring(M.wtext(w.TextHPValue)), tostring(M.wtext(w.TextHPMaxValue)),
            tostring(M.wtext(w.TextMPValue)), tostring(M.wtext(w.TextMPMaxValue)), tostring(dead), table.concat(g, " ")))
    end)
    each("BattleActionInfo_C", function(w, i)
        log(string.format("BDUMP action#%d vis=%s name=%s", i, tostring(M.wvis(w)), tostring(M.wtext(w.CommandName))))
    end)
    each("BuffIcon_C", function(w, i)   -- status icons: texture, turns, visibility
        local res, inn = M.icon_tex(w, 0x258), nil   -- StateIcon
        pcall(function() inn = w.IconIN end)
        if res then
            log(string.format("BDUMP buff#%d vis=%s in=%s %s turns=%s", i, tostring(M.wvis(w)), tostring(inn),
                tostring(res), tostring(M.wtext(w.TurnNum))))
        end
    end)
    each("ActionOrderTimeLine_C", function(w, i)
        local icons = {}
        for k = 0, 5 do
            pcall(function()
                local ic = w["InterceptIcon_0" .. k]
                local ca, en, br, nx = 0, nil, nil, nil
                pcall(function() ca = M.peekp(ic, 0x288) or 0 end)   -- Character
                pcall(function() en, br, nx = ic.EnableActionOrder, ic.IsBreak, ic.IsNextOrder end)
                icons[#icons + 1] = string.format("%d:%X e%s b%s n%s v%s", k, ca, tostring(en), tostring(br), tostring(nx),
                    tostring(M.wvis(ic)))
            end)
        end
        log(string.format("BDUMP order#%d vis=%s | %s", i, tostring(M.wvis(w)), table.concat(icons, " | ")))
    end)
    each("ActionOrderIcon_C", function(w, i)
        local ca, en, nx, fade = 0, nil, nil, nil
        pcall(function() ca = M.peekp(w, 0x288) or 0 end)   -- Character
        pcall(function() en, nx, fade = w.EnableActionOrder, w.IsNextOrder, w.IsFade end)
        if ca ~= 0 then
            local ol, sel
            pcall(function() ol = M.wvis(w.ThisTurnOutline) end)
            pcall(function() sel = M.wvis(w.SelecterEffect) end)
            log(string.format("BDUMP orderIcon#%d vis=%s char=%X e%s n%s fade%s outline=%s sel=%s", i, tostring(M.wvis(w)),
                ca, tostring(en), tostring(nx), tostring(fade), tostring(ol), tostring(sel)))
        end
    end)
    each("BattleCommandBoostHelp_C", function(w, i)
        log(string.format("BDUMP boosthelp#%d vis=%s boost=%s L=%s R=%s", i, tostring(M.wvis(w)),
            tostring(M.wtext(w.BoostText)), tostring(M.wtext(w.BtL_Text)), tostring(M.wtext(w.BtR_Enable_Text))))
    end)
    each("BattleResultPanelWidget_C", function(w, i)
        local ro, st, ex, jp, mo
        pcall(function() ro, st, ex, jp, mo = w.ResultOpen, w.State, w.GetTotalExp, w.GetTotalJobPoint, w.GetTotalMoney end)
        log(string.format("BDUMP result#%d vis=%s open=%s state=%s exp=%s jp=%s money=%s", i, tostring(M.wvis(w)),
            tostring(ro), tostring(st), tostring(ex), tostring(jp), tostring(mo)))
    end)
    local _, cls = M.get_active_screen()
    log("BDUMP active screen: " .. tostring(cls))
end
pcall(RegisterKeyBind, Key.F3, { ModifierKey.CONTROL }, function() M.in_gt(function() pcall(M.battle_dump) end) end)

-- Exploration dump of the main menu's lists (Ctrl+F5, game thread): every ListWidget_C
-- (inventory, abilities, ... share it) with cursor, category tabs and the visible rows'
-- text columns; the item detail, footer help, help window and the abilities screen's
-- state. Widgets and texts only -- no object pointers of characters.
M.menu_dump = function()
    local function each(cls, fn)
        local list
        pcall(function() list = FindAllOf(cls) end)
        if not list then log("MDUMP " .. cls .. ": none"); return end
        for i, w in ipairs(list) do
            local ok = false
            pcall(function() ok = w:IsValid() end)
            if ok then pcall(fn, w, i) end
        end
    end
    each("ListWidget_C", function(w, i)
        local act, en, cur, ccur, usecat, catsel
        pcall(function() act, en, cur = w.ActiveFlag, w.EnableCursor, w.CursorPosition end)
        pcall(function() ccur, usecat, catsel = w.CategoryCursorPos, w.UseCategory, w.CategorySelect end)
        local rows, cats = {}, {}
        pcall(function()
            w.ItemWidgetList_ActiveItems:ForEach(function(k, e)
                local r = e:get()
                local idx, st, cv
                pcall(function() idx, st = r.IndexInAll, r.ItemStatus end)
                pcall(function() cv = M.wvis(r.RefIcon_Cursor) end)
                rows[#rows + 1] = string.format("%s:%s|%s|%s|%s i%s s%s c%s", tostring(k), tostring(M.wtext(r.RefText_Col1)),
                    tostring(M.wtext(r.RefText_Col2)), tostring(M.wtext(r.RefText_Col3)), tostring(M.wtext(r.RefText_Unit)),
                    tostring(idx), tostring(st), tostring(cv))
            end)
        end)
        pcall(function()
            w.CategoryWidgetList:ForEach(function(k, e)
                local c = e:get()
                local t, cv, ln, nn, ht, id, gt
                pcall(function() t = c.CategoryText:ToString() end)
                pcall(function() cv = M.wvis(c.CurcorIcon) end)
                pcall(function() ln = c.ListNameText:ToString() end)
                pcall(function() nn = c.ListNumText:ToString() end)
                pcall(function() ht = c.CategoryHelpText:ToString() end)
                pcall(function() id = c.CategoryId end)
                pcall(function()
                    local idx = c.CategoryGameTextID:GetComparisonIndex()
                    if idx and idx > 0 and shim and shim.GameTextFName then gt = shim.GameTextFName(idx) end
                end)
                cats[#cats + 1] = string.format("%s:[%s|%s|%s|%s|id%s|gt %s] c%s", tostring(k), tostring(t), tostring(ln),
                    tostring(nn), tostring(ht), tostring(id), tostring(gt), tostring(cv))
            end)
        end)
        log(string.format("MDUMP list#%d vis=%s act=%s en=%s cur=%s cat=%s usecat=%s catsel=%s | cats: %s | rows: %s", i,
            tostring(M.wvis(w)), tostring(act), tostring(en), tostring(cur), tostring(ccur), tostring(usecat), tostring(catsel),
            table.concat(cats, ", "), table.concat(rows, " ; ")))
    end)
    each("ListItemDetailWidget_C", function(w, i)
        log(string.format("MDUMP detail#%d vis=%s text=%s", i, tostring(M.wvis(w)), tostring(M.wtext(w.KSTextBlock_0))))
    end)
    each("MenuFooter_C", function(w, i)
        local ho
        pcall(function() ho = w.HelpOpen end)
        log(string.format("MDUMP footer#%d vis=%s open=%s help=%s", i, tostring(M.wvis(w)), tostring(ho), tostring(M.wtext(w.HelpText))))
    end)
    each("HelpWindowWBP_C", function(w, i)
        log(string.format("MDUMP helpwin#%d vis=%s text=%s", i, tostring(M.wvis(w)), tostring(M.wtext(w.HelpText))))
    end)
    each("MainMenuSubItemPanel_C", function(w, i)
        local cv, un
        pcall(function() cv = M.wvis(w.CursorIcon) end)
        pcall(function() un = w.IsUnEnable end)
        log(string.format("MDUMP sub#%d vis=%s text=%s cur=%s un=%s", i, tostring(M.wvis(w)), tostring(M.wtext(w.MenuText)),
            tostring(cv), tostring(un)))
    end)
    each("MainMenuAbilityWidget_C", function(w, i)
        local st, sub, cmd, cost
        pcall(function() st, sub, cmd, cost = w.State, w.ShowSubJobList, w.SubMenuSelectCommand, w.AcquisitionJPCost end)
        log(string.format("MDUMP ability#%d vis=%s state=%s showsub=%s subcmd=%s jp=%s", i, tostring(M.wvis(w)), tostring(st),
            tostring(sub), tostring(cmd), tostring(cost)))
    end)
    each("SupportAbilityWidget_C", function(w, i)
        local lf, hv
        pcall(function() lf, hv = w.ListFocus, w.HelpVisible end)
        local slots = {}
        for k = 0, 3 do
            pcall(function()
                local s = w["SupportAbilityWidget0" .. k]
                local cv
                pcall(function() cv = M.wvis(s.CursorIcon) end)
                slots[#slots + 1] = string.format("%d:%s c%s v%s", k, tostring(M.wtext(s.Column1_Text)), tostring(cv),
                    tostring(M.wvis(s)))
            end)
        end
        local labels = {}
        pcall(function()
            w.EquipSkillDetailLabel:ForEach(function(k, e)
                local c, txt
                pcall(function() c = e:get():GetComparisonIndex() end)
                txt = c and M.gametext(c, 0)
                labels[#labels + 1] = tostring(k) .. "=" .. tostring(c) .. ":" .. tostring(txt)
            end)
        end)
        local col
        pcall(function() col = M.wtext(w.ListColumn.Column1_Title) end)
        log(string.format("MDUMP support#%d vis=%s focus=%s help=%s col=%s | slots: %s | labels: %s", i,
            tostring(M.wvis(w)), tostring(lf), tostring(hv), tostring(col), table.concat(slots, " ; "),
            table.concat(labels, " ; ")))
    end)
    each("SupportAbilityChangeWidget_C", function(w, i)
        local f = {}
        for _, k in ipairs({ "State", "SelectCategoryIndex", "Current", "IsCursorUpdate", "ConfirmNextState",
            "LastSelectJobScene", "SubJobConfirmReturn", "ChangeLanguage" }) do
            local v
            pcall(function() v = w[k] end)
            f[#f + 1] = k .. "=" .. tostring(v)
        end
        local cats = {}
        pcall(function()
            w.CategoryWidgetList:ForEach(function(k, e)
                local c = e:get()
                local t, cv, ln, nn, id, face
                pcall(function() t = c.CategoryText:ToString() end)
                pcall(function() cv = M.wvis(c.CurcorIcon) end)
                pcall(function() ln = c.ListNameText:ToString() end)
                pcall(function() nn = c.ListNumText:ToString() end)
                pcall(function() id, face = c.CategoryId, c.IsMemberFace end)
                cats[#cats + 1] = string.format("%s:[%s|%s|%s|id%s face=%s] c%s v%s", tostring(k), tostring(t), tostring(ln),
                    tostring(nn), tostring(id), tostring(face), tostring(cv), tostring(M.wvis(c)))
            end)
        end)
        local n = { cur = 0, acq = 0, items = 0 }
        pcall(function() w.CurrentSupportAbilityList:ForEach(function() n.cur = n.cur + 1 end) end)
        pcall(function() w.AcquisitionSupportAbility:ForEach(function() n.acq = n.acq + 1 end) end)
        pcall(function() w.SupportListItem:ForEach(function() n.items = n.items + 1 end) end)
        local sl, sw = nil, nil
        pcall(function() sl = M.addr_of(w.SupportAbilitySelectList) end)
        pcall(function() sw = M.addr_of(w.SupportAbilityWidget) end)
        log(string.format("MDUMP supportchange#%d vis=%s %s title=%s cur=%d acq=%d items=%d list=%X slots=%X | cats: %s", i,
            tostring(M.wvis(w)), table.concat(f, " "), tostring(M.wtext(w.TitleText)), n.cur, n.acq, n.items, sl or 0,
            sw or 0, table.concat(cats, ", ")))
        local ps = {}
        pcall(function()
            local pl = w.ListItemParamWidget
            for k = 1, 10 do
                local p
                pcall(function() p = pl[(k == 10) and "param_10" or string.format("Param_%02d", k)] end)
                if p then
                    local vb, va
                    pcall(function() vb, va = p.ValueBefore, p.ValueAfter end)
                    ps[#ps + 1] = string.format("%s:%s>%s(%s>%s) v%s", tostring(M.wtext(p.ParamName)),
                        tostring(M.wtext(p.ParamBefore)), tostring(M.wtext(p.ParamAfter)), tostring(vb), tostring(va),
                        tostring(M.wvis(p)))
                end
            end
        end)
        log("MDUMP supportchange params: " .. table.concat(ps, " ; "))
    end)
    each("MainMenuItemListWidget_C", function(w, i)
        local un, tn
        pcall(function() un = w.UseItemName:ToString() end)
        pcall(function() tn = w.TargetCharacterName:ToString() end)
        log(string.format("MDUMP itemscreen#%d vis=%s use=%s target=%s", i, tostring(M.wvis(w)), tostring(un), tostring(tn)))
    end)
    each("EquipmentMenuWidget_C", function(w, i)
        local f = {}
        for _, k in ipairs({ "IsActive", "IsPushedCenterList", "IsPushedRightList", "CurrentCursorEquipPart",
            "SelectedEquipPart", "RightListState", "SelectedCharacterID", "IsBarMode" }) do
            local v
            pcall(function() v = w[k] end)
            f[#f + 1] = k .. "=" .. tostring(v)
        end
        local ce, cl, rl = nil, nil, nil
        pcall(function() ce = M.wtext(w.EqpCharacterList.TextEqp) end)
        pcall(function() cl = M.addr_of(w.ListEqp_Center) end)
        pcall(function() rl = M.addr_of(w.ListEqp_Right) end)
        log(string.format("MDUMP equip#%d vis=%s %s char=%s center=%X right=%X", i, tostring(M.wvis(w)),
            table.concat(f, " "), tostring(ce), cl or 0, rl or 0))
        local ps = {}
        pcall(function()
            local pl = w.EqpParamList
            for n = 1, 10 do
                local p
                pcall(function() p = pl[(n == 10) and "param_10" or string.format("Param_%02d", n)] end)
                if p then
                    local vb, va
                    pcall(function() vb, va = p.ValueBefore, p.ValueAfter end)
                    ps[#ps + 1] = string.format("%s:%s>%s(%s>%s) v%s", tostring(M.wtext(p.ParamName)),
                        tostring(M.wtext(p.ParamBefore)), tostring(M.wtext(p.ParamAfter)), tostring(vb), tostring(va),
                        tostring(M.wvis(p)))
                end
            end
        end)
        log("MDUMP equip params: " .. table.concat(ps, " ; "))
    end)
    each("PartyCharacterList_C", function(w, i)
        local cp, open, valid
        pcall(function() cp, open, valid = w.CursorPosition, w.IsOpen, w.ValidListNum end)
        local mem = {}
        for k = 0, 3 do
            pcall(function()
                local pc = w["PartyCharacter_0" .. k]
                local cv
                pcall(function() cv = M.wvis(pc.CursorIcon) end)
                mem[#mem + 1] = string.format("%d:%s c%s", k, tostring(M.ml_member(pc)), tostring(cv))
            end)
        end
        log(string.format("MDUMP party#%d vis=%s cur=%s open=%s valid=%s caption=%s | %s", i, tostring(M.wvis(w)), tostring(cp),
            tostring(open), tostring(valid), tostring(M.wtext(w.CaptionText)), table.concat(mem, " ; ")))
    end)
    -- the status screen and the journal (2026-11-18): what their readers see
    each("StatusMenuWidget_C", function(w, i)
        local idx, num
        pcall(function() idx, num = w.SelectedCharacterIndex, w.CategoryDisplayedNum end)
        local okl, head, rest = pcall(M.status_lines, w)
        log(string.format("MDUMP status#%d vis=%s idx=%s num=%s | %s | %s", i, tostring(M.wvis(w)), tostring(idx),
            tostring(num), tostring(okl and head), tostring(okl and rest)))
    end)
    each("MainMenuMissionRecord_C", function(w, i)
        local st, pos, mainm, idx
        pcall(function() st, pos, mainm, idx = w.Status, w.SelectPos, w.IsOpenMainMission, w.MissionListSelectIdx end)
        local gs = {}
        pcall(function()
            w.GaugeList:ForEach(function(k, e)
                local g = e:get()
                local pct, un
                pcall(function() pct, un = g.MaxGaugePercent, g.IsUnEnable end)
                gs[#gs + 1] = string.format("%d:%s %s%s", k, tostring(M.wtext(g.GaugeText)), tostring(pct), un and " off" or "")
            end)
        end)
        local cap, help
        pcall(function() cap = M.wtext(w.TmpHeaderUI.CaptionText) end)
        pcall(function() help = M.wtext(w.TmpFooterUI.HelpText) end)
        local okt, jt = pcall(M.journal_text, w)
        local okk, keys = pcall(M.footer_guides, w.TmpFooterUI)
        log(string.format("MDUMP journal#%d vis=%s status=%s pos=%s main=%s listidx=%s caption=%s help=%s keys=%s text=%s | %s",
            i, tostring(M.wvis(w)), tostring(st), tostring(pos), tostring(mainm), tostring(idx), tostring(cap), tostring(help),
            tostring(okk and keys), tostring(okt and jt), table.concat(gs, " ; ")))
    end)
    -- every VISIBLE text block of the menu screens, with its path (where a title lives)
    for _, tcls in ipairs({ "TextBlock", "KSTextBlock" }) do
        local list
        pcall(function() list = FindAllOf(tcls) end)
        for _, t in ipairs(list or {}) do
            local ok = false
            pcall(function() ok = t:IsValid() end)
            if ok then
                local v = M.wvis(t)
                local s = (v == 0 or v == 3 or v == 4) and M.wtext(t) or nil
                if s and not M.placeholder(s) then
                    local full = ""
                    pcall(function() full = t:GetFullName() end)
                    if (full:find("MainMenu") and not full:find("MainMenuList")) or full:find("HelpWindow")
                        or full:find("Equipment") or full:find("SupportAbility") or full:find("MenuFooter") then
                        local short = (full:gsub("^.-PersistentLevel%.", ""):gsub("WidgetTree%.", ""))
                        log(string.format("MDUMP text %s = %s", short, s))
                    end
                end
            end
        end
    end
    local _, cls = M.get_active_screen()
    log("MDUMP active screen: " .. tostring(cls))
end
pcall(RegisterKeyBind, Key.F5, { ModifierKey.CONTROL }, function() M.in_gt(function() pcall(M.menu_dump) end) end)

-- MAIN MENU LISTS (2026-11-14): the inventory ("Inventar") and "Fertigkeiten erlernen"
-- -- and other main-menu screens -- share ListWidget_C (seen in-game with the MDUMP):
--   ActiveFlag + visible: the list in use. UseCategory + CategorySelect: the cursor is
--   on the tabs on the left (CategoryCursorPos; inventory: 10 icon tabs, abilities: one
--   per traveler); the tabs have no text, the list's TitleText names the tab ("Alles",
--   "Cyrus"). Otherwise in the rows (ItemWidgetList_ActiveItems, ListItemWidget_C):
--   RefText_Col1 name, RefText_Col2 count, ItemStatus 1 = greyed out, the row whose
--   RefIcon_Cursor shows is the focused one (CursorPosition as a fallback).
--   The description: HelpWindowWBP_C.HelpText while it shows.
-- Which screen: the owner's list property (MainMenuItemListWidget_C.ListWidget,
-- MainMenuAbilityWidget_C.MainJobAbilityAcquisitionListWidget) has the same address.
M.ml = {}
-- FindAllOf walks every object (~50 ms on the game thread), so a list it found is kept
-- while all of it stays valid; an empty one is searched again after 3 s. Cleared when
-- the menu closes (M.menu_lists_tick).
M.ml_cache = {}
M.ml_list = function(cls)
    local c, now = M.ml_cache[cls], os.clock()
    if c then
        if #c.l == 0 then
            if now - c.t < 3 then return c.l end
        else
            -- (each kept widget's handle first: the shim's reads, then UE4SS's IsValid)
            local all = true
            for i = 1, #c.l do
                if not M.kept(c.h[i]) then all = false; break end
            end
            if all then return c.l end
        end
    end
    local l, hs = {}, {}
    pcall(function()
        for _, w in ipairs(FindAllOf(cls) or {}) do
            local ok = false
            pcall(function() ok = w:IsValid() end)
            local h = ok and M.handle(w)
            if h then l[#l + 1] = w; hs[#hs + 1] = h end
        end
    end)
    M.ml_cache[cls] = { t = now, l = l, h = hs }
    return l
end
-- "items" / "abilities" / "equip" / nil, with the owner widget and which of its lists.
-- The owner is the list's outer's outer (owner -> WidgetTree -> list), so no object
-- search is needed; the FindAllOf search below is only the fallback.
M.ml_screen = function(addr, w)
    local owner, cls
    if w then
        pcall(function() owner = w:GetOuter():GetOuter() end)
        if owner then pcall(function() cls = class_name_of(owner) end) end
    end
    if cls then
        local function is(prop)
            local a
            pcall(function() a = M.addr_of(owner[prop]) end)
            return a == addr
        end
        if cls == "MainMenuItemListWidget_C" and is("ListWidget") then return "items", owner end
        if cls == "MainMenuAbilityWidget_C" then
            if is("MainJobAbilityAcquisitionListWidget") then return "abilities", owner, "main" end
            if is("SubJobAbilityAcquisitionListWidget") then return "abilities", owner, "sub" end
            -- the support screen's learned list lives here too (ChangeSupportSkillListWidget
            -- = SupportAbilityChangeWidget.SupportAbilitySelectList); its owner is that screen
            if is("ChangeSupportSkillListWidget") then
                local sw
                pcall(function() sw = owner.SupportAbilityChangeWidget end)
                if sw then return "support", sw end
            end
        end
        if cls == "EquipmentMenuWidget_C" then
            if is("ListEqp_Center") then return "equip", owner, "center" end
            if is("ListEqp_Right") then return "equip", owner, "right" end
        end
        if cls == "ShopMenuWidget_C" and is("ProductList") then return "shop", owner end
        if cls == "SupportAbilityChangeWidget_C" and is("SupportAbilitySelectList") then return "support", owner end
        if cls == "MainMenuMissionRecord_C" and is("ListWidget") then return "journal", owner end
        return nil   -- another screen's list (read plainly)
    end
    for _, o in ipairs(M.ml_list("MainMenuItemListWidget_C")) do
        local a
        pcall(function() a = M.addr_of(o.ListWidget) end)
        if a == addr then return "items", o end
    end
    for _, o in ipairs(M.ml_list("MainMenuAbilityWidget_C")) do
        local a1, a2
        pcall(function() a1 = M.addr_of(o.MainJobAbilityAcquisitionListWidget) end)
        pcall(function() a2 = M.addr_of(o.SubJobAbilityAcquisitionListWidget) end)
        if a1 == addr then return "abilities", o, "main" end
        if a2 == addr then return "abilities", o, "sub" end
    end
    for _, o in ipairs(M.ml_list("EquipmentMenuWidget_C")) do
        local a1, a2
        pcall(function() a1 = M.addr_of(o.ListEqp_Center) end)
        pcall(function() a2 = M.addr_of(o.ListEqp_Right) end)
        if a1 == addr then return "equip", o, "center" end
        if a2 == addr then return "equip", o, "right" end
    end
    return nil
end
-- The equipment screen's stat table (EqpParamList.Param_01..09 + param_10, each a
-- ParamBeforeAfterWBP_C with ParamName and the ints ValueBefore/ValueAfter): what the
-- focused item would change -- "Phys. Vert. 82 to 103, Tempo 77 to 99" -- or nil. The
-- support-ability screen has the same table as ListItemParamWidget (prop).
M.eq_changes = function(owner, prop)
    local pl
    pcall(function() pl = owner[prop or "EqpParamList"] end)
    if not pl then return nil end
    local out = {}
    for n = 1, 10 do
        local p, vb, va
        pcall(function() p = pl[(n == 10) and "param_10" or string.format("Param_%02d", n)] end)
        if p then pcall(function() vb, va = p.ValueBefore, p.ValueAfter end) end
        if type(vb) == "number" and type(va) == "number" and vb ~= va then
            local name = M.wtext(p.ParamName)
            if name and not M.placeholder(name) then
                out[#out + 1] = trf("%s %d to %d", name, vb, va)
            end
        end
    end
    return #out > 0 and table.concat(out, ", ") or nil
end
M.ml_help = function()
    for _, h in ipairs(M.ml_list("HelpWindowWBP_C")) do
        if M.wvis(h) == 0 then
            local s = M.wtext(h.HelpText)
            if s and not M.placeholder(s) then return M.join_text({ s }) end
        end
    end
    return nil
end
-- The abilities screen's support-skill rows under the list (no cursor goes there):
-- MainJobListBottomParts (or SubJob...) .SupportAbility01..04.Column1_Text, caption
-- ListCaption.Column1_Title. Rows that differ only in their number are merged:
-- "Hilfsfertigkeiten: Hierfür 4, 5, 6, 7 Fertigkeiten freischalten."
M.ml_support = function(owner, which)
    local bp
    pcall(function() bp = (which == "sub") and owner.SubJobListBottomParts or owner.MainJobListBottomParts end)
    if not bp then return nil end
    local items = {}
    for i = 1, 4 do
        local r
        pcall(function() r = bp["SupportAbility0" .. i] end)
        local v = r and M.wvis(r)
        if r and v ~= 1 and v ~= 2 then
            local t = M.wtext(r.Column1_Text)
            if not t then pcall(function() t = M.wtext(r.RefText_Col1) end) end
            if t and not M.placeholder(t) then items[#items + 1] = t end
        end
    end
    if #items == 0 then return nil end
    local out, i = {}, 1
    while i <= #items do
        local tmpl = items[i]:gsub("%d+", "#")
        local nums = { items[i]:match("%d+") }
        local j = i + 1
        while j <= #items and items[j]:gsub("%d+", "#") == tmpl do
            nums[#nums + 1] = items[j]:match("%d+")
            j = j + 1
        end
        if j - i > 1 and #nums == j - i and select(2, tmpl:gsub("#", "")) == 1 then
            out[#out + 1] = (tmpl:gsub("#", table.concat(nums, ", ")))
        else
            for k = i, j - 1 do out[#out + 1] = items[k] end
        end
        i = j
    end
    local cap
    pcall(function() cap = M.wtext(bp.ListCaption.Column1_Title) end)
    if cap and M.placeholder(cap) then cap = nil end
    return (cap and (cap .. ": ") or "") .. M.join_text(out)
end
-- A weapon or armor in a shop: the party panels on the right (ShopMenuWidget_C.PartsPartyList
-- .PartyCharacter_00..03, PartyCharacterPanel_C) switch to VBox_Equip and show what the piece
-- would change, row N = EquipNameN with EquipParamN_0 (now) and EquipParamN_1 (with it), in
-- EquipParamN_Top (screenshot 2026-11-15: "Cyrus  Phys. Angr. 78 > 85, Elem. Angr. 122 >
-- 138, Kritisch 70 > 68"; for a glaive Cyrus can't use only the name showed: "can't equip").
-- "Cyrus: Phys. Angr. 78 to 85, Elem. Angr. 122 to 138, Kritisch 70 to 68"
-- one party panel (PartyCharacterPanel_C): "Cyrus: Phys. Angr. 78 to 85, ...", "Cyrus: can't
-- equip", or nil (hidden / no name / not showing equipment); and a short log form
M.shop_member_line = function(pc)
    local v = pc and M.wvis(pc)
    if not pc or v == 1 or v == 2 then return nil end
    local name = M.wtext(pc.Name)
    if not name or M.placeholder(name) then return nil end
    local eqv
    pcall(function() eqv = M.wvis(pc.VBox_Equip) end)
    local rows = {}
    for n = 0, 3 do
        local top, tv
        pcall(function() top = pc["EquipParam" .. n .. "_Top"] end)
        tv = top and M.wvis(top)
        if top and tv ~= 1 and tv ~= 2 then
            local nm, a, b
            pcall(function()
                nm = M.wtext(pc["EquipName" .. n])
                a, b = M.wtext(pc["EquipParam" .. n .. "_0"]), M.wtext(pc["EquipParam" .. n .. "_1"])
            end)
            if nm and a and b and not M.placeholder(a) and not M.placeholder(nm) then
                rows[#rows + 1] = (a == b) and (nm .. " " .. a) or trf("%s %s to %s", nm, a, b)
            end
        end
    end
    local raw = string.format("%s equip=%s rows=%d", name, tostring(eqv), #rows)
    -- a piece the traveler can't use shows only the name (a glaive for Cyrus); one they
    -- can use shows its rows (two shields: 2 and 1 rows)
    if eqv == 1 or eqv == 2 then return nil, raw end
    return name .. ": " .. (#rows > 0 and table.concat(rows, ", ") or tr("can't equip")), raw
end
M.shop_party_changes = function(owner)
    local pl
    pcall(function() pl = owner.PartsPartyList end)
    if not pl then return nil end
    local out, raw = {}, {}
    for k = 0, 3 do
        local pc
        pcall(function() pc = pl[string.format("PartyCharacter_%02d", k)] end)
        local ok, line, r = pcall(M.shop_member_line, pc)
        if ok then
            if r then raw[#raw + 1] = r end
            if line then out[#out + 1] = line end
        end
    end
    local key = table.concat(raw, "; ")
    if key ~= M.shop_party_logged then M.shop_party_logged = key; log("SHOP party: " .. key) end
    return #out > 0 and table.concat(out, ". ") or nil
end
-- QUICK EQUIP after a purchase (user 2026-11-16: "Quarzrute sofort ausrüsten?" -> Ja, then
-- nothing was read). ShopMenuWidget_C's own state (KSUserWidgetWithState GetCurrentState;
-- ESHOPMENU_STATE, names from the asset's DisplayNameMap in enumerator order, the order
-- checked against ESHOPMENU_MODE's known commands): 10 = eSHOP_QUICK_EQUIP_CONFIRM (the
-- question, a dialog), 11 = eSHOP_QUICK_EQUIPMENT = choosing who gets it. The traveler under
-- the cursor: the party panel (PartsPartyList.PartyCharacter_0N) whose CursorIcon shows,
-- else QcEqp_CursorPos; said as in the goods list ("Cyrus: Phys. Angr. 83 to 94, ...").
M.SHOP_QUICK_EQUIP = 11
M.shop_quick_equip = function(w, sh)
    local pl
    pcall(function() pl = w.PartsPartyList end)
    if not pl then return end
    local pos, cnt, own
    pcall(function() pos = w.QcEqp_CursorPos end)
    pcall(function() cnt = w.QcEqp_EnableEquipCount end)
    pcall(function() own = w.QcEqp_PossessCount end)
    local focus, icons = nil, {}
    for k = 0, 3 do
        local pc, cv
        pcall(function() pc = pl[string.format("PartyCharacter_%02d", k)] end)
        if pc then pcall(function() cv = M.wvis(pc.CursorIcon) end) end
        icons[#icons + 1] = tostring(cv)
        if cv == 0 or cv == 3 or cv == 4 then focus = focus or k end
    end
    local k = focus or (type(pos) == "number" and pos) or nil
    local key = tostring(k) .. "|" .. tostring(pos)
    if key == sh.qe then return end
    local first = sh.qe == nil
    sh.qe = key
    log(string.format("SHOP quick equip: cursor icons [%s] QcEqp_CursorPos=%s enable=%s own=%s -> panel %s",
        table.concat(icons, " "), tostring(pos), tostring(cnt), tostring(own), tostring(k)))
    local line
    if type(k) == "number" and k >= 0 and k <= 3 then
        local pc
        pcall(function() pc = pl[string.format("PartyCharacter_%02d", k)] end)
        local ok, l = pcall(M.shop_member_line, pc)
        line = ok and l or nil
    end
    if first then
        speak(tr("Equip it: choose a traveler") .. (line and (". " .. line) or ""), true)
    elseif line then
        M.say_item(line)
    end
end
-- SUPPORT ABILITIES ("Hilfsfertigkeiten ausrüsten", SupportAbilityChangeWidget_C; seen
-- in game 2026-11-16 -- the user: "not read yet"). Its State: 2 = choosing the traveler
-- (face tabs, SelectCategoryIndex; the name in TitleText), 9 = choosing one of the four
-- slots, 10 = the learned list (SupportAbilitySelectList, a ListWidget_C) has the cursor.
-- The slots: SupportAbilityWidget (SupportAbilityWidget_C) .SupportAbilityWidget00..03
-- (Column1_Text "Keine" / the skill), ListFocus = the slot, and EquipSkillDetailLabel
-- (TArray<FName> at +0x248, read raw: the labels carry a number, BT_ABI_DETAIL_249) =
-- each slot's description, EQUIPMENT_EMPTY_HELP for an empty one. In state 9 the learned
-- list is already active and visible, without a cursor: the plain list reader said its
-- first row then. After a choice the game moves on to the next free slot, the list stays.
M.support_slots = function(sw)
    local sa
    pcall(function() sa = sw.SupportAbilityWidget end)
    if not sa then return nil end
    local slots, focus = {}, 0
    pcall(function() focus = sa.ListFocus end)
    for k = 0, 3 do
        local s
        pcall(function() s = sa["SupportAbilityWidget0" .. k] end)
        local t = s and M.wtext(s.Column1_Text)
        if not t or M.placeholder(t) then return nil end
        slots[#slots + 1] = { name = t }
    end
    -- the descriptions, and which slots are empty
    local a = M.addr_of(sa)
    local data = a and shim and shim.Peek(a + 0x248, "ptr")
    local n = a and shim and shim.Peek(a + 0x250, "i32")
    local ec = M.fname_of("EQUIPMENT_EMPTY_HELP")
    if data and data ~= 0 and n == #slots and shim.PeekFName then
        for i = 1, n do
            local c, num = shim.PeekFName(data + (i - 1) * 8)
            if c and c > 0 then
                slots[i].empty = (c == ec and num == 0)
                slots[i].help = M.gametext(c, num)
            end
        end
    end
    return slots, focus, sa
end
-- the four slots in one line: "Ausgerüstete Hilfsfertigkeiten: Ausweichmanöver, 3 free
-- slots" ("...: Keine" when none is used)
M.support_slots_text = function(slots, sa)
    local used, free, known = {}, 0, true
    for _, s in ipairs(slots) do
        if s.empty == nil then known = false
        elseif s.empty then free = free + 1
        else used[#used + 1] = s.name end
    end
    local list
    if not known then
        local same = true
        for i = 2, #slots do if slots[i].name ~= slots[1].name then same = false end end
        local names = {}
        for _, s in ipairs(slots) do names[#names + 1] = s.name end
        list = same and slots[1].name or table.concat(names, ", ")
    elseif #used == 0 then
        list = slots[1].name   -- the game's own word for an empty slot ("Keine")
    else
        list = table.concat(used, ", ")
        if free > 0 then list = list .. ", " .. trn("%d free slot", "%d free slots", free) end
    end
    local cap
    pcall(function() cap = M.wtext(sa.ListColumn.Column1_Title) end)
    if cap and not M.placeholder(cap) then return cap .. ": " .. list end
    return list
end
-- A key the footer offers, by its GameText label: "Ⓛ: Entfernen" (speak() says the key
-- cap as "L"), or nil. The footer copies with placeholder texts are skipped by the text.
M.footer_hint = function(label)
    local want = M.gt_label(label)
    if not want then return nil end
    for _, f in ipairs(M.ml_list("MenuFooter_C")) do
        local v = M.wvis(f)
        if v == 0 or v == 3 or v == 4 then
            for k = 0, 7 do
                local it
                pcall(function() it = f["MenuGuideItem0" .. k] end)
                if not it then break end
                local t = M.wtext(it.GuideText_00)
                local iv = M.wvis(it)
                if t == want and (iv == 0 or iv == 3 or iv == 4) then
                    local g = M.wtext(it.ButtonGuideText_00)
                    if g and not M.placeholder(g) then return g .. ": " .. t end
                end
            end
        end
    end
    return nil
end
-- State 2 / 9: sig, line, help line (nil, nil: nothing to say)
M.support_line = function(sw, state, st)
    if state == 2 then
        local name = M.wtext(sw.TitleText)
        if not name or M.placeholder(name) then return nil end
        local idx, ntab = 0, 0
        pcall(function() idx = sw.SelectCategoryIndex end)
        pcall(function() sw.CategoryWidgetList:ForEach(function() ntab = ntab + 1 end) end)
        local say = name .. (ntab > 1 and trf(", tab %d of %d", idx + 1, ntab) or "")
        local slots, _, sa = M.support_slots(sw)
        st.sup_slot = nil
        return "UC" .. tostring(idx) .. ":" .. name, say, slots and M.support_slots_text(slots, sa) or nil
    elseif state == 9 then
        local slots, focus = M.support_slots(sw)
        local s = slots and slots[focus + 1]
        if not s then return nil end
        st.sup_slot = focus
        -- a used slot: its description, and the footer's key to take it off ("L:
        -- Entfernen", read when the help line is due: the footer follows the cursor). An
        -- empty slot's "you have nothing equipped here" only repeats the "Keine".
        local extra
        if not s.empty then
            extra = function()
                local parts = { s.help }
                parts[#parts + 1] = M.footer_hint("eMAINMENU_INPUT_GUIDE_REMOVE")
                return #parts > 0 and M.join_text(parts) or nil
            end
        elseif M.support_learned(sw) == 0 then
            -- nothing to choose (Ophilia, 2026-11-16: the list stays empty, Enter does nothing)
            extra = tr("No support skills learned yet")
        end
        return "US" .. tostring(focus) .. ":" .. s.name, trf("Slot %d of %d: %s", focus + 1, #slots, s.name), extra
    end
    return nil
end
-- how many skills the learned list shows (in State 9 it shows already), nil: unreadable
M.support_learned = function(sw)
    local n, ok = 0, false
    pcall(function()
        sw.SupportAbilitySelectList.ItemWidgetList_ActiveItems:ForEach(function(_, e)
            local t = M.wtext(e:get().RefText_Col1)
            if t and not M.placeholder(t) then n = n + 1 end
        end)
        ok = true
    end)
    return ok and n or nil
end
-- a party member panel (PartyCharacterPanel_C): "Cyrus, level 5, HP 259 of 284, SP 56 of 64"
M.ml_member = function(pc)
    local name = M.wtext(pc.Name)
    if not name or M.placeholder(name) then return nil end
    local s = name
    local lv = M.wtext(pc.LevelValue)
    if lv and not M.placeholder(lv) then s = trf("%s, level %s", s, lv) end
    local hp, hpm, sp, spm = M.wtext(pc.HPValue), M.wtext(pc.HPMax), M.wtext(pc.MPValue), M.wtext(pc.MPMax)
    if hp and hpm then s = trf("%s, HP %s of %s", s, hp, hpm) end
    if sp and spm then s = trf("%s, SP %s of %s", s, sp, spm) end
    return s
end
M.poll_menu_list = function()
    local st, now = M.ml, os.clock()
    -- choosing whom an item is for: the item screen itself is on top of the UI stack (the
    -- list below it), the party list on the right moves its CursorPosition
    -- (only right after an item row was chosen: backing out of the tabs also puts the
    -- item screen on top for a moment -- that once said "Cyrus, level 5, ..." in passing)
    local aw, top = M.get_active_screen()
    -- inside an event only the focused list itself, never the widget scans below
    if M.ev_now and not M.ev_list_ok(top) then return end
    -- a tutorial pop-up over the list (first visit): its reader speaks it; the list
    -- waits, or its header cut the tutorial text off
    if top == "UITutorial_C" then return end
    -- a confirm dialog over the list (learn a skill?): its reader speaks it; afterwards
    -- the row is said again, so you hear where you are (or "learned")
    if top == "UICommonDialogBP_C" then st.said, st.help_said = nil, nil; return end
    if top == "MainMenuItemListWidget_C" and (st.said or ""):match("^[RP]") then
        for _, o in ipairs(M.ml_list("MainMenuItemListWidget_C")) do
            local pl, cp = nil, 0
            pcall(function() pl = o.PartyList end)
            pcall(function() cp = pl.CursorPosition end)
            local pc
            pcall(function() pc = pl["PartyCharacter_0" .. (cp or 0)] end)
            local s = pc and M.ml_member(pc)
            if s then
                local sig = "P" .. s
                if sig ~= st.said then
                    st.said = sig
                    speak(s)
                end
                return
            end
        end
    end
    local w
    -- the support-ability screen reads its travelers and slots itself (its learned list is
    -- active meanwhile, without the cursor); in State 10 that list has the cursor
    if top == "SupportAbilityChangeWidget_C" and aw then
        local state
        pcall(function() state = aw.State end)
        if state ~= 10 then
            local sig, say, extra = M.support_line(aw, state, st)
            if sig then M.ml_speak(st, now, sig, say, extra, "support", nil, aw, true) end
            return
        end
        pcall(function() w = aw.SupportAbilitySelectList end)
    end
    -- the focused list itself, as GetActiveStack returns it: the equipment screen has two
    -- lists active at once (slots, items) and the scan below took the wrong one
    if not w and top == "ListWidget_C" and aw then w = aw end
    if not w then
        for _, l in ipairs(M.ml_list("ListWidget_C")) do
            local act = false
            pcall(function() act = l.ActiveFlag end)
            if act and M.wvis(l) == 0 then w = l; break end
        end
    end
    if not w then
        -- the abilities screen's little sub menu ("Fertigkeiten erlernen" / "Hilfs-
        -- fertigkeiten ausrüsten", the latter "???" until unlocked): State 2, the choice
        -- in SubMenuSelectCommand (the panels' cursor icons all read as shown)
        for _, o in ipairs(M.ml_list("MainMenuAbilityWidget_C")) do
            local state, cmd = nil, nil
            pcall(function() state, cmd = o.State, o.SubMenuSelectCommand end)
            if state == 2 and M.wvis(o) ~= 1 then
                local p
                pcall(function() p = cmd and o.SubMenuCommandAbility or o.SubMenuSupportAbility end)
                local t, un = p and M.wtext(p.MenuText), false
                pcall(function() un = p.IsUnEnable end)
                local s = (t == "???" or un) and "Locked" or (t or "?")
                local sig = "S" .. s
                if sig ~= st.said then st.said = sig; speak(s) end
                return
            end
        end
        st.said, st.help_said, st.first_at = nil, nil, nil
        return
    end
    local addr = M.addr_of(w)
    local scr, owner, which = M.ml_screen(addr, w)
    -- the goods stay active while the shop asks who gets what was just bought
    -- (M.shop_quick_equip reads that): no goods row then
    if scr == "shop" and M.shop_qe_on then return end
    local usecat, catsel, ccur, cur = false, false, 0, 0
    pcall(function() usecat, catsel, ccur, cur = w.UseCategory, w.CategorySelect, w.CategoryCursorPos, w.CursorPosition end)
    local sig, say, extra
    if usecat and catsel then
        local title = M.wtext(w.TitleText)
        local ntab = 0
        pcall(function() w.CategoryWidgetList:ForEach(function() ntab = ntab + 1 end) end)
        sig = string.format("C%X:%s:%s", addr or 0, tostring(ccur), tostring(title))
        say = (title or trf("Tab %d", ccur + 1)) .. (ntab > 1 and trf(", tab %d of %d", ccur + 1, ntab) or "")
        if scr == "abilities" then
            -- the traveler's job, LBP and the next skill's price (the list header)
            local hd
            pcall(function()
                hd = (which == "sub") and owner.SubJobAbilityListHeaderWidget or owner.MainJobAbilityListHeaderWidget
            end)
            if hd then
                local job, jp, cost = M.wtext(hd.TextMainJobName), M.wtext(hd.JobPoint), M.wtext(hd.AcquisitionJP)
                if job and not M.placeholder(job) then say = say .. ", " .. job end
                if jp and not M.placeholder(jp) and not jp:match("^9999") then say = say .. ", " .. jp .. " LBP" end
                if cost and not M.placeholder(cost) and not cost:match("^9999") then
                    say = trf("%s, next skill %s LBP", say, cost)
                end
            end
            -- the support-skill rows, as the "help" line after the header
            local okp, sp = pcall(M.ml_support, owner, which)
            if okp and sp then extra = sp end
        end
    else
        -- THE SHOP'S AMOUNT PICKER over its goods (user 2026-11-23: choosing an item to
        -- buy, the item above it was said -- "Spitzer Hut" for "Runder Schild", while the
        -- picker priced the right one). The goods list stays active under the picker
        -- (M.poll_shop reads the picker), and as Enter opens it the goods row loses its
        -- cursor icon: the fallback below named the row above. So the goods keep quiet
        -- while the picker shows, and say their row again once it is gone ("W": not the
        -- first line of a screen, M.ml_speak).
        if scr == "shop" then
            local pv
            pcall(function() pv = M.wvis(owner.SelectItemNum) end)
            if pv == 0 or pv == 3 or pv == 4 then
                if st.said then st.said = "W" end
                return
            end
        end
        local row, idx, nrow, ncur = nil, nil, 0, 0
        pcall(function()
            w.ItemWidgetList_ActiveItems:ForEach(function(_, e)
                nrow = nrow + 1
                local r = e:get()
                local v
                pcall(function() v = M.wvis(r.RefIcon_Cursor) end)
                if v == 0 or v == 3 or v == 4 then
                    ncur = ncur + 1   -- (rows showing the cursor: two while it moves on)
                    if not row then row = r end
                end
            end)
        end)
        -- (not in the shop: a goods row without its cursor icon is the moment Enter opens
        -- the picker, before the picker shows -- nothing to say then)
        if not row and scr == "shop" then return end
        if not row then
            pcall(function()
                w.ItemWidgetList_ActiveItems:ForEach(function(k, e) if k == cur + 1 then row = e:get() end end)
            end)
        end
        if not row then return end
        local c1, c2, stv = M.wtext(row.RefText_Col1), M.wtext(row.RefText_Col2), 0
        pcall(function() idx, stv = row.IndexInAll, row.ItemStatus end)
        if not c1 or M.placeholder(c1) then return end
        say = c1
        if scr == "shop" then
            -- the goods (2026-11-14 log): col1 the name, col2 how many you have, col3 the
            -- price, unit the currency sign -- said as "Heiltraube, 50 Blätter, Zur Hand
            -- 0" (the column header's own text, eSHOP_EQUIP_AFTER_BUY_NUM)
            local c3, un = M.wtext(row.RefText_Col3), M.wtext(row.RefText_Unit)
            M.shop_cols_logged = M.shop_cols_logged or {}
            local lk = tostring(c1)
            if not M.shop_cols_logged[lk] then
                M.shop_cols_logged[lk] = true
                log(string.format("SHOP row: col1=%s col2=%s col3=%s unit=%s status=%s", tostring(c1), tostring(c2),
                    tostring(c3), tostring(un), tostring(stv)))
            end
            if c3 and not M.placeholder(c3) then
                say = say .. ", " .. c3 .. " " .. ((un and not M.placeholder(un)) and un or M.MONEY_SIGN)
            end
            if c2 and not M.placeholder(c2) then
                say = say .. ", " .. (M.gt_label("eSHOP_EQUIP_AFTER_BUY_NUM") or tr("on hand")) .. " " .. c2
            end
            if stv == 1 then say = trf("%s, unavailable", say) end
        elseif c2 and not M.placeholder(c2) then
            say = say .. ", " .. c2
        end
        if scr == "items" and stv == 1 then say = trf("%s, not usable here", say) end
        if scr == "journal" then
            local prog, new, done = M.journal_marks(row)
            say = M.journal_row(c1, c2, M.wtext(row.RefText_Col3), prog, new, done)
        end
        if scr == "abilities" then
            -- learned = the row's check mark (RefImg_Strikethrough shown). ItemStatus 1 only
            -- means greyed: with too few LBP every skill is greyed, and "Analyse, erlernt"
            -- was said for a skill not learned (2026-11-16, 33 of 100 LBP)
            local mark
            pcall(function() mark = M.wvis(row.RefImg_Strikethrough) end)
            if c1 == "???" then say = tr("Locked skill")
            elseif mark == 0 or mark == 3 or mark == 4 then say = trf("%s, learned", say) end
        end
        -- equipment: a greyed category is one this traveler can't use (swords for
        -- Cyrus); in an item list the greyed row is the piece worn now
        if scr == "equip" and stv == 1 then
            say = (which == "right") and trf("%s, equipped", say) or trf("%s, can't equip", say)
        end
        -- (a journal row by its title: its "new" mark may go once the cursor is on it)
        sig = string.format("R%X:%s:%s", addr or 0, tostring(idx), (scr == "journal") and c1 or say)
        -- THE JOURNAL BROWSED FAST (player report 2026-11-24: the wrong title first, then the
        -- right one, and then not the entry's text): moving on, the row left keeps its
        -- cursor a moment and was taken as the first of two. A journal row is said once it
        -- is the same on a second poll with the cursor on it alone (at the latest after
        -- 0.5 s); meanwhile the last row's text, now out of date, is dropped.
        if scr == "journal" and sig ~= st.said then
            if st.j_wait ~= sig then st.j_wait, st.j_wait_n = sig, 0 else st.j_wait_n = st.j_wait_n + 1 end
            if not ((st.j_wait_n >= 1 and ncur <= 1) or st.j_wait_n >= 5) then
                st.help_at = nil
                return
            end
        end
        -- the journal's list: its title first ("Tagebuch von Ophilia") when it opens
        if scr == "journal" and sig ~= st.said then
            local okt, title = pcall(M.journal_list_title, w)
            if okt and title and title ~= M.journal_title_said then
                M.journal_title_said = title
                say = title .. ". " .. say
            end
        end
        -- support abilities: a greyed row is one already equipped; the slot the list fills
        -- is said when it changes (after a choice the game moves on to the next free one)
        if scr == "support" then
            if stv == 1 then say = trf("%s, equipped", say) end
            local slot
            pcall(function() slot = owner.SupportAbilityWidget.ListFocus end)
            sig = string.format("R%X:%s:%s:%s", addr or 0, tostring(idx), say, tostring(slot))
            if slot and st.sup_slot ~= nil and slot ~= st.sup_slot then
                say = trf("Slot %d of %d", slot + 1, 4) .. ". " .. say
            end
            if slot then st.sup_slot = slot end
        end
    end
    M.ml_speak(st, now, sig, say, extra, scr, which, owner, scr == "support" or scr == "journal")
end
-- Say a list line (sig names what it is: the same again stays quiet), and 0.3 s later its
-- help line: extra (a tab's support rows, a support slot's description) or the help box,
-- with what the row would change. nowait: no screen name is coming (see below).
M.ml_speak = function(st, now, sig, say, extra, scr, which, owner, nowait)
    if sig ~= st.said then
        -- a screen just opened (nothing said yet): its name ("Items") comes from the
        -- screen announcer ~1 s later and cut this off -- so wait for it (at most 1.2 s),
        -- then queue
        local first = st.said == nil
        if first and not nowait then
            if not st.first_at then st.first_at = now; return end
            local named = (M.scr_said_t or -1) >= st.first_at
            if not named and now < st.first_at + 1.2 then return end
        end
        st.first_at = nil
        st.said = sig
        speak(say, not first)
        st.help_at = now + 0.3
        st.extra_say = extra
        -- the support screen's travelers and slots: their help line is said each time,
        -- even when it is the one said before (Ophilia's "...: Keine" after Cyrus's was
        -- left out; back on a used slot, its description again). A journal row too: its
        -- text belongs to it (browsing fast, a text cut off by the next row was taken as
        -- said, and never came when the row came back)
        if sig:match("^U") or scr == "journal" then st.help_said = nil end
        st.j_retry = 0
    end
    if st.help_at and now >= st.help_at then
        st.help_at = nil
        -- tabs: the support rows (abilities) instead of the help box, which still
        -- shows the last row's text there; the support screen's travelers and slots
        -- ("U"): only their own line
        local parts = {}
        local ex = st.extra_say
        if type(ex) == "function" then   -- (read now, not when the line was said)
            local ok, v = pcall(ex)
            ex = ok and v or nil
        end
        if ex then parts[#parts + 1] = ex end
        if not st.extra_say and not sig:match("^[CU]") then
            -- equipment items: what the piece would change first, read now (the table
            -- follows the cursor a frame late)
            if scr == "equip" and which == "right" then
                local okc, c = pcall(M.eq_changes, owner)
                if okc and c then parts[#parts + 1] = c end
            end
            -- the journal: the text beside its list instead of a help box
            if scr == "journal" then
                local okj, jt = pcall(M.journal_text, owner)
                if okj and jt then
                    parts[#parts + 1] = jt
                elseif (st.j_retry or 0) < 5 then
                    -- (the text not there yet: again a moment later, up to 0.5 s)
                    st.j_retry = (st.j_retry or 0) + 1
                    st.help_at = now + 0.1
                    return
                end
            end
            local hh = (scr ~= "journal") and M.ml_help() or nil
            -- a locked skill's help is just "???"
            if hh and not hh:match("^[%?%s]+$") then parts[#parts + 1] = hh end
            -- a support ability: what it changes (max. HP ...), after its description
            if scr == "support" then
                local okc, c = pcall(M.eq_changes, owner, "ListItemParamWidget")
                if okc and c then parts[#parts + 1] = c end
            end
            -- weapons and armor in a shop: what the piece would change for each traveler
            if scr == "shop" then
                local okp, pcs = pcall(M.shop_party_changes, owner)
                if okp and pcs then parts[#parts + 1] = pcs end
            end
        end
        st.extra_say = nil
        local h = #parts > 0 and M.join_text(parts) or nil
        if h and h ~= st.help_said then
            st.help_said = h
            speak(h, false)
        end
    end
end
-- From the polling loop: while a menu is up, the list reader, 10x/s.
-- Also INSIDE AN EVENT while a list is the focused screen (2026-11-14: the tavern keeper's
-- "Ausrüstung" opens the equipment screen within the talk event; the reader stood down
-- and only "Equipment" was said). M.evm_cls is the event reader's focused screen; never
-- in a fade, and poll_menu_list checks the screen again (M.ev_list_ok).
M.EVENT_LIST_SCREENS = { ListWidget_C = true }
M.ev_list_ok = function(cls)
    return M.ev_now and not M.fade_now and not M.battle_now and M.EVENT_LIST_SCREENS[cls or ""] == true
end
M.menu_lists_tick = function()
    local in_ev = M.ev_list_ok(M.evm_cls)
    if not in_ev and (not M.menu_now or M.ev_now or M.battle_now) then
        if M.ml.said then M.ml.said, M.ml.help_said = nil, nil end
        M.ml.first_at = nil
        if next(M.ml_cache) then M.ml_cache = {} end
        return
    end
    local now = os.clock()
    if M.ml.queued and now - M.ml.queued < 2.0 then return end
    if now - (M.ml.t or 0) < 0.1 then return end
    M.ml.t, M.ml.queued = now, now
    M.in_gt(function()
        M.ml.queued = nil
        if M.trace then log("TR menulist") end
        pcall(M.poll_menu_list)
    end)
end

-- BATTLE READER, on the game thread from M.poll_event_menus while a battle runs.
-- Command menus: the open BattleCommandMenu_C with the highest FloorIndex (1 = Angriff,
-- Fertigkeiten, Objekt..., 2 = a skill/item list) -- its item at CursorIndex -
-- OffsetIndex: TextCommandFocus, TextAddInfo (the SP cost), CommandUseable. The help
-- line (BattleCommandHelpWindow_C.HelpText) follows a moment later. While a target
-- cursor shows (BattleTargetCursor_C, CursorVisible), the target instead: its enemy
-- panel (BattleEnemyStatus_C.Enemy = the cursor's TargetCharacter) or party panel.
-- Unused widget copies carry placeholder texts ("0123456", "0124", "ああ..."): skipped.
-- Weaknesses: only REVEALED ones (WeakStatusIcon_0x.IconOpened) -- the icon textures
-- under the "?" cover already show the real ones, a sighted player sees only "?".
M.WEAK_DE = { sword = N_("Sword"), spear = N_("Spear"), dagger = N_("Dagger"), ax = N_("Axe"), arrow = N_("Bow"),
    cane = N_("Staff"), Flame = N_("Fire"), FIre = N_("Fire"), Fire = N_("Fire"), Ice = N_("Ice"), Thunder = N_("Lightning"),
    Wind = N_("Wind"), Light = N_("Light"), Dark = N_("Dark") }   -- (said through tr)
M.bt = {}
M.addr_of = function(o)
    local a
    pcall(function() a = o:GetAddress() end)
    return a
end
-- A battle widget's OTHER object pointers (characters, an image brush's texture) are
-- read as raw NUMBERS (shim.Peek, SEH-guarded), never handed to UE4SS as objects:
-- UE4SS inspects an object pointer when it wraps it, and a stale one -- unused order
-- icons, unused status icons -- ended the Lua call, once the whole game (2026-11-14).
-- Offsets from the object dump.
M.peekp = function(obj, off)
    local a = M.addr_of(obj)
    if not (a and shim and shim.Peek) then return nil end
    local v = shim.Peek(a + off, "ptr")
    if v and v ~= 0 then return v end
    return nil
end
M.TEX_NAMES = { "WeaponIcon_sword", "WeaponIcon_spear", "WeaponIcon_dagger", "WeaponIcon_ax",
    "WeaponIcon_arrow", "WeaponIcon_cane", "AttributeIcon_Flame", "AttributeIcon_FIre", "AttributeIcon_Ice",
    "AttributeIcon_Thunder", "AttributeIcon_Wind", "AttributeIcon_Light", "AttributeIcon_Dark" }
for _, k in ipairs({ "AbilityAll", "AttackAll", "Avoid", "BPBoost", "Counter", "Critical", "CriticalContinu",
    "Dark", "DDefense", "EAvoid", "Fire", "Health", "Hit", "Ice", "Invincible", "ItemAll", "Light", "MAttack",
    "MContinu", "MConverge", "MCritical", "Mdefense", "PAttack", "PDefense", "Provoke", "Reflec", "Regene",
    "Reraise", "Speed", "SPRegene", "Thunder", "Wind" }) do
    M.TEX_NAMES[#M.TEX_NAMES + 1] = "IconStatus_Up_" .. k
end
for _, k in ipairs({ "Adhesive", "Avoid", "Break", "BuffUnavailable", "Confu", "Critical", "Dark", "Faint",
    "Fear", "Hit", "MAttack", "MDefense", "MSealed", "PAttack", "Pdefense", "Poison", "Silence", "Sleep",
    "Speed", "Spoison" }) do
    M.TEX_NAMES[#M.TEX_NAMES + 1] = "IconStatus_Down_" .. k
end
-- texture NAME -> "IconStatus_Down_Poison", by the FName's comparison index: the
-- texture's own name is read raw (UObject NamePrivate, +0x18). Built once a session --
-- FNames never change. It used to be the textures' addresses, found with ~150
-- StaticFindObject calls at the first weakness or status read of EVERY battle -- that
-- first read is a number key at the start of a fight (user, 2026-11-16: "the first press
-- takes quite a while"). Names the FName table doesn't know yet (FNAME_Find) are asked
-- again later, at most once a second.
M.tex_names = { map = {}, missing = nil, t = -9 }
M.tex_fname_map = function()
    local T = M.tex_names
    local now = os.clock()
    if T.missing and (#T.missing == 0 or now - T.t < 1) then return T.map end
    T.t = now
    local todo = T.missing or M.TEX_NAMES
    local still = {}
    for _, n in ipairs(todo) do
        local c, num = M.fname_of("UiTX_Battle_" .. n)
        if c and num == 0 then T.map[c] = n else still[#still + 1] = n end
    end
    T.missing = still
    return T.map
end
-- the texture name of an icon widget's image (its UImage* at imgoff; Brush 0xF8 +
-- ResourceObject 0x48 = 0x140)
M.icon_tex = function(icon, imgoff)
    local img = M.peekp(icon, imgoff)
    if not img then return nil end
    local tex = shim.Peek(img + 0x140, "ptr")
    if not tex or tex == 0 or not shim.PeekFName then return nil end
    local c, num = shim.PeekFName(tex + 0x18)
    if not c or c <= 0 or num ~= 0 then return nil end
    local name = M.tex_fname_map()[c]
    if not name and #(M.tex_names.missing or {}) > 0 then
        M.tex_names.t = -9   -- a texture we don't know yet: ask for the missing names now
        name = M.tex_fname_map()[c]
    end
    return name
end
-- the unused copies' filler: "0123456", "0124", "0123" and Japanese "ああ...". Only
-- digit runs that START "012" -- a real "8" (an SP cost) is no placeholder.
M.placeholder = function(s)
    return not s or s:match("^012%d*$") ~= nil or s:find("\227\129\130", 1, true) ~= nil
end
-- a command's extra text: a skill's SP cost ("8") or an item's count ("x 4")
M.bt_addinfo = function(a)
    if a:match("^%d+$") then return trf("%s SP", a) end
    local n = a:match("^x%s*(%d+)$")
    if n then return trf("%s left", n) end
    return a
end
-- FindAllOf for the battle widgets. The copies live as long as the battle UI, so a list is
-- kept 15 s while every widget in it still checks out (an empty one is asked again after
-- 1 s). Each FindAllOf walks every object, 80-100 ms on the game thread: kept 3 s, the four
-- lists of the battle poll were searched again together every 3 s -- 350 ms stalls, and a
-- number key pressed meanwhile waited (2026-11-16). The lifetimes differ by 0.6 s per class
-- (in the order they were first asked for), so the searches fall into different polls.
M.bt_list = function(cls)
    M.bt.lists = M.bt.lists or {}
    local c, now = M.bt.lists[cls], os.clock()
    local life = (c and #c.l > 0) and (15 + (c.k % 8) * 0.6) or 1
    if c and now - c.t < life then
        -- (only while every kept widget's handle still matches in the shim's reads)
        local all = true
        for i = 1, #c.l do
            if not M.handle_ok(c.h[i]) then all = false; break end
        end
        if all then return c.l end
    end
    local l, hs = {}, {}
    pcall(function()
        local all = FindAllOf(cls)
        if all then
            for _, w in ipairs(all) do
                local ok = false
                pcall(function() ok = w:IsValid() end)
                local h = ok and M.handle(w)
                if h then l[#l + 1] = w; hs[#hs + 1] = h end
            end
        end
    end)
    local ms = (os.clock() - now) * 1000
    if (ms > 40 and not c) or ms > 150 then
        log(string.format("BT FindAllOf %s: %d widgets, %.0f ms", cls, #l, ms))
    end
    if not c then M.bt.nlist = (M.bt.nlist or 0) + 1 end
    M.bt.lists[cls] = { t = now, l = l, h = hs, k = c and c.k or M.bt.nlist }
    return l
end
-- the enemies on the field, in the order of their panels. Only ADDRESSES of battle
-- characters, never their names (GetFName on a stale one froze the game, 2026-11-14).
-- Each with alive: a defeated enemy keeps its panel, Enemy pointer and all (user,
-- 2026-11-18: two dead robbers still answered keys 2 and 3 five minutes later, "broken").
-- The enemy (BattleEnemyBP_C, read raw) has Dead (bool +0x3A9, from
-- BattleCharacterBaseBP_C: ForceDead sets it with HP 0) and StatusUI (+0x658, its panel:
-- EndStatusUI takes the panel off the screen and sets None, ResumeStatusUI shows it only
-- while IsAlive). Alive = not Dead and still pointing at this very panel; unreadable =
-- gone. The damage line's names still take every enemy (a lethal hit's target is dead).
M.bt_enemies = function()
    local out = {}
    for _, w in ipairs(M.bt_list("BattleEnemyStatus_C")) do
        local ea, name = M.peekp(w, 0x2C8), M.wtext(w.characterName)   -- Enemy
        if ea and ea ~= 0 and not M.placeholder(name) then
            local wa, dead, ui
            pcall(function()
                wa = w:GetAddress()
                dead = shim.Peek(ea + 0x3A9, "u8")
                ui = shim.Peek(ea + 0x658, "ptr")
            end)
            local alive = dead == 0 and ui ~= nil and ui == wa
            out[#out + 1] = { w = w, addr = ea, name = name, alive = alive, dead = dead ~= nil and dead ~= 0 }
        end
    end
    return out
end
M.bt_living = function()   -- the enemies still in the fight (keys 1-5)
    local out = {}
    for _, en in ipairs(M.bt_enemies()) do
        if en.alive then out[#out + 1] = en end
    end
    return out
end
-- WHO REALLY FIGHTS (user 2026-11-23): in a duel (Challenge, Provoke) only one traveler is
-- in the battle, yet keys 6-9 read the whole party ("H'aanit, HP 500 von 500 ..." on 7),
-- and the result screen said "Therion erreicht Stufe 11" again although nobody had gained
-- a level. The unused party panels (BattleSelectPlayerStatus_C) and result panels
-- (BattleResultPlayerWidget_C) keep what the last full battle put in them. The battle
-- manager's BattlePlayer (@0x3B0, object dump) lists the battle's own travelers; a panel
-- counts only when its character -- Owner (@0x388) / TergetCharacter (@0x258) -- is one of
-- them. -> a set of addresses, or nil (the manager unreadable: every panel, as before).
M.BT_PLAYERS = 0x3B0
M.bt_player_set = function()
    local mgr = M.kept(M.bt and M.bt.mgr_h)
    local ma = mgr and M.addr_of(mgr)
    if not ma then return nil end
    local set, n = {}, 0
    for _, a in ipairs(M.bt_array(ma, M.BT_PLAYERS)) do set[a] = true; n = n + 1 end
    return n > 0 and set or nil
end
-- panels (each { ..., ch = its character }) without those of travelers not in this battle;
-- all of them when none matches (a layout not seen yet: logged once)
M.bt_in_battle = function(list, what)
    local inb = M.bt_player_set()
    if not inb then return list end
    local out = {}
    for _, e in ipairs(list) do if e.ch and inb[e.ch] then out[#out + 1] = e end end
    if #out == 0 and #list > 0 then
        M.bt.inb_logged = M.bt.inb_logged or {}
        if not M.bt.inb_logged[what] then
            M.bt.inb_logged[what] = true
            log(string.format("BT %s: no panel's character is among the battle's travelers, taking all %d", what, #list))
        end
        return list
    end
    return out
end
M.bt_party = function()
    local out = {}
    for _, w in ipairs(M.bt_list("BattleSelectPlayerStatus_C")) do
        local name = M.wtext(w.CharaName)
        if not M.placeholder(name) then
            local owner = M.peekp(w, 0x388)   -- Owner
            out[#out + 1] = { w = w, addr = owner, name = name, ch = owner }
        end
    end
    return M.bt_in_battle(out, "party")
end
-- FOLLOWERS (user 2026-11-20): a person Ophilia guides or Primrose allures, called with
-- "Rufen", fights for a few turns: a BattleSupporterBP_C (object dump) with its own icon
-- in the turn order. Its actions were said as the last enemy's ("Heathcote: Physischer
-- Boost"), without a name ("Dolchsturm"), or as "Rufen: Physischer Boost". Found without
-- an object search: an order icon's Character (+0x288) that is neither an enemy nor a
-- traveler, whose class (UObject +0x10 -> the class's name +0x18) is BattleSupporterBP_C;
-- its name the GameText label SupportData.DisplayNameID (+0x708, an FName),
-- SupportFinish (+0x77C) once it has left ("Meryls Mutter hat sich aus dem Kampf
-- zurückgezogen."). All raw reads, as for every battle character.
M.SUP_NAME, M.SUP_FINISH = 0x708, 0x77C
-- THE FOLLOWER'S OWN TURN (user 2026-11-21: Meryls Mutter's second "Physischer Boost" came
-- out as "Ghisarma: Physischer Boost" again). A follower has no icon in the turn order: it
-- acts in a turn of its own right after its caller's (BattleManagerBP_C:SupporterTurn),
-- so the icons found nobody and the last enemy standing was taken. The battle manager
-- (M.bt_manager, found as the battle starts) knows: BattleSupporter (+0x550, the followers
-- in the fight), IsSupporterTurn (+0xFAC), and who acts, ActionCharacter (+0x8B0) next to
-- ActiveCharacter (M.BT_ACTIVE).
M.BT_SUPS, M.BT_SUP_TURN, M.BT_ACTION = 0x550, 0xFAC, 0x8B0
M.bt_sup_entry = function(a)
    local cmp, num = shim.Peek(a + M.SUP_NAME, "u32"), shim.Peek(a + M.SUP_NAME + 4, "u32")
    local fin = shim.Peek(a + M.SUP_FINISH, "u8")
    local name = (cmp and cmp > 0) and M.gametext(cmp, num) or nil
    return { addr = a, name = name or tr("Companion"), gone = fin ~= nil and fin ~= 0 }
end
M.bt_supporters = function()
    local out, seen = {}, {}
    -- the manager's list (kept since the battle's start: no search here)
    local mgr = M.kept(M.bt.mgr_h)
    local ma = mgr and M.addr_of(mgr)
    if ma then
        for _, a in ipairs(M.bt_array(ma, M.BT_SUPS)) do
            if not seen[a] then seen[a] = true; out[#out + 1] = M.bt_sup_entry(a) end
        end
    end
    -- and the turn order's icons
    local want = M.sup_cls_cmp
    if not want then
        want = M.fname_of("BattleSupporterBP_C")   -- (only once the class is loaded)
        M.sup_cls_cmp = want
        if not want then return out end
    end
    local known = {}
    for _, en in ipairs(M.bt_enemies()) do known[en.addr] = true end
    for _, pm in ipairs(M.bt_party()) do if pm.addr then known[pm.addr] = true end end
    for _, ic in ipairs(M.bt_list("ActionOrderIcon_C")) do
        local a = M.peekp(ic, 0x288)   -- Character
        if a and not known[a] and not seen[a] then
            seen[a] = true
            local cls = shim.Peek(a + 0x10, "ptr")
            if cls and cls ~= 0 and shim.Peek(cls + 0x18, "u32") == want then
                out[#out + 1] = M.bt_sup_entry(a)
            end
        end
    end
    return out
end
-- The manager's view of the action just starting: { sup_turn, action, active } (raw), or
-- nil without the manager.
M.bt_turn_state = function()
    local mgr = M.kept(M.bt.mgr_h)
    local ma = mgr and M.addr_of(mgr)
    if not ma then return nil end
    local st = shim.Peek(ma + M.BT_SUP_TURN, "u8")
    return { sup_turn = st ~= nil and st ~= 0, action = shim.Peek(ma + M.BT_ACTION, "ptr"),
        active = shim.Peek(ma + M.BT_ACTIVE, "ptr") }
end
-- The weakness tiles as said: { {name = "Stab"} or {} for a "?", locked = bool } in the
-- game's order -> "weak to 1 unknown, Stab, Dunkelheit" (a run of "?" as a count, in
-- place), nil for none. All of them locked: "weak to Stab, 2 unknown, all locked".
M.weak_tiles_text = function(tiles)
    if #tiles == 0 then return nil end
    local all = true
    for _, t in ipairs(tiles) do if not t.locked then all = false end end
    local out, run = {}, 0
    local function flush()
        if run > 0 then out[#out + 1] = trf("%d unknown", run); run = 0 end
    end
    for _, t in ipairs(tiles) do
        local lk = t.locked and not all
        if t.name then
            flush()
            out[#out + 1] = lk and trf("%s locked", t.name) or t.name
        elseif lk then
            flush()
            out[#out + 1] = tr("1 unknown locked")
        else
            run = run + 1
        end
    end
    flush()
    if all then return trf("weak to %s, all locked", table.concat(out, ", ")) end
    return trf("weak to %s", table.concat(out, ", "))
end
-- LOCKED WEAKNESSES (user, 2026-11-17: a boss that calls helpers has its weaknesses
-- blocked until they are gone). How many of an enemy's weakness tiles are set up, and
-- how many of those are locked. WeakStatusIcon_C.WeakLocked (bool @ +0x28A) is the flag:
-- the cooked Blueprint's bytecode sets it in SetAttributeIcon(Icon, Lock, Opened, Index)
-- when a tile is made (playing InstantLock or NoLock) and in SetWeakLock(Lock), which
-- plays the Lock or UnLock animation when it changes.
M.bt_weak_locked = function(w)
    local nl, nt = 0, 0
    for k = 0, 4 do
        local ic
        pcall(function() ic = w["WeakStatusIcon_0" .. k] end)
        local setup, locked = false, false
        if ic then pcall(function() setup = ic.IsSetup; locked = ic.WeakLocked == true end) end
        if setup then
            nt = nt + 1
            if locked then nl = nl + 1 end
        end
    end
    return nl, nt
end
-- From the battle poll, every 0.5 s: weaknesses locked, or free again, go with the damage
-- line. Locked when the battle starts: in the line that names the enemies (M.poll_battle
-- reads bt.locks); locked once the tiles are set up after that line: said then.
M.bt_lock_watch = function(bt, now)
    if now - (bt.lock_t or -9) < 0.5 then return end
    bt.lock_t = now
    bt.locks = bt.locks or {}
    for _, en in ipairs(M.bt_enemies()) do
        local nl, nt = M.bt_weak_locked(en.w)
        if nt > 0 then
            local lk = nl > 0
            local was = bt.locks[en.addr]
            if lk ~= was and (was ~= nil or (lk and bt.started)) then
                M.dmg_push(lk and trf("%s: weaknesses locked", en.name) or trf("%s: weaknesses free again", en.name))
            end
            if lk ~= was then log(string.format("WEAK lock %s: %d of %d tiles", tostring(en.name), nl, nt)) end
            bt.locks[en.addr] = lk
        end
    end
end
-- H'aanit's capture (and stealing in battle): the success rate over the enemy,
-- BattleSuccessRate_C (TitleText "Erfolgschance", RateValue "60 %"), seen 2026-11-15 on
-- screen while nothing was said. -> "Erfolgschance 60 %", or nil while it isn't shown.
M.bt_rate_text = function(w)
    local sr
    pcall(function() sr = w.BattleSuccessRate end)
    local sv = sr and M.wvis(sr)
    if not (sv == 0 or sv == 3 or sv == 4) then return nil end
    local t, r
    pcall(function() t, r = M.wtext(sr.TitleText), M.wtext(sr.RateValue) end)
    if not r or M.placeholder(r) then return nil end
    return ((t and not M.placeholder(t)) and (t .. " ") or "") .. r
end
-- (label: the name to say, M.bt_target_name's "Majesto-Murmeltier auf 2"; default en.name)
M.bt_enemy_text = function(en, label)
    local w = en.w
    local parts = { label or en.name }
    -- the success rate right after the name: at the line's end it was cut off by the next
    -- target and by the capture question (user 2026-11-21: "the chance isn't read out")
    local rate = M.bt_rate_text(w)
    if rate then parts[#parts + 1] = rate end
    local sh
    pcall(function() sh = M.wtext(w.BreakStatusIcon.Text_BreakGauge) end)
    if sh == "0" then parts[#parts + 1] = tr("broken")
    elseif sh then parts[#parts + 1] = trf("shield %s", sh) end
    -- The tiles in the game's own order (Schwert, Lanze, Dolch, Axt, Bogen, Stab, Feuer,
    -- Eis, Blitz, Wind, Licht, Dunkelheit): a revealed weakness opens in ITS tile, the
    -- others stay "?", so where an unknown one sits tells what it can still be (user,
    -- 2026-11-15: "weak to Stab, Dunkelheit, 1 unknown" lost that). Unknown tiles are
    -- said in place, a run of them as a count: "weak to 2 unknown, Stab, Dunkelheit".
    local tiles, nknown = {}, 0
    for k = 0, 4 do
        local ic
        pcall(function() ic = w["WeakStatusIcon_0" .. k] end)
        local setup, opened, locked = false, false, false
        if ic then pcall(function() setup, opened = ic.IsSetup, ic.IconOpened end) end
        if ic then pcall(function() locked = ic.WeakLocked == true end) end
        if setup then
            local t = { locked = locked }
            if opened then
                local res = M.icon_tex(ic, 0x248)   -- AttributeIcon's texture
                local key = res and res:match("Icon_(%a+)$")
                t.name = (key and M.WEAK_DE[key] and tr(M.WEAK_DE[key])) or key or "?"
                nknown = nknown + 1
            end
            tiles[#tiles + 1] = t
        end
    end
    local wt = M.weak_tiles_text(tiles)
    if wt then parts[#parts + 1] = wt end
    -- the panel has five tiles; an enemy with more weaknesses (a boss?) would show here
    local nweak
    pcall(function() nweak = w.EnableWeakIconNum end)
    if type(nweak) == "number" and nweak > #tiles and not (M.bt.weakmore or {})[en.name] then
        M.bt.weakmore = M.bt.weakmore or {}
        M.bt.weakmore[en.name] = true
        log(string.format("WEAK %s: %d weaknesses, %d tiles", tostring(en.name), nweak, #tiles))
    end
    local s = table.concat(parts, ", ")
    local st = M.bt_enemy_statuses(w)
    -- "broken" is already said from the shield; its icon only adds the turns
    local bw = tr("broken")
    for i = #st, 1, -1 do
        if st[i]:sub(1, #bw) == bw then
            local p = s:find(", " .. bw, 1, true)
            if sh == "0" and st[i]:find(",") and p then s = s:sub(1, p + 1) .. st[i] .. s:sub(p + 2 + #bw) end
            table.remove(st, i)
        end
    end
    if #st > 0 then s = s .. ". " .. table.concat(st, "; ") end
    return s
end
-- STATUS EFFECTS: BuffIcon_C widgets whose StateIcon texture names the effect,
-- "UiTX_Battle_IconStatus_Up_PAttack" / "..._Down_Poison"; TurnNum = turns left.
-- Party panel: BuffIcon_00..03 and DebuffIcon_00..03. Enemy panel: StateIcon01/02 (the
-- two shown, cycling) and DiseaseIconList (all of them).
M.STATUS_UP = { AbilityAll = N_("abilities hit all"), AttackAll = N_("attacks hit all"), Avoid = N_("evasion up"),
    BPBoost = N_("BP boost"), Counter = N_("counter"), Critical = N_("critical up"), CriticalContinu = N_("criticals continue"),
    Dark = N_("dark enchant"), DDefense = N_("damage guard"), EAvoid = N_("elemental evasion up"), Fire = N_("fire enchant"),
    Health = N_("health up"), Hit = N_("accuracy up"), Ice = N_("ice enchant"), Invincible = N_("invincible"),
    ItemAll = N_("items hit all"), Light = N_("light enchant"), MAttack = N_("elemental attack up"),
    MContinu = N_("spells continue"), MConverge = N_("spells converge"), MCritical = N_("spell criticals"),
    Mdefense = N_("elemental defense up"), PAttack = N_("physical attack up"), PDefense = N_("physical defense up"),
    Provoke = N_("provoke"), Reflec = N_("reflect"), Regene = N_("HP regeneration"), Reraise = N_("auto revive"),
    Speed = N_("speed up"), SPRegene = N_("SP regeneration"), Thunder = N_("lightning enchant"), Wind = N_("wind enchant") }
M.STATUS_DOWN = { Adhesive = N_("stuck"), Avoid = N_("evasion down"), Break = N_("broken"), BuffUnavailable = N_("buffs blocked"),
    Confu = N_("confused"), Critical = N_("critical down"), Dark = N_("blinded"), Faint = N_("unconscious"), Fear = N_("terrified"),
    Hit = N_("accuracy down"), MAttack = N_("elemental attack down"), MDefense = N_("elemental defense down"),
    MSealed = N_("abilities sealed"), PAttack = N_("physical attack down"), Pdefense = N_("physical defense down"),
    Poison = N_("poisoned"), Silence = N_("silenced"), Sleep = N_("asleep"), Speed = N_("speed down"), Spoison = N_("badly poisoned") }
M.bt_icon_status = function(ic)   -- -> "poisoned, 2 turns" or nil
    -- an icon in use has IconIN set: the 54 unused copies in a test were "visible" (4)
    -- with the default texture (Up_MAttack) and "8" turns, but IconIN false
    local inn = false
    pcall(function() inn = ic.IconIN end)
    if not inn then return nil end
    local v = M.wvis(ic)
    if not (v == 0 or v == 3 or v == 4) then return nil end
    local res = M.icon_tex(ic, 0x258)   -- StateIcon's texture
    local dir, key = (res or ""):match("IconStatus_(%a+)_(%w+)$")
    if not dir then return nil end
    local name = (dir == "Up" and M.STATUS_UP[key]) or (dir == "Down" and M.STATUS_DOWN[key])
    name = name and tr(name) or (dir == "Up" and trf("%s up", key) or trf("%s down", key))
    local t = M.wtext(ic.TurnNum)
    if t and t:match("^%d+$") and not M.placeholder(t) then
        name = name .. ", " .. trn("%d turn", "%d turns", tonumber(t))
    end
    return name
end
M.bt_statuses = function(icons)   -- unique effects of a list of BuffIcon_C widgets
    local out, seen = {}, {}
    for _, ic in ipairs(icons) do
        local s
        pcall(function() s = M.bt_icon_status(ic) end)
        local k = s and s:match("^[^,]+")
        if s and not seen[k] then seen[k] = true; out[#out + 1] = s end
    end
    return out
end
M.bt_enemy_statuses = function(w)
    local icons = {}
    for _, nm in ipairs({ "StateIcon01", "StateIcon02" }) do
        pcall(function() local ic = w[nm]; if ic then icons[#icons + 1] = ic end end)
    end
    pcall(function()
        w.DiseaseIconList:ForEach(function(_, e) local ic = e:get(); if ic then icons[#icons + 1] = ic end end)
    end)
    return M.bt_statuses(icons)
end
M.bt_party_statuses = function(w)
    local icons = {}
    for k = 0, 3 do
        for _, nm in ipairs({ "BuffIcon_0", "DebuffIcon_0" }) do
            pcall(function() local ic = w[nm .. k]; if ic then icons[#icons + 1] = ic end end)
        end
    end
    return M.bt_statuses(icons)
end
-- boost points: the filled ones of the 5 gauge points (BattleBoostGaugePoint_C)
M.bt_bp = function(w)
    local n = 0
    for k = 0, 4 do
        local e = false
        pcall(function() e = w["Gauge0" .. k].BoostEnable end)
        if e then n = n + 1 end
    end
    return n
end
M.bt_party_text = function(pm)
    local w = pm.w
    local dead
    pcall(function() dead = w.IsDead end)
    local s = trf("%s, HP %s of %s, SP %s of %s, BP %d", pm.name, tostring(M.wtext(w.TextHPValue)),
        tostring(M.wtext(w.TextHPMaxValue)), tostring(M.wtext(w.TextMPValue)), tostring(M.wtext(w.TextMPMaxValue)),
        M.bt_bp(w))
    if dead then s = trf("%s, down", s) end
    local st = M.bt_party_statuses(w)
    if #st > 0 then s = s .. ". " .. table.concat(st, "; ") end
    return s
end
-- ENEMY POSITIONS (user 2026-11-21): two "Majesto-Murmeltier" sounded the same as targets,
-- and key 0 couldn't tell which of them acts when. An enemy's position is its number
-- key (1-5: M.bt_living's order, "Gegner 2 von 4"). Key 0 names it for every enemy, a
-- target only when another enemy still fighting has the same name. (living: M.bt_living())
M.bt_pos_name = function(name, pos) return trf("%s at %d", name, pos) end
M.bt_target_name = function(en, living)
    local pos, same = nil, 0
    for i, e in ipairs(living or M.bt_living()) do
        if e.addr == en.addr then pos = i end
        if e.name == en.name then same = same + 1 end
    end
    if pos and same > 1 then return M.bt_pos_name(en.name, pos) end
    return en.name
end
-- The target with its success rate ("Majesto-Murmeltier auf 2, Erfolgschance 100 %"), for
-- the capture question that follows; nil without a rate shown.
M.bt_rate_line = function(addr)
    for _, en in ipairs(M.bt_enemies()) do
        if en.addr == addr then
            local rate = M.bt_rate_text(en.w)
            return rate and (M.bt_target_name(en) .. ", " .. rate) or nil
        end
    end
    return nil
end
M.bt_describe = function(addr)   -- a battle character by address: enemy or party
    for _, en in ipairs(M.bt_enemies()) do
        if en.addr == addr then return M.bt_enemy_text(en, M.bt_target_name(en)) end
    end
    for _, pm in ipairs(M.bt_party()) do
        if pm.addr == addr then return M.bt_party_text(pm) end
    end
    return nil
end
M.bt_targets = function()   -- addresses under a visible target cursor, sorted
    local t = {}
    for _, c in ipairs(M.bt_list("BattleTargetCursor_C")) do
        local cv = false
        pcall(function() cv = c.CursorVisible end)
        -- (any shown state: the capture cursor said nothing, 2026-11-15)
        local v = cv and M.wvis(c)
        if cv and (v == 0 or v == 3 or v == 4) then
            local a = M.peekp(c, 0x208)   -- TargetCharacter
            if a then t[#t + 1] = a end
        end
    end
    table.sort(t)
    return t
end
-- THE ATTACK'S WEAPON (2026-11-18, user: switching weapons with Left/Right in the battle
-- menu said nothing). A command item (BattleCommandMenuItem_C) has an AttributeIconPlate_C
-- (+0x258) with AttributeList (TArray<uint8> +0x240), the entry shown AttributeIndex
-- (+0x270; NextCommandAttribute / PrevCommandAttribute step it, wrapping) and
-- EnableAttributeIcon (+0x258). An entry is the index into the plate's icon table
-- (SetCommandAttribute: Conv_ByteToInt, Array_Get), whose order the Blueprint's defaults
-- give: sword, spear, dagger, axe, bow, staff, unknown, fire, ice, lightning, wind, light,
-- dark (M.ATTR_KEYS: the M.WEAK_DE keys). Read raw, as all battle widgets' pointers.
-- Returns the word, how many there are to switch between and the index, or nil.
M.ATTR_KEYS = { [0] = "sword", [1] = "spear", [2] = "dagger", [3] = "ax", [4] = "arrow", [5] = "cane",
    [7] = "Fire", [8] = "Ice", [9] = "Thunder", [10] = "Wind", [11] = "Light", [12] = "Dark" }
M.bt_attr = function(it)
    local plate = M.peekp(it, 0x258)
    if not (plate and shim and shim.Peek) then return nil end
    local function pk(off, kind)
        local v
        pcall(function() v = shim.Peek(plate + off, kind) end)
        return v
    end
    local en = pk(0x258, "u8")
    if not en or en == 0 then return nil end
    local data, num, idx = pk(0x240, "ptr"), pk(0x248, "i32"), pk(0x270, "i32")
    if not (data and data ~= 0 and num and idx) or num < 1 or num > 13 or idx < 0 or idx > num then return nil end
    -- the icons are a carousel with the first one again at the end: Right
    -- (NextCommandAttribute) counts 1 .. num and then goes back to 1, Left 0 .. num-1 -- so
    -- index num shows the first weapon (Right said nothing on it, user 2026-11-18)
    local v
    pcall(function() v = shim.Peek(data + (idx % num), "u8") end)
    local key = v and M.ATTR_KEYS[v]
    if not (key and M.WEAK_DE[key]) then return nil end
    return tr(M.WEAK_DE[key]), num, idx
end
M.bt_menu = function()   -- the focused command of the topmost open menu
    local best, bf
    for _, m in ipairs(M.bt_list("BattleCommandMenu_C")) do
        local open, fl = false, 0
        pcall(function() open, fl = m.MenuOpen, m.FloorIndex end)
        if open and (not bf or fl > bf) then best, bf = m, fl end
    end
    if not best then return nil end
    local ci, oi = 0, 0
    pcall(function() ci, oi = best.CursorIndex, best.OffsetIndex end)
    local slot = ci - oi
    if slot < 0 or slot > 7 then slot = ci end
    local it
    pcall(function() it = best["MenuItem0" .. slot] end)
    if not it then return nil end
    local text = M.wtext(it.TextCommandFocus)
    if M.placeholder(text) then return nil end
    local usable = true
    pcall(function() usable = it.CommandUseable end)
    local who = M.peekp(best, 0x368)   -- Player
    local boost = 0   -- the boost level chosen with O (BoostLevel; the highest of the open menus)
    for _, mm in ipairs(M.bt_list("BattleCommandMenu_C")) do
        local open, b = false, 0
        pcall(function() open, b = mm.MenuOpen, mm.BoostLevel end)
        if open and type(b) == "number" and b > boost then boost = b end
    end
    -- the weapon (or element) on the item: on the top menu (Attack), and where there is a
    -- choice
    local weapon, wnum, widx = nil, 0, nil
    pcall(function() weapon, wnum, widx = M.bt_attr(it) end)
    if weapon and bf ~= 1 and (wnum or 0) < 2 then weapon = nil end
    return { floor = bf, cur = ci, text = text, add = M.wtext(it.TextAddInfo), usable = usable, who = who,
        boost = boost, weapon = weapon, wnum = wnum, widx = widx }
end
M.bt_help = function()
    for _, h in ipairs(M.bt_list("BattleCommandHelpWindow_C")) do
        local v = M.wvis(h)
        if v == 0 or v == 3 or v == 4 then
            local s = M.wtext(h.HelpText)
            if s and not M.placeholder(s) then return M.join_text({ s }) end
        end
    end
    return nil
end
M.poll_battle = function()
    local bt, now = M.bt, os.clock()
    if not M.dmg_armed and M.arm_dmg_hooks then pcall(M.arm_dmg_hooks) end
    if not M.act_armed and M.arm_act_hook then pcall(M.arm_act_hook) end
    if bt.act_pending then   -- an action banner just opened (M.act_hook)
        speak(bt.act_pending)
        bt.act_pending = nil
    end
    -- shield changes go with the damage line: "shield 2", "broken" (PlayBreak is not
    -- called for a shield break), "recovers, shield 1" when its turn comes
    bt.shields = bt.shields or {}
    for _, en in ipairs(M.bt_enemies()) do
        local sh
        pcall(function() sh = M.wtext(en.w.BreakStatusIcon.Text_BreakGauge) end)
        local old = bt.shields[en.addr]
        if sh and old and sh ~= old then
            if sh == "0" then M.dmg_push(trf("%s broken", en.name))
            elseif old == "0" then M.dmg_push(trf("%s recovers, shield %s", en.name, sh))
            else M.dmg_push(trf("%s shield %s", en.name, sh)) end
        end
        if sh then bt.shields[en.addr] = sh end
    end
    -- a party member knocked out (or back up): the panel's IsDead. A lethal hit shows no
    -- damage number -- Olberic at 1 HP fell to "Flach-Froggen I: Angriff" and nothing
    -- was said; he just never came up again (2026-11-15). Goes with the damage line.
    bt.down = bt.down or {}
    for _, pm in ipairs(M.bt_party()) do
        local dead
        pcall(function() dead = pm.w.IsDead end)
        if dead ~= nil then
            local old = bt.down[pm.name]
            if old ~= nil and dead ~= old then
                M.dmg_push(dead and trf("%s is down", pm.name) or trf("%s is back up", pm.name))
            end
            bt.down[pm.name] = dead
        end
    end
    -- an enemy defeated: its Dead flag went on (M.bt_enemies), said once with the damage
    -- line -- only a change seen here, never an enemy first met dead
    bt.edead = bt.edead or {}
    for _, en in ipairs(M.bt_enemies()) do
        if en.dead and bt.edead[en.addr] == false then M.dmg_push(trf("%s defeated", en.name)) end
        bt.edead[en.addr] = en.dead
    end
    pcall(M.bt_lock_watch, bt, now)
    -- damage numbers gathered by the hooks: one line 0.25 s after the last of a burst
    if bt.dmgbuf and #bt.dmgbuf > 0 and now - (bt.dmg_t or 0) > 0.25 then
        local line = table.concat(bt.dmgbuf, ", ")
        bt.dmgbuf = {}
        speak(line, false)
    end
    -- the enemies, once at the start
    if not bt.started then
        local en = M.bt_enemies()
        if #en > 0 then
            bt.started = true
            local names = {}
            for _, e in ipairs(en) do
                names[#names + 1] = (bt.locks and bt.locks[e.addr]) and trf("%s, weaknesses locked", e.name) or e.name
            end
            speak(trf("Battle: %s", table.concat(names, ", ")))
            -- the battle manager, once now (one object search, during the battle's intro):
            -- a follower's turn and the turn order read from it (M.bt_actor, key 0)
            pcall(M.bt_manager)
        end
    end
    -- an action's name banner (BattleActionInfo_C, "Feuerball", an enemy's "Angriff"):
    -- spoken when its text CHANGES. The widget stays visible with the last text, also
    -- into the next battle -- so the first look only notes it (the battle-start
    -- passive "Gegner studieren" comes ~3 s later and is new). The same action twice
    -- in a row is said once. Only while the ActionInfoOpen hook (M.act_hook) isn't armed.
    for _, a in ipairs(M.act_armed and {} or M.bt_list("BattleActionInfo_C")) do
        if M.wvis(a) == 0 then
            local s = M.wtext(a.CommandName)
            if s and not M.placeholder(s) and s ~= bt.action then
                if bt.action ~= nil or bt.primed then speak(s) end
                bt.action = s
            end
        end
    end
    bt.primed = true
    -- a question on top (H'aanit's "Diesen Feind gefangen nehmen?") has the word: the
    -- command row under it ("Fangen") was said right after it and cut it off (2026-11-21)
    if dlg_visible then return end
    local tg = M.bt_targets()
    -- H'aanit's capture (and stealing in battle) picks its target without a target cursor
    -- (all cursors hidden, 2026-11-15): the enemy whose success rate shows is the target
    if #tg == 0 then
        for _, en in ipairs(M.bt_enemies()) do
            local sr
            pcall(function() sr = en.w.BattleSuccessRate end)
            local v = sr and M.wvis(sr)
            if v == 0 or v == 3 or v == 4 then
                if not bt.rate_logged then bt.rate_logged = true; log("BATTLE rate target " .. tostring(en.name)) end
                tg = { en.addr }
                break
            end
        end
    end
    -- our own input (menu or target cursor): the next action is that character's
    local mm = (#tg == 0) and M.bt_menu() or nil
    local input = (#tg > 0) or (mm ~= nil)
    if input then
        bt.menu_seen = true
        if mm and mm.who then bt.menu_who = mm.who end
    end
    if bt.input_was and not input then bt.menu_closed_t = now end
    bt.input_was = input
    if #tg > 0 then
        local sig = "T" .. table.concat(tg, ",")
        if sig ~= bt.said then
            bt.said = sig
            if #tg == 1 then speak(M.bt_describe(tg[1]) or tr("target"))
            else speak(trf("%d targets", #tg)) end
            -- for the capture question: the target with its chance (M.poll_dialog)
            bt.rate_line = (#tg == 1) and M.bt_rate_line(tg[1]) or nil
        end
        return
    end
    local m = mm   -- (read above, with the target check)
    if m and m.text then
        local sig = "M" .. m.floor .. ":" .. m.cur .. ":" .. m.text
        if sig ~= bt.said then
            local fresh = not (bt.said or ""):match("^M")   -- the menu (re)appeared
            if fresh and sig == bt.last_sig and now - (bt.last_t or -10) < 2.0 then
                bt.said = sig   -- it only flickered (opening the menu): nothing new
                bt.weapon = m.weapon
            else
                local s = m.text
                if m.add and not M.placeholder(m.add) then s = s .. ", " .. M.bt_addinfo(m.add); bt.add_said = sig end
                if m.weapon then s = s .. ", " .. m.weapon end   -- "Angriff, Speer" (M.bt_attr)
                bt.weapon = m.weapon
                if not m.usable then s = trf("%s, unavailable", s) end
                -- a new turn (the top menu just opened): whose
                if m.floor == 1 and fresh then
                    local who
                    for _, pm in ipairs(M.bt_party()) do if pm.addr == m.who then who = pm.name end end
                    if who then s = who .. ". " .. s end
                end
                bt.said = sig
                bt.item_said = m.text   -- (the row a call came from: a follower's name)
                bt.rate_line = nil
                speak(s)
                bt.help_at = now + 0.3
            end
        elseif m.weapon and m.weapon ~= bt.weapon then
            -- Left/Right on the same command: the weapon alone
            log(string.format("BATTLE weapon %s (%d to choose from, index %s)", m.weapon, m.wnum or 0,
                tostring(m.widx)))
            bt.weapon = m.weapon
            speak(m.weapon)
        end
        bt.last_sig, bt.last_t, bt.gone_t = sig, now, nil
        -- the boost level: say each change while the menu is up; the first time, also
        -- the keys from the boost help (BtR_Enable_Text "Ⓞ" raises, BtL_Text "Ⓠ" lowers)
        if bt.boost ~= nil and m.boost ~= bt.boost then
            local s = m.boost > 0 and trf("Boost %d", m.boost) or tr("No boost")
            if not M.boost_keys_said then
                M.boost_keys_said = true
                local function key_of(g)
                    local cp
                    pcall(function() cp = utf8.codepoint(g or "", 1) end)
                    if cp and cp >= 0x24B6 and cp <= 0x24CF then return string.char(cp - 0x24B6 + 65) end
                    return nil
                end
                for _, h in ipairs(M.bt_list("BattleCommandBoostHelp_C")) do
                    local up, down = key_of(M.wtext(h.BtR_Enable_Text)), key_of(M.wtext(h.BtL_Text))
                    if up and down then s = trf("%s. %s raises, %s lowers", s, up, down); break end
                end
            end
            speak(s)
        end
        bt.boost = m.boost
        -- the cost/count (TextAddInfo) may fill in a moment after the name: in a list
        -- (floor 2+) wait for it, at most 1.1 s, then say it before the help line
        local hasadd = m.add and not M.placeholder(m.add)
        if bt.help_at and now >= bt.help_at and (hasadd or bt.add_said == sig or m.floor < 2
            or now >= bt.help_at + 0.8) then
            bt.help_at = nil
            if bt.add_said ~= sig and hasadd then
                bt.add_said = sig
                speak(M.bt_addinfo(m.add), false)
            end
            local h = M.bt_help()
            if h and h ~= bt.help_said then
                bt.help_said = h
                speak(h, false)
            end
        end
    elseif bt.said and bt.said:match("^M") then
        -- the menu closed: an action runs. Gone for 0.6 s, so a flicker isn't a new turn
        bt.gone_t = bt.gone_t or now
        if now - bt.gone_t > 0.6 then bt.said, bt.gone_t, bt.boost = nil, nil, nil end
    end
end
-- The result screen ("Sieg!"): the panel's own totals (GetTotalMoney / Exp / JobPoint
-- ints: 25, 6 = 5 + break bonus, 5 in the first test), the level-ups and the drops
-- (BattleDropItemWidget_C texts), said as ONE line once the travelers' EXP count-up is
-- over; a level-up that shows after that is said on its own.
-- WHY WAIT (2026-11-17, user: "when two level up, only the last one is read"). The old
-- line came 1.5 s after the screen opened, before the count-up was done: "Sieg ... Tressa
-- erreicht Stufe 5", and a second later "Ophilia erreicht Stufe 8" on its own. The user
-- heard only the second and found the first in the history. The mod didn't cut it
-- (queued, and Prism's NVDA backend only cancels when told to): NVDA cuts speech at a key
-- press, and the key that skips the count-up (E, Enter, Backspace) is what makes the
-- level-ups show. Waiting for the count-up's end -- natural or skipped -- puts the key
-- press before the line. Seen in the game: BattleResultPlayerWidget_C.IsCountUp is true
-- from ~0.2 s to the end of the count-up; PlayerLevel rises and PlayLevelUp comes on at
-- its end, and the flag stays on. Fallbacks: no count-up seen in 2.5 s (no EXP), or 8 s.
-- Level-ups are watched from the first poll on: by the flag, or by a level that rose
-- since the screen opened (per widget address and name), a second level in one battle
-- is said too, and every change of a traveler's level, flag or count-up is logged ("BT
-- result"). Unused copies of the widget (level 0, a Japanese name) are left out.
M.poll_battle_result = function(w)
    local bt, now = M.bt, os.clock()
    local open = false
    pcall(function() open = w.ResultOpen end)
    if not open then return end
    bt.result_t = bt.result_t or now
    bt.lv_said = bt.lv_said or {}   -- name -> the level said
    bt.lv0 = bt.lv0 or {}           -- widget address + name -> the level when first read
    bt.lv_log = bt.lv_log or {}     -- widget address -> what the log said last
    bt.ups = bt.ups or {}           -- level-ups not said yet
    local counting = false
    -- (only the panels of travelers in this battle: in a duel the other three still showed
    -- the last full battle's party, one with its level-up flag on -- M.bt_in_battle)
    local panels = {}
    for _, pw in ipairs(M.bt_list("BattleResultPlayerWidget_C")) do
        panels[#panels + 1] = { w = pw, ch = M.peekp(pw, 0x258) }   -- TergetCharacter
    end
    for _, pe in ipairs(M.bt_in_battle(panels, "result")) do
        local pw = pe.w
        local name = M.wtext(pw.CharaName)
        local lv, up, cu, a = nil, false, nil, 0
        pcall(function() lv, up = pw.PlayerLevel, pw.PlayLevelUp end)
        if name and not M.placeholder(name) and lv ~= 0 then
            pcall(function() cu = pw.IsCountUp end)
            pcall(function() a = pw:GetAddress() end)
            if cu then counting = true end
            local sig = string.format("%s level %s, level-up %s, counting %s", name, tostring(lv), tostring(up), tostring(cu))
            local key = (a ~= 0) and a or name
            if bt.lv_log[key] ~= sig then
                bt.lv_log[key] = sig
                log(string.format("BT result %.1f s: %s", now - bt.result_t, sig))
            end
            if type(lv) == "number" then
                -- (the baseline per widget AND name: a slot that still showed another
                -- traveler's name and level from before can't "rise")
                local bk = (a ~= 0) and (tostring(a) .. "|" .. name) or nil
                if bk and lv >= 1 and not bt.lv0[bk] then bt.lv0[bk] = lv end
                local rose = bk ~= nil and bt.lv0[bk] ~= nil and lv > bt.lv0[bk]
                if (up or rose) and lv > (bt.lv_said[name] or 0) then
                    bt.lv_said[name] = lv
                    bt.ups[#bt.ups + 1] = trf("%s reaches level %s", name, tostring(lv))
                end
            end
        end
    end
    -- the count-up: seen running, then over for 0.3 s (the level-ups come at its end)
    if counting then bt.cu_seen, bt.cu_end = true, nil
    elseif bt.cu_seen and not bt.cu_end then bt.cu_end = now end
    local wait = now - bt.result_t
    local ready = (bt.cu_end ~= nil and now - bt.cu_end >= 0.3) or (not bt.cu_seen and wait >= 2.5) or wait >= 8
    if not bt.result_said and not ready then return end
    if not bt.result_said then
        log(string.format("BT result said at %.1f s (count-up %s)", wait,
            bt.cu_end and string.format("over at %.1f s", bt.cu_end - bt.result_t) or (bt.cu_seen and "still on" or "not seen")))
    end
    local ups = bt.ups
    bt.ups = {}
    if not bt.result_said then
        bt.result_said = true
        local ex, jp, mo
        pcall(function() ex, jp, mo = w.GetTotalExp, w.GetTotalJobPoint, w.GetTotalMoney end)
        -- (the money sign: speak() says it in the game's language -- "leaves" was fixed
        -- English, "20 leaves" in a German game, 2026-11-15)
        local parts = { trf("Victory. %s %s, %s EXP, %s JP", tostring(mo), M.MONEY_SIGN, tostring(ex),
            tostring(jp)) }
        for _, u in ipairs(ups) do parts[#parts + 1] = u end
        local drops = {}
        for _, d in ipairs(M.bt_list("BattleDropItemWidget_C")) do
            local n, c = M.wtext(d.Text_Name), M.wtext(d.Text_Num)
            if n and not M.placeholder(n) and M.wvis(d) == 0 then drops[#drops + 1] = c and (n .. " " .. c) or n end
        end
        if #drops > 0 then parts[#parts + 1] = trf("Items: %s", table.concat(drops, ", ")) end
        speak(table.concat(parts, ". "))
    elseif #ups > 0 then
        speak(table.concat(ups, ". "), false)
    end
end
-- DAMAGE NUMBERS. The digits on screen are material images, but BattleDamageNumber_C's
-- Blueprint events get the numbers as plain ints: PlayDamage(DamageValue, DamageType,
-- Owner), PlayRecoveryHP/MP/BP(RecoveryValue), PlayMiss(Owner), PlayBreak(Owner, ...).
-- Lua hooks on them (simple params, no structs), armed from the battle poll once the
-- class is loaded. A burst (one spell on all enemies) is gathered 0.25 s and said as
-- one line, queued after the action's name: "Eissentinel 54".
M.DMG_FN = "/Game/UI/Battle/BP/BattleDamageNumber.BattleDamageNumber_C:"
M.dmg_who = function(ctx, owner)   -- the hit character's name: the Owner param, else the
    local a                        -- widget's TargetCharacter (0x308, read raw)
    if owner then pcall(function() a = owner:get():GetAddress() end) end
    if (not a or a == 0) and ctx then pcall(function() a = M.peekp(ctx:get(), 0x308) end) end
    if not a or a == 0 then return nil end
    for _, en in ipairs(M.bt_enemies()) do if en.addr == a then return en.name end end
    for _, pm in ipairs(M.bt_party()) do if pm.addr == a then return pm.name end end
    for _, sp in ipairs(M.bt_supporters()) do if sp.addr == a then return sp.name end end
    return nil
end
M.dmg_push = function(s)
    M.bt.dmgbuf = M.bt.dmgbuf or {}
    M.bt.dmgbuf[#M.bt.dmgbuf + 1] = s
    M.bt.dmg_t = os.clock()
end
M.dmg_hook = function(kind)
    return function(ctx, p1, p2, p3)
        if M.trace then log("TR hook dmg " .. kind) end
        pcall(function()
            if kind == "damage" then
                -- DamageType seen (2026-11-14): 0 a plain hit, 3 a weakness (shield down),
                -- 4 a plain hit on a broken enemy, 5 a weakness on a broken enemy
                local v, t = p1:get(), nil
                pcall(function() t = p2:get() end)
                local who = M.dmg_who(ctx, p3)
                log(string.format("DMG %s %s type=%s", tostring(who), tostring(v), tostring(t)))
                M.dmg_push((who and (who .. " ") or "") .. tostring(v) .. ((t == 3 or t == 5) and (" " .. tr("weak")) or ""))
            elseif kind == "miss" or kind == "break" then
                local who = M.dmg_who(ctx, p1)
                log(string.format("DMG %s %s", kind, tostring(who)))
                M.dmg_push((who and (who .. " ") or "") .. (kind == "miss" and tr("miss") or tr("break")))
            else   -- recovery: "hp" / "sp" / "bp"
                local v = p1:get()
                local who = M.dmg_who(ctx, nil)
                log(string.format("DMG %s +%s %s", tostring(who), tostring(v), kind))
                M.dmg_push((who and (who .. " ") or "") .. "+" .. tostring(v) .. " " .. tr(({ hp = N_("HP"), sp = N_("SP"), bp = N_("BP") })[kind] or kind:upper()))
            end
        end)
    end
end
-- ACTIONS: BattleActionInfo_C:ActionInfoOpen (no params) opens the name banner; its
-- text was set just before (SetCommandName). Hooked, every action is said -- the same
-- one twice in a row too, which the text-change poll could not tell apart. With it:
-- Who acts. The order icons' ThisTurnOutline marks the whole round (both icons showed
-- it), and only an ENEMY's icon was IsFade when it acted (2026-11-14). So: an action
-- within 4 s after our own input (command menu or target cursor) is that menu's
-- character; otherwise an enemy -- the only one, or the one whose icon fades. Before
-- the battle's first menu (passives like "Gegner studieren", "Ihr habt Euren Feind ...
-- überrascht!") no name.
M.bt_actor = function()
    local bt = M.bt
    if not bt.menu_seen then return nil end
    -- (input_was: the last poll, <= 0.1 s ago, still saw our menu or target cursor --
    -- the action can start before the poll notices the input ended: Feuerball once
    -- came out as the enemy's)
    if bt.menu_who and (bt.input_was or (bt.menu_closed_t and os.clock() - bt.menu_closed_t < 4)) then
        bt.menu_closed_t, bt.input_was = nil, false
        -- (second value: it came from our own input)
        for _, pm in ipairs(M.bt_party()) do if pm.addr == bt.menu_who then return pm.name, true end end
    end
    local en = M.bt_living()   -- (a defeated one acts no more: the last one standing is it)
    local sup = M.bt_supporters()
    local present = 0
    for _, s in ipairs(sup) do if not s.gone then present = present + 1 end end
    -- a follower's own turn (the battle manager, M.bt_turn_state): its name -- the one the
    -- manager names as acting, else the one still fighting
    local ts = M.bt_turn_state()
    bt.turn_state = ts   -- (for the ACTION log line)
    if ts and ts.sup_turn then
        for _, s in ipairs(sup) do if s.addr == ts.action or s.addr == ts.active then return s.name end end
        for _, s in ipairs(sup) do if not s.gone then return s.name end end
        if sup[1] then return sup[1].name end
    end
    -- one enemy left is it -- not while a follower fights and no manager tells its turn
    if #en == 1 and (ts ~= nil or present == 0) then return en[1].name end
    local names = {}
    for _, e in ipairs(en) do names[e.addr] = e.name end
    for _, s in ipairs(sup) do names[s.addr] = s.name end
    for _, ic in ipairs(M.bt_list("ActionOrderIcon_C")) do
        local a, nx, fade = M.peekp(ic, 0x288), true, false   -- Character
        pcall(function() nx, fade = ic.IsNextOrder, ic.IsFade end)
        if a and names[a] and fade and not nx then return names[a] end
    end
    return nil
end
M.act_hook = function(ctx)
    if M.trace then log("TR hook act") end
    pcall(function()
        local s = M.wtext(ctx:get().CommandName)
        if not s or M.placeholder(s) then return end
        M.act_hook_ok = true
        M.bt.turn_state = nil
        local who, mine = M.bt_actor()
        -- a message, not an action ("Ihr habt die Bestie gefangen!" came out as the
        -- marmot's, 2026-11-15): no one in front
        if s:find("[%.!%?]$") and s:find(" ") then who, mine = nil, false end
        -- a called beast's own attack: H'aanit's "Linde", then "Feger" came out as the
        -- enemy's (2026-11-15). The beast's skills are in the help line of the command
        -- that called it ("Feger (Schwertangriff). Anspringen ..."), said just before.
        local bt = M.bt
        local prev = bt.prev_act
        -- (a follower: its name, not the command's -- "Rufen: Physischer Boost" for Meryls
        -- Mutter, 2026-11-20. It came with that call: one more in the fight than then.)
        local sn, sup_n = nil, 0
        local oks, sup = pcall(M.bt_supporters)
        for _, sp in ipairs(oks and sup or {}) do
            if not sp.gone then sup_n = sup_n + 1; sn = sp.name end
        end
        if prev and prev.mine and os.clock() - prev.t < 8 and prev.help and s ~= prev.name
            and prev.help:find(s, 1, true) then
            -- (else the menu row it was called from: "Meryls Mutter" under "Rufen", the
            -- beast's name under H'aanit's command)
            if sup_n == 1 and sup_n > (prev.sup_n or 0) then who = sn else who = prev.item or prev.name end
            mine = false
        end
        bt.prev_act = { name = s, mine = mine == true, t = os.clock(), help = bt.help_said, sup_n = sup_n,
            item = mine and bt.item_said or nil }
        M.bt.act_pending = (who and (who .. ": ") or "") .. s
        M.bt.action = s
        -- (what the battle manager said, while a follower fights: to check its fields)
        local ts, extra = M.bt.turn_state, ""
        if not ts and sup_n > 0 then ts = M.bt_turn_state() end
        if ts and sup_n > 0 then
            local function who_is(a)
                if not a or a == 0 then return "-" end
                for _, e in ipairs(M.bt_enemies()) do if e.addr == a then return e.name end end
                for _, p in ipairs(M.bt_party()) do if p.addr == a then return p.name end end
                for _, sp in ipairs(oks and sup or {}) do if sp.addr == a then return sp.name end end
                return string.format("%X", a)
            end
            extra = string.format(" [follower turn %s, action %s, active %s]", tostring(ts.sup_turn),
                who_is(ts.action), who_is(ts.active))
        end
        log("ACTION " .. M.bt.act_pending .. extra)
    end)
end
M.arm_act_hook = function()
    if M.act_armed then return end
    local ok, id = pcall(RegisterHook, "/Game/UI/Battle/BP/BattleActionInfo.BattleActionInfo_C:ActionInfoOpen",
        M.fg_guard(M.act_hook))
    if ok and id ~= nil then M.act_armed = true; log("Action hook ARMED") end
end
M.arm_dmg_hooks = function()
    if M.dmg_armed then return end
    local ok, id = pcall(RegisterHook, M.DMG_FN .. "PlayDamage", M.fg_guard(M.dmg_hook("damage")))
    if not (ok and id ~= nil) then return end   -- the class isn't loaded yet: next poll
    M.dmg_armed = true
    for fn, kind in pairs({ PlayRecoveryHP = "hp", PlayRecoveryMP = "sp", PlayRecoveryBP = "bp",
        PlayMiss = "miss", PlayBreak = "break" }) do
        pcall(RegisterHook, M.DMG_FN .. fn, M.fg_guard(M.dmg_hook(kind)))
    end
    log("Damage hooks ARMED")
end
-- 1-5: enemy N, 6-9: party member N-5, 0: turn order. Battle only.
M.bt_key = function(n)
    if not M.battle_now then return end
    local t0 = os.clock()
    local waited = M.key_t and (t0 - M.key_t) * 1000 or -1
    M.bt_key_read(n)
    log(string.format("BKEY %d: read %.0f ms after the press, took %.0f ms", n, waited, (os.clock() - t0) * 1000))
end
M.bt_key_read = function(n)
    if n >= 1 and n <= 5 then
        local en = M.bt_living()
        if en[n] then speak(trf("Enemy %d of %d: %s", n, #en, M.bt_enemy_text(en[n])))
        elseif #en == 0 and not M.bt.started then speak(tr("The battle is starting"))   -- (no panels yet)
        else speak(#en == 0 and tr("No enemies") or trn("Only %d enemy", "Only %d enemies", #en)) end
    elseif n >= 6 and n <= 9 then
        local pa = M.bt_party()
        if pa[n - 5] then speak(M.bt_party_text(pa[n - 5])) else speak(trf("No party member %d", n - 5)) end
    elseif n == 0 then
        pcall(M.bt_order)
    end
end
-- Turn order: the timeline's ActionOrderIcon_C widgets (visible, EnableActionOrder),
-- one per character and round; IsNextOrder marks the next round's row. (The
-- timeline's own InterceptIcon_0x slots stayed empty in tests.) Listed in widget
-- order -- the on-screen order of a bigger fight is still to be checked.
-- FROM THE CURRENT TURN (user 2026-11-20: at the round's last traveler key 0 said everyone
-- who had acted already). The battle manager (BattleManagerBP_C, object dump) knows whose
-- turn it is, ActiveCharacter (+0x3D8), and its BattleActionOrder (+0x3A0, a
-- BattleActionOrderBP_C) the round as characters: ActionOrder (+0x390, a TArray) this
-- round, NextOrder (+0x3A0) the next. Said from the active one on: "Jetzt: Therion.
-- Nächste Runde: ...". The manager is looked for once per battle (FindAllOf, the class
-- default skipped); without it, the icons as before.
M.BT_ACTIVE, M.BT_ORDER, M.BT_ROUND, M.BT_NEXT = 0x3D8, 0x3A0, 0x390, 0x3A0
M.bt_manager = function()
    local bt = M.bt
    local m = M.kept(bt.mgr_h)
    if m then return m end
    bt.mgr_h = nil
    local now = os.clock()
    if now - (bt.mgr_try or -99) < 5 then return nil end
    bt.mgr_try = now
    pcall(function()
        for _, o in pairs(FindAllOf("BattleManagerBP_C") or {}) do
            local fn = ""
            pcall(function() fn = o:GetFullName() end)
            if o:IsValid() and not fn:find("Default__", 1, true) then m = o; break end
        end
    end)
    bt.mgr_h = m and M.handle(m) or nil
    if m then log(string.format("BT manager %X", M.addr_of(m) or 0)) end
    return m
end
-- a TArray of object pointers at base+off, raw: { addr, ... }
M.bt_array = function(base, off)
    local out = {}
    local data, num = shim.Peek(base + off, "ptr"), shim.Peek(base + off + 8, "i32")
    if not data or data == 0 or not num or num <= 0 or num > 64 then return out end
    for i = 0, num - 1 do
        local p = shim.Peek(data + 8 * i, "ptr")
        if p and p ~= 0 then out[#out + 1] = p end
    end
    return out
end
-- names: addr -> name; broken: addr -> true. -> the line, or nil (no order readable)
M.bt_order_from = function(active, round, nxt, names, broken)
    local function nm(a) return broken[a] and trf("%s (broken)", names[a]) or names[a] end
    local start = 1
    for i, a in ipairs(round) do if a == active then start = i; break end end
    local now_l, next_l = {}, {}
    for i = start, #round do if names[round[i]] then now_l[#now_l + 1] = nm(round[i]) end end
    for _, a in ipairs(nxt) do if names[a] then next_l[#next_l + 1] = nm(a) end end
    if #now_l == 0 and #next_l == 0 then return nil end
    local s
    if #now_l > 0 then s = trf("Now: %s", table.concat(now_l, ", ")) end
    if #next_l > 0 then
        local nr = trf("Next round: %s", table.concat(next_l, ", "))
        s = s and (s .. ". " .. nr) or nr
    end
    return s
end
M.bt_order = function()
    local names = {}
    -- every enemy with its position, the number key that reads it ("Majesto-Murmeltier
    -- auf 2"): which of two of the same name acts when (user 2026-11-21)
    for i, en in ipairs(M.bt_living()) do names[en.addr] = M.bt_pos_name(en.name, i) end
    for _, pm in ipairs(M.bt_party()) do if pm.addr then names[pm.addr] = pm.name end end
    for _, sp in ipairs(M.bt_supporters()) do if not sp.gone then names[sp.addr] = sp.name end end
    local broken = {}
    for _, ic in ipairs(M.bt_list("ActionOrderIcon_C")) do
        local a, brk = M.peekp(ic, 0x288), false
        pcall(function() brk = ic.IsBreak end)
        if a and brk then broken[a] = true end
    end
    local mgr = M.bt_manager()
    local ma = mgr and M.addr_of(mgr)
    local ord = ma and shim.Peek(ma + M.BT_ORDER, "ptr")
    if ord and ord ~= 0 then
        local active = shim.Peek(ma + M.BT_ACTIVE, "ptr")
        local round, nxt = M.bt_array(ord, M.BT_ROUND), M.bt_array(ord, M.BT_NEXT)
        local raw = {}
        for _, a in ipairs(round) do raw[#raw + 1] = (a == active and "*" or "") .. (names[a] or string.format("%X", a)) end
        log(string.format("BT order: round [%s], next %d, active %s", table.concat(raw, ", "), #nxt,
            tostring(active and names[active] or active)))
        local s = M.bt_order_from(active, round, nxt, names, broken)
        if s then speak(s); return end
    end
    local now_l, next_l = {}, {}
    for _, ic in ipairs(M.bt_list("ActionOrderIcon_C")) do
        local en, a = false, M.peekp(ic, 0x288)   -- Character
        pcall(function() en = ic.EnableActionOrder end)
        if en and a and names[a] and M.wvis(ic) == 0 then
            local nx, brk = false, false
            pcall(function() nx, brk = ic.IsNextOrder, ic.IsBreak end)
            local s = brk and trf("%s (broken)", names[a]) or names[a]
            if nx then next_l[#next_l + 1] = s else now_l[#now_l + 1] = s end
        end
    end
    if #now_l == 0 and #next_l == 0 then speak(tr("Turn order unknown")); return end
    local s = trf("This round: %s", #now_l > 0 and table.concat(now_l, ", ") or tr("none"))
    if #next_l > 0 then s = trf("%s. Next: %s", s, table.concat(next_l, ", ")) end
    speak(s)
end
for n = 0, 9 do
    local kn = ({ "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" })[n + 1]
    pcall(function()
        RegisterKeyBind(Key[kn], function()
            if M.battle_now then M.in_gt(function() pcall(M.bt_key, n) end) end
        end)
    end)
end

-- The screen polls, ON THE GAME THREAD since 2026-11-14. On the async loop they raced
-- the game (the game died while idle in a menu) and their UFunction calls took queued
-- game-thread work. They used to be far too slow for the game thread (each FindFirstOf
-- of a closed screen walks every object, 45-80 ms -- that froze the start once); now
-- get_active_screen and poll_saveload search at most every 1-2 s. A slow run is logged.
-- Capture title widgets at this rate (20Hz) so the title menu reads immediately; the
-- pump only ticks ~5Hz, which made it read seconds late. Pre-game only (not
-- M.field_player) and never mid-fade (M.menu_unsafe).
-- ===== Updates (2026-11-14) =====
-- A release has Scripts\buildinfo.lua (written by scripts/package.ps1) with its version and the
-- GitHub repository. Then the mod asks GitHub for the latest release when it loads (the shim's
-- HTTP thread; no game calls) and says when a newer one is out. F5 checks again; F5 twice
-- installs it: the mod starts OP1AccessInstaller.exe from its folder with --update --restart
-- --game <game folder> and closes the game; the installer updates and starts the game again.
-- Development copies (no buildinfo.lua) don't check.
do
    local extra = M.MOD_DIR .. "Scripts\\?.lua"
    if not package.path:find(extra, 1, true) then package.path = extra .. ";" .. package.path end
end
M.build = {}
do
    local okb, bi = pcall(require, "buildinfo")
    if okb and type(bi) == "table" then M.build = bi end
    log(string.format("build: version %s, update source %s", tostring(M.build.version or "dev"),
        tostring(M.build.repo ~= "" and M.build.repo or "none")))
end
M.upd = { confirm_until = -1 }
M.has_update_source = function() return type(M.build.repo) == "string" and M.build.repo ~= "" end
-- "v1.2.3" / "1.2" -> { 1, 2, 3 }, or nil
M.version_parse = function(s)
    local a, b, c = tostring(s or ""):match("^[vV]?(%d+)%.(%d+)%.?(%d*)")
    if not a then return nil end
    return { tonumber(a), tonumber(b), tonumber(c) or 0 }
end
M.version_newer = function(x, y)
    local a, b = M.version_parse(x), M.version_parse(y)
    if not (a and b) then return false end
    for i = 1, 3 do
        if a[i] ~= b[i] then return a[i] > b[i] end
    end
    return false
end
M.update_check = function(manual)
    if not (M.has_update_source() and shim and shim.HttpGetStart) then return false end
    local url = "https://api.github.com/repos/" .. M.build.repo .. "/releases/latest"
    if not shim.HttpGetStart(url, "OP1Access/" .. tostring(M.build.version)) then return false end
    M.upd.pending, M.upd.manual = true, manual
    return true
end
-- From the polling loop (no game calls: only the shim's HTTP result and speech).
M.update_poll = function()
    if not (M.upd.pending and shim and shim.HttpGetPoll) then return end
    local status, body = shim.HttpGetPoll()
    if status == nil then return end
    M.upd.pending = false
    local manual = M.upd.manual
    if status == 404 then
        M.upd.latest = nil
        log("UPDATE no release published yet")
        if manual then speak(tr("No release of OP1 Access is published yet")) end
        return
    end
    if status ~= 200 or type(body) ~= "string" then
        log("UPDATE check failed: " .. tostring(status) .. " " .. tostring(status == false and body or ""))
        if manual then speak(tr("Could not check for updates")) end
        return
    end
    local tag = body:match('"tag_name"%s*:%s*"([^"]+)"')
    M.upd.latest = tag
    M.upd.page = body:match('"html_url"%s*:%s*"([^"]+)"')
    log(string.format("UPDATE latest release %s, this version %s", tostring(tag), tostring(M.build.version)))
    if tag and M.version_newer(tag, M.build.version) then
        if manual or M.upd.announced ~= tag then
            M.upd.announced = tag
            speak(trf("OP1 Access %s is available. Press F5 twice to install it.", (tag:gsub("^[vV]", ""))), manual)
        end
    elseif manual then
        speak(trf("OP1 Access is up to date, version %s", tostring(M.build.version)))
    end
end
M.update_key = function()
    -- Ctrl+F5 is the menu dump; don't count it as an F5 press (if UE4SS fires both)
    if shim and shim.KeyModifiers then
        local ctrl, shift, alt = shim.KeyModifiers()
        if ctrl or shift or alt then return end
    end
    if not M.has_update_source() then
        speak(tr("This copy of OP1 Access has no update source"))
        return
    end
    if M.upd.pending then speak(tr("Checking for updates")); return end
    local tag = M.upd.latest
    if tag and M.version_newer(tag, M.build.version) then
        if os.clock() <= M.upd.confirm_until then
            M.upd.confirm_until = -1
            M.update_install()
            return
        end
        M.upd.confirm_until = os.clock() + 10
        speak(trf("Version %s. Press F5 again to install it. The game closes without saving and starts again.",
            (tag:gsub("^[vV]", ""))), true)
        return
    end
    speak(tr("Checking for updates"))
    if not M.update_check(true) then speak(tr("Could not check for updates")) end
end
M.update_install = function()
    -- ...\OCTOPATH TRAVELER\Octopath_Traveler\Binaries\Win64\Octopath_Traveler-Win64-Shipping.exe
    -- (paths stay UTF-8 strings for the shim; Lua's io.open can't open non-ASCII paths)
    local bin = M.bin_dir()
    local game = bin and bin:match("^(.*)\\[^\\]+\\[^\\]+\\[^\\]+$")
    local ok, err = false, "no game folder"
    if game and shim.StartProcess then
        ok, err = shim.StartProcess(M.mod_dir_abs() .. "OP1AccessInstaller.exe",
            '--update --restart --game "' .. game .. '"')
    end
    if not ok then
        log("UPDATE could not start the installer: " .. tostring(err))
        speak(tr("Could not start the installer. Opening the download page."), true)
        local page = M.upd.page or ("https://github.com/" .. M.build.repo .. "/releases/latest")
        pcall(shim.StartProcess, (os.getenv("SystemRoot") or "C:\\Windows") .. "\\explorer.exe", '"' .. page .. '"')
        return
    end
    log("UPDATE installer started for " .. tostring(M.upd.latest) .. ", closing the game")
    speak(tr("Installing the update. The game closes now."), true)
    -- after a moment for the speech; the installer waits until the game has ended
    local okc, closing = pcall(shim.CloseGame, 1500)
    log("UPDATE closing the game: " .. tostring(okc and closing))
end
pcall(RegisterKeyBind, Key.F5, function() pcall(M.update_key) end)
if M.has_update_source() then pcall(M.update_check, false) end

-- ===== Problem reports (2026-11-23) =====
-- F1 twice opens the installer's "Report a problem" window beside the game, which keeps
-- running: OP1AccessInstaller.exe --report --game <game folder>. The window takes a
-- description and an e-mail address for questions and attaches the session logs
-- (logs\session-1..3.log), UE4SS.log and, if wanted, the game's crash dumps; it sends
-- them to the developer through Static Forms. A release built without the form key has
-- report = false in buildinfo.lua, and F1 says so instead.
M.report = { confirm_until = -1 }
M.report_key = function()
    if M.build.report == false then
        speak(tr("Problem reports are not available in this build"), true)
        return
    end
    if os.clock() > M.report.confirm_until then
        M.report.confirm_until = os.clock() + 10
        speak(tr("Report a problem: press F1 again. A window opens beside the game, the game keeps running."), true)
        return
    end
    M.report.confirm_until = -1
    local bin = M.bin_dir()
    local game = bin and bin:match("^(.*)\\[^\\]+\\[^\\]+\\[^\\]+$")
    local ok, err = false, "no game folder"
    if game and shim and shim.StartProcess then
        ok, err = shim.StartProcess(M.mod_dir_abs() .. "OP1AccessInstaller.exe", '--report --game "' .. game .. '"')
    end
    if not ok then
        log("REPORT could not start the installer: " .. tostring(err))
        speak(tr("Could not open the problem report window"), true)
        return
    end
    log("REPORT window started")
    speak(tr("Opening the problem report window"), true)
end
pcall(RegisterKeyBind, Key.F1, function() pcall(M.report_key) end)

M.fast_steps = {
    { "prune", function() M.sw_prune() end },   -- freed screen widgets out, before any reader
    { "lang", function() M.game_lang() end },   -- the text language, before anything speaks
    { "scan", function() if M.scan_scene and not M.field_player and not M.menu_unsafe then M.scan_scene() end end },
    { "active", function() poll_active_menu() end },
    { "saveload", function() M.poll_saveload() end },
    { "options", function() M.poll_options() end },
    { "mainmenu", function() M.poll_mainmenu() end },
    { "status", function() M.poll_status() end },
    { "journal", function() M.poll_journal() end },
    { "worldmap", function() M.poll_worldmap() end },
    { "gameover", function() M.poll_gameover() end },
    { "shop", function() M.poll_shop() end },
    { "tutorial", function() M.poll_tutorial() end },
    { "fieldcmd", function() M.poll_fieldcommand() end },
    { "fcscreens", function() M.poll_fc_screens() end },
    { "tavern", function() M.poll_tavern() end },
    { "notice", function() M.poll_notice() end },
}
M.fast_polls = function()
    M.fast_run = {}
    local t0, slow = os.clock(), nil
    for _, s in ipairs(M.fast_steps) do
        local ts = os.clock()
        if M.trace then log("TR fast " .. s[1]) end   -- (crash hunting: the last line names it)
        pcall(s[2])
        local d = os.clock() - ts
        if d > 0.015 then slow = (slow and (slow .. " ") or "") .. string.format("%s=%.0f", s[1], d * 1000) end
    end
    M.fast_run = nil
    local dt = os.clock() - t0
    -- a slow run stalls the game: log it, at most every 10 s, with the count meanwhile
    if dt > 0.02 then
        M.fast_slow = (M.fast_slow or 0) + 1
        if os.clock() - (M.fast_slow_t or -99) > 10 then
            M.fast_slow_t = os.clock()
            log(string.format("FAST polls slow: %.0f ms [%s] (%d slow runs so far)", dt * 1000, tostring(slow),
                M.fast_slow))
        end
    end
end
-- The polling loop's work, one tick (from the LoopAsync below, a game-thread timer)
M.ok_tick = function()
    pcall(M.update_poll)   -- the release check's answer (no game calls)
    if not M.fg_ok() then return end   -- unfocused: skip menu polls (game calls fault)
    pcall(M.event_menus_tick)
    if M.menu_lists_tick then pcall(M.menu_lists_tick) end
    pcall(M.fast_polls)   -- the screen polls
    -- work queued in a game-thread run's last round waits in M.gt_pending (M.in_gt); an
    -- empty run picks it up
    if #M.gt_pending > 0 and M.gt_depth == 0 then M.in_gt(function() end) end
    -- (Dialogue: the native GetTalkText hook speaks it; talkable-NPC learning runs in the
    -- radar pump.)
end
local ok_loop = pcall(LoopAsync, POLL_INTERVAL_MS, M.ok_tick)
log("Polling loop started: " .. tostring(ok_loop))
-- (Dialogs, title confirms and in-game prompts alike, are read by poll_dialog.)

-- Phase 0 boot announce
log("script loaded; shim=" .. tostring(shim ~= nil))
if shim and shim.IsSpeakingSupported then
    local backend = shim.DetectScreenReader and shim.DetectScreenReader()
    log("speech backend: " .. tostring(backend) .. ", can speak: " .. tostring(shim.IsSpeakingSupported()))
end
speak(tr("OP1 Access loaded"))

-- ---------------------------------------------------------------------------
-- Dev key bindings
-- ---------------------------------------------------------------------------
pcall(RegisterKeyBind, Key.F11, { ModifierKey.CONTROL }, function()
    speak(tr("Dumping headers"))
    local ok = pcall(GenerateUHTCompatibleHeaders)
    speak(ok and tr("Dump complete") or tr("Dump failed"))
end)
pcall(RegisterKeyBind, Key.F12, { ModifierKey.CONTROL }, function()
    speak(tr("Dumping objects"))
    local ok = pcall(DumpAllObjects)
    speak(ok and tr("Object dump complete") or tr("Dump failed"))
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
    if ax < 0.5 and ay < 0.5 then return tr("here") end
    local horiz = (dx >= 0) and "east" or "west"
    local vert  = (dy >= 0) and "south" or "north"
    if ax > ay * 2.5 then return tr(horiz) end
    if ay > ax * 2.5 then return tr(vert) end
    return tr(vert .. "-" .. horiz)
end

-- Distance word relative to the map's own scale; nil => mid-range, omitted.
local function cs_distance_word(d)
    if not cs_pos_diag then return nil end
    local frac = d / cs_pos_diag
    if frac < 0.10 then return tr("very near")
    elseif frac < 0.22 then return tr("near")
    elseif frac >= 0.45 then return tr("far") end
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
        if e[2] == "TitlePlayerSelect_C" and M.sw_ok(e) then
            local w, x, y = probe(e[1])
            if w then return w, x, y end
        end
    end
    -- the kept instance only through its registry entry's handle (review 2026-11-16: it
    -- was probed unchecked when its entry failed M.sw_ok, before the next prune); an
    -- instance without an entry was pruned and isn't touched
    for i = 1, #scene_widgets do
        local e = scene_widgets[i]
        if e[1] == cs_instance then
            if M.sw_ok(e) then return probe(cs_instance) end
            return nil
        end
    end
    return nil
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
            -- ...except the character select left with "Ja": the adventure starts, and
            -- "Choose your character" came again before the first scene (2026-11-15)
            if not (last_polled_class == "TitlePlayerSelect_C" and dlg_last_focus == 0) then
                last_polled_class = nil
            end
            last_select_owner, last_select_value = nil, nil
            M.dlg_closed_t = os.clock()
            -- "Ja" (the first answer) on the question over the load list: a load starts.
            -- Its area banner and "N objects here" are said again even for the place
            -- you were at (2026-11-16: after "Return to Title" the same save loaded in
            -- silence) -- reset when the load's fade comes up (radar pump), not before:
            -- the old world's banner still holds its text until then.
            if dlg_last_focus == 0 and M.sl_save_mode == false and M.sl_seen_t
                and os.clock() - M.sl_seen_t < 60 then
                M.load_pending, M.load_pending_t = true, os.clock()
                log("LOAD confirmed: area and object count will be said again")
            end
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
    -- How many answers the dialog SHOWS: its SetupDialog sets AnswerNum to the NowParam
    -- buttons it put up (0 = none, the answer area hidden). The Answer_0x widgets keep
    -- the last question's texts while hidden -- the save point's "Now saving... Please
    -- wait..." (no buttons, in the window of the save question) was read with "Yes", and
    -- "Save successful." with "OK|No" (player report 2026-11-24). nil if unreadable: as
    -- before.
    local shown
    pcall(function()
        local n = inst.AnswerNum
        if type(n) == "number" and n >= 0 and n <= 4 then shown = n end
    end)
    if shown and #buttons > shown then
        for i = #buttons, shown + 1, -1 do buttons[i] = nil end
    end
    -- Fallback for the buttons if the NowParam array doesn't marshal: read the
    -- Answer_01..04 widgets (these read fine before), skipping "000" placeholders --
    -- only the ones the dialog shows.
    if #buttons == 0 and shown ~= 0 then
        for i = 1, shown or 4 do
            local t
            pcall(function() local item = inst["Answer_0" .. i]; if item then t = read_text_block(item, "Text") end end)
            if t and t ~= "" and t ~= "000" then buttons[#buttons + 1] = t end
        end
    end
    -- No answers: a pop-up that closes by itself ("Now saving...") is read for its text
    -- alone; one without text either (the cached launch dialog, its NowParam empty) is
    -- not a dialog we read.
    local textonly = (#buttons == 0 and shown == 0 and (caption ~= "" or detail ~= ""))
    if #buttons == 0 and not textonly then
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

    -- the same dialog window asking something else (Primrose's second question, "Ihr könnt
    -- nur eine Person verführen ...", came in the window of the first, 2026-11-15): new
    local dsig = caption .. "|" .. detail .. "|" .. table.concat(buttons, "|")
    if dlg_visible and M.dlg_sig and dsig ~= M.dlg_sig then
        log("DLG content changed: a new question in the same window")
        dlg_visible = false
    end
    M.dlg_sig = dsig

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
        -- (not inside an event: that reader runs FindAllOf). Only that result dialog:
        -- it has no text of its own (its buttons read "In Ordnung|Nein", a leftover of the
        -- question). The question before the action ("Erfolgschance: 90 %", Ja/Nein) has
        -- the panel's design texts under it -- it says whom the action is aimed at instead
        local result_dlg = (detail == "" and caption == "")
        if not desc and M.fc_result_text and not M.evm_active and result_dlg then
            local okr, r = pcall(M.fc_result_text, inst)
            if okr then desc = r end
        end
        -- the other path actions' questions: the item (Purchase / Steal) or the person's
        -- panel (Challenge / Provoke / Guide / Allure) in front
        if not desc and not result_dlg and M.fc_dialog_desc then
            local okd, d = pcall(M.fc_dialog_desc, inst)
            if okd and d then desc = d end
        end
        -- in battle, H'aanit's capture question after its target: the target and its chance
        -- in front ("Majesto-Murmeltier, Erfolgschance 100 %. Diesen Feind gefangen nehmen?")
        -- -- the target line before it was cut off by it (2026-11-21)
        if not desc and M.battle_now and M.bt and M.bt.rate_line then desc = M.bt.rate_line end
        -- (the purchase question names the item in its caption already: said twice)
        if desc and desc == caption then desc = nil end
        if not desc and not result_dlg and #buttons >= 2 and M.fc_busy and M.fc_target_name then
            local okf, busy = pcall(M.fc_busy)
            if okf and busy then
                local okn, nm = pcall(M.fc_target_name)
                if okn and nm then desc = nm end
            end
        end
        -- the learn-skill dialog's LBP lines, attached under its caption (main menu only:
        -- the search walks every object, too slow for the game-thread event reader; not
        -- on the title before a game is loaded, where no skill can be learned)
        local extra
        M.dlg_extra_at = nil
        if M.menu_now and not M.evm_active and M.field_player and M.dlg_parts_text then
            local okx, x = pcall(M.dlg_parts_text)
            if okx then extra = x end
            -- the game may fill them a moment after the dialog shows: one more look
            if not extra then M.dlg_extra_at = os.clock() + 0.3 end
        end
        log(string.format("DLG open: caption=%s detail=%s buttons=[%s] focus=%s default=%s ef=%s desc=%s extra=%s",
            tostring(caption), tostring(detail), table.concat(buttons, "|"),
            tostring(focus), tostring(default), tostring(ef), tostring(desc), tostring(extra)))
        local parts = {}
        if desc and desc ~= "" then parts[#parts + 1] = desc end
        if caption ~= "" then parts[#parts + 1] = caption end
        if extra and extra ~= "" then parts[#parts + 1] = extra end
        if detail  ~= "" then parts[#parts + 1] = detail end
        if focused and focused ~= "" then parts[#parts + 1] = focused end  -- only the selected answer
        if #parts > 0 then speak(M.join_sentences(parts)) end
    elseif focus and focus >= 0 and focus ~= dlg_last_focus then
        dlg_last_focus = focus
        log(string.format("DLG focus -> %s = %s", tostring(focus), tostring(focused)))
        if focused and focused ~= "" then speak(focused) end
    elseif M.dlg_extra_at and os.clock() >= M.dlg_extra_at then
        M.dlg_extra_at = nil
        local okx, x = pcall(M.dlg_parts_text)
        if okx and x then speak(x, false) end
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
            if scene_widgets[i][2] == "TitlePlayerSelect_C" and M.sw_ok(scene_widgets[i]) then
                n = n + 1
                local w = scene_widgets[i][1]
                if widget_is_visible(w) then vis = vis + 1 end
                local px
                pcall(function() local p = w.PlayerPositionMoved; if p then px = p.X end end)
                if px ~= nil then rd = rd + 1 end
            end
        end
        if vis > 0 or instance then     -- not once a second for the whole game after it
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
        speak(trf("%d, %d", cx, cy))
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
        if entry[2] == cls and M.sw_ok(entry) then
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
        speak(tr("Character cycle is only active on character select"))
        return
    end

    local fn_name = (direction > 0) and "SelectDownMove" or "SelectUpMove"
    local called = false
    pcall(function() instance[fn_name](instance); called = true end)
    if not called then
        log("cycle: " .. fn_name .. " call failed (BP function not callable)")
        speak(tr("Cycle unavailable"))
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
    ExecuteWithDelay(300, function() M.in_gt(function()   -- (game thread)
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
    end) end)
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
            if nav_keys.wm and nav_keys.wm(-1) then return end   -- the world map's places
            if nav_keys.obj and nav_keys.obj(-1) then return end
            cycle_player_select(-1)
        end)
        log("Bound Page Up cycle: " .. tostring(ok))
    end
    if down then
        local ok = pcall(RegisterKeyBind, down, function()
            if nav_keys.wm and nav_keys.wm(1) then return end   -- the world map's places
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
            speak(trf("%d, %d", cx, cy))
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
    -- (after the key's own work: M.in_gt)
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
    ExecuteWithDelay(250, function() M.in_gt(function()   -- (game thread)
        if mygen ~= cs_noop_gen then return end          -- superseded by a newer press
        if dlg_visible then return end                   -- a dialog opened during the wait
        local i2, x2, y2 = cs_live_instance()
        if not i2 or not x2 or not y2 then return end
        local cx2, cy2 = math.floor(x2 + 0.5), math.floor(y2 + 0.5)
        if cx2 == px and cy2 == py then                  -- cursor never moved
            local label = (cs_move_key and pressed == CS_OPP[cs_move_key]) and tr("reversing") or tr("blocked")
            speak(trf("%s, %d, %d", label, cx2, cy2))
        else
            cs_announce(i2, x2, y2)       -- moved: announce where we landed (works w/o the loop)
        end
    end) end)
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
        speak(tr("No characters mapped yet. Give it a second, then try again."))
        return
    end

    local bN, bD, tx, ty
    for _, c in ipairs(cand) do
        local d = math.sqrt((c.x - cx) ^ 2 + (c.y - cy) ^ 2)
        if not bD or d < bD then bN, bD, tx, ty = c.name, d, c.x, c.y end
    end
    local who = (bN and bN ~= "" and bN ~= "nil") and bN or tr("Character")
    if bD < 30 then speak(trf("%s, here", who)); return end
    local dx, dy = tx - cx, ty - cy
    local parts = {}
    if math.abs(dy) >= 20 then local kw = cs_key_toward("y", dy > 0 and 1 or -1); if kw then parts[#parts + 1] = tr(CS_KEYWORD[kw]) end end
    if math.abs(dx) >= 20 then local kw = cs_key_toward("x", dx > 0 and 1 or -1); if kw then parts[#parts + 1] = tr(CS_KEYWORD[kw]) end end
    if #parts > 0 then
        speak(trf("%s, %s. At %d, %d", who,
            table.concat(parts, tr(" and ")), math.floor(tx + 0.5), math.floor(ty + 0.5)))
    else
        speak(trf("%s, at %d, %d", who, math.floor(tx + 0.5), math.floor(ty + 0.5)))
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
        if M.sw_ok(entry) and widget_is_visible(w) then
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
        speak(tr(SCENE_LABELS[last_spoken_class] or last_spoken_class))
    else
        speak(tr("No menu detected"))
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
    -- (the kept one only while the shim's reads show the same object: M.fcmd_h)
    if fcmd_mgr and M.kept(M.fcmd_h) then return fcmd_mgr, "cache" end
    fcmd_mgr, M.fcmd_h = nil, nil
    pcall(function()
        local cdo = StaticFindObject("/Script/Octopath_Traveler.Default__FieldCommandManager")
        if cdo then fcmd_mgr = cdo:GetInstance() end
    end)
    local ok = false
    pcall(function() ok = fcmd_mgr ~= nil and fcmd_mgr:IsValid() end)
    if ok then M.fcmd_h = M.handle(fcmd_mgr); return fcmd_mgr, "GetInstance" end
    fcmd_mgr = nil
    pcall(function() fcmd_mgr = FindFirstOf("FieldCommandManagerBP_C") end)
    pcall(function() ok = fcmd_mgr ~= nil and fcmd_mgr:IsValid() end)
    if ok then M.fcmd_h = M.handle(fcmd_mgr); return fcmd_mgr, "FindFirstOf" end
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
                    names[#names + 1] = FIELD_CMD_NAME[b] or trf("command %s", b)
                end
            end)
        end
    end)
    return names, raw
end
local function announce_interactions()
    local mgr, how = get_fcmd_mgr()
    if not mgr then log("FCMD: no manager"); speak(tr("No interaction here")); return end
    local names, raw = read_active_commands(mgr)
    log(string.format("FCMD via %s: n=%d types=[%s]", how, #raw, table.concat(raw, ",")))
    if #names == 0 then speak(tr("Nothing to interact with")); return end
    -- the path actions by the game's own names ("Studieren"); 0 stays "Talk"
    for i, b in ipairs(raw) do
        if b ~= 0 and M.fc_type_name then names[i] = M.fc_type_name(b) end
    end
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
-- OBJECT LISTS, KEPT (2026-11-15, user: the navigator's categories answered slowly).
-- A kept object handle is touched again only after the shim's SEH-guarded reads show its
-- memory still holds the same object: same vtable and class, not being destroyed
-- (UObjectBase in 4.18: ObjectFlags +0x8, ClassPrivate +0x10; RF_BeginDestroyed 0x8000,
-- RF_FinishDestroyed 0x10000). UE4SS's own IsValid on a freed object can fault inside IsA,
-- which pcall can't catch (see beacon_step).
M.handle = function(o)
    local h
    pcall(function()
        local a = o:GetAddress()
        if a and a ~= 0 then
            h = { o = o, a = a, vt = shim.Peek(a, "ptr"), cls = shim.Peek(a + 0x10, "ptr") }
        end
    end)
    if h and h.vt and h.cls then return h end
    return nil
end
M.handle_ok = function(h)
    if not h then return false end
    local vt, cls, fl
    pcall(function()
        vt = shim.Peek(h.a, "ptr"); cls = shim.Peek(h.a + 0x10, "ptr"); fl = shim.Peek(h.a + 8, "i32")
    end)
    return vt == h.vt and cls == h.cls and fl ~= nil and (math.floor(fl) & 0x18000) == 0
end
-- The object of a handle while it lives, else nil: the shim's reads first, then UE4SS's
-- IsValid. For the managers and widgets kept between polls (2026-11-16: the balloon and
-- level managers, the area banner, the action prompt, KSFade ... had only IsValid).
M.kept = function(h)
    if not M.handle_ok(h) then return nil end
    local ok = false
    pcall(function() ok = h.o:IsValid() end)
    return ok and h.o or nil
end

-- The level the player is in (LevelManagerBP_C.CurrentLevelID, e.g. 77 = the academy's
-- map). One level holds several areas (the banner changes between them, nothing loads),
-- and it changes the moment a new map is there -- the area banner only a second later.
-- nil while a fade is on or before the manager is found.
M.level_id = function()
    if M.fade_now then return nil end
    local h = M.levelmgr_h
    if not M.handle_ok(h) then
        h = nil
        M.levelmgr_h = nil
        local now = os.clock()
        if now - (M.levelmgr_t or -10) < 5.0 then return nil end
        M.levelmgr_t = now
        pcall(function()
            local lm = FindFirstOf("LevelManagerBP_C")
            if lm and lm:IsValid() then h = M.handle(lm) end
        end)
        M.levelmgr_h = h
        if not h then return nil end
    end
    local id
    pcall(function() id = h.o.CurrentLevelID end)
    return id
end

-- Which map you are on, for what is remembered per place (unreachable targets, the
-- background checks, a route cut short): the level AND the area banner. The banner alone
-- outlived a fast travel (no banner came, 2026-11-23). In a fade (no level read) the last
-- level known: a route cut short by a battle's transition still walks on after it.
M.map_id = function()
    local lv = M.level_id()
    if lv then M.map_lv = lv else lv = M.map_lv end
    return tostring(lv or "?") .. "|" .. tostring(M.area_said)
end

-- Every FindAllOf walks all objects: 45-80 ms on the game thread. A category press did
-- one or two (its class, and the house doors for "inside a building"), the marker
-- category three or four (people, chests, exits, events), and the radar's rescan after
-- every dialogue five. The lists are now kept per class while you stay in one level:
-- dropped when a scene or a transition starts or ends (the map may change behind it),
-- when the level changes, after ttl seconds (callers: 10 min; with 30 / 60 s, and 2 min
-- for people, a press a minute later still scanned), when a new marker comes up
-- (M.marker_watch), and as soon as one kept object is gone.
-- The radar's rescan right after you arrive fills them, so the navigator's first press
-- is quick too. (Keyed by the area banner first: it comes a second after the rescan,
-- so every first press in an area scanned again, 80-160 ms.)
M.fa_cache = {}
M.find_all = function(cls, ttl)
    local key = M.level_id() or M.area_said
    local c = M.fa_cache[cls]
    local now = os.clock()
    if c and c.key == key and now - c.t < (ttl or 30) then
        local all_ok = true
        for _, h in ipairs(c.hs) do
            if not M.handle_ok(h) then all_ok = false; break end
        end
        if all_ok then return c.list end
        log("FINDALL " .. cls .. ": a kept object is gone, scanning again")
    end
    local hs, list = {}, {}
    pcall(function()
        local all = FindAllOf(cls)
        if all then
            for _, o in pairs(all) do
                local h = M.handle(o)
                if h then hs[#hs + 1] = h; list[#list + 1] = o end
            end
        end
    end)
    M.fa_cache[cls] = { key = key, t = now, hs = hs, list = list }
    log(string.format("FINDALL %s: %d in %.0f ms (level %s)", cls, #list, (os.clock() - now) * 1000, tostring(key)))
    return list
end
M.fa_flush = function() M.fa_cache = {} end
-- The level's fixed parts (exits, doors, shop counters) outlive a plain dialogue: the
-- radar's rescan after each one searched for them again (~78 ms each, ~390 ms with
-- chests and people; known issue 2026-11-15). Their lists are set aside when a scene
-- starts and put back at its end if no fade came and the level is the same; every kept
-- object's handle is still checked at each use (M.find_all). People and chests are
-- searched again: a scene can move people, and a reward can be a new chest.
M.FA_STATIC = { LevelTrigger_C = true, HouseEnterTriggerBP_C = true, ShopTriggerBP_C = true }
M.fa_set_aside = function()
    local keep, key = {}, M.level_id() or M.area_said
    for cls in pairs(M.FA_STATIC) do
        local c = M.fa_cache[cls]
        if c and key ~= nil and c.key == key then keep[cls] = c end
    end
    M.fa_keep = next(keep) and { key = key, lists = keep } or nil
end
M.fa_put_back = function()
    local k = M.fa_keep
    M.fa_keep = nil
    if not k then return end
    local key = M.level_id() or M.area_said
    if key == nil or key ~= k.key then return end
    local n = 0
    for cls, c in pairs(k.lists) do M.fa_cache[cls] = c; n = n + 1 end
    log(string.format("FINDALL %d fixed lists kept through the scene (level %s)", n, tostring(key)))
end
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
    if M.chan_probe and now - (M.chprobe_t or 0) > 2.0 then   -- which trace sees this wall?
        M.chprobe_t = now
        pcall(M.chan_probe, "bump")
    end
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
        -- (beacon_on is declared further down: read through M, else it is the global, nil)
        if M.beacon_is_on and M.beacon_is_on() then beacon_rescan_at = now + 0.7 end
        M.jump_t = now   -- the navigator's list is stale now (NV.list_stale)
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
    if ax >= 0.4 * ay then parts[#parts + 1] = (dx > 0) and N_("up") or N_("down") end
    if ay >= 0.4 * ax then parts[#parts + 1] = (dy > 0) and N_("right") or N_("left") end
    if #parts == 0 then return tr("here") end
    return tr(table.concat(parts, " "))   -- "up left": one text, the order per language
end
M.nav_dir = nav_dir   -- (for M.marker_watch)
-- (for scripts/i18n.py: texts said through tr(variable) -- nav_dir's pairs and the
-- navigator's category names, NAV_CLASSES[].name / t.cat)
M.I18N_NAV = { N_("up left"), N_("up right"), N_("down left"), N_("down right"), N_("chest"), N_("exit"),
    N_("building"), N_("shop"), N_("marker") }
-- The word for a category. The internal names stay (also cue and log keys); "npc" is
-- said "person" (English 2026-11-16: "npc, 6 targets" was jargon).
M.CAT_WORDS = { npc = N_("person") }
M.cat_word = function(name) return tr(M.CAT_WORDS[name] or name) end
local nav_last_px, nav_last_py = nil, nil
local LEVEL_THRESH = 250  -- |dz| beyond this = another floor (one floor measured ~502 units; 250 clears same-floor jitter)
local function nav_probe()
    if world_susp then speak(M.battle_now and tr("In battle") or tr("Scene running")); return end
    local p, phow = get_player_obj()
    if not p then log("NAV: no player object"); speak(tr("No player position")); return end
    local px, py, pz, pposhow = read_actor_pos(p)
    if not px then log("NAV: player pos unreadable (" .. phow .. ")"); speak(tr("Player position unreadable")); return end
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
    if not bestd then speak(tr("No objects found")); return end
    log(string.format("NAV nearest=%s d=%.0f dx=%.0f dy=%.0f dz=%.0f", bestcat, bestd, bdx, bdy, bdz or 0))
    local lvl = ""
    if bdz and bdz > LEVEL_THRESH then lvl = ", " .. tr("above")
    elseif bdz and bdz < -LEVEL_THRESH then lvl = ", " .. tr("below") end
    speak(trf("%s%s, %s, distance %d", tr(bestcat), lvl, nav_dir(bdx, bdy), math.floor(bestd + 0.5)))
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
    local SHOT_PATH = (M.bin_dir() or ".") .. "\\op1access_shot.bmp"   -- (Win64, next to the game)
    -- ON THE GAME THREAD: PrintWindow sends WM_PRINT to the window's thread (the game
    -- thread). Called from the keybind thread it waited for the game thread while
    -- holding the Lua lock the game thread needed -> the game froze (2026-11-11).
    local ok = pcall(RegisterKeyBind, Key.F2, { ModifierKey.CONTROL }, function()
        M.in_gt(function()
            local done = false
            pcall(function() if shim and shim.Screenshot then done = shim.Screenshot(SHOT_PATH) end end)
            speak(done and tr("Screenshot saved") or tr("Screenshot failed"))
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
    { say = N_("engine right"),                       sa = 0 },
    { say = N_("engine left"),                        sa = 1 },
    { say = N_("engine front"),                       sa = 2 },
    { say = N_("engine behind"),                      sa = 3 },
    { say = N_("world right, the right arrow side"),  dx = 0,    dy = 300 },
    { say = N_("world left, the left arrow side"),    dx = 0,    dy = -300 },
    { say = N_("world front, the up arrow side"),     dx = 300,  dy = 0 },
    { say = N_("world behind, the down arrow side"),  dx = -300, dy = 0 },
    { say = N_("bump sound"),                         bump = true },   -- direct one-shot playback check
}
local function audio_test_cycle()
    if not (shim and shim.AudioInit) then speak(tr("Audio module not loaded")); return end
    if not audio_inited then
        local ok = false
        pcall(function() ok = shim.AudioInit() end)
        audio_inited = ok and true or false
        local st = "?"; pcall(function() st = shim.AudioStatus() end)
        log("AudioInit: " .. tostring(ok) .. " status=" .. tostring(st))
        if not audio_inited then speak(trf("Audio init failed: %s", tostring(st))); return end
        if M.load_cues then M.load_cues() end   -- (declared further down)
        if M.audio_set_ranges then M.audio_set_ranges() end
    end
    audio_test_phase = (audio_test_phase % (#AUDIO_TESTS + 1)) + 1
    pcall(function() shim.AudioTest(4) end)                          -- engine test off
    pcall(function() shim.AudioSetSource(0, false, 0, 0, 0, 0) end)  -- world test off
    local t = AUDIO_TESTS[audio_test_phase]
    if not t then speak(tr("test off")); return end
    if t.bump then
        pcall(function() shim.AudioPlayCue(BUMP_CUE) end)
    elseif t.sa then
        pcall(function() shim.AudioTest(t.sa) end)
    else
        local p = get_player_obj()
        local px, py, pz
        if p then px, py, pz = read_actor_pos(p) end
        if not px then speak(tr("No player position")); return end
        pcall(function() shim.AudioSetListener(px, py, pz) end)
        pcall(function() shim.AudioSetSource(0, true, px + t.dx, py + t.dy, pz, 2) end)
    end
    speak(tr(t.say))
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
M.beacon_is_on = function() return beacon_on end   -- (for code above this line)
local beacon_objs = {}
local beacon_slotof = {}   -- stable beacon_objs index -> shim slot (declick: one object, one slot)
-- Range model: ping EVERY object within a FIXED radius (no density filter), so an
-- object's presence + loudness map STEADILY to its distance. A radius that grew/
-- shrank with crowding could hide a nearby object just because the area was busy,
-- which breaks the distance estimation blind players rely on. HARDCAP is only a
-- slot-safety limit (the shim has 32 source slots).
-- (1500 since 2026-11-23, was 500: objects were heard only 4-5 steps away, which made
-- finding your way hard. The shim fades them out over the same range, M.audio_set_ranges.)
local BEACON_RANGE   = 1500     -- fixed audible radius (world units, each direction)
local BEACON_HARDCAP = 28       -- object beacons use slots 0..27; 28..31 reserved for wall radar
local CAT_CUE = { chest = 0, exit = 1, npc = 2, building = 3, shop = 4 }  -- category -> shim cue/freq

-- Custom cue assets: drop chest/exit/npc/building/shop/wall .flac|.mp3|.wav into the
-- mod's Assets/ folder and they replace the generated tones (played at the same
-- distance-driven ping rate). Missing files fall back to tones. Loaded once, lazily.
local ASSET_DIR = M.mod_dir_abs() .. "Assets\\"   -- (Mods\OP1Access\ or ue4ss\Mods\OP1Access\)
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
M.load_cues = load_cues   -- (for the audio test above)

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
-- A SAVE POINT's book is an NPC too: its talk is the save menu. Saving "learned" it as a
-- talkable person, so it joined the people list and the radar rang for it like one (user
-- 2026-11-17, the Maiya path). It is the marker list's save point instead. Every save
-- point in the logs (towns, paths, dungeons) has NPCUniqID 830 and the text label
-- CN_NP_SYS_000000_0000; its talk event is SC_SYS_SA0 (NV.keepers).
M.is_save_point = function(o, uniq)
    if uniq == 830 then return true end
    local yes = false
    pcall(function()
        local pd = o.PlacementData
        for _, L in ipairs({ "A", "B", "C", "D", "E" }) do
            local el = ""
            pcall(function() el = pd["EventLabel_" .. L]:ToString() end)
            if el:find("^SC_SYS_SA") then yes = true; return end
        end
    end)
    return yes
end
-- What a placed person is wired for, from its placement row (PlacementData): fc = a path
-- action's data (FCmd_Purchase_ID: Purchase/Steal, FCmd_Lure_ID: Guide/Allure,
-- FCmd_Battle_ID: Challenge/Provoke, FCmd_Search_ID: Scrutinize/Inquire), ev = an event
-- of its own (EventType_A..E / EventLabel_A..E: its talk, a shop, a side story, a save
-- point). -> { fc, ev }, or nil when the row can't be read; once per actor (the record).
-- In the placement table (2080 people) all 493 NNPC_* and 45 NPC_* have neither: the
-- crowds in taverns and streets, an event's henchmen. Facing one, the game still picks
-- it to talk to and the field-command list still holds the party's path actions, but
-- the balloon stays away, Enter does nothing and J offers only "Sich trennen" (user
-- 2026-11-18 evening: "a heap of unnamed people without talk or path actions").
M.NPC_FC_FIELDS = { "FCmd_Purchase_ID", "FCmd_Lure_ID", "FCmd_Battle_ID", "FCmd_Search_ID" }
M.npc_wiring = function(o)
    local addr
    pcall(function() addr = o:GetAddress() end)
    local rec = addr and M.npc_rec(o, addr)
    if type(rec) == "table" and rec.wire ~= nil then return rec.wire or nil end
    local w = nil
    pcall(function()
        local pd = o.PlacementData
        if not pd then return end
        local seen, fc, ev = false, false, false
        local function set(v)
            if v == nil then return false end
            seen = true
            local s = fname_to_str(v)
            return s ~= "" and s ~= "None"
        end
        for _, f in ipairs(M.NPC_FC_FIELDS) do
            local v
            pcall(function() v = pd[f] end)
            if set(v) then fc = true end
        end
        for _, L in ipairs({ "A", "B", "C", "D", "E" }) do
            local t, lb
            pcall(function() t = pd["EventType_" .. L] end)
            pcall(function() lb = pd["EventLabel_" .. L] end)
            if t ~= nil then seen = true end
            if (type(t) == "number" and t ~= 0) or set(lb) then ev = true end
        end
        if seen then w = { fc = fc, ev = ev } end
    end)
    if type(rec) == "table" then rec.wire = w or false end
    return w
end
-- KNOCKED OUT (user 2026-11-23, S'warkii): a person beaten after Provoke or Challenge lies
-- where they fell -- a villager lay in the only way to a hidden item, E talked to him
-- ("U-ugh...") from every side, every path action "not possible"; standing again later,
-- he goes to his door. The game keeps it in the save game: KSSaveGameBP_C.NPCEventList
-- (@0x1B8, NPCEventData 0x38 each: IsSwoon @0, SwoonBattleID @0x28), at the person's
-- NPC_UnqIndex (PlacementInfoData @0x18; KSFieldNPCCharacter_C.PlacementData @0xA00), the
-- index the game's own GetNPCEventData looks up by the person's label. They get up when
-- you enter a level of the SwoonRecLevel list (TArray<FName> @0x40, level IDs) of
-- NPCBattleData's SwoonBattleID-th row (LevelManagerBP_C.RecoveryNPC calls
-- NPCManagerBP_C.SwoonNPCRecover with the new level after every level load; a story
-- event can also wake one, EventManagerBP_C.StartRecoverSwoon): S'warkii's people at the
-- three forest paths around it (levels 159-161).
-- obj = the person's actor -> nil (unknown), false, or { idx, bid, row, levels } (levels
-- only with want_levels)
M.NPC_UNQ_INDEX, M.SG_NPC_EVENTS, M.NPC_EVENT_SIZE = 0xA18, 0x1B8, 0x38
-- The class object of the people (KSFieldNPCCharacter_C), its address, found once (nil
-- while not loaded: asked again after 30 s). An object is one of them when its class
-- pointer (+0x10) is that address -- a raw read through the shim: UE4SS's GetClass on
-- an object freed with the last map reads garbage, past any pcall (see M.nearest_npc).
M.npc_class_addr = function()
    if M.npc_cls_a then return M.npc_cls_a end
    local now = os.clock()
    if now - (M.npc_cls_t or -99) < 30 then return nil end
    M.npc_cls_t = now
    pcall(function()
        local c = StaticFindObject("/Game/Character/BP/Type/KSFieldNPCCharacter.KSFieldNPCCharacter_C")
        if c and c:IsValid() then M.npc_cls_a = c:GetAddress() end
    end)
    return M.npc_cls_a
end
M.npc_swoon = function(obj, want_levels)
    if not (obj and shim and shim.Peek) then return nil end
    local addr, sga
    pcall(function() addr = obj:GetAddress() end)
    local ca = M.npc_class_addr()
    if not (addr and addr ~= 0 and ca) then return nil end
    -- a person, alive: its class pointer and flags (not being destroyed), raw reads only
    local cls, fl = shim.Peek(addr + 0x10, "ptr"), shim.Peek(addr + 8, "i32")
    if cls ~= ca or not fl or (math.floor(fl) & 0x18000) ~= 0 then return nil end
    local sg = M.save_game()
    if sg then pcall(function() sga = sg:GetAddress() end) end
    if not (sga and sga ~= 0) then return nil end
    local idx = shim.Peek(addr + M.NPC_UNQ_INDEX, "i32")
    local arr, cnt = shim.Peek(sga + M.SG_NPC_EVENTS, "ptr"), shim.Peek(sga + M.SG_NPC_EVENTS + 8, "i32")
    if not M.swoon_logged then
        M.swoon_logged = true
        log(string.format("SWOON save game %s at %X: %s person entries; first person read: index %s",
            tostring(class_name_of(sg)), sga, tostring(cnt), tostring(idx)))
    end
    if not (idx and arr and arr ~= 0 and cnt and cnt > 0 and cnt < 100000 and idx >= 0 and idx < cnt) then
        return nil
    end
    local e = arr + idx * M.NPC_EVENT_SIZE
    local sw = shim.Peek(e, "u8")
    if sw == 0 then return false end
    if sw ~= 1 then return nil end   -- (not a bool: a bad read)
    local out = { idx = idx, bid = shim.Peek(e + 0x28, "i32"), levels = {} }
    if not want_levels then return out end
    local dt = M.dt_addr and M.dt_addr("/Game/Character/Database/NPCBattleData")
    local rc, rn, row
    if dt and out.bid and out.bid >= 0 then rc, rn, row = shim.DtRowAt(dt, out.bid) end
    if row then
        out.row = M.fname_str(rc, rn)
        local la, ln = shim.Peek(row + 0x40, "ptr"), shim.Peek(row + 0x48, "i32")
        if la and la ~= 0 and ln and ln > 0 and ln < 16 then
            for i = 0, ln - 1 do
                local c, n = shim.PeekFName(la + i * 8)
                local id = c and c > 0 and tonumber(M.fname_str(c, n))
                if id then out.levels[#out.levels + 1] = id end
            end
        end
    end
    return out
end
-- Where a knocked-out person gets up (M.npc_swoon's levels): the world map's place names,
-- "Nördlicher S'warkii-Weg or ...", each once; the area you are in as "this area again";
-- nil when none is known
M.swoon_places = function(levels)
    if not (levels and #levels > 0) then return nil end
    local g = M.wm_graph and M.wm_graph()
    local here = M.current_level and M.current_level()
    local here_nd = g and here and g.bylevel[here]
    local names, seen, again = {}, {}, false
    for _, id in ipairs(levels) do
        local nd = g and g.bylevel[id]
        if id == here or (nd and nd == here_nd) then
            again = true
        else
            local nm = nd and nd.name ~= nd.row and nd.name or nil
            if not nm and M.level_dest then
                local d = M.level_dest(id)
                nm = d and d.name
            end
            if nm and not seen[nm] then seen[nm] = true; names[#names + 1] = nm end
        end
    end
    if again then names[#names + 1] = tr("this area again") end
    if #names == 0 then return nil end
    if #names == 1 then return names[1] end
    return trf("%s or %s", table.concat(names, ", ", 1, #names - 1), names[#names])
end
-- "Dörfler lies knocked out in the way and gets up again once you enter X or Y"
M.swoon_text = function(who, sw)
    local okp, places = pcall(M.swoon_places, sw and sw.levels)
    if okp and places then return trf("%s lies knocked out in the way and gets up again once you enter %s", who, places) end
    return trf("%s lies knocked out in the way; the item is out of reach until they get up", who)
end
local function npc_interesting(o)
    local addr = nil
    pcall(function() addr = o:GetAddress() end)
    local rec = addr and M.npc_rec(o, addr)   -- (a reused address starts over)
    local learned = (rec == true) or (type(rec) == "table" and rec.learned) or false
    local lname = (type(rec) == "table" and (rec.sname or rec.name)) or nil

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
    -- That rule left out real people (user 2026-11-18: one stood in a Pflastersten doorway,
    -- the walker said "Jemand steht im Weg", yet the radar and the people list had nobody;
    -- the game picks such people to talk to). In the placement table (3528 rows) the ID is
    -- 0 for: the game's GENERIC people (493 NNPC_*, CN_NP_COM_000000_0000: townsfolk, an
    -- event's henchmen), the village chiefs (CN_NP_MOS_000000_0000 ...), barkeeps and
    -- dungeon merchants (CN_NP_SYS_..._0010/_0020), and every side-story person whose label
    -- has letters in it (CN_SS_FO3_0101B1_0003, CN_MS_BAL_0000A0_0000: not all digits).
    -- So every PLACED character (NPC_* / NNPC_*, all PlacementType 1) is a person; out
    -- stay the save points' books (below), editor dummies and actors without a label.
    local person = label:find("^N?NPC_") ~= nil
    -- ... except those with nothing to talk about and no path action (M.npc_wiring): out,
    -- also when "learned" (the game's Talk ran for one of them without a talk)
    local wire = person and M.npc_wiring(o) or nil
    local idle = (wire ~= nil) and not wire.fc and not wire.ev

    local keep = (learned or (not istest and (id > 0 or person))) and not idle
    -- (kept only by a talk, with no lines of its own: a save point? asked once per actor)
    local savept = false
    if keep and id == 0 then
        if type(rec) == "table" and rec.savept ~= nil then
            savept = rec.savept
        else
            savept = M.is_save_point(o, uniq)
            if type(rec) == "table" then rec.savept = savept end
        end
        if savept then keep = false end
    end
    local dbg = string.format("uniq=%s label=%s ptext=%s id=%d learned=%s%s%s",
        tostring(uniq), label == "" and "-" or label, ptext == "" and "-" or ptext, id, tostring(learned),
        savept and " (save point)" or "", idle and " (no talk, no path action)" or "")
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
    -- precise path: the Talk hook already pinned the EXACT actor, no proximity
    -- guessing. Its NAME comes from the talk's FIRST line only, right after the hook
    -- (0.07 s in the logs). For 30 s every line used to rename it: a guard's "Urgh ..."
    -- 18 s after a villager's Talk -- through the path-action menu, no Talk of its own --
    -- listed the villager as "Wachmann", and the walker went to him (user 2026-11-18).
    -- The later lines still count as this talk (no nearest-NPC guess for them).
    if npc_talking and (now - npc_talking.t) < 30 then
        local rec = npc_learned[npc_talking.addr]
        if type(rec) ~= "table" then rec = {}; npc_learned[npc_talking.addr] = rec end
        rec.learned = true; rec.keep = true
        if not npc_talking.named and now - npc_talking.t < 3.0 then
            npc_talking.named = true
            local nm = nil
            pcall(function() if shim and shim.LastSpeakerName then nm = shim.LastSpeakerName() end end)
            if nm and M.TRAVELER[nm] then nm = nil end   -- our own traveler spoke, not the NPC
            rec.name = nm or rec.name
            log("LEARNED (talk hook) name=" .. tostring(rec.name))
        end
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
        local cur = addr and M.npc_rec(best, addr)
        if cur and not (cur.learned and cur.name) then
            -- real dialogue OVERRIDES any cached probe verdict, and carries the
            -- speaker's resolved display name (from the talk hook; the static name,
            -- where there is one, still comes first: NV.resolve_name)
            cur.learned, cur.keep, cur.name, cur.dbg = true, true, nm, "learned"
            log(string.format("LEARNED talkable npc, d=%.0f name=%s", bd, tostring(nm)))
        end
    end
end
local function beacon_rescan()
    beacon_objs = {}
    beacon_slotof = {}
    for _, c in ipairs(NAV_CLASSES) do
        -- (the kept lists: after a scene or transition they were dropped, so this scans
        -- afresh then; after a door jump in the same level they are still good)
        local list = c.cls and M.find_all(c.cls, 600) or nil
        if list then
            for _, o in pairs(list) do
                local okv = false
                pcall(function() okv = o and o:IsValid() end)
                -- store the ACTOR (not a fixed position): NPCs wander, so the tick
                -- reads each one's live position. Cap defends against huge towns.
                if okv and #beacon_objs < 128 then
                    local keep = true
                    -- a lighting zone is no building (M.house_is_zone)
                    if c.name == "building" and M.actor_is_zone and M.actor_is_zone(o) then keep = false end
                    if c.name == "npc" then
                        local why, nm
                        keep, why, nm = npc_interesting(o)
                        log("NPC " .. (keep and "keep" or "omit") .. ": " .. why .. (nm and (" name=" .. nm) or ""))
                    end
                    if keep then
                        -- (h: the shim's check that this memory still holds the object,
                        -- for anything that touches it later besides its position; addr:
                        -- a chest's, for its opened flag -- read raw, M.chest_state)
                        local a
                        if c.name == "chest" then pcall(function() a = o:GetAddress() end) end
                        beacon_objs[#beacon_objs + 1] = { actor = o, cat = c.name, h = M.handle(o), addr = a }
                    end
                end
            end
        end
    end
    log(string.format("BEACON rescan: %d objects %.3f", #beacon_objs, os.clock()))
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
            -- (after a load always: M.load_resay, set when a confirmed load's fade came up)
            if far or #beacon_objs ~= o.n or M.load_resay then
                -- (the player's radar off -- the game's O, M.radar_poll: said along, as
                -- nothing pings)
                speak(M.radar_off and trf("%d objects here, radar off", #beacon_objs)
                    or trf("%d objects here", #beacon_objs))
            end
        end
        beacon_rescan_say = false
        M.load_resay = nil
    end
    local p = get_player_obj()
    local px, py, pz
    if p then px, py, pz = read_actor_pos(p) end
    if px then
        pcall(function() shim.AudioSetListener(px, py, pz) end)
        -- THE PLAYER'S RADAR OFF (the game's O, M.radar_poll): the objects stay known
        -- (navigator, walker, the count), only their pings go -- silenced once, then
        -- nothing to do
        if M.radar_off then
            if not M.beacons_hushed then
                M.beacons_hushed = true
                for i = 0, BEACON_HARDCAP - 1 do pcall(function() shim.AudioSetSource(i, false, 0, 0, 0, 0) end) end
                beacon_slotof = {}
            end
            return
        end
        M.beacons_hushed = nil
        -- which tracked objects are in range right now, keyed by their STABLE index.
        -- SAME LEVEL ONLY: objects a floor above/below are unreachable and their
        -- mostly-vertical direction reads as vague/drifting left-right -- on
        -- multi-level maps (prologue building!) they just pollute the panorama.
        -- Crossing stairs changes pz, so the audible set re-filters itself live.
        -- Ctrl+F8 still reports off-level objects explicitly ("below"/"above").
        local r2 = BEACON_RANGE * BEACON_RANGE
        local near = {}
        for idx, o in ipairs(beacon_objs) do
            -- NO o.actor:IsValid() here: on a cached actor that the game freed/streamed
            -- out (e.g. on focus-loss) that call faults at UObjectBase::IsA, which pcall
            -- CANNOT catch -> it crashes the game. read_actor_pos goes through the shim's
            -- SEH-guarded ActorLoc, so a dead actor just yields nil and we skip it.
            local ox, oy, oz = read_actor_pos(o.actor)
            -- AN OPENED CHEST IS SILENT (player report 2026-11-24: its sound went on after
            -- it was opened, so walking past one didn't tell whether it was worth a detour).
            -- Its IsOpenFlag, read raw each round (it flips as you open it); after the
            -- position, so only a live chest is read. The navigator still lists it.
            if ox and o.addr then
                local opened = M.chest_state({ addr = o.addr })
                if opened then ox = nil end
            end
            if ox then
                local dx, dy = ox - px, oy - py
                local d2 = dx * dx + dy * dy
                if d2 <= r2 and math.abs((oz or pz) - pz) <= LEVEL_THRESH then
                    near[#near + 1] = { idx = idx, d2 = d2, x = ox, y = oy, z = oz, cat = o.cat }
                end
            end
        end
        -- more in range than slots (the range grew to 1500): the nearest ones sound
        table.sort(near, function(a, b) return a.d2 < b.d2 end)
        local inrange = {}
        for k = 1, math.min(#near, BEACON_HARDCAP) do inrange[near[k].idx] = near[k] end
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

-- ===== Line traces (wall radar, router, walker) =====
local WALL_DIRS = {
    { name = "up",    dx = 1,  dy = 0 },   -- world +X (screen up)
    { name = "down",  dx = -1, dy = 0 },
    { name = "right", dx = 0,  dy = 1 },   -- world +Y (screen right)
    { name = "left",  dx = 0,  dy = -1 },
}
-- Every line trace goes through the shim (shim.Trace): KismetSystemLibrary
-- LineTraceSingle / LineTraceSingleByProfile called through ProcessEvent with one
-- reused parameter buffer -- 0.010 ms a trace, against 0.087 through UE4SS's own call,
-- which built Lua tables for both vectors and the whole FHitResult. A long route fires
-- ~6000. UE4SS's call stayed as a fallback until the native one had agreed with it on
-- every test (13 of 13 traces, dungeon and town); removed 2026-11-14 (user request).
-- ch = ETraceTypeQuery (default 0 = TraceTypeQuery1/Visibility, used by the
-- pathfinder for ground/clearance). The wall radar passes 1+ because OT's invisible
-- collision walls (non-enterable archways, map fences) IGNORE channel 0 but BLOCK
-- channels 1-5 -- channel 0 literally cannot see them (confirmed via CHPROBE).
-- ch = "pawn": a trace by the player capsule's collision profile ("Pawn") instead of a
-- channel. It blocks what the character collides with: the invisible walls channel 0
-- misses (the study's ledge the walker kept running into: ch0 miss, ch1 and Pawn hit at
-- 28, 2026-11-14) but not channel 1's camera-only decoration.
-- Set up on first use. The check: straight down from the player must hit the floor.
-- M.tr_native: true | "retry" (set up again after M.tr_retry_t) | false (no shim.Trace).
M.trace_setup = function(ksl, p)
    M.tr_native, M.tr_retry_t = "retry", os.clock() + 30
    if not (shim and shim.TraceSetup and shim.Trace) then
        M.tr_native = false
        log("TRACE: the shim has no Trace -- no walls, no routes")
        speak(tr("Navigation traces unavailable"))
        return
    end
    local a = {}
    pcall(function()
        a.k  = ksl:GetAddress()
        a.f1 = StaticFindObject("/Script/Engine.KismetSystemLibrary:LineTraceSingle"):GetAddress()
        a.f2 = StaticFindObject("/Script/Engine.KismetSystemLibrary:LineTraceSingleByProfile"):GetAddress()
        a.lf = StaticFindObject("/Script/Engine.Actor:K2_GetActorLocation"):GetAddress()
        a.p  = p:GetAddress()
        if not M.pawn_profile then
            local prof = p.CapsuleComponent:GetCollisionProfileName():ToString()
            M.pawn_profile = (prof and prof ~= "" and prof ~= "None") and prof or "Pawn"
        end
        if not M.pawn_fname then M.pawn_fname = FName(M.pawn_profile) end
        a.pf = M.pawn_fname:GetComparisonIndex()
    end)
    local px, py, pz = read_actor_pos(p)
    if not (a.k and a.f1 and a.f2 and a.lf and a.p and a.pf and px) then
        log("TRACE setup: lookup failed, retry in 30 s")
        return
    end
    local oks, res = pcall(shim.TraceSetup, a.k, a.f1, a.f2, a.p, a.lf)
    local okf, hitf, df = false, false, nil
    if oks and res then okf, hitf, df = shim.Trace(a.p, px, py, pz + 20, px, py, pz - 600, 0) end
    if not (okf and hitf and type(df) == "number" and df > 20 and df < 400) then
        log(string.format("TRACE setup failed (setup %s, floor %s/%s/%s), retry in 30 s",
            tostring(res), tostring(okf), tostring(hitf), tostring(df)))
        if not M.tr_warned then
            M.tr_warned = true
            speak(tr("Navigation traces failed, retrying"))
        end
        return
    end
    M.pawn_fidx = a.pf
    M.tr_native = true
    M.pfoot = df - 20   -- your capsule's center over the floor (82)
    log(string.format("TRACE ready (floor %.0f below)", df))
end
-- -> ok, hit, {Distance} (on a hit). ok = false: no trace (not set up, or the call
-- faulted) -- every caller then counts the way as blocked.
local function line_blocked(ksl, p, sx, sy, sz, ex, ey, ez, ch)
    if M.tr_native ~= true then
        if M.tr_native == nil or (M.tr_native == "retry" and os.clock() > M.tr_retry_t) then
            pcall(M.trace_setup, ksl, p)
        end
        if M.tr_native ~= true then return false, false, nil end
    end
    if not rawequal(p, M.tr_p) then   -- the player's address, once per object
        M.tr_p, M.tr_addr = p, nil
        pcall(function() M.tr_addr = p:GetAddress() end)
    end
    local addr = M.tr_addr
    if not addr then return false, false, nil end
    local okn, hit, dist
    if ch == "pawn" then
        okn, hit, dist = shim.Trace(addr, sx, sy, sz, ex, ey, ez, -1, M.pawn_fidx)
    else
        okn, hit, dist = shim.Trace(addr, sx, sy, sz, ex, ey, ez, ch or 0)
    end
    if not okn then return false, false, nil end
    if hit then return true, true, { Distance = dist } end
    return true, false, nil
end
NV_TRACE = "pawn"   -- the router's clearance trace (a global: the main chunk is at 200 locals)
-- Which trace sees what the player bumps into? ch0 (the router's), ch1 (the wall
-- radar's: also invisible walls, but decoration too -- the router on ch1 found no
-- routes, 2026-06-27) and a trace by the player capsule's OWN collision profile, which
-- should block exactly what the character collides with. Logged on every wall bump
-- (bump_fire, at most every 2 s) and on Ctrl+F6, to pick the router's trace.
M.chan_probe = function(tag)
    local p = get_player_obj(); if not p then return end
    local px, py, pz = read_actor_pos(p); if not px then return end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"); if not ksl then return end
    if not M.pawn_profile then
        local prof
        pcall(function() prof = p.CapsuleComponent:GetCollisionProfileName():ToString() end)
        M.pawn_profile = (prof and prof ~= "" and prof ~= "None") and prof or "Pawn"
    end
    local prof = M.pawn_profile
    local parts = {}
    for _, d in ipairs(WALL_DIRS) do
        local sx, sy, ex, ey = px + d.dx * 12, py + d.dy * 12, px + d.dx * 200, py + d.dy * 200
        local res = {}
        for _, ch in ipairs({ 0, 1, "pawn" }) do
            local ok, hit, oh = line_blocked(ksl, p, sx, sy, pz + 30, ex, ey, pz + 30, ch)
            res[#res + 1] = not ok and "err" or (hit and string.format("%.0f", oh.Distance) or "-")
        end
        parts[#parts + 1] = string.format("%s ch0=%s ch1=%s prof=%s", d.name, res[1], res[2], res[3])
    end
    log(string.format("CHPROBE %s at (%.0f,%.0f) profile=%s: %s", tag, px, py, prof, table.concat(parts, " | ")))
end
pcall(RegisterKeyBind, Key.F6, { ModifierKey.CONTROL }, function() M.in_gt(function() pcall(M.chan_probe, "key") end) end)
local function wall_probe()
    if world_susp then speak(M.battle_now and tr("In battle") or tr("Scene running")); return end
    local p = get_player_obj()
    if not p then speak(tr("No player")); return end
    local px, py, pz = read_actor_pos(p)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not (ksl and px) then speak(tr("No Kismet/pos")); return end
    local LEN = 230
    local blocked = {}
    for _, d in ipairs(WALL_DIRS) do
        local ok, hit, oh = line_blocked(ksl, p,
            px + d.dx * 30,  py + d.dy * 30,  pz + 30,
            px + d.dx * LEN, py + d.dy * LEN, pz + 30)
        local dist = "-"
        if type(oh) == "table" then pcall(function() if oh.Distance then dist = string.format("%.0f", oh.Distance) end end) end
        log(string.format("WALL %s: ok=%s hit=%s dist=%s", d.name, tostring(ok), tostring(hit), dist))
        if ok and hit then blocked[#blocked + 1] = tr(d.name) end
    end
    if #blocked == 0 then speak(tr("No walls near")) else speak(trf("Blocked: %s", table.concat(blocked, ", "))) end
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
-- Walls are heard within WALL_LEN, fading from loud (pressed against one) to silent at
-- the edge; objects reach farther (BEACON_RANGE), so walls don't ping all around you.
-- (450 since 2026-11-23, was 175: a wall was then always loud or very loud, never quiet.)
-- The bump check still counts a direction as blocked only within 175 (WALL_BUMP_LEN): a
-- far wall must not make arrow presses in a menu thud.
local WALL_LEN  = 450
local WALL_BUMP_LEN = 175
-- The shim's fade-outs and ping rates span the same ranges (shim.AudioSetRanges); set
-- after the audio module starts.
M.audio_set_ranges = function()
    if shim and shim.AudioSetRanges then pcall(shim.AudioSetRanges, BEACON_RANGE, WALL_LEN) end
end
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
                local hd = 120
                if type(oh) == "table" then pcall(function() if type(oh.Distance) == "number" and oh.Distance >= 1 then hd = oh.Distance end end) end
                if hd < 30 then hd = 30 elseif hd > WALL_LEN then hd = WALL_LEN end
                wall_blocked[d.name] = (hd <= WALL_BUMP_LEN) or nil   -- shared with bump detection
                -- (the player's radar off -- the game's O, M.radar_poll: the wall still
                -- counts for the bumps, its tone is off)
                pcall(function() shim.AudioSetSource(slot, not M.radar_off, px + d.dx * hd, py + d.dy * hd, pz, WALL_CUE) end)
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
-- 200-local cap). sdone marks "tried" so we don't re-probe blanks.
-- The STATIC name comes first: it is the game's own speaker name for that person. The
-- name learned in a talk only stands in where there is none (or only "???"); a learned
-- name went to the wrong person once (learn_talk_npc, 2026-11-18) and, kept first, it
-- stuck.
NV.resolve_name = function(o)
    if not o then return nil end
    local addr = nil
    pcall(function() addr = o:GetAddress() end)
    if not addr then return nil end
    local rec = M.npc_rec(o, addr)
    if not rec.sdone and shim and shim.NpcName then
        local nm = nil
        pcall(function() nm = shim.NpcName(addr) end)
        if nm == "" then nm = nil end
        rec.sname, rec.sdone = nm, true
    end
    if rec.sname and rec.sname ~= "???" then return rec.sname end
    if rec.name then return rec.name end
    -- "???" is a story person not met yet; the game's generic people (NNPC_*) have no
    -- name at all (theirs is "???" too)
    if rec.lbl and rec.lbl:find("^NNPC_") then return nil end
    return rec.sname
end

-- SHOPKEEPERS (2026-11-15, user report: the walk to the Wirtshaus in Atlasdam ended in
-- the doorway, the keeper still to be found by hand). A shop's ShopTriggerBP_C is a
-- 40-unit box just inside the entrance (the radar's shop icon), not the counter. The
-- keeper is the person whose talk event is a system one: PlacementData.EventLabel_A..E
-- "SC_SYS_SH0_*" (the shop event, cmd 7210) or "SC_SYS_BA0_*" (the tavern, cmd 7200;
-- Atlasdam's barkeep: SC_SYS_BA0_PLL000). Townsfolk carry "SC_NP_*" talk scripts, the
-- save point's book SC_SYS_SA0. A shop's target is then its keeper: the one nearest to
-- the trigger on its floor within 1500 (an event param naming the shop label wins).
-- Hidden ones count: a house's people are hidden until you go in. One FindAllOf per
-- area (keepers are cached; their positions are read fresh).
-- STALE KEEPERS (user 2026-11-23: the walk to the Wirtshaus in Pflastersten ended at the
-- captain of the guard). The list was kept per area banner, and after a fast travel no
-- banner came: the keepers of the town before were used -- Atlasdam's barkeep
-- (SC_SYS_BA0_PLL000), whose actor the game had freed and whose memory now held the
-- captain. Now the list goes with the people list it was made from (M.find_all searches
-- that again for a new level, after a scene or a transition, and as soon as one of its
-- objects is gone), and each keeper keeps a handle, checked before it is used.
NV.keepers = function()
    local people = M.find_all("KSFieldNPCCharacter_C", 600)
    if NV.kp_src == people and NV.kp_list then return NV.kp_list end
    local out = {}
    for _, o in ipairs(people) do
        local okv = false
        pcall(function() okv = o:IsValid() end)
        if okv then
            local kind, params = nil, {}
            pcall(function()
                local pd = o.PlacementData
                for _, L in ipairs({ "A", "B", "C", "D", "E" }) do
                    local el = ""
                    pcall(function() el = pd["EventLabel_" .. L]:ToString() end)
                    if el:find("^SC_SYS_SH") or el:find("^SC_SYS_BA") then
                        kind = kind or el
                        for i = 1, 3 do
                            pcall(function()
                                local pv = pd["EventParam_" .. L .. "_" .. i]:ToString()
                                if pv ~= "None" and pv ~= "" then params[pv] = true end
                            end)
                        end
                    end
                end
            end)
            if kind then out[#out + 1] = { actor = o, kind = kind, params = params, h = M.handle(o) } end
        end
    end
    log(string.format("SHOPKEEPERS %d in %s (level %s)", #out, tostring(M.area_said), tostring(M.level_id())))
    NV.kp_list, NV.kp_src = out, people
    return out
end
NV.shop_keeper = function(trig)
    local tx, ty, tz = read_actor_pos(trig)
    if not tx then return nil end
    local label = ""
    pcall(function() label = trig.ShopLabel:ToString() end)
    -- a tavern (ShopType 4) is run by a barkeep (SC_SYS_BA*), any other shop by someone
    -- with the shop event (SC_SYS_SH*). Atlasdam has a barkeep only: its armorer, store and
    -- merchant open at their trigger, so they keep it as their target.
    local okt, stype = pcall(M.shop_type, trig)
    local want = (okt and stype == 4) and "^SC_SYS_BA" or "^SC_SYS_SH"
    local best, bd = nil, 1500
    for _, k in ipairs(NV.keepers()) do
        local okv = M.handle_ok(k.h)   -- (the shim's check first: IsValid on freed memory faults)
        if okv then pcall(function() okv = k.actor:IsValid() end) end
        if okv and k.kind:find(want) then
            local x, y, z = read_actor_pos(k.actor)
            if x and math.abs((z or tz) - tz) < 300 then
                local d = math.sqrt((x - tx) ^ 2 + (y - ty) ^ 2)
                if k.params[label] then d = d - 10000 end   -- the keeper named for this shop wins
                if d < bd then best, bd = k, d end
            end
        end
    end
    if best then
        log(string.format("SHOPKEEPER for %s: %s (%s)", label, tostring(best.actor:GetFName():ToString()), best.kind))
        return best.actor
    end
    return nil
end

-- A target is an actor (read live: NPCs wander) or, for minimap markers without a
-- matching actor, a fixed position. Returns x, y, z (z may be nil). A shop's position
-- is its keeper's (NV.shop_keeper), when one was found.
NV.tpos = function(t)
    if t.keeper then
        local okk = false
        pcall(function() okk = t.keeper:IsValid() end)
        if okk then
            local x, y, z = read_actor_pos(t.keeper)
            if x then return x, y, z end
        end
    end
    if t.actor then
        local x, y, z = read_actor_pos(t.actor)
        if x then
            -- an exit: a place in its trigger box (NV.exit_point), not the actor
            if (t.cat == "exit" or t.walkcat == "exit") and NV.exit_point then
                local oke, e = pcall(NV.exit_point, t.actor, x, y)
                if oke and e then return e.x, e.y, e.z end
            end
            return x, y, z
        end
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
    NV.list_t = os.clock()
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
    local list = M.find_all(c.cls, 600)
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
                -- a lighting zone is no building (M.house_is_zone)
                if c.name == "building" and M.actor_is_zone and M.actor_is_zone(o) then keep = false end
                if c.name == "npc" then
                    local ok2, k, why, n = pcall(npc_interesting, o)
                    if ok2 then keep, nm = k, n else keep = false end
                    if dolog and ok2 then log("NPC " .. (keep and "keep " or "omit ") .. tostring(why)) end
                end
                if keep then
                    local e = { actor = o, cat = c.name, known = true, name = nm,
                        d = math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2) }
                    if c.name == "chest" then pcall(function() e.addr = o:GetAddress() end) end
                    if c.name == "shop" then
                        -- the shop's target is its keeper (NV.shop_keeper), not the
                        -- trigger at the entrance
                        local okk, k = pcall(NV.shop_keeper, o)
                        if okk and k then
                            e.keeper = k
                            local kx, ky = read_actor_pos(k)
                            if kx then e.d = math.sqrt((kx - px) ^ 2 + (ky - py) ^ 2) end
                        end
                    end
                    NV.list[#NV.list + 1] = e
                end
            end
        end
    end
    NV.list_done(px, py)
end
-- A chest's state (user request 2026-11-14: opened or not), from TreasureBoxBP_C's own
-- fields in the object dump: IsOpenFlag (bool, +0x3F8) -- set at load from the save
-- (the BP's AlreadyOpenCheck) and when you open it. Checked in the study: all 7 open
-- in Slot 1, none in the older autosave, and "opened" right after E on one. ObjectType
-- (byte, +0x410: 1 wood, 2 the plain chest, 3 thief, 4 a hidden item -- see
-- M.chest_purple) is logged ("CHESTS opened/type"). Raw SEH reads by address
-- (shim.Peek), fresh at every announce: a chest streamed out meanwhile can't fault.
-- Returns opened (bool), type (number) -- or nil.
M.chest_state = function(t)
    if not (t and t.addr and shim and shim.Peek) then return nil end
    local f = shim.Peek(t.addr + 0x3F8, "u8")
    if f == nil then return nil end
    return f ~= 0, shim.Peek(t.addr + 0x410, "u8")
end
-- A purple (thief) chest, which only opens with a certain traveler in the party
-- (2026-11-16): its closed or open mesh (CloseTresture_A_02 +0x3F0, OpenTresture_A_02
-- +0x3E8) wears the BP's thief material (ObjMI_TreasureClose_Theif +0x420 /
-- ObjMI_Treasure_Theif +0x418); MeshComponent.OverrideMaterials is at +0x690. Seen on
-- the flats: ObjectType 1 wears the wood material, 2 (and 4, a hidden item) a third
-- one; ObjectType 3 (Felsfall, the path to the Whisperwood) is the thief chest by
-- elimination, so the material decides, not the number. Raw reads, nil if unreadable.
M.chest_purple = function(t)
    if not (t and t.addr and shim and shim.Peek) then return nil end
    local a = t.addr
    local th_c, th_o = shim.Peek(a + 0x420, "ptr"), shim.Peek(a + 0x418, "ptr")
    if not th_c and not th_o then return nil end
    for _, off in ipairs({ 0x3F0, 0x3E8 }) do
        local comp = shim.Peek(a + off, "ptr")
        if comp and comp ~= 0 then
            local arr, n = shim.Peek(comp + 0x690, "ptr"), shim.Peek(comp + 0x698, "i32")
            if arr and arr ~= 0 and type(n) == "number" and n > 0 and n <= 8 then
                for i = 0, n - 1 do
                    local m = shim.Peek(arr + 8 * i, "ptr")
                    if m and m ~= 0 and (m == th_c or m == th_o) then return true end
                end
            end
        end
    end
    return false
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
M.house_cache, M.plane_cache, M.house_cache_src = {}, {}, nil
-- The room box of a door: its Actor_Room actor positions (min/max and mean), or false
-- (cached per door).
M.house_box = function(door, daddr, dx, dy)
    local box = M.house_cache[daddr]
    if box ~= nil then return box end
    box = false
    local n = 0
    local b = { minx = 1e9, maxx = -1e9, miny = 1e9, maxy = -1e9, minz = 1e9, maxz = -1e9, sx = 0, sy = 0 }
    pcall(function()
        door.Actor_Room:ForEach(function(_, v)
            local a = v:get()
            if a then
                local ax, ay, az = read_actor_pos(a)
                -- only room parts near the door: some rooms also list actors 16000 away
                -- (academy "IvonRoom"), which made a box that swallowed the whole hall
                if ax and math.sqrt((ax - dx) ^ 2 + (ay - dy) ^ 2) < 2000 then
                    n = n + 1
                    b.sx, b.sy = b.sx + ax, b.sy + ay
                    b.minx, b.maxx = math.min(b.minx, ax), math.max(b.maxx, ax)
                    b.miny, b.maxy = math.min(b.miny, ay), math.max(b.maxy, ay)
                    b.minz, b.maxz = math.min(b.minz, az), math.max(b.maxz, az)
                end
            end
        end)
    end)
    -- a box that is flat in X or Y is a wall/facade plane (the academy rooms' parts all
    -- sit on one line), not the room: don't use it
    if n > 0 and b.maxx - b.minx >= 200 and b.maxy - b.miny >= 200 then
        b.n, b.mx, b.my = n, b.sx / n, b.sy / n
        box = b
    end
    M.house_cache[daddr] = box
    return box
end
-- The doorway plane of a door (its BorderBox): center and the unit normal pointing INTO
-- the house. The box's thin axis is the normal, turned with the component. The side:
-- where the room's own parts are (their mean), when that is clearly off the plane; else
-- the box sitting a few units inside the door actor (library). The box alone was wrong
-- at a house in lower Felsfall: it sits 10 units OUTSIDE that door, so the street in
-- front counted as the room and the walker led out of a house you weren't in
-- (2026-11-15). pl.sure: the side is known. nil if unreadable.
M.house_plane = function(door, daddr, dx, dy)
    local pl = M.plane_cache[daddr]
    if pl ~= nil then return pl or nil end
    pl = false
    local box = M.house_box(door, daddr, dx, dy)
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
        local side, sure = "box", off >= 3
        if box and box.mx then
            local m = (box.mx - c.X) * nx + (box.my - c.Y) * ny
            if math.abs(m) >= 150 then
                if m < 0 then nx, ny = -nx, -ny end
                side, sure = "room", true
            end
        end
        pl = { cx = c.X, cy = c.Y, cz = c.Z, nx = nx, ny = ny, off = off, side = side, sure = sure }
    end)
    M.plane_cache[daddr] = pl
    return pl or nil
end
-- HouseEnterTriggerBP_C.IsHouseEnter (bool, +0x4B2 in the object dump): the game's own
-- "the player is in this house" -- set as you walk in (SetupHouseIn), cleared as you
-- leave. Raw read by address; nil if unreadable.
M.house_entered = function(daddr)
    if not (shim and shim.Peek and daddr and daddr ~= 0) then return nil end
    local v = shim.Peek(daddr + 0x4B2, "u8")
    if v == nil then return nil end
    return v ~= 0
end
-- The door that shuts behind you: DoorObj (+0x450) / DoorMeshComp (+0x458), raw reads.
-- Open doorways (the academy's inner rooms) have none.
M.house_has_door = function(daddr)
    if not (shim and shim.Peek and daddr and daddr ~= 0) then return true end
    local d, m = shim.Peek(daddr + 0x450, "ptr"), shim.Peek(daddr + 0x458, "ptr")
    if d == nil and m == nil then return true end   -- unreadable: as before
    return (d ~= nil and d ~= 0) or (m ~= nil and m ~= 0)
end
-- A trigger that only switches the light (2026-11-16, the academy's SchoolLighting_Out,
-- _IN and _In_Library): ForceHouseOut (+0x4B4) set and no door. Not a building: no
-- beacon, not in the list, never "the house you are in". By the study's entrance
-- SchoolLighting_Out's IsHouseEnter stayed set, so every walk first headed for it,
-- 2184 away a floor up, and found no way ("Not reachable").
M.house_is_zone = function(daddr)
    if not (shim and shim.Peek and daddr and daddr ~= 0) then return false end
    return shim.Peek(daddr + 0x4B4, "u8") == 1 and not M.house_has_door(daddr)
end
-- the same for an actor (nil-safe; other classes are never zones)
M.actor_is_zone = function(o)
    local a = 0
    pcall(function() a = o:GetAddress() end)
    return a ~= 0 and M.house_is_zone(a)
end
-- INSIDE A HOUSE, BY THE GAME'S OWN WORD (user 2026-11-19, Klarach): every placement
-- row has HouseInFlag (PlacementInfoData @0x29). Alfyn, to recruit, stands OUTSIDE by
-- Zeph's house (PC_TRivS_000A at (-30,-560), HouseInFlag off): 200 past the room box of
-- that house, but inside its 250 padding and on the inner side of its doorway plane, so
-- the walker took him for inside, led to Zeph's door, and Zeph stands in front of it:
-- "Zeph steht im Weg", no walk. A chest in Zeph's house (TrsrBx_River_TS_03, HouseInFlag
-- on) lies in a side room behind the doorway plane: never "in a building", the search
-- failed. An NPC carries its row (PlacementData); a chest only its position, so the
-- table's object rows (PlacementType 2) are indexed once and matched by position -- the
-- same spot to the unit, as rows of all maps share the table. -> true, false or nil.
M.PLACED_TABLE = "/Game/Character/Database/PlacementInfoData"
M.placed_house_at = function(x, y, z)
    if M.placed_objs == nil then
        -- (not loaded yet: asked again at most every 30 s -- StaticFindObject costs ~7 ms)
        local now = os.clock()
        if now - (M.placed_try_t or -99) < 30 then return nil end
        M.placed_try_t = now
        local dt = shim and shim.DtCount and shim.Peek and M.dt_addr(M.PLACED_TABLE)
        if not dt then return nil end
        M.placed_objs = false
        local n = shim.DtCount(dt) or 0
        local list = {}
        for i = 0, n - 1 do
            local _, _, row = shim.DtRowAt(dt, i)
            if row and shim.Peek(row + 0x08, "u8") == 2 then
                local rx, ry, rz = shim.Peek(row + 0x44, "f32"), shim.Peek(row + 0x48, "f32"), shim.Peek(row + 0x4C, "f32")
                local h = shim.Peek(row + 0x29, "u8")
                if rx and ry and h then list[#list + 1] = { x = rx, y = ry, z = rz or 0, h = (h ~= 0) } end
            end
        end
        log(string.format("PLACED object rows: %d of %d", #list, n))
        if #list > 0 then M.placed_objs = list end
    end
    if not M.placed_objs then return nil end
    local hit, n = nil, 0
    for _, r in ipairs(M.placed_objs) do
        if math.abs(r.x - x) < 2 and math.abs(r.y - y) < 2 and math.abs(r.z - (z or r.z)) < 200 then
            n = n + 1
            hit = r
        end
    end
    if n ~= 1 then return nil end   -- none, or two rows of different maps on one spot
    return hit.h
end
NV.target_in_house = function(t)
    if type(t) ~= "table" or not t.actor then return nil end
    if t.tin_done then return t.tin end
    t.tin_done = true
    local o, v = t.actor, nil
    local cls = class_name_of(o)
    if cls == "KSFieldNPCCharacter_C" then
        pcall(function()
            local h = o.PlacementData.HouseInFlag
            if type(h) == "boolean" then v = h end
        end)
    elseif cls == "TreasureBoxBP_C" then
        local x, y, z = read_actor_pos(o)
        if x then
            local okp, h = pcall(M.placed_house_at, x, y, z)
            if okp then v = h end
        end
    end
    t.tin = v
    return v
end
-- WHICH house, when several hold the target: room boxes overlap -- in Flammhuld the
-- tavern's reaches 1600 past its door, over House_B next to it, and the first door in
-- the list that held the target won. The Söldner in House_B (its door 116 from the
-- player) then got the tavern's door, 1194 away, and from there a route round House_B's
-- walls; no try reached him (user, 2026-11-16). So every door is looked at first, and
-- the one nearest the target wins (a door on another floor counts farther) -- unless the
-- player's own house holds the target too and its door is about as near.
-- tin: what the game itself says (NV.target_in_house, the placement's HouseInFlag):
-- false = the target stands outside every house, true = inside one (then the padded
-- room box alone decides which: an L-shaped house reaches past its doorway plane), nil =
-- unknown (the box and the plane as before).
M.house_door_for = function(tx, ty, tz, px, py, pz, dolog, allow_plane, tin)
    local list = M.find_all("HouseEnterTriggerBP_C", 600)
    if not list then return nil end
    -- (the room boxes and doorway planes, cached per door address, go with the door list
    -- they were read from: kept per area banner they outlived a fast travel, 2026-11-23 --
    -- doors of the next town at the same addresses got the old ones' rooms)
    if M.house_cache_src ~= list then
        M.house_cache, M.plane_cache, M.house_cache_src = {}, {}, list
    end
    local cands = {}                    -- the houses that may hold the target
    local mine, mined = nil, 1e9        -- the house the PLAYER is in (nearest such door)
    for _, door in pairs(list) do
        local okv = false
        pcall(function() okv = door:IsValid() end)
        local daddr = 0
        if okv then pcall(function() daddr = door:GetAddress() end) end
        if daddr ~= 0 and M.house_is_zone(daddr) then daddr = 0 end   -- a light switch, no house
        if daddr ~= 0 then
            local dx, dy, dz = read_actor_pos(door)
            local box = dx and M.house_box(door, daddr, dx, dy) or nil
            local function inroom(x, y, z)
                return box and x >= box.minx - 250 and x <= box.maxx + 250 and y >= box.miny - 250
                    and y <= box.maxy + 250 and (z or box.minz) >= box.minz - 300 and (z or box.minz) <= box.maxz + 300
            end
            local pl = dx and M.house_plane(door, daddr, dx, dy)
            -- distance in front of (> 0: inside) the doorway plane
            local function along(x, y) return (x - pl.cx) * pl.nx + (y - pl.cy) * pl.ny end
            local function inner(x, y)     -- not clearly outside the door
                return not (pl and pl.sure) or along(x, y) > -40
            end
            local ipb = inroom(px, py, pz)        -- in the padded box: inside or at the door
            local it, how = inroom(tx, ty, tz) and inner(tx, ty), "room"
            -- (the flag speaks for TOWN houses, those with a room box: a dungeon's rooms
            -- behind doors -- Ravus manor's "Ivons" doors, room=none -- hold chests flagged
            -- off, and after a failed route their door is still the way: 2026-11-20)
            if tin == false and box then it = false elseif tin == true then it = inroom(tx, ty, tz) end
            -- really inside: the game's own flag; the box and the plane only if unreadable
            local entered = M.house_entered(daddr)
            local ip
            if entered ~= nil then ip = entered else ip = ipb and inner(px, py) end
            -- fallback: the doorway plane alone, only after a failed route
            if not it and allow_plane and pl and (tin ~= false or not box) then
                local side = math.abs((tx - pl.cx) * pl.ny - (ty - pl.cy) * pl.nx)
                if along(tx, ty) > 60 and along(tx, ty) < 2500 and side < 1500
                    and math.abs((tz or pl.cz) - pl.cz) < 800 and along(px, py) < 0 then
                    it, how = true, "plane"
                end
            end
            local nm = "?"
            if dolog then pcall(function() nm = door:GetFName():ToString() end) end
            if dolog and dx and math.sqrt((dx - tx) ^ 2 + (dy - ty) ^ 2) < 3000 then
                log(string.format("HOUSE %s door=(%.0f,%.0f,%.0f) room=%s plane=%s target_in=%s(%s) player_in=%s/%s entered=%s game=%s",
                    nm, dx, dy, dz or 0,
                    box and string.format("%d actors x%.0f..%.0f y%.0f..%.0f z%.0f..%.0f mean(%.0f,%.0f)", box.n,
                        box.minx, box.maxx, box.miny, box.maxy, box.minz, box.maxz, box.mx, box.my) or "none",
                    pl and string.format("n(%.2f,%.2f) off=%.0f side=%s t%.0f p%.0f", pl.nx, pl.ny, pl.off,
                        tostring(pl.side), along(tx, ty), along(px, py)) or "none",
                    tostring(it), how, tostring(ipb), tostring(ip), tostring(entered), tostring(tin)))
            end
            -- a house's door is near its room: ignore doors far from the target (a door
            -- 17000 away whose room actors spread over half the map matched Russell)
            local dt = dx and math.sqrt((dx - tx) ^ 2 + (dy - ty) ^ 2) or 1e9
            local dp = dx and math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2) or 1e9
            if it and dt < 2500 then
                -- rank: the door nearest the target; one on another floor counts farther
                local zpen = (tz and dz) and math.max(0, math.abs(tz - dz) - 250) or 0
                cands[#cands + 1] = { door = door, addr = daddr, how = how, ipb = ipb, ip = ip,
                                      score = dt + zpen, name = nm }
            end
            if ip and dp < 2500 and dp < mined then mine, mined = { door = door, addr = daddr }, dp end
        end
    end
    table.sort(cands, function(a, b) return a.score < b.score end)
    local t = cands[1]
    if t and mine and t.door ~= mine.door then
        for _, c in ipairs(cands) do
            if c.door == mine.door and c.score <= t.score + 300 then t = c; break end
        end
    end
    if dolog and #cands > 1 then
        local parts = {}
        for _, c in ipairs(cands) do parts[#parts + 1] = string.format("%s %.0f", c.name, c.score) end
        log(string.format("HOUSE pick %s of %s", t.name, table.concat(parts, ", ")))
    end
    -- the player is in the target's house
    if t and t.ip then return nil, "same" end
    -- third result: the door of the house the player is in (and the target is not) --
    -- only behind a door that shuts (an open doorway needs no detour: the route goes
    -- through it). House doors close behind you, so leaving needs E at that door first
    -- (library)
    local leave = mine and (not t or mine.door ~= t.door) and M.house_has_door(mine.addr) and mine.door or nil
    if not t then return nil, nil, leave end
    -- just outside the target's house ("atdoor", with the door: it may still be shut --
    -- the walk goes to it first)
    if t.ipb and not leave then return t.door, "atdoor" end
    return t.door, t.how, leave
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
    if r.area ~= M.map_id() then return false end
    return math.sqrt((px - r.x) ^ 2 + (py - r.y) ^ 2) < 600
end

local function nav_announce(prefix)
    local t = nav_target()
    if not t then speak(tr("No target")); return end
    pcall(NV.bg_front, t)   -- the background check looks at this one next
    local p = get_player_obj(); if not p then speak(tr("No player")); return end
    local px, py, pz = read_actor_pos(p); if not px then speak(tr("No position")); return end
    local ox, oy, oz = NV.tpos(t)
    if not ox then speak(tr("Target lost")); return end
    local dx, dy = ox - px, oy - py
    local d = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    local lvl = ""
    -- (a floor up or down, or a terrace: NV.level_word)
    local okw, w = pcall(NV.level_word, p, px, py, pz, ox, oy, oz)
    if okw and w then lvl = ", " .. tr(w) end
    -- reachability note: inside a building you're not in, or the router failed here,
    -- or the background check found the way only through a shut door
    local key = NV.tkey(t)
    local noted = false
    if t.cat ~= "building" then
        local okd, door, how = pcall(M.house_door_for, ox, oy, oz or pz, px, py, pz, nil, nil, NV.target_in_house(t))
        if okd and (door or how == "atdoor") then lvl = lvl .. ", " .. tr("inside a building"); noted = true
        elseif NV.is_noroute(key, px, py) then
            lvl = lvl .. ", " .. (NV.noroute[key].door and tr("inside a building") or tr("not reachable")); noted = true
        end
    elseif NV.is_noroute(key, px, py) then
        lvl = lvl .. ", " .. tr("not reachable"); noted = true
    end
    local rr = key and NV.reach[key]
    if not noted and rr and rr.ok and rr.viadoor and NV.bg_valid(key, px, py) then
        lvl = lvl .. ", " .. tr("behind a door")
    end
    -- Name the focused NPC from STATIC data (NV.resolve_name -> placement label via
    -- GetGameTextString), so names show up WITHOUT having to talk first; the name
    -- learned in a talk only where there is none. Per-focus only, cached.
    if t.cat == "npc" and not t.name and t.actor then
        if NV.resolve_name then t.name = NV.resolve_name(t.actor) end
        if t.name and t.name:match("^[%?%s]+$") then t.name = tr("Unknown") end   -- (not "? ? ?")
        -- no name: the save point's book is an NPC too (it was "npc 1 of 7: up left,
        -- 156" by the save point, 2026-11-14) -- its minimap marker names it
        if not t.name then
            local okk, kind = pcall(M.marker_kind_of, t.actor)
            if okk and kind then t.name = tr(kind) end
        end
    end
    -- an exit says where it leads (M.exit_dest: the game's level tables), per focus
    if t.cat == "exit" and t.name == nil and t.actor then
        local okd, dest, lv = pcall(M.exit_dest, t.actor)
        t.name = (okd and dest) and (trf("to %s", dest) .. (lv and (", " .. lv) or "")) or false
    end
    -- a shop says what it is ("Gasthaus", "Händler": M.shop_name), per focus
    if t.cat == "shop" and t.name == nil and t.actor then
        local oks, nm = pcall(M.shop_name, t.actor)
        t.name = (oks and nm) or false
    end
    local who = t.name and (t.name .. ", ") or ""
    -- the exit that leads on along the world map route (M.route_goal)
    if t.actor and (t.cat == "exit" or t.walkcat == "exit") then
        local okr, note = pcall(M.route_exit_note, t.actor)
        if okr and note then who = who .. note .. ", " end
    end
    -- a person knocked out after Provoke or Challenge (M.npc_swoon) lies where they fell
    if t.cat == "npc" and t.actor then
        local okw, sw = pcall(M.npc_swoon, t.actor)
        if okw and sw then who = who .. tr("knocked out") .. ", " end
    end
    -- a chest says whether it was opened already (emptied: OT chests hold one thing)
    if t.cat == "chest" then
        local okc, opened = pcall(M.chest_state, t)
        if okc and opened then who = who .. tr("opened") .. ", " end
        local okp, purple = pcall(M.chest_purple, t)
        if okp and purple then who = who .. tr("purple") .. ", " end
    end
    speak(trf("%s%s %d of %d: %s%s, %d%s",
        prefix or "", M.cat_word(t.cat), NV.idx, #NV.list, who, nav_dir(dx, dy), d, lvl))
end

local function nav_cat_cycle(delta)
    NV.ctrlkey_t = os.clock()
    -- on the world map Home / End go through the regions
    if M.wm_region_cycle and M.wm_region_cycle(delta) then return end
    if world_susp then speak(M.battle_now and tr("In battle") or tr("Scene running")); return end
    local t0 = os.clock()
    for _ = 1, #NAV_CLASSES do
        NV.cat = ((NV.cat - 1 + delta) % #NAV_CLASSES) + 1
        nav_build_list()
        if #NV.list > 0 then
            NV.idx = 1
            -- chests: how many of them were opened already
            local extra = ""
            if NAV_CLASSES[NV.cat].name == "chest" then
                local nopen, kinds = 0, {}
                for _, t in ipairs(NV.list) do
                    local okc, opened, otype = pcall(M.chest_state, t)
                    if okc and opened then nopen = nopen + 1 end
                    local okp, purple = pcall(M.chest_purple, t)
                    kinds[#kinds + 1] = string.format("%s/%s%s", tostring(okc and opened), tostring(otype),
                        (okp and purple) and "/purple" or "")
                end
                log("CHESTS opened/type: " .. table.concat(kinds, " "))
                extra = trf(", %d opened", nopen)
            end
            nav_announce(trn("%s, %d target%s. ", "%s, %d targets%s. ", #NV.list, M.cat_word(NAV_CLASSES[NV.cat].name), #NV.list, extra))
            log(string.format("NAVCAT %s: %.0f ms", NAV_CLASSES[NV.cat].name, (os.clock() - t0) * 1000))
            return
        end
    end
    speak(tr("No targets in any category"))
end

-- AFTER A TELEPORT (a door, or an exit between two parts of one level: M.jump_t from the
-- bump watch) the list still holds the old part's targets -- their actors stay valid in
-- the same level. In the academy the markers still said "exit toward objective, 14743"
-- and "save point, 16459", and the walk found no route (user report 2026-11-14). The
-- minimap's icons follow a few seconds after the jump (2026-11-13: the headmaster's
-- marker was there 4 s after it), so a list built within 4 s of a jump is stale too.
-- Returns why the list is stale ("jump" or "markers"), or false.
NV.list_stale = function()
    local j = M.jump_t
    if j ~= nil and (NV.list_t or -1) < j + 4.0 then return "jump" end
    -- a radar marker came up or went away after the marker list was built (M.marker_watch)
    local c = NAV_CLASSES[NV.cat]
    if c and c.markers and M.marker_change_t ~= nil and (NV.list_t or -1) < M.marker_change_t then
        return "markers"
    end
    return false
end
-- Rebuild a stale list. Returns true if its targets changed (then the first one is
-- selected), false if they're the same (the selection stays) -- or if the markers
-- changed but the selected one is still there: it stays selected, and a walk to it goes
-- ahead (a marker gone elsewhere in the list changes nothing for it). Not after a jump:
-- the old part's icons follow a few seconds late, so one of them may still be listed.
NV.list_refresh = function()
    local why = NV.list_stale()
    local old = {}
    for _, t in ipairs(NV.list) do old[#old + 1] = tostring(NV.tkey(t)) end
    local sel = NV.list[NV.idx] and NV.tkey(NV.list[NV.idx])
    nav_build_list()
    local new = {}
    for _, t in ipairs(NV.list) do new[#new + 1] = tostring(NV.tkey(t)) end
    NV.idx = 0
    if sel ~= nil then
        for i, t in ipairs(NV.list) do if NV.tkey(t) == sel then NV.idx = i end end
    end
    table.sort(old); table.sort(new)
    if table.concat(old, "|") == table.concat(new, "|") then return false end
    local keep = why == "markers" and NV.idx > 0
    log(string.format("NAV list refreshed (%s): %d -> %d targets%s", tostring(why), #old, #NV.list,
        keep and ", the selected one stays" or ""))
    if keep then return false end
    NV.idx = (#NV.list > 0) and 1 or 0
    return true
end

local function nav_obj_cycle(delta)
    NV.ctrlkey_t = os.clock()
    if world_susp then speak(M.battle_now and tr("In battle") or tr("Scene running")); return end
    if #NV.list > 0 and NV.list_stale() and NV.list_refresh() then
        if #NV.list == 0 then speak(tr("No targets here, control left or right for categories")); return end
        nav_announce(trn("%s, %d target. ", "%s, %d targets. ", #NV.list, M.cat_word(NAV_CLASSES[NV.cat].name), #NV.list))
        return
    end
    if #NV.list == 0 then nav_build_list() end
    if #NV.list == 0 then speak(tr("No targets here, control left or right for categories")); return end
    if NV.idx < 1 then NV.idx = (delta > 0) and 1 or #NV.list   -- none selected: first or last
    else NV.idx = ((NV.idx - 1 + delta) % #NV.list) + 1 end
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
        if i <= 8 then parts[#parts + 1] = string.format("%s %d", tr(s.dir), math.floor(s.len / 10 + 0.5) * 10) end
    end
    if #segs > 8 then parts[#parts + 1] = tr("and more") end
    return table.concat(parts, ", "), math.floor(total + 0.5)
end

local function nav_walk_begin_path(pts, label)
    -- how close to come to each waypoint before turning to the next: 40 on a straight
    -- run, 22 at a real turn -- turning 40 early cut the inside corner into the wall
    for i = 2, #pts - 1 do
        local ax, ay = pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y
        local bx, by = pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y
        local la, lb = math.sqrt(ax * ax + ay * ay), math.sqrt(bx * bx + by * by)
        local turn = (la > 1 and lb > 1) and ((ax * bx + ay * by) / (la * lb) < 0.85)
        pts[i].reach = turn and 22 or 40
    end
    NV.path = pts
    NV.wp = 2
    nav_walking = true
    NV.prompt_at_start = M.popup_said   -- a door prompt already up (nav_walk_watch)
    NV.started = os.clock()
    NV.prog = { t = NV.started, x = pts[1].x, y = pts[1].y }
    NV.attempt_start = { x = pts[1].x, y = pts[1].y }
    NV.unwedged = false
    NV.unstuck = false
    NV.unwedge = nil
    NV.pwait, NV.pwait_n, NV.pwait_static = nil, 0, false
    local total = 0
    for i = 2, #pts do
        total = total + math.sqrt((pts[i].x - pts[i - 1].x) ^ 2 + (pts[i].y - pts[i - 1].y) ^ 2)
    end
    log(string.format("NAVWALK start mode=%s wps=%d total=%d", label, #pts, math.floor(total)))
    speak(trf("Walking, %s, total %d", label, math.floor(total + 0.5)))
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

-- ROOM TO STAND (2026-11-16, user: "er will immer durch das Wasser, er müsste über die
-- Brücke"). On the path to the Maiya caves the water is FILLED with invisible blocking
-- volumes (the level file: convex "Box brushes" from z -475 to 1525; channel 0 doesn't see
-- them, the capsule's profile does), and the bridge's deck is four invisible slabs (z 425
-- to 507) over a volume that ends at 355. Channel 0 found the river bed as floor and the
-- deck as nothing, so every route waded through the water -- each step "soft" (cost 8 or
-- 30), 15 learned walls in a row -- and none took the bridge.
-- A cell is a place only where the capsule fits: its knee (55 over the floor) and head
-- (150) points not inside anything the capsule's profile blocks -- a 1-unit trace from a
-- point inside a solid hits at once. People don't count (the people rules keep away from
-- them, and they move): a person within 70 of the point lets it pass. -> inside?, traces
NV.solid_at = function(R, ksl, p, x, y, z)
    local used = 0
    for _, h in ipairs({ 55, 150 }) do
        used = used + 1
        local ok, hit = line_blocked(ksl, p, x, y, z + h, x + 1, y, z + h, NV_TRACE)
        if ok and hit then
            local pl = R.people or R.blame
            if not pl then
                if R.pl_all == nil then
                    local okp, ppl = pcall(NV.people_scan, R.px, R.py, R.pz)
                    R.pl_all = okp and ppl or false
                end
                pl = R.pl_all or nil
            end
            for _, q in ipairs(pl or {}) do
                if math.abs(q.z - (z + (M.pfoot or 82))) < 250 and (q.x - x) ^ 2 + (q.y - y) ^ 2 < 70 * 70 then
                    return false, used
                end
            end
            return true, used
        end
    end
    return false, used
end
-- ...and where channel 0 finds no place, the capsule's own profile may: an invisible floor
-- (the bridge's deck). From za+160 to za-240 like nav_ground; a trace that begins inside
-- something solid finds nothing. -> floor or false, traces
NV.pawn_floor = function(R, ksl, p, x, y, za)
    local ok, hit, oh = line_blocked(ksl, p, x, y, za + 160, x, y, za - 240, NV_TRACE)
    if not (ok and hit and oh and type(oh.Distance) == "number") or oh.Distance < 1 then return false, 1 end
    local z = NV.stepin_floor(R, x, y, za + 160 - oh.Distance)   -- (not a person's head)
    local inside, u = NV.solid_at(R, ksl, p, x, y, z)
    if inside then return false, 1 + u end
    return z, 1 + u
end

-- AN EXIT'S GOAL (2026-11-18, user: the walker wouldn't go on into the next area). An
-- exit (LevelTrigger_C) fires on its Trigger box, not at the actor. From the Östliche to
-- the Südliche Sonnschatt-Sandwüste (F_Desert_1_2) the box is a strip 2400 long and 64
-- thin along the map's south edge, 195 south of the actor, whose root stands inside an
-- invisible wall (collision_68): the walker went for the root, into a pocket of walls 90
-- short of the strip, and re-routed every 2 s. Of the 416 exits in the area maps, 33
-- have the root outside the box and 14 inside a blocking volume (the level files).
-- The goal is now a place ON the box's middle line where the capsule stands (a floor by
-- its own profile and nothing solid there: NV.pawn_floor), the one nearest to the
-- exit's SpawnPoint -- where the game puts you when you come in through it, so in the
-- open way to it. Sampled every 60 once per exit (kept by address and root position);
-- not while a fade is up. Nothing free, or unreadable: the actor, as before.
NV.exit_cache = {}
NV.exit_point = function(actor, rx, ry)
    local addr
    pcall(function() addr = actor:GetAddress() end)
    if not addr then return nil end
    local c = NV.exit_cache[addr]
    if c and math.abs(c.rx - rx) < 1 and math.abs(c.ry - ry) < 1 then return c.x and c or nil end
    if M.fade_now then return nil end
    local p = get_player_obj()
    if not p then return nil end
    local cx, cy, cz, ex, ey, fx, fy
    pcall(function()
        local tb = actor.Trigger
        local cl, e, fv = tb:K2_GetComponentLocation(), tb:GetScaledBoxExtent(), tb:GetForwardVector()
        cx, cy, cz, ex, ey, fx, fy = cl.X, cl.Y, cl.Z, e.X, e.Y, fv.X, fv.Y
    end)
    if not (type(cx) == "number" and type(ex) == "number" and type(fx) == "number") then return nil end
    c = { rx = rx, ry = ry }   -- (kept only once the box was read: a failed read tries again)
    NV.exit_cache[addr] = c
    local sx, sy = rx, ry
    pcall(function() local s = actor.SpawnPoint:K2_GetComponentLocation(); sx, sy = s.X, s.Y end)
    local x, y, z, tried = NV.exit_pick(cx, cy, cz, ex, ey, fx, fy, sx, sy, function(qx, qy, qz)
        local ksl = NV.exit_ksl or StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
        NV.exit_ksl = ksl
        if not ksl then return false end
        return (NV.pawn_floor({ px = qx, py = qy, pz = qz, people = {} }, ksl, p, qx, qy, qz))
    end)
    c.x, c.y, c.z = x, y, z
    local nm = "?"
    pcall(function() nm = actor:GetFName():ToString() end)
    log(string.format("EXIT goal %s: box (%.0f,%.0f) %.0fx%.0f, spawn (%.0f,%.0f) -> %s after %d tries", nm, cx,
        cy, ex * 2, ey * 2, sx, sy, x and string.format("(%.0f,%.0f,%.0f)", x, y, z) or "none, the actor", tried))
    return x and c or nil
end
-- The pick itself (no game calls): the box (center, half extents along its own X and Y,
-- forward vector), the spawn point, and floor_at(x, y, z) -> floor z or false. Samples
-- every 60 along the long middle line (40 in from the ends), nearest to the spawn's spot
-- on the line first; the first with a floor wins. -> x, y, z (nil: none), samples tried
NV.exit_pick = function(cx, cy, cz, ex, ey, fx, fy, sx, sy, floor_at)
    local fl = math.sqrt(fx * fx + fy * fy)
    if fl < 0.01 then return nil, nil, nil, 0 end
    fx, fy = fx / fl, fy / fl
    local ux, uy, hl = fx, fy, ex
    if ey > ex then ux, uy, hl = -fy, fx, ey end   -- the box's Y axis (its right vector)
    local s0 = (sx - cx) * ux + (sy - cy) * uy
    local lim = math.max(0, hl - 40)
    local ss = {}
    for s = -lim, lim, 60 do ss[#ss + 1] = s end
    if #ss == 0 or ss[#ss] < lim then ss[#ss + 1] = lim end
    ss[#ss + 1] = math.max(-lim, math.min(lim, s0))   -- (the spawn's own spot on the line)
    table.sort(ss, function(a, b) return math.abs(a - s0) < math.abs(b - s0) end)
    local tried = 0
    for _, s in ipairs(ss) do
        if tried >= 80 then break end
        tried = tried + 1
        local x, y = cx + s * ux, cy + s * uy
        local z = floor_at(x, y, cz)
        if z then return x, y, z, tried end
    end
    return nil, nil, nil, tried
end

-- ground height at cell (bx,by) approached from height za (down-trace from
-- za+160 to za-240; false = void / too big a drop / no room to stand). Cached per cell
-- + band. fromstart: za is the start node's, the player's capsule, not a floor.
local function nav_ground(R, ksl, p, bx, by, za, fromstart)
    local gk = cellkey(bx, by) .. "@" .. math.floor((za - R.pz) / 200 + 0.5)
    local c = R.gcache[gk]
    if c ~= nil then return c, 0 end
    local wx, wy = R.px + bx * NV.STEP, R.py + by * NV.STEP
    R.traces = R.traces + 1
    local used = 1
    -- (R.groundch: a step-in route measures floors with the capsule's own profile, which
    -- sees steps channel 0 misses -- the Flammhuld inn's side stairs, NV.stepin_leg)
    local ok, hit, oh = line_blocked(ksl, p, wx, wy, za + 160, wx, wy, za - 240, R.groundch)
    local z = false
    if ok and hit then
        local dist
        pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
        z = dist and (za + 160 - dist) or za
        if R.groundch then
            if dist and dist < 1 then z = false else z = NV.stepin_floor(R, wx, wy, z) end
        end
    end
    -- no room to stand there (NV.solid_at): the river bed under the water's volume
    if z then
        local inside, u = NV.solid_at(R, ksl, p, wx, wy, z)
        used = used + u
        if inside then z = false; R.nroom = (R.nroom or 0) + 1 end
    end
    -- AN INVISIBLE FLOOR OVER CHANNEL 0'S (user report 2026-11-24, the Mountain Pass to the
    -- Brigands' Den, F_Mount_1_1: "not reachable" since 0.1.0, walked fine before). The rope
    -- bridge's deck is invisible slabs (channel 0 blind, z ~1400), and at its south end the
    -- cliff top runs on under it, 200 lower, with room to stand in between (the deck's
    -- underside 8 over a head). So the deck's first cells took that ground as their floor,
    -- a drop of 190, and the way over the bridge broke off there. The routes before ran
    -- along the top of the bridge's invisible side rail instead, which the ledge rule
    -- (NV.rise_ok, 1d2e021) rightly refuses. Where channel 0's floor lies more than a step
    -- below the floor you come from, the capsule's own profile is asked too: a floor of its
    -- own within a step of yours, and over channel 0's, with room, is what you walk onto.
    -- (One trace more, on drops only. Mock on the level's real collision: the scratchpad's
    -- run_mountpass.lua / test_deck.lua.)
    if z and not R.groundch then
        local af = fromstart and (za - (M.pfoot or 82)) or za   -- the floor you come from
        if z < af - NV.RISE_FREE then
            local zp, u = NV.pawn_floor(R, ksl, p, wx, wy, af)
            used = used + u
            if zp and zp > z + NV.RISE_FREE and math.abs(zp - af) <= NV.RISE_FREE then
                z = zp
                R.npawn = (R.npawn or 0) + 1
            end
        end
    end
    -- nothing (or no room) on channel 0: an invisible floor? (NV.pawn_floor)
    if not z and not R.groundch then
        local zp, u = NV.pawn_floor(R, ksl, p, wx, wy, za)
        used = used + u
        z = zp
        if z then R.npawn = (R.npawn or 0) + 1 end
    end
    R.traces = R.traces + (used - 1)
    R.gcache[gk] = z
    return z, used
end

local function nav_route_finish(goalnode)
    local R = NV.route
    NV.route = nil
    if not R then return end
    if not goalnode then
        log(string.format("ROUTE fail traces=%d pops=%d slides=%d people-blocked=%d no-room=%d capsule-floors=%d too-narrow=%d ledges=%d %.1fs",
            R.traces, R.pops, R.slides or 0, R.ppl_hit or 0, R.nroom or 0, R.npawn or 0, R.ntight or 0, R.nledge or 0,
            os.clock() - R.started))
        -- another side of a person or a chest: the next side (NV.spot_failed) -- not the
        -- search without people (the person you want to talk to stands beside the spot,
        -- it would name them "in the way"), never "not reachable" for the target itself
        if R.mode == "walk" and NV.goal and NV.goal.cat == "spot" and NV.spot_failed then
            NV.spot_failed(NV.goal)
            return
        end
        -- people stood in the way of some steps: was it them? The same search without
        -- people; if that finds a way, the person on it is named (below, R.blame)
        if R.people and (R.ppl_hit or 0) > 0 and not R.nopeople and not R.capped then
            local s0 = R.shifted or { x = R.px, y = R.py, z = R.pz }
            local W = NV.route_job(R.mode, R.ox, R.oy, R.oz, s0.x, s0.y, s0.z)
            W.nopeople, W.blame = true, R.people
            W.stepin, W.ofl_p, W.groundch, W.legchk = R.stepin, R.ofl_p, R.groundch, R.legchk
            W.saidlong = R.saidlong
            W.trailpre, W.trail_n = R.trailpre, R.trail_n
            if not R.shifted then
                -- the same grid: its traces hold (2026-11-16: a whole-area search again
                -- without them would trace the whole area once more). People only make a
                -- step "soft" there (the pawn trace hits them) -- still a step.
                W.gcache, W.ecache, W.eside, W.gcache2 = R.gcache, R.ecache, R.eside, R.gcache2
            end
            -- as wide as the search that failed (a whole-area search: the whole area)
            if R.whole then W = NV.route_widen(W, true) or W end
            log("ROUTE again without people")
            NV.route = W
            return
        end
        -- NO CELL WITH A CLEAR LAST LEG (2026-11-23, the Aashöhlen, chest TrsrBx_Cliff_D12_06:
        -- the search came within 160-250 of it from every side, and each leg from there hit
        -- something the capsule's trace sees, while the user could reach the chest): "not
        -- reachable" was wrong. The refused cell nearest the target is the goal after all;
        -- at a chest the item approach then looks for its prompt and tries its sides
        -- (NV.iapproach), at a door the push to it does. (Before the trail's retries: the
        -- search did get there.)
        if R.legbest and R.legchk ~= "spot" then
            log(string.format("ROUTE no clear last leg from any cell: to the nearest one, %.0f from the %s",
                R.legbest_d or -1, R.legchk == "door" and "door" or "target"))
            NV.route = R
            nav_route_finish(R.legbest)
            return
        end
        -- from your own trail, 250 and then 700 back (NV.trail_retry): the walk goes back
        -- there first
        if R.mode == "walk" and not R.capped then
            local W = NV.trail_retry(R)
            if W then
                if not R.trailpre then speak(tr("Searching again from a bit further back")) end
                NV.route = W
                return
            end
        end
        -- after a search on the shifted grid (NV.route_shift) the fallbacks below start
        -- from where you stand, and "boxed in" needs both searches to have died at once
        local boxed = (R.pops or 0) <= 3 and (R.pops0 or 0) <= 3
        if R.shifted then R.px, R.py, R.pz = R.shifted.x, R.shifted.y, R.shifted.z end
        if R.trailpre then   -- (a search from your trail: you stand at its first point)
            local c = R.trailpre[1]
            R.px, R.py, R.pz = c.x, c.y, c.z
        end
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
                        R.ox + pox * off, R.oy + poy * off, R.pz + 30, NV_TRACE)
                    if not (ok and not hit) then clear = false; break end
                end
            end
            if clear then
                nav_walk_begin_path({ { x = R.px, y = R.py }, { x = R.ox, y = R.oy } }, tr("direct"))
            else
                -- standing in an OPEN doorway with the target beyond it: the room
                -- behind may not be solid yet seen from outside (the game swaps it in
                -- as you enter) -- from the threshold of the academy office there was
                -- "no route" (2026-11-14). Step through, then route again from inside.
                local thr = NV.through_door and NV.through_door(R.px, R.py, R.pz, R.ox, R.oy)
                if thr and NV.goal then
                    log(string.format("NAVWALK step through door %s", tostring(thr.door.name)))
                    NV.goal = { x = thr.x2, y = thr.y2, z = R.pz, cat = "through", key = NV.goal.key }
                    speak(tr("Through the door first"))
                    nav_walk_begin_path({ { x = R.px, y = R.py }, { x = thr.x1, y = thr.y1 },
                        { x = thr.x2, y = thr.y2 } }, tr("through the door"))
                    return
                end
                -- no route: maybe behind a house door (doorway-plane test, see
                -- M.house_door_for) -- then walk to that door instead; else remember
                -- the failure so the list says "not reachable" from here on
                local g = NV.goal
                if g and g.samehouse then
                    -- at (or in) the target's house: the shut door blocked the search
                    speak(tr("The door is shut. Open it with Enter, then backspace again"))
                    return
                end
                if (NV.retries or 0) > 0 or boxed then
                    -- a RE-route after getting stuck: the target was reachable a moment
                    -- ago, this spot is just wedged -- not a "not reachable" target.
                    -- Or the search died at the start (<= 3 cells): we stand boxed in
                    -- (a corner -- every body-wide step from here grazes a wall), which
                    -- says nothing about the target either.
                    -- Free ourselves first: up to 3 steps into open directions, each
                    -- with a new route (that was the player's job, user 2026-11-14)
                    if boxed and NV.start_diag then pcall(NV.start_diag, R) end
                    if (NV.escapes or 0) < 3 and NV.escape_step and NV.escape_step(R.px, R.py, R.pz, R.ox, R.oy) then
                        NV.escapes = (NV.escapes or 0) + 1
                        return
                    end
                    speak(tr("Stuck, no way on from here. Step aside, then backspace again"))
                    return
                end
                if R.capped then
                    -- the whole area ran out of traces (NV.route_widen), not of cells:
                    -- nothing proven, so no "not reachable" for the list either
                    speak(tr("No route found, search limit reached"))
                    return
                end
                if g and g.key and g.cat ~= "door" then
                    local okd, door, dx, dy, dz = false, nil, nil, nil, nil
                    if g.cat ~= "exit" then   -- an exit is its own way out, never "in a house"
                        okd, door = pcall(M.house_door_for, g.x, g.y, g.z, R.px, R.py, R.pz, true, true, g.tin)
                    end
                    if okd and door then dx, dy, dz = read_actor_pos(door) end
                    NV.noroute[g.key] = { x = R.px, y = R.py, area = M.map_id(), door = dx and door or nil }
                    if dx and math.sqrt((dx - R.px) ^ 2 + (dy - R.py) ^ 2) > NV.ATDOOR and NV.route_begin then
                        NV.goal = { x = dx, y = dy, z = dz or R.pz, cat = "door", key = g.key }
                        speak(tr("Probably inside a building. Routing to its door"))
                        NV.route_begin("walk", dx, dy, dz or R.pz)
                        return
                    end
                end
                speak(tr("Not reachable, no route found"))
            end
        else
            speak(tr("No route found"))
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
    if R.mode == "walk" then   -- debug: the cells and their edge kinds (s soft, D door, x diagonal)
        local parts = {}
        local lastz = R.pz - (M.pfoot or 82)
        for i = #chain, 1, -1 do
            local nd = chain[i]
            local par = R.came[nd.k]
            local w = par and (R.ecache[par.k .. ">" .. nd.k] or R.ecache[nd.k .. ">" .. par.k])
            local t = (w == "soft") and "s" or (type(w) == "number" and "D" or "")
            if par and par.x ~= nd.x and par.y ~= nd.y then t = t .. "x" end
            if (nd.ox or 0) ~= 0 or (nd.oy or 0) ~= 0 then
                t = t .. string.format("~%d", math.floor(math.abs((nd.ox or 0) + (nd.oy or 0)) + 0.5))
            end
            -- (@z: the floor, where it changed by more than 40 -- the bridge's deck vs the bed)
            if nd.z and math.abs(nd.z - lastz) > 40 then
                t = t .. string.format("@%d", math.floor(nd.z + 0.5))
                lastz = nd.z
            end
            parts[#parts + 1] = nd.x .. "," .. nd.y .. t
        end
        log(string.format("ROUTE cells from (%.0f,%.0f): %s", R.px, R.py, table.concat(parts, " ")))
    end
    local raw = { { x = R.px, y = R.py } }
    -- on the shifted grid the walk starts where you stand, then goes to its start cell
    if R.shifted then raw = { { x = R.shifted.x, y = R.shifted.y }, { x = R.px, y = R.py, z = R.pz } } end
    -- a search from your trail (NV.trail_retry): first back along it to its start point
    -- (raw[1] = that point, the trail's last)
    if R.trailpre then
        local pre = {}
        for _, q in ipairs(R.trailpre) do pre[#pre + 1] = { x = q.x, y = q.y, z = q.z } end
        for j = 2, #raw do pre[#pre + 1] = raw[j] end
        raw = pre
    end
    for i = #chain, 1, -1 do   -- (z = the cell's floor, for NV.nudge_wp; ox/oy: a slid step)
        local pre = chain[i].pre   -- the side step before entering a narrow passage
        if pre then raw[#raw + 1] = { x = pre.x, y = pre.y, z = pre.z } end
        raw[#raw + 1] = { x = R.px + chain[i].x * NV.STEP + (chain[i].ox or 0),
                          y = R.py + chain[i].y * NV.STEP + (chain[i].oy or 0), z = chain[i].z }
    end
    raw[#raw + 1] = { x = R.ox, y = R.oy }
    -- a SHUT DOOR on the way: walk to the first one only. There the door leg's usual
    -- ending applies (push to its center until "Öffnen, E", "then backspace again");
    -- the next Backspace routes on through the opened door, door by door.
    local door, cut = NV.route_first_door(R, goalnode)
    if door then
        log(string.format("ROUTE through door %s at (%.0f,%.0f)", tostring(door.name), door.x, door.y))
        if R.mode == "walk" then
            local trail = {}   -- (not "tr": that is the translation function)
            for j = 1, math.max(1, cut - 1) do trail[#trail + 1] = raw[j] end
            trail[#trail + 1] = { x = door.x, y = door.y }
            raw = trail
            NV.goal = { x = door.x, y = door.y, z = door.z, cat = "door", key = NV.goal and NV.goal.key }
        end
    end
    -- PEOPLE IN THE WAY: a way found only without people names the one on it; a way to a
    -- door also checks its last leg (the search ends a cell before the target), where
    -- someone standing in the doorway is
    local blocker = nil
    if R.blame then
        blocker = NV.path_blocker(R.blame, raw, R.pz)
    elseif R.people and #raw >= 2 and (door or (NV.goal and (NV.goal.cat == "door" or NV.goal.cat == "building"))) then
        blocker = NV.path_blocker(R.people, { raw[#raw - 1], raw[#raw] }, R.pz)
    end
    if blocker then
        local nm = NV.person_name(blocker)
        log(string.format("ROUTE blocked by a person at (%.0f,%.0f): %s", blocker.x, blocker.y, tostring(nm)))
        speak(trf("%s is in the way", nm or tr("Someone")))
        return
    end
    -- the cells right at the target are no use: the walk arrives within 110 of it, and
    -- they can lie in its own collision -- the last two steps into a chest were "soft"
    -- (the Pawn trace hit the chest) and the walker pushed into it until the stuck
    -- check (study, 2026-11-14). Drop the tail within 110 on the target's floor.
    if R.mode == "walk" and not door then
        while #raw > 2 do
            local q = raw[#raw - 1]
            if math.sqrt((q.x - R.ox) ^ 2 + (q.y - R.oy) ^ 2) < 110
                and (not q.z or math.abs(q.z - R.oz) < 150) then
                table.remove(raw, #raw - 1)
            else
                break
            end
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
    if ez - R.pz < -250 then floorword = ", " .. tr("downstairs")
    elseif ez - R.pz > 250 then floorword = ", " .. tr("upstairs") end
    log(string.format("ROUTE ok cells=%d wps=%d traces=%d slides=%d no-room=%d capsule-floors=%d too-narrow=%d ledges=%d %.1fs (%d ticks, %.1f ms/tick, %.3f ms/trace)",
        #chain, #pts, R.traces, R.slides or 0, R.nroom or 0, R.npawn or 0, R.ntight or 0, R.nledge or 0, os.clock() - R.started,
        R.ticks or 0, (R.cpu or 0) * 1000 / math.max(1, R.ticks or 0), (R.cpu or 0) * 1000 / math.max(1, R.traces)))
    if R.mode == "walk" then
        if door then speak(tr("A shut door on the way")) end
        if R.trailpre then floorword = floorword .. ", " .. tr("back a bit first") end
        nav_walk_begin_path(pts, (door and tr("to the door") or tr("traced route")) .. floorword)
    else
        local desc, total = nav_describe_path(pts)
        speak(trf("Path: %s. Total %d%s%s.", desc, total, floorword, door and (", " .. tr("through a door")) or ""))
    end
end

-- Doors the router may plan THROUGH: every house/room door (HouseEnterTriggerBP_C) with
-- a readable doorway plane. A shut door is a wall to the traces, so rooms behind rooms
-- (the academy's upper doors) were "not reachable" (2026-11-14). Cached per area.
M.door_list = function()
    local list = M.find_all("HouseEnterTriggerBP_C", 600)
    if M.house_cache_src ~= list then
        M.house_cache, M.plane_cache, M.house_cache_src = {}, {}, list
    end
    if M.door_list_src == list and M.door_list_cache then return M.door_list_cache end
    local out = {}
    pcall(function()
        if not list then return end
        for _, door in pairs(list) do
            local okv = false
            pcall(function() okv = door:IsValid() end)
            local daddr = 0
            if okv then pcall(function() daddr = door:GetAddress() end) end
            if daddr ~= 0 and M.house_is_zone(daddr) then daddr = 0 end   -- a light switch
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
    M.door_list_cache, M.door_list_src = out, list
    return out
end

-- The open door the player stands in (within 160 of its center, no "Öffnen" prompt up)
-- with the target on its other side: { x1, y1 = doorway center, x2, y2 = 170 beyond
-- it toward the target, door }. nil otherwise. For the step-through after "no route".
-- Standing IN the doorway (within 40 of its plane) counts whatever the side: leaving
-- the library, the walker stopped 1 unit outside the plane and 22 off the center line,
-- the body-wide test grazed the frame, and "no route" said "The door is shut" in the
-- open door (2026-11-14). Then the step goes toward the target's side.
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
            if ap * at < 0 or (math.abs(ap) < 40 and math.abs(at) > 40) then best, bd, bat = d, dist, at end
        end
    end
    if not best then return nil end
    local s = (bat > 0) and 1 or -1
    return { x1 = best.cx, y1 = best.cy, x2 = best.cx + best.nx * s * 170, y2 = best.cy + best.ny * s * 170,
             door = best }
end

-- The A* open list as a binary min-heap on f. It was a plain list scanned in full for
-- every step (and shifted by table.remove): fine for small boxes, but quadratic in
-- the big ones that cheap native traces allow. Stale duplicates are skipped on pop
-- (R.closed), as before.
NV.heap_push = function(h, n)
    local i = #h + 1
    local f = n.f
    while i > 1 do
        local pi = i // 2
        local pn = h[pi]
        if pn.f <= f then break end
        h[i] = pn
        i = pi
    end
    h[i] = n
end
NV.heap_pop = function(h)
    local cnt = #h
    if cnt == 0 then return nil end
    local top, last = h[1], h[cnt]
    h[cnt] = nil
    cnt = cnt - 1
    if cnt > 0 then
        local i, f = 1, last.f
        while true do
            local l = i * 2
            if l > cnt then break end
            local r = l + 1
            local c = (r <= cnt and h[r].f < h[l].f) and r or l
            if h[c].f >= f then break end
            h[i] = h[c]
            i = c
        end
        h[i] = last
    end
    return top
end
-- The router's steps: the 4 straight ones first (NV.route_slice needs them before the
-- diagonals), then the 4 diagonals.
NV.DIRS8 = { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 }, { 1, 1 }, { 1, -1 }, { -1, 1 }, { -1, -1 } }
-- Move a waypoint off a wall before the walker heads for it. The grid can put a cell
-- center 10 units from an invisible wall the router's channel can't see (study, x
-- -3420, 2026-11-14): the body can't get there, so the walker pushed into the wall
-- until the stuck check re-routed. 8 short knee-high pawn-profile rays; each hit
-- closer than 50 pushes the point away by the difference (at most 60 in all), and
-- only if the way from the old spot to the new one is clear.
NV.nudge_wp = function(wp)
    wp.nudged = true
    if not wp.z then return end
    local p = get_player_obj(); if not p then return end
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary"); if not ksl then return end
    local CLR, z = 50, wp.z + 60
    local sx, sy = 0, 0
    for _, d in ipairs(NV.DIRS8) do
        local l = (d[1] ~= 0 and d[2] ~= 0) and 1.41421 or 1
        local ux, uy = d[1] / l, d[2] / l
        local ok, hit, oh = line_blocked(ksl, p, wp.x, wp.y, z, wp.x + ux * 70, wp.y + uy * 70, z, NV_TRACE)
        if ok and hit then
            local dist
            pcall(function() dist = oh.Distance end)
            if type(dist) == "number" and dist < CLR then
                sx, sy = sx - ux * (CLR - dist), sy - uy * (CLR - dist)
            end
        end
    end
    local m = math.sqrt(sx * sx + sy * sy)
    if m < 4 then return end
    if m > 60 then sx, sy = sx * 60 / m, sy * 60 / m end
    local ok, hit = line_blocked(ksl, p, wp.x, wp.y, z, wp.x + sx, wp.y + sy, z, NV_TRACE)
    if ok and not hit then
        log(string.format("NAVWALK wp nudged (%.0f,%.0f) by (%.0f,%.0f)", wp.x, wp.y, sx, sy))
        wp.x, wp.y = wp.x + sx, wp.y + sy
    end
end

-- WALLS LEARNED FROM GETTING STUCK (2026-11-16). The router's traces can call a step open,
-- or only "soft" (cost 8), where the character still can't pass: an invisible wall at a
-- ledge. North of Atlasdam a chest stood below one, and every route from above took a
-- short soft step through it; the walk got stuck and planned the same way again, though
-- a way round from below existed (found once, 21 cells). Now where a walk gets stuck with
-- the pawn trace hitting straight ahead (NV.learn_wall), a wall 200 long across that
-- direction is kept for the area: no route crosses it again, and soft steps there cost
-- 30 after that (the same ledge goes on), except near the target (its own collision).
NV.walls = { key = nil, list = {} }
NV.walls_key = function() return (M.level_id and M.level_id()) or M.area_said end
NV.walls_here = function()
    local key = NV.walls_key()
    if key == nil or NV.walls.key ~= key then return {} end
    return NV.walls.list
end
NV.wall_add = function(x1, y1, x2, y2, z)
    local key = NV.walls_key()
    if key == nil then return false end
    if NV.walls.key ~= key then NV.walls = { key = key, list = {} } end
    local L = NV.walls.list
    local mx, my = (x1 + x2) / 2, (y1 + y2) / 2
    for _, w in ipairs(L) do   -- the same spot again: kept once
        if ((w.x1 + w.x2) / 2 - mx) ^ 2 + ((w.y1 + w.y2) / 2 - my) ^ 2 < 40 * 40 and math.abs(w.z - z) < 200 then
            return false
        end
    end
    L[#L + 1] = { x1 = x1, y1 = y1, x2 = x2, y2 = y2, z = z }
    return true
end
-- 2D: do the segments a-b and c-d cross?
NV.seg_cross = function(ax, ay, bx, by, cx, cy, dx, dy)
    local o1 = (bx - ax) * (cy - ay) - (by - ay) * (cx - ax)
    local o2 = (bx - ax) * (dy - ay) - (by - ay) * (dx - ax)
    local o3 = (dx - cx) * (ay - cy) - (dy - cy) * (ax - cx)
    local o4 = (dx - cx) * (by - cy) - (dy - cy) * (bx - cx)
    return ((o1 > 0) ~= (o2 > 0)) and ((o3 > 0) ~= (o4 > 0)) and o1 ~= 0 and o2 ~= 0
end
-- does the step a-b cross one of the learned walls (on about its floor)?
NV.walls_cross = function(walls, ax, ay, bx, by, z)
    if not walls then return false end
    for _, w in ipairs(walls) do
        if math.abs((z or w.z) - w.z) < 200 and NV.seg_cross(ax, ay, bx, by, w.x1, w.y1, w.x2, w.y2) then
            return true
        end
    end
    return false
end

-- A routing job (the walk router's NV.route, or a background check's NV.bg.R): the
-- search box is the start/goal rectangle plus `pad` cells (9); it fails after maxtr
-- traces or maxt seconds. doors / via: see the door edges in NV.route_slice.
-- wbox: a world rectangle the box takes in as well (the whole area, NV.area_bounds).
NV.route_job = function(mode, ox, oy, oz, px, py, pz, pad, wbox)
    pad = pad or 9
    local gx = math.floor((ox - px) / NV.STEP + 0.5)
    local gy = math.floor((oy - py) / NV.STEP + 0.5)
    local startk = key3(0, 0, 0)
    local okd, doors = pcall(M.door_list)
    local R = {
        mode = mode, ox = ox, oy = oy, oz = oz, pad = pad,
        px = px, py = py, pz = pz, gx = gx, gy = gy, startk = startk,
        open = { { x = 0, y = 0, z = pz, k = startk, g = 0, f = math.abs(gx) + math.abs(gy) } },
        came = {}, gbest = { [startk] = 0 }, closed = {}, via = {},
        doors = (okd and type(doors) == "table") and doors or {},
        walls = NV.walls_here(),   -- learned where walks got stuck (NV.learn_wall)
        ecache = {}, gcache = {}, eside = {}, gcache2 = {}, traces = 0, pops = 0, started = os.clock(),
        maxtr = 7000, maxt = 8,   -- (5200 before the diagonals: more traces per cell now)
        minx = math.min(0, gx) - pad, maxx = math.max(0, gx) + pad,
        miny = math.min(0, gy) - pad, maxy = math.max(0, gy) + pad,
    }
    if wbox then
        R.wbox = wbox
        R.minx = math.min(R.minx, math.floor((wbox.x0 - px) / NV.STEP))
        R.maxx = math.max(R.maxx, math.ceil((wbox.x1 - px) / NV.STEP))
        R.miny = math.min(R.miny, math.floor((wbox.y0 - py) / NV.STEP))
        R.maxy = math.max(R.maxy, math.ceil((wbox.y1 - py) / NV.STEP))
    end
    return R
end
-- THE WHOLE AREA (2026-11-16, user: the search must always take in the whole area -- a
-- blind player can't first walk a bit the right way on luck until the walker takes over).
-- On the path to the Maiya caves a chest lay behind an invisible wall, the way round ran
-- through the far north of the map (105 cells, 14840 long). Found from one spot (26657
-- traces in the +40 box), after a battle 300 further along the same way not at all:
-- every stage ran out of TRACES with cells left (7000, +6000, +20000, the shifted grid
-- +20000 without the caches) -- "not reachable" without proof. The last stage now takes
-- in the whole area: where the level's chests, exits, doors, shops and people are (the
-- lists M.find_all keeps, from its cache only -- no FindAllOf here), 12 cells round them,
-- and at least the start/goal rectangle + 40; with traces to match its size
-- (NV.whole_traces). A target is "not reachable" only once that box ran out of cells.
NV.AREA_CLASSES = { "TreasureBoxBP_C", "LevelTrigger_C", "HouseEnterTriggerBP_C", "ShopTriggerBP_C",
    "KSFieldNPCCharacter_C" }
NV.area_bounds = function()
    local key = M.level_id() or M.area_said
    if key == nil then return nil end
    local c = NV.abox
    if c and c.key == key and os.clock() - c.t < 120 then return c end
    local x0, y0, x1, y1, n = math.huge, math.huge, -math.huge, -math.huge, 0
    for _, cls in ipairs(NV.AREA_CLASSES) do
        local fc = M.fa_cache[cls]
        if fc and fc.key == key then
            for i, o in ipairs(fc.list) do
                if M.handle_ok(fc.hs[i]) then
                    local x, y = read_actor_pos(o)
                    if x then
                        x0, y0 = math.min(x0, x), math.min(y0, y)
                        x1, y1 = math.max(x1, x), math.max(y1, y)
                        n = n + 1
                    end
                end
            end
        end
    end
    if n == 0 then return nil end
    local m = 12 * NV.STEP
    NV.abox = { key = key, t = os.clock(), n = n, x0 = x0 - m, y0 = y0 - m, x1 = x1 + m, y1 = y1 + m }
    log(string.format("ROUTE area from %d objects: (%.0f,%.0f)-(%.0f,%.0f)", n, NV.abox.x0, NV.abox.y0,
        NV.abox.x1, NV.abox.y1))
    return NV.abox
end
-- traces for a whole-area search: ~24 a cell of its box (a cell costs 10-20 to explore),
-- 40000 at least, 300000 at most (the walk does ~50000 a second, nav_route_step)
NV.whole_traces = function(R)
    local cells = (R.maxx - R.minx + 1) * (R.maxy - R.miny + 1)
    return math.max(40000, math.min(300000, cells * 24))
end
-- its time: the walk (you wait, Backspace cancels) 90 s, a background check 300 s of its
-- own work (NV.bg_step leaves out the time it waits)
NV.whole_time = function(R) return R.mode == "bg" and 300 or 90 end
-- YOUR OWN TRAIL (2026-11-18, user: "searching the whole area", yet no way, though it went
-- once you were nearer). Twice right after opening a chest the walker had led to, every
-- search from the corner by the chest (walls 30 to both sides) died in a pocket -- 24
-- cells, and 785 cells with the targets 1300-1800 above -- through the whole area and
-- the shifted grid, though you had just walked in; 300 further back the same targets had
-- a route at once. The grid is anchored where you stand, and from a tight corner it
-- doesn't get out. Where you walked is known to be walkable: the pump keeps a point every
-- 100 of your way (NV.trail_add), cleared in a new area or after a jump. A search that
-- failed starts again from a trail point 250 (then 700) back (NV.trail_retry), the whole
-- area at once; the walk goes back along the trail first (R.trailpre, nav_route_finish).
-- The background checks do the same when they failed in a pocket (NV.TRAIL_POCKET cells).
NV.trail = { pts = {}, key = nil }
NV.TRAIL_BACK = { 250, 700 }
NV.TRAIL_POCKET = 3000
NV.trail_add = function(x, y, z)
    local T = NV.trail
    local key = M.level_id() or M.area_said
    if T.key ~= key then T.pts, T.key = {}, key end
    local last = T.pts[#T.pts]
    if last then
        local d = math.sqrt((x - last.x) ^ 2 + (y - last.y) ^ 2)
        local dz = math.abs(z - last.z)
        -- a jump: no way between (after a scene, T.ev, already a step over 150: it may
        -- have moved you)
        if d > 800 or dz > 400 or (T.ev and (d > 150 or dz > 100)) then
            T.pts = {}
        elseif d < 100 and dz < 100 then
            T.ev = nil
            return
        end
    end
    T.ev = nil
    T.pts[#T.pts + 1] = { x = x, y = y, z = z }
    if #T.pts > 80 then table.remove(T.pts, 1) end
end
-- for the pump (radar_pump), which can't see NV (a local of its own block): there
-- `NV.trail_add` was the GLOBAL NV, nil -- the pump died at every field tick and the radar
-- never came back after a load (2026-11-18, 7b449d5; luac -l showed `GETTABUP _ENV "NV"`)
M.trail_add = NV.trail_add
M.trail_event = function() NV.trail.ev = true end
-- The trail point to search from: the newest one at least `back` along the trail behind
-- cur and `mindist` from it in a straight line; and the points from cur to it, in walking
-- order (cur first). nil when the trail is too short.
NV.trail_start = function(cur, back, mindist)
    local T = NV.trail
    if T.key ~= (M.level_id() or M.area_said) or #T.pts == 0 then return nil end
    local pre = { { x = cur.x, y = cur.y, z = cur.z } }
    local along, lx, ly = 0, cur.x, cur.y
    for i = #T.pts, 1, -1 do
        local q = T.pts[i]
        along = along + math.sqrt((q.x - lx) ^ 2 + (q.y - ly) ^ 2)
        lx, ly = q.x, q.y
        pre[#pre + 1] = { x = q.x, y = q.y, z = q.z }
        if along >= back and math.sqrt((q.x - cur.x) ^ 2 + (q.y - cur.y) ^ 2) >= mindist then return q, pre end
    end
    return nil
end
-- The next search after R failed: from the trail, the whole area (nil: no further try)
NV.trail_retry = function(R)
    local n = (R.trail_n or 0) + 1
    local back = NV.TRAIL_BACK[n]
    if not back then return nil end
    local cur = (R.trailpre and R.trailpre[1]) or R.shifted or { x = R.px, y = R.py, z = R.pz }
    local tp, pre = NV.trail_start(cur, back, 200)
    if not tp then return nil end
    local W = NV.route_job(R.mode, R.ox, R.oy, R.oz, tp.x, tp.y, tp.z)
    W.trailpre, W.trail_n = pre, n
    W.people, W.stepin, W.ofl_p, W.groundch, W.legchk = R.people, R.stepin, R.ofl_p, R.groundch, R.legchk
    W.saidlong = R.saidlong
    if R.mode == "bg" then W.maxt = 60 end
    W = NV.route_widen(W, true) or W
    log(string.format("ROUTE again from your trail: %d back, at (%.0f,%.0f), %d points", back, tp.x, tp.y, #pre))
    return W
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
-- With the shim's cheap traces (2026-11-14) a THIRD try followed in a +40 box with
-- 20000 more traces: from the Atlasdam library a building "3230, above" ran out of the
-- +20 box after 11675 traces. Since 2026-11-16 the third try is the WHOLE AREA (see
-- NV.area_bounds). whole: straight there (walls learned here, nav_route_begin).
NV.route_widen = function(R, whole)
    if R.whole then return nil end
    local pad, wbox
    if R.pad < 20 and not whole then
        pad = 20
    else
        pad = 40
        local okb, b = pcall(NV.area_bounds)
        wbox = okb and b or nil
    end
    local W = NV.route_job(R.mode, R.ox, R.oy, R.oz, R.px, R.py, R.pz, pad, wbox)
    W.gcache, W.ecache, W.eside, W.gcache2, W.slides = R.gcache, R.ecache, R.eside, R.gcache2, R.slides
    W.people, W.nopeople, W.blame, W.ppl_hit = R.people, R.nopeople, R.blame, R.ppl_hit
    W.stepin, W.ofl_p, W.pl_all, W.groundch, W.legchk = R.stepin, R.ofl_p, R.pl_all, R.groundch, R.legchk
    W.traces, W.pops, W.started, W.saidlong = R.traces, R.pops, R.started, R.saidlong
    W.cpu, W.ticks, W.ran = R.cpu, R.ticks, R.ran
    W.nroom, W.npawn, W.ntight = R.nroom, R.npawn, R.ntight
    W.shifted, W.pops0, W.shift_i = R.shifted, R.pops0, R.shift_i
    W.trailpre, W.trail_n = R.trailpre, R.trail_n
    if pad == 40 then
        W.whole = true
        W.maxtr = R.traces + NV.whole_traces(W)
        W.maxt = (os.clock() - R.started) + NV.whole_time(W)
        log(string.format("ROUTE whole area: %dx%d cells, %d more traces, after %d traces",
            W.maxx - W.minx + 1, W.maxy - W.miny + 1, W.maxtr - R.traces, R.traces))
    else
        W.maxtr, W.maxt = R.traces + 6000, R.maxt + 8
        log(string.format("ROUTE widen: box +%d cells after %d traces", pad, R.traces))
    end
    return W
end
-- A last try on a grid shifted by half a cell (2026-11-14). The grid is anchored where
-- you stand, and every step needs a body-wide corridor (centre +-42 at knee height), so
-- a passage about 150-210 wide is open on some alignments only: from the study's chest 3
-- the search found a pocket of 6 cells, and one small step aside the whole way
-- (97 cells). Shifted by half a cell, one of the two grids fits every passage 150 or
-- wider. The new start must be reachable: a floor within 100 of yours, a clear line to
-- it. Diagonal shifts first (they move both axes). A shifted search that dies at its own
-- start (<= 3 cells; at the study's chest 3 the first one had no open step) tries the
-- next shift -- cheap; one that explored an area ends the route's tries.
NV.SHIFTS = { { 1, 1 }, { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } }
-- (why: "box" = out of cells, "cap" = out of traces / time. The whole area out of traces:
-- a shifted grid starts without the traces done so far and can't get further.)
NV.route_shift = function(R, why)
    if R.shifted and (R.pops or 0) > 3 then return nil end
    if R.whole and why == "cap" then return nil end
    local base = R.shifted or { x = R.px, y = R.py, z = R.pz }
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local p = get_player_obj()
    if not (ksl and p) then return nil end
    local h = NV.STEP / 2
    for i = (R.shift_i or 0) + 1, #NV.SHIFTS do
        local d = NV.SHIFTS[i]
        local ax, ay = base.x + d[1] * h, base.y + d[2] * h
        local okf, hitf, ohf = line_blocked(ksl, p, ax, ay, base.z + 160, ax, ay, base.z - 240)
        if okf and hitf then
            local dist
            pcall(function() if type(ohf.Distance) == "number" then dist = ohf.Distance end end)
            local az = dist and (base.z + 160 - dist) or base.z
            local okl, hitl = line_blocked(ksl, p, base.x, base.y, base.z + 55, ax, ay, az + 55)
            -- (the walk goes from you to that start first: not through a person -- the
            -- traces don't see people, and a start 65 beyond a guard in a narrow street
            -- bumped into him four times, 2026-11-22)
            local who = R.people and NV.person_on(R.people, base.x, base.y, base.z, ax, ay)
            if who then
                log(string.format("ROUTE shifted start #%d (%d,%d) past a person: skipped", i, d[1] * h, d[2] * h))
            end
            if math.abs(az - base.z) <= 100 and okl and not hitl and not who then
                local W = NV.route_job(R.mode, R.ox, R.oy, R.oz, ax, ay, az, R.pad, R.wbox)
                W.shifted, W.shift_i, W.whole = base, i, R.whole
                W.people, W.nopeople, W.blame, W.ppl_hit = R.people, R.nopeople, R.blame, R.ppl_hit
                W.stepin, W.ofl_p, W.pl_all, W.groundch, W.legchk = R.stepin, R.ofl_p, R.pl_all, R.groundch, R.legchk
                W.pops0 = R.shifted and R.pops0 or R.pops
                W.traces, W.started, W.saidlong = R.traces, R.started, R.saidlong
                W.cpu, W.ticks, W.ran = R.cpu, R.ticks, R.ran
                W.nroom, W.npawn, W.ntight = R.nroom, R.npawn, R.ntight
                W.trailpre, W.trail_n = R.trailpre, R.trail_n
                if R.whole then   -- (the whole area again, without caches)
                    W.maxtr = R.traces + NV.whole_traces(W)
                    W.maxt = (os.clock() - R.started) + NV.whole_time(W)
                else
                    W.maxtr = R.traces + 7000
                    W.maxt = R.maxt + (R.shifted and 2 or 8)
                end
                log(string.format("ROUTE shifted grid #%d (%d,%d) after %d traces, %d cells", i, d[1] * h, d[2] * h,
                    R.traces, R.pops))
                return W
            end
        end
    end
    log("ROUTE no (further) shifted grid start")
    return nil
end
-- Why a route died at its start (2026-11-14: next to a chest, "pops=3"): for each of the
-- 8 first steps the floor (dz to the neighbour, "nofloor") and the knee-high lines
-- (c = center, + / - = the +-42 side lines, p = pawn profile; "x" = hit). One log line.
NV.start_diag = function(R)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local p = get_player_obj()
    if not (ksl and p) then return end
    local parts = {}
    for _, d in ipairs(NV.DIRS8) do
        local diag = d[1] ~= 0 and d[2] ~= 0
        local bx, by = R.px + d[1] * NV.STEP, R.py + d[2] * NV.STEP
        local ok, hit, oh = line_blocked(ksl, p, bx, by, R.pz + 160, bx, by, R.pz - 240)
        local s
        if not (ok and hit) then
            s = "nofloor"
        else
            local dist
            pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
            local zb = dist and (R.pz + 160 - dist) or R.pz
            local dl = diag and 1.41421 or 1
            local pox, poy = d[2] * 42 / dl, -d[1] * 42 / dl
            local marks = {}
            for _, off in ipairs({ 0, 1, -1 }) do
                local ok2, hit2 = line_blocked(ksl, p, R.px + pox * off, R.py + poy * off, R.pz + 55,
                    bx + pox * off, by + poy * off, zb + 55)
                marks[#marks + 1] = ((off == 0) and "c" or (off == 1 and "+" or "-")) .. ((ok2 and not hit2) and "" or "x")
            end
            local okp, hitp = line_blocked(ksl, p, R.px, R.py, R.pz + 55, bx, by, zb + 55, NV_TRACE)
            marks[#marks + 1] = "p" .. ((okp and not hitp) and "" or "x")
            s = string.format("dz%d %s", math.floor(zb - R.pz + 0.5), table.concat(marks))
        end
        parts[#parts + 1] = string.format("(%d,%d) %s", d[1], d[2], s)
    end
    log(string.format("ROUTE start diag at (%.0f,%.0f,%.0f): %s", R.px, R.py, R.pz, table.concat(parts, " | ")))
end
-- FLOORS, NOT HEIGHTS (2026-11-16, user: "er kann das Gasthaus nicht erreichen"). The
-- Flammhuld inn's trigger stands on a terrace ~170 over the street, its edge 28 in front
-- of where the walk ended. 129 over you, it passed every "same level" test (|dz| under
-- 200 / 250 / 300): the search took the start for the goal (within one cell), the walk
-- said "Arrived" at once, and E went to the follower. Actor heights don't tell floors: a
-- shop trigger on your floor sits 43 below you (39 over the floor), people are level with
-- you, a chest is at the floor. The floor under a target does: a down-trace from just over
-- it (channel 0 doesn't see people, triggers don't block). One that starts inside
-- something solid (a chest, a shut door: < 10) tells nothing -- the old height rule then.
-- Floors within NV.FLOOR_SAME: one level. Further apart: stairs or a ledge -- the floor
-- halfway decides (stairs: about halfway up; a ledge: one of the two ends).
NV.FLOOR_SAME = 100
-- the floor under (x, y) seen from height z; nil = none, or the trace began in something
-- solid. (ksl may be nil once the traces are set up.) ch: the trace (default channel 0,
-- NV_TRACE = the capsule's own profile); up: start this far over z (default 50).
NV.floor_at = function(ksl, p, x, y, z, ch, up)
    up = up or 50
    local ok, hit, oh = line_blocked(ksl, p, x, y, z + up, x, y, z - 400, ch)
    if not (ok and hit and oh and type(oh.Distance) == "number") or oh.Distance < 10 then return nil end
    return z + up - oh.Distance
end
-- from floor fa at (ax, ay) to floor fb at (bx, by): one level? true / false
NV.floor_link = function(ksl, p, ax, ay, fa, bx, by, fb)
    local d = math.abs(fb - fa)
    if d <= NV.FLOOR_SAME then return true end
    if d > 300 then return false end
    local mx, my, top = (ax + bx) / 2, (ay + by) / 2, math.max(fa, fb)
    local ok, hit, oh = line_blocked(ksl, p, mx, my, top + 60, mx, my, math.min(fa, fb) - 60)
    if not (ok and hit and oh and type(oh.Distance) == "number") then return false end
    return math.abs(top + 60 - oh.Distance - (fa + fb) / 2) <= d / 4
end
-- you at (px, py, pz), a target at (tx, ty, tz) (its floor tf if known): one level?
-- true / false / nil (a floor not found: the caller keeps its height rule)
NV.level_link = function(ksl, p, px, py, pz, tx, ty, tz, tf)
    tf = tf or NV.floor_at(ksl, p, tx, ty, tz)
    if not tf then return nil end
    local pf = NV.floor_at(ksl, p, px, py, pz)
    if not pf then return nil end
    return NV.floor_link(ksl, p, px, py, pf, tx, ty, tf)
end
-- the same for the walk's goal (NV.goal), its floor measured once per walk (g.fl)
NV.goal_level = function(p, px, py, pz)
    local g = NV.goal
    if not (g and g.z) or M.tr_native ~= true then return nil end
    if g.fl == nil then g.fl = NV.floor_at(nil, p, g.x, g.y, g.z) or false end
    if not g.fl then return nil end
    local ok = NV.level_link(nil, p, px, py, pz, g.x, g.y, g.z, g.fl)
    if ok == false and not g.flog then
        g.flog = true
        log(string.format("NAVWALK not at the goal's level: goal floor %.0f (z %.0f), you at (%.0f,%.0f,%.0f)",
            g.fl, g.z, px, py, pz))
    end
    return ok
end
-- the A* goal test's floor part (NV.route_slice): the goal's floor once per search
-- (R.ofl); the start node holds your height, not a floor -- measured; other nodes are
-- floors (nav_ground)
NV.goal_floor_ok = function(R, ksl, p, best)
    if R.ofl == nil then
        R.ofl = NV.floor_at(ksl, p, R.ox, R.oy, R.oz) or false
        R.traces = R.traces + 1
        -- the target hovers over that floor: an invisible one under it, like the bridge's
        -- deck (nav_ground then takes the capsule's floor there, NV.pawn_floor) -- that
        -- profile's floor, or none (the old height rule; a chest blocks that trace itself)
        if R.ofl and R.oz - R.ofl > 150 then
            R.ofl = NV.floor_at(ksl, p, R.ox, R.oy, R.oz, NV_TRACE) or false
            R.traces = R.traces + 1
        end
    end
    if not R.ofl then return true end
    local fz = best.z
    if best.k == R.startk then
        fz = NV.floor_at(ksl, p, R.px, R.py, R.pz)
        if not fz then return true end
    end
    R.traces = R.traces + 1
    local ok = NV.floor_link(ksl, p, R.px + best.x * NV.STEP + (best.ox or 0),
        R.py + best.y * NV.STEP + (best.oy or 0), fz, R.ox, R.oy, R.ofl)
    if not ok and not R.floorlog then
        R.floorlog = true
        log(string.format("ROUTE goal floor %.0f (z %.0f): cell %d,%d on floor %.0f is not its level, searching on",
            R.ofl, R.oz, best.x, best.y, fz))
    end
    return ok
end
-- THE LAST LEG INTO A STEP-IN TARGET (NV.is_stepin; 2026-11-16, Flammhuld inn, walked in
-- the game): the way in goes round the stone base on its left and up stairs behind it to
-- the landing, 96 up; "Gasthaus, E" came at (-1180,-1608). Channel 0 sees none of it, so
-- the search took the start beside the base for the goal (within one cell) and the walk
-- went straight at the base, where a man stands. A node is the goal only when the
-- capsule's own trace walks in from it: from its real floor (the same profile, from 200
-- over the node; at the start 82 under you) at knee height to 30 short of the target at
-- its floor's knee height. A hit at a person blocks only while the search keeps away from
-- people (R.goal_ppl: the search without them then follows at once and names who stands
-- there); any other hit: not the goal.
-- Targets whose last leg is traced (NV.goal_leg_ok): chests (hidden items and markers on
-- them too) -- you walk right up to them. Not people: a shopkeeper or a barkeep stands
-- behind a counter and is talked to across it, which the leg would take for a wall (a
-- fence before a person is learned on the first bump instead, NV.learn_wall). Not exits
-- (the map's edge lies on the leg), a story event's spot (stepped in) or another side of
-- a chest (a free spot).
-- A DOOR (a building, a house's door on the way in or out) too, as "door" (2026-11-23,
-- Flammhuld's prison, user: "another object the walker can't reach"): the door stands on
-- a landing 90 above the street, closed off on the street side by an invisible wall 115
-- before the door (BlockingVolume26, x -1731..-1720, y -1255..-983); the way up is round
-- its south end. The street cell opposite the door was within one cell, so it was the
-- goal; the walk ran into the wall, learned it, and "Neue Route" every 2 s took the
-- spot it stood on for the goal again. The leg ends 80 short of the door actor, so the
-- door's own collision (10 from it) is never hit.
NV.leg_target = function(t, cat)
    if cat == "door" or cat == "building" then return "door" end
    if cat == "spot" or cat == "exit" or cat == "through" or cat == "event" then return false end
    return (t and t.actor and class_name_of(t.actor) == "TreasureBoxBP_C") and true or false
end
-- The person (from the search's list, or a scan once per search) standing where a leg's
-- trace hit (oh, on the line from (wx, wy, sz) to (ex, ey, ez); nf = the floor there), or nil
NV.leg_person = function(R, wx, wy, sz, ex, ey, ez, oh, nf)
    local pl = R.people or R.blame
    if not pl then
        if R.pl_all == nil then
            local okp, ppl = pcall(NV.people_scan, R.px, R.py, R.pz)
            R.pl_all = okp and ppl or false
        end
        pl = R.pl_all or nil
    end
    local len = math.sqrt((ex - wx) ^ 2 + (ey - wy) ^ 2 + (ez - sz) ^ 2)
    local t = (len > 0 and oh and type(oh.Distance) == "number") and math.min(1, oh.Distance / len) or 0
    local hx, hy = wx + (ex - wx) * t, wy + (ey - wy) * t
    for _, c in ipairs(pl or {}) do
        if math.abs(c.z - (nf + 82)) < 250 and (c.x - hx) ^ 2 + (c.y - hy) ^ 2 < 60 * 60 then return c end
    end
    return nil
end
-- THE LAST LEG TO ANY OTHER TARGET (2026-11-17, Süd-Pflastersten-Kluft, user: "a fence is
-- in the way, the walker doesn't see it"). A chest 183 below, beyond a fence on the edge
-- of the path, the ground falling away behind it. The goal test took the cell above the
-- fence: within one cell, and the floors linked (the ground behind it slopes, so the
-- floor halfway was about halfway down). The leg from that cell to the chest was never
-- traced -- a trace all the way hits the chest itself -- so the walker ran into the fence
-- 20 times ("Neue Route"), and learned no wall there (NV.learn_wall: not within 250 of
-- the target). Now the leg is traced at knee height from the node to 80 short of the
-- target: channel 0 (fences, walls) and the capsule's profile (invisible walls too). A
-- hit, unless at a person, means: not the goal, search on. Level from the node when the
-- target is lower (the ground falls away under the line), rising to the target's floor
-- when it is higher. Under 100 to go: the walk's own last steps, nothing traced.
-- ANOTHER SIDE of a person or a chest ("spot", a free point to stand on; 2026-11-23, the
-- cathedral in Flammhuld): the side chosen for the former Ardante knight, sitting between
-- two pews, lay beyond the pew you stood at, 192 away, so the spot you stood on was the
-- goal ("0 cells"), the walk ran into the pew and re-routed five times. Its leg runs to 20
-- short of the spot (nothing of its own to hit there), and is traced from 30 on; a person
-- on it blocks like a wall -- also the one you want to talk to, beside the spot.
NV.goal_leg_ok = function(R, ksl, p, best)
    local spot = (R.legchk == "spot")
    local wx = R.px + best.x * NV.STEP + (best.ox or 0)
    local wy = R.py + best.y * NV.STEP + (best.oy or 0)
    local nf = best.z
    if best.k == R.startk then nf = R.shifted and R.pz or (R.pz - (M.pfoot or 82)) end
    local dx, dy = R.ox - wx, R.oy - wy
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= (spot and 30 or 100) then return true end
    local back = spot and 20 or 80
    local ex, ey = R.ox - dx / d * back, R.oy - dy / d * back
    local tf = (R.ofl and math.abs(R.ofl - R.oz) < 200) and R.ofl or R.oz
    local sz, ez = nf + 55, math.max(nf, tf) + 55
    R.traces = R.traces + 2
    local ok0, hit0 = line_blocked(ksl, p, wx, wy, sz, ex, ey, ez)
    local okp, hitp, oh = line_blocked(ksl, p, wx, wy, sz, ex, ey, ez, NV_TRACE)
    local blocked = ok0 and hit0
    if not blocked and okp and hitp then
        if spot then
            blocked = true
        else
            local q = NV.leg_person(R, wx, wy, sz, ex, ey, ez, oh, nf)
            if q and R.people then R.ppl_hit = (R.ppl_hit or 0) + 1; R.goal_ppl = true; return false end
            blocked = not q
        end
    end
    if blocked then
        R.nleg = (R.nleg or 0) + 1
        -- (the refused cell nearest the target: the goal after all when no cell has a clear
        -- leg -- see nav_route_finish; never for another side, a free spot)
        if not spot and (not R.legbest_d or d < R.legbest_d) then R.legbest, R.legbest_d = best, d end
        if not R.goallog then
            R.goallog = true
            log(string.format("ROUTE last leg blocked from cell %d,%d (floor %.0f) to the %s (floor %.0f, %.0f away): %s, searching on",
                best.x, best.y, nf, R.legchk == "door" and "door" or (spot and "spot" or "target"), tf, d,
                hit0 and "a wall" or "an invisible wall or a person"))
        end
        return false
    end
    return true
end
NV.stepin_leg = function(R, ksl, p, best)
    if R.ofl_p == nil then
        R.ofl_p = NV.floor_at(ksl, p, R.ox, R.oy, R.oz, NV_TRACE) or false
        R.traces = R.traces + 1
        log(string.format("ROUTE step-in target floor %s (z %.0f)", tostring(R.ofl_p), R.oz))
    end
    local tf = R.ofl_p
    if not tf then return true end            -- no floor under it: the walk's prompt decides
    local wx = R.px + best.x * NV.STEP + (best.ox or 0)
    local wy = R.py + best.y * NV.STEP + (best.oy or 0)
    local nf
    if best.k == R.startk then
        nf = R.shifted and R.pz or (R.pz - (M.pfoot or 82))
    else
        nf = NV.floor_at(ksl, p, wx, wy, best.z, NV_TRACE, 200)
        R.traces = R.traces + 1
        if not nf then return false end       -- inside something solid
        nf = NV.stepin_floor(R, wx, wy, nf)
    end
    local dx, dy = R.ox - wx, R.oy - wy
    local d = math.sqrt(dx * dx + dy * dy)
    if d <= 30 then return math.abs(nf - tf) <= 60 end
    local ex, ey = R.ox - dx / d * 30, R.oy - dy / d * 30
    local sz, ez = nf + 55, tf + 55
    R.traces = R.traces + 1
    local ok, hit, oh = line_blocked(ksl, p, wx, wy, sz, ex, ey, ez, NV_TRACE)
    if not ok then return false end
    local q = nil
    if hit then
        q = NV.leg_person(R, wx, wy, sz, ex, ey, ez, oh, nf)
        if not q then
            if not R.leglog then
                R.leglog = true
                log(string.format("ROUTE step-in: no way in from cell %d,%d (floor %.0f, target floor %.0f, hit at %.0f)",
                    best.x, best.y, nf, tf, type(oh.Distance) == "number" and oh.Distance or -1))
            end
            return false
        end
    elseif R.people then
        q = NV.person_on(R.people, wx, wy, nf + 82, R.ox, R.oy)   -- the body is wider than the line
    end
    if q and R.people then
        R.ppl_hit = (R.ppl_hit or 0) + 1
        R.goal_ppl = true
        return false
    end
    return true
end
-- "above" / "below" for the lists (a msgid, nil = level with you): a floor up or down
-- (|dz| over LEVEL_THRESH), or a terrace or a hollow (floors over NV.FLOOR_SAME apart)
NV.level_word = function(p, px, py, pz, tx, ty, tz)
    local dz = (tz or pz) - pz
    if dz > LEVEL_THRESH then return "above" elseif dz < -LEVEL_THRESH then return "below" end
    if M.tr_native ~= true then return nil end
    local tf = NV.floor_at(nil, p, tx, ty, tz or pz)
    local pf = tf and NV.floor_at(nil, p, px, py, pz)
    if not pf then return nil end
    if tf - pf > NV.FLOOR_SAME then return "above" elseif pf - tf > NV.FLOOR_SAME then return "below" end
    return nil
end

-- STEP-IN TARGETS (2026-11-16, Flammhuld inn, after c38e2eb didn't help). A shop without
-- a keeper opens at its trigger, a box in its entrance: there the game shows "Gasthaus,
-- E", and only there. The inn's door is on a landing 96 up behind a stone base; three
-- people stand in a row in front of the base (no way between them), and the way in goes
-- round the base's left end and up stairs behind it (NV.stepin_leg). Channel 0 sees
-- neither the base nor the stairs (CHPROBE "up ch0=- ch1=28"), so floors and routes took
-- it all for street: "Arrived" 152 away beside the base, E went to the follower. Now such
-- a walk ends only at the shop's prompt (also when it comes up on the way); stuck within
-- 250 of it, or 2 s of pushing at the end without it: "Entrance not reached", with the
-- people standing there.
NV.is_stepin = function(t) return t ~= nil and t.cat == "shop" and not t.keeper end
-- the shop's own prompt is up ("Gasthaus, E"; any prompt when the name is unknown)
NV.stepin_prompt = function()
    if not M.popup_said then return false end
    local nm = NV.goal and NV.goal.pname
    if not nm then return true end
    return (M.popup_text or ""):find(nm, 1, true) == 1
end
-- the people within 220 of the step-in goal on its floor, but not the follower (a person
-- of the ResidentGame level that trails you); -> count
NV.stepin_people = function(pz)
    local g = NV.goal
    if not g then return 0 end
    local okp, ppl = pcall(NV.people_scan, g.x, g.y, pz)
    local n = 0
    for _, q in ipairs(okp and ppl or {}) do
        if math.abs(q.z - pz) < 300 and (q.x - g.x) ^ 2 + (q.y - g.y) ^ 2 < 220 * 220 then
            local full = ""
            pcall(function() full = q.actor:GetFullName() end)
            if not full:find("ResidentGame", 1, true) then n = n + 1 end
        end
    end
    return n
end
NV.stepin_fail = function(px, py, pz)
    local g = NV.goal
    local n = NV.stepin_people(pz)
    log(string.format("NAVWALK step-in not reached: you (%.0f,%.0f,%.0f), target (%.0f,%.0f,%.0f), %d people there",
        px, py, pz, g and g.x or 0, g and g.y or 0, g and g.z or 0, n))
    if n > 0 then
        return trn("Entrance not reached, %d person is standing there", "Entrance not reached, %d people are standing there", n)
    end
    return tr("Entrance not reached")
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
            ox + pox * off, oy + poy * off, pz + 30, NV_TRACE)
        if not (ok and not hit) then return false end
    end
    return true
end

-- NARROW PASSAGES (2026-11-15): lower Felsfall's long stairs are ~118 wide between their
-- walls. A step's corridor (centre +-42) fits there only within 17 of their middle, and
-- cell centres 130 apart missed that on both grids: the exit up was "not reachable" and
-- the walk never started. A straight step whose CENTRE line is clear while a side line
-- hits may slide its corridor sideways by 22 or 44, either way. The cell then stands for
-- the slid point (node ox/oy; the walk goes there), and steps on from it run parallel
-- (s0) or back onto the grid (0). Diagonals only between unslid cells.
-- -> w (true / "soft"), offset {ox, oy}, floor z, traces used | nil, nil, nil, used
NV.SLIDES = { 22, -22, 44, -44 }

-- PEOPLE IN THE WAY (2026-11-15). The router's traces (channel 0) don't see people; only
-- the player's own profile hits their capsules (CHPROBE beside the Armer: ch0 -, Pawn
-- 33). Routes ran through them as cheap "soft" steps and the walk bumped -- in lower
-- Felsfall the Armer stands in a house's doorway. Walks and directions now keep
-- NV.PEOPLE_R (both capsules and a margin) from everyone in the area except the person
-- walked to. When that leaves no way, the same search runs without people, and if it
-- finds one the walk says who is in the way (nav_route_finish). The background check of
-- the list leaves people out: they move.
NV.PEOPLE_R = 70
-- the people of the area (FindAllOf at most every 20 s, positions read fresh): circles
-- {x, y, z, actor}; hidden helpers are not people; the one at the target is left out
NV.people_scan = function(px, py, pz, ox, oy)
    local out = {}
    for _, o in ipairs(M.find_all("KSFieldNPCCharacter_C", 600)) do
        local okv, hidden = false, false
        pcall(function() okv = o:IsValid() end)
        if okv then pcall(function() hidden = (o.bHidden == true) end) end
        if okv and not hidden then
            local x, y, z = read_actor_pos(o)
            if x and not (ox and math.sqrt((x - ox) ^ 2 + (y - oy) ^ 2) < 90) then
                out[#out + 1] = { x = x, y = y, z = z or pz, actor = o }
            end
        end
    end
    return out
end
-- the first person a step from a to b comes within NV.PEOPLE_R of, or nil. Heading away
-- from someone you stand next to is fine (the closest point is the start).
NV.person_on = function(people, ax, ay, az, bx, by)
    if not people then return nil end
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    local r2 = NV.PEOPLE_R * NV.PEOPLE_R
    for _, q in ipairs(people) do
        if math.abs(q.z - az) < 250 then
            local t = (l2 > 0) and (((q.x - ax) * dx + (q.y - ay) * dy) / l2) or 0
            if t > 0 then
                if t > 1 then t = 1 end
                local cx, cy = ax + dx * t - q.x, ay + dy * t - q.y
                if cx * cx + cy * cy < r2 then return q end
            end
        end
    end
    return nil
end
-- the first person on a list of walk points ({x, y, z}), or nil
NV.path_blocker = function(people, pts, z0)
    for i = 2, #pts do
        local a, b = pts[i - 1], pts[i]
        local q = NV.person_on(people, a.x, a.y, a.z or z0, b.x, b.y)
        if q then return q end
    end
    return nil
end
NV.person_name = function(q)
    local nm
    pcall(function() nm = NV.resolve_name(q.actor) end)
    if nm == "" or nm == "???" then nm = nil end
    return nm
end
-- floor at a world point (down trace from za+160 to za-240), cached per 10-unit spot
NV.ground_at = function(R, ksl, p, wx, wy, za)
    local gk = math.floor(wx / 10 + 0.5) .. "," .. math.floor(wy / 10 + 0.5) .. "@" .. math.floor((za - R.pz) / 200 + 0.5)
    local c = R.gcache2[gk]
    if c ~= nil then return c, 0 end
    R.traces = R.traces + 1
    -- (R.groundch: a step-in route measures floors with the capsule's own profile, which
    -- sees steps channel 0 misses -- the Flammhuld inn's side stairs, NV.stepin_leg)
    local ok, hit, oh = line_blocked(ksl, p, wx, wy, za + 160, wx, wy, za - 240, R.groundch)
    local z = false
    if ok and hit then
        local dist
        pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
        z = dist and (za + 160 - dist) or za
        if R.groundch then z = NV.stepin_floor(R, wx, wy, z) end
    end
    R.gcache2[gk] = z
    return z, 1
end
-- A RISE OR DROP between two cells (more than 45) is walkable only as stairs or a ramp:
-- the floor between them climbs. A ledge shows only its two levels in between: in Ravus
-- manor's library (user 2026-11-20) the route went over the TABLES (floor -399, table tops
-- -299 with papers on them, "@-299" between "@-399" in the ROUTE lines), the knee-high
-- line rising with the step cleared each table's edge, and the walk bumped into them for
-- minutes. Probed on the capsule's own profile (what the character stands on; channel 0
-- is blind to some stairs) at 1/2, 1/4 and 3/4 of the step: a point clearly between the
-- two floors -> a slope; none -> a ledge, no step. (Step-in routes: NV.stepin_rise_ok.)
NV.RISE_FREE, NV.RISE_MARGIN = 45, 12
NV.rise_ok = function(R, ksl, p, best, ax, ay, bx, by, zb)
    local az = best.z
    if best.k == R.startk and not R.shifted then
        -- (the start node's z is the player's capsule, not the floor: the floor under him)
        if R.start_floor == nil then R.start_floor = NV.ground_at(R, ksl, p, R.px, R.py, R.pz) or false end
        az = R.start_floor or (R.pz - (M.pfoot or 82))
    end
    if math.abs(zb - az) <= NV.RISE_FREE then return true end
    local lo, hi = math.min(az, zb), math.max(az, zb)
    local top = hi + 160
    R.gcache3 = R.gcache3 or {}
    local function floor(sx, sy)   -- the floor at a point on the capsule's profile, or false
        local gk = math.floor(sx / 10 + 0.5) .. "," .. math.floor(sy / 10 + 0.5) .. "@" .. math.floor(hi / 50 + 0.5)
        local z = R.gcache3[gk]
        if z == nil then
            R.traces = R.traces + 1
            local ok, hit, oh = line_blocked(ksl, p, sx, sy, top, sx, sy, lo - 120, NV_TRACE)
            z = false
            if ok and hit then
                local dist
                pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
                if dist and dist >= 1 then z = top - dist end
            end
            R.gcache3[gk] = z
        end
        return z
    end
    -- the two ends level on the capsule's profile: channel 0 read one end's floor under
    -- something the character stands on (the Maiya bridge's ends: the river bed 456 under
    -- the invisible deck 507, test_water.lua) -- no rise at all
    local fa, fb = floor(ax, ay), floor(bx, by)
    if fa and fb and math.abs(fa - fb) <= NV.RISE_FREE then return true end
    for _, f in ipairs({ 0.5, 0.25, 0.75 }) do
        local z = floor(ax + (bx - ax) * f, ay + (by - ay) * f)
        if z and z > lo + NV.RISE_MARGIN and z < hi - NV.RISE_MARGIN then return true end
    end
    R.nledge = (R.nledge or 0) + 1
    return false
end
-- STEP-IN ROUTES know their floors (R.groundch, the capsule's own profile), so two more
-- rules there (test_inn.lua: a corner cut through the inn's base wall, and a 96 ledge
-- taken as a step because the knee-high line rose with it):
-- a rise over 45 between two cells is a step only on stairs (the floor halfway about
-- halfway up), not at a ledge
NV.stepin_rise_ok = function(R, ksl, p, best, nx, ny, zb)
    local bz = best.z
    if best.k == R.startk and not R.shifted then bz = R.pz - (M.pfoot or 82) end
    local dz = zb - bz
    if math.abs(dz) <= 45 then return true end
    local ax = R.px + best.x * NV.STEP + (best.ox or 0)
    local ay = R.py + best.y * NV.STEP + (best.oy or 0)
    local bx, by = R.px + nx * NV.STEP, R.py + ny * NV.STEP
    local zm = NV.ground_at(R, ksl, p, (ax + bx) / 2, (ay + by) / 2, math.max(bz, zb))
    if not zm then return false end
    return math.abs(zm - (bz + zb) / 2) <= math.abs(dz) / 4
end
-- ...and the capsule's trace hitting something is a wall, unless a person stands at the
-- line (people are the people rules' business: kept away from, or named)
NV.stepin_person_at = function(R, ax, ay, bx, by, z)
    local pl = R.people or R.blame
    if not pl then
        if R.pl_all == nil then
            local okp, ppl = pcall(NV.people_scan, R.px, R.py, R.pz)
            R.pl_all = okp and ppl or false
        end
        pl = R.pl_all or nil
    end
    if not pl then return false end
    local dx, dy = bx - ax, by - ay
    local l2 = dx * dx + dy * dy
    for _, q in ipairs(pl) do
        if math.abs(q.z - z) < 250 then
            local t = (l2 > 0) and math.max(0, math.min(1, ((q.x - ax) * dx + (q.y - ay) * dy) / l2)) or 0
            local cx, cy = ax + dx * t - q.x, ay + dy * t - q.y
            if cx * cx + cy * cy < 60 * 60 then return true end
        end
    end
    return false
end
-- ...and that profile also lands on people's heads: there the floor is the one under the
-- person (else a person on the stairs made them a ledge, also for the search without
-- people that names who is in the way)
NV.stepin_floor = function(R, x, y, z)
    if not z then return z end
    local pl = R.people or R.blame
    if not pl then
        if R.pl_all == nil then
            local okp, ppl = pcall(NV.people_scan, R.px, R.py, R.pz)
            R.pl_all = okp and ppl or false
        end
        pl = R.pl_all or nil
    end
    for _, q in ipairs(pl or {}) do
        if (q.x - x) ^ 2 + (q.y - y) ^ 2 < 45 * 45 and z > q.z then return q.z - (M.pfoot or 82) end
    end
    return z
end
NV.slide_step = function(R, ksl, p, best, d, nx, ny)
    local used = 0
    local qx, qy = d[2], -d[1]                     -- across the step (straight steps: unit)
    local bo_x, bo_y = best.ox or 0, best.oy or 0
    local ax, ay = R.px + best.x * NV.STEP + bo_x, R.py + best.y * NV.STEP + bo_y
    local cx, cy = R.px + nx * NV.STEP, R.py + ny * NV.STEP
    local tries, seen = {}, {}
    local function add(s)
        s = math.floor(s + 0.5)
        if not seen[s] then seen[s] = true; tries[#tries + 1] = s end
    end
    if bo_x ~= 0 or bo_y ~= 0 then add(0); add(bo_x * qx + bo_y * qy) end
    for _, s in ipairs(NV.SLIDES) do add(s) end
    -- the 3 lines of a corridor from (x1,y1) to (x2,y2) along the step: clear?
    local function corridor(x1, y1, z1, x2, y2, z2)
        for _, off in ipairs({ 0, 1, -1 }) do
            R.traces = R.traces + 1
            used = used + 1
            local o2, h2 = line_blocked(ksl, p, x1 + qx * 42 * off, y1 + qy * 42 * off, z1 + 55,
                x2 + qx * 42 * off, y2 + qy * 42 * off, z2 + 55)
            if not (o2 and not h2) then return false end
        end
        return true
    end
    for _, s in ipairs(tries) do
        local bx, by = cx + qx * s, cy + qy * s
        local zb, u = NV.ground_at(R, ksl, p, bx, by, best.z)
        used = used + u
        if zb and math.abs(zb - best.z) <= 200 and (R.stepin or NV.rise_ok(R, ksl, p, best, ax, ay, bx, by, zb)) then
            -- straight from where this cell stands, or (into the passage from open
            -- ground) a side step inside this cell first, then parallel: from a cell 50
            -- off the passage's middle the slanted corridor clipped its entrance
            local pre = nil
            local ok = corridor(ax, ay, best.z, bx, by, zb)
            if not ok and s ~= 0 then
                local sx, sy = R.px + best.x * NV.STEP + qx * s, R.py + best.y * NV.STEP + qy * s
                if math.abs(sx - ax) + math.abs(sy - ay) > 1 then
                    local zs, u2 = NV.ground_at(R, ksl, p, sx, sy, best.z)
                    used = used + u2
                    if zs and math.abs(zs - best.z) <= 60 then
                        R.traces = R.traces + 1
                        used = used + 1
                        local o3, h3 = line_blocked(ksl, p, ax, ay, best.z + 55, sx, sy, zs + 55)
                        if o3 and not h3 and corridor(sx, sy, zs, bx, by, zb) then
                            ok, pre = true, { x = sx, y = sy, z = zs }
                        end
                    end
                end
            end
            if ok then
                R.traces = R.traces + 1
                used = used + 1
                local fx, fy, fz = ax, ay, best.z
                if pre then fx, fy, fz = pre.x, pre.y, pre.z end
                local okp, hitp = line_blocked(ksl, p, fx, fy, fz + 55, bx, by, zb + 55, NV_TRACE)
                -- unlike a plain step, a slid one the player's own profile calls blocked is
                -- out: at a house door in lower Felsfall the route took one into an
                -- invisible wall (ch0 blind, Pawn 28) instead of the door, and the walk
                -- stuck there (2026-11-15). Along the stairs the slid line runs parallel to
                -- the walls and stays clear. (A person on it doesn't count in the search
                -- without people: it is there to name who stands in a narrow way.)
                if okp and hitp and R.nopeople and NV.stepin_person_at(R, fx, fy, bx, by, fz) then hitp = false end
                if okp and not hitp then
                    if s ~= 0 then R.slides = (R.slides or 0) + 1 end
                    return true, { qx * s, qy * s, pre = pre }, zb, used
                end
            end
        end
    end
    return nil, nil, nil, used
end

-- One slice of the A* search on job R: at most `budget` traces and `itercap` loop
-- turns. Returns "found", node | "fail", why ("box" = no cells left in the box,
-- "cap" = out of traces / time) | nil (not done, call again next tick).
NV.route_slice = function(R, budget, itercap, deadline)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local p = get_player_obj()
    if not (ksl and p) then return "fail", "player" end
    -- HARD per-tick iteration cap. budget counts TRACES, but nav_ground / the edge
    -- wall-check return used=0 on a cache hit -- so over warm cache budget stops
    -- decrementing and the loop below would spin (O(open) min-scan each iteration)
    -- until the 8s route deadline, ALL IN ONE TICK = a multi-second game freeze.
    -- Cap iterations so a warm-cache tick yields to the next pump instead.
    -- deadline (os.clock): also yield once this tick has used its time.
    local iters = 0
    while budget > 0 do
        if deadline and os.clock() > deadline then return nil end
        iters = iters + 1
        if iters > itercap then return nil end   -- yield; routing resumes next tick
        local best = NV.heap_pop(R.open)
        if not best then return "fail", "box" end
        if not R.closed[best.k] then
            R.closed[best.k] = true
            R.pops = R.pops + 1
            -- Reached when WITHIN ONE CELL of the goal, not on the exact goal cell:
            -- solid targets (chests, NPCs) occupy their own cell and block the knee-height
            -- clearance trace into it, so the A* can never enter it (-> "No route found")
            -- even though you can stand adjacent and interact. The built path still appends
            -- the real goal position, so the walker finishes the last ~1 cell and arrives.
            -- ...on the goal's floor: below the Flammhuld inn's terrace the start counted
            -- (2026-11-16, NV.goal_floor_ok)
            if math.abs(best.x - R.gx) <= 1 and math.abs(best.y - R.gy) <= 1
                and math.abs(best.z - R.oz) <= 300 and NV.goal_floor_ok(R, ksl, p, best)
                and (not R.stepin or NV.stepin_leg(R, ksl, p, best))
                and (not R.legchk or NV.goal_leg_ok(R, ksl, p, best)) then
                return "found", best
            end
            -- 8 neighbours (2026-11-14, user: too many wall bumps and re-routes): the 4
            -- straight steps first -- they also decide the diagonals and how close this
            -- cell is to a wall -- then the diagonals. A diagonal needs both straight
            -- steps beside it open (no corner cutting); the walker moves in the same 8
            -- directions, so the old staircases (every cell a corner) become straight
            -- runs. Closed neighbours are checked too (cached, mostly as the reverse
            -- step), to count the walls.
            local open4, blocked, cand = {}, 0, {}
            -- a cell entered by a slid step stands for the slid point (NV.slide_step)
            local fromslid = (best.ox or 0) ~= 0 or (best.oy or 0) ~= 0
            for _, d in ipairs(NV.DIRS8) do
                local nx, ny = best.x + d[1], best.y + d[2]
                local diag = d[1] ~= 0 and d[2] ~= 0
                local inbox = nx >= R.minx and nx <= R.maxx and ny >= R.miny and ny <= R.maxy
                if inbox and diag and (fromslid or not (open4[d[1] .. ",0"] and open4["0," .. d[2]])) then
                    inbox = false
                end
                if inbox and fromslid then
                    -- from a slid point: straight steps only, slid again or back onto the grid
                    local sw, so, sz, used = NV.slide_step(R, ksl, p, best, d, nx, ny)
                    budget = budget - used
                    if sw then
                        cand[#cand + 1] = { nx, ny, sz, key3(nx, ny, zlayer(R, sz)), sw, false, so }
                    else
                        blocked = blocked + 1
                    end
                elseif inbox then
                    local zb, used = nav_ground(R, ksl, p, nx, ny, best.z, best.k == R.startk and not R.shifted)
                    budget = budget - used
                    if zb and math.abs(zb - best.z) <= 200
                        and (not R.stepin or NV.stepin_rise_ok(R, ksl, p, best, nx, ny, zb))
                        and (R.stepin or NV.rise_ok(R, ksl, p, best, R.px + best.x * NV.STEP, R.py + best.y * NV.STEP,
                            R.px + nx * NV.STEP, R.py + ny * NV.STEP, zb)) then
                        local nk = key3(nx, ny, zlayer(R, zb))
                        -- wall check at knee height between the two ground points
                        local ekey = best.k .. ">" .. nk
                        local w = R.ecache[ekey]
                        if w == nil then w = R.ecache[nk .. ">" .. best.k] end   -- traced from there
                        if w == nil then
                            -- CAPSULE-WIDTH clearance: 3 parallel knee-height
                            -- lines (center and +-42 units). A single ray can
                            -- thread banister gaps the character cannot fit
                            -- through -- that wedged the stair walks.
                            local dl = diag and 1.41421 or 1
                            local pox, poy = d[2] * 42 / dl, -d[1] * 42 / dl
                            local ax0, ay0 = R.px + best.x * NV.STEP, R.py + best.y * NV.STEP
                            local bx0, by0 = R.px + nx * NV.STEP, R.py + ny * NV.STEP
                            w = true
                            for _, off in ipairs({ 0, 1, -1 }) do
                                R.traces = R.traces + 1
                                budget = budget - 1
                                local ok2, hit2 = line_blocked(ksl, p,
                                    ax0 + pox * off, ay0 + poy * off, best.z + 55,
                                    bx0 + pox * off, by0 + poy * off, zb + 55)
                                if not (ok2 and not hit2) then
                                    w = false
                                    -- the centre line is clear, only a side line hits: maybe
                                    -- a narrow passage (NV.slide_step)
                                    if off ~= 0 and not diag then R.eside[ekey] = true end
                                    break
                                end
                            end
                            -- open on channel 0, but the character may still run into an
                            -- INVISIBLE wall there (the study's ledge: ch0 blind, the pawn
                            -- profile hit at 28). The pawn-profile trace as a high COST,
                            -- not a wall: as a wall it also shut a way the character can
                            -- walk (the chest in the study became "not reachable").
                            -- (a step-in route: a wall, also diagonally, unless a person
                            -- stands there -- NV.stepin_person_at)
                            if w and (not diag or R.stepin) then
                                R.traces = R.traces + 1
                                budget = budget - 1
                                local okp, hitp = line_blocked(ksl, p, ax0, ay0, best.z + 55, bx0, by0, zb + 55, NV_TRACE)
                                if okp and hitp then
                                    if diag or (R.stepin and not NV.stepin_person_at(R, ax0, ay0, bx0, by0, best.z)) then
                                        w = false
                                    else
                                        w = "soft"
                                    end
                                elseif not diag and not R.stepin then
                                    -- THE BODY'S SIDES on the capsule's own profile too
                                    -- (2026-11-16): channel 0's side lines don't see invisible
                                    -- walls, so the centre line alone passed gaps between two
                                    -- volumes narrower than the character (one under the Maiya
                                    -- bridge's east side, ~72 in the level file). Lines 40 to
                                    -- each side (the capsule's radius is ~42: CHPROBE hits at
                                    -- 28-32 from 12 out): both hit -> narrower than the body,
                                    -- no step; one -> it grazes a wall, "soft" (the routes keep
                                    -- off invisible walls as off visible ones). Not on step-in
                                    -- routes (the inn's narrow side stairs, centre line only).
                                    local sides = 0
                                    for _, off in ipairs({ 1, -1 }) do
                                        R.traces = R.traces + 1
                                        budget = budget - 1
                                        local oks, hits = line_blocked(ksl, p,
                                            ax0 + pox * off * 40 / 42, ay0 + poy * off * 40 / 42, best.z + 55,
                                            bx0 + pox * off * 40 / 42, by0 + poy * off * 40 / 42, zb + 55, NV_TRACE)
                                        if oks and hits then sides = sides + 1 end
                                    end
                                    if sides == 2 then
                                        w = false
                                        R.ntight = (R.ntight or 0) + 1
                                    elseif sides == 1 then
                                        w = "soft"
                                    end
                                end
                            end
                            -- blocked: maybe by a SHUT DOOR -- the step crosses a
                            -- doorway plane within its width. Then it is a door edge
                            -- (w = the door's index): passable, but dearer, and the
                            -- walk stops there for E (nav_route_finish). Straight only.
                            if not w and R.doors and not diag then
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
                            if w == true and not diag then open4[d[1] .. "," .. d[2]] = true end
                            cand[#cand + 1] = { nx, ny, zb, nk, w, diag }
                        elseif not diag then
                            if R.eside[ekey] or R.eside[nk .. ">" .. best.k] then
                                local sw, so, sz, used2 = NV.slide_step(R, ksl, p, best, d, nx, ny)
                                budget = budget - used2
                                if sw then
                                    cand[#cand + 1] = { nx, ny, sz, key3(nx, ny, zlayer(R, sz)), sw, false, so }
                                end
                            end
                            blocked = blocked + 1
                        end
                    elseif not diag then
                        blocked = blocked + 1          -- a drop or no floor: also a "wall"
                    end
                end
            end
            -- leaving a cell next to walls costs more: open ways keep off the walls
            -- (the routes hugged them, and the walker clipped the corners)
            local pen = 0.4 * blocked
            -- where this cell's walker stands (a slid cell: its slid point)
            local ax0, ay0 = R.px + best.x * NV.STEP + (best.ox or 0), R.py + best.y * NV.STEP + (best.oy or 0)
            for _, c in ipairs(cand) do
                local nk = c[4]
                local so = c[7]
                local bx = R.px + c[1] * NV.STEP + (so and so[1] or 0)
                local by = R.py + c[2] * NV.STEP + (so and so[2] or 0)
                local pre = so and so.pre
                -- PEOPLE IN THE WAY: a step through someone's circle is out (NV.person_on)
                local who = nil
                if R.people and not R.closed[nk] then
                    if pre then
                        who = NV.person_on(R.people, ax0, ay0, best.z, pre.x, pre.y)
                            or NV.person_on(R.people, pre.x, pre.y, best.z, bx, by)
                    else
                        who = NV.person_on(R.people, ax0, ay0, best.z, bx, by)
                    end
                    if who then R.ppl_hit = (R.ppl_hit or 0) + 1 end
                end
                -- a wall a walk got stuck at (NV.walls): no step across it
                local walled = false
                if R.walls and #R.walls > 0 and not R.closed[nk] and not who then
                    if pre then
                        walled = NV.walls_cross(R.walls, ax0, ay0, pre.x, pre.y, best.z)
                            or NV.walls_cross(R.walls, pre.x, pre.y, bx, by, best.z)
                    else
                        walled = NV.walls_cross(R.walls, ax0, ay0, bx, by, best.z)
                    end
                    if walled then R.wall_hit = (R.wall_hit or 0) + 1 end
                end
                if not R.closed[nk] and not who and not walled then
                    local isdoor = type(c[5]) == "number"
                    -- a door costs a stop and an E press: open ways up to 25 cells longer
                    -- win (at +6 the router took a door to a target it also reached openly);
                    -- a step the pawn trace calls blocked ("soft") costs 8 -- 30 once a walk
                    -- got stuck in this area (NV.walls), except within 250 of the target
                    local softc = 8
                    if c[5] == "soft" and R.walls and #R.walls > 0
                        and (bx - R.ox) ^ 2 + (by - R.oy) ^ 2 > 250 * 250 then
                        softc = 30
                    end
                    local step = isdoor and 25 or (c[5] == "soft" and softc or (c[6] and 1.41421 or 1))
                    -- a slid step: only where the grid has no way (narrow passages)
                    local slid = so and (so[1] ~= 0 or so[2] ~= 0)
                    if slid then step = step + 1 end
                    local ng = best.g + step + pen
                    if ng < (R.gbest[nk] or 1e9) then
                        R.gbest[nk] = ng
                        R.came[nk] = best
                        R.via[nk] = isdoor and c[5] or nil
                        -- octile distance, weighted a little: keeps the search focused now
                        -- that steps near walls cost more than 1
                        local hx, hy = math.abs(R.gx - c[1]), math.abs(R.gy - c[2])
                        local h = math.max(hx, hy) + 0.41421 * math.min(hx, hy)
                        NV.heap_push(R.open, { x = c[1], y = c[2], z = c[3], k = nk, g = ng, f = ng + 1.2 * h,
                            ox = slid and so[1] or nil, oy = slid and so[2] or nil, pre = so and so.pre or nil })
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
    -- Up to 8000 traces per tick, but at most 40 ms of it: this runs on the game thread
    -- (the pump, every 100 ms), and you stand waiting meanwhile -- the picture stutters, the
    -- sound doesn't. Until 2026-11-16 8 ms: the 105-cell route on the Maiya path waited
    -- 2.8 s and computed for 0.24 s of it; now ~50000 traces a second (a whole-area search
    -- takes up to 300000). Through UE4SS's own trace call 110 traces took ~10 ms; the
    -- shim's are ~9 times cheaper.
    local t0 = os.clock()
    local res, node = NV.route_slice(R, 8000, 30000, t0 + 0.040)
    R.cpu, R.ticks = (R.cpu or 0) + (os.clock() - t0), (R.ticks or 0) + 1
    local bc = NV.bg_cache   -- (its traces stay the spot's while the search runs)
    if bc and bc.g == R.gcache then bc.t = os.clock() end
    if res == "found" then nav_route_finish(node); return end
    if res == "fail" then
        -- out of cells in the box, or out of traces ("cap": 7000 ran out after 788 cells
        -- on the way back to the study's chest 3): a bigger box with more traces, then
        -- the whole area, then the shifted grid
        -- (not when people stood at a step-in target's entrance, NV.stepin_leg: the search
        -- without people follows at once and names them)
        local W = (node == "box" or node == "cap") and not R.goal_ppl and (NV.route_widen(R) or NV.route_shift(R, node))
        if W then
            if W.whole and not R.whole and W.mode == "walk" then
                W.saidlong = os.clock()
                speak(tr("Searching the whole area"))
            end
            NV.route = W
            return
        end
        -- the whole area ran out of traces, not of cells: nothing proven (nav_route_finish)
        R.capped = (node == "cap" and not R.goal_ppl) or nil
        nav_route_finish(nil); return
    end
    -- a long search says so, and again every 10 s
    local now = os.clock()
    if not R.saidlong then
        if now - R.started > 2 then
            R.saidlong = now
            speak(tr("Still routing"))
        end
    elseif now - R.saidlong > 10 then
        R.saidlong = now
        speak(tr("Still routing"))
    end
end

local function nav_route_begin(mode, ox, oy, oz)
    local p = get_player_obj(); if not p then speak(tr("No player")); return end
    local px, py, pz = read_actor_pos(p); if not px then speak(tr("No position")); return end
    oz = oz or pz
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local samelevel = math.abs(oz - pz) <= 200
    -- (a terrace 170 up is no "same level", see NV.FLOOR_SAME)
    if samelevel and ksl and NV.level_link(ksl, p, px, py, pz, ox, oy, oz) == false then samelevel = false end
    local gx = math.floor((ox - px) / NV.STEP + 0.5)
    local gy = math.floor((oy - py) / NV.STEP + 0.5)
    -- a step-in target (a shop without a keeper): the search must check the last leg in
    -- (NV.stepin_leg), so no "close by" shortcut
    local stepin = false
    if mode == "walk" then
        stepin = (NV.goal and NV.goal.stepin and NV.goal.x == ox and NV.goal.y == oy) and true or false
    else
        local t = nav_target()
        if t and NV.is_stepin(t) then
            local tx, ty = NV.tpos(t)
            stepin = (tx == ox and ty == oy)
        end
    end
    if gx == 0 and gy == 0 and samelevel and not stepin then
        if mode == "walk" then
            nav_walk_begin_path({ { x = px, y = py }, { x = ox, y = oy } }, tr("close by"))
        else
            speak(tr("Right here"))
        end
        return
    end
    -- the people around (NV.people_scan): the route keeps away from them -- except the
    -- one at the target when the target may be a person (not a door or an exit)
    local gcat = NV.goal and NV.goal.cat
    local topeople = not (gcat == "door" or gcat == "building" or gcat == "exit" or gcat == "through")
    local okp, people = pcall(NV.people_scan, px, py, pz, topeople and ox or nil, topeople and oy or nil)
    if not okp then people = nil end
    -- direct-line shortcut (same level only): if a BODY-WIDTH corridor (3 lines,
    -- center +-42) to the target is clear, skip the search entirely
    local walls = NV.walls_here()
    if ksl and samelevel and NV.corridor_clear(ksl, p, px, py, pz, ox, oy)
        and not NV.person_on(people, px, py, pz, ox, oy) and not NV.walls_cross(walls, px, py, ox, oy, pz) then
        if mode == "walk" then
            nav_walk_begin_path({ { x = px, y = py }, { x = ox, y = oy } }, tr("direct"))
        else
            local d = math.floor(math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2) + 0.5)
            speak(trf("Path: straight ahead, %d", d))
        end
        return
    end
    NV.route = NV.route_job(mode, ox, oy, oz, px, py, pz)
    NV.route.people = people
    NV.route.stepin = stepin
    do   -- the last leg to a chest or a door is traced (NV.goal_leg_ok); a walk decided at its start
        local leg
        if mode == "walk" then
            local g = NV.goal
            if g and g.x == ox and g.y == oy then
                leg = g.chest or ((g.cat == "door" or g.cat == "building") and "door")
                    or (g.cat == "spot" and "spot") or nil
            end
        else
            local t = nav_target()
            leg = t and NV.leg_target(t, t.walkcat or t.cat)
        end
        NV.route.legchk = (not stepin and leg) or false
    end
    if stepin then
        NV.route.groundch = NV_TRACE
    else
        -- the background checks' traces from this very spot (NV.share_traces)
        local oks, shared = pcall(NV.share_traces, NV.route, px, py, pz)
        if oks and shared then log("ROUTE takes over the traces of the checks from here") end
    end
    if people then log(string.format("ROUTE keeps away from %d people", #people)) end
    if #walls > 0 then
        log(string.format("ROUTE keeps off %d learned walls", #walls))
        -- a walk got stuck in this area: its soft steps cost 30 now, yet a small box can
        -- hold nothing but such steps while the way round runs outside it -- the whole
        -- area at once (2026-11-16, Maiya path: three more bumps along the same invisible
        -- wall, a box each, before the +40 box found the way round)
        NV.route = NV.route_widen(NV.route, true) or NV.route
    end
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
    if not r or r.area ~= M.map_id() then return nil end
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
        -- maybe behind a house door after all (doorway plane, as after a failed walk).
        -- Doors too: a door inside a room (behind the academy office door) is reached
        -- through the room's door. A door is never "inside" its own plane (along > 60).
        local door = nil
        if job.cat ~= "exit" then
            local okd, d = pcall(M.house_door_for, job.tx, job.ty, job.tz, job.px, job.py, job.pz, false, true,
                NV.target_in_house(job.t))
            if okd and d then door = d end
        end
        NV.noroute[job.key] = { x = job.px, y = job.py, area = job.area, door = door }
    end
    log(string.format("REACH %s %s d=%.0f dz=%.0f: %s (%s, traces=%d, pops=%d, slides=%d, %.1fs)", tostring(job.cat),
        tostring(job.name or job.key), math.sqrt((job.tx - job.px) ^ 2 + (job.ty - job.py) ^ 2), job.tz - job.pz,
        ok and "ok" or "NOT reachable", how or "route", job.R and job.R.traces or 0, job.R and job.R.pops or 0,
        job.R and job.R.slides or 0, job.R and (os.clock() - job.R.started) or 0))
end
-- ONE SPOT, ONE SET OF TRACES (2026-11-16, user: make the walker faster). The ground and
-- wall results of a search depend on its start (the grid is anchored there), not on the
-- target, the people (kept away from by NV.person_on, outside the caches) or the learned
-- walls (NV.walls_cross, outside too). So every search from the very same spot -- the
-- background checks of the list, and the walk you start right after picking a target --
-- shares them (NV.bg_cache): the focused target is checked first (NV.bg_front), and the
-- walk then finds its cells traced already. "The very same spot": your position to the
-- unit (you haven't moved), within 60 s of the last search there. Not for step-in routes
-- (their floors come from another trace), and not within 150 of a door: one opened with
-- E since (E needs you within ~35) would still count as shut. (Until 2026-11-16 only the
-- background checks shared, and the walk never: "a door just opened would still look
-- shut".) Returns true when R took the traces over; else R's own become the spot's.
NV.share_traces = function(R, px, py, pz)
    for _, dd in ipairs(R.doors or {}) do
        if dd.cx and (dd.cx - px) ^ 2 + (dd.cy - py) ^ 2 < 150 * 150 then return false end
    end
    local c = NV.bg_cache
    if c and c.x == px and c.y == py and c.z == pz and os.clock() - c.t < 60 then
        R.gcache, R.ecache = c.g, c.e
        R.eside, R.gcache2 = c.s or R.eside, c.g2 or R.gcache2
        c.t = os.clock()
        return true
    end
    NV.bg_cache = { x = px, y = py, z = pz, t = os.clock(), g = R.gcache, e = R.ecache, s = R.eside, g2 = R.gcache2 }
    return false
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
                  px = px, py = py, pz = pz, area = M.map_id(), t = t }
    if t.cat ~= "building" then
        -- behind a door: the walk leads there via the door. Standing just outside the
        -- target's door, its shut door failed the search: Russell "not reachable" at the
        -- library door (2026-11-14)
        local okd, door, how, pdoor = pcall(M.house_door_for, tx, ty, tz, px, py, pz, nil, nil, NV.target_in_house(t))
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
    local stepin = NV.is_stepin(t)
    if math.abs(tz - pz) <= 200 and NV.level_link(ksl, p, px, py, pz, tx, ty, tz) ~= false and ((gx == 0 and gy == 0 and not stepin)
        or (NV.corridor_clear(ksl, p, px, py, pz, tx, ty) and not NV.walls_cross(NV.walls_here(), px, py, tx, ty, pz))) then
        NV.bg_record(job, true, "straight")
        return nil
    end
    job.R = NV.route_job("bg", tx, ty, tz, px, py, pz)
    job.R.stepin = stepin
    job.R.legchk = not stepin and NV.leg_target(t, t.walkcat or t.cat)
    job.R.maxt = 60          -- slower slices: same trace budget, more time
    -- checks from the same spot share their ground / wall caches with each other and with
    -- the walk (NV.share_traces; NV.bg_step keeps them fresh while one runs -- a
    -- whole-area check takes long, and the next one needs the same cells)
    -- (a step-in check measures its floors by another trace: no sharing)
    if stepin then
        job.R.groundch = NV_TRACE
    else
        NV.share_traces(job.R, px, py, pz)
    end
    -- walls learned here: the whole area at once, as for the walk (nav_route_begin)
    if #job.R.walls > 0 then job.R = NV.route_widen(job.R, true) or job.R end
    return job
end
NV.bg_step = function()      -- nav_tick, only while no walk or route runs
    if nav_walking or NV.route or world_susp or M.explore_now == false or M.menu_now then return end
    local job = NV.bg
    if job and job.area ~= M.map_id() then NV.bg, NV.bgq, job = nil, {}, nil end   -- area changed
    if not job then
        if #NV.bgq == 0 then return end
        local p = get_player_obj(); if not p then return end
        local px, py, pz = read_actor_pos(p); if not px then return end
        local bx = NV.bg_boxed   -- boxed in here: no checks until we stand elsewhere
        if bx then
            if math.sqrt((px - bx.x) ^ 2 + (py - bx.y) ^ 2) < 40 then return end
            NV.bg_boxed = nil
        end
        for _ = 1, 3 do      -- a few set-ups per tick (each costs a house test + 3 traces)
            local t = table.remove(NV.bgq, 1)
            if not t then return end
            job = NV.bg_new(t, p, px, py, pz)
            if job then break end
        end
        if not job then return end
        NV.bg = job
    end
    -- its clock counts its own work only: while a walk, a route, a menu or a battle runs
    -- it waits (2026-11-16: a chest's check waited through two walks and a battle, its
    -- 76 s ran out meanwhile, and it said "not reachable" -- the walk found the way)
    local now = os.clock()
    if job.R.ran and now - job.R.ran > 0.5 then job.R.started = job.R.started + (now - job.R.ran) end
    -- quiet background work: traces for at most 4 ms per tick -- 10 ms for the target you
    -- have selected: the walk you may start next takes its traces over (NV.share_traces)
    local focused = job.t ~= nil and job.t == NV.list[NV.idx]
    local res, why = NV.route_slice(job.R, focused and 2000 or 800, focused and 8000 or 3000,
        now + (focused and 0.010 or 0.004))
    job.R.ran = os.clock()
    local bc = NV.bg_cache
    if bc and bc.g == job.R.gcache then bc.t = job.R.ran end
    if res == "fail" and (why == "box" or why == "cap") then
        -- the same tries as a walk: wider boxes, the whole area, then the half-shifted grid
        local W = NV.route_widen(job.R) or NV.route_shift(job.R, why)
        if W then job.R = W; return end
    end
    if res then
        NV.bg = nil
        if res == "fail" and why == "cap" and job.R.whole then
            -- the whole area ran out of traces, not of cells: nothing proven. No verdict;
            -- the next list build checks it again
            log(string.format("REACH %s %s: search limit reached (traces=%d, pops=%d, %.1fs), no verdict",
                tostring(job.cat), tostring(job.name or job.key), job.R.traces or 0, job.R.pops or 0,
                os.clock() - job.R.started))
            return
        end
        if res == "fail" and (job.R.pops or 0) < NV.TRAIL_POCKET then
            -- a pocket where you stand: again from your trail, as the walk would go
            -- (NV.trail_retry)
            local W = NV.trail_retry(job.R)
            if W then
                job.R = W
                NV.bg = job
                return
            end
        end
        if res == "fail" and (job.R.pops or 0) <= 3 and (job.R.pops0 or 0) <= 3 then
            -- the search died where we stand (a corner): nothing about the target. Not
            -- "not reachable" -- queue it again and wait until we stand elsewhere
            log(string.format("REACH %s %s: boxed in here (pops=%d), later", tostring(job.cat), tostring(job.name),
                job.R.pops or 0))
            if job.t then NV.bgq[#NV.bgq + 1] = job.t end
            NV.bg_boxed = { x = job.px, y = job.py }
            return
        end
        local door = (res == "found") and NV.route_first_door(job.R, why) or nil
        -- (no cell with a clear last leg, but the search got near: reachable, as the walk
        -- goes there -- nav_route_finish)
        local nearleg = res == "fail" and job.R.legbest ~= nil and job.R.legchk ~= "spot"
        NV.bg_record(job, res == "found" or nearleg, (nearleg and "no clear last leg, " or "")
            .. (job.R.whole and "whole area" or (job.R.pad > 9 and "wide route" or "route"))
            .. (job.R.shifted and ", shifted grid" or "")
            .. (job.R.trailpre and string.format(", from your trail %d back", NV.TRAIL_BACK[job.R.trail_n] or 0) or "")
            .. (door and (", door " .. tostring(door.name)) or ""), door ~= nil)
    end
end

local function nav_info()
    NV.ctrlkey_t = os.clock()
    -- on the world map: the route to the place Page Up/Down picked (M.wm_route_say)
    if M.WM and M.WM.open and M.explore_now ~= true then pcall(M.wm_route_say); return end
    if #NV.list > 0 and NV.list_stale() and NV.list_refresh() then   -- after a teleport
        if #NV.list == 0 then speak(tr("Targets changed, none here")); return end
        nav_announce(trn("Targets changed. %s, %d target. ", "Targets changed. %s, %d targets. ", #NV.list, M.cat_word(NAV_CLASSES[NV.cat].name), #NV.list))
        return
    end
    local t = nav_target()
    if not t then speak(tr("No target selected. Home and end pick a category, page up and down a target.")); return end
    local p = get_player_obj(); if not p then speak(tr("No player")); return end
    local px, py, pz = read_actor_pos(p)
    local ox, oy, oz = NV.tpos(t)
    if not (px and ox) then speak(tr("Target lost")); return end
    oz = oz or pz
    local dx, dy = ox - px, oy - py
    local d = math.floor(math.sqrt(dx * dx + dy * dy) + 0.5)
    local lvl = tr("same level")
    local okw, w = pcall(NV.level_word, p, px, py, pz, ox, oy, oz)
    if okw and w then lvl = tr(w) end
    local base = trf("%s %d of %d, %s, %d, %s. ", M.cat_word(t.cat), NV.idx, #NV.list, nav_dir(dx, dy), d, lvl)
    local pts = nav_find_path(p, px, py, pz, ox, oy, oz)
    if pts then
        local desc, total = nav_describe_path(pts)
        speak(base .. trf("Path: %s. Total %d.", desc, total))
    else
        speak(base .. tr("Routing."))
        nav_route_begin("info", ox, oy, oz)
    end
end

-- The game can miss the walker's key release: an arrow let go just as a battle, a scene
-- or a menu takes over stays down for the game, and afterwards the character walks on by
-- itself (2026-11-16: after a random encounter it marched off alone, and every new walk
-- said "Walk interrupted" -- its "down" against the stuck "up" made no input at all).
-- So once the field is back, each arrow let go then gets a second key-up. A lone key-up
-- for a key that is up does nothing; an arrow the walker holds again is skipped.
M.ARROW_VK = { UP_ARROW = 0x26, DOWN_ARROW = 0x28, LEFT_ARROW = 0x25, RIGHT_ARROW = 0x27 }
M.arrows_up = function(keys, why)
    if not (shim and shim.KeyEvent) then return end
    local cur = (nav_walking and NV.held) or (NV.face and NV.face.held) or {}
    local sent = {}
    for k in pairs(keys) do
        if M.ARROW_VK[k] and not cur[k] then
            pcall(function() shim.KeyEvent(M.ARROW_VK[k], false) end)
            sent[#sent + 1] = k
        end
    end
    table.sort(sent)
    if #sent > 0 then log(string.format("NAVWALK key-up again (%s): %s", why, table.concat(sent, " "))) end
end
-- remember the arrows let go now (any number of key sets; nil ones are skipped)
M.unstick_arm = function(...)
    local keys = {}
    for i = 1, select("#", ...) do
        local h = select(i, ...)
        if type(h) == "table" then for k in pairs(h) do keys[k] = true end end
    end
    if next(keys) then NV.unstick = { keys = keys, live = nil, n = 0 } end
end
-- nav_drive, while the field is live: 0.3 s after it came back, then once more 1 s later
M.unstick_step = function()
    local u = NV.unstick
    if not u then return end
    local now = os.clock()
    if not u.live then u.live = now; return end
    if now - u.live < 0.3 then return end
    local inp = -1
    local p = get_player_obj()
    if p then pcall(function() local iv = p:GetLastMovementInputVector(); inp = math.sqrt(iv.X * iv.X + iv.Y * iv.Y) end) end
    u.n = u.n + 1
    M.arrows_up(u.keys, string.format("field back, try %d, input %.2f", u.n, inp))
    if u.n >= 2 then NV.unstick = nil else u.live = now + 0.7 end
end

-- Stuck on the way (nav_walk_watch): is there a wall straight ahead that the route didn't
-- see? The pawn trace (the player's own collision) toward the waypoint hits within 90:
-- then a wall 200 long across that direction, just behind the surface, goes to NV.walls
-- and the re-route keeps off it. Not at the target itself (its own collision stops you
-- there: a hit within 120 of it) and not at a person (people move). (Until 2026-11-17
-- nothing was learned within 250 of the target: a fence 150 before a chest was run into
-- 20 times, the same route each time.)
NV.learn_wall = function(p, px, py, pz)
    local wp = NV.path and NV.path[NV.wp]
    if not wp then return false end
    local g = NV.goal
    -- (a step-in shop has its own end: "entrance not reached")
    if g and g.stepin and (px - g.x) ^ 2 + (py - g.y) ^ 2 < 250 * 250 then return false end
    local vx, vy = wp.x - px, wp.y - py
    local vl = math.sqrt(vx * vx + vy * vy)
    if vl < 1 then return false end
    vx, vy = vx / vl, vy / vl
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not ksl then return false end
    local ok, hit, info = line_blocked(ksl, p, px, py, pz + 30, px + vx * 90, py + vy * 90, pz + 30, NV_TRACE)
    if not (ok and hit) then return false end
    local d = 40
    pcall(function() if type(info.Distance) == "number" then d = info.Distance end end)
    local cx, cy = px + vx * d, py + vy * d
    if g and (cx - g.x) ^ 2 + (cy - g.y) ^ 2 < 120 * 120 then return false end
    local okp, people = pcall(NV.people_scan, px, py, pz)
    if okp and people then
        for _, q in ipairs(people) do
            if math.abs(q.z - pz) < 250 and (q.x - cx) ^ 2 + (q.y - cy) ^ 2 < 120 * 120 then
                log(string.format("NAVWALK stuck at a person near (%.0f,%.0f): no wall learned", cx, cy))
                return false, q   -- (the person: nav_walk_watch waits for them to walk on)
            end
        end
    end
    local wx, wy = cx + vx * 15, cy + vy * 15
    local ux, uy = -vy, vx
    if not NV.wall_add(wx - ux * 100, wy - uy * 100, wx + ux * 100, wy + uy * 100, pz) then return false end
    log(string.format("NAVWALK learned a wall at (%.0f,%.0f) across (%.2f,%.2f), pawn hit at %.0f; %d in this area",
        wx, wy, vx, vy, d, #NV.walls.list))
    return true
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
NV.face_goal = function(retry)
    local g = NV.goal
    if not g or g.cat == "exit" or g.cat == "door" or g.cat == "building" or g.cat == "event" then return end
    local p = get_player_obj(); if not p then return end
    local px, py = read_actor_pos(p); if not px then return end
    local tx, ty = g.x, g.y
    local t = nav_target()
    if g.face then
        -- arrived at another side of a chest / hidden item (NV.iapproach): face the item,
        -- then nav_tick looks for its prompt again
        tx, ty = g.face.x, g.face.y
        local ia = NV.iapproach
        if ia then ia.px, ia.py, ia.next = px, py, os.clock() + 1.0 end
        -- ...or of a person (NV.person_spot): the steps until the game picks them, again
        local gp = g.person
        if gp and not retry then
            NV.approach = { addr = gp.addr, tries = 0, next = os.clock() + 0.7, x = tx, y = ty, z = gp.z,
                name = gp.name, spots = gp.spots, t0 = os.clock(), px = px, py = py }
            if M.talk_pick == gp.addr then
                log("NAVWALK in talk range (on arrival)")
                NV.approach = nil
                return
            end
        end
        t = nil
    elseif not retry and t and g.key and NV.tkey(t) == g.key and t.actor
        and class_name_of(t.actor) == "TreasureBoxBP_C" then
        -- a chest or a hidden item (its chest): its "Öffnen, E" / "Untersuchen, E" prompt
        -- must show, which depends on the side you stand at -- the hidden item behind a
        -- ledge in Atlasdam said "Arrived" 138 away without it (2026-11-15). nav_tick
        -- waits for the prompt and else tries other sides (NV.iapproach).
        local a = 0
        pcall(function() a = t.actor:GetAddress() end)
        local okc, opened = pcall(M.chest_state, { addr = a })
        if a ~= 0 and not (okc and opened) then
            local x, y, z = read_actor_pos(t.actor)
            NV.iapproach = { addr = a, tries = 0, next = os.clock() + 1.0, x = x or tx, y = y or ty,
                z = z or g.z, px = px, py = py, spots = {} }
        end
    end
    if t and g.key and NV.tkey(t) == g.key then   -- a wandering NPC: where it is now
        local x, y = NV.tpos(t)
        if x then tx, ty = x, y end
        -- a person (or the save point's book): keep stepping closer until the game
        -- picks them as the one to talk to (nav_tick, NV.approach). The walker stops
        -- up to 170 away; the talk range is shorter -- the user had to hunt for an
        -- NPC's hitbox after "Arrived" (2026-11-14)
        if not retry and t.actor and class_name_of(t.actor) == "KSFieldNPCCharacter_C" then
            local a = 0
            pcall(function() a = t.actor:GetAddress() end)
            -- its name (nil for the save point's book): another actor of the same person
            -- picked where it stands counts as reached (nav_tick)
            local nm
            pcall(function() nm = shim.NpcName(a) end)
            if nm == "" or nm == "???" then nm = nil end
            if a ~= 0 then
                local _, _, z = read_actor_pos(t.actor)
                NV.approach = { addr = a, tries = 0, next = os.clock() + 0.7, x = tx, y = ty, z = z, name = nm,
                    spots = {}, t0 = os.clock(), px = px, py = py }
                -- already the game's pick (you face them in range): no step -- it could only
                -- lose the pick
                if M.talk_pick == a then
                    log("NAVWALK in talk range (on arrival)")
                    NV.approach = nil
                    return
                end
            end
        end
    end
    local dx, dy = tx - px, ty - py
    local dl = math.sqrt(dx * dx + dy * dy)
    if dl < 25 then return end
    -- 8 directions like the walk itself: a target up-left needs up AND left (one axis
    -- missed the headmaster at "up left, 143"; a tap up then gave "Path action")
    local nx, ny = dx / dl, dy / dl
    local u, d, r, l = nx > 0.38, nx < -0.38, ny > 0.38, ny < -0.38
    local dur = 0.18
    -- Odd retries (NV.approach): when the last step got no closer, a step SIDEWAYS
    -- instead -- a counter between you and the person stops the straight step, and the
    -- game picks them only when you stand nearly square in front. Mercedes behind the
    -- library counter: picked 26 to the side at 161, not 48 to the side at 166
    -- (2026-11-14). The next retry faces them again.
    local ap = NV.approach
    if type(retry) == "number" and retry % 2 == 1 and ap and ap.lastd and dl > ap.lastd - 5 then
        local side
        if math.abs(dx) >= math.abs(dy) then
            u, d, r, l, side = false, false, dy > 12, dy < -12, math.abs(dy)
        else
            u, d, r, l, side = dx > 12, dx < -12, false, false, math.abs(dx)
        end
        if not (u or d or r or l) then return end
        dur = (side < 60) and 0.12 or 0.18
    end
    if ap then ap.lastd = dl end
    log(string.format("NAVWALK face target d=%.0f keys=%s%s%s%s", dl, u and "U" or "", d and "D" or "",
        l and "L" or "", r and "R" or ""))
    M.face_t = os.clock()   -- bump_step: this tap is ours, no wall thud
    NV.face = { till = os.clock() + dur, u = u, d = d, l = l, r = r,
        held = { UP_ARROW = u or nil, DOWN_ARROW = d or nil, LEFT_ARROW = l or nil, RIGHT_ARROW = r or nil } }
end

-- The prompt on screen is the chest's / hidden item's own (M.poll_action_popup keeps its
-- TargetActor)? Not a person's: a villager lying before a chest ("Untersuchen, E", "U-ugh")
-- was taken for the chest's prompt and the walk ended at him (user 2026-11-23); nor a
-- door's. The item itself, or anything else (a hidden item's access point): yes; no
-- target readable: yes, as before.
NV.prompt_is_item = function(ia)
    local cls, a = M.popup_target_cls, M.popup_target_addr
    if not cls then return true end
    if ia and a == ia.addr then return true end
    return not (cls == "KSFieldNPCCharacter_C" or cls == "HouseEnterTriggerBP_C" or cls == "LevelTrigger_C")
end

-- Another side of a chest / hidden item to stand at (NV.iapproach): of 16 spots around
-- it (8 directions, 90 and 130 away) one with ground at about the item's height and a
-- clear line from there to just short of it at waist height (the capsule's own trace,
-- so ledges and invisible walls count), nearest to you, not where you stand and not
-- tried before. nil: none.
-- With a person picked at the item (ia.avoid: E went to them, not to the item), not where
-- they would stand nearly square in front of you as you face the item -- within 20
-- degrees, closer than 220: the game picks a person only then (Mercedes: 26 to the side
-- at 161 picked, 48 at 166 -- 16 degrees -- not) -- nor right beside them. When every
-- side has them in front (a villager lying right by a hidden item, 2026-11-23: "no other
-- side found" each time), the side where they stand farthest off your line of sight
-- (second value true). Third value, with none at all: why, for the log.
NV.item_spot = function(ia, p, px, py)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not (ksl and p and px) then return nil end
    local best, bestd = nil, 1e9
    local alt, altc = nil, 2
    local nn = { tried = 0, near = 0, ground = 0, line = 0 }
    for k = 0, 7 do
        local ang = k * math.pi / 4
        for _, r in ipairs({ 90, 130 }) do
            local cx, cy = ia.x + r * math.cos(ang), ia.y + r * math.sin(ang)
            local d = math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2)
            local fresh = d > 70
            for _, s in ipairs(ia.spots) do
                if math.sqrt((cx - s.x) ^ 2 + (cy - s.y) ^ 2) < 60 then fresh = false end
            end
            if not fresh then nn.tried = nn.tried + 1 end
            local fc   -- (the person nearly square in front here: the cosine)
            if fresh and ia.avoid then
                local fx, fy = ia.x - cx, ia.y - cy
                local nx, ny = ia.avoid.x - cx, ia.avoid.y - cy
                local fl, nl = math.sqrt(fx * fx + fy * fy), math.sqrt(nx * nx + ny * ny)
                if nl < 70 then
                    fresh = false
                    nn.near = nn.near + 1
                elseif nl < 220 and fl > 1 then
                    local c = (fx * nx + fy * ny) / (fl * nl)
                    if c > 0.94 then fc = c end
                end
            end
            if fresh and (fc or d < bestd) then
                local ok, hit, oh = line_blocked(ksl, p, cx, cy, ia.z + 160, cx, cy, ia.z - 200)
                local gz
                if ok and hit then
                    local dist
                    pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
                    gz = dist and (ia.z + 160 - dist)
                end
                if gz and math.abs(gz - ia.z) < 120 then
                    local ex, ey = ia.x + (cx - ia.x) / r * 30, ia.y + (cy - ia.y) / r * 30
                    local ok2, hit2 = line_blocked(ksl, p, cx, cy, gz + 50, ex, ey, gz + 50, NV_TRACE)
                    if ok2 and not hit2 then
                        local spot = { x = cx, y = cy, z = gz + 90 }
                        if fc then
                            if fc < altc then alt, altc = spot, fc end
                        else
                            best, bestd = spot, d
                        end
                    else
                        nn.line = nn.line + 1
                    end
                else
                    nn.ground = nn.ground + 1
                end
            end
        end
    end
    if best then return best, false end
    if alt then return alt, true end
    return nil, false, string.format("tried %d, by the person %d, no ground %d, line blocked %d",
        nn.tried, nn.near, nn.ground, nn.line)
end

-- Another spot to talk to a person from (NV.approach, after the steps there got no pick;
-- user 2026-11-21: Mercedes behind the library counter, "Arrived" 154 away, four steps,
-- no pick -- J then offered the follower's "Sich trennen"). Of 16 spots around them (8
-- directions, 100 and 140 away) one with ground at about their floor and a clear line at
-- head height to just short of them -- walls and shelves block it, a counter doesn't (the
-- game picks across one) -- nearest to you, not where you stand, not tried before. Each
-- lies on one of the walk's 8 directions from the person, so the step from there faces
-- them square: the game picks a person only when you stand nearly square in front
-- (Mercedes: picked 26 to the side at 161, not 48 to the side at 166, 2026-11-14).
NV.person_spot = function(a, p, px, py)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    if not (ksl and p and px and a.z) then return nil end
    local floor = a.z - 90   -- (an actor's position is its capsule's middle)
    local best, bestd = nil, 1e9
    for k = 0, 7 do
        local ang = k * math.pi / 4
        for _, r in ipairs({ 100, 140 }) do
            local cx, cy = a.x + r * math.cos(ang), a.y + r * math.sin(ang)
            local d = math.sqrt((cx - px) ^ 2 + (cy - py) ^ 2)
            local fresh = d > 70
            for _, s in ipairs(a.spots or {}) do
                if math.sqrt((cx - s.x) ^ 2 + (cy - s.y) ^ 2) < 60 then fresh = false end
            end
            if fresh and d < bestd then
                local ok, hit, oh = line_blocked(ksl, p, cx, cy, floor + 250, cx, cy, floor - 200)
                local gz
                if ok and hit then
                    local dist
                    pcall(function() if type(oh.Distance) == "number" then dist = oh.Distance end end)
                    gz = dist and (floor + 250 - dist)
                end
                if gz and math.abs(gz - floor) < 60 then
                    local ex, ey = a.x + (cx - a.x) / r * 40, a.y + (cy - a.y) / r * 40
                    local ok2, hit2 = line_blocked(ksl, p, cx, cy, gz + 150, ex, ey, gz + 150, NV_TRACE)
                    if ok2 and not hit2 then best, bestd = { x = cx, y = cy, z = gz + 90 }, d end
                end
            end
        end
    end
    return best
end
-- The steps at a person got no pick (nav_tick): walk to another side (NV.person_spot), up
-- to two, as for a chest -- only right after the steps, where they ended (not after a
-- menu in between, nor once you walked off: no walk you didn't ask for). Else say so;
-- it used to end without a word.
NV.approach_fail = function(a, noroute)
    local p = get_player_obj()
    local px, py
    if p then px, py = read_actor_pos(p) end
    local fresh = px and (noroute or (os.clock() - (a.t0 or -99) < 6 and a.px
        and math.sqrt((px - a.px) ^ 2 + (py - a.py) ^ 2) < 120))
    local spot
    a.spots = a.spots or {}
    if fresh and #a.spots < 2 then
        local oks, s = pcall(NV.person_spot, a, p, px, py)
        if oks then spot = s else log("NAVWALK person spot error: " .. tostring(s)) end
    end
    if spot then
        a.spots[#a.spots + 1] = spot
        log(string.format("NAVWALK person: no pick at (%.0f,%.0f), trying (%.0f,%.0f)", px, py, spot.x, spot.y))
        speak(noroute and tr("That side can't be reached, trying another side") or tr("Not in reach here, trying another side"))
        NV.goal = { x = spot.x, y = spot.y, z = spot.z, cat = "spot", key = NV.goal and NV.goal.key,
            face = { x = a.x, y = a.y }, person = { addr = a.addr, name = a.name, z = a.z, spots = a.spots } }
        NV.retries, NV.bestgoal, NV.noimprove = 0, nil, 0
        nav_route_begin("walk", spot.x, spot.y, spot.z)
    else
        speak(a.name and trf("%s is not within reach", a.name) or tr("Not within reach"))
    end
end
-- A route to another side found no way, or the walk there got stuck for good: the next
-- side -- a person's (NV.approach_fail, up to two in all) or a chest's (nav_tick's item
-- approach goes on from where you stand now). Never "not reachable" for the target: its
-- other sides may well be (2026-11-23, the cathedral: the side chosen for the former
-- Ardante knight lay between two pews, the aisle on his other side was free).
NV.spot_failed = function(g)
    local p = get_player_obj()
    local px, py
    if p then px, py = read_actor_pos(p) end
    log(string.format("NAVWALK side (%.0f,%.0f) not reachable", g.x, g.y))
    local gp = g.person
    if gp and g.face then
        NV.approach_fail({ addr = gp.addr, name = gp.name, z = gp.z, spots = gp.spots, x = g.face.x, y = g.face.y,
            t0 = os.clock(), px = px, py = py }, true)
        return
    end
    local ia = NV.iapproach
    if ia and px then
        ia.px, ia.py, ia.noroute, ia.next = px, py, true, os.clock() + 0.3
        return
    end
    speak(tr("That side can't be reached"))
end

-- STUCK: free ourselves instead of asking the player to step aside (user 2026-11-14).
-- Of 8 directions with a clear body-wide corridor 160 ahead, take the one nearest the
-- goal's (not straight back along the last escape); a 0.45 s step that way, then a new
-- route (nav_drive's unwedge phase). false: nothing clear around.
NV.escape_step = function(px, py, pz, gx, gy)
    local ksl = StaticFindObject("/Script/Engine.Default__KismetSystemLibrary")
    local p = get_player_obj()
    if not (ksl and p) then return false end
    local gdx, gdy = gx - px, gy - py
    local gl = math.sqrt(gdx * gdx + gdy * gdy)
    if gl > 1 then gdx, gdy = gdx / gl, gdy / gl end
    local best, bscore = nil, -9
    for i = 0, 7 do
        local ang = i * math.pi / 4
        local dx, dy = math.cos(ang), math.sin(ang)
        if NV.corridor_clear(ksl, p, px, py, pz, px + dx * 160, py + dy * 160)
            and not NV.walls_cross(NV.walls_here(), px, py, px + dx * 160, py + dy * 160, pz) then
            local score = dx * gdx + dy * gdy
            local le = NV.last_escape
            if le and dx * le[1] + dy * le[2] < -0.9 then score = score - 1 end
            if score > bscore then best, bscore = { dx, dy }, score end
        end
    end
    if not best then return false end
    NV.last_escape = best
    local u, d, r, l = best[1] > 0.38, best[1] < -0.38, best[2] > 0.38, best[2] < -0.38
    log(string.format("NAVWALK escape step %d dir=(%.2f,%.2f)", (NV.escapes or 0) + 1, best[1], best[2]))
    NV.unwedge = { till = os.clock() + 0.45, u = u, d = d, l = l, r = r, escape = true,
        held = { UP_ARROW = u or nil, DOWN_ARROW = d or nil, LEFT_ARROW = l or nil, RIGHT_ARROW = r or nil } }
    NV.path = nil
    nav_walking = true
    NV.started = os.clock()
    NV.prog = { t = os.clock(), x = px, y = py }
    return true
end

-- DOORS BY THEMSELVES (user request 2026-11-14): at a door on the route the walker
-- presses E itself -- only if the shown prompt belongs to a door (a house/room door or
-- a door exit), never at people -- waits for the prompt to go (the door opened) and
-- walks on. Two tries; then it hands over.
NV.AUTO_DOORS = true
NV.door_auto_start = function()
    if not (NV.AUTO_DOORS and shim and shim.KeyEvent) then return false end
    local cls
    pcall(function()
        local pw = M.kept(M.popup_widget_h)
        local ta = pw and pw.TargetActor
        if ta and ta:IsValid() then cls = class_name_of(ta) end
    end)
    if cls ~= "HouseEnterTriggerBP_C" and cls ~= "LevelTrigger_C" then
        log("DOORAUTO not a door prompt: " .. tostring(cls))
        return false
    end
    NV.door_auto = { phase = "press", t = os.clock(), tries = 0 }
    speak(tr("Opening the door"))
    return true
end
NV.door_auto_step = function()
    local d = NV.door_auto
    if not d then return end
    local now = os.clock()
    if world_susp or M.menu_now then        -- a scene or menu came up: let go
        pcall(function() shim.KeyEvent(0x45, false) end)
        NV.door_auto = nil
        return
    end
    if d.phase == "press" then
        pcall(function() shim.KeyEvent(0x45, true) end)
        d.phase, d.t = "release", now
    elseif d.phase == "release" then
        if now - d.t >= 0.08 then
            pcall(function() shim.KeyEvent(0x45, false) end)
            d.phase, d.t = "wait", now
        end
    elseif d.phase == "wait" then
        -- the prompt went away AND stays away 0.4 s: the door is open. A prompt that
        -- blinked off right after E once read as "opened" while the library door stayed
        -- shut (the route then said "A shut door on the way", 2026-11-14)
        if M.popup_said then d.gone = nil end
        if not M.popup_said and not d.gone then d.gone = now end
        if d.gone and now - d.gone >= 0.4 then
            log("DOORAUTO opened")
            NV.door_auto = nil
            NV.resume_walk = true
        elseif now - d.t > 1.5 and not d.gone then
            d.tries = d.tries + 1
            if d.tries >= 2 then
                log("DOORAUTO no luck")
                NV.door_auto = nil
                speak(tr("The door doesn't open. Press Enter yourself, then backspace again"))
            else
                d.phase = "press"
            end
        end
    end
end

-- Standing "at a door": the walk's door leg is skipped within this distance of the door
-- actor. The "Öffnen, E" prompt shows only ~35 in front of the door's center; with 250,
-- someone 240 away (at the Wachmann, outside the library) was told to press E there.
NV.ATDOOR = 120
-- ...but the door leg still runs from closer for a door that may be shut (the target's,
-- or the one of the house you are leaving): a route straight in fails at a shut door
-- only after a 10-second search, and "open it with E" there did nothing -- the prompt
-- needs the door's center. The Söldner in Flammhuld, 116 from House_B's door
-- (2026-11-16). Not within 60 (where the push ends), and not once the push found this
-- door open (NV.door_walked_on, 30 s).
NV.door_leg_near = function(key, dd)
    if dd <= 60 then return false end
    local w = NV.door_walked_on
    return not (w and w.key == key and os.clock() - w.t < 30)
end
-- WALKING ON AFTER A BATTLE (2026-11-16, user: after a battle the chest wasn't found any
-- more). A battle -- or a menu, a speech bubble, a scene -- stops the walk, and nav_drive
-- keeps its route (NV.paused). The next Backspace for the same target walks on with it
-- from where you stand, without a new search: on the path to the Maiya caves the search
-- from the battle's spot ran out of traces, yet the route the walk was on was fine. Only
-- in the same area, within 15 minutes, for the same target (a person who moved more than
-- 100 since: a new search), and from within 150 of the route's rest.
-- The leg (i -> i+1) of the rest (from the leg being walked) nearest to (px,py): i, distance.
NV.resume_index = function(path, wp, px, py)
    local best, bi = math.huge, nil
    for i = math.max(1, wp - 1), #path - 1 do
        local a, b = path[i], path[i + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local l2 = dx * dx + dy * dy
        local t = (l2 > 0) and math.max(0, math.min(1, ((px - a.x) * dx + (py - a.y) * dy) / l2)) or 0
        local cx, cy = a.x + dx * t - px, a.y + dy * t - py
        local d = math.sqrt(cx * cx + cy * cy)
        if d < best then best, bi = d, i end
    end
    return bi, best
end
NV.resume_paused = function(pr, key, cat, ox, oy, px, py)
    local g = pr.goal
    if not (g and key and g.key == key) or pr.area ~= M.map_id() or os.clock() - pr.t > 900 then return false end
    -- the target itself was the goal (not a door on the way): still where it was?
    if g.cat == cat and math.sqrt((g.x - ox) ^ 2 + (g.y - oy) ^ 2) > 100 then return false end
    local i, d = NV.resume_index(pr.path, pr.wp, px, py)
    if not i or d > 150 then
        log(string.format("NAVWALK the old route is %.0f away: a new search", d or -1))
        return false
    end
    local pts = { { x = px, y = py } }
    for j = i + 1, #pr.path do pts[#pts + 1] = pr.path[j] end
    NV.goal = g
    NV.push, NV.retries, NV.bestgoal, NV.noimprove = nil, 0, nil, 0
    NV.escapes, NV.last_escape, NV.approach, NV.iapproach = 0, nil, nil, nil
    log(string.format("NAVWALK on with the old route: %.0f from its leg %d of %d", d, i, #pr.path - 1))
    nav_walk_begin_path(pts, tr("same route as before"))
    return true
end
local function nav_walk_start(quiet)
    NV.ctrlkey_t = os.clock()
    -- plain Backspace is also the GAME's cancel key ("Rück Zurück"): pressed in a menu,
    -- a dialog or a scene it must do nothing here -- no walk, no "Scene running"
    if quiet and (world_susp or M.explore_now == false) then return end
    -- ...nor the Backspace that just closed a menu: it said "No target selected" as the
    -- main menu closed, and with a target it would have walked off (2026-11-14)
    if quiet and os.clock() - (M.unexplore_t or -9) < 0.6 then return end
    if nav_walking then nav_walk_stop(tr("Walk stopped")); return end
    if NV.route then NV.route = nil; speak(tr("Routing cancelled")); return end
    if NV.door_auto then                -- the walker is opening a door: Backspace stops it
        NV.door_auto, NV.resume_walk = nil, nil
        pcall(function() shim.KeyEvent(0x45, false) end)
        speak(tr("Walk stopped"))
        return
    end
    if world_susp then speak(M.battle_now and tr("In battle") or tr("Scene running, try again after")); return end
    -- after a teleport: never walk to a target of the part we left (NV.list_stale)
    if #NV.list > 0 and NV.list_stale() and NV.list_refresh() then
        if #NV.list == 0 then speak(tr("Targets changed, none here")); return end
        nav_announce(trn("Targets changed. %s, %d target. ", "Targets changed. %s, %d targets. ", #NV.list, M.cat_word(NAV_CLASSES[NV.cat].name), #NV.list))
        return
    end
    local t = nav_target()
    if not t then speak(tr("No target selected")); return end
    local p = get_player_obj(); if not p then speak(tr("No player")); return end
    local px, py, pz = read_actor_pos(p)
    local ox, oy, oz = NV.tpos(t)
    if not (px and ox) then speak(tr("Target lost")); return end
    oz = oz or pz
    local key = NV.tkey(t)
    -- the route a battle (a menu, a scene) cut short: on with it (NV.resume_paused)
    local pr = NV.paused
    NV.paused = nil
    if pr and NV.resume_paused(pr, key, t.walkcat or t.cat, ox, oy, px, py) then return end
    NV.goal = { x = ox, y = oy, z = oz, cat = t.walkcat or t.cat, key = key }
    NV.goal.chest = NV.leg_target(t, NV.goal.cat)   -- (its last leg is traced: NV.goal_leg_ok)
    if NV.is_stepin(t) then   -- a shop without a keeper: reached at its prompt
        NV.goal.stepin = true
        NV.goal.pname = type(t.name) == "string" and t.name or nil
    end
    NV.push = nil
    NV.retries = 0
    NV.bestgoal = nil
    NV.noimprove = 0
    NV.escapes, NV.last_escape, NV.approach, NV.iapproach = 0, nil, nil, nil
    -- INSIDE A BUILDING you're not in: walk to its door first (the closed door blocks
    -- every route). At the door the game says "Öffnen, E"; after E, Backspace again
    -- walks inside (then you stand at the door, so this leg is skipped).
    local samehouse = false
    if t.cat ~= "building" then
        NV.goal.tin = NV.target_in_house(t)   -- (the game's word, for the door after a failed route too)
        local okd, door, how, pdoor = pcall(M.house_door_for, ox, oy, oz, px, py, pz, true, nil, NV.goal.tin)
        -- you are in (or at the door of) the target's house: route straight in. If the
        -- door is still shut that fails -- then say "open the door", not "not reachable"
        samehouse = okd and (how == "same" or how == "atdoor")
        NV.goal.samehouse = samehouse
        -- LEAVING a house first: its door closes behind you and opens only with E, from
        -- inside too (the walk out of the library wedged at the shut door, 2026-11-13)
        local atmydoor = false
        if okd and pdoor and not samehouse then
            local dx, dy, dz = read_actor_pos(pdoor)
            local dd = dx and math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2)
            if dd and (dd > NV.ATDOOR or NV.door_leg_near(key, dd)) then
                NV.goal = { x = dx, y = dy, z = dz or pz, cat = "door", key = key }
                speak(trf("Leaving the building first. Routing to its door, %d", math.floor(dd + 0.5)))
                nav_route_begin("walk", dx, dy, dz or pz)
                return
            end
            NV.goal.samehouse = true   -- at the door: a failed route means "open it first"
            samehouse, atmydoor = true, true
        end
        -- or a door found earlier after the router failed (doorway-plane test)
        if not samehouse and not (okd and door) and NV.is_noroute(key, px, py) and NV.noroute[key].door then
            local okv = false
            pcall(function() okv = NV.noroute[key].door:IsValid() end)
            if okv then okd, door = true, NV.noroute[key].door end
        end
        if okd and door then
            local dx, dy, dz = read_actor_pos(door)
            local dd = dx and math.sqrt((dx - px) ^ 2 + (dy - py) ^ 2)
            if dd and (dd > NV.ATDOOR or (how == "atdoor" and NV.door_leg_near(key, dd))) then
                -- standing at the shut door of the house you are in: a failed route to
                -- this door means "open that one first"
                NV.goal = { x = dx, y = dy, z = dz or pz, cat = "door", key = key, samehouse = atmydoor or nil }
                local who = t.name and t.name:match("^[^,]+") or M.cat_word(t.cat)
                speak(trf("%s is inside a building. Routing to its door, %d", who, math.floor(dd + 0.5)))
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
        speak(tr("Not reachable from here. Press again to try anyway"))
        return
    end
    -- navmesh first (free + instant if the game has it), else our traced A*
    local pts = nav_find_path(p, px, py, pz, ox, oy, oz)
    if pts then
        nav_walk_begin_path(pts, tr("navmesh path"))
        return
    end
    local d = math.floor(math.sqrt((ox - px) ^ 2 + (oy - py) ^ 2) + 0.5)
    speak(trf("Routing to %s, %d", M.cat_word(t.cat), d))
    nav_route_begin("walk", ox, oy, oz)
end

nav_drive = function()   -- per FRAME from the tick hooks: steer by holding arrow keys
    -- a menu / dialog / speech bubble came up (M.menu_now, from the pump): held arrow
    -- keys would now move a menu cursor -- stop like for a scene
    if world_susp or M.menu_now then
        if NV.unstick then NV.unstick.live = nil end   -- its key-ups wait for the field
        -- scene/transition: end any walk or routing NOW and release the keys.
        -- (The driver runs outside the pump's gate, so it must check itself --
        -- it once kept keys held through a whole cutscene and the character
        -- marched through a door into the next crash.) The short tap after "Arrived"
        -- (NV.face) too: it held its keys through the scene.
        if nav_walking or NV.route or NV.face then
            local waswalking = nav_walking
            -- (not a route the walk is just freeing itself from: it got stuck on it)
            local path, wp = (not NV.unwedge) and NV.path or nil, NV.wp
            -- the game may miss this release (M.unstick_arm): key-ups again later
            M.unstick_arm(NV.held, NV.unwedge and NV.unwedge.held, NV.face and NV.face.held)
            nav_walking = false
            NV.path = nil
            NV.route = nil
            NV.unwedge = nil
            NV.pwait = nil
            NV.face = nil
            NV.held = nil
            pcall(function() shim.HoldKeys(false, false, false, false) end)
            -- walking INTO an exit ends in its transition fade: that is the arrival,
            -- and the new area announces itself -- say nothing then
            local into_exit = NV.goal and NV.goal.cat == "exit" and (NV.push or (NV.lastgd or 1e9) < 450)
            -- a story event's spot: its scene starting is the arrival, as an exit's fade
            local into_event = NV.goal and NV.goal.cat == "event" and (NV.lastgd or 1e9) < 450
            -- a battle (a menu, a scene) cut the walk short: its route is kept for the next
            -- Backspace (NV.resume_paused). Only values here -- no actor reads while the
            -- battle's transition may be tearing the field down.
            if waswalking and path and wp and NV.goal and not (into_exit or into_event) then
                NV.paused = { path = path, wp = wp, goal = NV.goal, area = M.map_id(), t = os.clock() }
            end
            if waswalking and not (into_exit or into_event) then speak(tr("Walk stopped")) end
            if into_exit then log("NAVWALK through exit") end
            if into_event then log("NAVWALK into the event") end
        end
        return
    end
    if NV.unstick then M.unstick_step() end
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
    -- waiting for a person in the way to walk on (NV.pwait, nav_walk_watch): no keys
    if NV.pwait then return end
    -- unwedge sidestep phase: hold the perpendicular key briefly, then re-route
    if NV.unwedge then
        if now < NV.unwedge.till then
            NV.held = NV.unwedge.held
            NV.held_t = NV.held_t or {}
            for k in pairs(NV.held or {}) do NV.held_t[k] = now end
            pcall(function() shim.HoldKeys(NV.unwedge.u, NV.unwedge.d, NV.unwedge.l, NV.unwedge.r) end)
            return
        end
        local esc = NV.unwedge.escape      -- a step to free ourselves (NV.escape_step)
        NV.unwedge = nil
        nav_walking = false
        NV.path = nil
        NV.held = nil
        pcall(function() shim.HoldKeys(false, false, false, false) end)
        if NV.goal and (esc or (NV.retries or 0) < 4) then
            if not esc then NV.retries = (NV.retries or 0) + 1 end
            speak(esc and tr("Trying another way") or tr("Rerouting"))
            nav_route_begin("walk", NV.goal.x, NV.goal.y, NV.goal.z)
        else
            speak(tr("Walk interrupted, backspace to resume"))
        end
        return
    end
    if not NV.path then return end
    local p = get_player_obj()
    local px, py, pz
    if p then px, py, pz = read_actor_pos(p) end
    if not px then
        -- world unstable (transition in progress): stop NOW, never idle with keys held
        M.unstick_arm(NV.held)
        nav_walking = false
        NV.path = nil
        NV.held = nil
        pcall(function() shim.HoldKeys(false, false, false, false) end)
        return
    end
    local wp = NV.path[NV.wp]
    while wp do
        local dx, dy = wp.x - px, wp.y - py
        -- tight at turns (nav_walk_begin_path), and at a chest's other side (NV.item_spot)
        local reach = (NV.wp == #NV.path) and ((NV.goal and NV.goal.cat == "spot") and 35 or 110) or (wp.reach or 40)
        local dist = math.sqrt(dx * dx + dy * dy)
        if dist >= reach then
            -- ...or already PAST it: within 60 and beyond the line through it square to
            -- its leg. 8 keys rarely pass a turn point within 22, so the walker circled
            -- it at ~30 until the "no closer" skip (0.35 s; chest 2, 2026-11-14)
            local wb = NV.wpbest
            if not (NV.wp < #NV.path and dist < 60 and wb and wb.i == NV.wp and wb.path == NV.path
                and (px - wp.x) * (wp.x - wb.ax) + (py - wp.y) * (wp.y - wb.ay) > 0) then
                break
            end
        end
        NV.wp = NV.wp + 1
        wp = NV.path[NV.wp]
    end
    if wp then
        -- a new leg: push its waypoint off walls first (not the target itself), and
        -- remember where the leg starts (the steering below follows the line from there)
        local wb = NV.wpbest
        local dd = math.sqrt((wp.x - px) ^ 2 + (wp.y - py) ^ 2)
        if not wb or wb.i ~= NV.wp or wb.path ~= NV.path then
            if NV.wp < #NV.path and not wp.nudged and NV.nudge_wp then
                pcall(NV.nudge_wp, wp)
                dd = math.sqrt((wp.x - px) ^ 2 + (wp.y - py) ^ 2)
            end
            NV.wpbest = { i = NV.wp, path = NV.path, d = dd, t = now, ax = px, ay = py }
        elseif dd < wb.d - 3 then
            wb.d, wb.t = dd, now
        elseif NV.wp < #NV.path and dd < 75 and now - wb.t > 0.35 then
            -- a waypoint the body still can't get near (a wall right beside it): within
            -- 75 and no closer for 0.35 s -> take the next one, instead of pushing the
            -- wall for 1.2 s until the stuck check re-routes
            log(string.format("NAVWALK wp %d skipped at %.0f (no closer)", NV.wp, dd))
            NV.wp = NV.wp + 1
            wp = NV.path[NV.wp]
            NV.wpbest = nil
        end
    end
    local dx, dy
    if not wp then
        local gcat = NV.goal and NV.goal.cat
        if gcat == "through" then          -- stepped through a doorway: route on
            nav_walk_stop()
            NV.resume_walk = true
            return
        end
        local stepin = NV.goal and NV.goal.stepin
        if gcat ~= "exit" and gcat ~= "door" and not stepin then
            nav_walk_stop(tr("Arrived"))
            pcall(NV.face_goal)
            return
        end
        -- STEP-IN (a shop without a keeper, NV.is_stepin): like a door, push on to its
        -- center until its prompt shows (nav_walk_watch stops the walk then), 2 s at most
        if stepin then
            if not NV.push then
                NV.push = { till = now + 2.0 }
                log("NAVWALK push into the step-in target")
            end
            NV.push.x, NV.push.y = NV.goal.x - px, NV.goal.y - py
            if now > NV.push.till then
                NV.push = nil
                nav_walk_stop(NV.stepin_fail(px, py, pz or NV.goal.z))
                return
            end
            dx, dy = NV.push.x, NV.push.y
        else
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
                if NV.door_auto_start() then return end   -- the walker opens it itself
                -- a prompt that was up before the walk wasn't spoken now: say it again
                if NV.prompt_at_start then speak(trf("Still shut. %s, then backspace again", M.popup_text or tr("press Enter")))
                elseif gcat == "door" then speak(tr("then backspace again"), false) end
                return
            end
            if now > NV.push.till then
                NV.push = nil
                if gcat == "door" then
                    local dd = math.sqrt((NV.goal.x - px) ^ 2 + (NV.goal.y - py) ^ 2)
                    log(string.format("DOORLEG no prompt: player (%.0f,%.0f) door (%.0f,%.0f) d=%.0f",
                        px, py, NV.goal.x, NV.goal.y, dd))
                    -- 2 s of pushing into the doorway and no "Öffnen" prompt: the door is OPEN
                    -- (the library's stayed open after we went in; the walker stood 30 past
                    -- its center and still said "Open it", 2026-11-14) -- walk on to the
                    -- target. Once per target in 30 s, so a door that really is shut can't loop.
                    local w = NV.door_walked_on
                    if dd < 60 and not (w and w.key == NV.goal.key and now - w.t < 30) then
                        NV.door_walked_on = { key = NV.goal.key, t = now }
                        log("DOORLEG door is open: walking on")
                        nav_walk_stop()
                        NV.resume_walk = true
                        return
                    end
                end
                nav_walk_stop(gcat == "door" and tr("At the door. Open it, then backspace again")
                    or tr("At the exit, no way through"))
                return
            end
            dx, dy = NV.push.x, NV.push.y
        end   -- (exit / door)
    else
        dx, dy = wp.x - px, wp.y - py
        -- follow the LEG, not just its end point: aim 70 ahead of us along the line from
        -- where this leg began. Chasing the point with 8 keys let a slanted leg drift
        -- sideways until the diagonal key came on (108 off a 415 leg, into a wall the
        -- route went round: study, 2026-11-14); now the drift stays under ~30.
        local wb = NV.wpbest
        if wb and wb.i == NV.wp and wb.path == NV.path and wb.ax then
            local sx, sy = wp.x - wb.ax, wp.y - wb.ay
            local sl = math.sqrt(sx * sx + sy * sy)
            if sl > 1 then
                local ux, uy = sx / sl, sy / sl
                local t = math.max(0, (px - wb.ax) * ux + (py - wb.ay) * uy) + 70
                if t < sl then dx, dy = wb.ax + ux * t - px, wb.ay + uy * t - py end
            end
        end
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
            nav_walk_stop(tr("Walk cancelled"))
            return
        end
    end
    local p = get_player_obj(); if not p then return end
    local px, py, pz = read_actor_pos(p); if not px then return end
    -- waiting for a person in the way to walk on (NV.pwait, the stuck check below): when
    -- the time is up, on along the same route if they moved; one who stood still is
    -- static, and the stuck check goes on as before (sidestep, re-route)
    local pw = NV.pwait
    if pw then
        if now < pw.till then return end
        NV.pwait = nil
        local qx, qy
        pcall(function() qx, qy = read_actor_pos(pw.q.actor) end)
        local moved = qx and math.sqrt((qx - pw.qx) ^ 2 + (qy - pw.qy) ^ 2) or 0
        log(string.format("NAVWALK %s moved %.0f while we waited", tostring(pw.name), moved))
        NV.prog = { t = now, x = px, y = py }
        if moved <= 40 then
            NV.pwait_static = true
            NV.prog.t = now - 1.3   -- (the stuck check right away: sidestep, re-route)
        end
        return
    end
    -- arrival forgiveness: within interaction range of the GOAL counts as
    -- arrived, even when the exact spot is blocked (counters, furniture) --
    -- chasing the unreachable final meters caused endless circling
    if NV.goal then
        local gd = math.sqrt((px - NV.goal.x) ^ 2 + (py - NV.goal.y) ^ 2)
        NV.lastgd = gd
        if NV.goal.stepin then
            -- a shop without a keeper (NV.is_stepin): there when its prompt shows, at any
            -- distance; never "close enough" (the Flammhuld inn: "Arrived" 152 below its
            -- steps). The prompt speech says it ("Gasthaus, E"); one already up when the
            -- walk began is said again.
            if NV.stepin_prompt() then
                log("NAVWALK step-in prompt: " .. tostring(M.popup_text))
                nav_walk_stop()
                if NV.prompt_at_start then speak(M.popup_text or tr("Arrived")) end
                return
            end
        elseif NV.goal.cat == "exit" then
            -- exits are walked THROUGH (nav_drive pushes on past the last waypoint).
            -- The arrival is the transition: a fade (nav_drive ends the walk silently)
            -- or a teleport jump (below). NOT the area banner: leaving the study the
            -- banner "Palasttor Atlasdamm" came up in the passage BEFORE the exit and
            -- the walk stopped short of it (2026-11-14).
            -- a DOOR exit: near it the game shows its prompt ("Öffnen, E", already
            -- spoken) and only the key opens it -- pushing on just wedges into the
            -- door and re-routes (seen 2026-11-11 at the academy door). Stop there.
            if M.popup_said and gd < 450 then
                log("NAVWALK at door exit (prompt)")
                nav_walk_stop()   -- silent: "Arrived" would cut off the prompt speech
                if NV.door_auto_start() then return end   -- the walker opens it itself
                -- ...unless the prompt was up already when the walk began: the door is
                -- still shut (an E press that didn't take) -- the walk ended without a
                -- word after "Walking, total 161" (2026-11-14). Say the prompt again.
                if NV.prompt_at_start then speak(trf("Still shut. %s", M.popup_text or tr("press Enter"))) end
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
                if NV.door_auto_start() then return end   -- the walker opens it itself
                if NV.prompt_at_start then
                    speak(trf("Still shut. %s, then backspace again", M.popup_text or tr("press Enter")))
                else
                    speak(tr("then backspace again"), false)
                end
                return
            end
        elseif NV.goal.cat == "event" then
            -- a story event's spot starts its scene when you step IN: no "close enough"
            -- at 170 (that left you 107 short of the headmaster's, 2026-11-14). The scene
            -- ends the walk (nav_drive); at the spot without one, arrived.
            if gd < 45 and math.abs(pz - (NV.goal.z or pz)) < LEVEL_THRESH then
                nav_walk_stop(tr("Arrived")); return
            end
        elseif NV.goal.cat == "spot" then
            -- another side of a chest / hidden item (NV.iapproach): the spot itself, not
            -- "close enough at 170" -- that ended the walk where it started (2026-11-15)
            if gd < 35 and math.abs(pz - (NV.goal.z or pz)) < LEVEL_THRESH then
                nav_walk_stop(tr("Arrived")); pcall(NV.face_goal); return
            end
        elseif gd < 170 and math.abs(pz - (NV.goal.z or pz)) < LEVEL_THRESH
            and NV.goal_level(p, px, py, pz) ~= false then
            -- (not when the goal is a floor up or down: in the academy hall a walk to
            -- a door upstairs said "Arrived" passing beneath it; nor below a terrace:
            -- the Flammhuld inn, 2026-11-16)
            nav_walk_stop(tr("Arrived")); pcall(NV.face_goal); return
        end
    end
    local jump = math.sqrt((px - NV.prog.x) ^ 2 + (py - NV.prog.y) ^ 2)
    if jump > 900 then
        -- through an exit with a teleport (the academy door): the arrival, quietly
        if NV.goal and NV.goal.cat == "exit" then log("NAVWALK through exit (jump)"); nav_walk_stop(); return end
        nav_walk_stop(tr("Walk ended, went through a door")); return
    end
    if jump > 40 then
        NV.prog = { t = now, x = px, y = py }
    elseif now - NV.prog.t > 1.2 and not NV.unwedge then   -- (was 2 s of pushing a wall)
        -- stuck: wedged on geometry, a blocker, a battle, or a cutscene.
        -- If we hold keys but the pawn reports no movement input, the game has
        -- taken input away (cutscene/battle): stop quietly, never fight it.
        local inpMag = 0
        pcall(function() local iv = p:GetLastMovementInputVector(); inpMag = math.sqrt(iv.X * iv.X + iv.Y * iv.Y) end)
        if NV.held and inpMag < 0.3 then
            -- ...or an arrow the game still takes as down cancels ours: its release was
            -- lost in a battle or a scene, and "down" against a stuck "up" is no input
            -- (2026-11-16). Once per walk: key-ups for the other arrows, then go on.
            if not NV.unstuck then
                NV.unstuck = true
                local others = {}
                for k in pairs(M.ARROW_VK) do if not NV.held[k] then others[k] = true end end
                M.arrows_up(others, string.format("no input while walking, %.2f", inpMag))
                NV.prog = { t = now, x = px, y = py }
                return
            end
            M.unstick_arm(NV.held)
            nav_walk_stop(tr("Walk interrupted"))
            return
        end
        -- an invisible wall the route took for open (or "soft"): learn it, so the
        -- re-route below goes round it (NV.walls)
        local okl, _, q = pcall(NV.learn_wall, p, px, py, pz)
        -- A PERSON WHO WALKS ABOUT in the way (2026-11-22, Sonnschatt: two patrolling
        -- guards, "Lakai des Meisters" and "Tunichtgut", stepped into the route again and
        -- again; four re-routes, each stuck within half a second, then the user stopped
        -- it): keys up and wait 1.5 s for them to walk on, then on along the same route.
        -- Up to 3 times on a route; someone who doesn't move gets the sidestep and the
        -- re-route as before (NV.pwait_static).
        if okl and q and q.actor and not NV.pwait_static and (NV.pwait_n or 0) < 3 and NV.path then
            NV.pwait_n = (NV.pwait_n or 0) + 1
            local nm = NV.person_name(q)
            NV.pwait = { till = now + 1.5, q = q, qx = q.x, qy = q.y, name = nm }
            NV.held = nil
            pcall(function() shim.HoldKeys(false, false, false, false) end)
            log(string.format("NAVWALK waits for %s at (%.0f,%.0f) (#%d)", tostring(nm), q.x, q.y, NV.pwait_n))
            if NV.pwait_n == 1 then
                speak(nm and trf("Waiting for %s", nm) or tr("Waiting for someone to walk on"))
            end
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
                        px + c[1] * 170, py + c[2] * 170, pz + 30, NV_TRACE)
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
        -- (an event's spot must be stepped into: stuck 200 short of it is not there; a
        -- chest's other side (NV.item_spot) likewise)
        local gc = NV.goal and NV.goal.cat
        local reach = (gc == "event") and 60 or (gc == "spot") and 50 or 220
        if NV.goal and NV.goal.stepin and gd >= 0 and gd < 250 then
            -- stuck at a step-in target: its prompt or the honest word (no wall is learned
            -- this close to the target, so a re-route would take the same way again)
            if NV.stepin_prompt() then
                if NV.prompt_at_start then speak(M.popup_text or tr("Arrived")) end
            else
                speak(NV.stepin_fail(px, py, pz))
            end
        elseif gd >= 0 and gd < reach and gdz < LEVEL_THRESH and NV.goal_level(p, px, py, pz) ~= false
            and not (NV.goal and NV.goal.stepin) then
            speak(tr("Arrived"))                       -- close enough to interact
            pcall(NV.face_goal)
        elseif NV.goal and (NV.noimprove or 0) < 2 and (NV.retries or 0) < 5 then
            NV.retries = (NV.retries or 0) + 1
            speak(tr("Rerouting"))
            nav_route_begin("walk", NV.goal.x, NV.goal.y, NV.goal.z)
        elseif gc == "spot" then
            NV.spot_failed(NV.goal)                    -- another side of a person / chest: the next
        else
            speak(trf("Can't reach, closest %d", math.floor((NV.bestgoal or gd) + 0.5)))
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
    if NV.resume_walk and not nav_walking and not NV.route and not NV.door_auto then
        NV.resume_walk = nil
        pcall(nav_walk_start, true)   -- after a doorway / an opened door: on to the target
    end
    -- after "Arrived" at a person: another short step until the game picks them as the
    -- one to talk to (M.talk_pick = player.refTalkChara), at most 3
    local a = NV.approach
    if a and not nav_walking and not NV.face and not NV.route and os.clock() >= a.next then
        local inrange = (M.talk_pick == a.addr)
        if not inrange and (M.talk_pick or 0) ~= 0 and M.talk_pick_obj and a.x then
            -- the game's pick can be ANOTHER object for the same person: in the library
            -- the hint said "Path action, Mercedes" (pick 24EF9C0D030), yet the list's
            -- actor differed and the walker stepped on, "not reached" (2026-11-14).
            -- Someone of the same name picked where the target stands counts -- the same
            -- NAME: Mercedes, picked next to the save point marker's nameless actor,
            -- counted as it ("in talk range", and Enter talked to her, user report
            -- 2026-11-14).
            local pn
            pcall(function() pn = shim.NpcName(M.talk_pick) end)
            local x, y = read_actor_pos(M.talk_pick_obj)
            if x and a.name and pn == a.name and math.sqrt((x - a.x) ^ 2 + (y - a.y) ^ 2) < 100 then
                inrange = true
            end
        end
        if inrange then
            log("NAVWALK in talk range")
            NV.approach = nil
        elseif a.tries >= 4 then
            log(string.format("NAVWALK talk range not reached (pick %X, target %X)", M.talk_pick or 0, a.addr))
            NV.approach = nil
            NV.approach_fail(a)
        else
            a.tries = a.tries + 1        -- odd tries step sideways (NV.face_goal)
            a.next = os.clock() + 0.7
            pcall(NV.face_goal, a.tries)
        end
    end
    -- after "Arrived" at a chest / hidden item: its prompt must show (M.popup_said = a
    -- prompt on screen now). If not: one more step toward it, then up to three other sides
    -- with a clear line to it (NV.item_spot), then say so. You walking off ends it.
    local ia = NV.iapproach
    if ia and not nav_walking and not NV.face and not NV.route and os.clock() >= ia.next then
        local p = get_player_obj()
        local px, py
        if p then px, py = read_actor_pos(p) end
        local okc, opened = pcall(M.chest_state, { addr = ia.addr })
        local mine = M.popup_said and NV.prompt_is_item(ia)
        if M.popup_said and not mine and ia.other ~= M.popup_said then
            ia.other = M.popup_said
            log("NAVWALK item: the prompt is not the item's: " .. tostring(M.popup_said) .. " "
                .. tostring(M.popup_target_cls))
        end
        -- ...and E must reach it: with a person picked as well (M.talk_pick: the save
        -- point's book, the villager lying by a hidden item), E talks to them first -- the
        -- save menu or "U-ugh..." each time (user 2026-11-23). Then another side, one
        -- where they aren't in front of you as you face the item (NV.item_spot, ia.avoid).
        local talker = (M.talk_pick or 0) ~= 0 and M.talk_pick or nil
        if mine and talker then
            mine = false
            if ia.talker ~= talker then
                ia.talker = talker
                ia.tname = M.talk_pick_name()
                local tx, ty
                if M.talk_pick_obj then tx, ty = read_actor_pos(M.talk_pick_obj) end
                if tx then ia.avoid = { x = tx, y = ty } end
                -- lying there knocked out (M.npc_swoon): once no side helps, that is said,
                -- and where they get up (user 2026-11-23: the villager in S'warkii)
                local okw, sw = pcall(M.npc_swoon, M.talk_pick_obj, true)
                ia.swoon = okw and sw or nil
                log(string.format("NAVWALK item: its prompt shows, but E would go to %s (%X)%s", tostring(ia.tname), talker,
                    ia.swoon and string.format(", knocked out (index %s, battle row %s, gets up at levels %s)",
                        tostring(ia.swoon.idx), tostring(ia.swoon.row), table.concat(ia.swoon.levels, ","))
                    or (okw and sw == false and ", not knocked out" or "")))
            end
            if ia.tries == 0 then ia.tries = 1 end   -- (a step closer won't help: other sides)
        end
        local who = ia.talker and (ia.tname or tr("someone else"))
        if mine then
            log("NAVWALK item prompt: " .. tostring(M.popup_said))
            NV.iapproach = nil
        elseif (okc and opened) or not px or math.sqrt((px - ia.px) ^ 2 + (py - ia.py) ^ 2) > 80 then
            NV.iapproach = nil                -- opened, or you walked off
        elseif ia.tries == 0 then
            ia.tries, ia.next = 1, os.clock() + 1.0
            pcall(NV.face_goal, 2)            -- one more step toward it
        elseif ia.tries <= 3 then
            ia.tries = ia.tries + 1
            local oks, spot, relaxed, why = pcall(NV.item_spot, ia, p, px, py)
            if oks and spot then
                ia.spots[#ia.spots + 1] = spot
                ia.next = os.clock() + 1.0
                log(string.format("NAVWALK item: no prompt at (%.0f,%.0f), trying (%.0f,%.0f)%s", px, py, spot.x, spot.y,
                    relaxed and " (every side has the person ahead: the one most off the line)" or ""))
                -- (after a side no route reached, NV.spot_failed: that, not "no prompt here")
                speak((ia.noroute and tr("That side can't be reached, trying another side"))
                    or (who and trf("Here Enter goes to %s, trying another side", who)) or tr("No prompt here, trying another side"))
                ia.noroute = nil
                NV.goal = { x = spot.x, y = spot.y, z = spot.z, cat = "spot", key = NV.goal and NV.goal.key,
                    face = { x = ia.x, y = ia.y } }
                NV.retries, NV.bestgoal, NV.noimprove = 0, nil, 0
                nav_route_begin("walk", spot.x, spot.y, spot.z)
            else
                if not oks then log("NAVWALK item spot error: " .. tostring(spot)) end
                if oks then
                    log(string.format("NAVWALK item: no side at item (%.0f,%.0f)%s: %s", ia.x, ia.y,
                        ia.avoid and string.format(", person at (%.0f,%.0f)", ia.avoid.x, ia.avoid.y) or "",
                        tostring(why)))
                end
                speak((ia.swoon and M.swoon_text(ia.tname or tr("Someone"), ia.swoon))
                    or (ia.noroute and tr("That side can't be reached, and no other side found"))
                    or (who and trf("Here Enter goes to %s, and no other side found", who))
                    or tr("No prompt here, and no other side found"))
                NV.iapproach = nil
            end
        else
            speak((ia.swoon and M.swoon_text(ia.tname or tr("Someone"), ia.swoon))
                or (ia.noroute and tr("That side can't be reached, and no other side found"))
                or (who and trf("Here Enter goes to %s, not to the item", who)) or tr("No prompt at this item"))
            NV.iapproach = nil
        end
    end
    pcall(NV.door_auto_step)          -- opening a door on the route (E, wait, walk on)
    -- (not for a list from before a teleport: its far targets cost thousands of traces
    -- each for nothing; the next navigator key rebuilds it)
    if not NV.route and not nav_walking and not NV.list_stale() then
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
        log("Bound " .. label .. " (" .. (mods and ((mods[1] == ModifierKey.SHIFT) and "Shift+" or "Ctrl+") or "")
            .. kn .. "): " .. tostring(ok))
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
    -- speech history (M.hist_key): comma / period back / forward, with Shift the first /
    -- the last line. The game binds neither (DefaultInput.ini: W A S D Q E O I J M P,
    -- arrows, Enter, Backspace, Escape, Shift, F12). The plain bind checks Shift itself.
    local function hist_plain(dir, shifted)
        return function()
            local ctrl, shift, alt = false, false, false
            if shim and shim.KeyModifiers then pcall(function() ctrl, shift, alt = shim.KeyModifiers() end) end
            if ctrl or alt then return end
            pcall(M.hist_key, shift and shifted or dir)
        end
    end
    bindany({ "OEM_COMMA", "COMMA" },  nil, hist_plain(-1, "first"), "history back")
    bindany({ "OEM_PERIOD", "PERIOD" }, nil, hist_plain(1, "last"),  "history forward")
    if ModifierKey.SHIFT then
        bindany({ "OEM_COMMA", "COMMA" },  { ModifierKey.SHIFT }, function() pcall(M.hist_key, "first") end, "history first")
        bindany({ "OEM_PERIOD", "PERIOD" }, { ModifierKey.SHIFT }, function() pcall(M.hist_key, "last") end,  "history last")
    end
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
    return pcall(LoopAsync, 100, function()   -- (a game-thread timer: see the top of the file)
        if not M.fg_ok() then return false end   -- unfocused: skip nav_drive + pump (game calls fault)
        pcall(nav_drive)
        pcall(radar_pump, "loop")
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

-- WHEN YOU CAN ACT AGAIN (2026-11-17, user: after a dialogue, a scene or a battle J and E
-- worked long before the radar was back). The radar waited 1.5 s after the event flag
-- went off (between two chained events it can drop for a moment), then 0.3 s for its
-- rescan. The player controller itself knows whom the input goes to (KSPlayerController,
-- native): InputMode, EKSInputMode u8 @ +0x6C0 (0 MODE_CHARA, 1 MODE_UI: the names from
-- the exe), and IsPlayerCharacterInput, bool @ +0x6C1. Read raw (shim.Peek) through a kept
-- handle: no game call, safe on any thread. Returns mode, input -- or nil when unknown.
-- Found again at most every 5 s, and never while a fade is up (FindFirstOf walks the
-- objects; M.fade_now is the last pump's).
M.ctrl_state = function()
    local h = M.pc_h
    if not M.handle_ok(h) then
        M.pc_h, h = nil, nil
        local now = os.clock()
        if M.fade_now or now - (M.pc_find_t or -99) < 5.0 then return nil end
        M.pc_find_t = now
        pcall(function()
            local x = FindFirstOf("KSPlayerControllerBP_C")
            if x and x:IsValid() then M.pc_h = M.handle(x) end
        end)
        h = M.pc_h
        if not h then return nil end
    end
    local mode, inp
    pcall(function() mode = shim.Peek(h.a + 0x6C0, "u8"); inp = shim.Peek(h.a + 0x6C1, "u8") end)
    return mode, inp
end
-- How long the radar stays down after an event, from the controller's state: the input
-- with the character (can_act true), away from it (false), or unknown (nil). Only when the
-- event took the input away and it has been back with the character for 0.25 s does the
-- wait shrink from 1.5 s to 0.25 s, so a controller that never changes (or can't be read)
-- leaves it as it was. A new event starts over. (W.ev_noact was cleared when the radar
-- came back: the next pump, still within 1.5 s of the event, took the radar down again
-- for a second -- seen after a battle in the game, 2026-11-17.)
-- Seen in the game: a battle keeps the input away from the character all along (0/0
-- during actions, 1/0 = MODE_UI in the command menus); it comes back (0/1) the moment
-- the battle mode ends. A load: nil (a new controller) until the field is there.
M.ev_hold = function(W, now, ev, can_act)
    if ev then
        if not W.in_ev then W.in_ev, W.ev_noact = true, nil end   -- (a new event)
        if can_act == false then W.ev_noact = true end
        W.act_since = nil
        return 1.5
    end
    W.in_ev = false
    if can_act then W.act_since = W.act_since or now else W.act_since = nil end
    if W.ev_noact and W.act_since and now - W.act_since >= 0.25 then return 0.25 end
    return 1.5
end

-- ---------------------------------------------------------------------------
-- Scene-widget registry rebuild (replaces on_widget_created / NotifyOnNewObject, which
-- was the focus-out crash: UE4SS's IsA class-match faults on a half-built widget during
-- the focus-change HUD rebuild, before our callback, so pcall can't catch it).
-- scene_widgets feeds menu announce (poll_active_menu), options (poll_options),
-- char-select (cs_instance) AND the radar's menu gate (BLOCKING_CLASSES scan).
--
-- One cheap source (the old broad NotifyOnNewObject is gone for good):
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
    local bm = M.kept(M.balloon_h)   -- (a handle: checked with the shim first)
    if not bm then
        M.balloon_h = nil
        local now = os.clock()
        if now - (M.balloon_find_t or -10) < 2.0 then return false end
        M.balloon_find_t = now
        pcall(function()
            local x = FindFirstOf("BalloonManagerBP_C")
            if not (x and x:IsValid()) then x = FindFirstOf("BalloonManager") end
            if x and x:IsValid() then bm = x; M.balloon_h = M.handle(x) end
        end)
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
-- NOT while the radar's rescan is pending, and only entries whose memory still holds
-- that object (M.handle_ok): CRASH 2026-11-23, walking out of the cathedral in
-- Flammhuld. In the first pump in the new area the hint (M.interact_poll, path actions
-- listed, nobody picked) asked for the nearest person; beacon_objs still held the
-- cathedral's people, freed with it, and one's old position lay within 250 of where you
-- came out. Its NPCLabel was read (M.npc_wiring -> M.npc_rec): access violation in UE4SS's
-- FindProperty (the object's class pointer was 0x0000000c00000000), past any pcall.
M.nearest_npc = function(maxd)
    if beacon_rescan_at then return nil end
    local p = get_player_obj(); if not p then return nil end
    local px, py, pz = read_actor_pos(p); if not px then return nil end
    local best, bd = nil, maxd or 250
    for _, b in ipairs(beacon_objs) do
        if b.cat == "npc" and M.handle_ok(b.h) then
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
M.poll_area_name = function(mark_only)
    local w = M.kept(M.area_widget_h)   -- (a handle: checked with the shim first)
    if not w then
        M.area_widget_h = nil
        local now = os.clock()
        if now - (M.area_find_t or -10) < 2.0 then return end
        M.area_find_t = now
        pcall(function()
            local x = FindFirstOf("MapNameNotificationWidget_C")
            if x and x:IsValid() then w = x; M.area_widget_h = M.handle(x) end
        end)
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
    -- the banner's design-time text before the game fills it in: loading at a save
    -- point spoke "0123456789, 0123456" (2026-11-14) -- wait for the real name
    if area:match("^%d+$") or (region and region:match("^%d+$")) then return end
    -- the banner's separator is part of the region text ("Flachland –"); strip a
    -- trailing dash as a whole UTF-8 sequence (byte classes would eat umlauts)
    if region then
        region = region:gsub("%s+$", "")
        for _, sep in ipairs({ "\u{2013}", "\u{2014}", "-" }) do
            if region:sub(-#sep) == sep then region = region:sub(1, -#sep - 1):gsub("%s+$", ""); break end
        end
    end
    local key = area .. "|" .. (region or "")
    -- mark_only (the game over screen): what the banner holds counts as said, so a text
    -- left from before the battle isn't said after "Weiter ab letztem Speicherpunkt" at a
    -- save point somewhere else
    if mark_only then
        if not region or region == "" then M.title_banner_said = key else M.area_said = key end
        return
    end
    -- Right after a battle: wait. A banner shown as the battle began was read between
    -- the battle's end and the game over screen ("Atlasdam, Flatlands" between its items,
    -- 2026-11-16); the game over screen then marks it said (mark_only above).
    if M.battle_end_t and os.clock() - M.battle_end_t < 2.5 then return end
    -- A story title on the same banner ('So begins the tale of "Kit, the Traveler."',
    -- 2026-11-16: said as an area, with the danger level of the place): no region text
    -- and no region label (areas have eAREA_NAME_xx; this one SMR_SS_EX1_013100_TITLE /
    -- None). Said as it is, once; the area stays what it was (no walk stop, no rescan).
    if not region or region == "" then
        local rl
        pcall(function() rl = w.RegionNameLabel:ToString() end)
        if not (type(rl) == "string" and rl:find("^eAREA")) then
            if key ~= M.title_banner_said then
                M.title_banner_said = key
                local ml
                pcall(function() ml = w.MapNameLabel:ToString() end)
                log("AREA title banner: " .. area .. " labels=" .. tostring(ml) .. "/" .. tostring(rl))
                speak(area, false)
            end
            return
        end
    end
    if key == M.area_said then return end
    M.area_said = key
    M.area_t = os.clock()   -- a walk into an exit ends here (nav_walk_watch)
    log("AREA: " .. key)
    -- the banner's GameText labels and the level ID, to compare with the EXIT lines
    -- (an exit's strNextAreaName / strNextMapName is the label the banner shows)
    local id
    pcall(function()
        local lm = FindFirstOf("LevelManagerBP_C")
        if lm and lm:IsValid() then id = lm.CurrentLevelID end
        local ml, rl = "?", "?"
        pcall(function() ml = w.MapNameLabel:ToString() end)
        pcall(function() rl = w.RegionNameLabel:ToString() end)
        -- the level the banner names: the manager's CurrentLevelID often still held the
        -- level just left (3 of 4 area changes on 2026-11-15: the study said no danger
        -- level, T_Plain_L_A came with 77), so the banner's own label decides
        local byname = M.level_id_by_name and M.level_id_by_name(ml)
        log(string.format("AREA level=%s by label=%s labels=%s/%s", tostring(id), tostring(byname), ml, rl))
        if byname then id = byname end
    end)
    -- what the game itself computed for this area (EncountManagerBP_C: DangerLevel
    -- @0x440, EncounterLevel @0x3DC, CurrentEncounter @0x3A8 = border/icons/danger), to
    -- check M.level_danger against
    pcall(function()
        local em = M.kept(M.encmgr_h)
        if not em then
            M.encmgr_h = nil
            local x = FindFirstOf("EncountManagerBP_C")
            if x and x:IsValid() then em = x; M.encmgr_h = M.handle(x) end
        end
        local a = 0
        pcall(function() a = em:GetAddress() end)
        if a ~= 0 then
            log(string.format("AREA encounters: DangerLevel=%s EncounterLevel=%s current border/icons/danger=%s/%s/%s",
                tostring(shim.Peek(a + 0x440, "i32")), tostring(shim.Peek(a + 0x3DC, "i32")),
                tostring(shim.Peek(a + 0x3A8, "i32")), tostring(shim.Peek(a + 0x3AC, "i32")),
                tostring(shim.Peek(a + 0x3B0, "i32"))))
        end
    end)
    -- the area's level, as the banner's danger icons show it (fields and dungeons)
    local okl, lv = pcall(M.danger_text, id)
    local say = (region and region ~= "") and (area .. ", " .. region) or area
    if okl and lv then say = say .. ", " .. lv end
    speak(say, false)
end

-- ACTION PROMPT: standing right at a door (and similar) shows a prompt such as
-- "[E] Öffnen" (ActionPopupWidget_C, one shared instance). Visible = isEnable and
-- Visibility 0; ShowHorizontalBox holds the key glyph (Image_Text, a circled letter
-- like "Ⓔ") and the action text ("Öffnen"). Speak "Öffnen, E" when it appears or
-- changes; nothing when it goes away. Property reads only, cached widget.
M.poll_action_popup = function()
    local w = M.kept(M.popup_widget_h)   -- (a handle: checked with the shim first)
    if not w then
        M.popup_widget, M.popup_widget_h = nil, nil
        local now = os.clock()
        if now - (M.popup_find_t or -10) < 2.0 then return end
        M.popup_find_t = now
        pcall(function()
            local x = FindFirstOf("ActionPopupWidget_C")
            if x and x:IsValid() then w = x; M.popup_widget_h = M.handle(x) end
        end)
        if not w then return end
    end
    M.popup_widget = w   -- (for the walker's prompt target: read with M.kept(M.popup_widget_h))
    local shown = false
    pcall(function() shown = (w.isEnable == true) and (w.Visibility == 0) end)
    if not shown then M.popup_said, M.popup_target_cls, M.popup_target_addr = nil, nil, nil; return end
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
    -- whose prompt it is (TargetActor, +0x268): a person's own -- "Untersuchen" at a
    -- villager lying on the ground -- gets the name in front; next to a chest it was taken
    -- for the chest's (user 2026-11-23). The walker checks it too (NV.prompt_is_item).
    local tcls, taddr, tname
    pcall(function()
        local ta = w.TargetActor
        if ta and ta:IsValid() then tcls = class_name_of(ta); taddr = ta:GetAddress() end
    end)
    if tcls == "KSFieldNPCCharacter_C" and taddr and shim and shim.NpcName then
        pcall(function() tname = shim.NpcName(taddr) end)
        if tname == "" or tname == "???" then tname = nil end
    end
    M.popup_target_cls, M.popup_target_addr = tcls, taddr
    local sig = action .. "|" .. (key or "") .. (taddr and string.format("|%X", taddr) or "")
    if sig == M.popup_said then return end
    M.popup_said = sig
    -- ENTER, not E (user 2026-11-23): Enter does the same as the game's E -- open, talk,
    -- examine -- and is the key screen reader users reach for: "Öffnen, Eingabe". Another
    -- key the prompt may show is said as it is.
    local text = key and (action .. ", " .. ((key == "E") and tr("Enter") or key)) or action
    if tname then text = trf("%s: %s", tname, text) end
    M.popup_text = text   -- as spoken ("Still shut. ...")
    log("PROMPT: " .. sig .. (tcls and (" " .. tcls) or ""))
    speak(text, false)
end

-- SKIP HINT (user 2026-11-18): a scene the game lets you skip says so once as it starts
-- ("Rücktaste halten zum Überspringen"); the game itself shows it only after a key is
-- pressed in the scene. Its skip widget, UIEventSkip_C (one, on the game instance), is
-- opened by EventManagerBP_C:PlayAfterFadeOut with UIManager:Open(101) only when the
-- scene's PlayEventData.EventSkip > 0, and closed by FinishPre (Close(101)) at the end; a
-- challenge dialog inside a scene closes and reopens it (TempEventSkip, RestoreEventSkip).
-- Holding MenuCancel (Backspace or Escape, DefaultInput.ini) fills its bar and skips; the
-- walker's Backspace stays quiet in scenes.
-- Open = Visibility (UWidget +0xB7) neither collapsed (1) nor hidden (2), and Sequence
-- (+0x248) not 2: its UIClose sets 2 and hides it. Freshly built it is visible with
-- Sequence 0 until its first tick outside a scene closes it, so the hint waits until the
-- widget was seen closed once (armed). Once per scene: a scene flag that is off for less
-- than 2 s (chained scenes) is the same scene. Not in a battle. Read raw through a kept
-- handle; found again at most every 10 s, never while a fade is up.
M.SKIP_VIS, M.SKIP_SEQ = 0xB7, 0x248
M.skip_state = function()   -- open (bool), visibility, sequence -- or nil (no widget yet)
    local h = M.skip_h
    if not M.handle_ok(h) then
        M.skip_h, h = nil, nil
        local now = os.clock()
        if M.fade_now or now - (M.skip_find_t or -99) < 10.0 then return nil end
        M.skip_find_t = now
        local nm
        pcall(function()
            local x = FindFirstOf("UIEventSkip_C")
            if x and x:IsValid() then h = M.handle(x); nm = x:GetFullName() end
        end)
        M.skip_h = h
        if not h then return nil end
        log(string.format("SKIPHINT widget %X %s", h.a, tostring(nm)))
    end
    local vis, seq
    pcall(function() vis = shim.Peek(h.a + M.SKIP_VIS, "u8"); seq = shim.Peek(h.a + M.SKIP_SEQ, "i32") end)
    if not (vis and seq) then return nil end
    return vis ~= 1 and vis ~= 2 and seq ~= 2, vis, seq
end
-- S: the state between polls; open: M.skip_state's (nil = unknown); ev: a scene plays;
-- now: os.clock(). True when the hint is due.
M.skip_hint_due = function(S, open, ev, battle, now)
    if ev and not battle then S.off_t = nil
    elseif not S.off_t then S.off_t = now end
    if S.said and S.off_t and now - S.off_t >= 2.0 then S.said = false end   -- that scene is over
    if open == nil then return false end
    if not open then S.armed = true; return false end
    if S.armed and ev and not battle and not S.said then
        S.said, S.armed = true, false
        return true
    end
    return false
end
M.skip_hint_poll = function(ev, battle, now)
    local S = M.skip_s
    if not S then S = {}; M.skip_s = S end
    local open, vis, seq = M.skip_state()
    local sig = tostring(vis) .. "/" .. tostring(seq)
    if open ~= nil and sig ~= S.sig then
        S.sig = sig
        log(string.format("SKIPHINT %s (visibility %s, sequence %s, scene %s, armed %s)",
            open and "open" or "closed", tostring(vis), tostring(seq), tostring(ev), tostring(S.armed)))
    end
    if M.skip_hint_due(S, open, ev, battle, now) then
        log("SKIPHINT said")
        speak(tr("Hold Backspace to skip"), false)
        -- the scene's first line often comes right after: it waits for the hint
        if shim and shim.TalkQueue then pcall(shim.TalkQueue, 3000) end
    end
end

-- THE GAME'S NOTIFICATIONS (user 2026-11-20: the reputation). A failed risky path action
-- (Scrutinize, Steal, Allure, Provoke) costs the town 5 of its 25 reputation points
-- (TownTable ConnectionInit/Max 25, game param SUB_RELATION_VALUE 5); the game says so
-- only in a notification at the screen's edge: "Scheitert noch 4 Mal, und Euer Ruf in der
-- Stadt wird leiden." (eCONNECTION_REMAINING), at 0 "Euer Ruf in Klarach hat gelitten."
-- (eCONNECTION_BAD), after the tavern restored it "... hat sich verbessert." (_GOOD). It is
-- LibUIUtil:CommonNotification -> UIManager:CreateByUIType(26) -> UICommonNotification_C
-- :AddInfoRequest(text), one widget for all its notices (object dump / bytecode):
-- KSTextBlock_249 the text, UiState @0x278 (ECOMMON_NOTIFICATION_STATE): 0 hidden, 1 the
-- window coming in with a text, 2 shown (2 s), 5 the text going out, 3 the next text
-- coming in, 4 shown, 6 the window going out, 7/8 queued behind a tutorial or a pause.
-- The widget comes from KSUIManager:GetList(26) (no object search); a new notice is a
-- state 1 or 3 entered, or one seen after a gap, or a text that changed.
M.NOTICE_KIND, M.NOTICE_STATE, M.NOTICE_TEXT = 26, 0x278, "KSTextBlock_249"
M.notice_widget = function()
    local w = M.kept(M.notice_h)
    if w then return w end
    M.notice_h = nil
    local now = os.clock()
    if M.fade_now or now - (M.notice_try_t or -99) < 2.0 then return nil end
    M.notice_try_t = now
    local kuim = M.ui_manager
    if not kuim then return nil end
    local o
    pcall(function() o = kuim:GetList(M.NOTICE_KIND) end)
    local ok = false
    pcall(function() ok = (o ~= nil) and o:IsValid() end)
    if not ok or class_name_of(o) ~= "UICommonNotification_C" then return nil end
    M.notice_h = M.handle(o)
    log(string.format("NOTICE widget %X", M.addr_of(o) or 0))
    return o
end
-- S: the state between polls; st: UiState; txt: its text. -> true when txt is to be said
M.notice_due = function(S, st, txt)
    local prev = S.st
    S.st = st
    if not (st and st >= 1 and st <= 4) or not txt or txt == "" then return false end
    local entering = (st == 1 or st == 3) and prev ~= st
    local after_gap = (prev == nil) or prev == 0 or prev >= 5
    if entering or after_gap or txt ~= S.text then
        S.text = txt
        return true
    end
    return false
end
M.poll_notice = function()
    local w = M.notice_widget()
    if not w then return end
    local a = M.addr_of(w)
    local st = a and shim and shim.Peek and shim.Peek(a + M.NOTICE_STATE, "u8")
    local S = M.notice_s
    if not S then S = {}; M.notice_s = S end
    local txt
    if st and st >= 1 and st <= 4 then pcall(function() txt = M.wtext(w[M.NOTICE_TEXT]) end) end
    if M.notice_due(S, st, txt) then
        log("NOTICE " .. txt)
        speak(txt, false)
    end
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
    M.talk_pick, M.talk_pick_obj = taddr, tobj   -- who Enter would talk to now (the walker's approach check)
    local raw = {}
    local mgr = get_fcmd_mgr()
    if mgr then local _; _, raw = read_active_commands(mgr) end
    local has_path = false
    for _, b in ipairs(raw) do if b ~= 0 then has_path = true; break end end
    -- the list holds the party's path actions for anyone the game picks, also for a
    -- person without a path action of their own (a tavern guest: "Wege-Aktion: Studieren;
    -- Führen; Kaufen; Herausfordern", and J offered only "Sich trennen", user 2026-11-18):
    -- the person's placement row decides (M.npc_wiring; unreadable: as before)
    local function no_path(o)
        local okw, wr = pcall(M.npc_wiring, o)
        return okw and wr ~= nil and not wr.fc
    end
    if has_path and tobj and no_path(tobj) then has_path = false end
    -- the path target is the talk pick; without one (rare), the nearest NPC
    local addr = taddr
    if addr == 0 and has_path then
        local npc = M.nearest_npc and M.nearest_npc(250)
        if npc and not no_path(npc) then pcall(function() addr = npc:GetAddress() end) end
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
    -- the balloon over the person (done / not possible) can lag the pick: once it went
    -- unsaid ("FCJUDGE balloon over 0", 2026-11-15); it shows once you stand still, so
    -- after a walk 0.8 s was too short. Wait for it up to 1.5 s.
    if has_path and now - M.ia_t < 1.5 and M.fc_judge_ready then
        local okr, ready = pcall(M.fc_judge_ready, addr)
        if okr and ready == false then return end
    end
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
            speak(tr("Save point"), false)
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
    local what = has_path and tr("Path action") or tr("Talk")
    local s = (nm and nm ~= "") and (what .. ", " .. nm) or what
    -- knocked out (M.npc_swoon): why every path action is "not possible" and the talk is
    -- only "U-ugh..." -- "Path action, Dörfler, knocked out: ..."
    do
        local okw, sw = pcall(M.npc_swoon, (addr == taddr) and tobj or nil)
        if okw and sw then s = s .. ", " .. tr("knocked out") end
    end
    -- which ones, and whether they are done or not possible (the balloon's icons):
    -- "Path action, Wachmann: Studieren, done"
    if has_path and M.fc_hint_actions then
        local oka, acts = pcall(M.fc_hint_actions, raw, addr)
        if oka and acts then s = s .. ": " .. acts end
    end
    speak(s, false)
end

-- Whom E would talk to now (M.talk_pick): the person's name, "Save point" for the save
-- point's book, else nil (the walker's item approach says it).
M.talk_pick_name = function()
    local a, o = M.talk_pick, M.talk_pick_obj
    if not a or a == 0 then return nil end
    local nm
    pcall(function() nm = shim.NpcName(a) end)
    if nm and nm ~= "" and nm ~= "???" then return nm end
    if o and M.marker_kind_of then
        local okk, kind = pcall(M.marker_kind_of, o)
        if okk and kind == "save point" then return tr("Save point") end
    end
    return nil
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
-- the path action's target by name (the field-command manager's TargetCharacter), or nil
M.fc_target_name = function()
    local mgr = get_fcmd_mgr()
    local nm
    pcall(function()
        local t = mgr and mgr.TargetCharacter
        if t and t:IsValid() then nm = shim.NpcName(t:GetAddress()) end
    end)
    return (nm and nm ~= "" and nm ~= "???") and nm or nil
end
-- A widget's design text, not the game's: full-width digits only ("１２", "２") or the run
-- "1234..." -- the Scrutinize panel before the action read "Alter: １２.
-- １２３４５６７８９０... ２. ３." (2026-11-14), the learn dialog "1234". (A real age, "41",
-- comes in plain digits.)
M.is_placeholder = function(s)
    if type(s) ~= "string" then return true end
    local core = s:gsub("[%s%p]", "")
    if core == "" then return true end
    if core:gsub("\239\188[\144-\153]", "") == "" then return true end
    if #core >= 4 and ("1234567890"):rep(4):sub(1, #core) == core then return true end
    -- the person panel's design texts: "123g" (in the hidden Guide screen, 2026-11-15)
    if core:match("^123%a?$") then return true end
    return false
end

-- Join spoken parts into sentences without doubling punctuation ("gewonnen!." /
-- "Akademie.."): a part that already ends in . ! ? : is followed by a space only.
M.join_sentences = function(parts) return M.join_text(parts) end

-- The learn-skill dialog (2026-11-14) attaches JobAbilityConfirmParts_C under its
-- caption: "LBP-Kosten: 30" / "Aktuelle LBP: 48". The dialog keeps no reference to it,
-- so it is searched for when the dialog opens; only one hanging in a widget tree
-- (GetParent) counts -- a detached one from an earlier dialog keeps its old texts.
M.dlg_parts_text = function()
    local out, seen = nil, {}
    -- (the kept list, M.ml_list: the six copies live as long as the menu; a FindAllOf
    -- on every dialog, twice when nothing was filled yet, stalled each Yes/No question
    -- in a menu 80-130 ms -- 2026-11-16, "FAST polls slow: 134 ms [active=134]")
    for _, w in ipairs(M.ml_list("JobAbilityConfirmParts_C") or {}) do
        local ok, par = false, false
        pcall(function() ok = w:IsValid() end)
        if ok then pcall(function() local p = w:GetParent(); par = p ~= nil and p:IsValid() end) end
        if ok then
            local a, an = M.wtext(w.TextAbilityJP), M.wtext(w.NumAbilityJP)
            local h, hn = M.wtext(w.TextHaveJP), M.wtext(w.NumHaveJP)
            seen[#seen + 1] = string.format("%s|%s|%s|%s par=%s", tostring(a), tostring(an), tostring(h), tostring(hn),
                tostring(par))
            -- unfilled copies keep the design texts "1234" (labels too)
            if not out and par and a and a:find("%a") and an and an:match("^%d+$") then
                out = a .. " " .. an
                if h and h:find("%a") and hn and hn:match("^%d+$") then out = out .. ", " .. h .. " " .. hn end
            end
        end
    end
    if not out and #seen > 0 then log("DLG parts (none filled): " .. table.concat(seen, " ; ")) end
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
    if age and not M.is_placeholder(age) and shown("AgeRoot") then
        parts[#parts + 1] = (agecap and (agecap .. " ") or "") .. age
    end
    local hist = read_text_block(sd, "HistoryText")
    if hist and not M.is_placeholder(hist) then parts[#parts + 1] = hist end
    local infos = {}
    for i, f in ipairs({ "InformationText01", "InformationText02" }) do
        local t = read_text_block(sd, f)
        if t and not M.is_placeholder(t) and shown("Information0" .. i) then infos[#infos + 1] = t end
    end
    if #infos > 0 then
        local cap = read_text_block(sd, "InformationCaptionText")
        parts[#parts + 1] = (cap and (cap .. ": ") or "") .. table.concat(infos, ", ")
    end
    local out = M.join_sentences(parts)
    return out ~= "" and out or nil
end

-- THE OTHER TRAVELERS' PATH ACTIONS (user request 2026-11-15: "make the remaining path
-- actions accessible, even without being able to try them"). Only Cyrus' Scrutinize has
-- been played; the rest is built from the game's own widgets and texts (object dump, the
-- name tables of the blueprints in Content/UI/FieldCommand, GameText eFC_*) and logs what
-- it reads (FCSCREEN, FCJUDGE, FCMENU, FCRANK) so the first real use shows what to fix.
--   type (KSFIeldCommandType)  traveler   name (GameText)            screen
--   1 Purchase                 Tressa     eFC_NAME_PURCHASE Kaufen   FieldCommandPurchase_C
--   2 Steal                    Therion    eFC_NAME_STEAL Stehlen     FieldCommandPurchase_C (ExecSteal)
--   3 Battle (Challenge)       Olberic    eFC_NAME_BATTLE            FieldCommandMonster_C (BattleMode)
--   4 Monster (Provoke)        H'aanit    eFC_NAME_MONSTER           FieldCommandMonster_C
--   5 Blessing (Guide)         Ophilia    eFC_NAME_BLESSING Führen   FieldCommandLure_C
--   6 Lure (Allure)            Primrose   eFC_NAME_LURE Verführen    FieldCommandLure_C (IsLure)
--   7 Examination (Inquire)    Alfyn      eFC_NAME_EXAMINATION       FieldCommandSearch_C, as Scrutinize
--   8 Search (Scrutinize)      Cyrus      eFC_NAME_SEARCH Studieren  FieldCommandSearch_C
-- Their questions ("Erfolgschance: 34 %\nDiebstahl versuchen?", "Preis: ⑳120\nDieses
-- Objekt kaufen?", "Ihr müsst mindestens Stufe {0} erreicht haben ...", "Ihr könnt nur
-- eine Person führen ...") are common dialogs: the dialog reader speaks them, with the
-- item or the person's panel in front (M.fc_dialog_desc).
M.FC_TYPES = {
    [1] = { "eFC_NAME_PURCHASE", "Purchase" }, [2] = { "eFC_NAME_STEAL", "Steal" },
    [3] = { "eFC_NAME_BATTLE", "Battle" }, [4] = { "eFC_NAME_MONSTER", "Monster" },
    [5] = { "eFC_NAME_BLESSING", "Blessing" }, [6] = { "eFC_NAME_LURE", "Lure" },
    [7] = { "eFC_NAME_EXAMINATION", "Examination" }, [8] = { "eFC_NAME_SEARCH", "Search" },
}
-- a path action's name in the game's language ("Studieren")
M.fc_type_name = function(t)
    local e = M.FC_TYPES[t]
    return (e and M.gt_label(e[1])) or FIELD_CMD_NAME[t] or trf("action %s", tostring(t))
end
M.fc_get = function(w, field)
    local v
    if w then pcall(function() v = w[field] end) end
    return v
end
M.fc_shown = function(w)
    if not w then return false end
    local v = M.wvis(w)
    return v ~= nil and v ~= 1 and v ~= 2
end
-- a text block's text while it shows and isn't a design filler ("0123", "１２", "ああ")
M.fc_txt = function(w, field)
    local tb = M.fc_get(w, field)
    if not tb or not M.fc_shown(tb) then return nil end
    local s = M.wtext(tb)
    if not s or M.placeholder(s) or M.is_placeholder(s) then return nil end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end
-- The balloon over the person you face (FieldCommandJudge_C), what sighted players see:
-- an icon per path action on offer, and on it the blueprint turns on Icon_<Type>_Comp
-- (GetFCommandComplete: done with this person) or Icon_<Type>_Imp (not possible: the
-- tavern keeper can't be scrutinized; a Challenge locked by Olberic's level showed NO Imp,
-- 2026-11-15 -- the level is only told when you try). One instance, found once (FindAllOf
-- walks every object: at most every 10 s while there is none).
M.fc_judge = function()
    local j = M.kept(M.fc_judge_h)   -- (a handle: checked with the shim first)
    if j then return j end
    M.fc_judge_w, M.fc_judge_h = nil, nil
    local now = os.clock()
    if now - (M.fc_judge_t or -99) < 10 then return nil end
    M.fc_judge_t = now
    pcall(function()
        for _, w in ipairs(FindAllOf("FieldCommandJudge_C") or {}) do
            local v = false
            pcall(function() v = w:IsValid() end)
            if v then
                local t = M.fc_get(w, "TargetCharacter")
                if not M.fc_judge_w or (t and M.addr_of(t)) then M.fc_judge_w = w end
            end
        end
    end)
    M.fc_judge_h = M.fc_judge_w and M.handle(M.fc_judge_w) or nil
    return M.fc_judge_w
end
-- whether the balloon is over the person at `addr` yet (nil: no balloon widget found)
M.fc_judge_ready = function(addr)
    local j = M.fc_judge()
    if not j then return nil end
    return M.addr_of(M.fc_get(j, "TargetCharacter")) == addr
end
-- { [type] = "done" | "not possible" } for the person at `addr`, from the balloon
M.fc_judge_states = function(addr, types)
    local j = M.fc_judge()
    if not j then return {} end
    local ta = M.addr_of(M.fc_get(j, "TargetCharacter"))
    if not ta or ta ~= addr then
        log(string.format("FCJUDGE balloon over %X, not %X", ta or 0, addr or 0))
        return {}
    end
    local out, raw = {}, {}
    for _, t in ipairs(types) do
        local e = M.FC_TYPES[t]
        if e then
            local comp = M.fc_shown(M.fc_get(j, "Icon_" .. e[2] .. "_Comp"))
            local imp = M.fc_shown(M.fc_get(j, "Icon_" .. e[2] .. "_Imp"))
            raw[#raw + 1] = string.format("%s comp=%s imp=%s", e[2], tostring(comp), tostring(imp))
            if comp then out[t] = tr("done") elseif imp then out[t] = tr("not possible") end
        end
    end
    log("FCJUDGE " .. table.concat(raw, "; "))
    return out
end
-- the hint's list: "Studieren, done; Stehlen"
M.fc_hint_actions = function(types, addr)
    local seen, list = {}, {}
    for _, t in ipairs(types or {}) do
        if t ~= 0 and not seen[t] then seen[t] = true; list[#list + 1] = t end
    end
    if #list == 0 then return nil end
    local okj, st = pcall(M.fc_judge_states, addr, list)
    if not okj then st = {} end
    local parts = {}
    for _, t in ipairs(list) do
        parts[#parts + 1] = M.fc_type_name(t) .. (st[t] and (", " .. st[t]) or "")
    end
    return table.concat(parts, "; ")
end
-- An entry of the J menu (FieldCommandMenuItemPanel_C): the blueprint shows Icon_Imp
-- (not possible) and Icon_Purchase_Comp (IsComplete) on it and greys it out
-- (UnusedFlag / IsUnused: not for this person). Its State is only the animation state
-- (EFIELDCOMMAND_MENUITEM_STATE: eNONE, eOPEN, eUPDATE, eDECIDE, eCLOSE, eSELECT).
M.fc_item_state = function(btn, label)
    if not btn then return nil end
    local unused = M.fc_get(btn, "UnusedFlag")
    local comp = M.fc_shown(M.fc_get(btn, "Icon_Purchase_Comp"))
    local imp = M.fc_shown(M.fc_get(btn, "Icon_Imp"))
    local key = string.format("%s unused=%s comp=%s imp=%s", tostring(label), tostring(unused), tostring(comp), tostring(imp))
    if key ~= M.fc_item_logged then M.fc_item_logged = key; log("FCMENU item " .. key) end
    if comp then return tr("done") end
    if imp then return tr("not possible") end
    if unused == true then return tr("unavailable") end
    return nil
end
-- stars of a RankWidget_C (Stärke): the images in RankList whose brush is RankEnable
-- (@0x258); a brush's texture is read raw at Image+0x140 (as the battle icons)
M.fc_rank = function(rw)
    if not M.fc_shown(rw) then return nil end
    local en = M.peekp(rw, 0x258)
    local on, shown, total = 0, 0, 0
    pcall(function()
        rw.RankList:ForEach(function(_, e)
            local img = e:get()
            total = total + 1
            if not M.fc_shown(img) then return end
            shown = shown + 1
            local tex = M.peekp(img, 0x140)
            if en and tex == en then on = on + 1 end
        end)
    end)
    local key = string.format("%d/%d/%d/%s", total, shown, on, tostring(en))
    if key ~= M.fc_rank_logged then
        M.fc_rank_logged = key
        log(string.format("FCRANK stars total=%d shown=%d on=%d enable=%X", total, shown, on, en or 0))
    end
    if on == 0 then return nil end
    return (shown > on) and trf("%d of %d", on, shown) or tostring(on)
end
-- A person's panel (NPCStatusPartsWidget_C) on the Challenge / Provoke / Guide / Allure
-- screens: name, strength (TextRank "Stärke" + stars), what they can do in battle
-- (NameAbility "Fertigkeiten" + TextAbility, in AbilityArea), how often they can be
-- called (NameLimit "Rufbereit" + TextLimit "3-mal", in LimitArea) -- GameText
-- eFC_BATTLE_DIALOG_RANK / _ABILITY, eFC_LEAD_SUPPORT_LIMIT(_FORMAT).
M.fc_npc_status = function(p)
    if not M.fc_shown(p) then return nil end
    local parts, raw = {}, {}
    local f = {}
    for _, k in ipairs({ "TextCharaName", "TextRank", "NameAbility", "TextAbility", "NameLimit", "TextLimit",
        "KSTextBlock_0", "KSTextBlock_1", "KSTextBlock_3" }) do
        f[k] = M.fc_txt(p, k)
        raw[#raw + 1] = k .. "=" .. tostring(f[k])
    end
    if f.TextCharaName then parts[#parts + 1] = f.TextCharaName end
    local stars = M.fc_rank(M.fc_get(p, "RankWidget"))
    if stars then
        parts[#parts + 1] = (f.TextRank or M.gt_label("eFC_BATTLE_DIALOG_RANK") or "Strength") .. " " .. stars
    end
    if M.fc_shown(M.fc_get(p, "AbilityArea")) and f.TextAbility then
        parts[#parts + 1] = (f.NameAbility and (f.NameAbility .. ": ") or "") .. f.TextAbility
    end
    if M.fc_shown(M.fc_get(p, "LimitArea")) and f.TextLimit then
        parts[#parts + 1] = (f.NameLimit and (f.NameLimit .. " ") or "") .. f.TextLimit
    end
    local key = table.concat(raw, " ")
    if key ~= M.fc_status_logged then M.fc_status_logged = key; log("FCSCREEN person: " .. key) end
    if #parts == 0 then return nil end
    return M.join_text(parts)
end
-- Guide / Allure: the person's panel (right), and while one already follows you the
-- change panel (NPCFollowChangePartsWidget_C: LeftWidget the one now, RightWidget the
-- new one) -- "Now: <panel>. New: <panel>"
M.fc_lure_status = function(w)
    local ch = M.fc_get(w, "CaptionChangeWidget")
    if M.fc_shown(ch) then
        local a = M.fc_npc_status(M.fc_get(ch, "LeftWidget"))
        local b = M.fc_npc_status(M.fc_get(ch, "RightWidget"))
        if a or b then
            return M.join_text({ a and trf("Now: %s", a) or "", b and trf("New: %s", b) or "" })
        end
    end
    local out = {}
    for _, k in ipairs({ "RightCaptionWidget", "LeftCaptionWidget" }) do
        local s = M.fc_npc_status(M.fc_get(w, k))
        if s then out[#out + 1] = s end
    end
    return #out > 0 and M.join_text(out) or nil
end
-- the focused row of a path-action list (PurchaselistWidget_C / MonsterListWidget_C):
-- the one whose cursor icon shows, else the one at CursorPosition
M.fc_list_row = function(lw)
    local row, cur
    pcall(function() cur = lw.CursorPosition end)
    pcall(function()
        lw.ActiveListItem:ForEach(function(_, e)
            if row then return end
            local r = e:get()
            if M.fc_shown(M.fc_get(r, "RefIcon_Cursor")) or M.fc_shown(M.fc_get(r, "CursorIcon")) then row = r end
        end)
    end)
    if not row and type(cur) == "number" then
        pcall(function()
            lw.ActiveListItem:ForEach(function(k, e) if k == cur + 1 then row = e:get() end end)
        end)
    end
    return row, cur
end
-- the list's column titles (Column1_Title ... of its ListColumn widget)
M.fc_titles = function(lw)
    local col = M.fc_get(lw, "ListColumn")
    return { M.fc_txt(col, "Column1_Title"), M.fc_txt(col, "Column2_Title"), M.fc_txt(col, "Column3_Title") }
end
-- A row of what a person carries (Purchase / Steal), laid out like the shop's goods:
-- col1 the item, col3 the price or the chance with RefText_Unit (⑳ / %), col2 how many
-- you have; a struck-through row is taken, a greyed one (ItemStatus 1) out of reach.
-- "Heilkraut, 50 Blätter, In Besitz 3" / "Kupferring, Erfolgsrate 34 %, In Besitz 0"
M.fc_purchase_say = function(row, steal, titles)
    local c1 = M.fc_txt(row, "RefText_Col1") or M.fc_txt(row, "Column1_Text")
    if not c1 then return nil end
    local c2 = M.fc_txt(row, "RefText_Col2") or M.fc_txt(row, "Column2_Text")
    local c3 = M.fc_txt(row, "RefText_Col3") or M.fc_txt(row, "Column2_Text_2")
    local un = M.fc_txt(row, "RefText_Unit") or M.fc_txt(row, "Unit_Text")
    local st = M.fc_get(row, "ItemStatus")
    local struck = M.fc_shown(M.fc_get(row, "RefImg_Strikethrough"))
    local lk = string.format("%s|%s|%s|%s|%s|%s", c1, tostring(c2), tostring(c3), tostring(un), tostring(st), tostring(struck))
    M.fc_rows_logged = M.fc_rows_logged or {}
    if not M.fc_rows_logged[lk] then
        M.fc_rows_logged[lk] = true
        log(string.format("FCSCREEN row: col1=%s col2=%s col3=%s unit=%s status=%s struck=%s titles=%s/%s/%s", c1,
            tostring(c2), tostring(c3), tostring(un), tostring(st), tostring(struck), tostring(titles[1]),
            tostring(titles[2]), tostring(titles[3])))
    end
    local price, have = c3, c2
    if not price then price, have = c2, nil end
    local say = c1
    -- Therion's list: column 2 is "Erfolgsrate" ("8%" on screen, no unit text: it said
    -- "8 Blätter", 2026-11-15); Tressa's is "Preis" with the money sign
    local rate = M.gt_label("eFC_STEAL_UI_RATE")
    if steal or un == "%" or (rate and titles[2] == rate) then
        if price then say = say .. ", " .. (rate or "chance") .. " " .. price:gsub("%s*%%$", "") .. " %" end
    elseif price then
        if price:match("^[%d%.,]+$") then
            say = say .. ", " .. price .. " " .. (un or M.MONEY_SIGN)
        else
            say = say .. ", " .. price .. (un and (" " .. un) or "")   -- "Unverkäufl."
        end
    end
    if have then say = say .. ", " .. (M.gt_label("eFC_PURCHASE_UI_HAVEITEM") or tr("on hand")) .. " " .. have end
    if struck then say = say .. ", " .. (steal and tr("stolen") or tr("bought")) end
    if st == 1 then say = trf("%s, unavailable", say) end
    return say
end
-- A row of H'aanit's monsters (ListItemWidget_Col3_2_C): name, how often it can be
-- called (Column2_Text, "--" none), strength stars -- with the list's column titles
M.fc_monster_say = function(row, titles)
    local c1 = M.fc_txt(row, "Column1_Text") or M.fc_txt(row, "RefText_Col1")
    if not c1 then return nil end
    local c2 = M.fc_txt(row, "Column2_Text") or M.fc_txt(row, "RefText_Col2")
    local stars = M.fc_rank(M.fc_get(row, "RankWidget") or M.fc_get(row, "RefRankWidget"))
    local say = c1
    if c2 then say = say .. ", " .. (titles[2] and (titles[2] .. " ") or "") .. c2 end
    if stars then say = say .. ", " .. (titles[3] or M.gt_label("eFC_MONSTER_UI_RANK") or tr("strength")) .. " " .. stars end
    return say
end
-- the chosen monster's panel (MonsterStatusCaptionPartsWidget_C): its skills
M.fc_monster_detail = function(p)
    if not M.fc_shown(p) then return nil end
    local ab = {}
    for _, k in ipairs({ "TextAbility01", "TextAbility02" }) do
        local s = M.fc_txt(p, k)
        if s then ab[#ab + 1] = s end
    end
    if #ab == 0 then return nil end
    local cap = M.fc_txt(p, "NameAbility")
    return (cap and (cap .. ": ") or "") .. table.concat(ab, "; ")
end
M.FC_SCREENS = { FieldCommandPurchase_C = "purchase", FieldCommandMonster_C = "monster",
    FieldCommandLure_C = "lure" }
M.FC_LISTS = { PurchaselistWidget_C = true, MonsterListWidget_C = true }
M.FCS = {}
M.fc_screen_open = function(S)
    local w = S.owner
    local head = M.fc_txt(M.fc_get(w, "PartsMenuHeader"), "CaptionText")
    local st, steal, bm, lure = M.fc_get(w, "State"), M.fc_get(w, "ExecSteal"), M.fc_get(w, "BattleMode"),
        M.fc_get(w, "IsLure")
    S.steal = steal == true or (head ~= nil and head == M.gt_label("eFC_STEAL_HEADER"))
    local parts = {}
    if S.kind == "purchase" then
        head = head or M.gt_label(S.steal and "eFC_STEAL_HEADER" or "eFC_PURCHASE_HEADER")
        parts[#parts + 1] = head
        local lw = M.fc_get(w, "PurchaselistWidget")
        local cap = M.fc_txt(lw, "CaptionText")       -- "Besitz von <name>"
        if cap then parts[#parts + 1] = cap end
        local p = M.fc_get(w, "PlayerStatusPanel")
        local money = (not S.steal) and M.fc_shown(p) and M.fc_txt(p, "TextHaveMoney")
        if money then parts[#parts + 1] = money .. " " .. (M.fc_txt(p, "TextMoneyUnit") or M.MONEY_SIGN) end
    elseif S.kind == "monster" then
        parts[#parts + 1] = head or M.gt_label(bm and "eFC_BATTLE_HEADER" or "eFC_MONSTER_HEADER")
        local s = M.fc_npc_status(M.fc_get(w, "NPCStatusPartsWidget"))
        if s then parts[#parts + 1] = s; S.status_said = s end
    else
        parts[#parts + 1] = head or M.gt_label(lure and "eFC_LURE_HEADER" or "eFC_LEAD_HEADER")
        local s = M.fc_lure_status(w)
        if s then parts[#parts + 1] = s; S.status_said = s end
    end
    log(string.format("FCSCREEN open %s: head=%s state=%s steal=%s battle=%s lure=%s level=%s", S.kind, tostring(head),
        tostring(st), tostring(steal), tostring(bm), tostring(lure), tostring(M.fc_get(w, "FieldCommandLevel"))))
    if #parts > 0 then
        speak(M.join_text(parts), true)
        M.await_first_item = true
    end
end
M.fc_screen_tick = function(S)
    local w, now = S.owner, os.clock()
    local st = M.fc_get(w, "State")
    if st ~= S.state then S.state = st; log(string.format("FCSCREEN %s state %s", S.kind, tostring(st))) end
    local lw = (S.kind == "purchase" and M.fc_get(w, "PurchaselistWidget"))
        or (S.kind == "monster" and M.fc_get(w, "MonsterList")) or nil
    if lw and M.fc_shown(lw) then
        local row = M.fc_list_row(lw)
        local titles = M.fc_titles(lw)
        local say
        if row and S.kind == "purchase" then say = M.fc_purchase_say(row, S.steal, titles)
        elseif row then say = M.fc_monster_say(row, titles) end
        if say and say ~= S.row then
            S.row = say
            M.say_item(say)
            S.more_at = now + 0.3
        end
    end
    -- a panel that shows up later (the opponent once the list closed, a changed follower)
    if S.kind ~= "purchase" then
        local s = (S.kind == "monster") and M.fc_npc_status(M.fc_get(w, "NPCStatusPartsWidget")) or M.fc_lure_status(w)
        if s and s ~= S.status_said then S.status_said = s; speak(s, false) end
    end
    -- after the row: the item's description (help window) / the monster's skills
    if S.more_at and now >= S.more_at then
        S.more_at = nil
        local m
        if S.kind == "purchase" then m = M.ml_help()
        else m = M.fc_monster_detail(M.fc_get(w, "MonsterStatusCaptionPartsWidget")) end
        if m and m ~= S.more_said then S.more_said = m; speak(m, false) end
    end
end
M.poll_fc_screens = function()
    local w, cls = M.get_active_screen()
    local S = M.FCS
    local kind, owner = M.FC_SCREENS[cls or ""], w
    if not kind and M.FC_LISTS[cls or ""] then
        -- its list focused on its own: the screen is the list's owner (owner -> WidgetTree -> list)
        local o
        pcall(function() o = w:GetOuter():GetOuter() end)
        local oc = o and class_name_of(o)
        if oc and M.FC_SCREENS[oc] then kind, owner = M.FC_SCREENS[oc], o
        elseif S.kind and S.owner then kind, owner = S.kind, S.owner end
    end
    if not kind then
        if cls == "UICommonDialogBP_C" then
            if S.kind then S.dlg = true end    -- a question over the screen: it comes back
        elseif S.kind then
            log("FCSCREEN closed")
            M.FCS = {}
        end
        return
    end
    local oa = M.addr_of(owner)
    if S.kind ~= kind or S.addr ~= oa then
        S = { kind = kind, owner = owner, addr = oa }
        M.FCS = S
        -- right after a question closed it is the screen closing (Guide / Allure panels
        -- were said again after "Ja" / "Nein", 2026-11-15): kept quiet
        if M.dlg_closed_t and os.clock() - M.dlg_closed_t < 1.0 then
            S.quiet = true
            log("FCSCREEN " .. kind .. " shows while closing: quiet")
        else
            pcall(M.fc_screen_open, S)
        end
    end
    if S.quiet then return end
    if S.dlg then S.dlg, S.row = nil, nil end   -- back from the question: the row again
    pcall(M.fc_screen_tick, S)
end
-- What goes in front of a path action's question: the item for Purchase / Steal ("Preis:
-- ⑳120. Dieses Objekt kaufen?" says no name), the person's panel for the others unless
-- their screen said it already. The screen is the dialog's owner (dialog -> WidgetTree
-- -> screen), else the one the screen reader saw last.
M.fc_dialog_desc = function(dlg)
    local o, kind
    pcall(function() o = dlg:GetOuter() end)
    for _ = 1, 3 do
        if not o then break end
        local c = class_name_of(o)
        if c and M.FC_SCREENS[c] then kind = M.FC_SCREENS[c]; break end
        local nxt
        pcall(function() nxt = o:GetOuter() end)
        o = nxt
    end
    local S = M.FCS
    if not kind and S.kind and S.owner then
        local ok = false
        pcall(function() ok = S.owner:IsValid() end)
        if ok then o, kind = S.owner, S.kind end
    end
    if not kind and not M.evm_active then
        -- Challenge / Provoke / Guide / Allure ask at once: their person panel sits in the
        -- question ("Wache, Stärke 4 of 10"), owned by a FieldCommandMonster_C (or _Lure_C)
        -- that never had the focus. The running action's type picks the screen class.
        local mgr = get_fcmd_mgr()
        local et = mgr and M.fc_get(mgr, "ExecFieldCommandType")
        local cls = (et == 3 or et == 4) and "FieldCommandMonster_C" or ((et == 5 or et == 6) and "FieldCommandLure_C")
        if cls then
            for _, inst in ipairs(M.ml_list(cls)) do
                local st
                if cls == "FieldCommandMonster_C" then st = M.fc_npc_status(M.fc_get(inst, "NPCStatusPartsWidget"))
                elseif M.fc_shown(inst) then st = M.fc_lure_status(inst) end
                if st then
                    log(string.format("FCSCREEN question over %s (type %s, found by class)", cls, tostring(et)))
                    return st
                end
            end
        end
    end
    if not kind then return nil end
    local same = (M.addr_of(o) == S.addr)
    log(string.format("FCSCREEN question over %s (seen by the screen reader: %s)", kind, tostring(same)))
    if kind == "purchase" then
        local row = M.fc_list_row(M.fc_get(o, "PurchaselistWidget"))
        return row and (M.fc_txt(row, "RefText_Col1") or M.fc_txt(row, "Column1_Text")) or nil
    end
    if same and S.status_said then return nil end
    local s
    if kind == "monster" then s = M.fc_npc_status(M.fc_get(o, "NPCStatusPartsWidget"))
    else s = M.fc_lure_status(o) end
    if s and same then S.status_said = s end
    return s
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
-- The whole enum (ERADARMAP_ICON_TYPE, its display names read from the cooked asset,
-- 2026-11-15): 0 ePLAYER, 1 eSAVEPOINT, 2 eTREASUREBOX, 3 eTHIEF_TREASUREBOX, 4
-- eTREASUREBOX_EMPTY, 5 eTHDDEN_POINT, 6 eMAIN_SCENARIO, 7 eSUB_SCENARIO (a side story:
-- the user found them in Atlasdam by talking to people), 8 eITEM_SHOP, 9 eWEAPON_SHOP,
-- 10 eGENERAL_SHOP, 11 eINN, 12 eMAIN_BAR, 13 eBAR, 14 eMAIN_MAPCHANGE, 15 eMAPCHANGE,
-- 16 eSAVE, 17 eADDMEMBER (a traveler who can join). Chests and shops have their own
-- categories: the marker list leaves 2-4 and 8-13 out.
M.MARKER_KIND = { [1] = N_("save point"), [5] = N_("hidden item"), [6] = N_("objective"), [7] = N_("side story"),
                  [14] = N_("exit toward objective"), [16] = N_("save point"), [17] = N_("traveler to recruit") }
M.MARKER_SKIP = { [0] = true, [2] = true, [3] = true, [4] = true, [8] = true, [9] = true, [10] = true,
                  [11] = true, [12] = true, [13] = true }

-- NEW MARKERS (2026-11-15, user: after talking to people in Atlasdam side stories came
-- up, and Scrutinize revealed hidden items -- maybe with new markers, but nothing said
-- so). While you explore, the radar's icons are compared every 2 s (property reads only,
-- no FindAllOf): one worth walking to (hidden item, objective, side story, exit toward
-- the objective, traveler to recruit) that wasn't there before is said with its
-- direction and distance: "New marker: hidden item, up left, 350". A new icon must show
-- in two checks in a row (the area banner, read every 0.3 s, has caught up by then). Not
-- said: what an area shows when you arrive; anything within 6 s of a teleport (each part
-- of a level has its own icons, and they follow a few seconds late); a set where two or
-- more icons went away at once (another part's icons coming in: 6 s of quiet) or three
-- or more came at once; an icon seen before in this level.
-- The navigator's marker list is rebuilt on its next use, so the new one is in it.
-- GONE ICONS (2026-11-17, user: "the objective takes me here with the walker, but
-- nothing happens"): on the Maiya path the objective was a story event's spot, the walk
-- to the exit beside it crossed the spot, the scene played (Tressa and the pirates'
-- wine), and the game took the objective's icon off the minimap. The navigator's list
-- still had it, and the walker took you to the empty spot. Now an icon gone in two
-- checks in a row, or at once after a pause (a scene, a menu, a battle: the watch
-- doesn't run then, so it can't be a flicker between two checks), makes the marker list
-- stale too, and a goal (objective, side story, traveler to recruit) is said: "Marker
-- gone: objective". Not said while settling (as above: a teleport, another area, two or
-- more icons gone at once).
-- The minimap widget, kept as a checked handle (it is touched every 2 s by the watch).
-- Found again only when it is gone; with `throttle`, at most every that many seconds
-- (FindFirstOf walks the objects too).
M.get_radarmap = function(throttle)
    local h = M.radarmap_h
    if M.handle_ok(h) then
        local ok = false
        pcall(function() ok = h.o:IsValid() end)
        if ok then return h.o end
    end
    M.radarmap_h = nil
    local now = os.clock()
    if throttle and now - (M.radarmap_find_t or -99) < throttle then return nil end
    M.radarmap_find_t = now
    local rm
    pcall(function() local x = FindFirstOf("RadarMap_C"); if x and x:IsValid() then rm = x end end)
    M.radarmap_h = rm and M.handle(rm) or nil
    return M.radarmap_h and rm or nil
end
M.MW = { seen = nil, area = nil, t = 0, pend = {}, gpend = {}, gonekeys = {} }
M.MW_KINDS = { [5] = true, [6] = true, [7] = true, [14] = true, [17] = true }
M.MW_GONE_SAY = { [6] = true, [7] = true, [17] = true }   -- (goals: "Marker gone: objective")
M.marker_watch = function(px, py)
    local W = M.MW
    local now = os.clock()
    if now - W.t < 2.0 then return end
    local gap = now - W.t   -- (well over 2 s: the watch didn't run -- a scene, a menu, a battle)
    W.t = now
    local rm = M.get_radarmap(30)
    if not rm then return end
    local cur, list, sig = {}, {}, {}
    pcall(function()
        rm.RadarIconList:ForEach(function(_, v)
            local w = v:get()
            if not (w and w:IsValid()) then return end
            local t, vis, reg, x, y = 0, false, "", nil, nil
            pcall(function() t = w.IconParam.IconType end)
            pcall(function() vis = w.IconParam.IsVisibility end)
            if type(t) == "number" and t ~= 0 then
                local sk = t .. (vis and "" or "h")   -- h = hidden on the map
                sig[sk] = (sig[sk] or 0) + 1
            end
            if not M.MW_KINDS[t] then return end
            pcall(function() reg = w.IconParam.RegistObjectName:ToString() end)
            pcall(function() x = w.IconParam.Position.X; y = w.IconParam.Position.Y end)
            if not vis or not x then return end
            local key = t .. "|" .. ((reg ~= "" and reg ~= "None") and reg
                or string.format("%d,%d", math.floor(x / 100), math.floor(y / 100)))
            local ic = { key = key, type = t, x = x, y = y }
            cur[key] = ic
            list[#list + 1] = ic
        end)
    end)
    -- one log line whenever the minimap's icons change (type x count, "h" = not shown):
    -- shows what the game changed live, e.g. a chest 2 -> 4 when opened
    local parts = {}
    for k, n in pairs(sig) do parts[#parts + 1] = k .. "x" .. n end
    table.sort(parts)
    local s = table.concat(parts, " ")
    if s ~= W.sig then
        W.sig = s
        log("MARKER icons: " .. s)
    end
    local lvl = M.level_id and M.level_id() or nil
    if lvl and W.lvl and lvl ~= W.lvl then   -- another level: start over, 6 s of quiet
        W.seen, W.settle_until = nil, now + 6.0
        W.prev, W.gpend, W.gonekeys = nil, {}, {}   -- (the last level's icons aren't "gone")
    end
    local settle = W.seen == nil or W.area ~= M.area_said or (M.jump_t and now - M.jump_t < 6.0)
        or now < (W.settle_until or 0)
    if not settle and W.prev then
        local gone = 0
        for k in pairs(W.prev) do if not cur[k] then gone = gone + 1 end end
        if gone >= 2 then
            W.settle_until = now + 6.0
            settle = true
            log("MARKER " .. gone .. " icons gone at once: another part's icons, not said")
        end
    end
    -- icons that went away: still gone a check later, or gone over a pause
    local gone, gpend = {}, {}
    for k, ic in pairs(W.gpend) do
        if not cur[k] then gone[#gone + 1] = ic end   -- (back again: a flicker)
    end
    for k, ic in pairs(W.prev or {}) do
        if not cur[k] then
            if gap > 3.5 then gone[#gone + 1] = ic else gpend[k] = ic end
        end
    end
    W.gpend = gpend
    -- one that went and came back (seen before: not said as new) is missing from a list
    -- rebuilt in between -- stale again
    for k in pairs(W.gonekeys) do
        if cur[k] then
            W.gonekeys[k] = nil
            M.marker_change_t = now
            log("MARKER back: " .. k)
        end
    end
    if #gone > 0 then
        M.marker_change_t = now   -- the navigator's marker list is stale now (NV.list_stale)
        local keys = {}
        for _, ic in ipairs(gone) do keys[#keys + 1] = ic.key; W.gonekeys[ic.key] = true end
        table.sort(keys)
        local say = not settle and #gone == 1 and M.MW_GONE_SAY[gone[1].type]
        log("MARKER gone: " .. table.concat(keys, " ") .. (say and "" or " (not said)"))
        if say then speak(trf("Marker gone: %s", tr(M.MARKER_KIND[gone[1].type] or "marker")), false) end
    end
    if settle then
        W.seen = W.seen or {}
        for k in pairs(cur) do W.seen[k] = true end
        W.pend = {}
    else
        local confirm, pend, tseen = {}, {}, now
        for _, ic in ipairs(list) do
            if not W.seen[ic.key] then
                if W.pend[ic.key] then
                    confirm[#confirm + 1] = ic
                    if W.pend[ic.key] < tseen then tseen = W.pend[ic.key] end
                else
                    pend[ic.key] = now   -- (when first seen)
                end
            end
        end
        W.pend = pend
        for _, ic in ipairs(confirm) do W.seen[ic.key] = true end
        if #confirm > 0 then
            -- the marker list pins icons to people, chests and event spots: scan those
            -- afresh in case the game made a new one for this marker, and let the radar
            -- pick it up too (a revealed hidden item's chest rang only after it was
            -- opened: the next rescan came after the "Erhalten" dialog; user 2026-11-15).
            -- Lists made after the icon showed have it already (the end of a path action
            -- drops them too): those stay, so the game doesn't stall twice.
            local dropped = false
            for _, k in ipairs({ "KSFieldNPCCharacter_C", "TreasureBoxBP_C", "EventTriggerBP_C" }) do
                local c = M.fa_cache[k]
                if c and c.t < tseen - 0.5 then M.fa_cache[k] = nil; dropped = true end
            end
            if dropped and beacon_on then beacon_rescan_at = now + 0.2 end
        end
        if #confirm >= 3 then
            log("MARKER " .. #confirm .. " new icons at once: a changed map, not said")
        elseif px then
            for _, ic in ipairs(confirm) do
                local dx, dy = ic.x - px, ic.y - py
                local s = trf("New marker: %s, %s, %d", tr(M.MARKER_KIND[ic.type] or "marker"),
                    M.nav_dir and M.nav_dir(dx, dy) or "", math.floor(math.sqrt(dx * dx + dy * dy) + 0.5))
                log("MARKER new " .. ic.key)
                speak(s, false)
                M.marker_change_t = now   -- the navigator's marker list is stale now (NV.list_stale)
            end
        end
    end
    W.prev, W.area = cur, M.area_said
    if lvl then W.lvl = lvl end
end

-- The marker kind pinned to an actor (by its object name), or nil. Used to name the
-- talk pick when it has no NPC name (a save point's book). Scans the ~16 icons.
M.marker_kind_of = function(actor)
    local rm = M.get_radarmap()
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
    local rm = M.get_radarmap()
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
            if M.MARKER_SKIP[t] then return end
            icons[#icons + 1] = { type = t, green = green, reg = reg, x = x, y = y }
        end)
    end)
    if #icons == 0 then return M.boss_markers({}) end
    -- Pin every icon to an actor: NPCs by object name (they wander; the icon follows
    -- them), hidden items and exits by name or else the nearest chest / exit trigger.
    -- The actor gives the REAL height. With the player's own z (icons carry X/Y only)
    -- the router searched the wrong floor: "No route found" to the "!" one floor down
    -- (user log 2026-11-13), while the chest category reached the very same spot.
    -- Names repeat across levels (the always-loaded ResidentGame level has its own
    -- KSFieldNPCCharacter_C_46 and so on), so a name gives every actor of it, and the
    -- icon takes the one NEAREST to the icon, and only near it: the save point once
    -- pinned to a nameless actor at Mercedes' counter -- the walker took you to her,
    -- 3224 from the academy door, where the save point had been 2289 away the day
    -- before; the minimap's quill was far off (user report 2026-11-14).
    -- The objective can also be a story event's trigger (EventTriggerBP_C, a spot you
    -- step into): the headmaster's at his office door, a floor up. Without its actor the
    -- marker had the player's own height, and the walker said "Arrived" a floor below
    -- (user report 2026-11-14).
    local byname, npcs, events, chests, pool = {}, {}, {}, {}, { chest = {}, exit = {}, npc = {}, event = {} }
    local specs = { { "KSFieldNPCCharacter_C", "npc" }, { "TreasureBoxBP_C", "chest" },
                    { "LevelTrigger_C", "exit" } }
    for _, ic in ipairs(icons) do   -- (each FindAllOf stalls the game 45-80 ms: only if needed)
        if ic.reg:find("^EventTriggerBP") then specs[#specs + 1] = { "EventTriggerBP_C", "event" }; break end
    end
    for _, spec in ipairs(specs) do
        pcall(function()
            local list = M.find_all(spec[1], 600)
            if not list then return end
            for _, o in pairs(list) do
                local okv = false
                pcall(function() okv = o:IsValid() end)
                if okv then
                    local ax, ay = read_actor_pos(o)
                    if ax then
                        local e = { o = o, x = ax, y = ay }
                        pcall(function()
                            local nm = o:GetFName():ToString()
                            byname[nm] = byname[nm] or {}
                            table.insert(byname[nm], e)
                        end)
                        local t = pool[spec[2]]; t[#t + 1] = e
                    end
                    if spec[2] == "npc" then pcall(function() npcs[o:GetAddress()] = true end) end
                    if spec[2] == "chest" then pcall(function() chests[o:GetAddress()] = true end) end
                    if spec[2] == "event" then pcall(function() events[o:GetAddress()] = true end) end
                end
            end
        end)
    end
    local function nearest(cands, ic, within)
        local best, bd = nil, within
        for _, c in ipairs(cands or {}) do
            local d = math.sqrt((c.x - ic.x) ^ 2 + (c.y - ic.y) ^ 2)
            if d < bd then best, bd = c.o, d end
        end
        return best, bd
    end
    M.pin_logged = M.pin_logged or {}
    local out = {}
    for _, ic in ipairs(icons) do
        local exitish = (ic.type == 14 or ic.type == 15)
        local named = (ic.reg ~= "" and ic.reg ~= "None") and byname[ic.reg] or nil
        local actor, how, pd = nil, "none", nil
        if named then actor, pd = nearest(named, ic, exitish and 600 or 300); how = "name" end
        if not actor then
            -- no actor of that name near the icon: the nearest chest / exit trigger, and for
            -- the save point the nearest NPC (its book is one). Not for marked people: a
            -- bystander next to them would lend the marker a wrong name.
            local cands = (ic.type == 5 and pool.chest) or (exitish and pool.exit)
                or (ic.type == 16 and pool.npc) or nil
            actor, pd = nearest(cands, ic, (ic.type == 5) and 300 or (ic.type == 16) and 150 or 600)
            how = actor and "nearest" or "icon"
        end
        local pk = ic.type .. "|" .. ic.reg .. "|" .. how
        if not M.pin_logged[pk] then
            M.pin_logged[pk] = true
            local full = "-"
            if actor then pcall(function() full = actor:GetFullName() end) end
            log(string.format("MARKER pin type=%d reg=%s (%d of that name) by %s d=%s -> %s icon=(%.0f,%.0f)",
                ic.type, ic.reg, named and #named or 0, how, pd and string.format("%.0f", pd) or "-",
                full, ic.x, ic.y))
        end
        local x, y, z = ic.x, ic.y, pz
        if actor then
            local ax, ay, az = read_actor_pos(actor)
            if ax then x, y, z = ax, ay, az else actor = nil end
        end
        local kind = M.MARKER_KIND[ic.type] or ((ic.type == 14 or ic.type == 15) and "exit toward objective")
        kind = kind and tr(kind) or trf("marker type %d", ic.type)
        local label = kind
        local aaddr = 0
        if actor then pcall(function() aaddr = actor:GetAddress() end) end
        -- a hidden item is a chest the game makes when you learn of it; its "!" stays on
        -- the minimap after you pick it up (2026-11-15: still there a minute later)
        if ic.type == 5 and chests[aaddr] and M.chest_state then
            local okc, opened = pcall(M.chest_state, { addr = aaddr })
            if okc and opened then label = trf("%s, collected", kind) end
        end
        if npcs[aaddr] then
            -- names only for NPCs: NpcName reads the NPC placement label at a fixed
            -- offset -- on a chest or trigger that would be garbage (and a bad FName
            -- can hang GetGameTextString)
            local nm
            pcall(function() nm = shim.NpcName(aaddr) end)
            if nm and nm ~= "" and nm ~= "???" then label = nm .. ", " .. kind end
        end
        if actor and (ic.type == 14 or ic.type == 15) and not npcs[aaddr] then
            local okd, dest, lv = pcall(M.exit_dest, actor)
            if okd and dest then label = trf("%s, to %s", kind, dest) .. (lv and (", " .. lv) or "") end
        end
        -- a story event's spot: the walker walks INTO it (walkcat "event")
        local walkcat = (ic.type == 14 or ic.type == 15) and "exit" or nil
        if events[aaddr] then label, walkcat = trf("%s place", kind), "event" end
        out[#out + 1] = { actor = actor, x = x, y = y, z = z, label = label, walkcat = walkcat }
    end
    return M.boss_markers(out)
end
-- BOSS FIGHTS (user 2026-11-23, the Aashöhlen: the boss has no marker, so there was no
-- way to be led there). An optional dungeon's boss starts as you step into its event box:
-- an EventTriggerBP_C whose PlaceInfo (PlacementInfoData @0x3A0) has EventType_A (@0xCC)
-- 6 -- the placement table's ten "*_LE_000" boxes (here BOX_DClf12_LE_000,
-- DCL12_BIR_010), nine of them without a minimap icon (InvalidRadarIcon). They join the
-- markers as "boss fight", walked into (walkcat "event"). One already pinned to an icon
-- isn't listed twice. Gone once the boss is beaten: the box's SpawnEndFlag (1035 here)
-- keeps it from being placed again, but until the level is loaded again it stays -- so
-- its EventEndFlag_A (@0xD4, the same flag) is asked too (M.boss_beaten).
M.EVT_PLACE, M.EVT_TYPE_A, M.EVT_END_A, M.EVT_BOSS = 0x3A0, 0xCC, 0xD4, 6
M.boss_beaten = function(a)
    local en = shim.Peek(a + M.EVT_PLACE + M.EVT_END_A, "i32")
    if type(en) ~= "number" or en <= 0 then return false end
    local sg = M.save_game()
    if not sg then return false end
    local ok, v = pcall(function() return sg:GetBitFlag(en) end)
    return ok and v == true
end
M.boss_markers = function(out)
    if not (shim and shim.Peek) then return out end
    local have = {}
    for _, m in ipairs(out) do
        if m.actor then pcall(function() have[m.actor:GetAddress()] = true end) end
    end
    for _, o in ipairs(M.find_all("EventTriggerBP_C", 600) or {}) do
        local a = 0
        pcall(function() a = o:GetAddress() end)
        if a ~= 0 and not have[a] and shim.Peek(a + M.EVT_PLACE + M.EVT_TYPE_A, "u8") == M.EVT_BOSS
            and not M.boss_beaten(a) then
            local x, y, z = read_actor_pos(o)
            if x then
                out[#out + 1] = { actor = o, x = x, y = y, z = z, label = tr("boss fight"), walkcat = "event" }
            end
        end
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
    -- a bare name is in /Game/Level/Database; a path ("/Game/Battle/Database/X") as given
    local path = name:find("/", 1, true) and (name .. "." .. name:match("([^/]+)$"))
        or ("/Game/Level/Database/" .. name .. "." .. name)
    pcall(function()
        local o = StaticFindObject(path)
        if o and o:IsValid() then a = o:GetAddress() end
    end)
    if a and a ~= 0 then M.dt_addrs[name] = a; return a end
    return nil
end
-- AN AREA'S LEVEL (user request 2026-11-14: say the recommended level at the exits). Not
-- in the LevelTable (its RecommendMin/MaxLevel are 0 for every field), but in the
-- encounters: LevelInfoData.EncountVolumeNameList (TArray<FName> @0x58) names rows of
-- /Game/Battle/Database/EncountVolumeData (EncountVolume: StartFlag @0, EndFlag @4,
-- EncounterList TArray<EncountData> @0x28), and an EncountData (0x18 each) has
-- ProgressBorder @0, DisplayLevel @4, DangerLevel @8, EncounterName FName @0x10 (object
-- dump). Seen in the flats by Atlasdam: borders 0/2/3/4 with DangerLevel 1/4/7/11 and
-- DisplayLevel 1/1/1/2 (the banner's danger icons, MapDangerWidget_C). The game's
-- CalcEncounterLevel takes the entry by the story progress (KSSaveGame's
-- MainProgressPoint): the last one whose ProgressBorder is not above it.
-- The story progress: the active save game is KSSaveDataManager.SaveGame (object dump),
-- the manager found once (FindAllOf, ~50 ms; the class default object skipped).
M.main_progress = function()
    local sg = M.save_game()
    local p
    if sg then pcall(function() p = sg.MainProgressPoint end) end
    return type(p) == "number" and p or nil
end
-- Level ID -> { display, danger, border, progress } for the story progress now, or nil
-- (no encounters, as in towns). The entries per level are read once (all logged).
M.danger_cache = {}
M.level_danger = function(id)
    if type(id) ~= "number" or id <= 0 or not (shim and shim.DtFind) then return nil end
    local ents = M.danger_cache[id]
    if ents == nil then
        ents = M.level_encounters(id) or false
        M.danger_cache[id] = ents
    end
    if not ents or #ents == 0 then return nil end
    local p = M.main_progress()
    local pick = ents[1]
    for _, e in ipairs(ents) do
        if p and e.border <= p and e.border >= pick.border then pick = e end
    end
    return { display = pick.display, danger = pick.danger, border = pick.border, progress = p }
end
-- the encounter entries of a level's first volume that has any: { {border, display, danger} }
M.level_encounters = function(id)
    local res = false
    pcall(function()
        local lt = M.dt_addr("LevelTable")
        local ev = M.dt_addr("/Game/Battle/Database/EncountVolumeData")
        local kc, kn = M.fname_of(tostring(id))
        local row = lt and kc and shim.DtFind(lt, kc, kn)
        if not (row and ev) then
            log(string.format("DANGER level %d: row=%s volumes table=%s", id, tostring(row), tostring(ev)))
            return
        end
        local arr, cnt = shim.Peek(row + 0x58, "ptr"), shim.Peek(row + 0x60, "i32")
        local seen = {}
        if arr and arr ~= 0 and cnt and cnt > 0 and cnt < 64 then
            for i = 0, cnt - 1 do
                local vc, vn = shim.PeekFName(arr + i * 8)
                local vrow = vc and vc > 0 and shim.DtFind(ev, vc, vn)
                if vrow then
                    local la, ln = shim.Peek(vrow + 0x28, "ptr"), shim.Peek(vrow + 0x30, "i32")
                    local txt, list = {}, {}
                    if la and la ~= 0 and ln and ln > 0 and ln < 64 then
                        for j = 0, ln - 1 do
                            local e = la + j * 0x18
                            local b, dl, dg = shim.Peek(e, "i32"), shim.Peek(e + 4, "i32"), shim.Peek(e + 8, "i32")
                            txt[#txt + 1] = string.format("%s:%s/%s", tostring(b), tostring(dl), tostring(dg))
                            if type(b) == "number" and type(dg) == "number" and dg > 0 and dg < 200 then
                                list[#list + 1] = { border = b, display = dl, danger = dg }
                            end
                        end
                    end
                    if not res and #list > 0 then res = list end
                    seen[#seen + 1] = string.format("%s[%s-%s] %s", M.fname_str(vc, vn),
                        tostring(shim.Peek(vrow, "i32")), tostring(shim.Peek(vrow + 4, "i32")), table.concat(txt, " "))
                end
            end
        end
        log(string.format("DANGER level %d: %d volumes: %s", id, #seen, table.concat(seen, " | ")))
    end)
    return res or nil
end
-- "danger level 4" from an area's encounters for the story so far (nil: no fights
-- there, as in towns)
M.danger_text = function(id)
    local d = M.level_danger(id)
    if not d then return nil end
    log(string.format("DANGER level %d now: danger %d, icons %s (border %d, progress %s)", id, d.danger,
        tostring(d.display), d.border, tostring(d.progress)))
    return trf("danger level %d", d.danger)
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
    -- UE4SS's FName(index) prints a "_0" of its own ("79_0", "eMAP_T_Cliff_M_0": the
    -- route finder missed every row name, 2026-11-14). A base name never ends in "_0" (UE
    -- splits that off into the number), so it goes.
    s = s:gsub("_0$", "")
    if num and num > 0 then s = s .. "_" .. (num - 1) end
    return s
end
M.gametext = function(cmp, num)
    if not (cmp and cmp > 0 and shim and shim.GameTextFName) then return nil end
    local ok, s = pcall(shim.GameTextFName, cmp, num or 0)
    if ok and type(s) == "string" and s ~= "" and s ~= "None" then return s end
    return nil
end
-- a GameText label ("eSHOP_BUY_NUMBER") in the game's language, or nil
M.gt_label = function(label)
    local c, n = M.fname_of(label)
    return c and M.gametext(c, n) or nil
end
-- TownTable: town ID -> TownName label (cmp, num), read once.
-- Level name (the banner's MapNameLabel: "D_Plain_1_1", or a part of a level,
-- "T_Plain_L_B_AreaA") -> the level ID (the LevelTable row whose LevelName it is), or nil.
-- The table is read once.
M.level_id_by_name = function(name)
    if type(name) ~= "string" or name == "" or name == "?" then return nil end
    if not M.level_ids then
        local idx, n = {}, 0
        local lt = shim and shim.DtCount and M.dt_addr("LevelTable")
        if lt then
            for i = 0, (shim.DtCount(lt) or 0) - 1 do
                local rc, rn, row = shim.DtRowAt(lt, i)
                local id = rc and tonumber(M.fname_str(rc, rn))
                if id and row then
                    local lc, ln = shim.PeekFName(row + 0x08)
                    if lc and lc > 0 then idx[M.fname_str(lc, ln)] = id; n = n + 1 end
                end
            end
        end
        log(string.format("LEVELS by name: %d", n))
        if n == 0 then return nil end   -- the table isn't loaded yet: try again next time
        M.level_ids = idx
    end
    return M.level_ids[name] or M.level_ids[(name:gsub("_Area%w+$", ""))]
end
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
        -- (RecommendMinLevel @0x20 / RecommendMaxLevel @0x24 are 0 in every field's row:
        -- the levels come from the encounters, M.level_danger)
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
    -- the destination's level (its encounters: fields and dungeons; towns have none)
    local lv = M.danger_text(id)
    local addr = 0
    pcall(function() addr = actor:GetAddress() end)
    if not M.exit_logged[addr] then
        M.exit_logged[addr] = true
        local on = "?"
        pcall(function() on = actor:GetFName():ToString() end)
        log(string.format("EXIT %s my=%s next=%s map=%s strMap='%s'(%s) strArea='%s'(%s) -> %s (%s)", on, tostring(my),
            tostring(nx), tostring(id), tostring(smap), tostring(nmap), tostring(sarea), tostring(narea), tostring(name),
            tostring(lv)))
    end
    return name, lv
end

-- THE PLAYER'S RADAR SWITCH (user request 2026-11-24: a key to turn the radar off for
-- good, kept over restarts). The game has one: O (MenuRB; its tutorial "Press O to turn
-- the radar on or off") runs RadarMap_C.NextSwitch, which flips the save game's
-- IsRadarMapVisible (KSSaveGameBP_C) and hides the minimap, and RadarMap_C.
-- SetRadarMapVisible reads the flag back -- so the game keeps it in every save and brings
-- it back with each load (cooked bytecode, scripts/bp-disasm.py). The mod's sound radar
-- follows that flag: off = no object pings, no wall tones; the objects stay known
-- (navigator, walker, "objects here") and the bumps, door and talk cues go on. Read
-- every 0.5 s while exploring. A switch right after a read is said at once ("Radar
-- off"); one found after a pause (a load, a scene, a menu) only by the next "objects
-- here", which says "radar off" along as long as it is off.
M.radar_off = false
M.radar_poll = function(now)
    if now - (M.radar_poll_t or -99) < 0.5 or now < (M.radar_retry_at or 0) then return end
    local prev = M.radar_poll_t
    M.radar_poll_t = now
    local sg = M.save_game()
    if not sg then M.radar_retry_at = now + 30; return end   -- (no search every 5 s, ~50 ms each)
    local ok, vis = pcall(function() return sg.IsRadarMapVisible end)
    if not ok or type(vis) ~= "boolean" then return end
    local off = not vis
    if off == M.radar_off and M.radar_known then return end
    local first = not M.radar_known
    M.radar_known = true
    M.radar_off = off
    local live = not first and prev ~= nil and now - prev < 1.5
    log("RADAR the game's radar is " .. (off and "off" or "on") .. (live and " (switched)" or ""))
    if live then speak(off and tr("Radar off") or tr("Radar on"), true) end
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
        if WS.fade and M.handle_ok(WS.fade_h) then pcall(function() fading = WS.fade:IsFadeVisible() end) end
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
            if M.hist_add then pcall(M.hist_add, t) end   -- for the speech history
            if learn_talk_npc then pcall(learn_talk_npc) end
        end
    end
    do
        local ev, ev_play, ev_theater = false, false, false
        if M.trace then log("TR pump event") end
        pcall(function()
            local ef = StaticFindObject("/Script/Octopath_Traveler.Default__EventFunction")
            if ef then
                ev_play = ef:IsEventPlaying() and true or false
                if not ev_play then ev_theater = ef:IsEventPlayTheater() and true or false end
            end
        end)
        ev = ev_play or ev_theater
        if M.trace then log("TR pump battle") end
        -- A BATTLE is no event to the game, but the field must stand still too: the
        -- navigator, walker and radar kept going in battle (user, 2026-11-14).
        -- KSGameStatics:GetBattleMode needs a world object for its context: the
        -- player, else the player controller. Not while the screen fade is up (the
        -- last pump saw it): a load tears the player down then, and a call that hands
        -- UE4SS a freed object faults in IsA, past any pcall (crash 2026-11-15 while
        -- loading a save from the title after a game over). The kept controller is
        -- used only while the shim's reads show the same object (M.handle_ok).
        local battle = M.battle_now or false
        if not M.fade_now then
            battle = false
            pcall(function()
                local gs = StaticFindObject("/Script/Octopath_Traveler.Default__KSGameStatics")
                if not gs then return end
                local ctx = get_player_obj()
                if not ctx then
                    local pc
                    if M.handle_ok(M.pc_h) then
                        pcall(function() if M.pc_h.o:IsValid() then pc = M.pc_h.o end end)
                    end
                    if not pc then
                        M.pc_h = nil
                        local x = FindFirstOf("KSPlayerControllerBP_C")
                        if x and x:IsValid() then pc = x; M.pc_h = M.handle(x) end
                    end
                    ctx = pc
                end
                if ctx then battle = gs:GetBattleMode(ctx) and true or false end
            end)
        end
        if battle ~= (M.battle_now or false) then
            M.battle_now = battle
            M.bt = {}   -- the battle reader starts afresh (enemy list, menus, widget lists)
            log("BATTLE " .. (battle and "started" or "ended"))
            if not battle then M.battle_end_t = now end   -- (the area banner waits: poll_area_name)
        end
        if M.skip_hint_poll then pcall(M.skip_hint_poll, ev, battle, now) end   -- "hold Backspace to skip"
        if battle then ev = true end
        if ev then WS.ev_t = now end
        local settling = false
        if not ev and M.fade_now then
            -- the fade is up (last pump): settling anyway, and the player may be
            -- mid-teardown -- don't ask the game for it (see the battle check above)
            WS.present_since = nil
            settling = true
            WS.why = "fade"
        elseif not ev then
            -- position reads PAUSE during events (scenes teleport the player step by
            -- step; freezing WS.px makes the whole displacement register as ONE jump).
            if M.trace then log("TR pump player") end
            local p = get_player_obj()
            if M.trace then log("TR pump fade") end
            if not p then
                WS.present_since = nil        -- no field player: title / load in progress
                settling = true
                WS.why = "no player"
            else
                if not WS.present_since then WS.present_since = now end
                -- TRANSITION GATE -- the readable "central gate" for load/exit safety.
                -- KSFade:IsFadeVisible() is true whenever the screen fade is up: the
                -- initial load AND walking through an exit, exactly when the player
                -- actor is mid-teardown and read_actor_pos AVs UE4SS (the crash). KSFade
                -- is a PERSISTENT manager, so reading it is safe mid-transition (unlike
                -- the streamed player actor). Cached; only re-found if the handle dies.
                local kf = M.kept(WS.fade_h)   -- (a handle: checked with the shim first)
                if not kf then
                    WS.fade, WS.fade_h = nil, nil
                    pcall(function()
                        local x = FindFirstOf("KSFade")
                        if x and x:IsValid() then WS.fade = x; WS.fade_h = M.handle(x) end
                    end)
                    kf = WS.fade
                end
                local faded, ferr = nil, nil
                if kf then
                    local okf, e = pcall(function() faded = kf:IsFadeVisible() end)
                    if not okf then ferr = tostring(e) end
                end
                -- A KSFade that can't be read -- after loading a save from the title the radar
                -- never came back (2026-11-18, "fade false, settling true" for minutes): the
                -- first one found can be the title world's, not yet freed. Every 2 s the
                -- instances are searched (FindAllOf) for one that answers.
                if kf and faded == nil and now - (WS.fade_seek_t or -99) >= 2.0 then
                    WS.fade_seek_t = now
                    local pick, n = nil, 0
                    pcall(function()
                        for _, x in ipairs(FindAllOf("KSFade") or {}) do
                            n = n + 1
                            local v
                            pcall(function() if x:IsValid() then v = x:IsFadeVisible() end end)
                            if type(v) == "boolean" and not pick then pick, faded = x, v end
                        end
                    end)
                    log(string.format("FADE unreadable (%s): %d KSFade, %s", tostring(ferr or "no answer"), n,
                        pick and ("one answers: " .. tostring(faded)) or "none answers"))
                    if pick then WS.fade, WS.fade_h = pick, M.handle(pick) end
                end
                -- still no answer: go by the player controller -- the character has had the
                -- input for 2 s (a load or an exit takes it away at once, M.ctrl_state)
                if faded == nil then
                    local cm, ci = nil, nil
                    pcall(function() cm, ci = M.ctrl_state() end)
                    if cm == 0 and ci ~= nil and ci ~= 0 then
                        WS.input_ok_t = WS.input_ok_t or now
                        if now - WS.input_ok_t >= 2.0 then
                            faded = false
                            if not WS.fade_fallback then
                                WS.fade_fallback = true
                                log("FADE unreadable: going by the controller (the character has the input)")
                            end
                        end
                    else
                        WS.input_ok_t = nil
                    end
                else
                    WS.input_ok_t, WS.fade_fallback = nil, nil
                end
                local why = nil
                if faded ~= false then
                    settling = true              -- fade up / unreadable / no mgr -> don't poke the world
                    why = (not kf) and "no KSFade" or (faded == nil and "KSFade unreadable" or "fade up")
                elseif now - WS.present_since < 0.5 then
                    settling = true              -- tiny buffer right after the player first appears
                    why = "player just appeared"
                end
                WS.why = why
                if why then
                    -- (blocked for long: say why once, then every 30 s)
                    if why ~= WS.why_said or now - (WS.why_t or -99) > 30 then
                        if why ~= "player just appeared" and why ~= "fade up" then
                            log("SETTLE " .. why)
                            WS.why_said, WS.why_t = why, now
                        end
                    end
                else
                    local px, py, pz = read_actor_pos(p)
                    if px then
                        if WS.px then
                            local dm = math.sqrt((px - WS.px) ^ 2 + (py - WS.py) ^ 2)
                            if dm > 900 then WS.hold = now + 1.0 end
                        end
                        WS.px, WS.py = px, py
                        if pz and M.trail_add then   -- (your trail; a scene may move you)
                            if ev then pcall(M.trail_event) else pcall(M.trail_add, px, py, pz) end
                        end
                    end
                end
            end
        end
        -- does the character have the input? (M.ctrl_state; the wait after an event: M.ev_hold)
        local cmode, cinp
        if not M.fade_now then cmode, cinp = M.ctrl_state() end
        local can_act = nil
        if cmode ~= nil and cinp ~= nil then can_act = (cmode == 0 and cinp ~= 0) end
        local hold = M.ev_hold(WS, now, ev, can_act)
        local susp = ev or settling or (now - WS.ev_t < hold) or (now < WS.hold)
        -- (for the log: you walked while the radar still waited after an event)
        if ev or settling or not susp then
            WS.wait_pos, WS.wait_moved = nil, nil
        elseif WS.px then
            if not WS.wait_pos then
                WS.wait_pos = { WS.px, WS.py }
            elseif not WS.wait_moved then
                local dm = math.sqrt((WS.px - WS.wait_pos[1]) ^ 2 + (WS.py - WS.wait_pos[2]) ^ 2)
                if dm > 30 then
                    WS.wait_moved = true
                    log(string.format("STATE %.3f moved %.0f while the radar waited (event off %.2f s ago)",
                        now, dm, now - WS.ev_t))
                end
            end
        end
        -- menu-read danger flag for the async menu pollers (poll_active_menu /
        -- widget_is_visible). Fade up OR event = scene widgets mid-teardown -> their
        -- IsVisible() ProcessEvent AVs. Deliberately NOT "no field player": the title
        -- screen is stable and its menus must read, so this is fade/event-specific
        -- (narrower than world_susp). WS.fade is nil on the title -> false there.
        local fade_now = false
        if M.trace then log("TR pump fade2") end
        if WS.fade and M.handle_ok(WS.fade_h) then
            pcall(function() fade_now = (WS.fade:IsFadeVisible() == true) end)
        elseif WS.fade then
            WS.fade, WS.fade_h = nil, nil   -- freed (a teardown): unsafe this once, found again later
            fade_now = true
        end
        if M.trace then log("TR pump after") end
        -- A screen fade is always a teardown window. An EVENT is only one IN-GAME
        -- (cutscene) -- on the TITLE screen IsEventPlaying is true (boot/title sequence)
        -- but the menus are stable and must read, so qualify ev with "a field player
        -- exists" (WS.px). Without this the title menu never announces.
        M.menu_unsafe = fade_now or (ev and WS.px ~= nil)
        M.fade_now, M.ev_now = fade_now, (ev and WS.px ~= nil) and true or false   -- M.poll_event_menus
        -- THE STATE PROBE: one line with the time (s, ms) whenever one of the signals that
        -- decide the radar changes -- to see in a log which of them comes back first after
        -- a dialogue, a scene, a battle or a load ("input" = InputMode/IsPlayerCharacterInput)
        do
            local st = string.format("event %s, theater %s, battle %s, fade %s, settling %s%s, input %s/%s",
                tostring(ev_play), tostring(ev_theater), tostring(battle), tostring(fade_now), tostring(settling),
                (settling and WS.why) and (" (" .. WS.why .. ")") or "", tostring(cmode), tostring(cinp))
            if st ~= WS.state then
                WS.state = st
                log(string.format("STATE %.3f %s", now, st))
            end
        end
        -- a confirmed load's fade is up: forget the last area, and say the object count
        -- after it (poll_dialog; M.idle_from can't just be dropped: the radar's moment
        -- "live" before the fade sets it again)
        if M.load_pending and fade_now then
            M.load_pending = nil
            M.area_said = nil
            M.load_resay = true
        end
        world_susp = susp   -- update BEFORE the transition handling below: the
                            -- deferred learn there must see the world as RESUMED
                            -- (it used to re-queue itself forever on stale state)
        if susp ~= WS.susp then
            WS.susp = susp
            if susp then
                log(string.format("RADAR suspended (event/transition) %.3f", now))
            else
                log(string.format("RADAR resumed %.3f (event off %.2f s ago, wait %.2f s%s)", now, now - WS.ev_t, hold,
                    WS.act_since and string.format(", input with the character %.2f s", now - WS.act_since) or ""))
            end
            -- a scene or transition may change the map: the kept object lists go, at
            -- its start and at its end (nothing kept from inside it either) -- except the
            -- level's fixed parts after a scene without a fade (M.fa_set_aside)
            if susp then pcall(M.fa_set_aside) end
            if M.fa_flush then M.fa_flush() end
            if not susp then pcall(M.fa_put_back) end
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
        -- a fade, a missing player or a jump inside the scene: nothing set aside survives
        if WS.susp and M.fa_keep and (fade_now or settling or now < WS.hold) then M.fa_keep = nil end
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
        if M.trace then log("TR pump area/popup") end
        if pump_count % 3 == 0 then pcall(M.poll_area_name) end
        if pump_count % 2 == 1 then pcall(M.poll_action_popup) end
        if M.trace then log("TR pump active") end
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
        -- the title screen: after a game over the old field's player still exists there,
        -- so the radar counted the title as exploring (rescans, wall traces; 2026-11-15)
        if acls and (acls:find("^Title") or acls == "UIMainTitle_C") then menu_open = true end
        -- a confirmed load before its fade: the title's screens are gone, the old world
        -- is still there, and the radar went "live" there for a moment (2026-11-15). Up
        -- to 8 s; the fade normally comes within one.
        if M.load_pending then
            if now - (M.load_pending_t or 0) < 8 then menu_open = true else M.load_pending = nil end
        end
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
                if M.fc_busy_since and M.fa_cache then
                    -- a path action ended: it may have made a hidden item's chest
                    -- (Scrutinize) or taken a person along (Allure, Guide). The radar's
                    -- rescan when exploring resumes then scans these afresh.
                    M.fa_cache["TreasureBoxBP_C"] = nil
                    M.fa_cache["KSFieldNPCCharacter_C"] = nil
                end
                M.fc_busy_since = nil
            end
        end
        if M.trace then log("TR pump vis") end
        if not menu_open then
            for i = 1, #scene_widgets do
                local e = scene_widgets[i]
                if BLOCKING_CLASSES[e[2]] and M.sw_ok(e) and widget_is_visible(e[1]) then menu_open = true; break end
            end
        end
        if M.trace then log("TR pump balloon") end
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
    if not explore then M.unexplore_t = now end   -- (the Backspace that closed a menu: nav_walk_start)
    if explore ~= WS.explore then
        WS.explore = explore
        log("RADAR " .. (explore and "live (exploring)"
            or ("idle (" .. (menu_open and "menu" or (talk_open and "talk" or "scene")) .. ")"))
            .. string.format(" %.3f", now))
        if explore then
            beacon_rescan_at  = now + 0.3                    -- re-enumerate this area
            beacon_rescan_say = (WS.idle_reason ~= "menu") or (M.load_resay == true)   -- announce count on area change / load, not menu close
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
    if M.trace then log("TR pump explore=" .. tostring(explore)) end
    if explore then
        -- lazy audio bring-up on the first field pump
        if WS.px and not audio_inited and not audio_autotry and shim and shim.AudioInit then
            audio_autotry = true
            local okA = false
            pcall(function() okA = shim.AudioInit() end)
            audio_inited = okA and true or false
            if audio_inited then pcall(load_cues); pcall(M.audio_set_ranges) end
            log("Audio auto-init: " .. tostring(okA))
        end
        pcall(M.radar_poll, now)   -- (the player's radar switch, before the pings)
        if audio_inited then
            pcall(bump_step)
            pcall(beacon_step)
            pcall(wall_step)
        end
        pcall(nav_tick)
        pcall(M.interact_poll)   -- talk / path-action hint
        -- new radar markers (a hidden item after Scrutinize, a side story after a talk)
        if WS.px and M.marker_watch then pcall(M.marker_watch, WS.px, WS.py) end
    end
    if pump_count % 30 == 1 then pcall(arm_pump_tickhook) end
    if (beacon_on or wall_on) and pump_count % 64 == 0 then
        log(string.format("PUMP #%d hook=%d loop=%d key=%d", pump_count,
            pump_n.hook or 0, pump_n.loop or 0, pump_n.key or 0))
    end
end
do
    local okl = start_pump_loop()
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
        ExecuteWithDelay(140, function() M.in_gt(function()   -- (game thread)
            if mygen ~= cs_cursor_gen then return end        -- superseded by a newer press
            if dlg_visible then return end                    -- a dialog owns input
            -- Full-map cursor position (on-screen cursor minus map scroll; see
            -- cs_cursor_pos). Announce the hovered traveler / cursor cell.
            local x, y = cs_cursor_pos(inst)
            if x and y then cs_announce(inst, x, y) end
        end) end)
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
