local Locator = {}

-- findText covers ~2 page heights from the current CRE Y origin.
-- findAllText scans from the start of the book and cannot take a start xpointer.
local MAX_WINDOW_HITS = 64
local MAX_ALL_HITS = 256
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

local function clear_selection(document)
    if document and document.clearSelection then
        pcall(document.clearSelection, document)
    end
end

function Locator.search_window(document, text)
    if not document or not document.findText or text == nil or text == "" then
        return {}
    end
    local ok, results = pcall(document.findText, document, text, 0, 0, true,
        0, false, MAX_WINDOW_HITS, SEARCH_FLAGS)
    clear_selection(document)
    return ok and Locator.normalize_hits(results) or {}
end

function Locator.search(document, text)
    if not document or text == nil or text == "" then return {} end
    local ok, results = pcall(document.findAllText, document, text, true, 0,
        MAX_ALL_HITS, false, SEARCH_FLAGS)
    clear_selection(document)
    return ok and Locator.normalize_hits(results) or {}
end

local function position(document, result)
    if not document then return nil end
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

local function collect(document, text, use_window)
    local search = use_window and Locator.search_window or Locator.search
    local results = search(document, text)
    if #results == 0 and #text > FALLBACK_QUOTE_BYTES then
        results = search(document, utf8_prefix(text, FALLBACK_QUOTE_BYTES))
    end
    return results
end

--- Locate one underline. With `bounds.start_xp`, walk via findText from that
--- xpointer (or `from_xp`) and restore the reader. With pos-only bounds, use
--- findAllText. With no bounds, skip.
--- @return record|nil, cursor_pos, next_from_xp
function Locator.locateOne(document, chapter_uid, row, cursor, bounds, from_xp)
    if not document or not row then
        return nil, cursor, from_xp
    end
    if type(bounds) ~= "table" then
        return nil, cursor, from_xp
    end
    local text = quote(row)
    if text == "" then
        return nil, cursor, from_xp
    end

    local results
    local target_xp = from_xp or bounds.start_xp
    if target_xp and document.gotoXPointer then
        local ok_save, saved = pcall(document.getXPointer, document)
        local ok_goto = pcall(document.gotoXPointer, document, target_xp)
        if ok_goto then
            results = collect(document, text, true)
        else
            results = {}
        end
        if ok_save and saved then
            pcall(document.gotoXPointer, document, saved)
        end
        clear_selection(document)
    else
        results = collect(document, text, false)
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
