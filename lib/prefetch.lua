local UIManager = require("ui/uimanager")
local logger = require("lib.logger")
local Locator = require("lib.locator")
local _ = require("gettext")

local Prefetch = {}
Prefetch.__index = Prefetch

function Prefetch:new(plugin)
    return setmetatable({
        plugin = plugin,
        gen = 0,
        last_underline_at = 0,
    }, self)
end

function Prefetch:cancel()
    self.gen = self.gen + 1
    self.job = nil
    self._followup = false
    self._cooldown_pending = false
    self._paused = false
    self._turn_token = nil
end

function Prefetch:pause()
    self._paused = true
end

function Prefetch:resume()
    self._paused = false
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
    if #chapters > 0 then return chapters end
    if not binding or not self.plugin.api:isOnline() then return {} end
    local ok, catalog = pcall(self.plugin.api.chapters, self.plugin.api, binding.book_id)
    if not ok or type(catalog) ~= "table" or #catalog == 0 then
        logger.warn("Prefetch catalog failed:", catalog)
        return {}
    end
    chapters = self.plugin.api.filter_chapters_for_underlines(catalog)
    self.plugin.database:saveChapters(file, chapters)
    self.plugin._chapter_list = chapters
    return chapters
end

function Prefetch:planWindow(file, current_uid, opts)
    opts = opts or {}
    local chapters = self.plugin.database:listChapters(file)
    if #chapters == 0 then return nil, "no-catalog" end
    local window_size = tonumber(self.plugin.settings:get("prefetch_underline_window", 5)) or 5
    if window_size < 1 then window_size = 5 end

    if opts.from_start then
        local window = {}
        for i = 1, math.min(window_size, #chapters) do
            window[#window + 1] = chapters[i]
        end
        if #window == 0 then return nil, "empty" end
        return window
    end

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

    if not opts.force then
        local cached = self.plugin.database:cachedChapterSet(file)
        local current_cached = cached[current_uid] == true
        if current_cached then
            local next_ch = chapters[idx + 1]
            if next_ch and cached[tostring(next_ch.chapterUid)] then
                return nil, "not-edge"
            end
            if not next_ch then
                return nil, "end-of-book"
            end
        end
        local start = current_cached and (idx + 1) or idx
        local window = {}
        for i = start, math.min(start + window_size - 1, #chapters) do
            window[#window + 1] = chapters[i]
        end
        if #window == 0 then return nil, "empty" end
        local needs_network = false
        for _, chapter in ipairs(window) do
            if not cached[tostring(chapter.chapterUid)] then
                needs_network = true
                break
            end
        end
        if not needs_network then return nil, "already-cached" end
        return window
    end

    local window = {}
    for i = idx, math.min(idx + window_size - 1, #chapters) do
        window[#window + 1] = chapters[i]
    end
    if #window == 0 then return nil, "empty" end
    return window
end

function Prefetch:persistLocated(file, located)
    if not located or #located == 0 then return end
    self.plugin.database:saveRecords(file, located)
    if self.plugin._local_annotation_overlay then
        self.plugin._local_annotation_overlay:mergeRecords(located)
        self.plugin._chapter_starts = nil
    end
end

function Prefetch:refreshOverlay()
    if not self.plugin._local_annotation_overlay then return end
    UIManager:setDirty(self.plugin.ui, "partial")
end

function Prefetch:locateChapter(chapter_uid, rows)
    rows = rows or {}
    if #rows == 0 then return {} end
    local document = self.plugin.ui and self.plugin.ui.document
    if not document then return {} end
    local ok, located = pcall(Locator.locate, document, chapter_uid, rows)
    if not ok then
        logger.err("Prefetch locate failed:", located)
        return {}
    end
    return located or {}
end

function Prefetch:reloadOverlay(file)
    self.plugin._chapter_starts = nil
end

function Prefetch:onChapter(chapter_uid)
    self:request({ chapter_uid = chapter_uid })
end

function Prefetch:remainingCooldown()
    local cooldown = tonumber(self.plugin.settings:get("prefetch_underline_cooldown", 30)) or 30
    if cooldown < 0 then cooldown = 0 end
    local last = self.last_underline_at or 0
    if last <= 0 then return 0 end
    local left = cooldown - (os.time() - last)
    if left < 0 then return 0 end
    return left
end

function Prefetch:afterChapterTurn(chapter_uid)
    local plugin = self.plugin
    local session = plugin._reader_session
    local token = {}
    self._turn_token = token
    UIManager:scheduleIn(0.45, function()
        if self._turn_token ~= token then return end
        if plugin._reader_session ~= session then return end
        if plugin._thought_open then return end
        if self.job then return end
        local file = plugin.ui and plugin.ui.document and plugin.ui.document.file
        if not file then return end
        local still = plugin:currentWereadChapterUid()
        if still and tostring(still) ~= tostring(chapter_uid) then return end
        local window = self:planWindow(file, chapter_uid)
        if not window then return end
        if self:remainingCooldown() > 0 then
            self:onChapter(chapter_uid)
            return
        end
        notify(self, _("Fetching underlines…"), 2)
        UIManager:scheduleIn(0.25, function()
            if self._turn_token ~= token then return end
            if plugin._reader_session ~= session then return end
            if plugin._thought_open then return end
            self:request({ chapter_uid = chapter_uid, skip_fetch_toast = true })
        end)
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

    local chapter_uid = opts.chapter_uid
    if not opts.from_start then
        chapter_uid = chapter_uid or plugin:currentWereadChapterUid({ allow_toc = opts.force or false })
        if opts.force and not chapter_uid then
            chapter_uid = plugin:currentWereadChapterUid({ allow_toc = true })
        end
        if not chapter_uid and not opts.force then return end
    end

    local window, reason = self:planWindow(file, chapter_uid, {
        force = opts.force,
        from_start = opts.from_start,
    })
    if not window then
        if opts.notify and reason == "no-catalog" then
            plugin:showInfo(_("Could not load the Weread chapter list."))
        end
        return
    end

    local respect_cooldown = opts.respect_cooldown
    if respect_cooldown == nil then respect_cooldown = not opts.force or opts.from_current end
    if opts.from_start then respect_cooldown = false end
    local cooldown = tonumber(plugin.settings:get("prefetch_underline_cooldown", 30)) or 30
    if cooldown < 0 then cooldown = 0 end
    local elapsed = os.time() - (self.last_underline_at or 0)
    if respect_cooldown and self.last_underline_at > 0 and elapsed < cooldown then
        notify(
            self,
            _("Cooling down. Underlines will update shortly."),
            3
        )
        if not self._cooldown_pending then
            self._cooldown_pending = true
            later(cooldown - elapsed, function()
                self._cooldown_pending = false
                local next_opts = opts.force and opts or { chapter_uid = plugin:currentWereadChapterUid() }
                notify(self, _("Fetching underlines…"), 2)
                UIManager:scheduleIn(0.25, function()
                    next_opts.skip_fetch_toast = true
                    self:request(next_opts)
                end)
            end)
        end
        return
    end

    if not opts.skip_fetch_toast then
        if opts.notify or not opts.force then
            if opts.from_start then
                notify(self, _("Fetching the first 5 chapters…"), 2)
            else
                notify(self, _("Fetching underlines…"), 2)
            end
        end
    end
    if chapter_uid then
        plugin._seen_chapter_uid = tostring(chapter_uid)
    end
    self:startUnderlines(file, binding, window, gen)
end

function Prefetch:startUnderlines(file, binding, window, gen)
    local job = {
        file = file,
        binding = binding,
        window = window,
        index = 1,
        located = {},
        fetched_uids = {},
    }
    self.job = job

    local function step()
        if not self:alive(gen) or self.job ~= job then return end
        if self._paused then
            UIManager:scheduleIn(0.4, step)
            return
        end
        local chapter = job.window[job.index]
        if not chapter then
            self:persistLocated(file, job.located)
            self.job = nil
            self:refreshOverlay()
            notify(self, string.format(
                _("Underline prefetch finished (%d matched)."),
                #job.located
            ), 2)
            self:startThoughts(file, binding, job.window, gen)
            return
        end
        local uid = tostring(chapter.chapterUid)
        local cache = self.plugin.database:getUnderlineCache(file, uid)
        if not cache then
            if not self.plugin.api:isOnline() then
                self:persistLocated(file, job.located)
                self.job = nil
                self:refreshOverlay()
                notify(self, _("Underline prefetch failed: offline."), 3)
                return
            end
            local ok, result = pcall(self.plugin.api.popular_underlines_sync, self.plugin.api,
                binding.book_id, uid, 0)
            self.last_underline_at = os.time()
            if not ok or not result then
                logger.err("Underline prefetch failed:", result)
                self:persistLocated(file, job.located)
                self.job = nil
                self:refreshOverlay()
                if self.plugin.api.is_login_expired(result) then
                    notify(self, _("Weread login has expired."), 3)
                    return
                end
                notify(self,
                    _("Underline prefetch failed: ") .. tostring(result or "unknown error"),
                    3
                )
                self:startThoughts(file, binding, job.fetched_uids, gen)
                return
            end
            cache = {
                synckey = result.synckey,
                items = result.items or {},
            }
            self.plugin.database:saveUnderlineCache(file, uid, cache.synckey, cache.items)
        end
        local located = self:locateChapter(uid, cache.items or {})
        for _, record in ipairs(located) do
            job.located[#job.located + 1] = record
        end
        job.fetched_uids[#job.fetched_uids + 1] = chapter
        job.index = job.index + 1
        UIManager:scheduleIn(0.1, step)
    end
    UIManager:scheduleIn(0.1, step)
end

function Prefetch:startThoughts(file, binding, chapters, gen)
    chapters = chapters or {}
    if #chapters == 0 or not self.plugin.settings:get("prefetch_thoughts", true) then
        self:finish(gen)
        return
    end
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
        if not job.batches[job.index] then
            if load_chapter() then
                UIManager:scheduleIn(0.1, step)
                return
            end
            self:reloadOverlay(file)
            self.job = nil
            self:finish(gen)
            return
        end
        local batch = job.batches[job.index]
        local ok, result = pcall(self.plugin.api.reviews, self.plugin.api,
            binding.book_id, job.chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            local found_ranges = {}
            for _, review in ipairs(result.reviews) do
                local range = review.range
                if range then
                    found_ranges[range] = true
                    local parsed = self.plugin.api:parseReviewItems(review)
                    local encoded = self.plugin.json_encode(parsed)
                    self.plugin.database:saveThoughts(file, job.chapter_uid, range, encoded, true)
                    if self.plugin._local_annotation_overlay then
                        self.plugin._local_annotation_overlay:updateThought(
                            job.chapter_uid, range, parsed)
                    end
                end
            end
            for _, range in ipairs(batch) do
                if not found_ranges[range] then
                    self.plugin.database:deleteUnderline(file, job.chapter_uid, range)
                    if self.plugin._local_annotation_overlay then
                        self.plugin._local_annotation_overlay:removeRecord(
                            job.chapter_uid, range)
                    end
                end
            end
            job.retry = 0
            job.index = job.index + 1
            local delay = tonumber(self.plugin.settings:get("prefetch_batch_delay", 0.3)) or 0.3
            UIManager:scheduleIn(delay, step)
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
    end

    if not load_chapter() then
        self.job = nil
        self:finish(gen)
        return
    end
    UIManager:scheduleIn(0.1, step)
end

function Prefetch:finish(gen)
    if not self:alive(gen) then return end
    local followup = false
    -- captured on a previous onChapter while busy
    if self._followup then
        followup = true
        self._followup = false
    end
    if followup then
        UIManager:scheduleIn(0.3, function()
            if not self:alive(gen) then return end
            self:onChapter(self.plugin:currentWereadChapterUid())
        end)
    end
end

return Prefetch
