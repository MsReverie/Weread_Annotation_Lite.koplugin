package.path = "./?.lua;./?/init.lua;" .. package.path

package.loaded.ltn12 = {}
package.loaded.socketutil = {
    set_timeout = function() end,
    reset_timeout = function() end,
    table_sink = function() return function() end end,
}
package.loaded["socket.http"] = { request = function() end }
package.loaded["lib.protocol"] = {
    USER_AGENT = "",
    SKILL_VERSION = "1.0.4",
    SEARCH_SCOPE_EBOOK = 10,
}
package.loaded["lib.logger"] = {
    info = function() end, warn = function() end, err = function() end,
    isDebug = function() return false end,
}
package.loaded.json = { encode = function() return "{}" end, decode = function() return {} end }
package.loaded["ui/network/manager"] = { isOnline = function() return true end }

local API = require("lib.api")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

-- ── formatSearchHit ──────────────────────────────────────────────────────────

local hit = API.formatSearchHit({
    bookId = "abc123",
    bookInfo = { title = "Test Book", author = "Author A" },
})
assert_eq(hit.book_id, "abc123", "book_id from bookInfo.bookId")
assert_eq(hit.title, "Test Book", "title")
assert_eq(hit.author, "Author A", "author")
assert_eq(hit.subtitle:find("Author A"), 1, "subtitle contains author")

-- Missing bookId → nil
assert_eq(API.formatSearchHit({ title = "no id" }), nil, "no bookId → nil")
assert_eq(API.formatSearchHit("not a table"), nil, "non-table → nil")

-- Candidate without bookInfo (flat structure)
hit = API.formatSearchHit({
    bookId = "xyz",
    title = "Flat Book",
    author = "Auth B",
    newRating = 850,
})
assert_eq(hit.book_id, "xyz", "flat bookId")
assert_eq(hit.title, "Flat Book", "flat title")
assert_eq(hit.subtitle:find("Auth B"), 1, "subtitle has author")
assert_eq(hit.subtitle:find("85.0") ~= nil, true, "rating 850 → 85.0")

-- ── format_rating ────────────────────────────────────────────────────────────

assert_eq(API.format_rating(850), "85.0", "850 → 85.0")
assert_eq(API.format_rating(90), "90.0", "90 stays 90.0")
assert_eq(API.format_rating(100), "100.0", "100 stays 100.0")
assert_eq(API.format_rating(7), "7.0", "7 stays 7.0")
assert_eq(API.format_rating(nil), nil, "nil → nil")
assert_eq(API.format_rating("bad"), nil, "non-numeric → nil")

-- ── filter_chapters_for_underlines ───────────────────────────────────────────

local chapters = {
    { chapterUid = "1", title = "Ch1", wordCount = 5000,  isMPChapter = false },
    { chapterUid = "2", title = "Ch2", wordCount = 0,     isMPChapter = false },  -- empty
    { chapterUid = "3", title = "MP1", wordCount = 3000,  isMPChapter = true  },  -- MP
    { chapterUid = "4", title = "Ch4", wordCount = 2000,  isMPChapter = false },
    { chapterUid = "1", title = "Ch1 dup", wordCount = 1000, isMPChapter = false }, -- dup uid
}

local filtered = API.filter_chapters_for_underlines(chapters)
assert_eq(#filtered, 2, "2 eligible chapters (empty and MP filtered out)")
assert_eq(filtered[1].chapterUid, "1", "first non-empty non-MP")
assert_eq(filtered[2].chapterUid, "4", "fourth chapter kept")

-- All MP → fallback to unique chapters
local all_mp = {
    { chapterUid = "1", title = "M1", isMPChapter = true,  wordCount = 100 },
    { chapterUid = "2", title = "M2", isMPChapter = true,  wordCount = 200 },
}
local fallback = API.filter_chapters_for_underlines(all_mp)
assert_eq(#fallback, 2, "fallback: all MP chapters kept when no eligible")

-- Empty input
assert_eq(#API.filter_chapters_for_underlines(nil), 0, "nil input")
assert_eq(#API.filter_chapters_for_underlines({}), 0, "empty input")

-- ── hasThoughtContent ────────────────────────────────────────────────────────

assert_eq(API.hasThoughtContent({
    { content = "Hello world" },
}), true, "has content")

assert_eq(API.hasThoughtContent({
    { content = "" },
    { content = "   " },
}), false, "all empty/whitespace → false")

assert_eq(API.hasThoughtContent({}), false, "empty array → false")
assert_eq(API.hasThoughtContent(nil), false, "nil → false")

assert_eq(API.hasThoughtContent({
    { content = nil },
    { author = "x" },
}), false, "nil content and no content field → false")

-- ── is_login_expired ─────────────────────────────────────────────────────────

assert_eq(API.is_login_expired("-2012 登录超时"), true, "error code -2012")
assert_eq(API.is_login_expired("登录超时"), true, "Chinese timeout message")
assert_eq(API.is_login_expired("some other error"), false, "other error → false")
assert_eq(API.is_login_expired(nil), false, "nil → false")

-- ── is_skill_upgrade_required ────────────────────────────────────────────────

assert_eq(API.is_skill_upgrade_required("upgrade_required 需要升级"), true, "upgrade_required string")
assert_eq(API.is_skill_upgrade_required('{"upgrade_info":{}}'), true, "upgrade_info in JSON string")
assert_eq(API.is_skill_upgrade_required("ok"), false, "normal response → false")
assert_eq(API.is_skill_upgrade_required(nil), false, "nil → false")

-- ── parseReviewItems ─────────────────────────────────────────────────────────

local api = API:new({ get = function() return "" end })

-- Standard pageReviews format
local parsed = api:parseReviewItems({
    pageReviews = {
        {
            likesCount = 42,
            review = {
                author = { nick = "UserA", name = "" },
                content = "Great book!",
                abstract = "Best quote",
            },
        },
        {
            likesCount = 10,
            review = {
                author = { nick = "UserB" },
                content = "Second thought",
            },
        },
    },
})
assert_eq(#parsed, 2, "two pageReviews → two items")
assert_eq(parsed[1].author, "UserA", "first author nick")
assert_eq(parsed[1].content, "Great book!", "first content")
assert_eq(parsed[1].abstract, "Best quote", "first abstract")
assert_eq(parsed[1].likes_count, 42, "likes_count")
assert_eq(parsed[2].author, "UserB", "second author")
assert_eq(parsed[2].abstract, nil, "second has no abstract")
assert_eq(parsed[2].likes_count, 10, "second likes")

-- Fallback: no pageReviews, use review directly
parsed = api:parseReviewItems({
    review = {
        author = { nick = "Solo" },
        content = "Only thought",
        abstract = "Solo abstract",
    },
})
assert_eq(#parsed, 1, "fallback single item")
assert_eq(parsed[1].author, "Solo", "fallback author")
assert_eq(parsed[1].content, "Only thought", "fallback content")

-- Empty pages → empty result
parsed = api:parseReviewItems({ pageReviews = {} })
assert_eq(#parsed, 0, "empty pageReviews → empty")

-- Missing review fields → defaults
parsed = api:parseReviewItems({
    pageReviews = {
        { review = {} },
    },
})
assert_eq(parsed[1].author, "匿名", "missing author → 匿名")
assert_eq(parsed[1].content, "", "missing content → empty")

local kept = API.items_for_chapter({
    { chapterUid = 3, range = "1-2", markText = "in chapter" },
    { chapterUid = 9, range = "3-4", markText = "other chapter" },
    { range = "5-6", markText = "unspecified" },
    { chapterUid = "3", range = "7-8", markText = "string uid" },
}, 3)
assert_eq(#kept, 2, "only items whose chapterUid matches the requested chapter")
assert_eq(kept[1].range, "1-2")
assert_eq(kept[2].range, "7-8", "numeric and string chapterUid compare equal")

local intro = API.items_for_chapter({
    { chapterUid = 0, range = "0-1", markText = "intro" },
    { chapterUid = 1, range = "2-3", markText = "ch1" },
}, 0)
assert_eq(#intro, 1, "chapterUid 0 is a real chapter")
assert_eq(intro[1].range, "0-1")

print("ok")
