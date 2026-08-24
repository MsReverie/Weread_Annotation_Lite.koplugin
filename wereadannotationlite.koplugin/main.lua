local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local Settings = require("WereadAnnotationLite.settings")
local Database = require("WereadAnnotationLite.lib.database")
local API = require("WereadAnnotationLite.lib.api")
local Locator = require("WereadAnnotationLite.lib.locator")
local Prefetch = require("WereadAnnotationLite.lib.prefetch")
local OverlayController = require("WereadAnnotationLite.ui.overlay_controller")

local Plugin = WidgetContainer:extend{
    name = "wereadannotationlite",
    version = "0.1.0",
}

function Plugin:init()
    self.settings = Settings:new()
    self.database = Database:new(self.settings)
    self.api = API:new(self.settings)
    self.qr_login = require("WereadAnnotationLite.lib.qr_login"):new(self, self.api, self.settings)
    self.prefetch = Prefetch:new(self)
    self._reader_session = 0
    self.ui.menu:registerToMainMenu(self)
end


function Plugin:addToMainMenu(menu_items)
    menu_items.weread_local_annotations = {
        text = _("Weread Annotation Lite"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return {
                { text = _("Match current local book"), callback = function()
                    self:matchCurrentBook()
                end },
                { text = _("Sync underlines"), callback = function()
                    self:syncUnderlines()
                end },
                { text = _("Prefetch thoughts"), callback = function()
                    self:prefetchThoughts(true)
                end },
                { text = _("Show underlines"), checked_func = function()
                    return self.settings:get("show_annotations", true)
                end, callback = function()
                    require("WereadAnnotationLite.ui.overlay_controller").toggleVisibility(self)
                end },
                { text = _("Weread QR login"), callback = function()
                    self.qr_login:start()
                end },
                { text = _("Clear current book data"), callback = function()
                    self:clearCurrentData()
                end },
            }
        end,
    }
end

function Plugin:isNetworkOnline()
    return self.api:isOnline()
end

function Plugin:runOnlineTask(_label, callback)
    local ok, err = pcall(callback)
    if not ok then self:showInfo(tostring(err)); return false end
    return true
end

function Plugin:showBusy(_text) end
function Plugin:closeBusy() end
function Plugin:showOffline(label)
    self:showInfo(tostring(label or "Network") .. ": offline")
end
function Plugin:showInputDialog(dialog)
    UIManager:show(dialog)
end
function Plugin:refreshUI() end
function Plugin:refreshLoginMenu() end
function Plugin:onWereadAccountChanged() end

function Plugin:clearCurrentData()
    local file = self.ui.document and self.ui.document.file
    if not file then return end
    local ConfirmBox = require("ui/widget/confirmbox")
    UIManager:show(ConfirmBox:new{
        text = _("Clear Weread annotations for this book?"),
        ok_callback = function()
            self.database:clear(file)
            if self._local_annotation_overlay then self._local_annotation_overlay:setRecords({}) end
            self:showTransientInfo(_("Current book data cleared."), 2)
        end,
    })
end

function Plugin:showInfo(text)
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{ text = tostring(text or "") })
end

function Plugin:showTransientInfo(text, timeout)
    local Notification = require("ui/widget/notification")
    UIManager:show(Notification:new{ text = tostring(text or ""), timeout = timeout or 2 })
end

function Plugin:showList(title, items, empty_text)
    if not items or #items == 0 then self:showInfo(empty_text or _("No items.")); return end
    local MenuWidget = require("ui/widget/menu")
    UIManager:show(MenuWidget:new{ title = title, item_table = items })
end

function Plugin:json_encode(value)
    local json = require("json")
    return json.encode(value)
end

function Plugin:prefetchThoughts(immediate)
    local file = self.ui.document and self.ui.document.file
    local entry = file and self.database:getDocument(file)
    if not entry or not entry.binding then
        self:showInfo(_("Match this local book first.")); return
    end
    local chapter
    local document = self.ui and self.ui.document
    local current = document and document.getCurrentPos and document:getCurrentPos() or 0
    local best_pos = -math.huge
    for _, record in ipairs(entry.records or {}) do
        local ok, position = pcall(document.getPosFromXPointer, document, record.pos0)
        position = ok and tonumber(position) or nil
        if position and position <= current and position >= best_pos then
            best_pos = position
            chapter = record.chapter_uid
        end
    end
    chapter = chapter or (entry.records[1] and entry.records[1].chapter_uid)
    if not chapter then self:showInfo(_("Sync underlines first.")); return end
    self.prefetch:start(file, entry.binding, chapter, immediate)
    self:showTransientInfo(_("Thought prefetch started."), 2)
end

function Plugin:openThought(record)
    local file = self.ui.document and self.ui.document.file
    local entry = file and self.database:getDocument(file)
    if not entry or not entry.binding then return true end
    local items = type(record.items) == "table" and record.items or {}
    local chapter_uid = tonumber(record.chapter_uid) or record.chapter_uid
    local loading
    if #items == 0 then
        local InfoMessage = require("ui/widget/infomessage")
        loading = InfoMessage:new{ text = _("Loading thoughts…") }
        UIManager:show(loading)
        local ok, result = pcall(self.api.reviews, self.api, entry.binding.book_id,
            chapter_uid, { record.range })
        if ok and result and result.reviews then
            for _, range_review in ipairs(result.reviews) do
                local pages = range_review.pageReviews
                if type(pages) ~= "table" or next(pages) == nil then
                    pages = range_review.review and { range_review } or {}
                end
                local page_index = 0
                for _, page in ipairs(pages) do
                    page_index = page_index + 1
                    local review = page.review or {}
                    local author = review.author or {}
                    local abstract
                    if page_index == 1 then
                        abstract = review.abstract or review.contextAbstract
                        if type(abstract) ~= "string" or abstract == "" then abstract = nil end
                    end
                    items[#items + 1] = {
                        abstract = abstract,
                        author = tostring(author.nick or author.name or "匿名"),
                        content = tostring(review.content or ""),
                        likes_count = tonumber(page.likesCount) or 0,
                    }
                end
            end
            self.database:saveThoughts(file, record.chapter_uid, record.range,
                require("json").encode(items), true)
        elseif not ok then
            UIManager:close(loading)
            self:showInfo(tostring(result))
            return true
        end
        UIManager:close(loading)
    end
    if #items == 0 then
        self:showTransientInfo(_("No thoughts were returned for this underline."), 3)
        return true
    end
    require("WereadAnnotationLite.ui.thought_popup").show{
        pages = items,
        position = "bottom",
        height_ratio = 0.55,
        doc_font_size = require("device").screen:scaleBySize(22),
    }
    return true
end

function Plugin:matchCurrentBook()
    local file = self.ui.document and self.ui.document.file
    if not file then return end
    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new{
        title = _("Search Weread book"),
        input = file:match("([^/]+)%.[^%.]+$") or "",
        buttons = {{ { text = _("Cancel"), callback = function() UIManager:close(dialog) end }, {
            text = _("Search"), is_enter_default = true, callback = function()
                local keyword = dialog:getInputText(); UIManager:close(dialog)
                local ok, result = pcall(self.api.search, self.api, keyword)
                if not ok then
                    local message = tostring(result or "")
                    if message:find("API key is not configured", 1, true) then
                        self:showInfo(_("Please use Weread QR login first. The QR login obtains the official API key automatically."))
                    else
                        self:showInfo(message)
                    end
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
                            rows[#rows + 1] = { text = info.title or info.bookId,
                                post_text = info.author or "", callback = function()
                                self.database:saveBinding(file, {
                                    book_id = tostring(info.bookId), title = info.title, author = info.author,
                                })
                                self:showTransientInfo(_("Book matched."), 2)
                                end } end
                    end
                end
                self:showList(_("Select matching book"), rows, _("No results."))
            end } }},
    }
    UIManager:show(dialog)
end

function Plugin:syncUnderlines()
    local file = self.ui.document and self.ui.document.file
    local entry = file and self.database:getDocument(file)
    if not entry or not entry.binding then
        self:showInfo(_("Match this local book first."))
        return
    end

    local ok, chapters = pcall(self.api.chapters, self.api, entry.binding.book_id)
    if not ok or type(chapters) ~= "table" or #chapters == 0 then
        if not ok and (tostring(chapters):find("-2012", 1, true)
                or tostring(chapters):find("登录超时", 1, true)) then
            self:showInfo(_("Weread login has expired. Please use Weread QR login again."))
            return
        end
        self:showInfo(tostring(ok and _("Could not load the Weread chapter list.") or chapters))
        return
    end

    self.database:saveChapters(file, chapters)

    local ProgressDialog = require("WereadAnnotationLite.ui.progress_dialog")
    local progress = ProgressDialog:new{
        title = _("Syncing Weread underlines (concurrent 3)…"),
        description = _("Fetching popular underlines for each chapter, 3 at a time."),
        progress_max = #chapters,
        buttons = {},
    }
    progress:show()

    -- 并发控制
    local CONCURRENCY = 5
    local pending = {}
    for i, ch in ipairs(chapters) do
        table.insert(pending, { index = i, chapter = ch })
    end

    local running = 0
    local completed = 0
    local total = #chapters
    local all_located = {}
    local failed_count = 0
    local last_error_msg = nil
    local finished = false

    local socket_ok, socket = pcall(require, "socket")

    local function processNext()
        if finished then return end
        if #pending == 0 and running == 0 then
            finished = true
            progress:close()
			
            if #all_located > 0 then
                if failed_count == 0 then
                    self.database:clearRecords(file)
                end
                self.database:saveRecords(file, all_located)
                if self._local_annotation_overlay then
                    self._local_annotation_overlay:setRecords(
                        self.database:getDocument(file).records or all_located
                    )
                end
            end

            local summary = string.format(
                _("Matched %d popular underlines; fetched %d/%d chapters; %d failed."),
                #all_located, total - failed_count, total, failed_count
            )
            if #all_located == 0 and total > 0 then
                summary = summary .. "\n" .. _("No downloaded underlines matched this local book; existing data was kept.")
            end
            if last_error_msg then
                summary = summary .. "\n" .. tostring(last_error_msg)
            end
            self:showInfo(summary)
            return
        end

        if running >= CONCURRENCY then return end
        if #pending == 0 then return end

        local task = table.remove(pending, 1)
        running = running + 1
        local index = task.index
        local chapter = task.chapter
        local chapter_uid = chapter.chapterUid

        progress:setTitle(string.format(
            _("Syncing popular underlines · %d/%d chapters done (concurrent 3)"),
            completed, total
        ))

        -- 使用异步调度发起请求，避免阻塞UI
        UIManager:scheduleIn(0, function()
            local function doRequest(retry)
                retry = retry or 0
                local cache = self.database:getUnderlineCache(file, chapter_uid)
                local ok, data = pcall(self.api.popular_underlines_sync, self.api,
                    entry.binding.book_id, chapter_uid, cache and cache.synckey or 0)

                if not ok then
                    -- 重试（最多3次，指数退避）
                    if retry < 3 then
                        local delay = 1 * (2 ^ retry)
                        UIManager:scheduleIn(delay, function()
                            doRequest(retry + 1)
                        end)
                        return
                    else
                        -- 重试失败，记录失败
                        failed_count = failed_count + 1
                        last_error_msg = tostring(data)
                        running = running - 1
                        completed = completed + 1
                        progress:reportProgress(completed)
                        processNext()
                        return
                    end
                end

                -- 成功处理
                local rows
                if data.unchanged and cache then
                    rows = cache.items or {}
                else
                    rows = data.items or {}
                    self.database:saveUnderlineCache(file, chapter_uid,
                        data.synckey, rows)
                end

                table.sort(rows, function(a, b)
                    local ac = tonumber(a.count or a.totalCount) or 0
                    local bc = tonumber(b.count or b.totalCount) or 0
                    if ac ~= bc then return ac > bc end
                    local as = tonumber(a.score) or 0
                    local bs = tonumber(b.score) or 0
                    if as ~= bs then return as > bs end
                    return tostring(a.range or "") < tostring(b.range or "")
                end)

                -- 在本地文档中定位划线
                local located = Locator.locate(self.ui.document, chapter_uid, rows)
                for _, record in ipairs(located) do
                    table.insert(all_located, record)
                end

                running = running - 1
                completed = completed + 1
                progress:reportProgress(completed)
                processNext()
            end

            doRequest(0)
        end)
    end

    for _ = 1, CONCURRENCY do
        processNext()
    end
end

function Plugin:onReaderReady()
    self._reader_session = self._reader_session + 1
    OverlayController.onReaderReady(self)
    if self.settings:get("prefetch_thoughts", true) then
        UIManager:scheduleIn(0.8, function()
            if self.ui and self.ui.document and self.ui.document.file then
                local entry = self.database:getDocument(self.ui.document.file)
                if entry and entry.binding then
                    self:prefetchThoughts(false)
                end
            end
        end)
    end
end

function Plugin:onPageUpdate()
    OverlayController.onPageUpdate(self)
end

function Plugin:onCloseDocument()
    self._reader_session = self._reader_session + 1
    self.prefetch:cancel()
    OverlayController.onCloseDocument(self)
end

function Plugin:onFlushSettings()
    self.settings:flush()
end

return Plugin
