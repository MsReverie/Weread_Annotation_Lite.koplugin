local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings

function Settings:new()
    local obj = setmetatable({}, self)
    obj.data_dir = DataStorage:getFullDataDir() .. "/WereadAnnotationLite"
    obj.file = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/wereadannotationlite.lua"
    )
    if obj.file:readSetting("api_key", "") == "" then
        local legacy = LuaSettings:open("wereadannotationlite")
        for _, key in ipairs({ "api_key", "cookies", "wr_ticket", "wr_wrpa", "account" }) do
            local value = legacy:readSetting(key)
            if value ~= nil then obj.file:saveSetting(key, value) end
        end
        obj.file:flush()
    end
    if not lfs.attributes(obj.data_dir, "mode") then lfs.mkdir(obj.data_dir) end
    obj.values = {
        api_key = "",
        cookies = {},
        show_annotations = true,
        prefetch_thoughts = true,
        prefetch_notify = false,
        debug_log = false,
        prefetch_batch_size = 5,
        prefetch_batch_delay = 0.3,
        sync_concurrency = 4,    
        sync_base_interval = 0.2,
        sync_jitter_max = 0.3,  
    }
    return obj
end

function Settings:get(key, default)
    if key == "data_dir" then return self.data_dir end
    local value = self.file:readSetting(key)
    if value == nil then value = self.values[key] end
    if value == nil then value = default end
    return value
end

function Settings:set(key, value)
    self.file:saveSetting(key, value)
end

function Settings:update_auth(values)
    for key, value in pairs(values or {}) do
        self:set(key, value)
    end
    self:flush()
end

function Settings:flush()
    self.file:flush()
end

return Settings
