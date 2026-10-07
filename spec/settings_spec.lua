package.path = "./?.lua;./?/init.lua;" .. package.path

local DATA = "/koreader"
local modes = {}

package.loaded["libs/libkoreader-lfs"] = {
    attributes = function(path, key)
        assert(key == "mode")
        return modes[path]
    end,
    mkdir = function(path)
        if modes[path] then return nil, "File exists" end
        modes[path] = "directory"
        return true
    end,
}
package.loaded.datastorage = {
    getFullDataDir = function() return DATA end,
    getSettingsDir = function() return DATA .. "/settings" end,
}
package.loaded.luasettings = {
    open = function()
        local data = {}
        return {
            readSetting = function(_, key, default)
                if data[key] == nil then return default end
                return data[key]
            end,
            saveSetting = function(_, key, value) data[key] = value end,
            delSetting = function(_, key) data[key] = nil end,
            flush = function() end,
        }
    end,
}
local real_remove = os.remove
os.remove = function(path)
    if modes[path] == "file" then modes[path] = nil; return true end
    return real_remove(path)
end

local Settings = require("settings")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

-- A stray file at the data dir path is replaced by a directory.
modes[DATA .. "/wereadannotationlite"] = "file"
local settings = Settings:new()
assert_eq(modes[settings:get("data_dir")], "directory", "data_dir becomes a directory")

os.remove = real_remove
print("settings_spec: ok")
