local Locator = {}

-- findAllText is whole-document. findText from the chapter origin avoids
-- earlier-book hits filling the cap before this chapter is reached.
local MAX_SEARCH_HITS = 512
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

local function search_all(document, text)
    local ok, results = pcall(document.findAllText, document, text, true, 0,
        MAX_SEARCH_HITS, false, SEARCH_FLAGS)
    return ok and Locator.normalize_hits(results) or {}
end

local function search_from_here(document, text)
    -- origin 0 = from current position, direction 0 = forward
    local ok, results = pcall(document.findText, document, text, 0, 0, true,
        0, false, MAX_SEARCH_HITS, SEARCH_FLAGS)
    if ok then
        local hits = Locator.normalize_hits(results)
        if #hits > 0 then return hits end
    end
    return search_all(document, text)
end

function Locator.withOrigin(document, xpointer, fn)
    if not document or type(xpointer) ~= "string" or xpointer == "" then
        return fn(false)
    end
    local ok_save, saved = pcall(document.getXPointer, document)
    if not ok_save then saved = nil end
    local ok_goto = pcall(document.gotoXPointer, document, xpointer)
    local ok, result = pcall(fn, ok_goto == true)
    if saved then pcall(document.gotoXPointer, document, saved) end
    if not ok then error(result, 0) end
    return result
end

local function position(document, result)
    if type(result) ~= "table" or not result.start or not result["end"] then
        return nil
    end
    local ok, value = pcall(document.getPosFromXPointer, document, result.start)
    return ok and tonumber(value) or nil
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

function Locator.locate(document, chapter_uid, underlines, bounds)
    local rows = {}
    for _, row in ipairs(underlines or {}) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b) return range_start(a) < range_start(b) end)

    local function run(search_fn)
        local records = {}
        local cursor = -math.huge
        for _, row in ipairs(rows) do
            local text = quote(row)
            if text ~= "" then
                local results = search_fn(text)
                local result, result_position = Locator.choose_after(document, results, cursor, bounds)
                if not result and #text > FALLBACK_QUOTE_BYTES then
                    results = search_fn(utf8_prefix(text, FALLBACK_QUOTE_BYTES))
                    result, result_position = Locator.choose_after(document, results, cursor, bounds)
                end
                if result then
                    cursor = result_position
                    records[#records + 1] = {
                        chapter_uid = tostring(chapter_uid),
                        range = tostring(row.range or ""),
                        text = text,
                        pos0 = result.start,
                        pos1 = result["end"],
                        items = {},
                    }
                end
            end
        end
        return records
    end

    local start_xp = type(bounds) == "table" and bounds.start_xp or nil
    if start_xp then
        return Locator.withOrigin(document, start_xp, function(moved)
            if moved then
                return run(function(text) return search_from_here(document, text) end)
            end
            return run(function(text) return search_all(document, text) end)
        end)
    end
    return run(function(text) return search_all(document, text) end)
end

return Locator
