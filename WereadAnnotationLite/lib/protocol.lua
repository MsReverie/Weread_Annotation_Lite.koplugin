local bit = require("bit")
local Crypto = require("WereadAnnotationLite.lib.crypto")

local Weread = {}

Weread.USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
Weread.DEFAULT_READER_TOKEN = "3c5c8717f3daf09iop3423zafeqoi"
Weread.SKILL_VERSION = "1.0.5"

local function is_digit_string(value)
    return tostring(value):match("^%d+$") ~= nil
end

local function js_string(value)
    if value == true then
        return "true"
    elseif value == false then
        return "false"
    elseif value == nil then
        return "null"
    end
    return tostring(value)
end

function Weread.urlencode(value)
    value = js_string(value)
    return (value:gsub("([^%w%-_%.~])", function(ch)
        return string.format("%%%02X", ch:byte())
    end))
end

local function byte_hex(value)
    local out = {}
    for i = 1, #value do
        out[i] = string.format("%x", value:byte(i))
    end
    return table.concat(out)
end

function Weread.e(value)
    local s = tostring(value)
    local h = Crypto.md5_hex(s)
    local result = h:sub(1, 3)
    local chunks = {}
    local type_flag

    if is_digit_string(s) then
        type_flag = "3"
        local i = 1
        while i <= #s do
            local part = s:sub(i, i + 8)
            table.insert(chunks, string.format("%x", tonumber(part)))
            i = i + 9
        end
    else
        type_flag = "4"
        table.insert(chunks, byte_hex(s))
    end

    result = result .. type_flag .. "2" .. h:sub(-2)
    for i, chunk in ipairs(chunks) do
        result = result .. string.format("%02x", #chunk) .. chunk
        if i < #chunks then
            result = result .. "g"
        end
    end

    if #result < 20 then
        result = result .. h:sub(1, 20 - #result)
    end

    result = result .. Crypto.md5_hex(result):sub(1, 3)
    return result
end

function Weread.web_app_id(user_agent)
    user_agent = user_agent or Weread.USER_AGENT
    local prefix = {}
    local count = 0
    for part in user_agent:gmatch("%S+") do
        count = count + 1
        if count > 12 then
            break
        end
        table.insert(prefix, tostring(#part % 10))
    end

    local hash = 0
    for i = 1, #user_agent do
        hash = bit.band(0x83 * hash + user_agent:byte(i), 0x7fffffff)
    end

    return "wb" .. table.concat(prefix) .. "h" .. tostring(hash)
end

-- Lua string indexes are byte offsets. Return a valid UTF-8 prefix containing
-- at most max_chars code points so payload fields are never cut mid-character.
function Weread.utf8_substr(value, max_chars)
    local text = tostring(value or "")
    local limit = math.max(0, math.floor(tonumber(max_chars) or 0))
    local index = 1
    local count = 0

    while index <= #text and count < limit do
        local first = text:byte(index)
        local width = 0
        local second = text:byte(index + 1)

        if first <= 0x7f then
            width = 1
        elseif first >= 0xc2 and first <= 0xdf
            and second and second >= 0x80 and second <= 0xbf then
            width = 2
        elseif first == 0xe0
            and second and second >= 0xa0 and second <= 0xbf then
            width = 3
        elseif first >= 0xe1 and first <= 0xec
            and second and second >= 0x80 and second <= 0xbf then
            width = 3
        elseif first == 0xed
            and second and second >= 0x80 and second <= 0x9f then
            width = 3
        elseif first >= 0xee and first <= 0xef
            and second and second >= 0x80 and second <= 0xbf then
            width = 3
        elseif first == 0xf0
            and second and second >= 0x90 and second <= 0xbf then
            width = 4
        elseif first >= 0xf1 and first <= 0xf3
            and second and second >= 0x80 and second <= 0xbf then
            width = 4
        elseif first == 0xf4
            and second and second >= 0x80 and second <= 0x8f then
            width = 4
        else
            break
        end

        for offset = 2, width - 1 do
            local continuation = text:byte(index + offset)
            if not continuation or continuation < 0x80 or continuation > 0xbf then
                width = 0
                break
            end
        end
        if width == 0 then
            break
        end

        index = index + width
        count = count + 1
    end

    return text:sub(1, index - 1)
end

local function read_position_payload(opts)
    local now = opts.now or os.time()
    local pc = opts.pclts or opts.pc
    if pc == nil or pc == "" or tonumber(pc) == 0 then
        pc = Weread.e(now)
    end
    local progress = math.floor(tonumber(opts.progress) or 0)
    progress = math.max(0, math.min(100, progress))
    return {
        appId = opts.app_id or Weread.web_app_id(opts.user_agent),
        b = Weread.e(opts.book_id),
        c = Weread.e(opts.chapter_uid or 0),
        ci = math.floor(tonumber(opts.chapter_idx) or 0),
        co = math.max(0, math.floor(tonumber(opts.chapter_offset) or 0)),
        sm = Weread.utf8_substr(opts.summary, 20),
        pr = progress,
        ct = now,
        ps = opts.psvts or opts.ps or "",
        pc = pc,
    }
end


function Weread.reader_url(book_id, chapter_uid)
    local url = "https://weread.qq.com/web/reader/" .. Weread.e(book_id)
    if chapter_uid then
        url = url .. "k" .. Weread.e(chapter_uid)
    end
    return url
end

return Weread
