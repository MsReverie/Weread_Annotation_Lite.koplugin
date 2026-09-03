local UIManager = require("ui/uimanager")
local logger = require("lib.logger")
local Locator = require("lib.locator")
local ffiutil = require("ffi/util")
local json = require("json")
local _ = require("lib.i18n")

local Prefetch = {}
Prefetch.__index = Prefetch

function Prefetch:new(plugin)
    return setmetatable({
        plugin = plugin,
        gen = 0,
        last_underline_at = 0,
    }, self)
end

function Prefetch:_holdStandby()
    if self._standby_held then return end
    UIManager:preventStandby()
    self._standby_held = true
end

function Prefetch:_releaseStandby()
    if not self._standby_held then return end
    self._standby_held = false
    UIManager:allowStandby()
end

function Prefetch:_openJobDb(file)
    self.plugin.database:beginSession(file, true)
    self._db_session = true
end

function Prefetch:_closeJobDb()
    if not self._db_session then return end
    self._db_session = false
    self.plugin.database:endSession()
end

function Prefetch:_stopBg()
    local pid = self._bg_pid
    local fd = self._bg_fd
    self._bg_pid = nil
    self._bg_fd = nil
    if pid and ffiutil.terminateSubProcess then
        pcall(ffiutil.terminateSubProcess, pid)
    end
    if fd then
        pcall(function() ffiutil.readAllFromFD(fd) end)
    end
end

-- Run task() off the UI thread when fork is available (e-ink Linux).
-- on_done(ok, result) is always invoked from a UIManager tick.
function Prefetch:_bg(task, on_done)
    local gen = self.gen
    local spawned, pid, parent_read_fd = pcall(ffiutil.runInSubProcess, function(_, child_write_fd)
        local ok, result = pcall(task)
        local payload
        local packed, err = pcall(json.encode, {
            ok = ok == true,
            result = ok and result or tostring(result),
        })
        if packed then
            payload = err
        else
            payload = json.encode({ ok = false, result = "encode failed" })
        end
        ffiutil.writeToFD(child_write_fd, payload, true)
    end, true)
    if not spawned or not pid then
        local ok, result = pcall(task)
        UIManager:scheduleIn(0.05, function()
            if not self:alive(gen) then return end
            on_done(ok, result)
        end)
        return
    end
    self._bg_pid = pid
    self._bg_fd = parent_read_fd
    local function poll()
        if self._bg_pid ~= pid then
            return
        end
        if not ffiutil.isSubProcessDone(pid) then
            UIManager:scheduleIn(0.15, poll)
            return
        end
        self._bg_pid = nil
        self._bg_fd = nil
        local raw = ""
        pcall(function()
            raw = ffiutil.readAllFromFD(parent_read_fd) or ""
        end)
        if not self:alive(gen) then return end
        local ok_json, decoded = pcall(json.decode, raw)
        if not ok_json or type(decoded) ~= "table" then
            decoded = {}
        end
        on_done(decoded.ok == true, decoded.result)
    end
    UIManager:scheduleIn(0.15, poll)
end

function Prefetch:cancel()
    self.gen = self.gen + 1
    self.job = nil
    self._followup = false
    self._cooldown_pending = false
    self._paused = false
    self._turn_token = nil
    self._unknown_chapter_notified = false
    self:_stopBg()
    self:_releaseStandby()
    self:_closeJobDb()
end

function Prefetch:pause()
    self._paused = true
    self:_releaseStandby()
end

function Prefetch:resume()
    self._paused = false
    if self.job then self:_holdStandby() end
end

function Prefetch:alive(gen)
    return self.gen == gen
        and self.plugin._reader_session == (self.session or self.plugin._reader_session)
end

local function notify(self, text, timeout)
    if self.plugin.settings:get("prefetch_notify", false) then
        self.plugin:showTransientInfo(text, timeout or 2)
    end
end

function Prefetch:ensureCatalog(file, binding)
    local chapters = self.plugin.database:listChapters(file)
    if #chapters > 0 then
        return chapters
    end
    if not binding or not self.plugin.api:isOnline() then
        return chapters
    end
    local ok, catalog = pcall(self.plugin.api.chapters, self.plugin.api, binding.book_id)
    if not ok or type(catalog) ~= "table" then
        logger.warn("Prefetch catalog failed:", catalog)
        return chapters
    end
    local filtered = self.plugin.api.filter_chapters_for_underlines(catalog)
    if #filtered == 0 then
        return chapters
    end
    local synckey = tonumber(catalog.synckey) or 0
    self.plugin.database:saveChapters(file, filtered, synckey)
    if self.plugin.toc_map then
        self.plugin.toc_map:clearCache()
    end
    return filtered
end

function Prefetch:planWindow(file, current_uid, opts)
    opts = opts or {}
    local chapters = self.plugin.database:listChapters(file)
    if #chapters == 0 then return nil, "no-catalog" end
    local window_size = tonumber(self.plugin.settings:get("prefetch_underline_window", 5)) or 5
    if window_size < 1 then window_size = 5 end

    if not current_uid then return nil, "unknown-chapter" end
    local idx
    current_uid = tostring(current_uid)
    for i, chapter in ipairs(chapters) do
        if tostring(chapter.chapterUid) == current_uid then
            idx = i
            break
        end
    end
    if not idx then
        if opts.force then idx = 1 else return nil, "unknown-chapter" end
    end

    local window = {}
    if opts.force then
        for i = idx, math.min(idx + window_size - 1, #chapters) do
            window[#window + 1] = chapters[i]
        end
        if #window == 0 then return nil, "empty" end
        return window
    end

    local ready = self.plugin.database:readyChapterSet(file)
    local start = ready[current_uid] and (idx + 1) or idx
    local all_ready = true
    for i = 1, #chapters do
        if not ready[tostring(chapters[i].chapterUid)] then
            all_ready = false
            break
        end
    end
    if all_ready then
        return nil, "already-cached"
    end
    local hole = false
    for i = start, math.min(idx + 3, #chapters) do
        if not ready[tostring(chapters[i].chapterUid)] then
            hole = true
            break
        end
    end
    if not hole then
        return nil, idx >= #chapters and "end-of-book" or "ahead-ok"
    end
    if not ready[current_uid] and idx >= #chapters then
        return nil, "end-of-book"
    end
    if not ready[current_uid] then
        local j = idx + 1
        while j <= #chapters and ready[tostring(chapters[j].chapterUid)] do j = j + 1 end
        local has_ready_ahead = j > idx + 1
        local k = idx - 1
        while k >= 1 and ready[tostring(chapters[k].chapterUid)] do k = k - 1 end
        local has_ready_before = k < idx - 1
        if has_ready_ahead and has_ready_before then
            window[#window + 1] = chapters[idx]
        elseif has_ready_ahead then
            window[#window + 1] = chapters[idx]
            if j <= #chapters then
                window[#window + 1] = chapters[j]
            end
        else
            for i = idx, #chapters do
                local uid = tostring(chapters[i].chapterUid)
                if not ready[uid] then
                    window[#window + 1] = chapters[i]
                    if #window >= window_size then break end
                end
            end
        end
    else
        for i = start, #chapters do
            local uid = tostring(chapters[i].chapterUid)
            if not ready[uid] then
                window[#window + 1] = chapters[i]
                if #window >= window_size then break end
            end
        end
    end
    if #window == 0 then
        return nil, "already-cached"
    end
    return window
end

function Prefetch:persistLocated(file, located)
    if not located or #located == 0 then return end
    self.plugin.database:saveRecords(file, located)
    if self.plugin._local_annotation_overlay then
        self.plugin._local_annotation_overlay:mergeRecords(located)
    end
end

function Prefetch:refreshOverlay()
    if not self.plugin._local_annotation_overlay then return end
    UIManager:setDirty(self.plugin.ui, "partial")
end

function Prefetch:_prepareLocateRows(chapter_uid, rows)
    rows = Locator.sortedRows(rows or {})
    if #rows == 0 then return rows end
    local file = self.plugin.ui and self.plugin.ui.document and self.plugin.ui.document.file
    if not file then return rows end
    local pending = {}
    for _, range in ipairs(self.plugin.database:getUnlocatedRanges(file, chapter_uid) or {}) do
        pending[tostring(range)] = true
    end
    local kept = {}
    for _, row in ipairs(rows) do
        local range = tostring(row.range or "")
        if pending[range] then
            kept[#kept + 1] = row
        end
    end
    return kept
end

function Prefetch:onChapter(chapter_uid)
    self:request({ chapter_uid = chapter_uid })
end

function Prefetch:afterChapterTurn(_chapter_uid)
    self:ensureAhead()
end

-- Debounced chapter-boundary check: fetch a 5-chapter batch when any of
-- the next 1–3 chapters is not locate-ready (and request() is not in cooldown).
function Prefetch:ensureAhead()
    local plugin = self.plugin
    local token = {}
    self._turn_token = token
    UIManager:scheduleIn(0.4, function()
        if self._turn_token ~= token then return end
        if plugin._thought_open then
            self._followup = true
            return
        end
        if self.job then
            self._followup = true
            return
        end
        local uid = plugin.toc_map and plugin.toc_map:currentWereadChapterUid()
        if not uid then
            logger.debug("prefetch ensureAhead skip: unknown-chapter")
            local file = plugin.ui.document and plugin.ui.document.file
            if file and plugin.database:getBinding(file) and not self._unknown_chapter_notified then
                self._unknown_chapter_notified = true
                notify(self, _("Could not detect the current chapter."))
            end
            return
        end
        self:request({ chapter_uid = uid })
    end)
end

function Prefetch:request(opts)
    opts = opts or {}
    local plugin = self.plugin
    if not plugin.settings:get("show_annotations", true) then return end
    if not opts.force and not plugin.settings:get("prefetch_thoughts", true) then
        return
    end
    local file = plugin.ui and plugin.ui.document and plugin.ui.document.file
    local binding = file and plugin.database:getBinding(file)
    if not file or not binding then
        if opts.notify then
            plugin:showInfo(_("Match this local book first."))
        end
        return
    end
    if not plugin.api:isOnline() then
        if opts.notify and plugin:whenOnline(function() self:request(opts) end) then
            return
        end
        if opts.notify then
            plugin:showOffline(_("Sync"))
        end
        return
    end

    if self.job then
        if opts.force then
            self:cancel()
        else
            self._followup = true
            return
        end
    end

    self.session = plugin._reader_session
    local gen = self.gen
    local function later(delay, fn)
        UIManager:scheduleIn(math.max(0.1, delay), function()
            if not self:alive(gen) then return end
            fn()
        end)
    end

    local chapters = self:ensureCatalog(file, binding)
    if #chapters == 0 then
        if opts.notify then
            plugin:showInfo(_("Could not load the Weread chapter list.") .. "\n" .. _("Please log in first."))
        end
        return
    end

    local chapter_uid = opts.chapter_uid or (plugin.toc_map and plugin.toc_map:currentWereadChapterUid())
    if not chapter_uid and not opts.force then return end

    local window, reason = self:planWindow(file, chapter_uid, {
        force = opts.force,
    })
    if not window then
        logger.debug("prefetch plan skip:", reason, "uid=", chapter_uid)
        if opts.notify and reason == "no-catalog" then
            plugin:showInfo(_("Could not load the Weread chapter list."))
        end
        return
    end

    local respect_cooldown = opts.respect_cooldown
    if respect_cooldown == nil then respect_cooldown = not opts.force or opts.from_current end
    local cooldown = tonumber(plugin.settings:get("prefetch_underline_cooldown", 30)) or 30
    if cooldown < 0 then cooldown = 0 end
    local elapsed = os.time() - (self.last_underline_at or 0)
    if respect_cooldown and self.last_underline_at > 0 and elapsed < cooldown then
        if not self._cooldown_pending then
            self._cooldown_pending = true
            later(cooldown - elapsed, function()
                self._cooldown_pending = false
                local next_opts = opts.force and opts or {
                    chapter_uid = plugin.toc_map and plugin.toc_map:currentWereadChapterUid(),
                }
                self:request(next_opts)
            end)
        end
        return
    end

    if opts.notify or (not opts.force and not opts.skip_fetch_toast) then
        notify(self, _("Fetching underlines…"), 2)
    end
    if chapter_uid then
        self._unknown_chapter_notified = false
    end
    self:_holdStandby()
    self:startUnderlines(file, binding, window, gen, opts.force)
end

local function item_ranges(items)
    local ranges = {}
    for _, item in ipairs(items or {}) do
        if item.range then
            ranges[#ranges + 1] = tostring(item.range)
        end
    end
    return ranges
end

function Prefetch:startUnderlines(file, binding, window, gen, force)
    self:_openJobDb(file)
    local job = {
        file = file,
        binding = binding,
        window = window,
        index = 1,
        located = {},
        fetched_uids = {},
        prune = {},
    }
    self.job = job

    local function finish_underlines(start_thoughts)
        for uid, ranges in pairs(job.prune) do
            self.plugin.database:pruneChapterRanges(file, uid, ranges)
            if self.plugin._local_annotation_overlay then
                self.plugin._local_annotation_overlay:retainChapterRanges(uid, ranges)
            end
        end
        self:persistLocated(file, job.located)
        self.job = nil
        self:refreshOverlay()
        if start_thoughts then
            self:startThoughts(file, binding, job.fetched_uids, gen)
        else
            self:finish(gen)
        end
    end

    local function fail_underlines(result)
        logger.err("Underline prefetch failed:", result)
        local expired = self.plugin.api.is_login_expired(result)
        local upgrade = self.plugin.api.is_skill_upgrade_required(result)
        finish_underlines(not expired and not upgrade)
        if expired then
            notify(self, _("Weread login has expired."), 3)
            return
        end
        if upgrade then
            local message = tostring(result or ""):gsub("^upgrade_required%s+", "")
            notify(self, message, 4)
            return
        end
        notify(self,
            _("Underline prefetch failed: ") .. tostring(result or "unknown error"),
            3
        )
    end

    local begin_chapter
    local locate_one

    local function chapter_done()
        job.fetched_uids[#job.fetched_uids + 1] = job.window[job.index]
        job.index = job.index + 1
        job.rows = nil
        job.row_i = nil
        job.cache = nil
        UIManager:scheduleIn(0.05, begin_chapter)
    end

    locate_one = function()
        if not self:alive(gen) or self.job ~= job then return end
        if self._paused then
            UIManager:scheduleIn(0.4, locate_one)
            return
        end
        local row = job.rows and job.rows[job.row_i]
        if not row then
            chapter_done()
            return
        end
        local document = self.plugin.ui and self.plugin.ui.document
        if document and job.bounds then
            local ok, rec, cursor, from_xp = pcall(Locator.locateOne, document,
                job.uid, row, job.cursor, job.bounds, job.from_xp)
            if ok then
                if rec then
                    self.plugin.database:markLocateAttempted(job.file, job.uid, row.range)
                    job.located[#job.located + 1] = rec
                    job.cursor = cursor
                    job.from_xp = from_xp
                end
            else
                logger.err("Prefetch locate failed:", rec)
            end
        end
        job.row_i = job.row_i + 1
        UIManager:scheduleIn(0, locate_one)
    end

    local function start_locate(cache)
        local items = cache and cache.items or {}
        self.plugin.database:ensureUnderlineRows(file, job.uid, items)
        if force then
            job.rows = Locator.sortedRows(items)
        else
            job.rows = self:_prepareLocateRows(job.uid, items)
        end
        if #job.rows == 0 then
            chapter_done()
            return
        end
        job.row_i = 1
        job.cursor = -math.huge
        job.from_xp = nil
        job.bounds = self.plugin.toc_map and self.plugin.toc_map:getChapterBounds(job.uid)
        locate_one()
    end

    begin_chapter = function()
        if not self:alive(gen) or self.job ~= job then return end
        if self._paused then
            UIManager:scheduleIn(0.4, begin_chapter)
            return
        end
        local chapter = job.window[job.index]
        if not chapter then
            finish_underlines(true)
            notify(self, string.format(
                _("Underline prefetch finished (%d matched)."),
                #job.located
            ), 2)
            return
        end
        local uid = tostring(chapter.chapterUid)
        job.uid = uid
        local cache = self.plugin.database:getUnderlineCache(file, uid)
        local need_fetch = force or not cache
        if need_fetch and not self.plugin.api:isOnline() then
            if cache then
                need_fetch = false
            else
                finish_underlines(false)
                notify(self, _("Underline prefetch failed: offline."), 3)
                return
            end
        end
        if need_fetch then
            local synckey = cache and tonumber(cache.synckey) or 0
            local api = self.plugin.api
            local book_id = binding.book_id
            self:_bg(function()
                return api.popular_underlines_sync(api, book_id, uid, synckey)
            end, function(ok, result)
                if not self:alive(gen) or self.job ~= job then return end
                self.last_underline_at = os.time()
                if not ok or not result then
                    fail_underlines(result)
                    return
                end
                if not (result.unchanged and cache) then
                    cache = {
                        synckey = result.synckey,
                        items = result.items or {},
                    }
                    self.plugin.database:saveUnderlineCache(file, uid, cache.synckey, cache.items)
                    job.prune[uid] = item_ranges(cache.items)
                end
                start_locate(cache)
            end)
            return
        end
        start_locate(cache)
    end

    UIManager:scheduleIn(0.1, begin_chapter)
end

function Prefetch:startThoughts(file, binding, chapters, gen)
    chapters = chapters or {}
    if #chapters == 0 or not self.plugin.settings:get("prefetch_thoughts", true) then
        self:_releaseStandby()
        self:finish(gen)
        return
    end
    self:_holdStandby()
    local job = {
        file = file,
        binding = binding,
        chapters = chapters,
        chapter_index = 1,
        batches = {},
        index = 1,
        retry = 0,
        chapter_uid = nil,
    }
    self.job = job

    local function load_chapter()
        while job.chapter_index <= #job.chapters do
            local chapter = job.chapters[job.chapter_index]
            local uid = tostring(chapter.chapterUid or chapter)
            job.chapter_uid = uid
            local ranges = self.plugin.database:getRanges(file, uid)
            job.chapter_index = job.chapter_index + 1
            if #ranges > 0 then
                local batches = {}
                local size = tonumber(self.plugin.settings:get("prefetch_batch_size", 5)) or 5
                for i = 1, #ranges, size do
                    local batch = {}
                    for j = i, math.min(i + size - 1, #ranges) do
                        batch[#batch + 1] = ranges[j]
                    end
                    batches[#batches + 1] = batch
                end
                job.batches = batches
                job.index = 1
                job.retry = 0
                return true
            end
        end
        return false
    end

    local function step()
        if not self:alive(gen) or self.job ~= job then return end
        if self._paused then
            UIManager:scheduleIn(0.4, step)
            return
        end
        if job.waiting then return end
        if not job.batches[job.index] then
            if load_chapter() then
                UIManager:scheduleIn(0.1, step)
                return
            end
            self.job = nil
            self:finish(gen)
            return
        end
        local batch = job.batches[job.index]
        job.waiting = true
        local api = self.plugin.api
        local book_id = binding.book_id
        local chapter_uid = job.chapter_uid
        self:_bg(function()
            return api.reviews(api, book_id, chapter_uid, batch)
        end, function(ok, result)
            if not self:alive(gen) or self.job ~= job then return end
            job.waiting = false
            if ok and type(result) == "table" and type(result.reviews) == "table" then
                local found_ranges = {}
                for _, review in ipairs(result.reviews) do
                    local range = review.range
                    if range then
                        local parsed = self.plugin.api:parseReviewItems(review)
                        if self.plugin.api.hasThoughtContent(parsed) then
                            found_ranges[range] = true
                            local encoded = self.plugin.api:json_encode(parsed)
                            self.plugin.database:saveThoughts(file, job.chapter_uid, range, encoded, true)
                            if self.plugin._local_annotation_overlay then
                                self.plugin._local_annotation_overlay:updateThought(
                                    job.chapter_uid, range, parsed)
                            end
                        end
                    end
                end
                for _, range in ipairs(batch) do
                    if not found_ranges[range] then
                        self.plugin.database:saveThoughts(file, job.chapter_uid, range, "[]", true)
                        if self.plugin._local_annotation_overlay then
                            self.plugin._local_annotation_overlay:updateThought(
                                job.chapter_uid, range, {})
                        end
                    end
                end
                job.retry = 0
                job.index = job.index + 1
                local delay = tonumber(self.plugin.settings:get("prefetch_batch_delay", 0.3)) or 0.3
                UIManager:scheduleIn(delay, step)
            elseif self.plugin.api.is_login_expired(result)
                or self.plugin.api.is_skill_upgrade_required(result) then
                self.job = nil
                if self.plugin.api.is_login_expired(result) then
                    notify(self, _("Weread login has expired."), 3)
                else
                    notify(self, tostring(result or ""):gsub("^upgrade_required%s+", ""), 4)
                end
                self:finish(gen)
            elseif job.retry < 3 then
                job.retry = job.retry + 1
                UIManager:scheduleIn(0.8 * (2 ^ (job.retry - 1)), step)
            else
                logger.err("Thought prefetch failed after retries")
                notify(self, _("Thought prefetch failed."), 3)
                job.index = job.index + 1
                job.retry = 0
                UIManager:scheduleIn(0.5, step)
            end
        end)
    end

    if not load_chapter() then
        self.job = nil
        self:finish(gen)
        return
    end
    UIManager:scheduleIn(0.1, step)
end

function Prefetch:finish(gen)
    self:_releaseStandby()
    self:_closeJobDb()
    local followup = self._followup
    self._followup = false
    if not self:alive(gen) then return end
    if followup then
        self:ensureAhead()
    end
end

return Prefetch
