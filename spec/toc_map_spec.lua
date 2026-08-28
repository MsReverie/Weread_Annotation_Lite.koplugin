package.path = "./?.lua;./?/init.lua;" .. package.path

local TocMap = require("lib.toc_map")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

-- Title-only matching leaves 第六章 unmatched when Weread/EPUB titles
-- differ slightly; leftover TOC entries must still get a uid so reaching
-- that chapter can start the next underline window.
local weread = {
    { chapterUid = "1", title = "第一章 开始" },
    { chapterUid = "2", title = "第二章 继续" },
    { chapterUid = "3", title = "第三章 发展" },
    { chapterUid = "4", title = "第四章 转折" },
    { chapterUid = "5", title = "第五章 高潮" },
    { chapterUid = "6", title = "第六章 后半" },
}
local toc = {
    { title = "第一章 开始", pos = 0, xpointer = "xp1" },
    { title = "第二章 继续", pos = 100, xpointer = "xp2" },
    { title = "第三章 发展", pos = 200, xpointer = "xp3" },
    { title = "第四章 转折", pos = 300, xpointer = "xp4" },
    { title = "第五章 高潮", pos = 400, xpointer = "xp5" },
    { title = "第6章 后半", pos = 500, xpointer = "xp6" },
}

local matched = TocMap.match(weread, toc)
assert_eq(matched["6"], 6, "chapter 6 leftover TOC should match")

local bounds = TocMap.bounds(weread, toc, matched)
assert_eq(TocMap.uidAtPos(bounds, 500), "6", "pos at chapter 6 maps to uid 6")
assert_eq(TocMap.uidAtPos(bounds, 450), "5", "pos in chapter 5 stays uid 5")

-- Exact titles still win; an unmatched intro must not steal 第二章.
local intro_weread = {
    { chapterUid = "0", title = "简介" },
    { chapterUid = "1", title = "第一章" },
    { chapterUid = "2", title = "第二章" },
}
local intro_toc = {
    { title = "第一章", pos = 0, xpointer = "a" },
    { title = "第二章", pos = 100, xpointer = "b" },
}
local intro_map = TocMap.match(intro_weread, intro_toc)
assert_eq(intro_map["1"], 1, "第一章 stays TOC 1")
assert_eq(intro_map["2"], 2, "第二章 stays TOC 2")
assert_eq(intro_map["0"], nil, "unmatched intro has no leftover TOC")

print("ok")
