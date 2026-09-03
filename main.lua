--[[--
Weread Annotation Lite plugin.

@module koplugin.wereadannotationlite
--]]--

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local Dispatcher = require("dispatcher")
local UIManager = require("ui/uimanager")
local _ = require("lib.i18n")
local logger = require("lib.logger")

local Settings = require("settings")
local Database = require("lib.database")
local API = require("lib.api")
local Prefetch = require("lib.prefetch")
local OverlayController = require("ui.overlay_controller")
local TocMap = require("lib.toc_map")
local BookMatch = require("lib.book_matcher")
local ThoughtHandler = require("ui.thought_handler")
local Menu = require("lib.menu")

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
    self.toc_map = TocMap.newInstance(self)
    self._reader_session = 0
    self._wake_token = 0
    self._wake_hold = false
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    require("lib.ota").cleanup_backup(self)
end

function Plugin:onDispatcherRegisterActions()
    Dispatcher:registerAction("weread_fetch_underlines", {
        category = "none",
        event = "WereadFetchUnderlines",
        title = _("Weread Annotation Lite: Fetch underlines"),
        general = true,
    })
end

function Plugin:onWereadFetchUnderlines()
    self:syncUnderlines()
    return true
end

function Plugin:addToMainMenu(menu_items)
    menu_items.wereadannotationlite = {
        text = _("Weread Annotation Lite"),
        sorting_hint = "tools",
        sub_item_table_func = function()
            return Menu.build(self)
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

function Plugin:onChapterMaybeChanged()
    if self._wake_hold then return end
    if self._thought_open then return end
    if not self.settings:get("show_annotations", true) then return end
    if not self.settings:get("prefetch_thoughts", true) then return end
    if not (self.ui and self.ui.document) then return end
    self.prefetch:ensureAhead()
end

function Plugin:_prefetchWhenNetworkReady()
    if not self.api:isOnline() then return end
    self._wake_hold = false
    if self._thought_open then return end
    if not (self.ui and self.ui.document) then return end
    self.prefetch:resume()
    self:onChapterMaybeChanged()
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
    local chapter = self.toc_map:currentWereadChapterUid()
    if not chapter then
        if not silent then
            self:showTransientInfo(_("Could not detect the current chapter."))
        end
        return
    end
    self.prefetch:onChapter(chapter)
    if not silent then
        self:showTransientInfo(_("Prefetch started."), 2)
    end
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
        BookMatch.matchDialog(self, function(success)
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

function Plugin:openThought(record)
    return ThoughtHandler.open(self, record)
end

function Plugin:onReaderReady()
    self._reader_session = self._reader_session + 1
    self._wake_token = (self._wake_token or 0) + 1
    self._wake_hold = false
    self._thought_open = false
    self.toc_map:clearCache()
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

function Plugin:onPageUpdate(pageno)
    OverlayController.onPageUpdate(self)
    self.toc_map:setPageno(pageno)
    if self._local_annotation_overlay then
        self._local_annotation_overlay:dropFetchedEmpty(self.api.hasThoughtContent)
    end
    if self._thought_open then return end
    self:onChapterMaybeChanged()
end

function Plugin:onPosUpdate(_pos, pageno)
    self.toc_map:setPageno(pageno)
    if self._thought_open then return end
    self:onChapterMaybeChanged()
end

function Plugin:onNetworkConnected()
    self._wake_token = (self._wake_token or 0) + 1
    self:_prefetchWhenNetworkReady()
end

function Plugin:onResume()
    self._wake_token = (self._wake_token or 0) + 1
    local token = self._wake_token
    self._wake_hold = true
    if not self._thought_open and self.prefetch.job then
        self.prefetch:pause()
    end
    UIManager:scheduleIn(2, function()
        if token ~= self._wake_token then return end
        self:_prefetchWhenNetworkReady()
    end)
end

function Plugin:onDocumentRerendered()
    OverlayController.onDocumentRerendered(self)
    self:onChapterMaybeChanged()
end

function Plugin:onDocumentPartiallyRerendered()
    OverlayController.onDocumentRerendered(self)
end

function Plugin:onCloseDocument()
    self._reader_session = self._reader_session + 1
    self._wake_token = (self._wake_token or 0) + 1
    self._wake_hold = false
    self._thought_open = false
    self.toc_map:clearCache()
    self.prefetch:cancel()
    OverlayController.onCloseDocument(self)
end

function Plugin:onFlushSettings()
    self.settings:flush()
end

return Plugin
