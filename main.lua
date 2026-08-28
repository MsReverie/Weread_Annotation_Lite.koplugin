--[[--
Weread Annotation Lite plugin.

@module koplugin.wereadannotationlite
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("lib.i18n")
local logger = require("lib.logger")

local Settings = require("settings")
local Database = require("lib.database")
local API = require("lib.api")
local Prefetch = require("lib.prefetch")
local OverlayController = require("ui.overlay_controller")
local TocMap = require("lib.toc_map")

local Plugin = WidgetContainer:extend {
    name = "wereadannotationlite",
    is_doc_only = true,
}

function Plugin:init()
    self.settings = Settings:new()
    logger.setDebug(self.settings:get("debug_log", false))
    self.database = Database:new(self.settings)
    self.api = API:new(self.settings)
    self.qr_login = require("lib.qr_login"):new(self, self.api, self.settings)
    self.prefetch = Prefetch:new(self)
    self._reader_session = 0
    self.ui.menu:registerToMainMenu(self)
end

function Plugin:addToMainMenu(menu_items)
    local function is_enabled()
        return self.settings:get("show_annotations", true)
    end
    menu_items.wereadannotationlite = {
        text = _("Weread Annotation Lite"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                {
                    text = _("Enable underlines and thoughts"),
                    checked_func = is_enabled,
                    callback = function()
                        local new_state = not self.settings:get("show_annotations", true)
                        self.settings:set("show_annotations", new_state)
                        self.settings:flush()
                        -- 更新叠加层
                        if self._local_annotation_overlay then
                            self._local_annotation_overlay:setEnabled(new_state)
                            UIManager:setDirty(self.ui, "partial")
                        end
                        -- 若关闭，取消所有预取任务
                        if not new_state then
                            self.prefetch:cancel()
                        elseif self.ui and self.ui.document then
                            -- 若开启，尝试自动预取
                            local binding = self.database:getBinding(self.ui.document.file)
                            if binding then
                                self:prefetchThoughts()
                            end
                        end
                    end
                },
                {
                    text = _("Fetch underlines"),
                    enabled_func = is_enabled,
                    callback = function()
                        self:syncUnderlines()
                    end
                },
                {
                    text = _("Auto prefetch underlines and thoughts"),
                    enabled_func = is_enabled,
                    checked_func = function()
                        return self.settings:get("prefetch_thoughts", true)
                    end,
                    callback = function()
                        local new_state = not self.settings:get("prefetch_thoughts", true)
                        self.settings:set("prefetch_thoughts", new_state)
                        self.settings:flush()
                        if new_state then
                            if self.ui and self.ui.document then
                                local binding = self.database:getBinding(self.ui.document.file)
                                if binding then
                                    self:prefetchThoughts()
                                end
                            end
                        else
                            self.prefetch:cancel()
                        end
                    end
                },
                {
                    text = _("Show prefetch notifications"),
                    enabled_func = is_enabled,
                    checked_func = function()
                        return self.settings:get("prefetch_notify", false)
                    end,
                    callback = function()
                        local new_state = not self.settings:get("prefetch_notify", false)
                        self.settings:set("prefetch_notify", new_state)
                        self.settings:flush()
                    end
                },
                {
                    text = _("Weread QR login"),
                    callback = function()
                        self.qr_login:start()
                    end
                },
                {
                    text = _("Clear current book data"),
                    callback = function()
                        self:clearCurrentData()
                    end
                },
            }
        end,
    }
end

function Plugin:isNetworkOnline()
    return self.api:isOnline()
end

function Plugin:showOffline(label)
    local T = require("ffi/util").template
    self:showInfo(T(_("%1: offline"), tostring(label or _("Network"))))
end

function Plugin:showInputDialog(dialog)
    UIManager:show(dialog)
end

function Plugin:runOnlineTask(_label, callback)
    local ok, err = pcall(callback)
    if not ok then
        self:showInfo(tostring(err))
        return false
    end
    return true
end

-- Returns true when the caller should abort: Wi-Fi will come up and callback
-- will run. Matches NetworkMgr:willRerunWhenOnline.
function Plugin:whenOnline(callback)
    local NetworkMgr = require("ui/network/manager")
    return NetworkMgr:willRerunWhenOnline(callback)
end

function Plugin:clearCurrentData()
    local file = self.ui.document and self.ui.document.file
    if not file then
        self:showInfo(_("No document open."))
        return
    end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new {
        text = _("Clear Weread annotations for this book?"),
        ok_callback = function()
            self.database:clear(file)
            if self._local_annotation_overlay then
                self._local_annotation_overlay:setRecords({})
            end
            self:showTransientInfo(_("Current book data cleared."), 2)
        end,
    })
end

function Plugin:showInfo(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new { text = tostring(text or "") })
end

function Plugin:showTransientInfo(text, timeout)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new { text = tostring(text or ""), timeout = timeout or 2 })
end

function Plugin:showList(title, items, empty_text)
    if not items or #items == 0 then
        self:showInfo(empty_text or _("No items.")); return
    end
    local MenuWidget = require("ui/widget/menu")
    local menu = MenuWidget:new { title = title, item_table = items }
    for _, item in ipairs(items) do
        local orig_cb = item.callback
        if orig_cb then
            item.callback = function(...)
                UIManager:close(menu)
                if orig_cb then orig_cb(...) end
            end
        end
    end
    UIManager:show(menu)
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

function Plugin:ensureTocMap()
    if self._toc_map then return self._toc_map end
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then return nil end
    local chapters = self._chapter_list
    if not chapters or #chapters == 0 then
        chapters = self.database:listChapters(file)
        self._chapter_list = chapters
    end
    if not chapters or #chapters == 0 then return nil end
    local toc = document:getToc()
    if type(toc) ~= "table" or #toc == 0 then return nil end
    local resolved = {}
    for i, item in ipairs(toc) do
        local xp = item.xpointer
        local pos = tonumber(item.page) or 0
        if xp then
            pos = tonumber((document:getPosFromXPointer(xp))) or pos
        end
        resolved[i] = {
            title = item.title,
            xpointer = xp,
            pos = pos,
        }
    end
    local matched = TocMap.match(chapters, resolved)
    self._toc_map = {
        chapters = chapters,
        toc = resolved,
        matched = matched,
        bounds = TocMap.bounds(chapters, resolved, matched),
    }
    return self._toc_map
end

function Plugin:getChapterBounds(chapter_uid)
    if not chapter_uid then return nil end
    local map = self:ensureTocMap()
    if not map then return nil end
    return map.bounds[tostring(chapter_uid)]
end

function Plugin:currentWereadChapterUid()
    local document = self.ui and self.ui.document
    if not document or not document.file then return nil end
    local map = self:ensureTocMap()
    if not map then return nil end
    return TocMap.uidAtPos(map.bounds, document:getCurrentPos() or 0)
end

function Plugin:onChapterMaybeChanged()
    if self._thought_open then return end
    if not self.settings:get("show_annotations", true) then return end
    if not self.settings:get("prefetch_thoughts", true) then return end
    if not (self.ui and self.ui.document) then return end
    local uid = self:currentWereadChapterUid()
    if not uid or uid == self._seen_chapter_uid then return end
    self._seen_chapter_uid = uid
    self.prefetch:afterChapterTurn(uid)
end

function Plugin:prefetchThoughts(silent)
    if not self.settings:get("show_annotations", true) then
        return
    end

    local file = self.ui.document and self.ui.document.file
    local binding = file and self.database:getBinding(file)

    if silent == nil then
        silent = not self.settings:get("prefetch_notify", false)
    end
    if not binding then
        if not silent then
            self:showTransientInfo(_("Match this local book first."))
        end
        return
    end

    self.prefetch:ensureCatalog(file, binding)
    local chapter = self:currentWereadChapterUid()
    if not chapter then
        if not silent then
            self:showTransientInfo(_("Could not detect the current chapter."))
        end
        return
    end

    self._seen_chapter_uid = chapter
    self.prefetch:onChapter(chapter)
    if not silent then
        self:showTransientInfo(_("Prefetch started."), 2)
    end
end

function Plugin:openThought(record)
    if not self.settings:get("show_annotations", true) then
        return true
    end
    self._thought_open = true
    self.prefetch:pause()
    local file = self.ui.document and self.ui.document.file
    local binding = file and self.database:getBinding(file)
    if not binding then
        self._thought_open = false
        self.prefetch:resume()
        return true
    end
    local items = type(record.items) == "table" and record.items or {}
    local chapter_uid = record.chapter_uid
    local loading
    if tonumber(record.fetched) == 1 and not self.api.hasThoughtContent(items) then
        self._thought_open = false
        self.prefetch:resume()
        self:showTransientInfo(_("No thoughts for this underline."), 2)
        return true
    end
    if #items == 0 then
        if self:whenOnline(function() self:openThought(record) end) then
            self._thought_open = false
            self.prefetch:resume()
            return true
        end
        local InfoMessage = require("ui/widget/infomessage")
        loading = InfoMessage:new { text = _("Loading thoughts…") }
        UIManager:show(loading)
        local ok, result = pcall(self.api.reviews, self.api, binding.book_id,
            chapter_uid, { record.range })
        if ok and result and result.reviews then
            for _, range_review in ipairs(result.reviews) do
                local parsed = self.api:parseReviewItems(range_review)
                for _, item in ipairs(parsed) do
                    items[#items + 1] = item
                end
            end
            if self.api.hasThoughtContent(items) then
                self.database:saveThoughts(file, record.chapter_uid, record.range,
                    self.api:json_encode(items), true)
                if self._local_annotation_overlay then
                    self._local_annotation_overlay:updateThought(record.chapter_uid, record.range, items)
                end
            else
                items = {}
            end
        elseif not ok then
            UIManager:close(loading)
            self._thought_open = false
            self.prefetch:resume()
            local message = tostring(result)
            if self.api.is_skill_upgrade_required(result) then
                message = message:gsub("^upgrade_required%s+", "")
            end
            self:showInfo(message)
            return true
        end
        UIManager:close(loading)
    end
    if #items == 0 then
        self.database:saveThoughts(file, record.chapter_uid, record.range, "[]", true)
        if self._local_annotation_overlay then
            self._local_annotation_overlay:updateThought(record.chapter_uid, record.range, {})
        end
        self._thought_open = false
        self.prefetch:resume()
        self:showTransientInfo(_("No thoughts for this underline."), 2)
        return true
    end
    require("ui.thought_popup").show {
        pages = items,
        close_callback = function()
            self._thought_open = false
            self.prefetch:resume()
            self._seen_chapter_uid = nil
            self:onChapterMaybeChanged()
        end,
    }
    return true
end

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

local function document_isbn(plugin)
    local props = document_props(plugin)
    local raw = props.isbn or props.identifiers
    if type(raw) == "table" then
        raw = table.concat(raw, " ")
    end
    raw = normalize_isbn(raw)
    return raw:match("97[89]%d%d%d%d%d%d%d%d%d%d")
        or raw:match("%d%d%d%d%d%d%d%d%d[0-9X]")
end

local function document_search_keyword(plugin, file)
    local props = document_props(plugin)
    local title = strip_search_noise(props.display_title or props.title)
    if title ~= "" then
        return title, props.authors or props.author
    end
    local raw_name = tostring(file or ""):match("([^/\\]+)%.[^%.]+$") or ""
    return strip_search_noise(raw_name), props.authors or props.author
end

function Plugin:showWereadSearchResults(file, keyword, callback)
    if self:whenOnline(function()
        self:showWereadSearchResults(file, keyword, callback)
    end) then
        return
    end

    local rows = {}
    local seen = {}
    local function append_hits(groups)
        for _g, group in ipairs(groups or {}) do
            for _c, candidate in ipairs(group.books or {}) do
                local hit = self.api.formatSearchHit(candidate)
                if hit and not seen[hit.book_id] then
                    seen[hit.book_id] = true
                    rows[#rows + 1] = {
                        text = hit.title,
                        post_text = hit.subtitle,
                        callback = function()
                            self.database:saveBinding(file, {
                                book_id = hit.book_id,
                                title = hit.title,
                                author = hit.author,
                            })
                            self:showTransientInfo(_("Book matched."), 2)
                            if callback then callback(true) end
                        end
                    }
                end
            end
        end
    end

    local isbn = document_isbn(self)
    if isbn then
        local ok_isbn, isbn_result = pcall(self.api.search, self.api, isbn)
        if ok_isbn then
            append_hits(isbn_result)
        end
    end

    if keyword ~= isbn then
        local ok, result = pcall(self.api.search, self.api, keyword)
        if not ok then
            if #rows == 0 then
                local message = tostring(result or "")
                if message:find("API key is not configured", 1, true) then
                    self:showInfo(_(
                        "Please use Weread QR login first. The QR login obtains the official API key automatically."))
                else
                    self:showInfo(message)
                end
                if callback then callback(false) end
                return
            end
        else
            append_hits(result)
        end
    end

    if #rows == 0 then
        self:showInfo(_("No results."))
        if callback then callback(false) end
        return
    end
    self:showList(_("Select matching book"), rows, _("No results."))
end

function Plugin:matchBookAndThen(callback)
    local file = self.ui.document and self.ui.document.file
    if not file then
        if callback then callback(false) end
        return
    end
    local cleaned_name, doc_author = document_search_keyword(self, file)
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
                end
            },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local keyword = dialog:getInputText()
                    UIManager:close(dialog)
                    self:showWereadSearchResults(file, keyword, callback)
                end
            }
        } },
    }
    UIManager:show(dialog)
end

function Plugin:syncUnderlines()
    if not self.settings:get("show_annotations", true) then
        return
    end
    local file = self.ui.document and self.ui.document.file
    if not file then
        self:showInfo(_("No document open."))
        return
    end

    local binding = self.database:getBinding(file)
    if binding then
        self.prefetch:request({
            force = true,
            from_current = true,
            respect_cooldown = true,
            notify = true,
        })
    else
        self:matchBookAndThen(function(success)
            if success then
                self.prefetch:request({
                    force = true,
                    from_current = true,
                    respect_cooldown = false,
                    notify = true,
                })
            end
        end)
    end
end

function Plugin:onReaderReady()
    self._reader_session = self._reader_session + 1
    self._seen_chapter_uid = nil
    self._toc_map = nil
    self._thought_open = false
    OverlayController.onReaderReady(self)
    if self.settings:get("prefetch_thoughts", true) then
        UIManager:scheduleIn(0.8, function()
            if self.ui and self.ui.document and self.ui.document.file then
                local binding = self.database:getBinding(self.ui.document.file)
                if binding then
                    self:prefetchThoughts()
                end
            end
        end)
    end
end

function Plugin:onPageUpdate()
    OverlayController.onPageUpdate(self)
    if self._local_annotation_overlay then
        self._local_annotation_overlay:dropFetchedEmpty(self.api.hasThoughtContent)
    end
    if self._thought_open then return end
    self:onChapterMaybeChanged()
end

function Plugin:onDocumentRerendered()
    OverlayController.onDocumentRerendered(self)
end

function Plugin:onDocumentPartiallyRerendered()
    OverlayController.onDocumentRerendered(self)
end

function Plugin:onCloseDocument()
    self._reader_session = self._reader_session + 1
    self._seen_chapter_uid = nil
    self._chapter_list = nil
    self._toc_map = nil
    self._thought_open = false
    self.prefetch:cancel()
    OverlayController.onCloseDocument(self)
end

function Plugin:onFlushSettings()
    self.settings:flush()
end

return Plugin
