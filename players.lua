-- ---------------------------------------------------------------------------
-- Player-list editor: a picker listing the players (tap one to rename it),
-- plus "Add a player" / "Remove the last player". Re-opens after each change
-- so the list can be edited in one go.
--
--   PlayersMenu.open{ names = {...}, min = 3, max = 12, parent = widget,
--                     on_change = function(names) end }
-- ---------------------------------------------------------------------------

local InputDialog = require("ui/widget/inputdialog")
local UIManager   = require("ui/uimanager")
local _           = require("i18n")
local T           = require("ffi/util").template

local MenuHelper = require("menu_helper")

local PlayersMenu = {}

function PlayersMenu.defaultName(i)
    return T(_("Player %1"), i)
end

-- Trims and caps a typed name; an empty one falls back to "Player N".
function PlayersMenu.cleanName(text, i)
    text = tostring(text or ""):gsub("[%c]", " "):gsub("^%s+", ""):gsub("%s+$", "")
    if text == "" then return PlayersMenu.defaultName(i) end
    -- 24 bytes keeps names on one line of the scoreboard (UTF-8 safe cut).
    if #text > 24 then
        text = text:sub(1, 24):gsub("[\xC0-\xFF][\x80-\xBF]*$", "")
    end
    return text
end

local function rename(opts, names, i)
    local dialog
    dialog = InputDialog:new{
        title      = T(_("Name of player %1"), i),
        input      = names[i],
        buttons    = {{
            { text = _("Cancel"), id = "close", callback = function()
                UIManager:close(dialog)
                PlayersMenu.open(opts)
            end },
            { text = _("OK"), is_enter_default = true, callback = function()
                names[i] = PlayersMenu.cleanName(dialog:getInputText(), i)
                UIManager:close(dialog)
                opts.on_change(names)
                PlayersMenu.open(opts)
            end },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function PlayersMenu.open(opts)
    local names = {}
    for i, n in ipairs(opts.names) do names[i] = n end
    opts.names = names
    local min, max = opts.min or 0, opts.max or 12

    local items = {}
    for i, n in ipairs(names) do
        items[#items + 1] = { id = i, text = i .. ". " .. n }
    end
    if #names < max then
        items[#items + 1] = { id = "add", text = "+ " .. _("Add a player") }
    end
    if #names > min then
        items[#items + 1] = { id = "remove", text = "− " .. _("Remove the last player") }
    end

    MenuHelper.openPickerMenu{
        title     = T(_("Players: %1"), #names),
        items     = items,
        parent    = opts.parent,
        on_select = function(id)
            if id == "add" then
                names[#names + 1] = PlayersMenu.defaultName(#names + 1)
                opts.on_change(names)
                rename(opts, names, #names)
            elseif id == "remove" then
                table.remove(names)
                opts.on_change(names)
                PlayersMenu.open(opts)
            else
                rename(opts, names, id)
            end
        end,
    }
end

return PlayersMenu
