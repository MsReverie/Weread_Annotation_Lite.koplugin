local WidgetContainer = require("ui/widget/container/widgetcontainer")
local UIManager = require("ui/uimanager")
local _ = require("gettext")
local InfoMessage = require("ui/widget/infomessage")
local ProgressbarDialog = require("ui/widget/progressbardialog")
local logger = require("WereadAnnotationLite.lib.logger")

local Settings = require("WereadAnnotationLite.settings")
local Database = require("WereadAnnotationLite.lib.database")
local API = require("WereadAnnotationLite.lib.api")
local Locator = require("WereadAnnotationLite.lib.locator")
local Prefetch = require("WereadAnnotationLite.lib.prefetch")
local OverlayController = require("WereadAnnotationLite.ui.overlay_controller")

local Plugin = WidgetContainer:extend {
    name = "wereadannotationlite",
    version = "0.1.0",
}

function Plugin:init()
    self.settings = Settings:new()
    logger.setDebug(self.settings:get("debug_log", false))
    self.database = Database:new(self.settings)
    self.api = API:new(self.settings)
    self.qr_login = require("WereadAnnotationLite.lib.qr_login"):new(self, self.api, self.settings)
    self.prefetch = Prefetch:new(self)
    self._reader_session = 0
    self.ui.menu:registerToMainMenu(self)
end

function Plugin:addToMainMenu(menu_items)
    local function is_enabled()
        return self.settings:get("show_annotations", true)
    end
    menu_items.weread_local_annotations = {
        text = _("Weread Annotation Lite"),
        sorting_hint = "tools",
        --获取总开关状态
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
                            local entry = self.database:getDocument(self.ui.document.file)
                            if entry and entry.binding then
                                self:prefetchThoughts(false)
                            end
                        end
                    end
                },
                {
                    text = _("Sync underlines"),
                    enabled_func = is_enabled,
                    callback = function()
                        self:syncUnderlines()
                    end
                },
                {
                    text = _("Auto prefetch thoughts"),
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
                                local entry = self.database:getDocument(self.ui.document.file)
                                if entry and entry.binding then
                                    self:prefetchThoughts(false)
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

function Plugin:showBusy(text)
end

function Plugin:closeBusy()
end

function Plugin:runOnlineTask(_label, callback)
    local ok, err = pcall(callback)
    if not ok then
        self:showInfo(tostring(err))
        return false
    end
    return true
end

function Plugin:refreshUI()
end

function Plugin:refreshLoginMenu()
end

function Plugin:onWereadAccountChanged()
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
    UIManager:show(MenuWidget:new { title = title, item_table = items })
end

function Plugin:json_encode(value)
    local json = require("json")
    return json.encode(value)
end

function Plugin:prefetchThoughts(immediate, silent)
    if not self.settings:get("show_annotations", true) then
        return
    end

    local file = self.ui.document and self.ui.document.file
    local entry = file and self.database:getDocument(file)

    if silent == nil then
        silent = not self.settings:get("prefetch_notify", false)
    end
    -- 没有绑定 → 不预取
    if not entry or not entry.binding then
        if not silent then
            self:showTransientInfo(_("Match this local book first."))
        end
        return
    end

    -- 没有划线记录 → 不预取
    if not entry.records or #entry.records == 0 then
        if not silent then
            self:showTransientInfo(_("No underlines yet. Sync first."))
        end
        return
    end

    -- 定位当前章节
    local chapter
    local document = self.ui and self.ui.document
    local current = document and document.getCurrentPos and document:getCurrentPos() or 0
    local best_pos = -math.huge
    for _, record in ipairs(entry.records) do
        local ok, position = pcall(document.getPosFromXPointer, document, record.pos0)
        position = ok and position or nil
        if position and position <= current and position >= best_pos then
            best_pos = position
            chapter = record.chapter_uid
        end
    end
    chapter = chapter or (entry.records[1] and entry.records[1].chapter_uid)

    if not chapter then
        if not silent then
            self:showTransientInfo(_("Sync underlines first."))
        end
        return
    end

    -- 启动预取
    self.prefetch:start(file, entry.binding, chapter, immediate)
    if not silent then
        self:showTransientInfo(_("Thought prefetch started."), 2)
    end
end

function Plugin:openThought(record)
    if not self.settings:get("show_annotations", true) then
        return true
    end
    local file = self.ui.document and self.ui.document.file
    local entry = file and self.database:getDocument(file)
    if not entry or not entry.binding then return true end
    local items = type(record.items) == "table" and record.items or {}
    local chapter_uid = record.chapter_uid
    local loading
    if #items == 0 then
        local InfoMessage = require("ui/widget/infomessage")
        loading = InfoMessage:new { text = _("Loading thoughts…") }
        UIManager:show(loading)
        local ok, result = pcall(self.api.reviews, self.api, entry.binding.book_id,
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
    require("WereadAnnotationLite.ui.thought_popup").show {
        pages = items,
        position = "bottom",
        height_ratio = 0.75,
        doc_font_size = require("device").screen:scaleBySize(22),
    }
    return true
end

function Plugin:matchBookAndThen(callback)
    local file = self.ui.document and self.ui.document.file
    if not file then
        if callback then callback(false) end
        return
    end

    local InputDialog = require("ui/widget/inputdialog")
    local dialog
    dialog = InputDialog:new {
        title = _("Search Weread book"),
        input = file:match("([^/]+)%.[^%.]+$") or "",
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

    -- 检查是否有绑定
    local entry = self.database:getDocument(file)
    if entry and entry.binding then
        self:doSyncUnderlines()
    else
        -- 没有绑定，启动匹配流程
        self:matchBookAndThen(function(success)
            if success then
                self:doSyncUnderlines()
            else
                self:showInfo(_("Sync cancelled."))
            end
        end)
    end
end

function Plugin:doSyncUnderlines()
    self.prefetch:cancel()
    local file = self.ui.document and self.ui.document.file
    local entry = self.database:getDocument(file)
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

        local error_msg = ok and _("Could not load the Weread chapter list.") or tostring(chapters)
        self:showInfo(error_msg .. "\n" .. _("Please log in first."))
        return
    end

    self.database:saveChapters(file, chapters)

    local dialog = ProgressbarDialog:new {
        title = _("Syncing underlines..."),
        progress_max = #chapters,
    }
    UIManager:show(dialog)

    -- ========== 并发控制 ==========
    local CONCURRENCY = tonumber(self.settings:get("sync_concurrency", 5)) or 5
    local BASE_INTERVAL = tonumber(self.settings:get("sync_base_interval", 0.6)) or 0.6
    local JITTER_MAX = tonumber(self.settings:get("sync_jitter_max", 0.3)) or 0.3
    local last_request_time = 0

    local pending = {}
    for i, ch in ipairs(chapters) do
        table.insert(pending, { index = i, chapter = ch })
    end

    local running = 0
    local completed = 0
    local all_located = {}
    local failed_count = 0
    local last_error_msg = nil
    local finished = false

    local function updateProgress(completed)
        dialog:reportProgress(completed)
    end

    local function processNext()
        -- 如果已完成或用户取消，则停止
        if finished or dialog.cancelled then
            if not finished then
                finished = true
                UIManager:close(dialog)
                restorePrefetch()
            end
            return
        end

        if #pending == 0 and running == 0 then
            finished = true
            UIManager:close(dialog)

            -- 保存匹配到的划线到数据库
            if #all_located > 0 then
                if failed_count == 0 then
                    self.database:clearRecords(file)
                end
                self.database:saveRecords(file, all_located)
                if self._local_annotation_overlay then
                    self._local_annotation_overlay:setRecords(all_located)
                end
            end

            local summary = string.format(
                _("Matched %d popular underlines; fetched %d/%d chapters; %d failed."),
                #all_located, #chapters - failed_count, #chapters, failed_count
            )
            if #all_located == 0 and #chapters > 0 then
                summary = summary ..
                    "\n" .. _("No downloaded underlines matched this local book; existing data was kept.")
            end
            if last_error_msg then
                summary = summary .. "\n" .. tostring(last_error_msg)
            end
            self:showInfo(summary)
            restorePrefetch()
            return
        end

        if running >= CONCURRENCY then return end
        if #pending == 0 then return end

        -- 检查请求间隔（带随机抖动）
        local now = os.clock()
        local elapsed = now - last_request_time
        local target_interval = BASE_INTERVAL + math.random() * JITTER_MAX
        local wait = target_interval - elapsed

        if wait > 0 then
            UIManager:scheduleIn(wait, function()
                processNext()
            end)
            return
        end

        -- 更新上次请求时间，立即发起新请求
        last_request_time = os.clock()

        local task = table.remove(pending, 1)
        running = running + 1
        local chapter = task.chapter
        local chapter_uid = chapter.chapterUid

        UIManager:scheduleIn(0, function()
            local function doRequest(retry)
                -- 每次请求前检查取消状态
                if dialog.cancelled then
                    running = running - 1
                    processNext()
                    return
                end

                retry = retry or 0
                local cache = self.database:getUnderlineCache(file, chapter_uid)
                local ok, data = pcall(self.api.popular_underlines_sync, self.api,
                    entry.binding.book_id, chapter_uid, cache and cache.synckey or 0)

                if not ok then
                    if retry < 3 then
                        local delay = 1 * (2 ^ retry)
                        UIManager:scheduleIn(delay, function()
                            doRequest(retry + 1)
                        end)
                        return
                    else
                        failed_count = failed_count + 1
                        last_error_msg = tostring(data)
                        running = running - 1
                        completed = completed + 1
                        updateProgress(completed)
                        processNext()
                        return
                    end
                end

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

                local located = Locator.locate(self.ui.document, chapter_uid, rows)
                for _, record in ipairs(located) do
                    table.insert(all_located, record)
                end

                running = running - 1
                completed = completed + 1
                updateProgress(completed)
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
