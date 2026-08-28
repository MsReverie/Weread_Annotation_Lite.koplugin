local Overlay = {}
Overlay.__index = Overlay

local function inside(rect, pos, padding)
    if not rect or not pos then return false end
    padding = padding or 0
    return pos.x >= rect.x - padding and pos.x <= rect.x + rect.w + padding
        and pos.y >= rect.y - padding and pos.y <= rect.y + rect.h + padding
end

function Overlay:new(opts)
    opts = opts or {}
    return setmetatable({
        records = opts.records or {}, enabled = opts.enabled ~= false,
        cache = {}, visible = {}, generation = 1,
        hit_padding = tonumber(opts.hit_padding) or 3,
    }, self)
end

function Overlay:setRecords(records)
    self.records = type(records) == "table" and records or {}
    self:invalidate()
end

function Overlay:mergeRecords(records)
    self.records = self.records or {}
    local index = {}
    for i, rec in ipairs(self.records) do
        index[tostring(rec.chapter_uid) .. "\0" .. tostring(rec.range)] = i
    end
    for _, rec in ipairs(records or {}) do
        local key = tostring(rec.chapter_uid) .. "\0" .. tostring(rec.range)
        local at = index[key]
        if at then
            local old = self.records[at]
            if (not rec.items or #rec.items == 0) and old.items then
                rec.items = old.items
                rec.fetched = old.fetched
            end
            self.records[at] = rec
        else
            self.records[#self.records + 1] = rec
            index[key] = #self.records
        end
    end
    self:invalidate()
end

function Overlay:updateThought(chapter_uid, range, items)
    for _, rec in ipairs(self.records or {}) do
        if tostring(rec.chapter_uid) == tostring(chapter_uid)
            and tostring(rec.range) == tostring(range) then
            rec.items = items or {}
            rec.fetched = 1
            return
        end
    end
end

function Overlay:dropFetchedEmpty(has_thoughts)
    local records = self.records or {}
    local changed = false
    for i = #records, 1, -1 do
        local rec = records[i]
        if tonumber(rec.fetched) == 1 and not has_thoughts(rec.items) then
            table.remove(records, i)
            changed = true
        end
    end
    if changed then self:invalidate() end
end

function Overlay:removeRecord(chapter_uid, range)
    local records = self.records or {}
    for i = #records, 1, -1 do
        local rec = records[i]
        if tostring(rec.chapter_uid) == tostring(chapter_uid)
            and tostring(rec.range) == tostring(range) then
            table.remove(records, i)
            self:invalidate()
            return
        end
    end
end

function Overlay:retainChapterRanges(chapter_uid, keep_ranges)
    local keep = {}
    for _, range in ipairs(keep_ranges or {}) do
        keep[tostring(range)] = true
    end
    local records = self.records or {}
    local changed = false
    chapter_uid = tostring(chapter_uid)
    for i = #records, 1, -1 do
        local rec = records[i]
        if tostring(rec.chapter_uid) == chapter_uid
            and not keep[tostring(rec.range)] then
            table.remove(records, i)
            changed = true
        end
    end
    if changed then self:invalidate() end
end

function Overlay:setEnabled(enabled)
    self.enabled = enabled ~= false
    self.visible = {}
end

function Overlay:invalidate()
    self.generation = self.generation + 1
    self.cache = {}
    self._cache_key = nil
    self.visible = {}
    self._sorted = false
    for _, rec in ipairs(self.records or {}) do
        rec._start_pos = nil
        rec._end_pos = nil
    end
end

-- ReaderView:resetLayout() calls this on every view module after a layout pass.
function Overlay:resetLayout()
    self:invalidate()
end

local function draw_boxes(overlay, bb, x, y, boxes)
    overlay.visible = {}
    for _, entry in ipairs(boxes) do
        overlay.visible[#overlay.visible + 1] = entry
        overlay.view:drawHighlightRect(bb, x, y, entry.rect, "underscore", nil, false)
    end
end

function Overlay:_refreshPositions(document)
    local records = self.records or {}
    local need_sort = not self._sorted
    for _, record in ipairs(records) do
        if record.pos0 then
            if record._start_pos == nil then
                record._start_pos = tonumber((document:getPosFromXPointer(record.pos0))) or math.huge
                need_sort = true
            end
            if record._end_pos == nil and record.pos1 then
                record._end_pos = tonumber((document:getPosFromXPointer(record.pos1))) or record._start_pos
            end
        elseif record._start_pos == nil then
            record._start_pos = math.huge
            need_sort = true
        end
    end
    if need_sort then
        table.sort(records, function(a, b)
            return (a._start_pos or math.huge) < (b._start_pos or math.huge)
        end)
        self._sorted = true
    end
end

function Overlay:_computeVisible()
    local document = self.ui and self.ui.document
    local view = self.view
    if not document or not view or self.ui.paging then return {} end
    local top = tonumber((document:getCurrentPos())) or 0
    local height = self.ui.dimen and tonumber(self.ui.dimen.h) or 0
    local pages = tonumber((document:getVisiblePageCount())) or 1
    local bottom = top + height * math.max(1, pages)
    self:_refreshPositions(document)
    local visible = {}
    for _, record in ipairs(self.records) do
        if record.pos0 and record.pos1 then
            local start_pos = record._start_pos
            local end_pos = record._end_pos
            if start_pos and start_pos > bottom then
                break
            end
            if start_pos and end_pos and start_pos <= bottom and end_pos >= top then
                local boxes = document:getScreenBoxesFromPositions(record.pos0, record.pos1, true)
                if type(boxes) == "table" then
                    for _, rect in ipairs(boxes) do
                        if type(rect) == "table" and tonumber(rect.h) ~= 0 then
                            visible[#visible + 1] = { rect = rect, record = record }
                        end
                    end
                end
            end
        end
    end
    return visible
end

function Overlay:paintTo(bb, x, y)
    if not self.enabled or #self.records == 0 then
        self.visible = {}
        return
    end
    local document = self.ui and self.ui.document
    if not document then return end
    local page = document:getCurrentPage() or 0
    local view_mode = self.view and self.view.view_mode
    local cache_key
    if view_mode == "page" then
        cache_key = tostring(self.generation) .. ":p:" .. tostring(page)
    else
        local top = tonumber(document:getCurrentPos()) or 0
        local height = self.ui.dimen and tonumber(self.ui.dimen.h) or 0
        local pages = tonumber(document:getVisiblePageCount()) or 1
        local bottom = top + height * math.max(1, pages)
        cache_key = tostring(self.generation) .. ":s:" .. tostring(top) .. ":" .. tostring(bottom)
    end
    local cached = self._cache_key == cache_key and self.cache[cache_key] or nil
    local boxes
    if cached then
        boxes = cached
    else
        boxes = self:_computeVisible()
        self._cache_key = cache_key
        self.cache = { [cache_key] = boxes }
    end
    draw_boxes(self, bb, x, y, boxes)
end

function Overlay:hitTest(pos)
    for index = #self.visible, 1, -1 do
        local entry = self.visible[index]
        if inside(entry.rect, pos, self.hit_padding) then return entry.record end
    end
end

return Overlay
