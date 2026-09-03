package.path = "./?.lua;./?/init.lua;./spec/?.lua;" .. package.path

local gettext = setmetatable({ current_lang = "en" }, {
    __call = function(_, s) return s end,
})
package.loaded.gettext = gettext
package.loaded.logger = {
    info = function() end, warn = function() end, err = function() end,
    debug = function() end,
}

local scheduled = {}
package.loaded["ui/uimanager"] = {
    preventStandby = function() end,
    allowStandby = function() end,
    scheduleIn = function(_, _, fn)
        scheduled[#scheduled + 1] = fn
    end,
    setDirty = function() end,
}
package.loaded["ffi/util"] = {}
package.loaded.json = {
    encode = function() return "{}" end,
    decode = function() return {} end,
}

local locator_calls = {}
package.loaded["lib.locator"] = {
    sortedRows = function(rows)
        return rows or {}
    end,
    locateOne = function(_, chapter_uid, row)
        locator_calls[#locator_calls + 1] = row.range
        if row.range == "r2" then
            return nil
        end
        return {
            chapter_uid = chapter_uid,
            range = row.range,
            text = row.text,
            pos0 = "xp0-" .. row.range,
            pos1 = "xp1-" .. row.range,
        }, 0, nil
    end,
}

local Prefetch = require("lib.prefetch")
local current_file = "/books/test.epub"

-- ── Locate-row selection ─────────────────────────────────────────────────────
local pending = { "r1", "r3" }
local database = {
    getUnlocatedRanges = function(_, file, chapter_uid)
        assert(file == current_file, "uses current document file")
        assert(chapter_uid == "chapter-1", "passes chapter uid")
        return pending
    end,
}
local prefetch = Prefetch:new({
    ui = { document = { file = current_file } },
    database = database,
})

local rows = {
    { range = "r1", text = "one" },
    { range = "r2", text = "two" },
    { range = "r3", text = "three" },
}

local kept = prefetch:_prepareLocateRows("chapter-1", rows)
assert(#kept == 2, "only unattempted ranges remain")
assert(kept[1].range == "r1", "first pending range is kept")
assert(kept[2].range == "r3", "second pending range is kept")

pending = { "r1", "r2" }
kept = prefetch:_prepareLocateRows("chapter-1", rows)
assert(#kept == 2, "all unattempted ranges remain eligible")
assert(kept[1].range == "r1", "r1 remains eligible")
assert(kept[2].range == "r2", "r2 remains eligible")

-- ── Persistence helper ───────────────────────────────────────────────────────
local saved_records
local merged_records
prefetch.plugin._local_annotation_overlay = {
    mergeRecords = function(_, records) merged_records = records end,
}
prefetch.plugin.database.saveRecords = function(_, file, records)
    assert(file == current_file, "persist uses current document file")
    saved_records = records
end

local located = {
    { chapter_uid = "chapter-1", range = "r1", text = "one", pos0 = "xp0", pos1 = "xp1" },
}
prefetch:persistLocated(current_file, located)
assert(saved_records == located, "persistLocated saves located records")
assert(merged_records == located, "persistLocated refreshes overlay")

saved_records = nil
merged_records = nil
prefetch:persistLocated(current_file, {})
assert(saved_records == nil, "empty persist is a no-op")
assert(merged_records == nil, "empty persist does not refresh overlay")

-- ── Generation/session guard ─────────────────────────────────────────────────
local plugin = { _reader_session = 7 }
local guarded = Prefetch:new(plugin)
guarded.session = 7
assert(guarded:alive(guarded.gen), "current generation/session is alive")

local gen = guarded.gen
guarded:cancel()
assert(guarded.gen == gen + 1, "cancel invalidates generation")
assert(not guarded:alive(gen), "cancel invalidates previous generation")

plugin._reader_session = 8
assert(not guarded:alive(guarded.gen), "reader session change invalidates job")

-- ── Pause/resume state ───────────────────────────────────────────────────────
guarded.job = {}
guarded._standby_held = true
guarded:pause()
assert(guarded._paused == true, "pause marks job paused")
assert(guarded._standby_held == false, "pause releases standby")
guarded:resume()
assert(guarded._paused == false, "resume clears paused state")
assert(guarded._standby_held == true, "resume restores standby for active job")

-- ── ensureAhead scheduling/gating ────────────────────────────────────────────
local requested
local ahead_plugin = {
    _reader_session = 1,
    _thought_open = false,
    toc_map = { currentWereadChapterUid = function() return "chapter-9" end },
}
local ahead = Prefetch:new(ahead_plugin)
ahead.request = function(_, opts) requested = opts end
ahead:ensureAhead()
assert(#scheduled > 0, "ensureAhead schedules a delayed check")
local callback = table.remove(scheduled, 1)
callback()
assert(requested and requested.chapter_uid == "chapter-9", "ensureAhead requests current chapter")

requested = nil
ahead_plugin._thought_open = true
ahead:ensureAhead()
callback = table.remove(scheduled, 1)
callback()
assert(requested == nil, "open thought popup defers ensureAhead")
assert(ahead._followup == true, "open thought popup marks followup")

requested = nil
ahead_plugin._thought_open = false
ahead.underlines_done = true
local scheduled_n = #scheduled
ahead:ensureAhead()
assert(#scheduled == scheduled_n, "done underlines skip ensureAhead")
ahead.underlines_done = false

-- ── whole-book underline latch ───────────────────────────────────────────────
local latch_plugin = {
    settings = {
        get = function(_, key, default)
            if key == "show_annotations" or key == "prefetch_thoughts" then
                return true
            end
            return default
        end,
    },
    ui = { document = { file = current_file } },
    database = {
        getBinding = function() return { book_id = "book-1" } end,
        listChapters = function()
            return { { chapterUid = "1" }, { chapterUid = "2" } }
        end,
        cachedChapterSet = function()
            return { ["1"] = true, ["2"] = true }
        end,
    },
    api = { isOnline = function() return true end },
    toc_map = { currentWereadChapterUid = function() return "1" end },
}
local latched = Prefetch:new(latch_plugin)
latched:request({ chapter_uid = "1" })
assert(latched.underlines_done == true, "already-cached marks underlines done")

local plan_calls = 0
local orig_plan = Prefetch.planWindow
function Prefetch.planWindow(self, ...)
    plan_calls = plan_calls + 1
    return orig_plan(self, ...)
end
latched:request({ chapter_uid = "1" })
assert(plan_calls == 0, "done underlines skip later request")
latched.startUnderlines = function() end
latched:request({ force = true, chapter_uid = "1" })
Prefetch.planWindow = orig_plan
assert(latched.underlines_done == false, "force clears the underline latch")
assert(plan_calls == 1, "force still plans a window")

-- ── _bg fallback path ────────────────────────────────────────────────────────
local bg = Prefetch:new({ _reader_session = 1 })
local bg_result
bg:_bg(function() return "done" end, function(ok, result)
    bg_result = { ok = ok, result = result }
end)
assert(#scheduled > 0, "_bg fallback schedules callback")
callback = table.remove(scheduled, #scheduled)
callback()
assert(bg_result and bg_result.ok == true and bg_result.result == "done",
    "_bg fallback returns task result")

-- ── startUnderlines happy path + no-match path ───────────────────────────────
local cache_saved
local save_calls = 0
local ensure_calls = 0
local prune_calls = 0
local attempt_ranges = {}
local retained_ranges
local flow_database = {
    beginSession = function() end,
    endSession = function() end,
    getUnderlineCache = function() return nil end,
    ensureUnderlineRows = function(_, file, uid, items)
        ensure_calls = ensure_calls + 1
        assert(file == current_file, "ensure rows uses current file")
        assert(uid == "chapter-1", "ensure rows uses chapter uid")
        assert(#items == 2, "all underline items reach the database")
    end,
    getUnlocatedRanges = function()
        return { "r1", "r2" }
    end,
    markLocateAttempted = function(_, file, uid, range)
        assert(file == current_file, "locate attempt uses current file")
        assert(uid == "chapter-1", "locate attempt uses chapter uid")
        attempt_ranges[#attempt_ranges + 1] = range
    end,
    saveUnderlineCache = function(_, file, uid, synckey, items)
        assert(file == current_file, "underline cache uses current file")
        assert(uid == "chapter-1", "underline cache uses chapter uid")
        assert(synckey == 11, "underline cache preserves synckey")
        cache_saved = items
    end,
    pruneChapterRanges = function(_, file, uid, ranges)
        prune_calls = prune_calls + 1
        assert(file == current_file, "prune uses current file")
        assert(uid == "chapter-1", "prune uses chapter uid")
        assert(#ranges == 2 and ranges[1] == "r1" and ranges[2] == "r2",
            "prune keeps remote underline ranges")
    end,
    saveRecords = function(_, file, records)
        save_calls = save_calls + 1
        assert(file == current_file, "located records use current file")
        assert(#records == 1 and records[1].range == "r1",
            "only matched underline reaches persistence")
    end,
}

local overlay_updates = 0
local flow_plugin = {
    _reader_session = 1,
    ui = { document = { file = current_file } },
    database = flow_database,
    api = {
        isOnline = function() return true end,
        popular_underlines_sync = function()
            return {
                synckey = 11,
                items = {
                    { range = "r1", markText = "one" },
                    { range = "r2", markText = "two" },
                },
            }
        end,
        is_login_expired = function() return false end,
        is_skill_upgrade_required = function() return false end,
    },
    settings = {
        get = function(_, key, default)
            if key == "prefetch_thoughts" then return false end
            if key == "prefetch_notify" then return false end
            return default
        end,
    },
    toc_map = {
        getChapterBounds = function()
            return { start_pos = 0, end_pos = 1000, start_xp = "xp-ch" }
        end,
    },
    _local_annotation_overlay = {
        retainChapterRanges = function(_, uid, ranges)
            retained_ranges = { uid = uid, ranges = ranges }
        end,
        mergeRecords = function() overlay_updates = overlay_updates + 1 end,
    },
    showTransientInfo = function() end,
}

local flow = Prefetch:new(flow_plugin)
flow:startUnderlines(current_file, { book_id = "book-1" },
    { { chapterUid = "chapter-1", title = "Chapter 1" } }, flow.gen, false)

while #scheduled > 0 do
    callback = table.remove(scheduled, 1)
    callback()
end

assert(cache_saved and #cache_saved == 2, "underline API result is cached")
assert(ensure_calls == 1, "underline rows are ensured before locating")
assert(locator_calls[1] == "r1" and locator_calls[2] == "r2",
    "all unattempted ranges reach Locator")
assert(#attempt_ranges == 1 and attempt_ranges[1] == "r1",
    "only a successful locate is marked attempted")
assert(save_calls == 1, "only the matched underline is persisted")
assert(prune_calls == 1, "remote underline ranges are pruned once")
assert(retained_ranges and retained_ranges.uid == "chapter-1",
    "overlay retains remote chapter ranges")
assert(flow.job == nil, "successful underline job finishes")

print("ok")
