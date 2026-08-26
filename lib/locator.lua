local Locator = {}

local MAX_SEARCH_HITS = 16
local FALLBACK_QUOTE_BYTES = 90

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

local function search(document, text)
    if not document or type(document.findAllText) ~= "function" then
        return {}
    end
    local ok, results = pcall(document.findAllText, document, text, true, 0,
        MAX_SEARCH_HITS, false, 0)
    return ok and type(results) == "table" and results or {}
end

local function position(document, result)
    if type(result) ~= "table" or not result.start or not result["end"] then
        return nil
    end
    local ok, value = pcall(document.getPosFromXPointer, document, result.start)
    return ok and tonumber(value) or nil
end

local function choose_after(document, results, minimum)
    local selected, selected_position
    for _, result in ipairs(results) do
        local value = position(document, result)
        if value and value > minimum and (not selected_position or value < selected_position) then
            selected, selected_position = result, value
        end
    end
    return selected, selected_position
end

function Locator.locate(document, chapter_uid, underlines)
    local records = {}
    local cursor = -math.huge
    local rows = {}
    for _, row in ipairs(underlines or {}) do
        rows[#rows + 1] = row
    end
    table.sort(rows, function(a, b) return range_start(a) < range_start(b) end)

    for _, row in ipairs(rows) do
        local text = quote(row)
        if text ~= "" then
            local results = search(document, text)
            if #results == 0 and #text > FALLBACK_QUOTE_BYTES then
                results = search(document, utf8_prefix(text, FALLBACK_QUOTE_BYTES))
            end
            local result, result_position = choose_after(document, results, cursor)
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

return Locator
