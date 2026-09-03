local ltn12 = require("ltn12")
local socketutil = require("socketutil")
local http = require("socket.http")
local Weread = require("lib.protocol")
local logger = require("lib.logger")
local json = require("json")

local DEFAULT_TIMEOUT_SECONDS = 15
local Client = {}
Client.__index = Client

local function header_value(headers, name)
    if type(headers) ~= "table" or type(name) ~= "string" then return nil end
    if headers[name] ~= nil then return headers[name] end
    local target = name:lower()
    if headers[target] ~= nil then return headers[target] end
    for key, value in pairs(headers) do
        if type(key) == "string" and key:lower() == target then return value end
    end
    return nil
end

local function http_error(client, code, text, headers)
    text = text or ""
    local content_type = tostring(header_value(headers, "content-type") or "unknown")
    local parts = {
        "HTTP " .. tostring(code),
        "content_type=" .. content_type,
        "body_bytes=" .. tostring(#text),
    }
    local looks_like_json = content_type:lower():find("json", 1, true)
        or text:match("^%s*{") ~= nil
        or text:match("^%s*%[") ~= nil
    if looks_like_json and #text <= 65536 then
        local ok, data = pcall(function()
            return client:json_decode(text)
        end)
        if ok and type(data) == "table" then
            local err_code = data.errCode or data.errcode or data.code
            local err_message = data.errMsg or data.errmsg or data.message or data.msg
            if err_code ~= nil then
                table.insert(parts, "error_code=" .. tostring(err_code))
            end
            if err_message ~= nil then
                local message = tostring(err_message):gsub("[%c]+", " "):sub(1, 200)
                table.insert(parts, "error_message=" .. message)
            end
        end
    end
    return table.concat(parts, ", ")
end

local function deepcopy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = deepcopy(item)
    end
    return out
end

local function log_response(label, context, text)
    context = context or {}
    text = text or ""
    -- 默认只输出基本信息，不输出完整响应体
    local response_body = ""
    if logger.isDebug() then
        response_body = text
    else
        response_body = "<hidden> (enable debug_log to see)"
    end

    logger.err(
        label,
        "method=", tostring(context.method or "unknown"),
        "url=", tostring(context.url or "unknown"),
        "api=", tostring(context.api_name or "unknown"),
        "status=", tostring(context.code or "unknown"),
        "content_type=", tostring(header_value(context.headers, "content-type") or "unknown"),
        "body_bytes=", tostring(#text),
        "response_body=", response_body
    )
end

local function merge_req_opts(default_opts, user_opts)
    default_opts = default_opts or {}
    if not user_opts then
        return deepcopy(default_opts)
    end
    local result = deepcopy(default_opts)
    for k, v in pairs(user_opts) do
        if k == "headers" and type(v) == "table" then
            result.headers = result.headers or {}
            for hk, hv in pairs(v) do
                local target = hk:lower()
                for existing_k, _ in pairs(result.headers) do
                    if type(existing_k) == "string" and existing_k:lower() == target then
                        result.headers[existing_k] = nil
                    end
                end
                result.headers[hk] = deepcopy(hv)
            end
        else
            result[k] = deepcopy(v)
        end
    end
    return result
end

local function absolute_url(base_url, location)
    if type(location) ~= "string" or location == "" then
        return nil
    end
    if location:match("^https?://") then
        return location
    end
    local scheme, host = tostring(base_url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return location
    end
    if location:sub(1, 1) == "/" then
        return scheme .. "://" .. host .. location
    end
    local prefix = base_url:match("^(https?://.*/)") or (scheme .. "://" .. host .. "/")
    return prefix .. location
end

local function url_origin(url)
    local scheme, authority = tostring(url or ""):match("^(https?)://([^/]+)")
    if not scheme then
        return nil
    end
    return scheme:lower() .. "://" .. authority:lower()
end

local function clear_cross_origin_headers(headers)
    for key in pairs(headers or {}) do
        local name = tostring(key):lower()
        if name == "authorization" or name == "cookie" or name == "origin" then
            headers[key] = nil
        end
    end
end

function Client:new(settings)
    return setmetatable({
        settings = settings,
    }, self)
end

function Client:isOnline()
    local NetworkMgr = require("ui/network/manager")
    return NetworkMgr:isOnline()
end

function Client:chapters(book_id)
    local result = self:gateway("/book/chapterinfo", {
        bookId = tostring(book_id),
    })
    local rows = type(result) == "table" and result.chapters or {}
    local chapters = {}
    for _, row in ipairs(rows) do
        local uid = row.chapterUid
        if uid then
            chapters[#chapters + 1] = {
                chapterUid = tostring(uid),
                title = tostring(row.title or ""),
                level = tonumber(row.level),
                wordCount = tonumber(row.wordCount),
                isMPChapter = tonumber(row.isMPChapter) == 1 or row.isMPChapter == true,
            }
        end
    end
    chapters.synckey = tonumber(result and result.synckey) or 0
    return chapters
end

-- Skip public-account chapters, empty/copyright nodes, and duplicate uids.
-- Do not filter by TOC level: body underlines can sit on any heading depth.
function Client.filter_chapters_for_underlines(chapters)
    local function dedupe(rows)
        local seen, out = {}, {}
        for _, chapter in ipairs(rows or {}) do
            local uid = tostring(chapter.chapterUid or "")
            if uid ~= "" and not seen[uid] then
                seen[uid] = true
                out[#out + 1] = chapter
            end
        end
        return out
    end

    local unique = dedupe(chapters)
    local eligible = {}
    for _, chapter in ipairs(unique) do
        if not chapter.isMPChapter then
            local empty = chapter.wordCount ~= nil and chapter.wordCount <= 0
            if not empty then
                eligible[#eligible + 1] = chapter
            end
        end
    end
    if #eligible > 0 then return eligible end
    return unique
end

function Client.format_rating(value)
    local n = tonumber(value)
    if not n then return nil end
    if n > 100 then n = n / 10 end
    return string.format("%.1f", n)
end

function Client.formatSearchHit(candidate)
    if type(candidate) ~= "table" then return nil end
    local info = candidate.bookInfo or candidate
    local book_id = info.bookId or candidate.bookId
    if not book_id then return nil end
    local author = tostring(info.author or candidate.author or "")
    local publisher = tostring(info.publisher or candidate.publisher or "")
    local isbn = tostring(info.isbn or candidate.isbn or "")
    local rating = Client.format_rating(candidate.newRating or info.newRating)
    local parts = {}
    if author ~= "" then parts[#parts + 1] = author end
    if publisher ~= "" then parts[#parts + 1] = publisher end
    if rating then parts[#parts + 1] = rating end
    if isbn ~= "" then parts[#parts + 1] = isbn end
    return {
        book_id = tostring(book_id),
        title = info.title or tostring(book_id),
        author = author,
        publisher = publisher,
        isbn = isbn,
        subtitle = table.concat(parts, " · "),
    }
end

function Client:search(keyword)
    local result = self:gateway("/store/search", {
        keyword = keyword,
        count = 20,
        scope = Weread.SEARCH_SCOPE_EBOOK,
    })
    return result.results or {}
end

function Client:reviews(book_id, chapter_uid, ranges)
    local batch = {}
    for _, range in ipairs(ranges or {}) do
        batch[#batch + 1] = {
            range = range,
            maxIdx = 0,
            count = 20,
            synckey = 0,
        }
    end
    if not book_id or tostring(book_id) == "" then
        error("empty book_id")
    end
    if not chapter_uid then
        error("empty chapter_uid")
    end
    if #batch == 0 then
        return { reviews = {} }
    end
    chapter_uid = tonumber(chapter_uid) or chapter_uid
    local result = self:gateway("/book/readreviews", {
        bookId = tostring(book_id),
        chapterUid = chapter_uid,
        reviews = batch,
    })
    if type(result) ~= "table" or type(result.reviews) ~= "table" then
        error("readreviews: gateway returned invalid data")
    end
    return result
end

function Client:json_encode(data)
    return json.encode(data)
end

function Client:json_decode(text)
    return json.decode(text)
end

function Client:decode_http_json(text, context)
    local ok, data = pcall(self.json_decode, self, text)
    if not ok then
        log_response("HTTP JSON decode failed:", context, text)
        error(data, 0)
    end

    if type(data) == "table" then
        if type(data.upgrade_info) == "table" then
            log_response("API requested a skill upgrade:", context, text)
            local info = data.upgrade_info
            local msg = tostring(info.message or info.msg or "Weread Skill needs an update")
            error("upgrade_required " .. msg, 0)
        end
        local err_code = data.errCode or data.errcode
        if err_code ~= nil and tonumber(err_code) ~= 0 then
            log_response("API response reported an error:", context, text)
            local msg = tostring(data.errMsg or data.errmsg or data.message or "API error")
            error(tostring(err_code) .. " " .. msg, 0)
        end
    end
    return data
end

function Client:request(opts)
    opts = opts or {}
    local body = opts.body
    local response
    local headers = {
        ["User-Agent"] = Weread.USER_AGENT,
        ["Accept"] = "application/json, text/plain, */*"
    }

    if body then
        headers["Content-Length"] = tostring(#body)
    end
    local block_timeout = DEFAULT_TIMEOUT_SECONDS
    local total_timeout = -1
    if type(opts.timeout) == "table" and opts.timeout[1] then
        block_timeout = opts.timeout[1]
        total_timeout = opts.timeout[2] or block_timeout
    elseif type(opts.timeout) == "number" then
        block_timeout = opts.timeout
    end
    socketutil:set_timeout(block_timeout, total_timeout)

    local sink_to_use = opts.sink
    if not sink_to_use then
        response = {}
        sink_to_use = socketutil.table_sink(response)
    end

    local req_opts = merge_req_opts({
        method = body and "POST" or "GET",
        source = body and ltn12.source.string(body) or nil,
        sink = sink_to_use,
        headers = headers,
    }, opts)
    -- Redirects are handled explicitly by request_follow so credentials can be
    -- rebuilt for every destination instead of being copied across origins.
    req_opts.redirect = false
    local diagnostic_api = req_opts.diagnostic_api
    req_opts.diagnostic_api = nil

    local results = { pcall(http.request, req_opts) }
    socketutil:reset_timeout()
    if not results[1] then
        logger.err(
            "HTTP transport failed:",
            "method=", tostring(req_opts.method),
            "url=", tostring(req_opts.url),
            "api=", tostring(diagnostic_api or "unknown"),
            "error=", tostring(results[2])
        )
        error(results[2])
    end
    local _, raw_code, resp_headers, status = results[2], results[3], results[4], results[5]
    if status == nil and type(raw_code) == "string" then
        status = raw_code
    end

    if not opts.sink then response = table.concat(response) end

    local code = tonumber(raw_code)
    if code and code >= 400 then
        log_response("HTTP response failed:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    elseif not code then
        log_response("HTTP response unavailable:", {
            method = req_opts.method,
            url = req_opts.url,
            api_name = diagnostic_api,
            code = status or raw_code,
            headers = resp_headers,
        }, type(response) == "string" and response or "")
    end

    return response, code, resp_headers or {}, status
end

function Client:request_follow(opts, max_redirects)
    local request_opts = deepcopy(opts or {})
    local on_redirect = request_opts.on_redirect
    request_opts.on_redirect = nil
    max_redirects = max_redirects or request_opts.maxredirects or 5
    request_opts.maxredirects = nil
    local url = request_opts.url

    for _redirect_index = 0, max_redirects do
        request_opts.url = url
        local text, code, headers, status = self:request(request_opts)
        local is_redirect = code == 301 or code == 302 or code == 303
            or code == 307 or code == 308
        if not is_redirect then
            return text, code, headers, status, url
        end

        local next_url = absolute_url(url, header_value(headers, "location"))
        if not next_url then
            return text, code, headers, status, url
        end
        if on_redirect then
            on_redirect(url, next_url, code)
        end
        if url_origin(url) ~= url_origin(next_url) then
            clear_cross_origin_headers(request_opts.headers)
        end
        if code == 303 or ((code == 301 or code == 302)
                and request_opts.method ~= "GET" and request_opts.method ~= "HEAD") then
            request_opts.method = "GET"
            request_opts.body = nil
            request_opts.source = nil
            if request_opts.headers then
                for key in pairs(request_opts.headers) do
                    if tostring(key):lower() == "content-length" then
                        request_opts.headers[key] = nil
                    end
                end
            end
        end
        url = next_url
    end
    error("Too many redirects")
end

function Client:post_json(url, data, opts)
    opts = opts or {}
    local referer = header_value(opts.headers, "Referer") or opts.referer
    local req_opts = merge_req_opts(opts, {
        url = url,
        method = "POST",
        body = self:json_encode(data),
        headers = {
            ["Content-Type"] = "application/json;charset=UTF-8",
            ["Origin"] = "https://weread.qq.com",
            ["Referer"] = referer or "https://weread.qq.com/",
        }
    })
    local text, code, resp_headers = self:request(req_opts)
    if code and code >= 200 and code < 300 then
        return self:decode_http_json(text, {
            method = "POST",
            url = url,
            api_name = opts.diagnostic_api,
            code = code,
            headers = resp_headers,
        }), code, resp_headers
    end
    error(http_error(self, code, text, resp_headers))
end

function Client:gateway(api_name, params, opts)
    opts = opts or {}
    local payload = merge_req_opts({
        api_name = api_name,
        skill_version = (params and params.skill_version) or Weread.SKILL_VERSION
    }, params)

    local api_key = self.settings:get("api_key", "")
    if api_key == "" then
        error("Weread API key is not configured")
    end
    local post_opts = {
        diagnostic_api = api_name,
        headers = {
            ["Authorization"] = "Bearer " .. api_key,
        },
    }
    -- Optional shorter timeout for interactive thought fetches (avoids long UI stalls).
    if opts.timeout ~= nil then
        post_opts.timeout = opts.timeout
    end
    return self:post_json("https://i.weread.qq.com/api/agent/gateway", payload, post_opts)
end

function Client.is_login_expired(err)
    local text = tostring(err or "")
    return text:find("-2012", 1, true) ~= nil
        or text:find("登录超时", 1, true) ~= nil
end

function Client.is_skill_upgrade_required(err)
    local text = tostring(err or "")
    return text:find("upgrade_required", 1, true) ~= nil
        or text:find("upgrade_info", 1, true) ~= nil
end

function Client.items_for_chapter(items, chapter_uid)
    local uid = tonumber(chapter_uid)
    local out = {}
    for _, item in ipairs(items or {}) do
        local item_uid = tonumber(item.chapterUid)
        if not item_uid or item_uid == uid then
            out[#out + 1] = item
        end
    end
    return out
end

function Client:popular_underlines_sync(book_id, chapter_uid, synckey)
    local uid = tonumber(chapter_uid) or error("invalid chapter_uid")
    local result = self:gateway("/book/bestbookmarks", {
        bookId = tostring(book_id),
        chapterUid = uid,
        synckey = tonumber(synckey) or 0,
    })
    if type(result) ~= "table" then error("bestbookmarks: gateway returned non-table") end
    local items = type(result.items) == "table" and result.items or {}
    return {
        items = Client.items_for_chapter(items, uid),
        synckey = tonumber(result.synckey) or tonumber(synckey) or 0,
        unchanged = tonumber(synckey) and tonumber(synckey) ~= 0
            and tonumber(result.synckey) == tonumber(synckey),
    }
end

function Client:parseReviewItems(review)
    local items = {}
    local pages = review.pageReviews
    if type(pages) ~= "table" or next(pages) == nil then
        pages = review.review and { review } or {}
    end
    local page_index = 0
    for _, page in ipairs(pages) do
        page_index = page_index + 1
        local item = page.review or {}
        local author = item.author or {}
        local abstract
        if page_index == 1 then
            abstract = item.abstract or item.contextAbstract
            if type(abstract) ~= "string" or abstract == "" then abstract = nil end
        end
        items[#items + 1] = {
            abstract = abstract,
            author = tostring(author.nick or author.name or "匿名"),
            content = tostring(item.content or ""),
            likes_count = tonumber(page.likesCount) or 0,
        }
    end
    return items
end

function Client.hasThoughtContent(items)
    for _, item in ipairs(items or {}) do
        if type(item.content) == "string" and item.content:find("%S") then
            return true
        end
    end
    return false
end

Client.header_value = header_value
Client.deepcopy = deepcopy

return Client
