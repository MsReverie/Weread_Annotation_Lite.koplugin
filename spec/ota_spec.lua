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

assert_eq(OTA.PLUGIN_DIRNAME, "wereadannotationlite.koplugin")
assert_eq(OTA.normalize_zip_path("Weread_Annotation_Lite.koplugin/main.lua"), "main.lua")
assert_eq(OTA.normalize_zip_path("wereadannotationlite.koplugin/main.lua"), "main.lua")
assert_eq(OTA.normalize_zip_path("./wereadannotationlite.koplugin/lib/ota.lua"), "lib/ota.lua")
assert_true(OTA.is_excluded("Weread_Annotation_Lite.koplugin/spec/foo.lua"))
assert_true(OTA.is_excluded(".github/workflows/ci.yml"))
assert_false(OTA.is_excluded("Weread_Annotation_Lite.koplugin/main.lua"))
assert_false(OTA.path_is_safe("../evil.lua"))
assert_true(OTA.path_is_safe("Weread_Annotation_Lite.koplugin/main.lua"))

local meta_version = OTA.current_version("_meta.lua")
assert_true(meta_version:match("^%d+%.%d+%.%d+$"), "meta version is semver")
assert_eq(OTA.preferred_archive_name(meta_version),
    "Weread_Annotation_Lite.koplugin.v" .. meta_version .. ".zip")

assert_eq(
    OTA.backup_path("/koreader/plugins/wereadannotationlite.koplugin"),
    "/koreader/plugins/wereadannotationlite.koplugin.backup"
)
assert_eq(OTA.backup_path(nil), nil)
assert_eq(OTA.backup_path(""), nil)

local function parse_assets(assets)
    return OTA.parse_release({
        tag_name = "v0.2.0",
        assets = assets,
    })
end

local function gh_zip(name)
    return {
        name = name,
        browser_download_url = "https://github.com/MsReverie/Weread_Annotation_Lite.koplugin/releases/download/v0.2.0/" .. name,
        size = 70000,
    }
end

local urls = OTA.candidate_urls(OTA.API_URL)
assert_eq(urls[1], OTA.API_URL)
assert_true(#urls > 1)
assert_eq(#OTA.candidate_urls("https://example.com/x"), 1)

local release, err = parse_assets({ gh_zip("Weread_Annotation_Lite.koplugin.v0.2.0.zip") })
assert_eq(err, nil)
assert_eq(release.version, "0.2.0")
assert_eq(select(1, OTA.parse_release({ tag_name = "v0.2.0", draft = true })), nil)
assert_eq(select(2, OTA.parse_release({ tag_name = "v0.2.0", assets = {} })), "release package is missing")

local loose, loose_err = parse_assets({ gh_zip("Weread_Annotation_Lite-v0.2.0.zip") })
assert_eq(loose_err, nil, "zip without the word koplugin should still be accepted")
assert_eq(loose.archive_url:match("Weread_Annotation_Lite%-v0%.2%.0%.zip$") ~= nil, true)

local preferred, preferred_err = parse_assets({
    gh_zip("Weread_Annotation_Lite-v0.2.0.zip"),
    gh_zip("Weread_Annotation_Lite.koplugin.v0.2.0.zip"),
})
assert_eq(preferred_err, nil)
assert_true(
    preferred.archive_url:find("Weread_Annotation_Lite.koplugin.v0.2.0.zip", 1, true) ~= nil,
    "canonical zip name should win over a looser match"
)

assert_eq(
    select(2, parse_assets({ gh_zip("notes-v0.2.0.zip") })),
    "release package is missing"
)

assert_eq(select(1, OTA.validate_staged_plugin(".", meta_version)), true)
assert_eq(select(2, OTA.validate_staged_plugin(".", "9.9.9")), "release package version mismatch")
assert_eq(select(2, OTA.validate_staged_plugin("spec", meta_version)), "release package is missing main.lua")
assert_eq(select(1, OTA.validate_staged_plugin(nil, meta_version)), nil)

print("ota_spec ok")
