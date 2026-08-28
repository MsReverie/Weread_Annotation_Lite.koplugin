local Locator = {}

-- findText searches a short window around the document's current Y origin.
-- Callers pass a chapter (or previous-hit) xpointer, then restore the reader's
-- xpointer so the view is not left at the search origin.
local MAX_SEARCH_HITS = 64
local FALLBACK_QUOTE_BYTES = 90
local SEARCH_FLAGS = 0x00FF

local function scalar(value)
    if type(value) == "string" or type(value) == "number" then
        return tostring(value)
    end
    return ""
end

local function clean_quote(value)
    local text = scalar(value)
    text = text:gsub("^%s+", ""):gsub("%s+$", "")
    return text:gsub("[\226][\128][\139-\141]", "")
end

local function quote(row)
    for _, key in ipairs({ "markText", "bookmarkText", "rangeText", "abstract", "text" }) do
        local value = clean_quote(row and row[key])
        if value ~= "" then return value end
    end
    return ""
end

local function utf8_prefix(text, max_bytes)
    if #text <= max_bytes then return text end
    local cut = max_bytes
    while cut > 1 do
        local byte = text:byte(cut + 1)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        cut = cut - 1
    end
    return text:sub(1, cut)
end

local function range_start(row)
    return tonumber(tostring(row and row.range or ""):match("^(%d+)")) or math.huge
end

function Locator.normalize_hits(results)
    if type(results) ~= "table" then return {} end
    if results.start and results["end"] then
        return { results }
    end
    local out = {}
    for _, result in ipairs(results) do
        if type(result) == "table" and result.start and result["end"] then
            out[#out + 1] = result
        end
    end
    return out
end

function Locator.search(document, text)
    if not document or text == nil or text == "" then return {} end
    local ok, results = pcall(document.findText, document, text, 0, 0, true,
        0, false, MAX_SEARCH_HITS, SEARCH_FLAGS)
    if document.clearSelection then
        pcall(document.clearSelection, document)
    end
    return ok and Locator.normalize_hits(results) or {}
end

local function position(document, result)
    if type(result) ~= "table" or not result.start or not result["end"] then
        return nil
    end
    local ok, value = pcall(document.getPosFromXPointer, document, result.start)
    return ok and tonumber((value)) or nil
end

function Locator.choose_after(document, results, minimum, bounds)
    local after = tonumber(minimum) or -math.huge
    local lo, hi = -math.huge, math.huge
    if type(bounds) == "table" then
        lo = tonumber(bounds.start_pos) or lo
        hi = tonumber(bounds.end_pos) or hi
    end
    local selected, selected_position
    for _, result in ipairs(results or {}) do
        local value = position(document, result)
        if value and value > after and value >= lo and value < hi
            and (not selected_position or value < selected_position) then
            selected, selected_position = result, value
        end
    end
    return selected, selected_position
end

function Locator.sortedRows(underlines)
    local rows = {}
    for _, row in ipairs(underlines or {}) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b) return range_start(a) < range_start(b) end)
    return rows
end

--- Locate one underline. Temporarily moves CRE to `from_xp` (chapter start or
--- the previous hit) for findText, then restores the reader's xpointer.
--- @return record|nil, cursor_pos, next_from_xp
function Locator.locateOne(document, chapter_uid, row, cursor, bounds, from_xp)
    if not document or not row then
        return nil, cursor, from_xp
    end
    local text = quote(row)
    if text == "" then
        return nil, cursor, from_xp
    end

    local target_xp = from_xp or (bounds and bounds.start_xp)
    local saved
    if target_xp then
        local ok_save, xp = pcall(document.getXPointer, document)
        if ok_save then saved = xp end
        local ok_goto = pcall(document.gotoXPointer, document, target_xp)
        if not ok_goto then
            if saved then pcall(document.gotoXPointer, document, saved) end
            return nil, cursor, from_xp
        end
    end

    local results = Locator.search(document, text)
    if #results == 0 and #text > FALLBACK_QUOTE_BYTES then
        results = Locator.search(document, utf8_prefix(text, FALLBACK_QUOTE_BYTES))
    end
    if saved then
        pcall(document.gotoXPointer, document, saved)
    end

    local result, result_position = Locator.choose_after(document, results, cursor, bounds)
    if not result then
        return nil, cursor, from_xp
    end
    return {
        chapter_uid = tostring(chapter_uid),
        range = tostring(row.range or ""),
        text = text,
        pos0 = result.start,
        pos1 = result["end"],
        items = {},
    }, result_position, result.start
end

return Locator
