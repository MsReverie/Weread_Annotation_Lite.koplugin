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

assert_false(OTA.is_version_newer(nil, "1.0"))
assert_true(OTA.is_version_newer("0.2.0", "0.1.0"))
assert_false(OTA.is_version_newer("0.1.0", "0.1.0"))
assert_true(OTA.is_version_newer("0.1.10", "0.1.9"))
assert_true(OTA.is_version_newer("1.0.0", "1.0.0-rc.1"))
assert_false(OTA.is_version_newer("1.0.0-rc.1", "1.0.0"))
assert_true(OTA.is_version_newer("v0.2.0", "v0.1.0"))

assert_eq(OTA.normalize_zip_path("Weread_Annotation_Lite.koplugin/main.lua"), "main.lua")
assert_eq(OTA.normalize_zip_path("./wereadannotationlite.koplugin/lib/ota.lua"), "lib/ota.lua")
assert_true(OTA.is_excluded("Weread_Annotation_Lite.koplugin/spec/foo.lua"))
assert_true(OTA.is_excluded(".github/workflows/ci.yml"))
assert_false(OTA.is_excluded("Weread_Annotation_Lite.koplugin/main.lua"))
assert_false(OTA.path_is_safe("../evil.lua"))
assert_true(OTA.path_is_safe("Weread_Annotation_Lite.koplugin/main.lua"))

assert_eq(OTA.current_version("_meta.lua"), "0.1.0")

local release, err = OTA.parse_release({
    tag_name = "v0.2.0",
    assets = {{
        name = "Weread_Annotation_Lite.koplugin.v0.2.0.zip",
        browser_download_url = "https://github.com/MsReverie/Weread_Annotation_Lite.koplugin/releases/download/v0.2.0/x.zip",
        size = 70000,
    }},
})
assert_eq(err, nil)
assert_eq(release.version, "0.2.0")
assert_eq(select(1, OTA.parse_release({ tag_name = "v0.2.0", draft = true })), nil)
assert_eq(select(2, OTA.parse_release({ tag_name = "v0.2.0", assets = {} })), "release package is missing")

print("ota_spec ok")
