-- busted spec for the Undercover game logic and content.
-- Run from the plugin dir: busted test_game_spec.lua
package.path = "./?.lua;./common/?.lua;" .. package.path
local Game = dofile("game.lua")
local SeenHistory = require("seen_history")

-- Plugin settings stand-in (getSetting/saveSetting), kept between "sessions".
local function fakePlugin()
    local store = {}
    return {
        store = store,
        getSetting  = function(_self, k, d) if store[k] == nil then return d end return store[k] end,
        saveSetting = function(_self, k, v) store[k] = v end,
    }
end

local PACKS = { "history", "geo", "pop", "food", "kids", "mix" }

local function content(lang)
    local c = { pairs = {}, places = {} }
    for _, pack in ipairs(PACKS) do
        for _, kind in ipairs({ "pairs", "places" }) do
            for _, e in ipairs(dofile("content/" .. lang .. "/" .. kind .. "_" .. pack .. ".lua")) do
                table.insert(c[kind], e)
            end
        end
    end
    return c
end

-- Names that must never appear in the content: figures mainly known for
-- genocide, terrorism, mass murder or dictatorship, serial killers, and
-- living politicians. Whole words on normalised text.
local EXCLUDED = {
    "hitler", "nazi", "nazis", "staline", "stalin", "pol pot", "ben laden", "bin laden",
    "mussolini", "mao zedong", "mao tse toung", "pinochet", "kim jong", "saddam",
    "kadhafi", "gaddafi", "idi amin", "attila", "gengis khan", "genghis khan",
    "landru", "eventreur", "ripper", "ceausescu", "franco", "himmler", "goebbels",
    "macron", "sarkozy", "hollande", "trump", "biden", "poutine", "putin", "le pen",
    "melenchon", "obama", "zelensky", "xi jinping", "erdogan",
}

-- " text " with whole-word padding, so "franco" doesn't hit "francophone".
local function hasExcluded(text)
    local t = " " .. Game.normalize(text) .. " "
    for _, name in ipairs(EXCLUDED) do
        if t:find(" " .. name .. " ", 1, true) then return name end
    end
end

local function names(n)
    local t = {}
    for i = 1, n do t[i] = "P" .. i end
    return t
end

local function indexOf(g, role)
    for i = 1, #g.players do
        if g.round.roles[i] == role then return i end
    end
end

local function dealAll(g)
    for _ = 1, #g.players do g:nextDeal() end
end

describe("content", function()
    for _, lang in ipairs({ "fr", "en" }) do
        it("has >= 1000 distinct " .. lang .. " word pairs", function()
            local c = content(lang)
            assert.is_true(#c.pairs >= 1000, #c.pairs)
            local seen = {}
            for _, p in ipairs(c.pairs) do
                assert.equals(2, #p)
                local a, b = Game.normalize(p[1]), Game.normalize(p[2])
                assert.are_not.equal(a, b)
                local k = a < b and (a .. "|" .. b) or (b .. "|" .. a)
                assert.is_nil(seen[k], k)
                seen[k] = true
            end
        end)
        it("has >= 300 distinct " .. lang .. " places with roles", function()
            local c = content(lang)
            assert.is_true(#c.places >= 300, #c.places)
            local seen = {}
            for _, p in ipairs(c.places) do
                assert.is_true(#p >= 3, p[1])
                local k = Game.normalize(p[1])
                assert.is_nil(seen[k], p[1])
                seen[k] = true
            end
        end)
        it("has every " .. lang .. " pack non-empty and nothing excluded", function()
            for _, pack in ipairs(PACKS) do
                for _, kind in ipairs({ "pairs", "places" }) do
                    local list = dofile("content/" .. lang .. "/" .. kind .. "_" .. pack .. ".lua")
                    assert.is_true(#list >= 40, kind .. "_" .. pack)
                    for _, e in ipairs(list) do
                        for _, w in ipairs(e) do
                            assert.is_nil(hasExcluded(w), w)
                        end
                    end
                end
            end
        end)
    end
end)

describe("lenient matching", function()
    it("ignores case, accents, articles and punctuation", function()
        assert.is_true(Game.matches("napoleon", "Napoléon"))
        assert.is_true(Game.matches("  LA TOUR EIFFEL ", "Tour Eiffel"))
        assert.is_true(Game.matches("tour-eiffel", "tour Eiffel"))
        assert.is_true(Game.matches("creme brulee", "Crème brûlée"))
        assert.is_true(Game.matches("oeuf", "Œuf"))
        assert.is_true(Game.matches("the titanic", "Le Titanic"))
    end)
    it("forgives one typo on longer words only", function()
        assert.is_true(Game.matches("camenbert", "Camembert"))
        assert.is_false(Game.matches("rat", "Chat"))
        assert.is_false(Game.matches("brie", "Camembert"))
        assert.is_false(Game.matches("", "Paris"))
    end)
end)

describe("role counts", function()
    it("keeps infiltrators a minority", function()
        for n = 3, 12 do
            for _, und in ipairs({ "auto", 1, 2, 3 }) do
                local g = Game.new{ names = names(n), undercovers = und, mr_white = true }
                local civ, u, w = g:roleCounts()
                assert.equals(n, civ + u + w)
                assert.is_true(u >= 1)
                assert.is_true(civ > u + w, n .. "/" .. tostring(und))
            end
        end
    end)
    it("has no Mr. White under 5 players", function()
        local _, _, w = Game.new{ names = names(4), mr_white = true }:roleCounts()
        assert.equals(0, w)
        local _, _, w5 = Game.new{ names = names(5), mr_white = true }:roleCounts()
        assert.equals(1, w5)
    end)
end)

describe("undercover round", function()
    local c = content("fr")

    it("deals words: civilians share one, undercovers the other", function()
        local g = Game.new{ names = names(7), mr_white = true }
        g:startRound(c, "fr")
        local r = g.round
        assert.are_not.equal(r.word_civ, r.word_und)
        for i = 1, 7 do
            local s = g:secretFor(i)
            if r.roles[i] == "civilian" then assert.equals(r.word_civ, s.word)
            elseif r.roles[i] == "undercover" then assert.equals(r.word_und, s.word)
            else assert.equals("mrwhite", s.kind) end
        end
        assert.are_not.equal("mrwhite", r.roles[r.starter])
        assert.equals("deal", g:phase())
        dealAll(g)
        assert.equals("discuss", g:phase())
    end)

    it("civilians win when every infiltrator is out", function()
        local g = Game.new{ names = names(6), undercovers = 1, mr_white = false }
        g:startRound(c, "fr")
        dealAll(g)
        local u = indexOf(g, "undercover")
        assert.equals("undercover", g:eliminate(u))
        assert.is_true(g:isOver())
        assert.equals("civilians", g.round.winner)
        for i = 1, 6 do
            assert.equals(i == u and 0 or Game.POINTS.civilian_win, g.players[i].score)
        end
    end)

    it("infiltrators win when one civilian is left", function()
        local g = Game.new{ names = names(3), undercovers = 1 }
        g:startRound(c, "fr")
        dealAll(g)
        local civ = indexOf(g, "civilian")
        g:eliminate(civ)
        assert.is_true(g:isOver())
        assert.equals("infiltrators", g.round.winner)
        assert.equals(Game.POINTS.undercover_win, g.players[indexOf(g, "undercover")].score)
    end)

    it("goes on after a wrong elimination with enough civilians", function()
        local g = Game.new{ names = names(6), undercovers = 1, mr_white = false }
        g:startRound(c, "fr")
        dealAll(g)
        g:eliminate(indexOf(g, "civilian"))
        assert.equals("eliminated", g:phase())
        g:continue()
        assert.equals("discuss", g:phase())
        assert.equals(5, #g:aliveList())
        assert.is_true(g.round.alive[g.round.starter])
    end)

    it("Mr. White wins alone by guessing the word", function()
        local g = Game.new{ names = names(6), mr_white = true }
        g:startRound(c, "fr")
        dealAll(g)
        local w = indexOf(g, "mrwhite")
        g:eliminate(w)
        assert.is_true(g.round.pending_guess)
        assert.is_true(g:guess(g.round.word_civ:upper()))
        assert.equals("mrwhite", g.round.winner)
        assert.equals(Game.POINTS.white_guess, g.players[w].score)
    end)

    it("a wrong Mr. White guess lets the game go on", function()
        local g = Game.new{ names = names(8), undercovers = 1, mr_white = true }
        g:startRound(c, "fr")
        dealAll(g)
        g:eliminate(indexOf(g, "mrwhite"))
        assert.is_false(g:guess("zzzzzz"))
        assert.equals("eliminated", g:phase())
        g:continue()
        assert.equals("discuss", g:phase())
    end)
end)

describe("spy round", function()
    local c = content("en")

    it("one spy, everybody else sees the place", function()
        local g = Game.new{ names = names(5), mode = "spy" }
        g:startRound(c, "en")
        local spies = 0
        for i = 1, 5 do
            local s = g:secretFor(i)
            if s.kind == "spy" then spies = spies + 1
            else assert.equals(g.round.place, s.place); assert.is_string(s.role) end
        end
        assert.equals(1, spies)
    end)

    it("voting out an innocent hands the spy the win", function()
        local g = Game.new{ names = names(5), mode = "spy" }
        g:startRound(c, "en")
        dealAll(g)
        g:eliminate(indexOf(g, "agent"))
        assert.equals("spy", g.round.winner)
        assert.equals(Game.POINTS.spy_escapes, g.players[indexOf(g, "spy")].score)
    end)

    it("a caught spy who misses loses; the group may accept the guess", function()
        local g = Game.new{ names = names(4), mode = "spy" }
        g:startRound(c, "en")
        dealAll(g)
        local spy = indexOf(g, "spy")
        g:eliminate(spy)
        assert.is_false(g:guess("somewhere else entirely"))
        assert.equals("agents", g.round.winner)
        assert.equals(0, g.players[spy].score)
        g:acceptGuess()
        assert.equals("spy", g.round.winner)
        assert.equals(Game.POINTS.spy_guess, g.players[spy].score)
        for i = 1, 4 do if i ~= spy then assert.equals(0, g.players[i].score) end end
    end)

    it("the spy may give himself up and name the place", function()
        local g = Game.new{ names = names(4), mode = "spy" }
        g:startRound(c, "en")
        dealAll(g)
        g:spyDeclares()
        assert.is_true(g:guess(g.round.place))
        assert.equals("spy", g.round.winner)
    end)
end)

describe("persistence and repeats", function()
    it("round-trips a game in progress", function()
        local g = Game.new{ names = names(5), mr_white = true }
        g:startRound(content("fr"), "fr")
        g:nextDeal()
        local g2 = Game.load(g:serialize())
        assert.equals("deal", g2:phase())
        assert.equals(2, g2.round.deal_index)
        assert.equals(g.round.word_civ, g2.round.word_civ)
        assert.same(g.round.roles, g2.round.roles)
    end)

    it("does not repeat a pair until all are played", function()
        local c = { pairs = { { "a", "b" }, { "c", "d" }, { "e", "f" } }, places = {} }
        local g = Game.new{ names = names(3) }
        local seen = {}
        for _ = 1, 3 do
            g:startRound(c, "x")
            local k = g.round.word_civ < g.round.word_und and g.round.word_civ or g.round.word_und
            assert.is_nil(seen[k])
            seen[k] = true
        end
        g:startRound(c, "x") -- wraps around without error
        assert.is_nil(g:serialize().used)
    end)

    local function seenFor(p)
        return {
            pairs  = SeenHistory.open(p, "pairs_fr", { id_of = Game.pairId }),
            places = SeenHistory.open(p, "places_fr", { id_of = Game.placeId }),
        }
    end

    it("does not repeat across sessions, until the selection is used up", function()
        local c = { pairs = {}, places = {} }
        for i = 1, 12 do c.pairs[i] = { "a" .. i, "b" .. i } end
        local p = fakePlugin()
        local got = {}
        for session = 1, 3 do
            -- a new game each session (reader closed in between)
            local g = Game.new{ names = names(4) }
            for _ = 1, 4 do
                g:startRound(c, "fr", nil, seenFor(p))
                local id = math.min(g.round.word_civ, g.round.word_und)
                assert.is_nil(got[id], "repeated in session " .. session .. ": " .. id)
                got[id] = true
            end
        end
        -- all 12 played: the next one starts a new cycle without error
        Game.new{ names = names(4) }:startRound(c, "fr", nil, seenFor(p))
        assert.equals(1, #p.store.seen_pairs_fr)
    end)

    it("keeps other packs' history when the selection is used up", function()
        local p = fakePlugin()
        local small = { pairs = { { "x1", "y1" }, { "x2", "y2" } }, places = {} }
        local other = { "o1", "o2" }
        seenFor(p).pairs:mark({ other })
        local g = Game.new{ names = names(4) }
        for _ = 1, 3 do g:startRound(small, "fr", nil, seenFor(p)) end
        assert.is_true(SeenHistory.open(p, "pairs_fr", { id_of = Game.pairId }):has(Game.pairId(other)))
    end)

    it("migrates the 1.0.x used sets of a saved game once", function()
        local fr = content("fr")
        -- 1.0.x state: indices into the merged "food,kids" pairs and all-pack places
        local food = dofile("content/fr/pairs_food.lua")
        local kids = dofile("content/fr/pairs_kids.lua")
        local merged = {}
        for _, e in ipairs(food) do merged[#merged + 1] = e end
        for _, e in ipairs(kids) do merged[#merged + 1] = e end
        local state = {
            players = { { name = "A", score = 0 }, { name = "B", score = 0 }, { name = "C", score = 0 } },
            used = { ["fr:food,kids:pairs"] = { 1, 2, #food + 1 },
                     ["fr:history,geo,pop,food,kids,mix:places"] = { 3 } },
        }
        local p = fakePlugin()
        local hist = seenFor(p)
        local function listFor(kind, packs, lang)
            assert.equals("fr", lang)
            if kind == "pairs" then
                assert.same({ "food", "kids" }, packs)
                return merged
            end
            return fr.places
        end
        assert.is_true(Game.migrateLegacyUsed(state, listFor, function(kind) return hist[kind] end))
        assert.is_true(hist.pairs:has(Game.pairId(food[1])))
        assert.is_true(hist.pairs:has(Game.pairId(food[2])))
        assert.is_true(hist.pairs:has(Game.pairId(kids[1])))
        assert.is_false(hist.pairs:has(Game.pairId(food[3])))
        assert.is_true(hist.places:has(Game.placeId(fr.places[3])))
        assert.equals(3, #p.store.seen_pairs_fr)
        -- persisted: a new session sees them
        assert.is_true(seenFor(p).pairs:has(Game.pairId(kids[1])))
        -- the loaded game no longer carries them, so nothing migrates twice
        local g = Game.load(state)
        assert.is_false(Game.migrateLegacyUsed(g:serialize(), listFor, function() error("again") end))
        assert.is_false(Game.migrateLegacyUsed(nil, listFor, function() error("nil") end))
    end)
end)
