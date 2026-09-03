package.path = "./?.lua;./?/init.lua;" .. package.path

local OTA = require("lib.ota")

local function assert_eq(actual, expected, msg)
    if actual ~= expected then
        error((msg or "assert_eq") .. ": expected " .. tostring(expected)
            .. ", got " .. tostring(actual), 2)
    end
end

local function assert_true(cond, msg)
    if not cond then error(msg or "assert_true", 2) end
end

local function assert_false(cond, msg)
    if cond then error(msg or "assert_false", 2) end
end

assert_eq(OTA.parseVersion("v0.1.0")[1], 0)
assert_eq(OTA.parseVersion("v0.1.0")[2], 1)
assert_eq(OTA.parseVersion("v0.1.0")[3], 0)
assert_eq(OTA.parseVersion("1.2")[1], 1)
assert_eq(OTA.parseVersion("1.2")[2], 2)

assert_false(OTA.isNewer("v0.1.0", "0.1.0"), "same version is not newer")
assert_false(OTA.isNewer("0.1.0", "v0.1.0"), "v-prefix ignored")
assert_true(OTA.isNewer("0.2.0", "0.1.0"), "minor bump")
assert_true(OTA.isNewer("v1.0.0", "0.9.9"), "major bump")
assert_false(OTA.isNewer("0.1.0", "0.1.1"), "older patch")
assert_true(OTA.isNewer("0.1.10", "0.1.9"), "numeric compare, not string")

assert_eq(OTA.readMetaVersion('version = "0.1.0"'), "0.1.0")
assert_eq(OTA.readMetaVersion("version = '1.2.3'"), "1.2.3")
assert_eq(OTA.readMetaVersion("fullname = 'x'"), nil)

local installed = OTA.getInstalledVersion("_meta.lua")
assert_eq(installed, "0.1.0", "reads repo _meta.lua")

local url, name = OTA.selectAsset({
    assets = {
        { name = "notes.txt", browser_download_url = "http://example/notes" },
        { name = "Weread_Annotation_Lite.koplugin.v0.2.0.zip", browser_download_url = "http://example/p.zip" },
    }
})
assert_eq(name, "Weread_Annotation_Lite.koplugin.v0.2.0.zip")
assert_eq(url, "http://example/p.zip")

local zipball, fallback = OTA.selectAsset({ zipball_url = "http://example/zipball" })
assert_eq(zipball, "http://example/zipball")
assert_eq(fallback, "source.zip")

assert_eq(OTA.releaseTag({ tag_name = "v0.2.0" }), "v0.2.0")
assert_eq(OTA.releaseTag({ name = "1.0.0" }), "1.0.0")
assert_eq(OTA.releaseTag({}), nil)

print("ota_spec ok")
