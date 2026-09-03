--[[--
TOC ↔ WeRead chapter matching with per-document caching.

Pure functions are exported at module level for tests. TocMap.newInstance
owns the per-document cache so invalidation is atomic.

@module lib.toc_map
--]]

local TocMap = {}
local Matcher = require("lib.toc_matcher")

function TocMap.normalize(text)
    text = tostring(text or "")
    text = text:gsub("%s+", "")
    -- Lua 5.1 [] classes are bytes. Strip ASCII punctuation that way, but
    -- UTF-8 marks as whole characters so 一 is never eaten by 0x80.
    text = text:gsub("[%.%(%)%[%]]", "")
    for _, mark in ipairs({ "　", "《", "》", "【", "】" }) do
        text = text:gsub(mark, "")
    end
    return text
end

function TocMap.match(weread_chapters, toc_items)
    local map = Matcher.match(weread_chapters, toc_items)
    return map
end

function TocMap.bounds(weread_chapters, toc_items, matched)
    local out = {}
    matched = matched or TocMap.match(weread_chapters, toc_items)
    for i, chapter in ipairs(weread_chapters or {}) do
        local uid = tostring(chapter.chapterUid or "")
        local toc_idx = matched[uid]
        if uid ~= "" and toc_idx and toc_items[toc_idx] then
            local start_pos = tonumber(toc_items[toc_idx].pos) or 0
            local end_pos = math.huge
            for j = i + 1, #weread_chapters do
                local next_idx = matched[tostring(weread_chapters[j].chapterUid)]
                if next_idx and toc_items[next_idx] then
                    end_pos = tonumber(toc_items[next_idx].pos) or math.huge
                    break
                end
            end
            out[uid] = {
                start_pos = start_pos,
                end_pos = end_pos,
                start_xp = toc_items[toc_idx].xpointer,
            }
        end
    end
    return out
end

function TocMap.uidAtPos(bounds, pos)
    pos = tonumber(pos) or 0
    local best_uid, best_start = nil, -math.huge
    for uid, span in pairs(bounds or {}) do
        local start_pos = tonumber(span.start_pos) or 0
        local end_pos = tonumber(span.end_pos) or math.huge
        if pos >= start_pos and pos < end_pos and start_pos >= best_start then
            best_start = start_pos
            best_uid = uid
        end
    end
    return best_uid
end

-- Same rule as ReaderToc:getTocIndexByPage(pageno).
function TocMap.indexAtPage(toc_items, pageno)
    pageno = tonumber(pageno)
    if not pageno then return nil end
    local prev = 0
    for i, item in ipairs(toc_items or {}) do
        local page = tonumber(item.page) or 0
        if page == pageno then
            return i
        end
        if page > pageno then
            break
        end
        prev = i
    end
    return prev > 0 and prev or nil
end

function TocMap.uidAtTocIndex(matched, toc_idx)
    toc_idx = tonumber(toc_idx)
    if not toc_idx then return nil end
    local best_uid, best = nil, -math.huge
    for uid, idx in pairs(matched or {}) do
        idx = tonumber(idx)
        if idx and idx <= toc_idx and idx >= best then
            best = idx
            best_uid = uid
        end
    end
    return best_uid
end

-- CreDocument:compareXPointers(xp1, xp2): 1 if xp2 after xp1, 0 same, -1 before.
function TocMap.uidAtXPointer(weread_chapters, matched, toc_items, document, xp)
    if not xp or not document or not document.compareXPointers then
        return nil
    end
    local best_uid, best_idx = nil, -math.huge
    for _, chapter in ipairs(weread_chapters or {}) do
        local uid = tostring(chapter.chapterUid or "")
        local toc_idx = matched and matched[uid]
        local item = toc_idx and toc_items and toc_items[toc_idx]
        if uid ~= "" and item and item.xpointer then
            local cmp = document:compareXPointers(item.xpointer, xp)
            if cmp ~= nil and cmp >= 0 and toc_idx >= best_idx then
                best_idx = toc_idx
                best_uid = uid
            end
        end
    end
    return best_uid
end

local TocMapInstance = {}
TocMapInstance.__index = TocMapInstance

function TocMapInstance:new(plugin)
    return setmetatable({
        plugin = plugin,
        _chapter_list = nil,
        _toc_map = nil,
        pageno = nil,
    }, self)
end

function TocMapInstance:setPageno(pageno)
    if pageno then self.pageno = pageno end
end

function TocMapInstance:ensure()
    if self._toc_map then return self._toc_map end
    local document = self.plugin.ui and self.plugin.ui.document
    local file = document and document.file
    if not file then return nil end
    local chapters = self._chapter_list
    if not chapters or #chapters == 0 then
        chapters = self.plugin.database:listChapters(file)
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
            page = tonumber(item.page) or 0,
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

function TocMapInstance:clearCache()
    self._chapter_list = nil
    self._toc_map = nil
end

function TocMapInstance:getChapterBounds(chapter_uid)
    if not chapter_uid then return nil end
    local map = self:ensure()
    if not map then return nil end
    return map.bounds[tostring(chapter_uid)]
end

function TocMapInstance:currentWereadChapterUid()
    local document = self.plugin.ui and self.plugin.ui.document
    if not document or not document.file then return nil end
    local map = self:ensure()
    if not map then return nil end

    -- Page mode reports the page, not a Y offset. The page-top Y can still
    -- sit in the previous WeRead chapter when a heading starts mid-page.
    local xp = document.getXPointer and document:getXPointer()
    local pageno = self.pageno
    if not pageno and document.getCurrentPage then
        pageno = document:getCurrentPage()
    end
    local scroll = self.plugin.ui.view and self.plugin.ui.view.view_mode == "scroll"
    if not scroll and pageno then
        local toc_idx = TocMap.indexAtPage(map.toc, pageno)
        local uid = TocMap.uidAtTocIndex(map.matched, toc_idx)
        if uid then return uid end
    end
    if xp and document.compareXPointers then
        local uid = TocMap.uidAtXPointer(map.chapters, map.matched, map.toc, document, xp)
        if uid then return uid end
    end
    if scroll and pageno then
        local toc_idx = TocMap.indexAtPage(map.toc, pageno)
        local uid = TocMap.uidAtTocIndex(map.matched, toc_idx)
        if uid then return uid end
    end
    return TocMap.uidAtPos(map.bounds, document.getCurrentPos and document:getCurrentPos() or 0)
end

function TocMap.newInstance(plugin)
    return TocMapInstance:new(plugin)
end

TocMap.matcher = Matcher

return TocMap
