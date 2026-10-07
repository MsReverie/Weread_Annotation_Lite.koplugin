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
package.loaded["ffi/blitbuffer"] = { COLOR_DARK_GRAY = 1 }
package.loaded["ui/size"] = { line = { thick = 2 } }
package.loaded.socketutil = {}
package.loaded.json = {
    encode = function(value) return value end,
    decode = function(value) return value end,
}

local Prefetch = require("lib.prefetch")
local Overlay = require("ui.overlay")
local API = require("lib.api")

local file = "/books/test.epub"
local saves = {}
local updates = {}
local mode = "with_thought"

local database = {
    getRanges = function(_, actual_file, uid)
        assert(actual_file == file, "thought lookup uses the current file")
        assert(uid == "chapter-1", "thought lookup uses the current chapter")
        return { "r1", "r2" }
    end,
    saveThoughts = function(_, actual_file, uid, range, payload, fetched)
        saves[#saves + 1] = {
            file = actual_file,
            uid = uid,
            range = range,
            payload = payload,
            fetched = fetched,
        }
    end,
}

local plugin = {
    _reader_session = 1,
    database = database,
    api = {
        reviews = function(_, book_id, uid, batch)
            assert(book_id == "book-1", "reviews uses the bound book id")
            assert(uid == "chapter-1", "reviews uses the chapter uid")
            assert(#batch == 2, "one batch contains both ranges")
            if mode == "with_thought" then
                return {
                    reviews = {
                        { range = "r1", items = { { content = "idea" } } },
                    },
                }
            end
            if mode == "partial" then
                return {
                    reviews = {
                        { range = "r1", pageReviews = { { review = { content = "idea" } } } },
                    },
                }
            end
            return { reviews = {} }
        end,
        parseReviewItems = function(_, review)
            return review.items
        end,
        hasThoughtContent = function(items)
            return type(items) == "table" and #items > 0
        end,
        json_encode = function(items)
            return items
        end,
        is_login_expired = function() return false end,
        is_skill_upgrade_required = function() return false end,
    },
    settings = {
        get = function(_, key, default)
            if key == "prefetch_thoughts" then return true end
            if key == "prefetch_batch_size" then return 5 end
            return default
        end,
    },
    _local_annotation_overlay = {
        updateThought = function(_, uid, range, items)
            updates[#updates + 1] = { uid = uid, range = range, items = items }
        end,
    },
}

local prefetch = Prefetch:new(plugin)
prefetch:startThoughts(file, { book_id = "book-1" },
    { { chapterUid = "chapter-1" } }, prefetch.gen)
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end

assert(#saves == 1, "only the range with a thought is saved")
assert(saves[1].range == "r1" and saves[1].fetched == true,
    "range with a thought is marked fetched")
assert(#updates == 1 and updates[1].range == "r1", "thought result updates the overlay")
assert(prefetch.job == nil, "successful thought prefetch finishes")

-- An empty reviews response is a successful negative result, so it must not retry.
saves = {}
updates = {}
mode = "empty"

local empty_prefetch = Prefetch:new(plugin)
empty_prefetch:startThoughts(file, { book_id = "book-1" },
    { { chapterUid = "chapter-1" } }, empty_prefetch.gen)
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end

assert(#saves == 0, "empty reviews response saves nothing")
assert(empty_prefetch.job == nil, "empty reviews response completes without retry")

-- A range missing from the response stays fetched=0 and its underline stays
-- displayed. The response uses the documented readreviews shape.
saves = {}
mode = "partial"
plugin.api.parseReviewItems = API.parseReviewItems
local overlay = Overlay:new({ records = {
    { chapter_uid = "chapter-1", range = "r1", pos0 = "1", pos1 = "1", fetched = 0, items = {} },
    { chapter_uid = "chapter-1", range = "r2", pos0 = "2", pos1 = "2", fetched = 0, items = {} },
} })
overlay.ui = { dimen = { h = 100 }, document = {
    getCurrentPos = function() return 0 end,
    getVisiblePageCount = function() return 1 end,
    getPosFromXPointer = function(_, xp) return tonumber(xp) end,
    getScreenBoxesFromPositions = function() return { { x = 0, y = 0, w = 1, h = 1 } } end,
} }
overlay.view = {}
plugin._local_annotation_overlay = overlay

local partial_prefetch = Prefetch:new(plugin)
partial_prefetch:startThoughts(file, { book_id = "book-1" },
    { { chapterUid = "chapter-1" } }, partial_prefetch.gen)
while #scheduled > 0 do
    local callback = table.remove(scheduled, 1)
    callback()
end

assert(#saves == 1 and saves[1].range == "r1", "range with a thought is saved")
assert(overlay.records[2].range == "r2" and overlay.records[2].fetched == 0,
    "missing range is not marked fetched")
assert(#overlay:_computeVisible() == 2, "missing range stays displayed")

print("ok")
