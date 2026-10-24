--[[
  Sound Browser
  -------------
  Lists the game's built-in sounds (the id.Sound table exposed by the plugin
  API) and plays one when you click its name, so you can hear what each
  sound is and pick ones you like. Favourites are saved locally.

  Guideline notes for moderators:
    * Display/preview only. Plays built-in client sounds locally through the
      documented audio.Play(builtinID, params) API. Sends no input, menu
      actions or packets, reads no game state.
    * No permissions.
    * 0.1.29 Music mode: browses every RuneScape music track (names, IDs,
      areas from the RS Wiki track list, rs_music_data.lua) and plays one
      with audio.Play(id, params{type = SoundType.MUSIC}). Prev / Next,
      loop (track / list), shuffle; next track is picked on the tick when
      the current one ends (no os.clock).
    * List is virtualised: a fixed set of row components is rebound on
      paging, so the component count stays small (about 110).
]]

local PLUGIN_NAME = "Sound Browser"
local helpers = require("ui_helpers")
helpers.VERSION = "0.1.30"
local H = helpers

-------------------------------------------------------------------------------
-- Settings
-------------------------------------------------------------------------------
local KEY = "sound_browser"
local state = {}
pcall(function() state = PersistentDB:GetStructuredData(KEY) or {} end)
if type(state) ~= "table" then state = {} end
state.favs = state.favs or {}         -- ["i"..id] = true
-- 0.1.19: volume is always 1.0 (the client mutes any SoundPlaybackParams
-- volume below 1, FAQ 28), so the old Vol setting is dropped. The bus is
-- picked from audio.AudioBus (MASTER by default).
state.vol = nil
state.bus = type(state.bus) == "string" and state.bus or "MASTER"
state.cat = math.tointeger(state.cat) or 1
local function save() pcall(function() PersistentDB:SetStructuredData(KEY, state) end) end
local function busList()
    local L = {}
    pcall(function() for k, v in pairs(audio.AudioBus) do if type(k) == "string" and type(v) == "number" then L[#L + 1] = { k = k, v = v } end end end)
    table.sort(L, function(a, b) return a.v < b.v end)
    local out = {}
    for _, b in ipairs(L) do out[#out + 1] = b.k end
    return out
end
-- Category filter (0.1.19): name prefixes / words in the sound's name.
local CATS = {
    { "All", nil },
    { "Emote", { "emote" } },
    { "Teleport", { "teleport", "tele " } },
    { "Quest", { "quest" } },
    { "Combat", { "combat", "attack", "atk", "hit", "block", "death", "die", "weapon", "sword", "bow", "spell", "magic" } },
    { "Interface", { "interface", "button", "select", "click", "ui " } },
    { "Skilling", { "mining", "woodcut", "fishing", "smith", "craft", "cook", "fletch", "firemaking", "herblore", "farming", "levelup", "level up" } },
}
if state.cat < 1 or state.cat > #CATS then state.cat = 1 end

-------------------------------------------------------------------------------
-- Sound list, read at runtime from the API (no bundled data).
--   1. pairs(id.Sound): every NAME = id entry.
--   2. fallback: id.Sound.FromID(i) for i = 1..MAX_ID, spread over ticks.
-------------------------------------------------------------------------------
local MAX_ID = 62000
-- Display/search form of a name: '_' -> ' ', repeated spaces collapsed, trimmed.
local function spaced(n) return (tostring(n or ""):gsub("_", " "):gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")) end
-- 0.1.19 (review): sentence case for scanning ("Quest bacon pig machine operate")
local function nice(n) local t = string.lower(spaced(n)); return (t:gsub("^%l", string.upper)) end
local function norm(q) return string.lower(spaced(q)) end
local sounds = {}          -- { id = n, name = s, lower = s }
local source = "loading"
local scanNext = nil       -- next id for the FromID fallback, or nil
local filtered = nil       -- array of sound indexes matching the filter

local function sortSounds() table.sort(sounds, function(a, b) return a.id < b.id end) end

local function readTable()
    local ok = pcall(function()
        for k, v in pairs(id.Sound) do
            if type(k) == "string" and type(v) == "number" then
                sounds[#sounds + 1] = { id = v, raw = k, name = nice(k), lower = norm(k) }
            end
        end
    end)
    if ok and #sounds > 0 then
        sortSounds(); source = "id.Sound table"; return true
    end
    sounds = {}
    return false
end

local function scanStep()
    local stop = math.min(MAX_ID, scanNext + 1500)
    for i = scanNext, stop do
        local name = nil
        pcall(function() name = id.Sound.FromID(i) end)
        if type(name) == "string" and name ~= "" then
            sounds[#sounds + 1] = { id = i, raw = name, name = nice(name), lower = norm(name) }
        end
    end
    scanNext = stop + 1
    if scanNext > MAX_ID then
        scanNext = nil
        source = #sounds > 0 and "id.Sound.FromID scan" or "not available"
        return true
    end
    return false
end

if not readTable() then scanNext = 1; source = "scanning" end

-------------------------------------------------------------------------------
-- Music tracks (0.1.29). A runtime id.Music-style table wins if the API ever
-- exposes one; otherwise the bundled RS Wiki list (rs_music_data.lua).
-------------------------------------------------------------------------------
local tracks = {}          -- { id, raw, name, lower, loc, dur, mem }
local musicSource = "not available"
local function loadTracks()
    for _, nm in ipairs({ "Music", "MusicTrack", "Jingle" }) do
        pcall(function()
            local t = id[nm]
            if t ~= nil then
                for k, v in pairs(t) do
                    if type(k) == "string" and type(v) == "number" then
                        tracks[#tracks + 1] = { id = v, raw = k, name = nice(k), lower = norm(k), loc = "", dur = "" }
                    end
                end
            end
        end)
        if #tracks > 0 then musicSource = "id." .. nm .. " table"; return end
        tracks = {}
    end
    local D = nil
    pcall(function() D = require("rs_music_data") end)
    if type(D) ~= "table" then D = rawget(_G, "SB_MUSIC_DATA") end
    if type(D) == "table" then
        for _, r in ipairs(D) do
            if type(r) == "table" and type(r[2]) == "number" then
                local loc = tostring(r[3] or "")
                tracks[#tracks + 1] = { id = r[2], raw = tostring(r[1]), name = tostring(r[1]),
                    lower = norm(tostring(r[1]) .. " " .. loc), loc = loc, dur = tostring(r[4] or ""), mem = r[5] == 1 }
            end
        end
        if #tracks > 0 then musicSource = "RS Wiki track list" end
    end
end
loadTracks()
state.mode = state.mode == "music" and "music" or "sounds"
local function music() return state.mode == "music" end
local function listOf() return music() and tracks or sounds end
local function fk(sid) return (music() and "m" or "i") .. sid end
local MCATS = { { "All", nil }, { "Free-to-play", false }, { "Members", true } }
state.mcat = math.tointeger(state.mcat) or 1
if state.mcat < 1 or state.mcat > #MCATS then state.mcat = 1 end
local LOOPS = { "Loop: off", "Loop: track", "Loop: list" }
state.mloop = math.tointeger(state.mloop) or 3
if state.mloop < 1 or state.mloop > #LOOPS then state.mloop = 3 end

-------------------------------------------------------------------------------
-- Playback
-------------------------------------------------------------------------------
local played = {}     -- id -> true (for Stop all)
local results = {}    -- id -> "playing" / "stopped" / "done" / "nil" / "err"
local insts = {}      -- id -> SoundInstance returned by audio.Play (0.1.1)

local function isPlaying(inst)
    local v = false
    pcall(function() v = inst.isPlaying == true end)
    return v
end

local function play(sid)
    local r = "err"
    pcall(function()
        local p = audio.SoundPlaybackParams.new()
        p.type = audio.SoundType.SCRIPT
        p.audioBus = audio.AudioBus[state.bus] or audio.AudioBus.MASTER
        p.volume = 1.0   -- below 1.0 the client plays nothing (FAQ 28)
        p.numLoops = 0
        p.delayTick = 0
        p.emitterShape = audio.EmitterShape.NONE
        local inst = audio.Play(sid, p)
        insts[sid] = inst
        r = inst ~= nil and "playing" or "nil"
    end)
    results[sid] = r
    played[sid] = true
end

--- Click on a name: stop it if this sound's instance is playing, else play.
local function toggle(sid)
    local inst = insts[sid]
    if inst ~= nil and isPlaying(inst) then
        pcall(function() inst:Stop() end)
        insts[sid] = nil
        results[sid] = "stopped"
    else
        play(sid)
    end
end

--- Called from the tick: clear instances that finished on their own.
local function sweep()
    local changed = false
    for sid, inst in pairs(insts) do
        if not isPlaying(inst) then
            insts[sid] = nil
            if results[sid] == "playing" then results[sid] = "done" end
            changed = true
        end
    end
    return changed
end

-- Music player: one track at a time.
local mus = { cur = nil, pos = nil, inst = nil, seen = false, wait = 0, fails = 0, note = "" }
local filtered_ref = function() return filtered end
local function musStop()
    if mus.inst ~= nil then pcall(function() mus.inst:Stop() end) end
    if mus.cur ~= nil then local c = mus.cur; pcall(function() audio.StopSoundsUsingResource(c) end) end
    mus.inst, mus.cur, mus.seen, mus.wait = nil, nil, false, 0
end
local function musPlay(pos)
    local f = filtered_ref()
    local idx = f and f[pos]
    local t = idx and tracks[idx]
    if t == nil then return end
    musStop()
    local inst = nil
    pcall(function()
        local p = audio.SoundPlaybackParams.new()
        p.type = audio.SoundType.MUSIC
        p.audioBus = audio.AudioBus[state.bus] or audio.AudioBus.MASTER
        p.volume = 1.0   -- below 1.0 the client plays nothing (FAQ 28)
        p.numLoops = 0
        p.delayTick = 0
        p.emitterShape = audio.EmitterShape.NONE
        inst = audio.Play(t.id, p)
    end)
    mus.inst, mus.cur, mus.pos, mus.seen, mus.wait = inst, t.id, pos, false, 0
    mus.name = t.name
    mus.note = inst ~= nil and ("Now playing: " .. t.name) or ("Track " .. t.id .. ": audio.Play returned nothing")
end
local function musStep(dir)
    local f = filtered_ref()
    local n = #(f or {})
    if n == 0 then return end
    local pos
    if state.mshuf and n > 1 then
        repeat pos = math.random(1, n) until pos ~= mus.pos
    else
        pos = ((mus.pos or (dir > 0 and 0 or 1)) + dir - 1) % n + 1
    end
    musPlay(pos)
end
--- Tick (every 5 ticks while a track is up): loop / advance when it ends.
local function musTick()
    if mus.inst == nil then return false end
    if isPlaying(mus.inst) then
        if not mus.seen then mus.seen = true; mus.fails = 0 end
        return false
    end
    mus.wait = mus.wait + 1
    if not mus.seen and mus.wait < 4 then return false end   -- ~2 s to start
    local ended = mus.seen
    mus.inst = nil
    if not ended then
        mus.fails = mus.fails + 1
        mus.note = "Track " .. tostring(mus.cur) .. ": client reports it is not playing"
    else
        mus.note = "Finished: " .. tostring(mus.name or mus.cur)
    end
    mus.cur = nil
    if mus.fails >= 3 then mus.fails = 0; mus.note = "3 tracks in a row did not start; stopped"; return true end
    if not music() then return true end
    if state.mloop == 2 and ended then musPlay(mus.pos)
    elseif state.mloop == 3 then musStep(1) end
    return true
end

local function stopAll()
    musStop()
    for sid, _ in pairs(played) do
        pcall(function() audio.StopSoundsUsingResource(sid) end)
    end
    for sid, inst in pairs(insts) do
        pcall(function() inst:Stop() end)
        results[sid] = "stopped"
    end
    insts = {}
    played = {}
end

-------------------------------------------------------------------------------
-- Panel
-------------------------------------------------------------------------------
local ROWS = 14

-- 0.1.2 column layout, shared by the header and every row. Columns right of
-- Sound are anchored to the right edge; Sound takes what is left and
-- ellipsizes (full name on hover).
local COL_PAD   = 8     -- left/right padding
local COL_GAP   = 8     -- gap between columns
local FAV_W     = 24    -- 0.1.19: star toggle column
local STATUS_W  = 12    -- 0.1.19: gold play triangle, shown only while playing
local ID_W      = 44    -- right-aligned (measured), up to 5 digits
local CTRL_GAP  = 8     -- gap between controls / pager buttons
local ROW_FAV_H = 18    -- Fav button height inside a 20 px row
local PANEL_W   = 480   -- default width: name column about 336 px
local FAV_X, STATUS_X, ID_X, NAME_W
-- 0.1.21: adjustable columns (shared helpers.columns): the Sound/ID border
-- is draggable (or < > buttons); widths persist, Settings resets them.
local cols = nil
local idHandle = nil
local function recalcCols()
    if cols ~= nil then ID_W = cols:get("id") end
    FAV_X    = -(COL_PAD + FAV_W)                -- right-anchored x
    STATUS_X = FAV_X - COL_GAP - STATUS_W
    ID_X     = STATUS_X - COL_GAP - ID_W
    NAME_W   = ID_X - COL_GAP - COL_PAD          -- negative = fill minus this
end
recalcCols()
local headCells, headDiv, rowBgs = {}, nil, {}
local listBg = nil
local BG = { { 0x24/255, 0x21/255, 0x1E/255 }, { 0x2E/255, 0x2A/255, 0x26/255 } }  -- even, odd
local function tw(plain) return helpers.textWidthOf(H.FONT, plain) or (#plain * 7) end
local function commas(n)
    local s2 = tostring(n)
    local k
    repeat s2, k = string.gsub(s2, "^(%d+)(%d%d%d)", "%1,%2") until k == 0
    return s2
end
local page = 1
local rowCells = {}       -- i -> { name, idt, res, fav, sid }
local searchField, volBtn, stopBtn, favOnlyBtn, statusText = nil, nil, nil, nil, nil
local catBtn, copyLbl, copyBox = nil, nil, nil
local modeBtn, mPrev, mPlay, mStop, mNext, mLoop, mShuf, nowText = nil, nil, nil, nil, nil, nil, nil, nil
local MODE_W = 104
local prevB, pageText, nextB = nil, nil, nil
local pagerY = 0
local jumpBtns, jumpRoot, lastJumpW = {}, nil, nil   -- 0.1.13: page jumps
local settingsUI = nil
local filterText, lastFilterSeen = "", nil
local refresh
local placeId, placePager

local function rebuildFilterRaw()
    filtered = {}
    local q = norm(helpers.cleanText(filterText, 64))
    local favOnly = state.favOnly == true
    if music() then
        local want = MCATS[state.mcat] and MCATS[state.mcat][2]
        for i, s in ipairs(tracks) do
            if (q == "" or string.find(s.lower, q, 1, true) or tostring(s.id) == q)
               and (not favOnly or state.favs["m" .. s.id]) and (want == nil or s.mem == want) then
                filtered[#filtered + 1] = i
            end
        end
        return
    end
    local words = CATS[state.cat] and CATS[state.cat][2]
    local function inCat(l)
        if words == nil then return true end
        for _, w in ipairs(words) do if string.find(l, w, 1, true) then return true end end
        return false
    end
    for i, s in ipairs(sounds) do
        if (q == "" or string.find(s.lower, q, 1, true) or tostring(s.id) == q)
           and (not favOnly or state.favs["i" .. s.id]) and inCat(s.lower) then
            filtered[#filtered + 1] = i
        end
    end
end
local function rebuildFilter()
    if not pcall(rebuildFilterRaw) then filtered = {} end
end

local function pages() return math.max(1, math.ceil(#(filtered or {}) / ROWS)) end

local function volLabel() return "Bus: " .. state.bus end
local function favOnlyLabel() return state.favOnly and "Favs only" or (music() and "All tracks" or "All sounds") end

--- ID column: TOPRIGHT text alignment is not honoured, so right-align by
-- measuring: x = column right edge - text width.
placeId = function(c)
    if c.y == nil or c.idt == nil then return end
    local w = math.min(ID_W, math.floor(c.idW or 0))
    helpers.safe(function()
        c.idt:SetSize(w + 2, H.ROW_HEIGHT)
        c.idt:SetPos(ID_X + ID_W - w, c.y, 1.0, 0.0)
    end)
end
--- 0.1.19 standard pager, one centred row:
-- [-100] [-10] [Prev] Page [n] of N [Next] [+10] [+100]; jumps drop out
-- (outermost first) when the panel is too narrow.
local pageLbl, pageBox, pageShown = nil, nil, nil
local PAGE_BOX_W = 48
placePager = function(textW)
    if prevB == nil then return end
    local ow = math.floor(textW or 0) + 4
    local lw = math.floor(tw("Page")) + 6
    local core = 40 + 6 + lw + PAGE_BOX_W + 6 + ow + 6 + 40
    local avail = 300
    pcall(function() avail = jumpRoot.width - 2 * COL_PAD end)
    local J = jumpBtns
    local function jw(a, b) local t = 0; for i = a, b do t = t + J[i].w + 4 end; return t end
    local show = {}
    if #J == 4 and core + jw(1, 4) <= avail then show = { true, true, true, true }
    elseif #J == 4 and core + jw(2, 3) <= avail then show = { false, true, true, false } end
    local total = core
    for i = 1, #J do if show[i] then total = total + J[i].w + 4 end end
    local x = -(total // 2)
    local ty = pagerY
    for i = 1, #J do helpers.setHidden({ J[i].btn }, not show[i]) end
    helpers.safe(function()
        for i = 1, 2 do if show[i] then J[i].btn:SetPos(x, ty, 0.5, 0.0); x = x + J[i].w + 4 end end
        prevB:SetPos(x, ty, 0.5, 0.0); x = x + 46
        pageLbl:SetSize(lw, H.BTN_H); pageLbl:SetPos(x, ty, 0.5, 0.0); x = x + lw
        pageBox:SetPos(x, ty, 0.5, 0.0); x = x + PAGE_BOX_W + 6
        pageText:SetSize(ow, H.BTN_H); pageText:SetPos(x, ty, 0.5, 0.0); x = x + ow + 6
        nextB:SetPos(x, ty, 0.5, 0.0); x = x + 46
        for i = 3, 4 do if show[i] then J[i].btn:SetPos(x, ty, 0.5, 0.0); x = x + J[i].w + 4 end end
    end)
end

local function bindRows()
    for r = 1, ROWS do
        local c = rowCells[r]
        local idx = filtered and filtered[(page - 1) * ROWS + r]
        local s = idx and listOf()[idx]
        c.sid = s and s.id or nil
        local show = s ~= nil
        helpers.setHidden({ c.name, c.idt, c.res, c.fav }, not show)
        helpers.safe(function() rowBgs[r].hidden = not show end)
        if show then
            local fav = state.favs[fk(s.id)] == true
            local on
            if music() then on = mus.cur == s.id else on = results[s.id] == "playing" end
            c.pos = (page - 1) * ROWS + r
            helpers.setText(c.name, (on or fav) and H.gold(s.name) or H.val(s.name))
            c.raw = s.raw
            c.trk = music() and s or nil
            helpers.setText(c.idt, H.lbl(tostring(s.id)))
            c.idW = tw(tostring(s.id)); placeId(c)
            helpers.safe(function() c.res.hidden = not on end)
            helpers.setImage(c.fav, fav and "star_on" or "star_off")
            -- playing row: gold tint
            helpers.safe(function()
                local k = on and { 0x5A/255, 0x4A/255, 0x2A/255 } or BG[(r % 2) + 1]
                rowBgs[r].colour = Vector4.new(k[1], k[2], k[3], on and 0.98 or 0.92)
            end)
        end
    end
    local n = #(filtered or {})
    local first = n == 0 and 0 or (page - 1) * ROWS + 1
    local last = math.min(n, page * ROWS)
    local st = music() and (#tracks == 0 and "No music track list available"
        or (commas(first) .. "-" .. commas(last) .. " of " .. commas(n) .. " tracks (" .. musicSource .. ")"))
        or scanNext ~= nil and ("Reading sound list... " .. commas(#sounds))
        or (#sounds == 0 and "No sounds available"
        or (commas(first) .. "-" .. commas(last) .. " of " .. commas(n) .. " sounds"))
    helpers.setText(statusText, H.lbl(st))
    if nowText ~= nil then helpers.setText(nowText, mus.cur ~= nil and H.gold(mus.note) or H.lbl(mus.note ~= "" and mus.note or "Click a track, or press Play")) end
    if mShuf ~= nil then helpers.setText(mShuf, state.mshuf and "Shuffle: on" or "Shuffle: off", "label") end
    local pt = "of " .. commas(pages())
    helpers.setText(pageText, H.lbl(pt))
    if pageShown ~= page then pageShown = page; helpers.safe(function() pageBox.content = tostring(page) end) end
    placePager(tw(pt))
end

local function goPage(p)
    page = math.max(1, math.min(pages(), p))
    bindRows()
end

-- Column layout for list rows.
local function placeCols(c, y)
    c.y = y
    helpers.safe(function() c.name:SetSize(NAME_W, H.ROW_HEIGHT, 1.0, 0.0); c.name:SetPos(COL_PAD, y) end)
    placeId(c)
    if c.favIsText then
        -- header: "Fav" centred over the button column (measured)
        helpers.safe(function() c.fav:SetPos(FAV_X + (FAV_W - (c.favW or 0)) // 2, y, 1.0, 0.0) end)
    else
        helpers.safe(function() c.res:SetPos(STATUS_X, y + (H.ROW_HEIGHT - STATUS_W) // 2, 1.0, 0.0) end)
        helpers.safe(function() c.fav:SetPos(FAV_X + (FAV_W - ROW_FAV_H) // 2, y + (H.ROW_HEIGHT - ROW_FAV_H) // 2, 1.0, 0.0) end)
    end
end
local function placeRow(c, y, r)
    placeCols(c, y)
    helpers.safe(function()
        local bg = rowBgs[r]; local k = BG[(r % 2) + 1]
        bg.colour = Vector4.new(k[1], k[2], k[3], 0.92)
        bg:SetPos(4, y)
    end)
end

local function layout()
    local y = H.PAD + helpers.TITLE_HEIGHT + 4
    -- line 1: search + filter
    helpers.safe(function() searchField:SetPos(COL_PAD, y) end)
    helpers.safe(function() favOnlyBtn:SetPos(-(COL_PAD + 80), y, 1.0, 0.0) end)
    helpers.safe(function() modeBtn:SetPos(-(COL_PAD + 80 + CTRL_GAP + MODE_W), y, 1.0, 0.0) end)
    y = y + H.BTN_H + CTRL_GAP
    -- line 2: volume, Stop all with equal gaps
    local x = COL_PAD
    for _, b in ipairs({ { volBtn, 140 }, { catBtn, 132 }, { stopBtn, 64 } }) do
        helpers.safe(function() b[1]:SetPos(x, y) end)
        x = x + b[2] + CTRL_GAP
    end
    y = y + H.BTN_H + CTRL_GAP
    -- 0.1.29 music transport line (Music mode only)
    if mPrev ~= nil then
        local hide = not music()
        for _, c in ipairs({ mPrev, mPlay, mStop, mNext, mLoop, mShuf, nowText }) do helpers.safe(function() c.hidden = hide end) end
    end
    if music() then
        local x2 = COL_PAD
        for _, b in ipairs({ { mPrev, 50 }, { mPlay, 50 }, { mStop, 50 }, { mNext, 50 }, { mLoop, 110 }, { mShuf, 92 } }) do
            helpers.safe(function() b[1]:SetPos(x2, y) end)
            x2 = x2 + b[2] + CTRL_GAP
        end
        y = y + H.BTN_H + 4
        helpers.safe(function() nowText:SetPos(COL_PAD, y) end)
        y = y + H.ROW_HEIGHT
    end
    helpers.safe(function() statusText:SetPos(COL_PAD, y) end)
    y = y + H.ROW_HEIGHT
    -- copy row: ready-made snippet for the last clicked sound
    helpers.safe(function() copyLbl:SetPos(COL_PAD, y); copyBox:SetPos(COL_PAD + 44, y) end)
    y = y + H.BTN_H + 4
    placeCols(headCells, y)
    if idHandle then idHandle:place(ID_X - COL_GAP // 2, y, H.ROW_HEIGHT, 1.0, 0.0) end
    y = y + H.ROW_HEIGHT
    helpers.safe(function() headDiv:SetPos(COL_PAD, y) end)
    y = y + 2
    helpers.safe(function()
        listBg:SetPos(4, y)
        listBg:SetSize(-8, ROWS * H.ROW_HEIGHT, 1.0, 0.0)
    end)
    for r = 1, ROWS do
        placeRow(rowCells[r], y, r)
        y = y + H.ROW_HEIGHT
    end
    y = y + CTRL_GAP
    pagerY = y
    bindRows()   -- re-places the pager at its measured width
    y = y + H.BTN_H + 8   -- 8 px clearance under the pager
    if settingsUI ~= nil then
        settingsUI.open = state.editOpen == true
        y = settingsUI:place(y)
    end
    helpers.fitHeight(y + H.PAD)
end

refresh = function()
    helpers.setText(headCells.name, H.gold(music() and "Track" or "Sound"))
    bindRows(); layout(); helpers.refit()
end

local function newText(root, w, align)
    local t = nil
    pcall(function()
        t = ui.Text.new(root)
        t:SetSize(w, H.ROW_HEIGHT, w < 0 and 1.0 or 0.0, 0.0)
        t.font = H.FONT
        t.content = ""
        t:AlignTo(align or ui.AlignMode.TOPLEFT, ui.AlignMode.CENTRE)
        helpers.shadow(t)
    end)
    return t
end

local function buildPanel(root)
    searchField = helpers.input(root, H.PAD, 0, 200, H.BTN_H, "Search name or id")
    pcall(function() searchField:SetSize(-(2 * COL_PAD + 80 + MODE_W + 2 * CTRL_GAP), H.BTN_H, 1.0, 0.0) end)
    helpers.setTip(searchField, function() return music() and "Search track name, area or ID." or "Search sound name or ID." end)
    modeBtn = helpers.dropdown(root, 0, 0, MODE_W, H.BTN_H, { name = "mode",
        options = { "Sounds", "Music" },
        get = function() return music() and 2 or 1 end,
        set = function(i) state.mode = i == 2 and "music" or "sounds"; save() end,
        onChange = function()
            helpers.setText(favOnlyBtn, favOnlyLabel(), "label")
            rebuildFilter(); page = 1; refresh()
        end })
    helpers.setTip(modeBtn.box, function() return "Sounds: the game's built-in sound effects (id.Sound). Music: all " .. commas(#tracks) .. " RuneScape music tracks (" .. musicSource .. ")." end)
    favOnlyBtn = helpers.button(root, 0, 0, 80, H.BTN_H, favOnlyLabel(), function()
        state.favOnly = not state.favOnly; save()
        helpers.setText(favOnlyBtn, favOnlyLabel(), "label")
        rebuildFilter(); goPage(1)
    end)
    do
        local okBus = false
        for _, b in ipairs(busList()) do if b == state.bus then okBus = true end end
        if not okBus then state.bus = "MASTER" end
    end
    -- 0.1.20: Bus and Type are RuneScape-style dropdowns (helpers.dropdown)
    volBtn = helpers.dropdown(root, 0, 0, 140, H.BTN_H, { name = "bus",
        options = function() local L = {}; for i, b in ipairs(busList()) do L[i] = "Bus: " .. b end; return L end,
        get = function() for i, b in ipairs(busList()) do if b == state.bus then return i end end; return 1 end,
        set = function(i) local L = busList(); if L[i] then state.bus = L[i]; save() end end })
    helpers.setTip(volBtn.box, function()
        return "Audio bus for previews: " .. state.bus .. ". MASTER follows only the master volume; SFX, MUSIC, AMBIENT and VOICEOVER follow their own sliders; the *_SUB buses are mixer sub-buses and may be silent. Pick one of the " .. #busList() .. " buses in audio.AudioBus."
    end)
    catBtn = helpers.dropdown(root, 0, 0, 132, H.BTN_H, { name = "cat",
        options = function()
            local L = {}
            for i, c in ipairs(music() and MCATS or CATS) do L[i] = (music() and "Show: " or "Type: ") .. c[1] end
            return L
        end,
        get = function() return music() and state.mcat or state.cat end,
        set = function(i) if music() then state.mcat = i else state.cat = i end; save() end,
        onChange = function() rebuildFilter(); goPage(1) end })
    helpers.setTip(catBtn.box, function()
        if music() then return "Show all tracks, only free-to-play tracks, or only members tracks (RS Wiki data)." end
        local w = CATS[state.cat][2]
        return "Show one kind of sound, matched on words in the name" .. (w and (": " .. table.concat(w, ", ")) or "") .. "."
    end)
    copyLbl = newText(root, 44); helpers.setText(copyLbl, H.lbl("Copy"))
    helpers.safe(function() copyLbl:SetSize(44, H.BTN_H) end)
    copyBox = helpers.input(root, 0, 0, 200, H.BTN_H, "Click a sound: its ID and a Lua snippet appear here")
    helpers.safe(function() copyBox:SetSize(-(2 * COL_PAD + 44), H.BTN_H, 1.0, 0.0) end)
    helpers.setTip(copyBox, "Ready-made code for the last sound you clicked (for alarm sounds in your own plugin). Click, select all, copy.")
    stopBtn = helpers.button(root, 0, 0, 64, H.BTN_H, "Stop all", function() stopAll(); bindRows() end)
    helpers.setTip(stopBtn, "Stop every sound and music track this plugin started.")
    -- 0.1.29 music transport
    local function after() bindRows() end
    mPrev = helpers.button(root, 0, 0, 50, H.BTN_H, "Prev", function() musStep(-1); if mus.pos then goPage(math.ceil(mus.pos / ROWS)) end; after() end)
    helpers.setTip(mPrev, "Previous track in the list (random one when Shuffle is on).")
    mPlay = helpers.button(root, 0, 0, 50, H.BTN_H, "Play", function()
        musPlay(mus.pos or ((page - 1) * ROWS + 1)); after()
    end)
    helpers.setTip(mPlay, "Play the selected track again, or the first track on this page.")
    mStop = helpers.button(root, 0, 0, 50, H.BTN_H, "Stop", function() musStop(); mus.note = "Stopped"; after() end)
    helpers.setTip(mStop, "Stop the music track.")
    mNext = helpers.button(root, 0, 0, 50, H.BTN_H, "Next", function() musStep(1); if mus.pos then goPage(math.ceil(mus.pos / ROWS)) end; after() end)
    helpers.setTip(mNext, "Next track in the list (random one when Shuffle is on).")
    mLoop = helpers.dropdown(root, 0, 0, 110, H.BTN_H, { name = "mloop", options = LOOPS,
        get = function() return state.mloop end, set = function(i) state.mloop = i; save() end })
    helpers.setTip(mLoop.box, "When a track ends: stop (off), play it again (track), or go on to the next one in the list (list).")
    mShuf = helpers.button(root, 0, 0, 92, H.BTN_H, "Shuffle: off", function() state.mshuf = not state.mshuf; save(); after() end)
    helpers.setTip(mShuf, "Shuffle: Next, Prev and Loop: list pick a random track from the current list.")
    nowText = newText(root, -2 * COL_PAD)
    helpers.track(nowText, "content", 2)
    helpers.setTip(nowText, "Volume: the client mutes plugin audio below full volume, so set loudness with the game's slider for the chosen Bus (MUSIC bus = Music slider).")
    statusText = newText(root, -2 * COL_PAD)
    helpers.track(statusText, "content", 2)
    -- header row (same column constants as the rows)
    -- Backgrounds first so they draw above the panel and below the text
    -- (creation order = draw order; no MoveToBack, which put them behind
    -- the panel body in 0.1.2).
    pcall(function()
        listBg = ui.Rectangle.new(root)
        listBg.fill = true
        listBg.colour = Vector4.new(0x1C/255, 0x1A/255, 0x17/255, 0.94)   -- list area: opaque, no chat show-through
    end)
    for r = 1, ROWS do
        pcall(function()
            local bg = ui.Rectangle.new(root)
            bg.fill = true
            bg:SetSize(-8, H.ROW_HEIGHT, 1.0, 0.0)
            bg.hidden = true
            rowBgs[r] = bg
        end)
    end
    headCells = { favIsText = true,
        name = newText(root, NAME_W), idt = newText(root, ID_W),
        fav = newText(root, FAV_W) }
    cols = helpers.columns("sounds", { id = { w = 44, min = 36, max = 160 } }, function()
        recalcCols(); pcall(layout)
    end)
    recalcCols()
    idHandle = cols:handle(root, "id", -1, "Drag to resize the Sound / ID columns (Settings > Column widths > Reset).")
    helpers.setText(headCells.name, H.gold("Sound"))
    helpers.setText(headCells.idt, H.gold("ID")); headCells.idW = tw("ID")
    helpers.setText(headCells.fav, H.gold("Fav")); headCells.favW = tw("Fav")
    helpers.setTip(headCells.fav, "Gold star = favourite. Click a star to add or remove it; favourites are saved on this computer.")
    pcall(function() headCells.fav:SetSize(math.floor(headCells.favW) + 2, H.ROW_HEIGHT) end)
    pcall(function()
        headDiv = ui.Rectangle.new(root)
        headDiv.fill = true
        headDiv:SetSize(-2 * COL_PAD, 1, 1.0, 0.0)
        headDiv.colour = Vector4.new(0.78, 0.70, 0.52, 0.9)   -- light bronze, 90%
    end)
    for r = 1, ROWS do
        local c = {}
        c.name = newText(root, NAME_W)
        helpers.track(c.name, "content", 2)
        c.idt = newText(root, ID_W)
        c.res = helpers.imageButton(root, 0, 0, STATUS_W, "play", nil)   -- playing marker
        helpers.safe(function() c.res.hidden = true end)
        c.fav = helpers.imageButton(root, 0, 0, ROW_FAV_H, "star_off", function()
            if c.sid == nil then return end
            local k = fk(c.sid)
            state.favs[k] = (not state.favs[k]) or nil; save()
            if state.favOnly then rebuildFilter(); goPage(page) else bindRows() end
        end)
        helpers.blockClicks(c.name)
        helpers.setTip(c.name, function()
            if c.sid == nil then return nil end
            local t = c.trk
            if t ~= nil then
                return t.name .. "  (track id " .. c.sid .. ")" .. (t.loc ~= "" and ("\nArea: " .. t.loc) or "")
                    .. (t.dur ~= "" and ("\nLength: " .. t.dur) or "") .. (t.mem ~= nil and (t.mem and "\nMembers" or "\nFree-to-play") or "")
                    .. "\nClick to play, click again to stop."
            end
            return tostring(c.raw or "") .. "  (id " .. c.sid .. "). Click to play, click again to stop."
        end)
        helpers.setTip(c.fav, "Star this sound as a favourite (gold) or remove it (dim).")
        pcall(function()
            c.name:Subscribe(ui.Hook.ONCLICK, "play", function()
                pcall(helpers.raiseWindow)
                if c.sid ~= nil and music() then
                    if mus.cur == c.sid then musStop(); mus.note = "Stopped" else musPlay(c.pos) end
                    local snip = "local p = audio.SoundPlaybackParams.new(); p.type = audio.SoundType.MUSIC; audio.Play(" .. c.sid .. ", p)  -- " .. tostring(c.raw or "")
                    helpers.safe(function() copyBox.content = snip end)
                    bindRows()
                elseif c.sid ~= nil then
                    toggle(c.sid)
                    local snip = "audio.Play(" .. c.sid .. ")  -- " .. tostring(c.raw or "") .. " (bus " .. state.bus .. ": set params.audioBus)"
                    helpers.safe(function() copyBox.content = snip end)
                    bindRows()
                end
            end)
        end)
        rowCells[r] = c
    end
    prevB = helpers.button(root, 0, 0, 40, H.BTN_H, "Prev", function() goPage(page - 1) end)
    pageLbl = newText(root, 40); helpers.setText(pageLbl, H.lbl("Page"))
    pageBox = helpers.input(root, 0, 0, PAGE_BOX_W, H.BTN_H, "1")
    helpers.setTip(pageBox, "Current page. Click, type a page number and press Enter.")
    pcall(function()
        pageBox:Subscribe(ui.Hook.ONCONTENTCHANGED, "sbPage", function(_, cause)
            if cause == ui.InputFieldActionResult.SUBMIT or cause == ui.InputFieldActionResult.SUBMIT_ON_FOCUS_LOSS then
                local t = ""
                pcall(function() t = tostring(pageBox.content or "") end)
                local n = helpers.cleanInt(helpers.cleanText(t, 8), 1, pages())
                pageShown = nil
                if n then goPage(n) else bindRows() end
            end
        end)
    end)
    pageText = newText(root, 60)
    nextB = helpers.button(root, 0, 0, 40, H.BTN_H, "Next", function() goPage(page + 1) end)
    jumpRoot = root
    for _, n in ipairs({ -100, -10, 10, 100 }) do
        local lbl = (n > 0 and "+" or "") .. n
        local w = #lbl * 8 + 14
        jumpBtns[#jumpBtns + 1] = { w = w, btn = helpers.button(root, 0, 0, w, H.BTN_H, lbl, function() goPage(page + n) end) }
    end

    local items = helpers.commonItems(function() refresh() end)
    table.insert(items, 1, { label = "Click a name to play it", options = nil })
    table.insert(items, 2, { labelFn = function()
        local n = 0; for _ in pairs(state.favs) do n = n + 1 end
        return "Favourites: " .. n end, options = { "Clear" },
        get = function() return 1 end,
        set = function() state.favs = {}; save(); rebuildFilter(); goPage(1) end })
    settingsUI = helpers.newSettings(root, items, 6)
    settingsUI.onChange = function() refresh() end
    helpers.editToggle(root, function() return state.editOpen == true end, function(v)
        state.editOpen = v; save(); refresh()
    end)
    rebuildFilter()
    refresh()
end

-------------------------------------------------------------------------------
-- Ticks: finish the FromID scan if needed, watch the search box.
-------------------------------------------------------------------------------
local window = nil
local tick = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "sbLogic", function()
    helpers.tickToast()
    -- 0.1.13: re-wrap the page-jump row when the panel width changes.
    if jumpRoot ~= nil then
        local w = nil
        pcall(function() w = jumpRoot.width end)
        if w ~= nil and w ~= lastJumpW and not helpers.isResizing() then
            if lastJumpW ~= nil then pcall(layout) end
            lastJumpW = w
        end
    end
    if scanNext ~= nil then
        if scanStep() then sortSounds(); rebuildFilter(); if window then refresh() end
        elseif window and tick % 25 == 0 then bindRows() end
    end
    tick = tick + 1
    if window ~= nil and tick % 5 == 0 and next(insts) ~= nil and sweep() then bindRows() end
    if tick % 5 == 0 and mus.inst ~= nil and musTick() and window ~= nil then
        if mus.pos and music() then goPage(math.ceil(mus.pos / ROWS)) else bindRows() end
    end
    if window ~= nil and searchField ~= nil and tick % 10 == 0 then
        local t = ""
        pcall(function() t = tostring(searchField.content or "") end)
        if t ~= lastFilterSeen then
            lastFilterSeen = t
            filterText = t
            rebuildFilter(); goPage(1)
        end
    end
end)

local function tryCreateWindow()
    if window ~= nil then return end
    window = helpers.createWindow(PLUGIN_NAME, PANEL_W, 200, 0.30, 0.15)
    if window ~= nil then
        if not state.w013 then helpers.growWidth(PANEL_W); state.w013 = true; save() end  -- 0.1.3 wider default
        local ok, err = pcall(buildPanel, window)
        helpers.raiseGrip()
        helpers.diag("sounds", { count = #sounds, source = source, tracks = #tracks, musicSource = musicSource })
        if not ok then helpers.log("[" .. PLUGIN_NAME .. "] ERROR building panel: " .. tostring(err)) end
    end
end

tryCreateWindow()

local retryTicks = 0
helpers.subscribe(PLUGIN_NAME, "Logic", "windowRetry", function()
    if window == nil then
        retryTicks = retryTicks + 1
        if retryTicks >= 50 then retryTicks = 0; tryCreateWindow() end
    end
end)

helpers.installRibbon(PLUGIN_NAME)
helpers.log("[" .. PLUGIN_NAME .. "] loaded")

function PluginShutdown()
    stopAll()
    save()
    helpers.destroyToast()
    helpers.destroyWindow()
end
