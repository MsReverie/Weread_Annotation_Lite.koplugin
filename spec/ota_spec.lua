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

assert_eq(OTA.compare_versions("0.1.0", "0.1.0"), 0)
assert_eq(OTA.compare_versions("v0.2.0", "0.1.0"), 1)
assert_eq(OTA.compare_versions("0.1.0", "v0.1.1"), -1)
assert_eq(OTA.compare_versions("0.1.10", "0.1.9"), 1)
assert_eq(OTA.compare_versions("nope", "0.1.0"), nil)

assert_eq(OTA.read_meta_version('version = "0.1.0"'), "0.1.0")
assert_eq(OTA.current_version("_meta.lua"), "0.1.0")

local urls = OTA.candidate_urls(OTA.API_URL)
assert_eq(urls[1], OTA.API_URL)
assert_true(#urls > 1, "mirrors appended")
assert_eq(#OTA.candidate_urls("https://evil.example/x"), 0)

local release, err = OTA.parse_release({
    tag_name = "v0.2.0",
    body = "## Notes\n**hi**",
    assets = {
        {
            name = "Weread_Annotation_Lite.koplugin.v0.2.0.zip",
            browser_download_url = OTA.RELEASE_PREFIX .. "v0.2.0/Weread_Annotation_Lite.koplugin.v0.2.0.zip",
            size = 70000,
            digest = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        },
    },
})
assert_eq(err, nil)
assert_eq(release.version, "0.2.0")
assert_eq(release.digest, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
assert_eq(release.notes, "Notes\nhi")

local missing = select(2, OTA.parse_release({ tag_name = "v0.2.0", assets = {} }))
assert_eq(missing, "release package is missing")

local draft = select(1, OTA.parse_release({ tag_name = "v0.2.0", draft = true, assets = {} }))
assert_eq(draft, nil)

print("ota_spec ok")
