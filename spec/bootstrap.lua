package.path = "./?.lua;./?/init.lua;./spec/?.lua;" .. package.path

-- KOReader provides socketutil and json at runtime. The CI test suite runs
-- outside KOReader, so provide small compatible shims for the APIs currently
-- used by lib/api.lua.
local ltn12 = require("ltn12")

package.loaded["socketutil"] = {
    set_timeout = function() end,
    reset_timeout = function() end,
    table_sink = function(target)
        return ltn12.sink.table(target)
    end,
}

package.loaded["json"] = require("dkjson")
