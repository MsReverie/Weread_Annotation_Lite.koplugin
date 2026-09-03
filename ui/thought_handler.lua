--[[--
Thought display handler.

Manages the full flow of opening a thought popup: state tracking,
offline retry scheduling, API fetching, DB persistence, and overlay
updates. Called with the Plugin instance as the first argument.

@module ui.thought_handler
--]]

local _ = require("lib.i18n")
local UIManager = require("ui/uimanager")

local M = {}

--- Open thoughts for the given underline record.
--- Returns true when the caller should abort further processing.
function M.open(plugin, record)
    if not plugin.settings:get("show_annotations", true) then
        return true
    end
    plugin._thought_open = true
    plugin.prefetch:pause()
    local file = plugin.ui.document and plugin.ui.document.file
    local binding = file and plugin.database:getBinding(file)
    if not binding then
        plugin._thought_open = false
        plugin.prefetch:resume()
        return true
    end
    local items = type(record.items) == "table" and record.items or {}
    local chapter_uid = record.chapter_uid
    local loading
    if tonumber(record.fetched) == 1 and not plugin.api.hasThoughtContent(items) then
        plugin._thought_open = false
        plugin.prefetch:resume()
        plugin:showTransientInfo(_("No thoughts for this underline."), 2)
        return true
    end
    if #items == 0 then
        if plugin:whenOnline(function() M.open(plugin, record) end) then
            plugin._thought_open = false
            plugin.prefetch:resume()
            return true
        end
        local InfoMessage = require("ui/widget/infomessage")
        loading = InfoMessage:new { text = _("Loading thoughts…") }
        UIManager:show(loading)
        local ok, result = pcall(plugin.api.reviews, plugin.api, binding.book_id,
            chapter_uid, { record.range })
        if ok and result and result.reviews then
            for _, range_review in ipairs(result.reviews) do
                local parsed = plugin.api:parseReviewItems(range_review)
                for _, item in ipairs(parsed) do
                    items[#items + 1] = item
                end
            end
            if plugin.api.hasThoughtContent(items) then
                plugin.database:saveThoughts(file, record.chapter_uid, record.range,
                    plugin.api:json_encode(items), true)
                if plugin._local_annotation_overlay then
                    plugin._local_annotation_overlay:updateThought(record.chapter_uid, record.range, items)
                end
            else
                items = {}
            end
        elseif not ok then
            UIManager:close(loading)
            plugin._thought_open = false
            plugin.prefetch:resume()
            local message = tostring(result)
            if plugin.api.is_skill_upgrade_required(result) then
                message = message:gsub("^upgrade_required%s+", "")
            end
            plugin:showInfo(message)
            return true
        end
        UIManager:close(loading)
    end
    if #items == 0 then
        plugin.database:saveThoughts(file, record.chapter_uid, record.range, "[]", true)
        if plugin._local_annotation_overlay then
            plugin._local_annotation_overlay:updateThought(record.chapter_uid, record.range, {})
        end
        plugin._thought_open = false
        plugin.prefetch:resume()
        plugin:showTransientInfo(_("No thoughts for this underline."), 2)
        return true
    end
    require("ui.thought_popup").show {
        pages = items,
        close_callback = function()
            plugin._thought_open = false
            plugin.prefetch:resume()
            plugin:onChapterMaybeChanged()
        end,
    }
    return true
end

return M
