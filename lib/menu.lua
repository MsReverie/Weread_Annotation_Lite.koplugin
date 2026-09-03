--[[--
Main menu for Weread Annotation Lite.

Returns a sub-item table suitable for registerToMainMenu().
All callbacks delegate to the Plugin instance passed in.

@module lib.menu
--]]

local UIManager = require("ui/uimanager")
local _ = require("lib.i18n")

local M = {}

function M.build(plugin)
    local function is_enabled()
        return plugin.settings:get("show_annotations", true)
    end
    return {
        {
            text = _("Enable underlines and thoughts"),
            checked_func = is_enabled,
            callback = function()
                local new_state = not plugin.settings:get("show_annotations", true)
                plugin.settings:set("show_annotations", new_state)
                plugin.settings:flush()
                if plugin._local_annotation_overlay then
                    plugin._local_annotation_overlay:setEnabled(new_state)
                    UIManager:setDirty(plugin.ui, "partial")
                end
                if not new_state then
                    plugin.prefetch:cancel()
                elseif plugin.ui and plugin.ui.document then
                    local binding = plugin.database:getBinding(plugin.ui.document.file)
                    if binding then
                        plugin:prefetchThoughts()
                    end
                end
            end,
        },
        {
            text = _("Fetch underlines"),
            enabled_func = is_enabled,
            callback = function()
                plugin:syncUnderlines()
            end,
        },
        {
            text = _("Auto prefetch underlines and thoughts"),
            enabled_func = is_enabled,
            checked_func = function()
                return plugin.settings:get("prefetch_thoughts", true)
            end,
            callback = function()
                local new_state = not plugin.settings:get("prefetch_thoughts", true)
                plugin.settings:set("prefetch_thoughts", new_state)
                plugin.settings:flush()
                if new_state then
                    if plugin.ui and plugin.ui.document then
                        local binding = plugin.database:getBinding(plugin.ui.document.file)
                        if binding then
                            plugin:prefetchThoughts()
                        end
                    end
                else
                    plugin.prefetch:cancel()
                end
            end,
        },
        {
            text = _("Show prefetch notifications"),
            enabled_func = is_enabled,
            checked_func = function()
                return plugin.settings:get("prefetch_notify", false)
            end,
            callback = function()
                local new_state = not plugin.settings:get("prefetch_notify", false)
                plugin.settings:set("prefetch_notify", new_state)
                plugin.settings:flush()
            end,
        },
        {
            text = _("Weread QR login"),
            callback = function()
                plugin.qr_login:start()
            end,
        },
        {
            text = _("Check for updates"),
            callback = function()
                require("lib.ota").check(plugin)
            end,
        },
        {
            text = _("Clear current book data"),
            callback = function()
                plugin:clearCurrentData()
            end,
        },
    }
end

return M
