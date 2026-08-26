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
    -- 取消正在进行的预取
    self.prefetch:cancel()

    local file = self.ui.document and self.ui.document.file
    local entry = self.database:getDocument(file)
    if not entry or not entry.binding then
        self:showInfo(_("Match this local book first."))
        return
    end

    -- 获取章节列表
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

    -- 创建进度条
    local dialog = ProgressbarDialog:new {
        title = _("Syncing underlines..."),
        progress_max = #chapters,
    }
    UIManager:show(dialog)

    -- 收集结果
    local all_located = {}
    local failed_count = 0
    local last_error_msg = nil
    local completed = 0

    -- 协程主流程
    local co = coroutine.create(function()
        -- 逐个处理章节（可调并发数，此处改为顺序，但可以轻松改为并发）
        for idx, chapter in ipairs(chapters) do
            local chapter_uid = chapter.chapterUid

            -- 1. 检查缓存
            local cache = self.database:getUnderlineCache(file, chapter_uid)
            if cache then
                local rows = cache.items or {}
                if #rows > 0 then
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
                end
                completed = completed + 1
                dialog:reportProgress(completed)
                coroutine.yield()
            else
                -- 2. 无缓存，发起网络请求（单次，失败即终止）
                local ok_req, result = pcall(self.api.popular_underlines_sync, self.api,
                    entry.binding.book_id, chapter_uid, 0)
                if not ok_req or not result then
                    local err_msg = tostring(result or "Unknown error")
                    last_error_msg = err_msg
                    UIManager:close(dialog)
                    error("Sync failed at chapter " .. tostring(idx) .. ": " .. err_msg)
                end

                local data = result
                local rows = data.items or {}
                self.database:saveUnderlineCache(file, chapter_uid, data.synckey, rows)
                if #rows > 0 then
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
                end
                completed = completed + 1
                dialog:reportProgress(completed)
                coroutine.yield()
            end
        end

        -- 所有章节处理完毕
        UIManager:close(dialog)
        UIManager:setDirty("all", "full")

        -- 保存结果
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
            _("Matched %d popular underlines; fetched %d/%d chapters."),
            #all_located, #chapters - failed_count, #chapters, failed_count
        )
        if #all_located == 0 and #chapters > 0 then
            summary = summary ..
                "\n" .. _("No downloaded underlines matched this local book; existing data was kept.")
        end
        if last_error_msg then
            summary = summary .. "\n" .. tostring(last_error_msg)
        end

        -- 显示信息弹窗
        UIManager:show(InfoMessage:new {
            text = summary,
            callback = function()
                UIManager:setDirty("all", "full")
                self.prefetch:scheduleRestore()
            end
        })
        return -- 协程结束
    end)

    -- 启动协程调度
    local function resume_co()
        local status, err = coroutine.resume(co)
        if not status then
            logger.err("Sync coroutine error:", err)
            UIManager:close(dialog)
            self:showInfo(_("Sync failed: ") .. tostring(err))
        elseif coroutine.status(co) ~= "dead" then
            -- 协程未结束，安排下一次继续执行（保证 UI 刷新）
            UIManager:scheduleIn(0.05, resume_co)
        end
    end

    -- 开始执行
    resume_co()
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
