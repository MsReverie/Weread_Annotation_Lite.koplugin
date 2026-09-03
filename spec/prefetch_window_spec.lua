package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded.logger = {
    info = function() end, warn = function() end, err = function() end,
}
package.loaded.gettext = function(s) return s end
package.loaded["ui/uimanager"] = {
    preventStandby = function() end,
    allowStandby = function() end,
    scheduleIn = function(_, fn) end,
    setDirty = function() end,
}
package.loaded["lib.locator"] = { sortedRows = function(rows) return rows or {} end }
package.loaded["ffi/util"] = {}
package.loaded.json = {
    encode = function() return "{}" end,
    decode = function() return {} end,
}

local Prefetch = require("lib.prefetch")

local function chapters(n)
    local rows = {}
    for i = 1, n do
        rows[i] = { chapterUid = tostring(i), title = "ch" .. i }
    end
    return rows
end

local function prefetch(catalog, cached, window_size)
    local cached_set = {}
    for _, uid in ipairs(cached or {}) do
        cached_set[tostring(uid)] = true
    end
    return Prefetch:new({
        settings = {
            get = function(_, key, default)
                if key == "prefetch_underline_window" then
                    return window_size or 5
                end
                return default
            end,
        },
        database = {
            listChapters = function() return catalog end,
            cachedChapterSet = function() return cached_set end,
        },
    })
end

local function uids(window)
    if not window then return nil end
    local out = {}
    for i, chapter in ipairs(window) do
        out[i] = tostring(chapter.chapterUid)
    end
    return table.concat(out, ",")
end

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local catalog = chapters(10)
local p = prefetch(catalog, { "1", "2", "3", "4", "5" })

local window, reason = p:planWindow("file", "1")
assert_eq(window, nil, "still in first window: " .. tostring(reason))
assert_eq(reason, "ahead-ok", "chapters 2-4 cached is ahead-ok")

window, reason = p:planWindow("file", "5")
assert_eq(uids(window), "6,7,8,9,10", "lookahead from chapter 5: " .. tostring(reason))

window, reason = p:planWindow("file", "6")
assert_eq(uids(window), "6,7,8,9,10", "second window at chapter 6: " .. tostring(reason))

p = prefetch(catalog, { "7", "8", "9" })
window, reason = p:planWindow("file", "6")
assert_eq(uids(window), "6,10", "uncached current chapter must be fetched: " .. tostring(reason))

p = prefetch(catalog, {})
window, reason = p:planWindow("file", "1")
assert_eq(uids(window), "1,2,3,4,5", "unlocated current chapter must enter the window: " .. tostring(reason))

p = prefetch(catalog, { "1", "2", "3", "4", "5", "6", "7", "8", "9", "10" })
window, reason = p:planWindow("file", "3")
assert_eq(window, nil, "all cached")
assert_eq(reason, "already-cached", "all cached → already-cached")

p = prefetch(catalog, { "8", "9", "10" })
window, reason = p:planWindow("file", "10")
assert_eq(window, nil, "at end of book")
assert_eq(reason, "end-of-book", "at end of book → end-of-book")

p = prefetch(catalog, { "1", "2", "3", "4", "5" })
window, reason = p:planWindow("file", "99")
assert_eq(window, nil, "unknown uid → nil")
assert_eq(reason, "unknown-chapter", "unknown uid → unknown-chapter")

window, reason = p:planWindow("file", "99", { force = true })
assert_eq(uids(window), "1,2,3,4,5", "force with unknown uid → start from 1")

p = prefetch({}, {})
window, reason = p:planWindow("file", "1")
assert_eq(window, nil, "empty catalog → nil")
assert_eq(reason, "no-catalog", "empty catalog → no-catalog")

p = prefetch(chapters(3), { "1" }, 2)
window, reason = p:planWindow("file", "1")
assert_eq(uids(window), "2,3", "window fits within remaining chapters")

p = prefetch(chapters(5), { "1" }, 1)
window, reason = p:planWindow("file", "1")
assert_eq(uids(window), "2", "window size 1")

window, reason = p:planWindow("file", "5")
assert_eq(window, nil, "last chapter with window 1")
assert_eq(reason, "end-of-book", "last chapter → end-of-book")

p = prefetch(catalog, { "2", "3", "4" }, 5)
window, reason = p:planWindow("file", "1")
assert_eq(uids(window), "1,5", "hole at current forces fetch starting from hole")

p = prefetch(catalog, { "1", "2", "4", "5" }, 5)
window, reason = p:planWindow("file", "3")
assert_eq(uids(window), "3", "hole in middle fetches just the hole")

p = prefetch(catalog, {}, 10)
window, reason = p:planWindow("file", "1")
assert_eq(uids(window), "1,2,3,4,5,6,7,8,9,10", "window larger than catalog")

print("ok")
