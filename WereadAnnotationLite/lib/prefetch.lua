local UIManager = require("ui/uimanager")

local Prefetch = {}
Prefetch.__index = Prefetch

local function review_items(review)
    local items = {}
    local pages = review.pageReviews
    if type(pages) ~= "table" or next(pages) == nil then
        pages = review.review and { review } or {}
    end
    local page_index = 0
    for _, page in ipairs(pages) do
        page_index = page_index + 1
        local item = page.review or {}
        local author = item.author or {}
        local abstract
        if page_index == 1 then
            abstract = item.abstract or item.contextAbstract
            if type(abstract) ~= "string" or abstract == "" then abstract = nil end
        end
        items[#items + 1] = {
            abstract = abstract,
            author = tostring(author.nick or author.name or "匿名"),
            content = tostring(item.content or ""),
            likes_count = tonumber(page.likesCount) or 0,
        }
    end
    return items
end

function Prefetch:new(plugin)
    return setmetatable({ plugin = plugin }, self)
end

function Prefetch:cancel()
    if self.job then self.job.cancelled = true end
    self.job = nil
end

function Prefetch:start(file, binding, chapter_uid, immediate)
    self:cancel()
    local job = { cancelled = false, file = file, binding = binding,
        session = self.plugin._reader_session,
        chapter_uid = chapter_uid, index = 1, retry = 0 }
    self.job = job
    if not self.plugin.api:isOnline() then
        self.job = nil
        return false
    end
    local ranges = self.plugin.database:getRanges(file, chapter_uid)
    local batches = {}
    local size = tonumber(self.plugin.settings:get("prefetch_batch_size", 5)) or 5
    for i = 1, #ranges, size do
        local batch = {}
        for j = i, math.min(i + size - 1, #ranges) do batch[#batch + 1] = ranges[j] end
        batches[#batches + 1] = batch
    end
    job.batches = batches
    local function step()
        if job.cancelled or self.job ~= job
            or job.session ~= self.plugin._reader_session then
            return
        end
        local batch = job.batches[job.index]
        if not batch then
            local next_uid = self.plugin.database:nextChapter(file, chapter_uid)
            self.job = nil
            if next_uid then
                UIManager:scheduleIn(0.5, function()
                    self:start(file, binding, next_uid, true)
                end)
            end
            return
        end
            local ok, result = pcall(self.plugin.api.reviews, self.plugin.api,
            binding.book_id, chapter_uid, batch)
        if ok and type(result) == "table" and type(result.reviews) == "table" then
            local found_ranges = {}
            for _, review in ipairs(result.reviews) do
                local range = review.range
                if range then
                    found_ranges[range] = true
                    local encoded = self.plugin.json_encode(review_items(review))
                    self.plugin.database:saveThoughts(file, chapter_uid, range, encoded, true)
                end
            end

            local requested_ranges = job.batches[job.index] or {}
            for _, range in ipairs(requested_ranges) do
                if not found_ranges[range] then
                    self.plugin.database:deleteUnderline(file, chapter_uid, range)
                end
            end
            
            job.retry = 0; job.index = job.index + 1
            UIManager:scheduleIn(0.3, step)
        elseif job.retry < 3 then
            job.retry = job.retry + 1
            UIManager:scheduleIn(0.8 * (2 ^ (job.retry - 1)), step)
        else
            self.job = nil
        end
    end
    UIManager:scheduleIn(immediate and 0.1 or 1.0, step)
end

return Prefetch
