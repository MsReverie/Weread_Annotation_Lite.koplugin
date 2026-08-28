--[[--
Native WeRead thought dialog.

Centered rounded frame. Long content scrolls inside the bitmap viewport.

@module ui.thought_popup
--]]

local FaceFactory = require("ui.thought_popup_text").FaceFactory
local ThoughtPopupWidget = require("ui.thought_popup_widget")
local UIManager = require("ui/uimanager")

FaceFactory:init()

local M = {}
local _pooled

--- Show (or reopen the pooled instance) a thought popup.
--- @param opts table { pages, close_callback }
function M.show(opts)
    opts = opts or {}
    if type(opts.pages) ~= "table" or #opts.pages == 0 then
        error("thought popup: invalid pages")
    end

    if _pooled then
        _pooled:_reopen{
            items = opts.pages,
            close_callback = opts.close_callback,
        }
        UIManager:show(_pooled)
        return _pooled
    end

    _pooled = ThoughtPopupWidget:new{
        items = opts.pages,
        close_callback = opts.close_callback,
    }
    UIManager:show(_pooled)
    return _pooled
end

return M
