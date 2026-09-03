package.path = "./?.lua;./?/init.lua;./spec/?.lua;" .. package.path

package.loaded["ffi/blitbuffer"] = { COLOR_DARK_GRAY = 1 }
package.loaded["ui/size"] = { line = { thick = 2 } }

local Overlay = require("ui.overlay")

local document = {
    getCurrentPos = function() return 0 end,
    getVisiblePageCount = function() return 1 end,
    getCurrentPage = function() return 0 end,
    getPosFromXPointer = function(_, xp)
        return tonumber(xp:match("%d+")) or 0
    end,
    getScreenBoxesFromPositions = function(_, pos0)
        local y = (tonumber(pos0) or 0) * 5
        return { { x = 1, y = y, w = 10, h = 8 } }
    end,
}

local overlay = Overlay:new({ records = {
    { chapter_uid = "1", range = "r0", pos0 = "0", pos1 = "1", fetched = 0, items = {} },
    { chapter_uid = "1", range = "r1", pos0 = "10", pos1 = "11", fetched = 1, items = {} },
    { chapter_uid = "1", range = "r2", pos0 = "20", pos1 = "21", fetched = 1,
        items = { { content = "thought" } } },
} })
overlay.ui = { document = document, dimen = { h = 100 } }
overlay.view = { view_mode = "scroll", drawHighlightRect = function() end }

local visible = overlay:_computeVisible()
assert(#visible == 2, "unfetched and thoughtful records are visible")
assert(visible[1].record.range == "r0", "unfetched underline remains visible")
assert(visible[2].record.range == "r2", "underline with thought remains visible")

local before = overlay.generation
overlay:updateThought("1", "r1", { { content = "now has a thought" } })
assert(overlay.generation > before, "thought update invalidates visibility cache")

visible = overlay:_computeVisible()
assert(#visible == 3, "record becomes visible after thought fetch")

overlay:updateThought("1", "r2", {})
visible = overlay:_computeVisible()
assert(#visible == 2, "fetched empty thought record becomes hidden")

-- PageUpdate clears the last paint's hit list. Tap must still resolve.
overlay.visible = {}
local hit = overlay:hitTest({ x = 5, y = 5 })
assert(hit and hit.range == "r0", "hitTest rebuilds visible after PageUpdate wipe")

print("ok")
