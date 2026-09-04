package.path = "./?.lua;./?/init.lua;" .. package.path

local TocMap = require("lib.toc_map")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

-- ── normalize ───────────────────────────────────────────────────────────────

assert_eq(TocMap.normalize("  第一章 开始  "), "第一章开始", "normalize trims whitespace")
assert_eq(TocMap.normalize("第(一)章"), "第一章", "normalize strips parens")
assert_eq(TocMap.normalize(" chapter-1 "), "chapter-1", "normalize preserves hyphens")
assert_eq(TocMap.normalize("《序》"), "序", "normalize strips 《》")
assert_eq(TocMap.normalize(nil), "", "normalize nil returns empty string")
assert_eq(TocMap.normalize(""), "", "normalize empty returns empty")

-- ── match – exact ───────────────────────────────────────────────────────────

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
    { title = "第六章 后半", pos = 500, xpointer = "xp6" },
}

local matched = TocMap.match(weread, toc)
assert_eq(matched["1"], 1, "chapter 1 exact match")
assert_eq(matched["6"], 6, "chapter 6 exact match")

-- ── match – exact wins over related ─────────────────────────────────────────

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
assert_eq(intro_map["1"], 1, "exact: 第一章 stays TOC 1")
assert_eq(intro_map["2"], 2, "exact: 第二章 stays TOC 2")
assert_eq(intro_map["0"], nil, "unmatched intro has no TOC entry")

-- ── match – Chinese numeral vs Arabic numeral ───────────────────────────────
-- Numeric chapter forms are normalized by the matcher, not by TocMap.normalize.
local cn_weread = {
    { chapterUid = "a", title = "第一章" },
    { chapterUid = "b", title = "第2章" },
    { chapterUid = "c", title = "第三章" },
}
local num_toc = {
    { title = "第1章", pos = 0, xpointer = "xp1" },
    { title = "第二章", pos = 100, xpointer = "xp2" },
    { title = "第3章", pos = 200, xpointer = "xp3" },
}
local num_map = TocMap.match(cn_weread, num_toc)
assert_eq(num_map["a"], 1, "第一章 matches 第1章")
assert_eq(num_map["b"], 2, "第2章 matches 第二章")
assert_eq(num_map["c"], 3, "第三章 matches 第3章")

-- ── match – unmatched chapter must not consume the next TOC ─────────────────

local gap_weread = {
    { chapterUid = "a", title = "第一章" },
    { chapterUid = "x", title = "神秘章节" },
    { chapterUid = "b", title = "第二章" },
}
local gap_toc = {
    { title = "第一章", pos = 0, xpointer = "xp1" },
    { title = "附录说明", pos = 50, xpointer = "extra" },
    { title = "第二章", pos = 100, xpointer = "xp2" },
}
local gap_map = TocMap.match(gap_weread, gap_toc)
assert_eq(gap_map["a"], 1, "gap: first chapter matched")
assert_eq(gap_map["x"], nil, "gap: unknown chapter remains unmatched")
assert_eq(gap_map["b"], 3, "gap: later known chapter still matches")
local gap_bounds = TocMap.bounds(gap_weread, gap_toc, gap_map)
assert_eq(gap_bounds["x"].start_pos, 50, "unmatched hole starts at next TOC after left anchor")
assert_eq(gap_bounds["x"].end_pos, 100, "unmatched hole ends at right anchor")
assert_eq(gap_bounds["x"].start_xp, "extra", "unmatched hole can search from the in-between TOC")

-- ── match – unrelated titles must remain unmatched ──────────────────────────

local unrelated_map = TocMap.match({
    { chapterUid = "x", title = "黑暗降临在冬夜" },
}, {
    { title = "作者后记", pos = 0, xpointer = "xp" },
})
assert_eq(unrelated_map["x"], nil, "unrelated titles do not fallback-match")

-- ── match – empty / nil inputs ──────────────────────────────────────────────

assert_eq(#TocMap.match({}, toc), 0, "match empty weread returns empty")
assert_eq(#TocMap.match(weread, {}), 0, "match empty toc returns empty")
assert_eq(#TocMap.match(nil, toc), 0, "match nil weread returns empty")
assert_eq(#TocMap.match(weread, nil), 0, "match nil toc returns empty")

-- ── match – duplicate chapter UIDs are deduped ──────────────────────────────

local dup_weread = {
    { chapterUid = "1", title = "第一章" },
    { chapterUid = "1", title = "第一章 dup" },
    { chapterUid = "2", title = "第二章" },
}
local dup_map = TocMap.match(dup_weread, {
    { title = "第一章", pos = 0, xpointer = "xp1" },
    { title = "第二章", pos = 100, xpointer = "xp2" },
})
assert_eq(dup_map["1"], 1, "first dup uid maps to first toc")
assert_eq(dup_map["2"], 2, "second uid maps correctly")

-- ── match – skip empty titles / uids ────────────────────────────────────────

local messy_weread = {
    { chapterUid = "", title = "第一章" },
    { chapterUid = "2", title = "" },
    { chapterUid = "3", title = "第三章" },
}
local messy_map = TocMap.match(messy_weread, {
    { title = "第三章", pos = 200, xpointer = "xp3" },
})
assert_eq(messy_map["3"], 1, "only valid chapter matched")

-- ── bounds ──────────────────────────────────────────────────────────────────

local bounds = TocMap.bounds(weread, toc, matched)
assert_eq(bounds["1"].start_pos, 0,   "chapter 1 starts at 0")
assert_eq(bounds["1"].end_pos,  100,  "chapter 1 ends at chapter 2 start")
assert_eq(bounds["6"].start_pos, 500, "chapter 6 starts at 500")
assert_eq(bounds["6"].end_pos,  math.huge, "last chapter ends at infinity")
assert_eq(bounds["1"].start_xp, "xp1", "start_xp preserved")
assert_eq(bounds["999"], nil, "unmatched uid has no bounds")

-- ── uidAtPos ────────────────────────────────────────────────────────────────

assert_eq(TocMap.uidAtPos(bounds, 0),    "1", "pos 0 → chapter 1")
assert_eq(TocMap.uidAtPos(bounds, 50),   "1", "pos inside ch1 → chapter 1")
assert_eq(TocMap.uidAtPos(bounds, 100),  "2", "pos at boundary → chapter 2")
assert_eq(TocMap.uidAtPos(bounds, 500),  "6", "pos at ch6 start → chapter 6")
assert_eq(TocMap.uidAtPos(bounds, 9999), "6", "pos beyond last chapter → last")
assert_eq(TocMap.uidAtPos(bounds, -1),   nil, "negative pos → nil")
assert_eq(TocMap.uidAtPos({}, 0),        nil, "empty bounds → nil")
assert_eq(TocMap.uidAtPos(nil, 0),       nil, "nil bounds → nil")

-- ── TocMapInstance cache lifecycle ──────────────────────────────────────────

local function make_plugin(chapters, toc_data, current_pos)
    return {
        ui = {
            document = {
                file   = "/books/test.epub",
                getToc = function() return toc_data end,
                getCurrentPos = function() return current_pos or 0 end,
                getPosFromXPointer = function(_, xp)
                    for _, item in ipairs(toc_data or {}) do
                        if item.xpointer == xp then return item.pos end
                    end
                    return 0
                end,
            },
        },
        database = {
            listChapters = function() return chapters end,
        },
    }
end

local inst = TocMap.newInstance(make_plugin({
    { chapterUid = "1", title = "Ch1" },
    { chapterUid = "2", title = "Ch2" },
}, {
    { title = "Ch1", pos = 0, xpointer = "xp1" },
    { title = "Ch2", pos = 100, xpointer = "xp2" },
}, 50))

local map1 = inst:ensure()
assert_eq(map1.bounds["1"].start_pos, 0, "ensure builds map from toc")
assert_eq(map1.bounds["2"].start_pos, 100, "bounds computed correctly")

local map2 = inst:ensure()
assert_eq(map2, map1, "ensure returns cached map on second call")
assert_eq(inst:currentWereadChapterUid(), "1", "pos 50 → chapter 1")

local b = inst:getChapterBounds("2")
assert_eq(b.start_pos, 100, "getChapterBounds returns cached bounds")

inst:clearCache()
assert_eq(inst._toc_map, nil, "clearCache empties _toc_map")
assert_eq(inst._chapter_list, nil, "clearCache empties _chapter_list")

local map3 = inst:ensure()
assert_eq(map3 ~= map1, true, "ensure rebuilds a new cache after clearCache")
assert_eq(map3.bounds["1"].start_pos, 0, "rebuilt cache preserves chapter 1")
assert_eq(map3.bounds["2"].start_pos, 100, "rebuilt cache preserves chapter 2")

inst:clearCache()
inst:clearCache()

local no_ui = TocMap.newInstance({ ui = nil })
assert_eq(no_ui:ensure(), nil, "no ui → ensure returns nil")

local empty_chapters = TocMap.newInstance(make_plugin({}, {
    { title = "Ch1", pos = 0, xpointer = "xp1" },
}, 0))
assert_eq(empty_chapters:ensure(), nil, "empty chapters → ensure returns nil")

local no_toc = TocMap.newInstance(make_plugin({
    { chapterUid = "1", title = "Ch1" },
}, nil, 0))
assert_eq(no_toc:ensure(), nil, "nil toc → ensure returns nil")

-- Page-mode: page-top Y can still sit in the previous chapter.
local page_toc = {
    { title = "第五章 高潮", pos = 400, page = 5, xpointer = "xp5" },
    { title = "第6章 后半", pos = 500, page = 6, xpointer = "xp6" },
}
local page_weread = {
    { chapterUid = "5", title = "第五章 高潮" },
    { chapterUid = "6", title = "第六章 后半" },
}
local page_matched = TocMap.match(page_weread, page_toc)
local page_bounds = TocMap.bounds(page_weread, page_toc, page_matched)
assert_eq(TocMap.uidAtPos(page_bounds, 480), "5", "page-top Y still in chapter 5")
assert_eq(TocMap.indexAtPage(page_toc, 6), 2, "TOC page 6 is the second entry")
assert_eq(TocMap.uidAtTocIndex(page_matched, 2), "6", "TOC index maps to WeRead 6")

local doc = {
    compareXPointers = function(_, a, b)
        local order = { xp5 = 5, xp6 = 6 }
        local na, nb = order[a], order[b]
        if not na or not nb then return nil end
        if nb > na then return 1 end
        if nb < na then return -1 end
        return 0
    end,
}
assert_eq(TocMap.uidAtXPointer(page_weread, page_matched, page_toc, doc, "xp6"),
    "6", "xpointer at chapter 6 heading is uid 6")

assert_eq(TocMap.uidAtExactTocIndex(page_matched, 2), "6",
    "exact TOC index maps to the WeRead chapter aligned there")
assert_eq(TocMap.uidAtExactTocIndex(page_matched, 9), nil,
    "unaligned TOC index has no exact WeRead chapter")
assert_eq(TocMap.tocIndexAtXPointer(page_toc, doc, "xp6"), 2,
    "xpointer at chapter 6 heading is local TOC index 2")

-- TOC jump: WeRead order differs, so 第二章 is unmatched forward, but the
-- landed local heading still reverse-matches the cached WeRead title.
local jump_weread = {
    { chapterUid = "1", title = "第一章" },
    { chapterUid = "x", title = "插曲" },
    { chapterUid = "2", title = "第二章" },
}
local jump_toc = {
    { title = "第一章", pos = 0, page = 1, xpointer = "xp1" },
    { title = "第二章", pos = 100, page = 2, xpointer = "xp2" },
    { title = "插曲", pos = 200, page = 3, xpointer = "xp3" },
}
local jump_plugin = make_plugin(jump_weread, jump_toc, 100)
local jump = TocMap.newInstance(jump_plugin)
jump:setPageno(2)
assert_eq(jump:currentWereadChapterUid(), "2",
    "TOC jump to 第二章 uses cached WeRead uid even when forward match skipped it")

-- Subsection under a matched chapter stays on that chapter.
local sub_plugin = make_plugin({
    { chapterUid = "3", title = "第三章" },
    { chapterUid = "4", title = "第四章" },
}, {
    { title = "第三章", pos = 0, page = 1, xpointer = "xp3" },
    { title = "3.2 细节", pos = 50, page = 2, xpointer = "xp32" },
    { title = "第四章", pos = 100, page = 3, xpointer = "xp4" },
}, 50)
local sub = TocMap.newInstance(sub_plugin)
sub:setPageno(2)
assert_eq(sub:currentWereadChapterUid(), "3",
    "unmatched subsection stays on the previous WeRead chapter")

print("ok")
