--[[--
Native WeRead thought dialog.

Displays thoughts in a bottom bitmap popup. Long content scrolls inside the
bitmap viewport; the implementation intentionally exposes no popup options.

@module ui.thought_popup
--]]

local FaceFactory = require("ui.thought_popup_text").FaceFactory
local UIManager = require("ui/uimanager")

FaceFactory:init()

local M = {}
local _pool = {}  -- single bottom popup instance

local function normalizePosition(_position)
    return "bottom"
end

--- The widget class for a position; required lazily so the entry can be
--- loaded without instantiating UI (and so tests can mock either widget).
local function widgetClassFor()
    return require("ui.thought_popup_widget")
end

--- Show (or reopen the pooled instance for the position) a thought popup.
--- @param opts table { pages, position?, doc_font_name, doc_font_size,
---                    doc_margins, height_ratio, dialog, close_callback }
function M.show(opts)
    opts = opts or {}
    if type(opts.pages) ~= "table" or #opts.pages == 0 then
        error("thought popup: invalid pages")
    end

    -- The widget stores the records under "items" (its field name); the
    -- public contract uses "pages". Normalize once so the initial construction
    -- and the pooled reopen below both receive the items.
    opts.items = opts.items or opts.pages

    local position = normalizePosition(opts.position)

    -- Only the active position stays resident: drop the other pool so its
    -- page/piece/layout caches (bitmaps) are not held for the whole session.
    for other_position, pooled in pairs(_pool) do
        if other_position ~= position then
            pcall(function()
                if UIManager:isWidgetShown(pooled) then
                    UIManager:close(pooled)
                end
            end)
            pooled:clear()
            pooled:_freeContentCaches()
            _pool[other_position] = nil
        end
    end

    local pooled = _pool[position]
    if pooled then
        pooled:_reopen(opts)
        UIManager:show(pooled)
        return pooled
    end

    local popup = widgetClassFor():new{
        items = opts.items,
        doc_font_name = opts.doc_font_name,
        doc_font_size = opts.doc_font_size,
        doc_margins = opts.doc_margins,
        height_ratio = opts.height_ratio,
        dialog = opts.dialog,
        close_callback = opts.close_callback,
    }
    _pool[position] = popup
    UIManager:show(popup)
    return popup
end

return M
