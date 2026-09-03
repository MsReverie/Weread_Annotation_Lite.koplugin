--[[--
GitHub Release self-updater, following weread.koplugin's updater:
Archiver extract, directory rename + backup, GitHub mirrors, Trapper.

@module lib.ota
--]]


local M = {}

M.REPO = "MsReverie/Weread_Annotation_Lite.koplugin"
M.API_URL = "https://api.github.com/repos/" .. M.REPO .. "/releases/latest"
M.RELEASE_PREFIX = "https://github.com/" .. M.REPO .. "/releases/download/"
M.GITHUB_MIRRORS = {
    "https://gh-proxy.com/",
    "https://ghfast.top/",
    "https://ghproxy.net/",
}
M.MAX_PACKAGE_BYTES = 10 * 1024 * 1024
M.USER_AGENT = "KOReader-WereadAnnotationLite-Updater/1.0"
M.ZIP_ROOTS = {
    "Weread_Annotation_Lite.koplugin/",
    "wereadannotationlite.koplugin/",
}

local function trim(value)
    return tostring(value or ""):match("^%s*(.-)%s*$")
end

local function plugin_dir_from_source()
    local source = debug.getinfo(1, "S").source or ""
    return source:match("^@?(.+)/lib/[^/]+$")
end

function M.plugin_dir(plugin)
    if plugin and type(plugin.path) == "string" and plugin.path ~= "" then
        return plugin.path
    end
    return plugin_dir_from_source()
end

function M.compare_versions(left, right)
    local function parts(version)
        local major, minor, patch = tostring(version or ""):match("^v?(%d+)%.(%d+)%.(%d+)$")
        if not major then return nil end
        return { tonumber(major), tonumber(minor), tonumber(patch) }
    end
    local a, b = parts(left), parts(right)
    if not a or not b then return nil end
    for i = 1, 3 do
        if a[i] < b[i] then return -1 end
        if a[i] > b[i] then return 1 end
    end
    return 0
end

function M.read_meta_version(text)
    if type(text) ~= "string" then return nil end
    return text:match('version%s*=%s*"([^"]+)"')
        or text:match("version%s*=%s*'([^']+)'")
end

function M.current_version(meta_path)
    meta_path = meta_path or ((plugin_dir_from_source() or ".") .. "/_meta.lua")
    local file = io.open(meta_path, "r")
    if not file then return "unknown" end
    local text = file:read("*a")
    file:close()
    return M.read_meta_version(text) or "unknown"
end

function M.candidate_urls(url, prefer_proxy)
    local allowed = url == M.API_URL
        or (type(url) == "string" and url:sub(1, #M.RELEASE_PREFIX) == M.RELEASE_PREFIX)
    if not allowed then return {} end
    local direct, proxies = { url }, {}
    for _, prefix in ipairs(M.GITHUB_MIRRORS) do
        proxies[#proxies + 1] = prefix .. url
    end
    local first = prefer_proxy and proxies or direct
    local second = prefer_proxy and direct or proxies
    local out = {}
    for _, candidate in ipairs(first) do out[#out + 1] = candidate end
    for _, candidate in ipairs(second) do out[#out + 1] = candidate end
    return out
end

local function zip_asset_for_version(name, version)
    if type(name) ~= "string" or not name:match("%.zip$") then return false end
    if name:match("%.sha256$") then return false end
    if not name:find(version, 1, true) and not name:find("v" .. version, 1, true) then
        return false
    end
    return name:find("koplugin", 1, true) ~= nil
end

local function normalize_notes(notes)
    notes = trim(notes)
    if notes == "" then return nil end
    notes = notes:gsub("\r\n", "\n"):gsub("\r", "\n")
    notes = notes:gsub("^#+%s*", ""):gsub("\n#+%s*", "\n")
    notes = notes:gsub("%*%*(.-)%*%*", "%1")
    notes = notes:gsub("`(.-)`", "%1")
    if #notes > 1600 then notes = notes:sub(1, 1597) .. "..." end
    return notes
end

function M.parse_release(data)
    if type(data) ~= "table" or data.draft == true or data.prerelease == true then
        return nil, "invalid release metadata"
    end
    local version = type(data.tag_name) == "string"
        and data.tag_name:match("^v(%d+%.%d+%.%d+)$") or nil
    if not version then return nil, "invalid release tag" end

    local archive_url, archive_size, digest, checksum_url
    for _, asset in ipairs(data.assets or {}) do
        local name = asset.name or ""
        if zip_asset_for_version(name, version) then
            archive_url = asset.browser_download_url
            archive_size = tonumber(asset.size)
            local raw = tostring(asset.digest or "")
            digest = raw:match("^sha256:([0-9a-fA-F]+)$") or raw:match("^([0-9a-fA-F][0-9a-fA-F]+)$")
        elseif name:match("%.sha256$") and name:find(version, 1, true) then
            checksum_url = asset.browser_download_url
        end
    end
    local function valid_url(url)
        return type(url) == "string" and url:sub(1, #M.RELEASE_PREFIX) == M.RELEASE_PREFIX
    end
    if not valid_url(archive_url) then
        return nil, "release package is missing"
    end
    if archive_size and archive_size > M.MAX_PACKAGE_BYTES then
        return nil, "release package is too large"
    end
    return {
        version = version,
        archive_url = archive_url,
        checksum_url = valid_url(checksum_url) and checksum_url or nil,
        digest = digest and digest:lower() or nil,
        archive_size = archive_size,
        notes = normalize_notes(data.body),
    }
end

local function remove_file(path)
    if path then pcall(os.remove, path) end
end

local function remove_tree(path)
    if not path or path == "" then return nil, "invalid directory" end
    local ok, ffiutil = pcall(require, "ffi/util")
    if ok and ffiutil and ffiutil.purgeDir then
        local removed, err = pcall(ffiutil.purgeDir, path)
        if removed then return true end
        return nil, err
    end
    return nil, "directory cleanup unavailable"
end

local function make_path(path)
    local ok, util = pcall(require, "util")
    if ok and util and util.makePath then
        return util.makePath(path)
    end
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(path, "mode") == "directory" then return true end
    return lfs.mkdir(path)
end

local function zip_root_ok(path)
    for _, root in ipairs(M.ZIP_ROOTS) do
        if path:sub(1, #root) == root then return true end
    end
    return false
end

local function unpack_release(archive, stage)
    local Archiver = require("ffi/archiver")
    local reader = Archiver.Reader:new()
    if not reader:open(archive) then
        reader:close()
        return nil, reader.err or "could not open release archive"
    end
    local ok, err = true, nil
    for entry in reader:iterate() do
        local path = entry.path
        local safe = type(path) == "string"
            and path ~= ""
            and path:sub(1, 1) ~= "/"
            and path:find("\\", 1, true) == nil
            and zip_root_ok(path)
            and path:match("^%.%./") == nil
            and path:match("/%.%./") == nil
            and path:match("/%.%.$") == nil
        if not safe then
            ok, err = nil, "unsafe path in release archive"
            break
        end
        if not reader:extractToPath(path, stage .. "/" .. path) then
            ok, err = nil, reader.err or "archive extraction failed"
            break
        end
    end
    if reader.err then ok, err = nil, reader.err end
    reader:close()
    return ok, err
end

local function staged_plugin_dir(stage)
    local lfs = require("libs/libkoreader-lfs")
    for _, root in ipairs(M.ZIP_ROOTS) do
        local dir = stage .. "/" .. root:gsub("/$", "")
        if lfs.attributes(dir .. "/main.lua", "mode") == "file" then
            return dir
        end
    end
    return nil
end

local function http_get(url, destination, max_bytes)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")
    local sink, chunks, limit_error
    if destination then
        local file = io.open(destination, "wb")
        if not file then return nil, "cannot create download file" end
        local file_sink = ltn12.sink.file(file)
        local received = 0
        sink = function(chunk, err)
            if chunk then
                if max_bytes and received + #chunk > max_bytes then
                    limit_error = "download exceeds size limit"
                    file_sink(nil, limit_error)
                    return nil, limit_error
                end
                received = received + #chunk
            end
            return file_sink(chunk, err)
        end
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        chunks = {}
        sink = ltn12.sink.table(chunks)
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, headers, status = socket.skip(1, http.request{
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
    if limit_error then
        remove_file(destination)
        return nil, limit_error
    end
    if headers == nil or code ~= 200 then
        if destination then remove_file(destination) end
        return nil, "HTTP " .. tostring(code or status or "error")
    end
    return destination and true or table.concat(chunks)
end

local function http_get_with_mirrors(url, destination, max_bytes)
    local candidates = M.candidate_urls(url, false)
    if #candidates == 0 then return nil, "update URL is not allowed" end
    local last_error
    for _, candidate in ipairs(candidates) do
        local ok, err = http_get(candidate, destination, max_bytes)
        if ok then return ok end
        if err == "download exceeds size limit" then return nil, err end
        last_error = err
        require("lib.logger").warn("update source failed:", tostring(candidate), tostring(err))
    end
    return nil, last_error or "all update sources failed"
end

local function read_file(path, max_bytes)
    local file, err = io.open(path, "rb")
    if not file then return nil, err end
    if max_bytes then
        local size = file:seek("end")
        if not size or size > max_bytes then
            file:close()
            return nil, "file is larger than expected"
        end
        file:seek("set", 0)
    end
    local data = file:read("*a")
    file:close()
    return data
end

function M.fetch_release()
    local body, err = http_get_with_mirrors(M.API_URL)
    if not body then return nil, err end
    local ok_json, json = pcall(require, "json")
    if not ok_json then return nil, "JSON support unavailable" end
    local ok, data = pcall(json.decode, body)
    if not ok then return nil, "invalid GitHub response" end
    return M.parse_release(data)
end

function M.cleanup_backup(plugin)
    local dir = M.plugin_dir(plugin)
    if not dir then return end
    local backup = dir .. ".backup"
    local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok_lfs and lfs and not lfs.attributes(backup, "mode") then
        return true
    end
    local removed, err = remove_tree(backup)
    if not removed then
        require("lib.logger").warn("could not remove previous update backup:", tostring(err))
    end
    return removed
end

function M.install_release(plugin, release)
    local dir = M.plugin_dir(plugin)
    if not dir then return nil, "plugin directory unavailable" end
    local data_dir = plugin.settings and plugin.settings.data_dir
        or require("datastorage"):getSettingsDir()
    local archive = data_dir .. "/wereadannotationlite-update.zip"
    local checksum = archive .. ".sha256"
    local stage = data_dir .. "/update-stage"
    remove_file(archive)
    remove_file(checksum)
    remove_tree(stage)
    local made, make_err = make_path(stage)
    if not made then return nil, "cannot create staging directory: " .. tostring(make_err) end

    local ok, err = http_get_with_mirrors(release.archive_url, archive, M.MAX_PACKAGE_BYTES)
    if not ok then remove_tree(stage); return nil, err end

    local expected = release.digest
    if release.checksum_url then
        local checksum_ok, checksum_err = http_get_with_mirrors(release.checksum_url, checksum, 4096)
        if not checksum_ok then
            remove_file(archive); remove_tree(stage)
            return nil, checksum_err
        end
        local checksum_body = read_file(checksum, 4096)
        expected = checksum_body and checksum_body:match("^%s*([0-9a-fA-F]+)")
        remove_file(checksum)
    end
    if expected then
        local package = read_file(archive, M.MAX_PACKAGE_BYTES)
        local Crypto = require("lib.crypto")
        if not package or Crypto.sha256_hex(package) ~= expected:lower() then
            remove_file(archive); remove_tree(stage)
            return nil, "SHA-256 verification failed"
        end
    end

    local unpacked, unpack_err = unpack_release(archive, stage)
    remove_file(archive)
    if not unpacked then remove_tree(stage); return nil, unpack_err end

    local staged = staged_plugin_dir(stage)
    local meta = staged and read_file(staged .. "/_meta.lua", 65536)
    local main = staged and read_file(staged .. "/main.lua", 1024 * 1024)
    local staged_version = meta and M.read_meta_version(meta)
    if not main or staged_version ~= release.version then
        remove_tree(stage)
        return nil, "release package structure or version is invalid"
    end

    local backup = dir .. ".backup"
    remove_tree(backup)
    local moved_old, move_old_err = os.rename(dir, backup)
    if not moved_old then remove_tree(stage); return nil, move_old_err or "could not back up plugin" end
    local moved_new, move_new_err = os.rename(staged, dir)
    if not moved_new then
        os.rename(backup, dir)
        remove_tree(stage)
        return nil, move_new_err or "could not activate update"
    end
    remove_tree(stage)
    return true
end

local function run_in_background(message, task, callback)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ok_trapper, Trapper = pcall(require, "ui/trapper")
    if ok_trapper and Trapper and Trapper.wrap and not coroutine.running() then
        Trapper:wrap(function()
            run_in_background(message, task, callback)
        end)
        return
    end
    local widget
    if message then
        widget = InfoMessage:new { text = message, timeout = 120 }
        UIManager:show(widget)
    end
    local function safe_task()
        local ok, result = xpcall(task, debug.traceback)
        if ok then return result end
        return { error = result }
    end
    local function finish(result)
        if widget then UIManager:close(widget) end
        callback(result)
    end
    if ok_trapper and Trapper and Trapper.dismissableRunInSubprocess then
        local completed, result = Trapper:dismissableRunInSubprocess(safe_task, widget)
        UIManager:scheduleIn(0.1, function()
            if completed then
                finish(result)
            else
                finish { cancelled = true, error = "cancelled" }
            end
        end)
    else
        UIManager:scheduleIn(0.1, function() finish(safe_task()) end)
    end
end

function M.check(plugin)
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    local ConfirmBox = require("ui/widget/confirmbox")
    local _ = require("lib.i18n")
    local T = require("ffi/util").template

    if plugin and plugin.whenOnline and plugin:whenOnline(function()
        M.check(plugin)
    end) then
        return
    end

    local installed = M.current_version((M.plugin_dir(plugin) or ".") .. "/_meta.lua")
    run_in_background(_("Checking for updates…"), function()
        local release, err = M.fetch_release()
        return { release = release, error = err }
    end, function(result)
        if not result or not result.release then
            if result and result.cancelled then return end
            UIManager:show(InfoMessage:new {
                text = T(_("Update check failed:\n%1"),
                    result and result.error or _("Unknown error")),
            })
            return
        end
        local release = result.release
        if M.compare_versions(release.version, installed) ~= 1 then
            UIManager:show(InfoMessage:new {
                text = T(_("Already up to date (v%1)."), installed),
                timeout = 3,
            })
            return
        end
        local msg = T(_("Version %1 is available (installed: %2). Install it?"),
            release.version, installed)
        if release.notes then
            msg = msg .. "\n\n" .. release.notes
        end
        UIManager:show(ConfirmBox:new {
            text = msg,
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
    local ConfirmBox = require("ui/widget/confirmbox")
    local _ = require("lib.i18n")
    local T = require("ffi/util").template

    run_in_background(_("Downloading update…"), function()
        local ok, err = M.install_release(plugin, release)
        return { success = ok == true, error = err }
    end, function(result)
        if not result or not result.success then
            if result and result.cancelled then return end
            UIManager:show(InfoMessage:new {
                text = T(_("Update installation failed:\n%1"),
                    result and result.error or _("Unknown error")),
            })
            return
        end
        UIManager:show(ConfirmBox:new {
            text = T(_("Updated to %1. Restart KOReader to load it?"), release.version),
            ok_text = _("Restart now"),
            cancel_text = _("Later"),
            ok_callback = function()
                UIManager:restartKOReader()
            end,
        })
    end)
end

return M
