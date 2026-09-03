package.path = "./?.lua;./?/init.lua;" .. package.path

local Matcher = require("lib.toc_matcher")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function assert_true(value, msg)
    if not value then error(msg or "expected true", 2) end
end

-- Deterministic normalization, including chapter-number semantics.
assert_eq(Matcher.normalize_title(" 第一章：黎明之前 "), "第1章黎明之前", "normalize Chinese chapter number")
assert_eq(Matcher.normalize_title("第 12 章 - 黎明之前"), "第12章黎明之前", "normalize Arabic chapter number")
assert_eq(Matcher.normalize_title("《序》"), "序", "normalize brackets")

assert_eq(Matcher.similarity("第一章 黎明之前", "第1章：黎明之前"), 1, "equivalent chapter titles are exact after normalization")
assert_true(Matcher.similarity("第一章 黎明之前", "黎明之前") >= 0.78,
    "matching chapter subject should have a strong score")
assert_true(Matcher.similarity("序", "序言") < 0.78,
    "short titles must not fuzzy-match on a tiny fragment")

-- High-confidence fuzzy match beats an unrelated TOC entry.
local candidate = Matcher.find_candidate("第十二章 黎明之前", {
    { title = "第十一章 黑夜" },
    { title = "第12章：黎明之前" },
    { title = "第十三章 破晓" },
}, 0)
assert_eq(candidate.index, 2, "fuzzy candidate chooses the strongest title")
assert_true(candidate.score >= Matcher.FUZZY_THRESHOLD, "accepted fuzzy match clears threshold")

-- Ambiguous fuzzy candidates must be rejected rather than guessed.
local ambiguous = Matcher.find_candidate("黎明之前的世界", {
    { title = "第一章 黎明之前" },
    { title = "第二章 黎明之前" },
}, 0)
assert_eq(ambiguous, nil, "ambiguous fuzzy candidates are rejected")

-- Conservative monotonic alignment: an unknown chapter does not consume a TOC entry.
local map = Matcher.match({
    { chapterUid = "1", title = "第一章 开始" },
    { chapterUid = "x", title = "神秘章节" },
    { chapterUid = "2", title = "第二章 继续" },
}, {
    { title = "第一章：开始" },
    { title = "附录说明" },
    { title = "第二章：继续" },
})
assert_eq(map["1"], 1, "first chapter matches after normalization")
assert_eq(map["x"], nil, "unknown chapter remains unmatched")
assert_eq(map["2"], 3, "later known chapter still matches")

-- Anchor-to-anchor fill: same hole count and similar titles.
local filled = Matcher.match({
    { chapterUid = "1", title = "第一章" },
    { chapterUid = "a", title = "插曲：黎明" },
    { chapterUid = "b", title = "插曲：黄昏" },
    { chapterUid = "2", title = "第二章" },
}, {
    { title = "第1章" },
    { title = "插曲黎明" },
    { title = "插曲黄昏" },
    { title = "第2章" },
})
assert_eq(filled["1"], 1, "fill keeps first anchor")
assert_eq(filled["a"], 2, "fill pairs first hole")
assert_eq(filled["b"], 3, "fill pairs second hole")
assert_eq(filled["2"], 4, "fill keeps last anchor")

-- Hole count matches but titles do not: still unmatched.
local refused = Matcher.match({
    { chapterUid = "1", title = "第一章" },
    { chapterUid = "x", title = "神秘章节" },
    { chapterUid = "2", title = "第二章" },
}, {
    { title = "第1章" },
    { title = "附录说明" },
    { title = "第2章" },
})
assert_eq(refused["1"], 1, "refused fill keeps first anchor")
assert_eq(refused["x"], nil, "unlike titles are not filled")
assert_eq(refused["2"], 3, "refused fill keeps last anchor")

-- Unequal hole counts: do not guess.
local uneven = Matcher.match({
    { chapterUid = "1", title = "第一章" },
    { chapterUid = "x", title = "临时标题甲" },
    { chapterUid = "2", title = "第二章" },
}, {
    { title = "第1章" },
    { title = "插曲黎明" },
    { title = "多余一节" },
    { title = "第2章" },
})
assert_eq(uneven["x"], nil, "uneven holes stay unmatched")

print("ok")
