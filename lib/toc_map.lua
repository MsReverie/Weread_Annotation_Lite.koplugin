local TocMap = {}

function TocMap.normalize(text)
    text = tostring(text or "")
    text = text:gsub("%s+", "")
    text = text:gsub("[%.%-%(%)%[%]《》【】　]", "")
    return text
end

local function titles_related(want, have)
    if want == "" or have == "" then return false end
    if want == have then return true end
    return want:find(have, 1, true) ~= nil or have:find(want, 1, true) ~= nil
end

-- Order-preserving match of WeRead chapters onto a local TOC.
-- Returns map[chapterUid] = toc_index (1-based).
function TocMap.match(weread_chapters, toc_items)
    local map = {}
    local used = {}
    local last = 0
    for _, chapter in ipairs(weread_chapters or {}) do
        local uid = tostring(chapter.chapterUid or "")
        local want = TocMap.normalize(chapter.title)
        if uid ~= "" and want ~= "" then
            local found
            for i = last + 1, #(toc_items or {}) do
                if not used[i] and TocMap.normalize(toc_items[i].title) == want then
                    found = i
                    break
                end
            end
            if not found then
                for i = last + 1, #(toc_items or {}) do
                    if not used[i] and titles_related(want, TocMap.normalize(toc_items[i].title)) then
                        found = i
                        break
                    end
                end
            end
            if found then
                used[found] = true
                map[uid] = found
                last = found
            end
        end
    end
    -- Title match can miss a later chapter (e.g. 第六章 vs 第6章). Pair any
    -- leftover WeRead chapter with the next unused TOC entry after the
    -- previous match so uidAtPos still changes at that boundary.
    local last_idx = 0
    for _, chapter in ipairs(weread_chapters or {}) do
        local uid = tostring(chapter.chapterUid or "")
        if uid ~= "" then
            if map[uid] then
                last_idx = map[uid]
            else
                local found
                for i = last_idx + 1, #(toc_items or {}) do
                    if not used[i] then
                        found = i
                        break
                    end
                end
                if found then
                    used[found] = true
                    map[uid] = found
                    last_idx = found
                end
            end
        end
    end
    return map
end

-- uid -> { start_pos, end_pos, start_xp } using the next matched WeRead chapter as end.
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

return TocMap
