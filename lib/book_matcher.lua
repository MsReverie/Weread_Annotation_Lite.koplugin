--[[--
Book search and binding module.

Handles document metadata extraction, WeRead search, result display,
and binding persistence. Called with the Plugin instance as the first arg.

@module lib.book_matcher
--]]

local UIManager = require("ui/uimanager")
local _ = require("lib.i18n")

local M = {}

local function strip_search_noise(text)
    text = tostring(text or "")
        :gsub("%s*（.-）", "")
        :gsub("%s*%(.-%)", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    return text
end

local function normalize_isbn(text)
    return tostring(text or ""):upper():gsub("[^0-9X]", "")
end

local function document_props(plugin)
    local props = plugin.ui and plugin.ui.doc_props
    if type(props) ~= "table" then
        local document = plugin.ui and plugin.ui.document
        if document then
            props = document:getProps()
        end
    end
    return type(props) == "table" and props or {}
end

function M.documentISBN(plugin)
    local props = document_props(plugin)
    local raw = props.isbn or props.identifiers
    if type(raw) == "table" then
        raw = table.concat(raw, " ")
    end
    raw = normalize_isbn(raw)
    return raw:match("97[89]%d%d%d%d%d%d%d%d%d%d")
        or raw:match("%d%d%d%d%d%d%d%d%d[0-9X]")
end

function M.documentSearchKeyword(plugin)
    local props = document_props(plugin)
    local title = strip_search_noise(props.display_title or props.title)
    if title ~= "" then
        return title, props.authors or props.author
    end
    local raw_name = tostring(plugin.ui.document.file or ""):match("([^/\\]+)%.[^%.]+$") or ""
    return strip_search_noise(raw_name), props.authors or props.author
end

-- Display the WeRead search results list and save the binding when selected.
-- Invokes callback(true) on successful match, callback(false) otherwise.
function M.showSearchResults(plugin, file, keyword, callback)
    if plugin:whenOnline(function()
        M.showSearchResults(plugin, file, keyword, callback)
    end) then
        return
    end

    local rows = {}
    local seen = {}
    local function append_hits(groups)
        for _g, group in ipairs(groups or {}) do
            for _c, candidate in ipairs(group.books or {}) do
                local hit = plugin.api.formatSearchHit(candidate)
                if hit and not seen[hit.book_id] then
                    seen[hit.book_id] = true
                    rows[#rows + 1] = {
                        text = hit.title,
                        post_text = hit.subtitle,
                        callback = function()
                            plugin.database:saveBinding(file, {
                                book_id = hit.book_id,
                                title = hit.title,
                                author = hit.author,
                            })
                            plugin:showTransientInfo(_("Book matched."), 2)
                            if callback then callback(true) end
                        end,
                    }
                end
            end
        end
    end

    local isbn = M.documentISBN(plugin)
    if isbn then
        local ok_isbn, isbn_result = pcall(plugin.api.search, plugin.api, isbn)
        if ok_isbn then
            append_hits(isbn_result)
        end
    end

    if keyword ~= isbn then
        local ok, result = pcall(plugin.api.search, plugin.api, keyword)
        if not ok then
            if #rows == 0 then
                local message = tostring(result or "")
                if message:find("API key is not configured", 1, true) then
                    plugin:showInfo(_(
                        "Please use Weread QR login first. The QR login obtains the official API key automatically."))
                else
                    plugin:showInfo(message)
                end
                if callback then callback(false) end
                return
            end
        else
            append_hits(result)
        end
    end

    if #rows == 0 then
        plugin:showInfo(_("No results."))
        if callback then callback(false) end
        return
    end
    plugin:showList(_("Select matching book"), rows, _("No results."))
end

-- Open the input dialog pre-filled with the document title/author and
-- dispatch to showSearchResults after the user confirms.
-- Invokes callback(success) when a match is saved (or cancelled).
function M.matchDialog(plugin, callback)
    local file = plugin.ui.document and plugin.ui.document.file
    if not file then
        if callback then callback(false) end
        return
    end
    local cleaned_name, doc_author = M.documentSearchKeyword(plugin)
    local description
    if doc_author and tostring(doc_author) ~= "" then
        description = _("Author") .. ": " .. tostring(doc_author)
    end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new {
        title = _("Search Weread book"),
        input = cleaned_name,
        description = description,
        buttons = { {
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                    if callback then callback(false) end
                end,
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local keyword = dialog:getInputText()
                    UIManager:close(dialog)
                    M.showSearchResults(plugin, file, keyword, callback)
                end,
            },
        } },
    }
    plugin:showInputDialog(dialog)
end

return M
