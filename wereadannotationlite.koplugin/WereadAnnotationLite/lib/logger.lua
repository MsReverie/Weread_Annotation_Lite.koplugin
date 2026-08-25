local ok, base_logger = pcall(require, "logger")
if not ok then
    base_logger = nil
end

local LEVELS = { "dbg", "info", "warn", "err" }
local debug_enabled = false

local function build(prefix)
    local wrapped = {}
    for _, level in ipairs(LEVELS) do
        local method = level
        wrapped[method] = function(...)
            if base_logger and type(base_logger[method]) == "function" then
                base_logger[method](prefix, ...)
            end
        end
    end

    wrapped.debug = function(...)
        if debug_enabled and base_logger and type(base_logger.info) == "function" then
            base_logger.info(prefix, ...)
        end
    end
    return wrapped
end

local Logger = build("[WeRead]")

function Logger.setDebug(enabled)
    debug_enabled = enabled == true
end

function Logger.isDebug()
    return debug_enabled
end

function Logger.scoped(scope)
    assert(type(scope) == "string" and scope ~= "", "logger scope is required")
    return build("[WeRead][" .. scope .. "]")
end

return Logger
