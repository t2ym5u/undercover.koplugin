-- ---------------------------------------------------------------------------
-- Undercover game logic (pure Lua, no UI -- testable headless)
--
-- Two modes:
--   "undercover": civilians share word A, 1-3 undercovers get a close word B
--                 (they don't know they are undercover), an optional
--                 Mr. White gets no word. Rounds of clues and votes until one
--                 side wins.
--   "spy":        everybody sees the same place (and a role), except the spy.
--                 One vote: catch the spy, who may still win by naming the
--                 place.
--
-- A round goes through phases:
--   deal       -- the reader goes round, each player sees their secret
--   discuss    -- clues / questions, then a vote
--   eliminated -- the voted player's role is revealed (maybe a last guess)
--   over       -- a side has won, scores are added
-- ---------------------------------------------------------------------------

local Game = {}
Game.__index = Game

Game.MIN_PLAYERS = 3
Game.MAX_PLAYERS = 12

-- Points, as in the usual app version of the game.
Game.POINTS = {
    civilian_win   = 2,   -- every civilian, when all infiltrators are out
    undercover_win = 10,  -- every undercover, when infiltrators win
    white_survives = 6,   -- Mr. White, still in when infiltrators win
    white_guess    = 6,   -- Mr. White, guessing the civilians' word
    spy_escapes    = 2,   -- the spy, when the group votes out someone else
    spy_guess      = 4,   -- the spy, naming the place
    agent_win      = 1,   -- every non-spy, when the spy is caught and fails
}

-- ---------------------------------------------------------------------------
-- Lenient text comparison (case-, accent- and punctuation-insensitive)
-- ---------------------------------------------------------------------------

local ACCENTS = {
    ["à"]="a", ["â"]="a", ["ä"]="a", ["á"]="a", ["ã"]="a", ["å"]="a",
    ["À"]="a", ["Â"]="a", ["Ä"]="a", ["Á"]="a", ["Ã"]="a", ["Å"]="a",
    ["ç"]="c", ["Ç"]="c",
    ["é"]="e", ["è"]="e", ["ê"]="e", ["ë"]="e",
    ["É"]="e", ["È"]="e", ["Ê"]="e", ["Ë"]="e",
    ["î"]="i", ["ï"]="i", ["í"]="i", ["ì"]="i",
    ["Î"]="i", ["Ï"]="i", ["Í"]="i", ["Ì"]="i",
    ["ô"]="o", ["ö"]="o", ["ó"]="o", ["ò"]="o", ["õ"]="o", ["ø"]="o",
    ["Ô"]="o", ["Ö"]="o", ["Ó"]="o", ["Ò"]="o", ["Õ"]="o", ["Ø"]="o",
    ["ù"]="u", ["û"]="u", ["ü"]="u", ["ú"]="u",
    ["Ù"]="u", ["Û"]="u", ["Ü"]="u", ["Ú"]="u",
    ["ÿ"]="y", ["ý"]="y", ["Ÿ"]="y", ["Ý"]="y",
    ["ñ"]="n", ["Ñ"]="n",
    ["œ"]="oe", ["Œ"]="oe", ["æ"]="ae", ["Æ"]="ae", ["ß"]="ss",
}

local ARTICLES = {
    le = true, la = true, les = true, l = true, un = true, une = true,
    des = true, du = true, the = true, a = true, an = true,
}

-- "L'Œuf-de-Pâques !" -> "oeuf de paques"
function Game.normalize(s)
    s = tostring(s or "")
    s = s:gsub("[\xC2-\xF4][\x80-\xBF]*", function(ch) return ACCENTS[ch] or " " end)
    s = s:lower():gsub("[^%w]", " ")
    local words = {}
    for w in s:gmatch("%S+") do words[#words + 1] = w end
    while #words > 1 and ARTICLES[words[1]] do table.remove(words, 1) end
    return table.concat(words, " ")
end

local function levenshtein(a, b)
    local la, lb = #a, #b
    if la == 0 then return lb end
    if lb == 0 then return la end
    local prev, cur = {}, {}
    for j = 0, lb do prev[j] = j end
    for i = 1, la do
        cur[0] = i
        local ca = a:byte(i)
        for j = 1, lb do
            local cost = (ca == b:byte(j)) and 0 or 1
            cur[j] = math.min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
        end
        prev, cur = cur, prev
    end
    return prev[lb]
end

-- True when `guess` names `answer`, forgiving case, accents, articles,
-- spacing and a typo (one letter off from 5 letters, two from 10).
function Game.matches(guess, answer)
    local g, a = Game.normalize(guess), Game.normalize(answer)
    if g == "" then return false end
    if g == a then return true end
    g, a = g:gsub(" ", ""), a:gsub(" ", "")
    if g == a then return true end
    local tol = (#a >= 10 and 2) or (#a >= 5 and 1) or 0
    return levenshtein(g, a) <= tol
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- opts: names (list), mode, undercovers ("auto" or 1..3), mr_white (bool)
function Game.new(opts)
    opts = opts or {}
    local self = setmetatable({
        mode        = opts.mode or "undercover",
        undercovers = opts.undercovers or "auto",
        mr_white    = opts.mr_white and true or false,
        players     = {},
        used        = {},   -- content index -> true, so a session doesn't repeat
        rounds      = 0,
        round       = nil,
    }, Game)
    for i, name in ipairs(opts.names or {}) do
        self.players[i] = { name = name, score = 0 }
    end
    return self
end

function Game:playerCount()
    return #self.players
end

-- Civilians, undercovers, Mr. White for this many players with the current
-- settings. Infiltrators always stay a minority, so a vote can still matter.
function Game:roleCounts(n)
    n = n or #self.players
    local und = self.undercovers
    if und == "auto" then
        und = (n <= 5 and 1) or (n <= 8 and 2) or 3
    end
    und = math.max(1, math.min(3, und))
    local white = (self.mr_white and n >= 4) and 1 or 0
    while und + white >= n - (und + white) and und > 1 do und = und - 1 end
    if und + white >= n - (und + white) then white = 0 end
    return n - und - white, und, white
end

-- ---------------------------------------------------------------------------
-- Rounds
-- ---------------------------------------------------------------------------

local function shuffle(t, rng)
    for i = #t, 2, -1 do
        local j = rng(i)
        t[i], t[j] = t[j], t[i]
    end
    return t
end

-- Pick an unused entry index of `list`, forgetting the used set once every
-- entry has been played.
function Game:_pickIndex(list, key, rng)
    self.used[key] = self.used[key] or {}
    local used = self.used[key]
    local free = {}
    for i = 1, #list do
        if not used[i] then free[#free + 1] = i end
    end
    if #free == 0 then
        self.used[key] = {}
        used = self.used[key]
        for i = 1, #list do free[i] = i end
    end
    local idx = free[rng(#free)]
    used[idx] = true
    return idx
end

-- content: { pairs = { {a, b}, ... }, places = { {place, role, ...}, ... } }
-- key: a string identifying the content (language), for the no-repeat set.
function Game:startRound(content, key, rng)
    rng = rng or math.random
    local n = #self.players
    assert(n >= Game.MIN_PLAYERS, "not enough players")
    local r = {
        mode       = self.mode,
        roles      = {},
        sub_roles  = {},
        alive      = {},
        phase      = "deal",
        deal_index = 1,
        order      = {},     -- eliminated player indices, in order
    }
    local slots = {}
    if self.mode == "spy" then
        local list = content.places
        local idx = self:_pickIndex(list, (key or "") .. ":places", rng)
        local entry = list[idx]
        r.place = entry[1]
        slots[1] = "spy"
        for i = 2, n do slots[i] = "agent" end
        local roles = {}
        for i = 2, #entry do roles[#roles + 1] = entry[i] end
        shuffle(roles, rng)
        shuffle(slots, rng)
        local k = 0
        for i = 1, n do
            r.roles[i] = slots[i]
            if slots[i] == "agent" and #roles > 0 then
                k = k + 1
                r.sub_roles[i] = roles[(k - 1) % #roles + 1]
            end
        end
    else
        local list = content.pairs
        local idx = self:_pickIndex(list, (key or "") .. ":pairs", rng)
        local pair = list[idx]
        if rng(2) == 1 then
            r.word_civ, r.word_und = pair[1], pair[2]
        else
            r.word_civ, r.word_und = pair[2], pair[1]
        end
        local civ, und, white = self:roleCounts(n)
        for _ = 1, civ   do slots[#slots + 1] = "civilian"   end
        for _ = 1, und   do slots[#slots + 1] = "undercover" end
        for _ = 1, white do slots[#slots + 1] = "mrwhite"    end
        shuffle(slots, rng)
        for i = 1, n do r.roles[i] = slots[i] end
    end
    for i = 1, n do r.alive[i] = true end
    self.round = r
    self.rounds = self.rounds + 1
    r.starter = self:_pickStarter(rng)
    return r
end

-- Who speaks first: a random player still in, never Mr. White (he would
-- have nothing to say) nor the spy (asking the first question would give
-- him away less, but the classic rule is that he never opens).
function Game:_pickStarter(rng)
    local r = self.round
    local cands = {}
    for i = 1, #self.players do
        if r.alive[i] and r.roles[i] ~= "mrwhite" and r.roles[i] ~= "spy" then
            cands[#cands + 1] = i
        end
    end
    if #cands == 0 then return nil end
    return cands[(rng or math.random)(#cands)]
end

-- What player i sees when they reveal their secret.
--   { kind = "word", word }          civilian or undercover
--   { kind = "mrwhite" }             no word
--   { kind = "spy" }                 no place
--   { kind = "place", place, role }  spy mode, everyone else
function Game:secretFor(i)
    local r = self.round
    local role = r.roles[i]
    if role == "civilian"   then return { kind = "word", word = r.word_civ } end
    if role == "undercover" then return { kind = "word", word = r.word_und } end
    if role == "mrwhite"    then return { kind = "mrwhite" } end
    if role == "spy"        then return { kind = "spy" } end
    return { kind = "place", place = r.place, role = r.sub_roles[i] }
end

-- The current player has seen (and hidden) their secret.
function Game:nextDeal()
    local r = self.round
    if r.phase ~= "deal" then return end
    r.deal_index = r.deal_index + 1
    if r.deal_index > #self.players then
        r.phase = "discuss"
    end
end

function Game:aliveList()
    local list = {}
    for i = 1, #self.players do
        if self.round and self.round.alive[i] then list[#list + 1] = i end
    end
    return list
end

function Game:_counts()
    local r = self.round
    local civ, inf = 0, 0
    for i = 1, #self.players do
        if r.alive[i] then
            local role = r.roles[i]
            if role == "civilian" or role == "agent" then civ = civ + 1 else inf = inf + 1 end
        end
    end
    return civ, inf
end

-- The group votes player i out. Returns their role.
function Game:eliminate(i)
    local r = self.round
    if not r or r.phase ~= "discuss" or not r.alive[i] then return nil end
    r.alive[i] = false
    r.order[#r.order + 1] = i
    r.last = i
    r.guess = nil
    r.phase = "eliminated"
    local role = r.roles[i]
    if r.mode == "spy" then
        if role == "spy" then
            r.pending_guess = true
        else
            self:_finish("spy", "spy_escapes")
        end
    elseif role == "mrwhite" then
        r.pending_guess = true
    else
        self:_checkWinner()
    end
    return role
end

-- Spy mode: the spy reveals himself before the vote and tries to name the
-- place (Spyfall's "stop the clock" move).
function Game:spyDeclares()
    local r = self.round
    if not r or r.mode ~= "spy" or r.phase ~= "discuss" then return end
    for i = 1, #self.players do
        if r.roles[i] == "spy" then
            r.last = i
            r.declared = true
        end
    end
    r.phase = "eliminated"
    r.pending_guess = true
    r.guess = nil
end

-- The eliminated Mr. White (or the spy) guesses. Returns true when right.
-- `force` accepts the guess anyway (the group judged it close enough).
function Game:guess(text, force)
    local r = self.round
    if not r or not r.pending_guess then return nil end
    r.pending_guess = false
    local answer = r.mode == "spy" and r.place or r.word_civ
    local ok = force or Game.matches(text, answer)
    r.guess = { text = text, correct = ok and true or false }
    if r.mode == "spy" then
        if ok then self:_finish("spy", "spy_guess")
        else self:_finish("agents") end
    elseif ok then
        self:_finish("mrwhite")
    else
        self:_checkWinner()
    end
    return ok
end

-- Spy mode: after a wrong automatic match the group may decide the spy's
-- wording named the right place after all.
function Game:acceptGuess()
    local r = self.round
    if not (r and r.mode == "spy" and r.guess and not r.guess.correct) then return end
    self:_unscore()
    r.guess.correct = true
    r.winner = nil
    self:_finish("spy", "spy_guess")
end

function Game:_checkWinner()
    local r = self.round
    local civ, inf = self:_counts()
    if inf == 0 then
        self:_finish("civilians")
    elseif civ <= 1 then
        self:_finish("infiltrators")
    end
end

-- Award points and end the round. Remembers what was awarded so a judged
-- guess can be re-scored.
function Game:_finish(winner, how)
    local r = self.round
    r.winner = winner
    r.phase  = "over"
    r.awarded = {}
    local P = Game.POINTS
    local function give(i, pts)
        self.players[i].score = self.players[i].score + pts
        r.awarded[i] = (r.awarded[i] or 0) + pts
    end
    for i = 1, #self.players do
        local role = r.roles[i]
        if winner == "civilians" and role == "civilian" then
            give(i, P.civilian_win)
        elseif winner == "infiltrators" then
            if role == "undercover" then give(i, P.undercover_win)
            elseif role == "mrwhite" and r.alive[i] then give(i, P.white_survives) end
        elseif winner == "mrwhite" and role == "mrwhite" then
            give(i, P.white_guess)
        elseif winner == "spy" and role == "spy" then
            give(i, P[how or "spy_escapes"])
        elseif winner == "agents" and role == "agent" then
            give(i, P.agent_win)
        end
    end
end

function Game:_unscore()
    local r = self.round
    for i, pts in pairs(r.awarded or {}) do
        self.players[i].score = self.players[i].score - pts
    end
    r.awarded = {}
end

-- Back to the clues after an elimination that didn't end the round.
function Game:continue(rng)
    local r = self.round
    if not r or r.phase ~= "eliminated" or r.pending_guess then return end
    r.phase = "discuss"
    r.guess = nil
    r.starter = self:_pickStarter(rng)
end

function Game:phase()
    return self.round and self.round.phase or "setup"
end

function Game:isOver()
    return self.round ~= nil and self.round.phase == "over"
end

function Game:resetScores()
    for _, p in ipairs(self.players) do p.score = 0 end
    self.round = nil
    self.rounds = 0
end

-- Players ranked by score (stable on ties: seating order).
function Game:ranking()
    local idx = {}
    for i = 1, #self.players do idx[i] = i end
    table.sort(idx, function(a, b)
        local sa, sb = self.players[a].score, self.players[b].score
        if sa ~= sb then return sa > sb end
        return a < b
    end)
    return idx
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end

-- Keys of r.roles etc. are player indices; LuaSettings keeps numeric keys,
-- but `used` sets are stored as lists to stay compact.
function Game:serialize()
    local used = {}
    for key, set in pairs(self.used) do
        local l = {}
        for i in pairs(set) do l[#l + 1] = i end
        table.sort(l)
        used[key] = l
    end
    return {
        mode = self.mode, undercovers = self.undercovers, mr_white = self.mr_white,
        players = copy(self.players), used = used, rounds = self.rounds,
        round = copy(self.round),
    }
end

function Game.load(data)
    if type(data) ~= "table" or type(data.players) ~= "table" then return nil end
    local self = Game.new{ mode = data.mode, undercovers = data.undercovers, mr_white = data.mr_white }
    for i, p in ipairs(data.players) do
        self.players[i] = { name = tostring(p.name or "?"), score = tonumber(p.score) or 0 }
    end
    for key, l in pairs(data.used or {}) do
        self.used[key] = {}
        for _, i in ipairs(l) do self.used[key][i] = true end
    end
    self.rounds = tonumber(data.rounds) or 0
    self.round  = copy(data.round)
    local r = self.round
    if r then
        if type(r.roles) ~= "table" or type(r.alive) ~= "table" then
            self.round = nil
        else
            r.sub_roles = r.sub_roles or {}
            r.order     = r.order or {}
        end
    end
    return self
end

return Game
