local LuaSettings = require("luasettings")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")

local Settings = {}
Settings.__index = Settings

local function drop_web_session(file)
    local stale = false
    for _, key in ipairs({ "cookies", "wr_ticket", "wr_wrpa" }) do
        if file:readSetting(key) ~= nil then
            file:delSetting(key)
            stale = true
        end
    end
    return stale
end

function Settings:new()
    local obj = setmetatable({}, self)
    obj.data_dir = DataStorage:getFullDataDir() .. "/wereadannotationlite"
    obj.file = LuaSettings:open(
        DataStorage:getSettingsDir() .. "/wereadannotationlite.lua"
    )
    if obj.file:readSetting("api_key", "") == "" then
        local legacy = LuaSettings:open("wereadannotationlite")
        for _, key in ipairs({ "api_key", "account" }) do
            local value = legacy:readSetting(key)
            if value ~= nil then obj.file:saveSetting(key, value) end
        end
        if legacy.close then legacy:close() end
        obj.file:flush()
    end
    if drop_web_session(obj.file) then
        obj.file:flush()
    end
    if not lfs.attributes(obj.data_dir, "mode") then lfs.mkdir(obj.data_dir) end
    obj.values = {
        api_key = "",
        show_annotations = true,
        prefetch_thoughts = true,
        prefetch_notify = true,
        debug_log = false,
        prefetch_batch_size = 5,
        prefetch_batch_delay = 0.3,
        prefetch_underline_window = 5,
        prefetch_underline_cooldown = 30,
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
    values = values or {}
    if values.api_key ~= nil then
        self:set("api_key", values.api_key)
    end
    if values.account ~= nil then
        self:set("account", values.account)
    end
    drop_web_session(self.file)
    self:flush()
end

function Settings:flush()
    self.file:flush()
end

return Settings