local logger = require("logger")

local LEVELS = { "info", "warn", "err" }
local debug_enabled = false

local function build(prefix)
    local wrapped = {}
    for _, level in ipairs(LEVELS) do
        wrapped[level] = function(...)
            logger[level](prefix, ...)
        end
    end
    wrapped.debug = function(...)
        if debug_enabled then
            logger.info(prefix, ...)
        end
    end
    return wrapped
end

local Logger = build("[wereadannotationlite]")

function Logger.setDebug(enabled)
    debug_enabled = enabled == true
end

function Logger.isDebug()
    return debug_enabled
end

function Logger.scoped(scope)
    return build("[wereadannotationlite][" .. scope .. "]")
end

return Logger
