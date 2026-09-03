package.path = "./?.lua;./?/init.lua;" .. package.path

local Locator = require("lib.locator")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then error(msg or "assert_true", 2) end
end

local single = { start = "xp1", ["end"] = "xp2" }
assert_eq(#Locator.normalize_hits(single), 1, "single result wrapped in array")
assert_eq(Locator.normalize_hits(single)[1], single, "same reference")

local arr = {
    { start = "a", ["end"] = "b" },
    { start = "c", ["end"] = "d" },
}
assert_eq(#Locator.normalize_hits(arr), 2, "array passes through")
assert_eq(#Locator.normalize_hits(nil), 0, "nil → empty")

local mixed = {
    { start = "a", ["end"] = "b" },
    { start = "c" },
    { ["end"] = "d" },
    "not a table",
}
local filtered = Locator.normalize_hits(mixed)
assert_eq(#filtered, 1, "only valid items kept")

local rows = {
    { range = "100:200" },
    { range = "10:20" },
    { range = "50:60" },
}
local sorted = Locator.sortedRows(rows)
assert_eq(sorted[1].range, "10:20", "sorted by range start ascending")
assert_eq(sorted[2].range, "50:60", "")
assert_eq(sorted[3].range, "100:200", "")
assert_eq(#Locator.sortedRows(nil), 0, "nil → empty")

local function make_doc(results)
    return {
        getPosFromXPointer = function(_, xp)
            return results[xp] or nil
        end,
    }
end

local doc = make_doc({
    xp_a = 100,
    xp_b = 200,
    xp_c = 300,
    xp_d = 400,
})
local results = {
    { start = "xp_a", ["end"] = "x1" },
    { start = "xp_b", ["end"] = "x2" },
    { start = "xp_c", ["end"] = "x3" },
    { start = "xp_d", ["end"] = "x4" },
}
local picked, pos = Locator.choose_after(doc, results, 150)
assert_eq(picked.start, "xp_b", "choose_after picks next after cursor")
assert_eq(pos, 200, "position is 200")
picked, pos = Locator.choose_after(doc, results, 0, { start_pos = 250, end_pos = 350 })
assert_eq(picked.start, "xp_c", "bounds lo=250 skips xp_b")
picked, pos = Locator.choose_after(nil, results, 0)
assert_eq(picked, nil, "nil doc → nil")

local goto_count = 0
local find_text_count = 0
local find_all_count = 0
local search_doc = {
    findText = function()
        find_text_count = find_text_count + 1
        return {}
    end,
    findAllText = function(_, pattern)
        find_all_count = find_all_count + 1
        if pattern == "later in the chapter" then
            return {
                { start = "xp-early", ["end"] = "xp-early-end" },
                { start = "xp-far", ["end"] = "xp-far-end" },
            }
        end
        return {}
    end,
    gotoXPointer = function()
        goto_count = goto_count + 1
    end,
    getXPointer = function() return "xp-reader" end,
    getPosFromXPointer = function(_, xp)
        local at = { ["xp-early"] = 10, ["xp-far"] = 8000, ["xp-reader"] = 100 }
        return at[xp]
    end,
    clearSelection = function() end,
}

local bounds = { start_pos = 100, end_pos = 9000, start_xp = "xp-ch" }
local rec, cursor = Locator.locateOne(search_doc, "3", {
    markText = "later in the chapter",
    range = "10-20",
}, -math.huge, bounds)

assert_eq(find_text_count, 0, "must not use findText")
assert_true(find_all_count > 0, "must search with findAllText")
assert_eq(goto_count, 0, "must not gotoXPointer to search")
assert_true(rec ~= nil, "far hit inside chapter bounds must locate")
assert_eq(rec.pos0, "xp-far", "skip the hit before chapter start")
assert_eq(cursor, 8000)

print("ok")
