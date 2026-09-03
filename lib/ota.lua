--[[--
Plugin OTA, following omer-faruq/assistant.koplugin:
GitHub latest release, dismissable download, non-dismissable install,
Archiver extract, backup in a temp ota dir, UIManager:askForRestart.

@module lib.ota
--]]

local M = {}

M.REPO = "MsReverie/Weread_Annotation_Lite.koplugin"
M.API_URL = "https://api.github.com/repos/" .. M.REPO .. "/releases/latest"
M.USER_AGENT = "KOReader-WereadAnnotationLite-Updater/1.0"
M.PLUGIN_DIRNAME = "wereadannotationlite.koplugin"
M.MAX_PACKAGE_BYTES = 10 * 1024 * 1024

function M.is_version_newer(v1_str, v2_str)
    if not v1_str or not v2_str then return false end

    local function parse_version(v_str)
        v_str = tostring(v_str):gsub("^v", "")
        local parts, pre_parts = {}, {}
        local main_part = v_str
        local pre_start = v_str:find("-")
        if pre_start then
            main_part = v_str:sub(1, pre_start - 1)
            for part in v_str:sub(pre_start + 1):gmatch("([^.]+)") do
                if part:match("^[0-9]+$") then
                    pre_parts[#pre_parts + 1] = tonumber(part)
                else
                    pre_parts[#pre_parts + 1] = part
                end
            end
        end
        for part in main_part:gmatch("%d+") do
            parts[#parts + 1] = tonumber(part)
        end
        return parts, pre_parts
    end

    local parts1, pre1 = parse_version(v1_str)
    local parts2, pre2 = parse_version(v2_str)
    local max_len = math.max(#parts1, #parts2)
    for i = 1, max_len do
        local p1, p2 = parts1[i] or 0, parts2[i] or 0
        if p1 > p2 then return true end
        if p1 < p2 then return false end
    end
    local has_pre1, has_pre2 = #pre1 > 0, #pre2 > 0
    if has_pre1 and not has_pre2 then return false end
    if not has_pre1 and has_pre2 then return true end
    if not has_pre1 then return false end
    for i = 1, math.max(#pre1, #pre2) do
        local p1, p2 = pre1[i], pre2[i]
        if p1 == nil then return false end
        if p2 == nil then return true end
        local n1, n2 = type(p1) == "number", type(p2) == "number"
        if n1 and n2 then
            if p1 > p2 then return true elseif p1 < p2 then return false end
        elseif n1 then return false
        elseif n2 then return true
        else
            if p1 > p2 then return true elseif p1 < p2 then return false end
        end
    end
    return false
end

function M.normalize_zip_path(path)
    if not path or path == "" then return "" end
    local p = path:gsub("\\", "/")
    while p:sub(1, 2) == "./" do p = p:sub(3) end
    while p:sub(1, 1) == "/" do p = p:sub(2) end
    p = p:gsub("^Weread_Annotation_Lite%.koplugin[^/]*/", "")
    p = p:gsub("^wereadannotationlite%.koplugin[^/]*/", "")
    return p:gsub("/+$", "")
end

function M.is_excluded(path)
    local n = M.normalize_zip_path(path)
    if n == "" then return true end
    if n:find("/%.") or n:sub(1, 1) == "." then return true end
    if n:find("^spec/") or n:find("/spec/") then return true end
    if n:find("^%.github/") or n:find("%.github/") then return true end
    if n:match("%.md$") then return true end
    if n == "LICENSE" then return true end
    return false
end

function M.path_is_safe(path)
    local p = tostring(path or ""):gsub("\\", "/")
    if p == "" or p:sub(1, 1) == "/" then return false end
    if p:match("^%.%./") or p:match("/%.%./") or p:match("/%.%.$") then return false end
    return true
end

function M.read_meta_version(text)
    if type(text) ~= "string" then return nil end
    return text:match('version%s*=%s*"([^"]+)"')
        or text:match("version%s*=%s*'([^']+)'")
end

function M.current_version(meta_path)
    local file = io.open(meta_path, "r")
    if not file then return "unknown" end
    local text = file:read("*a")
    file:close()
    return M.read_meta_version(text) or "unknown"
end

local function zip_asset_for_version(name, version)
    if type(name) ~= "string" or not name:match("%.zip$") then return false end
    if not name:find("koplugin", 1, true) then return false end
    return name:find(version, 1, true) ~= nil or name:find("v" .. version, 1, true) ~= nil
end

function M.parse_release(data)
    if type(data) ~= "table" or data.draft == true or data.prerelease == true then
        return nil, "invalid release metadata"
    end
    local tag = data.tag_name
    if type(tag) ~= "string" or tag == "" then
        return nil, "invalid release tag"
    end
    local version = tag:match("^v?(.*)$")
    local archive_url, archive_size
    for _, asset in ipairs(data.assets or {}) do
        if zip_asset_for_version(asset.name, version) then
            archive_url = asset.browser_download_url
            archive_size = tonumber(asset.size)
            break
        end
    end
    if type(archive_url) ~= "string" or archive_url == "" then
        return nil, "release package is missing"
    end
    if archive_size and archive_size > M.MAX_PACKAGE_BYTES then
        return nil, "release package is too large"
    end
    return {
        tag = tag,
        version = version,
        archive_url = archive_url,
        archive_size = archive_size,
    }
end

function M.plugin_dir(plugin)
    if plugin and type(plugin.path) == "string" and plugin.path ~= "" then
        return plugin.path
    end
    local source = debug.getinfo(1, "S").source or ""
    local dir = source:match("^@?(.+)/lib/[^/]+$")
    if dir then return dir end
    local DataStorage = require("datastorage")
    return DataStorage:getFullDataDir() .. "/plugins/" .. M.PLUGIN_DIRNAME
end

local function join(ffiutil, ...)
    local result = select(1, ...)
    for i = 2, select("#", ...) do
        result = ffiutil.joinPath(result, select(i, ...))
    end
    return result
end

function M.cleanup_backup(plugin)
    local dir = M.plugin_dir(plugin)
    if not dir then return end
    local leftover = dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and not lfs.attributes(leftover, "mode") then
        return
    end
    local ffiutil = require("ffi/util")
    pcall(ffiutil.purgeDir, leftover)
end

local function http_get(url, destination)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink, chunks
    if destination then
        local file_handle = io.open(destination, "wb")
        if not file_handle then return nil, "Could not create temp file" end
        sink = ltn12.sink.file(file_handle)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        chunks = {}
        sink = ltn12.sink.table(chunks)
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local status_code, headers, status_line = socket.skip(1, http.request{
        url = url,
        method = "GET",
        headers = {
            ["User-Agent"] = M.USER_AGENT,
            ["Accept"] = "application/vnd.github+json",
        },
        sink = sink,
        redirect = true,
    })
    socketutil:reset_timeout()
    if destination then
        -- ltn12.sink.file closes on EOF; ignore double-close.
    end
    if status_code ~= 200 then
        if destination then pcall(os.remove, destination) end
        return nil, "HTTP " .. tostring(status_code or status_line or "error")
    end
    if destination then
        local lfs = require("libs/libkoreader-lfs")
        local size = lfs.attributes(destination, "size")
        if not size or size == 0 then
            pcall(os.remove, destination)
            return nil, "Download failed: empty file"
        end
        if size > M.MAX_PACKAGE_BYTES then
            pcall(os.remove, destination)
            return nil, "release package is too large"
        end
        return true
    end
    return table.concat(chunks)
end

function M.fetch_release()
    local body, err = http_get(M.API_URL)
    if not body then return nil, err end
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "JSON support unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "invalid GitHub response" end
    return M.parse_release(data)
end

local function find_extracted_plugin(stage)
    local lfs = require("libs/libkoreader-lfs")
    local util = require("util")
    if util.pathExists(stage .. "/main.lua") then
        return stage
    end
    for name in lfs.dir(stage) do
        if name ~= "." and name ~= ".." then
            local candidate = stage .. "/" .. name
            if lfs.attributes(candidate, "mode") == "directory"
                and util.pathExists(candidate .. "/main.lua") then
                return candidate
            end
        end
    end
    return nil
end


function M.apply_release(plugin, zip_path, tmp)
    local FFIUtil = require("ffi/util")
    local util = require("util")
    local Archiver = require("ffi/archiver")
    local target = M.plugin_dir(plugin)
    if not target then return nil, "plugin directory unavailable" end

    local bak = join(FFIUtil, tmp, "backup", M.PLUGIN_DIRNAME)
    local extract_root = join(FFIUtil, tmp, "extract")
    util.makePath(extract_root)
    local arc = Archiver.Reader:new()
    if not arc:open(zip_path) then
        arc:close()
        return nil, "Failed to open archive"
    end
    for entry in arc:iterate() do
        if M.path_is_safe(entry.path) and not M.is_excluded(entry.path) then
            local rel = M.normalize_zip_path(entry.path)
            if rel ~= "" then
                local dest = join(FFIUtil, extract_root, rel)
                local parent = dest:match("(.+)/[^/]+$")
                if parent and not util.pathExists(parent) then
                    util.makePath(parent)
                end
                if not arc:extractToPath(entry.path, dest) then
                    arc:close()
                    return nil, "Failed to extract: " .. tostring(entry.path)
                end
            end
        elseif not M.path_is_safe(entry.path) then
            arc:close()
            return nil, "unsafe path in release archive"
        end
    end
    arc:close()

    local staged = find_extracted_plugin(extract_root)
    if not staged then
        return nil, "Could not find extracted plugin directory"
    end

    if util.pathExists(target) then
        if util.pathExists(bak) then FFIUtil.purgeDir(bak) end
        local moved, move_err = os.rename(target, bak)
        if not moved then
            return nil, "Failed to backup existing plugin: " .. tostring(move_err)
        end
    end
    local installed, install_err = os.rename(staged, target)
    if not installed then
        os.rename(bak, target)
        return nil, "Failed to install plugin: " .. tostring(install_err)
    end
    return true
end

function M.check(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local Notification = require("ui/widget/notification")
    local Trapper = require("ui/trapper")
    local _ = require("lib.i18n")
    local T = require("ffi/util").template

    if plugin and plugin.whenOnline and plugin:whenOnline(function()
        M.check(plugin)
    end) then
        return
    end

    Trapper:wrap(function()
        local installed = M.current_version(M.plugin_dir(plugin) .. "/_meta.lua")
        local msg = InfoMessage:new { text = _("Checking for updates…"), timeout = 120 }
        UIManager:show(msg)
        local completed, result = Trapper:dismissableRunInSubprocess(function()
            local release, err = M.fetch_release()
            return { release = release, error = err }
        end, msg)
        UIManager:close(msg)
        if not completed then
            Notification:notify(_("OTA update canceled."), Notification.SOURCE_ALWAYS_SHOW)
            return
        end
        if not result or not result.release then
            UIManager:show(InfoMessage:new {
                text = T(_("OTA update failed: %1"), result and result.error or _("Unknown error")),
            })
            return
        end
        local release = result.release
        if not M.is_version_newer(release.version, installed) then
            UIManager:show(InfoMessage:new {
                text = T(_("Already up to date (v%1)."), installed),
                timeout = 3,
            })
            return
        end
        UIManager:show(ConfirmBox:new {
            text = T(_("A new version of the plugin (%1) is available. Please update!"),
                release.tag),
            ok_text = _("Install"),
            cancel_text = _("Later"),
            ok_callback = function()
                M.install(plugin, release)
            end,
        })
    end)
end

function M.install(plugin, release)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local Notification = require("ui/widget/notification")
    local Trapper = require("ui/trapper")
    local FFIUtil = require("ffi/util")
    local util = require("util")
    local DataStorage = require("datastorage")
    local _ = require("lib.i18n")
    local T = FFIUtil.template

    Trapper:wrap(function()
        local tmp = join(FFIUtil, DataStorage:getFullDataDir(), "ota", M.PLUGIN_DIRNAME .. ".update")
        local zip_path = join(FFIUtil, tmp, "update.zip")
        FFIUtil.purgeDir(tmp)
        util.makePath(join(FFIUtil, tmp, "backup"))

        local download_msg = InfoMessage:new { text = _("Downloading…"), timeout = 120 }
        UIManager:show(download_msg)
        local completed, dl_ok, dl_err = Trapper:dismissableRunInSubprocess(function()
            return http_get(release.archive_url, zip_path)
        end, download_msg)
        UIManager:close(download_msg)
        if not completed then
            FFIUtil.purgeDir(tmp)
            Notification:notify(_("OTA update canceled."), Notification.SOURCE_ALWAYS_SHOW)
            return
        end
        if not dl_ok then
            FFIUtil.purgeDir(tmp)
            UIManager:show(InfoMessage:new {
                text = T(_("OTA update failed: %1"), tostring(dl_err)),
            })
            return
        end

        local extract_msg = InfoMessage:new { text = _("Installing…") }
        UIManager:show(extract_msg)
        UIManager:forceRePaint()
        local pcall_ok, ret = pcall(function()
            local ok, err = M.apply_release(plugin, zip_path, tmp)
            return { success = ok == true, error = err }
        end)
        UIManager:close(extract_msg)
        if not pcall_ok then
            FFIUtil.purgeDir(tmp)
            UIManager:show(InfoMessage:new {
                text = T(_("OTA update failed: %1"), tostring(ret)),
            })
            return
        end
        if not ret or not ret.success then
            FFIUtil.purgeDir(tmp)
            UIManager:show(InfoMessage:new {
                text = T(_("OTA update failed: %1"), tostring(ret and ret.error)),
            })
            return
        end
        FFIUtil.purgeDir(tmp)
        Notification:notify(_("OTA update OK. Restart is required."), Notification.SOURCE_ALWAYS_SHOW)
        UIManager:askForRestart()
    end)
end

return M
