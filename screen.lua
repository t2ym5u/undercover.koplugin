local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local Blitbuffer      = require("ffi/blitbuffer")
local ButtonTable     = require("ui/widget/buttontable")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local LineWidget      = require("ui/widget/linewidget")
local RenderText      = require("ui/rendertext")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper  = require("menu_helper")
local ScreenBase  = require("screen_base")
local SeenHistory = require("seen_history")
local Game        = lrequire("game")
local PlayersMenu = lrequire("players")

local DeviceScreen = Device.screen

-- ---------------------------------------------------------------------------
-- Text sizing helpers
--
-- Font:getFace() scales its size by the screen DPI, so a size worked out from
-- pixel dimensions has to be divided back first.
-- ---------------------------------------------------------------------------

local DPI_SCALE = DeviceScreen:scaleBySize(1000) / 1000

local function pxFace(px)
    return Font:getFace("cfont", math.max(8, math.floor(px / DPI_SCALE)))
end

-- One line of text at up to `px` pixels, shrunk until it fits `max_w`.
local function fitLine(text, px, max_w, bold)
    local face = pxFace(px)
    while px > 12 do
        local m = RenderText:sizeUtf8Text(0, max_w * 10, face, text, true, bold)
        if m.x <= max_w then break end
        px   = math.floor(px * 0.9)
        face = pxFace(px)
    end
    return TextWidget:new{ text = text, face = face, max_width = max_w, bold = bold }
end

-- A paragraph wrapped to `width`, centred.
local function wrapText(text, face, width, bold)
    return TextBoxWidget:new{ text = text, face = face, width = width, alignment = "center", bold = bold }
end

-- A wrapped paragraph at up to `px`, shrunk until it fits `max_h`.
local function fitBox(text, px, width, max_h, bold)
    local box
    while true do
        box = wrapText(text, pxFace(px), width, bold)
        if box:getSize().h <= max_h or px <= 14 then return box end
        box:free()
        px = math.floor(px * 0.9)
    end
end

-- A centring box that remembers where it was painted, so the countdown can
-- refresh just its own rectangle.
local TimerBox = CenterContainer:extend{}

function TimerBox:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    CenterContainer.paintTo(self, bb, x, y)
end

local TIMER_CHOICES = { 0, 60, 120, 180, 300 }

local GAME_RULES_EN = [[
Undercover — Rules

One reader, 3 to 12 players. Pass it round: each player taps to see their secret, taps again to hide it, and hands the reader on.

UNDERCOVER MODE
• The civilians all get the same word. The undercovers get a close but different word — and nobody knows which side they are on!
• Mr. White (optional, from 5 players) gets no word at all and must bluff.
• In turn, starting with the player shown, everyone says ONE word or short clue about their word. Not too obvious (the undercovers would catch on), not too vague (you'd look suspicious).
• Then debate and vote: tap the player the group eliminates. Their role is revealed.
• An eliminated Mr. White may guess the civilians' word: if he's right, he wins alone.
• Civilians win when every undercover and Mr. White is out. The infiltrators win when only one civilian is left.
• Points: civilians 2 each, undercovers 10 each, Mr. White 6.

SPY MODE
• Everyone sees the same place (and a role), except the spy, who sees nothing.
• Ask each other questions about the place — precise enough to prove you know it, vague enough not to give it away to the spy.
• Then vote. Wrong player: the spy wins (2 points). Spy caught: he gets one last chance to name the place (4 points), otherwise everyone else scores 1.
• At any time the spy may give himself up and name the place.

The optional timer limits the discussion. Scores add up across rounds; "New game" sets them back to zero.
]]

local GAME_RULES_FR = [[
Undercover — Règles

Une liseuse, de 3 à 12 joueurs. Elle fait le tour de la table : chacun touche l'écran pour voir son secret, touche à nouveau pour le cacher, et passe la liseuse au suivant.

MODE UNDERCOVER
• Les civils ont tous le même mot. Les undercovers ont un mot proche mais différent — et personne ne sait dans quel camp il est !
• Mr. White (facultatif, dès 5 joueurs) n'a aucun mot : il doit bluffer.
• À tour de rôle, en commençant par le joueur indiqué, chacun dit UN mot ou un court indice sur son mot. Pas trop évident (les undercovers comprendraient), pas trop vague (vous deviendriez suspect).
• Puis on débat et on vote : touchez le joueur éliminé par le groupe. Son rôle est révélé.
• Mr. White éliminé peut deviner le mot des civils : s'il a raison, il gagne seul.
• Les civils gagnent quand tous les undercovers et Mr. White sont éliminés. Les infiltrés gagnent quand il ne reste qu'un civil.
• Points : 2 par civil, 10 par undercover, 6 pour Mr. White.

MODE ESPION
• Tout le monde voit le même lieu (et un rôle), sauf l'espion, qui ne voit rien.
• Posez-vous des questions sur le lieu — assez précises pour prouver que vous le connaissez, assez floues pour ne pas le livrer à l'espion.
• Puis on vote. Mauvaise cible : l'espion gagne (2 points). Espion démasqué : il a une dernière chance de nommer le lieu (4 points), sinon tous les autres marquent 1 point.
• À tout moment, l'espion peut se dénoncer et tenter de nommer le lieu.

Le chrono (facultatif) limite la discussion. Les scores s'additionnent d'une manche à l'autre ; « Nouvelle partie » les remet à zéro.
]]

-- ---------------------------------------------------------------------------
-- UndercoverScreen
-- ---------------------------------------------------------------------------

local UndercoverScreen = ScreenBase:extend{}

function UndercoverScreen:init()
    local p = self.plugin
    self.lang        = p:getLang({ "fr", "en" })
    self.timer_secs  = p:getSetting("timer", 0)
    self.content     = {}
    self.packs       = self:_loadPackSelection()
    self.showing_secret = false
    self.voting      = false
    self.time_left   = self.timer_secs
    self.timer_running = false

    local state = p:loadState()
    if self:_migrateUsed(state) then
        state.used = nil
        p:saveState(state)
    end
    self.game = Game.load(state)
    if not self.game or #self.game.players < Game.MIN_PLAYERS then
        self.game = Game.new{
            names       = self:_savedNames(),
            mode        = p:getSetting("mode", "undercover"),
            undercovers = p:getSetting("undercovers", "auto"),
            mr_white    = p:getSetting("mr_white", true),
        }
    end

    self.ges_events = {
        TapScreen = { GestureRange:new{ ges = "tap", range = function() return self.dimen end } },
    }
    ScreenBase.init(self)
end

function UndercoverScreen:_savedNames()
    local names = self.plugin:getSetting("names")
    if type(names) ~= "table" or #names < Game.MIN_PLAYERS then
        names = {}
        for i = 1, 5 do names[i] = PlayersMenu.defaultName(i) end
    end
    return names
end

function UndercoverScreen:serializeState()
    return self.game:serialize()
end

function UndercoverScreen:_save()
    self.plugin:saveState(self:serializeState())
end

function UndercoverScreen:_refresh()
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
end

-- Themed packs, each a file per kind and language:
-- content/<lang>/pairs_<pack>.lua and content/<lang>/places_<pack>.lua.
local PACKS = { "history", "geo", "pop", "food", "kids", "mix" }
local PACK_LABELS = {
    history = _("History & legends"),
    geo     = _("Geography & monuments"),
    pop     = _("Pop culture"),
    food    = _("Food"),
    kids    = _("Kids"),
    mix     = _("Mix & laughs"),
}

-- One pack file, loaded on first use and kept for the session (a pack is a
-- few kilobytes; only the packs actually played get loaded).
function UndercoverScreen:_pack(kind, pack, lang)
    local key = (lang or self.lang) .. "/" .. kind .. "_" .. pack
    if not self.content[key] then
        local chunk = loadfile(_dir .. "content/" .. key .. ".lua")
        local ok, t = pcall(chunk or error)
        self.content[key] = (ok and type(t) == "table") and t or {}
    end
    return self.content[key]
end

function UndercoverScreen:_isPackOn(pack)
    return self.packs == nil or self.packs[pack] == true
end

-- The selected packs merged, for the current mode's kind, and the language
-- (the in-memory fallback key of Game:startRound()).
function UndercoverScreen:_content()
    local kind = self.game.mode == "spy" and "places" or "pairs"
    return { [kind] = self:_merged(kind, nil, self.lang) }, self.lang
end

-- `packs`: list of pack ids, nil = the current selection.
function UndercoverScreen:_merged(kind, packs, lang)
    local on = {}
    if packs then
        for _i, pk in ipairs(packs) do on[pk] = true end
    end
    local list = {}
    for _i, pack in ipairs(PACKS) do
        if (packs and on[pack]) or (not packs and self:_isPackOn(pack)) then
            for _j, e in ipairs(self:_pack(kind, pack, lang)) do list[#list + 1] = e end
        end
    end
    return list
end

-- What was dealt, remembered across sessions in the plugin settings, one
-- history per kind and language ("seen_pairs_fr", "seen_places_en"...).
-- A pair or place is not dealt again until every one of the selected packs
-- has been played; then only that selection starts over, the rest of the
-- history (other packs) is kept.
local SEEN_MAX = { pairs = 2000, places = 500 }
local SEEN_ID  = { pairs = Game.pairId, places = Game.placeId }

function UndercoverScreen:_seen(kind, lang)
    lang = lang or self.lang
    self.seen_hist = self.seen_hist or {}
    local key = kind .. "_" .. lang
    if not self.seen_hist[key] then
        self.seen_hist[key] = SeenHistory.open(self.plugin, key,
            { max = SEEN_MAX[kind], id_of = SEEN_ID[kind] })
    end
    return self.seen_hist[key]
end

-- 1.0.x kept the dealt entries in the saved game (`used`, indices into the
-- packs selected then): carry them into the SeenHistory once, so nobody gets
-- the words of last night again. Returns true when the state had some (the
-- caller then saves it without them).
function UndercoverScreen:_migrateUsed(state)
    return Game.migrateLegacyUsed(state,
        function(kind, packs, lang) return self:_merged(kind, packs, lang) end,
        function(kind, lang) return self:_seen(kind, lang) end)
end

function UndercoverScreen:_loadPackSelection()
    local saved = self.plugin:getSetting("packs", "")
    if type(saved) ~= "string" or saved == "" then return nil end
    local sel = {}
    for id in saved:gmatch("[^,]+") do sel[id] = true end
    return sel
end

-- ---------------------------------------------------------------------------
-- Labels
-- ---------------------------------------------------------------------------

local function modeLabel(mode)
    return mode == "spy" and _("Spy") or _("Undercover")
end

local function roleLabel(role)
    if role == "civilian"   then return _("Civilian") end
    if role == "undercover" then return _("Undercover") end
    if role == "mrwhite"    then return _("Mr. White") end
    if role == "spy"        then return _("Spy") end
    return _("Insider")
end

local function timerLabel(secs)
    if secs == 0 then return nil end
    return string.format("%d:%02d", math.floor(secs / 60), secs % 60)
end

function UndercoverScreen:_name(i)
    return self.game.players[i].name
end

-- "4 civilians · 1 undercover · 1 Mr. White"
function UndercoverScreen:_rolesLine()
    local g = self.game
    local n = #g.players
    if g.mode == "spy" then
        return T(_("%1 players, one of them a spy"), n)
    end
    local civ, und, white = g:roleCounts(n)
    return self:joinStatus(
        T(_("Civilians: %1"), civ),
        T(_("Undercovers: %1"), und),
        white > 0 and _("Mr. White") or nil)
end

-- ---------------------------------------------------------------------------
-- Actions
-- ---------------------------------------------------------------------------

function UndercoverScreen:onStartRound()
    local c, key = self:_content()
    local list = self.game.mode == "spy" and c.places or c.pairs
    if #list == 0 then
        self:showMessage(_("No content found for this language."))
        return
    end
    self:_stopCountdown()
    self.game:startRound(c, key, nil, { pairs = self:_seen("pairs"), places = self:_seen("places") })
    self.showing_secret = false
    self.voting = false
    self.time_left = self.timer_secs
    self:_save()
    self:_refresh()
end

-- Next round, scores kept.
function UndercoverScreen:onNextRound()
    self:onStartRound()
end

-- New game: scores back to zero, back to the player list.
function UndercoverScreen:onNewGame()
    self:_stopCountdown()
    self.game:resetScores()
    self.showing_secret = false
    self.voting = false
    self:_save()
    self:_refresh()
end

function UndercoverScreen:onTapScreen()
    if self.game:phase() ~= "deal" then return false end
    if self.showing_secret then self:onHideSecret() else self:onShowSecret() end
    return true
end

function UndercoverScreen:onShowSecret()
    self.showing_secret = true
    self:_refresh()
end

function UndercoverScreen:onHideSecret()
    self.showing_secret = false
    self.game:nextDeal()
    if self.game:phase() == "discuss" then
        self.time_left = self.timer_secs
    end
    self:_save()
    -- A full refresh, so no ghost of the word stays on the e-ink panel.
    self:buildLayout()
    UIManager:setDirty(self, function() return "full", self.dimen end)
end

function UndercoverScreen:onVote()
    self:_stopCountdown()
    self.voting = true
    self:_refresh()
end

function UndercoverScreen:onEliminate(i)
    self.voting = false
    self.game:eliminate(i)
    self:_save()
    self:_refresh()
    self:refreshActionBar()
end

function UndercoverScreen:onSpyDeclares()
    self:_stopCountdown()
    self.game:spyDeclares()
    self:_save()
    self:_refresh()
end

function UndercoverScreen:onGuess()
    local r = self.game.round
    local dialog
    dialog = InputDialog:new{
        title   = r.mode == "spy" and _("Where are we?") or _("The civilians' word is…"),
        input   = "",
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("OK"), is_enter_default = true, callback = function()
                local text = dialog:getInputText()
                UIManager:close(dialog)
                self.game:guess(text)
                self:_save()
                self:_refresh()
                self:refreshActionBar()
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function UndercoverScreen:onAcceptGuess()
    self.game:acceptGuess()
    self:_save()
    self:_refresh()
end

function UndercoverScreen:onContinue()
    self.game:continue()
    self.time_left = self.timer_secs
    self:_save()
    self:_refresh()
end

-- ---------------------------------------------------------------------------
-- Discussion timer: redraws only its own box, once a second
-- ---------------------------------------------------------------------------

function UndercoverScreen:onToggleTimer()
    if self.timer_running then
        self:_stopCountdown()
    else
        if self.time_left <= 0 then self.time_left = self.timer_secs end
        self.timer_running = true
        self._tick_gen = (self._tick_gen or 0) + 1
        local gen = self._tick_gen
        UIManager:scheduleIn(1, function() self:_onTick(gen) end)
    end
    self:_refresh()
end

function UndercoverScreen:_stopCountdown()
    self.timer_running = false
    self._tick_gen = (self._tick_gen or 0) + 1
end

function UndercoverScreen:_onTick(gen)
    if gen ~= self._tick_gen then return end
    self.time_left = math.max(0, self.time_left - 1)
    if self.timer_widget then
        self.timer_widget:setText(timerLabel(self.time_left) or "0:00")
        local box = self.timer_box
        UIManager:setDirty(self, function()
            return "fast", box and box.dimen and Geom:new{
                x = box.dimen.x, y = box.dimen.y, w = box.dimen.w, h = box.dimen.h } or self.dimen
        end)
    end
    if self.time_left <= 0 then
        self:_stopCountdown()
        self:_refresh()
        UIManager:show(InfoMessage:new{ text = _("Time's up — vote!"), timeout = 3 })
    else
        UIManager:scheduleIn(1, function() self:_onTick(gen) end)
    end
end

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

function UndercoverScreen:openLangMenu()
    MenuHelper.openPickerMenu{
        title      = _("Language"),
        items      = { { id = "fr", text = "Français" }, { id = "en", text = "English" } },
        current_id = self.lang,
        parent     = self,
        on_select  = function(lang)
            self.lang = lang
            self.plugin:setLang(lang)
            self:_refresh()
        end,
    }
end

function UndercoverScreen:openPlayersMenu()
    local names = {}
    for i, p in ipairs(self.game.players) do names[i] = p.name end
    PlayersMenu.open{
        names     = names,
        min       = Game.MIN_PLAYERS,
        max       = Game.MAX_PLAYERS,
        parent    = self,
        on_change = function(list) self:_setPlayers(list) end,
    }
end

-- Renaming keeps scores and the round; adding or removing a player starts
-- over from the player list (the roles were dealt for another table).
function UndercoverScreen:_setPlayers(list)
    local g = self.game
    self.plugin:saveSetting("names", list)
    if #list == #g.players then
        for i, name in ipairs(list) do g.players[i].name = name end
    else
        self:_stopCountdown()
        g.players = {}
        for i, name in ipairs(list) do g.players[i] = { name = name, score = 0 } end
        g.round = nil
        self.showing_secret, self.voting = false, false
    end
    self:_save()
    self:_refresh()
end

function UndercoverScreen:openModeMenu()
    MenuHelper.openPickerMenu{
        title      = _("Mode"),
        items      = {
            { id = "undercover", text = _("Undercover") .. " — " .. _("close words, Mr. White") },
            { id = "spy",        text = _("Spy") .. " — " .. _("a place, one spy") },
        },
        current_id = self.game.mode,
        parent     = self,
        on_select  = function(mode)
            self.game.mode = mode
            self.plugin:saveSetting("mode", mode)
            self:_save()
            self:_refresh()
        end,
    }
end

function UndercoverScreen:openUndercoversMenu()
    local auto_civ, auto_und = self.game.undercovers, nil
    local saved = self.game.undercovers
    self.game.undercovers = "auto"
    auto_civ, auto_und = self.game:roleCounts()
    self.game.undercovers = saved
    local items = { { id = "auto", text = T(_("Auto (%1)"), auto_und) } }
    for n = 1, 3 do items[#items + 1] = { id = n, text = tostring(n) } end
    MenuHelper.openPickerMenu{
        title      = _("Undercovers"),
        items      = items,
        current_id = saved,
        parent     = self,
        on_select  = function(v)
            self.game.undercovers = v
            self.plugin:saveSetting("undercovers", v)
            self:_save()
            self:_refresh()
        end,
    }
end

function UndercoverScreen:toggleMrWhite()
    self.game.mr_white = not self.game.mr_white
    self.plugin:saveSetting("mr_white", self.game.mr_white)
    self:_save()
    self:_refresh()
end

function UndercoverScreen:_packsText()
    if self.packs == nil then return T(_("Packs: %1"), _("all")) end
    local n = 0
    for _i, pack in ipairs(PACKS) do if self.packs[pack] then n = n + 1 end end
    return T(_("Packs: %1"), n .. "/" .. #PACKS)
end

-- Multi-select: each tap toggles one pack and re-opens the menu; counts are
-- for the current mode (word pairs or places). The last pack stays on.
function UndercoverScreen:openPacksMenu()
    local kind = self.game.mode == "spy" and "places" or "pairs"
    local items = {}
    for _i, pack in ipairs(PACKS) do
        items[#items + 1] = {
            id   = pack,
            text = (self:_isPackOn(pack) and "✓ " or "○ ") .. PACK_LABELS[pack]
                   .. string.format("  (%d)", #self:_pack(kind, pack)),
        }
    end
    items[#items + 1] = { id = "__all__", text = "★ " .. _("All packs") }
    MenuHelper.openPickerMenu{
        title     = _("Packs"),
        items     = items,
        parent    = self,
        on_select = function(id)
            if id == "__all__" then
                self.packs = nil
            else
                local sel, n = {}, 0
                for _i, pack in ipairs(PACKS) do
                    if self:_isPackOn(pack) then sel[pack] = true end
                end
                sel[id] = not sel[id] or nil
                for _i, pack in ipairs(PACKS) do if sel[pack] then n = n + 1 end end
                if n == 0 then
                    self:showMessage(_("Keep at least one pack."))
                    self:openPacksMenu()
                    return
                end
                self.packs = n < #PACKS and sel or nil
            end
            local parts = {}
            for _i, pack in ipairs(PACKS) do
                if self.packs and self.packs[pack] then parts[#parts + 1] = pack end
            end
            self.plugin:saveSetting("packs", table.concat(parts, ","))
            self:_refresh()
            self:openPacksMenu()
        end,
    }
end

function UndercoverScreen:openTimerMenu()
    local items = {}
    for _i, s in ipairs(TIMER_CHOICES) do
        items[#items + 1] = { id = s, text = timerLabel(s) or _("No timer") }
    end
    MenuHelper.openPickerMenu{
        title      = _("Timer"),
        items      = items,
        current_id = self.timer_secs,
        parent     = self,
        on_select  = function(s)
            self:_stopCountdown()
            self.timer_secs = s
            self.time_left  = s
            self.plugin:saveSetting("timer", s)
            self:_refresh()
        end,
    }
end

function UndercoverScreen:_undercoversText()
    local _c, und = self.game:roleCounts()
    if self.game.undercovers == "auto" then
        return T(_("Undercovers: %1"), T(_("Auto (%1)"), und))
    end
    return T(_("Undercovers: %1"), und)
end

function UndercoverScreen:_titleBar()
    return self:buildTitleBar(_("Undercover"), function()
        local g = self.game
        local items = {
            { text = _("New game"), callback = function() self:onNewGame() end },
            { text = T(_("Language: %1"), self.lang:upper()), callback = function() self:openLangMenu() end },
            { text = T(_("Players: %1"), #g.players), callback = function() self:openPlayersMenu() end },
            { text = T(_("Mode: %1"), modeLabel(g.mode)), callback = function() self:openModeMenu() end },
            { text = self:_packsText(), callback = function() self:openPacksMenu() end },
        }
        if g.mode == "undercover" then
            items[#items + 1] = { text = self:_undercoversText(), callback = function() self:openUndercoversMenu() end }
            items[#items + 1] = { text = g.mr_white and _("Mr. White: yes") or _("Mr. White: no"),
                                  callback = function() self:toggleMrWhite() end }
        end
        items[#items + 1] = {
            text = self.timer_secs > 0 and T(_("Timer: %1"), timerLabel(self.timer_secs)) or _("Timer: none"),
            callback = function() self:openTimerMenu() end,
        }
        items[#items + 1] = self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR)
        return items
    end)
end

-- ---------------------------------------------------------------------------
-- Round over
-- ---------------------------------------------------------------------------

function UndercoverScreen:isRoundOver()
    return self.game:isOver()
end

-- "Next round" keeps the scores going; "New game" zeroes them.
function UndercoverScreen:getRoundOverButtons()
    local next_btn = { text = _("Next round"), callback = function() self:onNextRound() end }
    local new_btn  = { text = _("New game"),   callback = function() self:onNewGame() end }
    -- The landscape side panel is too narrow for both labels side by side.
    if self:isLandscape() then return { { next_btn }, { new_btn } } end
    return { next_btn, new_btn }
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function UndercoverScreen:buildLayout()
    local phase = self.game:phase()
    local builder
    if phase == "setup" then builder = self._setupView
    elseif phase == "deal" then
        builder = self.showing_secret and self._secretView or self._handoverView
    elseif phase == "discuss" then
        builder = self.voting and self._voteView or self._discussView
    elseif phase == "eliminated" then builder = self._eliminatedView
    else builder = self._overView end

    self.timer_widget, self.timer_box = nil, nil
    local rows, make_content = builder(self)
    local title_bar = self:_titleBar()
    local controls  = self:_buildControls(rows)
    local bw, bh = self:getBoardBudget(title_bar, controls)
    local content = make_content(bw, bh)
    self:_placeLayout(title_bar, content, controls)
    self[1] = self.layout
    self:updateStatus()
end

function UndercoverScreen:_buildControls(rows)
    self.status_text:setMaxWidth(self:getControlsWidth())
    -- The landscape side panel is narrow: one button per row keeps labels
    -- like "Start round" whole instead of shrinking them to a squint.
    if self:isLandscape() then
        if rows[1] and rows[1].text then rows = { rows } end
        local flat = {}
        for _i, row in ipairs(rows) do
            for _j, btn in ipairs(row) do flat[#flat + 1] = { btn } end
        end
        rows = flat
    end
    return VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar(rows),
    }
end

function UndercoverScreen:_placeLayout(title_bar, content, controls)
    if self:isLandscape() then
        self:buildLandscapeLayout(title_bar, HorizontalGroup:new{
            align = "center",
            content,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        })
    else
        self:buildPortraitLayout(title_bar, content,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
end

-- French counts 0 and 1 as singular ("0 pt", "1 pt"); the other
-- languages only 1.
local function singular(n)
    if _.lang() == "fr" then return n >= -1 and n <= 1 end
    return n == 1 or n == -1
end

local function vspan(h) return VerticalSpan:new{ width = h } end

local function rule(w)
    return LineWidget:new{
        background = Blitbuffer.COLOR_DARK_GRAY,
        dimen      = Geom:new{ w = math.floor(w * 0.5), h = Size.line.medium },
    }
end

local function cardFrame(group, w)
    local pad = Size.padding.large
    return FrameContainer:new{
        padding = pad,
        margin  = 0,
        bordersize = Size.border.window,
        CenterContainer:new{
            dimen = Geom:new{ w = w - 2 * (pad + Size.border.window), h = group:getSize().h },
            group,
        },
    }
end

-- One line per player: "Alice   12" (names in seating order).
function UndercoverScreen:_scoreboard(bw, max_h, extra)
    local lines = {}
    for i, p in ipairs(self.game.players) do
        local s = p.name
        if extra then s = s .. extra(i) end
        lines[#lines + 1] = T(singular(p.score) and _("%1 — %2 pt") or _("%1 — %2 pts"), s, p.score)
    end
    local face_px = math.floor(math.min(bw * 0.06, max_h / (#lines * 1.5)))
    return fitBox(table.concat(lines, "\n"), face_px, bw, max_h)
end

function UndercoverScreen:_setupView()
    local rows = {
        { text = _("Players"), callback = function() self:openPlayersMenu() end },
        { text = _("Start round"), callback = function() self:onStartRound() end },
    }
    return rows, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        local head = VerticalGroup:new{
            align = "center",
            fitLine(modeLabel(self.game.mode):upper(), short * 0.11, bw, true),
            vspan(vs),
            wrapText(self:_rolesLine(), Font:getFace("infofont"), bw),
            vspan(vs * 2),
            rule(bw),
            vspan(vs * 2),
        }
        local board = self:_scoreboard(bw, bh - head:getSize().h)
        return VerticalGroup:new{ align = "center", head, board }
    end
end

function UndercoverScreen:_handoverView()
    local r = self.game.round
    local i = r.deal_index
    local rows = {
        { text = T(_("I'm %1 — show"), self:_name(i)), callback = function() self:onShowSecret() end },
    }
    return rows, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        return VerticalGroup:new{
            align = "center",
            wrapText(_("Pass the reader to"), pxFace(short * 0.06), bw),
            vspan(vs * 2),
            fitLine(self:_name(i), short * 0.15, bw, true),
            vspan(vs * 2),
            wrapText(T(_("Secret %1 of %2"), i, #self.game.players), Font:getFace("infofont"), bw),
            vspan(vs * 4),
            wrapText(_("Nobody else looks!\nTap the screen when you're ready."), pxFace(short * 0.05), bw),
        }
    end
end

function UndercoverScreen:_secretView()
    local g = self.game
    local i = g.round.deal_index
    local last = i >= #g.players
    local rows = {
        { text = last and _("Hide — start the discussion") or _("Hide and pass on"),
          callback = function() self:onHideSecret() end },
    }
    return rows, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        local inner = bw - 2 * (Size.padding.large + Size.border.window)
        local secret = g:secretFor(i)
        local group
        if secret.kind == "word" then
            group = VerticalGroup:new{
                align = "center",
                wrapText(_("Your word:"), pxFace(short * 0.05), inner),
                vspan(vs * 2),
                fitLine(secret.word, short * 0.13, inner, true),
                vspan(vs * 2),
            }
        elseif secret.kind == "mrwhite" then
            group = VerticalGroup:new{
                align = "center",
                fitLine(_("You are Mr. White!"), short * 0.09, inner, true),
                vspan(vs * 2),
                wrapText(_("You have no word. Listen to the others, give a clue that blends in, and try to work out the civilians' word."),
                    pxFace(short * 0.045), inner),
            }
        elseif secret.kind == "spy" then
            group = VerticalGroup:new{
                align = "center",
                fitLine(_("You are the spy!"), short * 0.1, inner, true),
                vspan(vs * 2),
                wrapText(_("You don't know the place. Listen, ask innocent questions, don't get caught — and work out where everybody is."),
                    pxFace(short * 0.045), inner),
            }
        else
            local parts = {
                align = "center",
                wrapText(_("The place:"), pxFace(short * 0.05), inner),
                vspan(vs * 2),
                fitBox(secret.place, short * 0.09, inner, bh * 0.4, true),
                vspan(vs * 2),
            }
            if secret.role then
                parts[#parts + 1] = rule(inner)
                parts[#parts + 1] = vspan(vs * 2)
                parts[#parts + 1] = wrapText(T(_("Your role: %1"), secret.role), pxFace(short * 0.055), inner)
            end
            group = VerticalGroup:new(parts)
        end
        return VerticalGroup:new{
            align = "center",
            fitLine(g.players[i].name, short * 0.07, bw),
            vspan(vs * 2),
            cardFrame(group, bw),
            vspan(vs * 2),
            wrapText(_("Tap to hide."), Font:getFace("smallinfofont"), bw),
        }
    end
end

function UndercoverScreen:_discussView()
    local g = self.game
    local r = g.round
    local rows = { {} }
    if self.timer_secs > 0 then
        rows[1][#rows[1] + 1] = {
            text = self.timer_running and _("Pause timer") or _("Start timer"),
            callback = function() self:onToggleTimer() end,
        }
    end
    rows[1][#rows[1] + 1] = { text = _("Vote"), callback = function() self:onVote() end }
    if r.mode == "spy" then
        rows[1][#rows[1] + 1] = { text = _("The spy gives up"), callback = function() self:onSpyDeclares() end }
    end
    return rows, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        local parts = { align = "center" }
        local how = r.mode == "spy"
            and _("Take turns asking each other questions about the place. Then vote for the spy.")
            or  _("Each player in turn gives ONE word about their secret word. Then debate and vote.")
        if r.starter then
            parts[#parts + 1] = wrapText(_("First to speak:"), pxFace(short * 0.05), bw)
            parts[#parts + 1] = vspan(vs)
            parts[#parts + 1] = fitLine(self:_name(r.starter), short * 0.12, bw, true)
            parts[#parts + 1] = vspan(vs * 2)
        end
        parts[#parts + 1] = wrapText(how, pxFace(short * 0.045), bw)
        if self.timer_secs > 0 then
            parts[#parts + 1] = vspan(vs * 2)
            self.timer_widget = TextWidget:new{
                text = timerLabel(self.time_left) or "0:00",
                face = pxFace(short * 0.14),
            }
            self.timer_box = TimerBox:new{
                dimen = Geom:new{ w = bw, h = self.timer_widget:getSize().h },
                self.timer_widget,
            }
            parts[#parts + 1] = self.timer_box
        end
        parts[#parts + 1] = vspan(vs * 3)
        parts[#parts + 1] = rule(bw)
        parts[#parts + 1] = vspan(vs * 2)
        local names = {}
        for _i, idx in ipairs(g:aliveList()) do names[#names + 1] = self:_name(idx) end
        local used = 0
        for _i, w in ipairs(parts) do used = used + w:getSize().h end
        parts[#parts + 1] = fitBox(T(_("Still in: %1"), table.concat(names, "\u{00A0}· ")),
            short * 0.045, bw, math.max(40, bh - used))
        return VerticalGroup:new(parts)
    end
end

function UndercoverScreen:_voteView()
    local g = self.game
    local rows = { { text = _("Back"), callback = function() self.voting = false; self:_refresh() end } }
    return rows, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        local alive = g:aliveList()
        local cols = (#alive > 8 and 3) or 2
        -- Names big enough to read across the table; ButtonTable sizes are
        -- DPI-scaled, hence the division.
        local font_size = math.floor(short * (cols == 3 and 0.045 or 0.055) / DPI_SCALE)
        local btn_h = math.floor(short * 0.13)
        local btn_rows, row = {}, {}
        for k, idx in ipairs(alive) do
            row[#row + 1] = { text = self:_name(idx), font_size = font_size, height = btn_h,
                              callback = function() self:onEliminate(idx) end }
            if #row == cols or k == #alive then
                while #row < cols do row[#row + 1] = { text = "", enabled = false, height = btn_h } end
                btn_rows[#btn_rows + 1] = row
                row = {}
            end
        end
        local head = VerticalGroup:new{
            align = "center",
            fitLine(_("Vote: who's eliminated?"), short * 0.07, bw, true),
            vspan(vs),
            wrapText(_("Tap the player the group votes out."), Font:getFace("infofont"), bw),
            vspan(vs * 3),
        }
        return VerticalGroup:new{
            align = "center",
            head,
            ButtonTable:new{ width = bw, buttons = btn_rows },
        }
    end
end

function UndercoverScreen:_eliminatedView()
    local g = self.game
    local r = g.round
    local name = self:_name(r.last)
    local role = r.roles[r.last]
    local rows
    if r.pending_guess then
        rows = { { text = r.mode == "spy" and _("The spy names the place") or _("Mr. White guesses"),
                   callback = function() self:onGuess() end } }
    else
        rows = { { text = _("Continue"), callback = function() self:onContinue() end } }
    end
    return rows, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        local parts = { align = "center" }
        if r.declared then
            parts[#parts + 1] = fitLine(T(_("%1 is the spy!"), name), short * 0.09, bw, true)
        else
            parts[#parts + 1] = fitLine(T(_("%1 is out!"), name), short * 0.09, bw, true)
            parts[#parts + 1] = vspan(vs * 2)
            parts[#parts + 1] = wrapText(T(_("Role: %1"), roleLabel(role)), pxFace(short * 0.065), bw, true)
        end
        parts[#parts + 1] = vspan(vs * 3)
        local msg
        if r.pending_guess then
            msg = r.mode == "spy"
                and _("Last chance: if the spy names the place, the spy wins.")
                or  _("Last chance: if Mr. White finds the civilians' word, he wins alone.")
        elseif r.guess then
            msg = T(_("“%1” — wrong guess. The game goes on!"), r.guess.text)
        else
            msg = _("The game goes on: a new round of clues.")
        end
        parts[#parts + 1] = wrapText(msg, pxFace(short * 0.05), bw)
        return VerticalGroup:new(parts)
    end
end

local function winnerText(r)
    local w = r.winner
    if w == "civilians"    then return _("The civilians win!") end
    if w == "infiltrators" then return _("The infiltrators win!") end
    if w == "mrwhite"      then return _("Mr. White wins!") end
    if w == "spy"          then return _("The spy wins!") end
    return _("The spy is caught!")
end

function UndercoverScreen:_overView()
    local g = self.game
    local r = g.round
    return { { text = _("Next round"), callback = function() self:onNextRound() end } }, function(bw, bh)
        local short = math.min(bw, bh)
        local vs = Size.span.vertical_large
        local parts = { align = "center", fitLine(winnerText(r), short * 0.09, bw, true), vspan(vs * 2) }
        local reveal
        if r.mode == "spy" then
            reveal = T(_("The place: %1"), r.place)
            if r.guess then
                reveal = reveal .. "\n" .. T(r.guess.correct and _("The spy said “%1”: right!")
                    or _("The spy said “%1”: wrong."), r.guess.text)
            end
        else
            reveal = T(_("Civilians: %1"), r.word_civ) .. "\n" .. T(_("Undercovers: %1"), r.word_und)
            if r.guess and r.guess.correct then
                reveal = reveal .. "\n" .. T(_("Mr. White found it: “%1”"), r.guess.text)
            end
        end
        parts[#parts + 1] = wrapText(reveal, pxFace(short * 0.05), bw)
        -- The program judged the spy's wording wrong: the group may overrule.
        if r.mode == "spy" and r.guess and not r.guess.correct then
            parts[#parts + 1] = vspan(vs)
            parts[#parts + 1] = ButtonTable:new{ width = math.floor(bw * 0.7), buttons = {{
                { text = _("Close enough: accept the guess"), callback = function() self:onAcceptGuess() end },
            }} }
        end
        parts[#parts + 1] = vspan(vs * 2)
        parts[#parts + 1] = rule(bw)
        parts[#parts + 1] = vspan(vs * 2)
        local used = 0
        for _i, w in ipairs(parts) do used = used + w:getSize().h end
        parts[#parts + 1] = self:_scoreboard(bw, bh - used, function(i)
            local gain = r.awarded and r.awarded[i]
            return " (" .. roleLabel(r.roles[i]) .. (gain and gain > 0 and (", +" .. gain) or "") .. ")"
        end)
        return VerticalGroup:new(parts)
    end
end

-- ---------------------------------------------------------------------------
-- Status bar
-- ---------------------------------------------------------------------------

function UndercoverScreen:updateStatus(msg)
    if msg then ScreenBase.updateStatus(self, msg); return end
    local g = self.game
    local phase = g:phase()
    local text
    if phase == "setup" then
        text = self:joinStatus(T(_("Players: %1"), #g.players), modeLabel(g.mode), self.lang:upper())
    elseif phase == "deal" then
        text = self:joinStatus(modeLabel(g.round.mode), T(_("Secret %1 of %2"), g.round.deal_index, #g.players))
    elseif phase == "over" then
        local best = g:ranking()[1]
        text = self:joinStatus(T(_("Round %1"), g.rounds), T(_("Leader: %1"), self:_name(best)))
    else
        text = self:joinStatus(T(_("Round %1"), g.rounds), modeLabel(g.round.mode),
            T(_("Players left: %1"), #g:aliveList()))
    end
    ScreenBase.updateStatus(self, text)
end

function UndercoverScreen:onClose()
    self:_stopCountdown()
    ScreenBase.onClose(self)
end

function UndercoverScreen:onCloseWidget()
    self:_stopCountdown()
end

return UndercoverScreen
