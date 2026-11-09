-- Content language: the game follows KOReader's language unless the player
-- picked another one in the game's Language menu while KOReader had its
-- current language (PluginBase:getLang/setLang, game-common 1.15.0).
-- The real screen.lua runs on top of permissive stubs for KOReader's UI.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"

-- Anything KOReader-side: every field is another stub, calling it returns the
-- table it was given (Widget:new{...}, Class:extend{...}) or a stub.
local Stub
Stub = setmetatable({}, {
    __index = function() return Stub end,
    __call = function(_, a, b)
        local o = (a ~= Stub and type(a) == "table" and a) or (type(b) == "table" and b) or nil
        if o and getmetatable(o) == nil then return setmetatable(o, { __index = Stub }) end
        return o or Stub
    end,
    __add = function() return 0 end, __sub = function() return 0 end,
    __mul = function() return 0 end, __div = function() return 0 end,
    __idiv = function() return 0 end, __unm = function() return 0 end,
    __lt = function() return false end, __le = function() return true end,
    __concat = function() return "" end, __len = function() return 0 end,
})

local function koreader(lang)
    _G.G_reader_settings = { readSetting = function(_, k) if k == "language" then return lang end end }
end

local saved = {}
local picked   -- the last MenuHelper.openPickerMenu{} call

local function setup_env()
    saved.path = package.path
    saved.loaded = {}
    for k, v in pairs(package.loaded) do saved.loaded[k] = v end
    saved.preload = {}
    for k, v in pairs(package.preload) do saved.preload[k] = v end
    package.path = DIR .. "?.lua;" .. DIR .. "common/?.lua;" .. package.path
    local i18n = setmetatable({ lang = function()
        return (G_reader_settings and G_reader_settings:readSetting("language") or "en"):sub(1, 2)
    end }, { __call = function(_, s) return s end })
    package.preload["i18n"] = function() return i18n end
    package.preload["ffi/util"] = function()
        return { template = function(s, ...)
            local args = { ... }
            return (tostring(s):gsub("%%(%d)", function(n) return tostring(args[tonumber(n)]) end))
        end }
    end
    package.preload["menu_helper"] = function()
        return setmetatable({ openPickerMenu = function(opts) picked = opts end }, { __index = Stub })
    end
    package.preload["screen_base"] = function()
        -- ScreenBase's own methods do nothing; any other field stays nil.
        local methods = {}
        local src = assert(io.open(DIR .. "common/screen_base.lua")):read("a")
        for m in src:gmatch("function ScreenBase:([%w_]+)") do methods[m] = true end
        local SB = {}
        SB.extend = function(self, o) o = o or {}; o.__index = o; return setmetatable(o, { __index = self }) end
        return setmetatable(SB, { __index = function(_, k) if methods[k] then return Stub end end })
    end
    local searchers = package.searchers or package.loaders
    saved.searcher = function(name)
        if name:match("^ui/") or name:match("^ffi/") or name == "device" or name == "datastorage"
                or name == "luasettings" or name == "stats_exporter" or name == "games_menu" then
            return function() return Stub end, name
        end
        return nil
    end
    table.insert(searchers, 2, saved.searcher)
end

local function teardown_env()
    local searchers = package.searchers or package.loaders
    for i = #searchers, 1, -1 do
        if searchers[i] == saved.searcher then table.remove(searchers, i) end
    end
    for k in pairs(package.loaded) do package.loaded[k] = saved.loaded[k] end
    for k, v in pairs(saved.loaded) do package.loaded[k] = v end
    for k in pairs(package.preload) do package.preload[k] = saved.preload[k] end
    package.path = saved.path
    _G.G_reader_settings = nil
end

-- A plugin backed by a plain table instead of a settings file.
local function newPlugin(store)
    store = store or {}
    local PluginBase = require("plugin_base")
    local p = setmetatable({}, { __index = PluginBase })
    p.settings = {
        readSetting = function(_, k) return store[k] end,
        saveSetting = function(_, k, v) store[k] = v end,
        delSetting  = function(_, k) store[k] = nil end,
        flush = function() end,
    }
    p.settings_file = "/tmp/lang_spec.lua"
    return p, store
end

-- Loads a game file. Lua 5.5 (Homebrew busted) makes a for-loop variable
-- constant, which LuaJIT does not: a loop that reassigns it (`line = trim(line)`)
-- gets a fresh local copy here.
local function loadGameFile(name)
    local path = DIR .. name
    local src = assert(io.open(path)):read("a")
    src = src:gsub("for ([%a_][%w_]*) in ([^\n]-) do\n", "for %1__ in %2 do local %1 = %1__\n")
    return assert(load(src, "@" .. path))()
end

local function newScreen(plugin, file)
    local Screen = loadGameFile(file or "screen.lua")
    local s = setmetatable({ plugin = plugin }, { __index = Screen })
    -- Drawing needs a real screen: skip it, the state is what is checked.
    for _i, m in ipairs({ "_redraw", "_refresh", "rebuild", "buildLayout" }) do
        s[m] = function() end
    end
    s:init()
    return s
end

describe("Undercover content language", function()
    setup(setup_env)
    teardown(teardown_env)

    it("deals French words when KOReader is in French", function()
        koreader("fr")
        local s = newScreen((newPlugin()))
        assert.are.equal("fr", s.lang)
        local _c, lang = s:_content()
        assert.are.equal("fr", lang)
        for key in pairs(s.content) do assert.are.equal("fr/", key:sub(1, 3)) end
    end)

    it("no longer keeps English saved by an older version", function()
        koreader("fr")
        local s = newScreen((newPlugin({ lang = "en" })))
        assert.are.equal("fr", s.lang)
    end)

    it("keeps the language picked in the game while KOReader's stays the same", function()
        koreader("fr")
        local p, store = newPlugin()
        local s = newScreen(p)
        s:openLangMenu()
        picked.on_select("en")
        assert.are.equal("en", s.lang)
        assert.are.equal("en", select(2, s:_content()))
        assert.are.equal("fr", store.lang_ko)
        assert.are.equal("en", newScreen(p).lang)
        koreader("en")
        assert.are.equal("en", newScreen(p).lang)
        koreader("fr")
        assert.are.equal("en", newScreen(p).lang)
    end)
end)
