--[[--
Weread Annotation Lite plugin.

@module koplugin.wereadannotationlite
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local logger = require("lib.logger")

local Settings = require("settings")
local Database = require("lib.database")
local API = require("lib.api")
local Locator = require("lib.locator")
local Prefetch = require("lib.prefetch")
local OverlayController = require("ui.overlay_controller")

local Plugin = WidgetContainer:extend {
    name = "wereadannotationlite",
    is_doc_only = false,
    version = "0.1.0",
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
    self:showInfo(tostring(label or "Network") .. ": offline")
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

function Plugin:json_encode(value)
    local json = require("json")
    return json.encode(value)
end

local function normalize_chapter_title(text)
    text = tostring(text or "")
    text = text:gsub("%s+", "")
    text = text:gsub("[%.%-%(%)%[%]《》【】　]", "")
    return text
end

function Plugin:matchTocChapterUid(document, file)
    local chapters = self._chapter_list
    if not chapters or #chapters == 0 then
        chapters = self.database:listChapters(file)
        self._chapter_list = chapters
    end
    if not chapters or #chapters == 0 or type(document.getToc) ~= "function" then
        return nil
    end
    local ok_toc, toc = pcall(document.getToc, document)
    if not ok_toc or type(toc) ~= "table" or #toc == 0 then
        return nil
    end
    local current_pos = 0
    if document.getCurrentPos then
        current_pos = document:getCurrentPos() or 0
    end
    local best_toc, best_toc_pos = nil, -math.huge
    for _, item in ipairs(toc) do
        local pos = tonumber(item.page)
        local xp = item.xpointer or item.pos
        if xp and document.getPosFromXPointer then
            local okp, value = pcall(document.getPosFromXPointer, document, xp)
            if okp then pos = tonumber(value) or pos end
        end
        if pos and pos <= current_pos and pos >= best_toc_pos then
            best_toc_pos = pos
            best_toc = item
        end
    end
    if not best_toc then return nil end
    local want = normalize_chapter_title(best_toc.title)
    if want == "" then return nil end
    for _, chapter in ipairs(chapters) do
        if normalize_chapter_title(chapter.title) == want then
            return tostring(chapter.chapterUid)
        end
    end
    local hit
    for _, chapter in ipairs(chapters) do
        local title = normalize_chapter_title(chapter.title)
        if title ~= "" and (want:find(title, 1, true) or title:find(want, 1, true)) then
            if hit then return nil end
            hit = chapter
        end
    end
    return hit and tostring(hit.chapterUid) or nil
end

function Plugin:tocChapterIsAfter(cached_uid, toc_uid, file)
    if not cached_uid or not toc_uid or cached_uid == toc_uid then return false end
    local chapters = self._chapter_list
    if not chapters or #chapters == 0 then
        chapters = self.database:listChapters(file)
        self._chapter_list = chapters
    end
    local cached_idx, toc_idx
    cached_uid = tostring(cached_uid)
    toc_uid = tostring(toc_uid)
    for i, chapter in ipairs(chapters or {}) do
        local uid = tostring(chapter.chapterUid)
        if uid == cached_uid then cached_idx = i end
        if uid == toc_uid then toc_idx = i end
    end
    return cached_idx and toc_idx and toc_idx > cached_idx
end

function Plugin:currentWereadChapterUid(opts)
    opts = opts or {}
    local document = self.ui and self.ui.document
    local file = document and document.file
    if not file then return nil end

    if document.getCurrentPos and type(document.getPosFromXPointer) == "function" then
        local starts = self._chapter_starts
        if not starts then
            local records = self._local_annotation_overlay and self._local_annotation_overlay.records
            starts = {}
            local seen = {}
            for _, record in ipairs(records or {}) do
                local ok, position = pcall(document.getPosFromXPointer, document, record.pos0)
                position = ok and tonumber(position) or nil
                if position and record.chapter_uid then
                    local uid = tostring(record.chapter_uid)
                    if not seen[uid] or position < seen[uid] then
                        seen[uid] = position
                    end
                end
            end
            for uid, position in pairs(seen) do
                starts[#starts + 1] = { uid = uid, pos = position }
            end
            table.sort(starts, function(a, b) return a.pos < b.pos end)
            self._chapter_starts = starts
        end
        if #starts > 0 then
            local current = document:getCurrentPos() or 0
            local chapter
            local later = false
            for _, item in ipairs(starts) do
                if item.pos <= current then
                    chapter = item.uid
                else
                    later = true
                    break
                end
            end
            if chapter and later then
                return chapter
            end
            if chapter and not later then
                local toc_uid = self:matchTocChapterUid(document, file)
                if self:tocChapterIsAfter(chapter, toc_uid, file) then
                    return toc_uid
                end
                return chapter
            end
        end
    end

    if not opts.allow_toc then return nil end
    return self:matchTocChapterUid(document, file)
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
    local chapter = self:currentWereadChapterUid({ allow_toc = true })
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
    if #items == 0 then
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
            self.database:saveThoughts(file, record.chapter_uid, record.range,
                self:json_encode(items), true)
            if self._local_annotation_overlay then
                self._local_annotation_overlay:updateThought(record.chapter_uid, record.range, items)
            end
        elseif not ok then
            UIManager:close(loading)
            self._thought_open = false
            self.prefetch:resume()
            self:showInfo(tostring(result))
            return true
        end
        UIManager:close(loading)
    end
    if #items == 0 then
        self._thought_open = false
        self.prefetch:resume()
        self:showTransientInfo(_("No thoughts were returned for this underline."), 3)
        return true
    end
    require("ui.thought_popup").show {
        pages = items,
        position = "bottom",
        height_ratio = 0.75,
        doc_font_size = require("device").screen:scaleBySize(22),
        close_callback = function()
            self._thought_open = false
            self.prefetch:resume()
        end,
    }
    return true
end

function Plugin:matchBookAndThen(callback)
    local file = self.ui.document and self.ui.document.file
    if not file then
        if callback then callback(false) end
        return
    end
    local raw_name = file:match("([^/]+)%.[^%.]+$") or ""
    local cleaned_name = raw_name
        :gsub("%s*（.-）", "")
        :gsub("%s*%(.-%)", "")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new {
        title = _("Search Weread book"),
        input = cleaned_name,
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
                    local ok, result = pcall(self.api.search, self.api, keyword)
                    if not ok then
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

                    local rows = {}
                    local source = result
                    if type(source) == "table" and type(source.results) == "table" then
                        source = source.results
                    end
                    if type(source) == "table" and type(source.books) == "table" then
                        source = source.books
                    end
                    for _row_index, row in ipairs(source or {}) do
                        local candidates = type(row) == "table" and row.books or nil
                        if type(candidates) ~= "table" then candidates = { row } end
                        for _candidate_index, candidate in ipairs(candidates) do
                            local info = candidate.bookInfo or candidate
                            if info.bookId then
                                rows[#rows + 1] = {
                                    text = info.title or info.bookId,
                                    post_text = info.author or "",
                                    callback = function()
                                        self.database:saveBinding(file, {
                                            book_id = tostring(info.bookId),
                                            title = info.title,
                                            author = info.author,
                                        })
                                        self:showTransientInfo(_("Book matched."), 2)
                                        if callback then callback(true) end
                                    end
                                }
                            end
                        end
                    end
                    if #rows == 0 then
                        self:showInfo(_("No results."))
                        if callback then callback(false) end
                        return
                    end
                    self:showList(_("Select matching book"), rows, _("No results."))
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
                    from_start = true,
                    respect_cooldown = false,
                    notify = true,
                })
            else
                self:showInfo(_("Sync cancelled."))
            end
        end)
    end
end

function Plugin:onReaderReady()
    self._reader_session = self._reader_session + 1
    self._seen_chapter_uid = nil
    self._chapter_starts = nil
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
    if self._thought_open then return end
    self:onChapterMaybeChanged()
end

function Plugin:onCloseDocument()
    self._reader_session = self._reader_session + 1
    self._seen_chapter_uid = nil
    self._chapter_list = nil
    self._chapter_starts = nil
    self._thought_open = false
    self.prefetch:cancel()
    OverlayController.onCloseDocument(self)
end

function Plugin:onFlushSettings()
    self.settings:flush()
end

return Plugin
