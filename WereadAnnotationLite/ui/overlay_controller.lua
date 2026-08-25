local UIManager = require("ui/uimanager")
local Overlay = require("WereadAnnotationLite.ui.overlay")

local M = {}
local MODULE = "weread_local_annotations_overlay"
local TOUCH = "weread_local_annotations_tap"

local function supported(plugin)
    local doc = plugin.ui and plugin.ui.document
    return doc and doc.info and not doc.info.has_pages
        and type(doc.getXPointer) == "function"
        and type(doc.getScreenBoxesFromPositions) == "function"
end

function M.onReaderReady(plugin)
    if not supported(plugin) then return end
    local entry = plugin.database:getDocument(plugin.ui.document.file)
    local overlay = Overlay:new{
        records = entry and entry.records or {},
        enabled = plugin.settings:get("show_annotations", true),
    }
    plugin.ui.view:registerViewModule(MODULE, overlay)
    plugin._local_annotation_overlay = overlay
    if plugin.ui.registerTouchZones then
        plugin.ui:registerTouchZones({{ id = TOUCH, ges = "tap",
            screen_zone = { ratio_x = 0, ratio_y = 0, ratio_w = 1, ratio_h = 1 },
            overrides = { "tap_forward", "tap_backward", "readerfooter_tap" },
            handler = function(ges)
                local record = overlay:hitTest(ges and ges.pos)
                if record then plugin:openThought(record); return true end
                return false
            end }})
    end
end

function M.toggleVisibility(plugin)
    local enabled = not plugin.settings:get("show_annotations", true)
    plugin.settings:set("show_annotations", enabled)
    plugin.settings:flush()
    if plugin._local_annotation_overlay then
        plugin._local_annotation_overlay.enabled = enabled
        plugin._local_annotation_overlay.visible = {}
        UIManager:setDirty(plugin.ui, "partial")
    end
    return enabled
end

function M.onPageUpdate(plugin)
    local overlay = plugin._local_annotation_overlay
    if overlay then overlay.visible = {} end
end

function M.onCloseDocument(plugin)
    if plugin.ui and plugin.ui.unRegisterTouchZones then
        plugin.ui:unRegisterTouchZones({{ id = TOUCH }})
    end
    if plugin.ui and plugin.ui.view and plugin.ui.view.view_modules then
        plugin.ui.view.view_modules[MODULE] = nil
    end
    plugin._local_annotation_overlay = nil
end

return M
