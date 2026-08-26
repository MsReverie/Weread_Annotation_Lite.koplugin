local Cookie = {}

function Cookie.to_header(cookies)
    local parts = {}
    for key, value in pairs(cookies or {}) do
        table.insert(parts, key .. "=" .. value)
    end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function Cookie.merge_set_cookie(cookies, set_cookie)
    if not set_cookie or set_cookie == "" then
        return cookies
    end
    cookies = cookies or {}
    if type(set_cookie) == "table" then
        for _, value in pairs(set_cookie) do
            Cookie.merge_set_cookie(cookies, value)
        end
        return cookies
    end
    local allowed = {
        ptcz = true,
        RK = true,
        pgv_pvid = true,
    }
    for name, value in set_cookie:gmatch("([%w_]+)=([^;,\r\n]*)") do
        if name:match("^wr_") or allowed[name] then
            if value == "" then
                cookies[name] = nil
            else
                cookies[name] = value
            end
        end
    end
    return cookies
end

return Cookie
