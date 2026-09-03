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
    encode = function(value) return value end,
    decode = function(value) return value end,
}

local Prefetch = require("lib.prefetch")

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

assert(#saves == 2, "successful review response records both ranges")
assert(saves[1].range == "r1" and saves[1].fetched == true,
    "range with a thought is marked fetched")
assert(saves[2].range == "r2" and saves[2].fetched == true,
    "range without a thought is also marked fetched")
assert(#updates == 2, "both ranges update the overlay")
assert(updates[1].range == "r1", "thought result updates the overlay")
assert(updates[2].range == "r2" and #(updates[2].items or {}) == 0,
    "empty thought marks the overlay fetched so shouldDisplay can hide it")
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

assert(#saves == 2, "empty reviews response records both ranges")
assert(saves[1].fetched == true and saves[2].fetched == true,
    "empty reviews response is cached as fetched")
assert(empty_prefetch.job == nil, "empty reviews response completes without retry")

print("ok")
