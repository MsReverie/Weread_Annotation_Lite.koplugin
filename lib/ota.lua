--[[--
OTA updates from GitHub Releases.

Pure helpers (version / asset / zip layout) have no KOReader requires so they
run under the bare Lua spec harness. Network, unzip, and UI are required lazily.

Release zips are expected to wrap files in a single top-level folder
(Weread_Annotation_Lite.koplugin/ or wereadannotationlite.koplugin/).
Installation copies that folder's contents onto the live plugin directory,
so login/settings/data outside the plugin tree are left alone.

@module lib.ota
--]]

local M = {}

M.REPO = "MsReverie/Weread_Annotation_Lite.koplugin"
M.API_LATEST = "https://api.github.com/repos/" .. M.REPO .. "/releases/latest"
M.RELEASES_PAGE = "https://github.com/" .. M.REPO .. "/releases"
M.USER_AGENT = "KOReader-WereadAnnotationLite"
M.MIN_ZIP_SIZE = 4096

function M.parseVersion(v)
    local parts = {}
    for part in tostring(v):gsub("^v", ""):gmatch("([^%.]+)") do
        parts[#parts + 1] = tonumber(part:match("^(%d+)")) or 0
    end
    return parts
end

function M.isNewer(candidate, installed)
    local a, b = M.parseVersion(candidate), M.parseVersion(installed)
    for i = 1, math.max(#a, #b) do
        local x, y = a[i] or 0, b[i] or 0
        if x > y then return true end
        if x < y then return false end
    end
    return false
end

function M.readMetaVersion(text)
    if type(text) ~= "string" then return nil end
    return text:match('version%s*=%s*"([^"]+)"')
        or text:match("version%s*=%s*'([^']+)'")
end

function M.getInstalledVersion(meta_path)
    meta_path = meta_path or (M.pluginPath() .. "/_meta.lua")
    local f = io.open(meta_path, "r")
    if not f then return "unknown" end
    local text = f:read("*a")
    f:close()
    return M.readMetaVersion(text) or "unknown"
end

function M.selectAsset(release)
    for _, asset in ipairs(release and release.assets or {}) do
        local name = asset.name or ""
        if name:match("%.zip$") and asset.browser_download_url then
            return asset.browser_download_url, name
        end
    end
    if release and release.zipball_url then
        return release.zipball_url, "source.zip"
    end
    return nil, nil
end

function M.releaseTag(release)
    if type(release) ~= "table" then return nil end
    local tag = release.tag_name or release.name
    if type(tag) ~= "string" or tag == "" then return nil end
    return tag
end

function M.pluginPath()
    local src = debug.getinfo(1, "S").source or ""
    if src:sub(1, 1) == "@" then
        src = src:sub(2)
    end
    local dir = src:match("(.+)/lib/ota%.lua$")
    if dir then return dir end
    local DataStorage = require("datastorage")
    return DataStorage:getDataDir() .. "/plugins/wereadannotationlite.koplugin"
end

function M.cacheDir()
    local DataStorage = require("datastorage")
    return DataStorage:getSettingsDir() .. "/wereadannotationlite_ota"
end

local function file_size(path)
    local lfs = require("libs/libkoreader-lfs")
    local attr = lfs.attributes(path)
    return (attr and attr.size) or 0
end

local function is_zip(path)
    local f = io.open(path, "rb")
    if not f then return false end
    local sig = f:read(2)
    f:close()
    return sig == "PK"
end

local function ensure_dir(path)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") ~= "directory" then
        lfs.mkdir(path)
    end
end

local function list_dir(path)
    local lfs = require("libs/libkoreader-lfs")
    local names = {}
    for name in lfs.dir(path) do
        if name ~= "." and name ~= ".." then
            names[#names + 1] = name
        end
    end
    table.sort(names)
    return names
end

function M.payloadDirectory(extract_dir)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(extract_dir .. "/main.lua", "mode") == "file"
        or lfs.attributes(extract_dir .. "/_meta.lua", "mode") == "file" then
        return extract_dir
    end
    local names = list_dir(extract_dir)
    local dirs = {}
    for _, name in ipairs(names) do
        local full = extract_dir .. "/" .. name
        if lfs.attributes(full, "mode") == "directory" then
            dirs[#dirs + 1] = full
        end
    end
    if #dirs == 1 and (
        lfs.attributes(dirs[1] .. "/main.lua", "mode") == "file"
        or lfs.attributes(dirs[1] .. "/_meta.lua", "mode") == "file"
    ) then
        return dirs[1]
    end
    return nil
end

local function copy_file(src, dest)
    local inf = io.open(src, "rb")
    if not inf then return false end
    local outf = io.open(dest, "wb")
    if not outf then
        inf:close()
        return false
    end
    while true do
        local chunk = inf:read(65536)
        if not chunk then break end
        outf:write(chunk)
    end
    inf:close()
    outf:close()
    return true
end

local function copy_tree(src, dest)
    local lfs = require("libs/libkoreader-lfs")
    ensure_dir(dest)
    for _, name in ipairs(list_dir(src)) do
        local from, to = src .. "/" .. name, dest .. "/" .. name
        local mode = lfs.attributes(from, "mode")
        if mode == "directory" then
            if not copy_tree(from, to) then return false end
        elseif mode == "file" then
            if not copy_file(from, to) then return false end
        end
    end
    return true
end

local function decode_json(text)
    local ok_rj, rapidjson = pcall(require, "rapidjson")
    local JSON = ok_rj and rapidjson or require("json")
    local ok, data = pcall(JSON.decode, text)
    if ok then return data end
    return nil
end

local function http_get_body(url, accept)
    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local body = {}
    socketutil:set_timeout(15, 60)
    local ok, code = pcall(function()
        local _n, status_code = http.request({
            url = url,
            method = "GET",
            headers = {
                ["User-Agent"] = M.USER_AGENT,
                ["Accept"] = accept or "application/vnd.github+json",
            },
            sink = ltn12.sink.table(body),
            redirect = true,
        })
        return status_code
    end)
    pcall(function() socketutil:reset_timeout() end)
    if not ok then return nil, tostring(code) end
    local ncode = tonumber(code)
    if ncode == 200 then
        return table.concat(body)
    end
    local handle = io.popen(string.format(
        "curl -sL -A %q -H %q %q",
        M.USER_AGENT,
        "Accept: " .. (accept or "application/vnd.github+json"),
        url
    ))
    if not handle then return nil, "curl unavailable" end
    local curl_body = handle:read("*a")
    handle:close()
    if curl_body and curl_body ~= "" then
        return curl_body
    end
    return nil, "HTTP " .. tostring(code)
end

local function download_file(url, dest)
    local ltn12 = require("ltn12")
    local http = require("socket.http")
    local socketutil = require("socketutil")
    local f = io.open(dest, "wb")
    if not f then return false end
    socketutil:set_timeout(15, 180)
    local ok, code = pcall(function()
        local _n, status_code = http.request({
            url = url,
            method = "GET",
            headers = { ["User-Agent"] = M.USER_AGENT },
            sink = ltn12.sink.file(f),
            redirect = true,
        })
        return status_code
    end)
    pcall(function() socketutil:reset_timeout() end)
    if ok and tonumber(code) == 200 and is_zip(dest) then
        return true
    end
    pcall(os.remove, dest)
    local ret = os.execute(string.format("curl -sfL -A %q -o %q %q", M.USER_AGENT, dest, url))
    if (ret == 0 or ret == true) and is_zip(dest) then
        return true
    end
    pcall(os.remove, dest)
    return false
end

local function unzip_archive(zip_path, dest)
    ensure_dir(dest)
    local quoted = string.format("unzip -oq %q -d %q", zip_path, dest)
    local ret = os.execute(quoted)
    if ret == 0 or ret == true then
        return true
    end
    -- BusyBox unzip on some readers.
    ret = os.execute(string.format("unzip -o %q -d %q", zip_path, dest))
    return ret == 0 or ret == true
end

local function restart_koreader()
    local Device = require("device")
    if Device.restartKOReader then
        Device:restartKOReader()
        return true
    end
    return false
end

function M.install(zip_url, new_version)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local _ = require("lib.i18n")
    local T = require("ffi/util").template
    local lfs = require("libs/libkoreader-lfs")

    UIManager:show(InfoMessage:new { text = _("Downloading update…"), timeout = 2 })
    UIManager:scheduleIn(0.2, function()
        local dir = M.cacheDir()
        ensure_dir(dir)
        local zip_path = dir .. "/update.zip"
        local extract_dir = dir .. "/extract"
        pcall(os.remove, zip_path)
        os.execute(string.format("rm -rf %q", extract_dir))
        ensure_dir(extract_dir)

        if not download_file(zip_url, zip_path) then
            UIManager:show(InfoMessage:new { text = _("Could not download the update.") })
            return
        end
        if file_size(zip_path) < M.MIN_ZIP_SIZE then
            pcall(os.remove, zip_path)
            UIManager:show(InfoMessage:new { text = _("The downloaded update looks incomplete.") })
            return
        end
        if not unzip_archive(zip_path, extract_dir) then
            UIManager:show(InfoMessage:new { text = _("Could not unpack the update.") })
            return
        end
        local payload = M.payloadDirectory(extract_dir)
        if not payload then
            UIManager:show(InfoMessage:new { text = _("The update archive has an unexpected layout.") })
            return
        end
        local dest = M.pluginPath()
        if lfs.attributes(dest, "mode") ~= "directory" then
            UIManager:show(InfoMessage:new { text = _("Could not find the plugin directory.") })
            return
        end
        if not copy_tree(payload, dest) then
            UIManager:show(InfoMessage:new { text = _("Could not install the update files.") })
            return
        end
        pcall(os.remove, zip_path)
        os.execute(string.format("rm -rf %q", extract_dir))

        UIManager:show(ConfirmBox:new {
            text = T(_("Updated to %1. Restart KOReader to load it?"), tostring(new_version or "")),
            ok_text = _("Restart"),
            cancel_text = _("Later"),
            ok_callback = function()
                if not restart_koreader() then
                    UIManager:show(InfoMessage:new {
                        text = _("Please restart KOReader to load the update."),
                    })
                end
            end,
        })
    end)
end

function M.check(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local NetworkMgr = require("ui/network/manager")
    local _ = require("lib.i18n")
    local T = require("ffi/util").template

    if plugin and plugin.isNetworkOnline and not plugin:isNetworkOnline() then
        if plugin.showOffline then
            plugin:showOffline(_("Update"))
        else
            UIManager:show(InfoMessage:new { text = _("Update: offline") })
        end
        return
    end
    if not NetworkMgr:isOnline() then
        UIManager:show(InfoMessage:new { text = _("Update: offline") })
        return
    end

    UIManager:show(InfoMessage:new { text = _("Checking for updates…"), timeout = 2 })
    UIManager:scheduleIn(0.2, function()
        local body, err = http_get_body(M.API_LATEST)
        if not body then
            UIManager:show(InfoMessage:new {
                text = T(_("Could not check for updates: %1"), tostring(err or "error")),
            })
            return
        end
        local release = decode_json(body)
        local tag = M.releaseTag(release)
        if not tag then
            UIManager:show(InfoMessage:new { text = _("Could not read the latest release.") })
            return
        end
        local installed = M.getInstalledVersion()
        if not M.isNewer(tag, installed) then
            UIManager:show(InfoMessage:new {
                text = T(_("Already up to date.\n\nInstalled: %1\nLatest: %2"), installed, tag),
            })
            return
        end
        local url = M.selectAsset(release)
        if not url then
            UIManager:show(InfoMessage:new { text = _("Latest release has no downloadable zip.") })
            return
        end
        local notes = tostring(release.body or ""):gsub("#+%s*", "")
        if #notes > 800 then
            notes = notes:sub(1, 800) .. "…"
        end
        local msg = T(_("Version %1 is available (installed: %2). Install it?"), tag, installed)
        if notes:find("%S") then
            msg = msg .. "\n\n" .. notes
        end
        UIManager:show(ConfirmBox:new {
            text = msg,
            ok_text = _("Install"),
            cancel_text = _("Later"),
            ok_callback = function()
                M.install(url, tag)
            end,
        })
    end)
end

return M
