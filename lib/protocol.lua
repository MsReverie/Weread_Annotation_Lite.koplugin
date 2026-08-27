local Weread = {}

Weread.USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/135.0.0.0 Safari/537.36 Edg/135.0.0.0"
Weread.SKILL_VERSION = "1.0.4"
Weread.SEARCH_SCOPE_EBOOK = 10

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

return Weread
