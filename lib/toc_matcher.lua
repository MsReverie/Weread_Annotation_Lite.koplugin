--[[--
Conservative matching of WeRead chapter titles to a local KOReader TOC.

The matcher is intentionally independent from document/cache lifecycle code.
It combines deterministic title normalization with a bounded fuzzy score and
monotonic matching. Ambiguous candidates are rejected instead of guessed.

@module lib.toc_matcher
--]]

local Matcher = {}

local FUZZY_THRESHOLD = 0.78
local FUZZY_MARGIN = 0.10
local FILL_THRESHOLD = 0.50

local function strip_ascii_punctuation(text)
    return text:gsub("[%.%,!%?;:%-%_/%\\%(%)%[%]{}]", "")
end

local function chinese_digit_value(char)
    return ({ ["零"] = 0, ["〇"] = 0, ["一"] = 1, ["二"] = 2,
        ["三"] = 3, ["四"] = 4, ["五"] = 5, ["六"] = 6,
        ["七"] = 7, ["八"] = 8, ["九"] = 9 })[char]
end

local function chinese_unit_value(char)
    return ({ ["十"] = 10, ["百"] = 100, ["千"] = 1000 })[char]
end

local function utf8_chars(text)
    local chars = {}
    local i = 1
    while i <= #text do
        local b = text:byte(i)
        local width = 1
        if b >= 0xF0 then width = 4
        elseif b >= 0xE0 then width = 3
        elseif b >= 0xC0 then width = 2 end
        chars[#chars + 1] = text:sub(i, i + width - 1)
        i = i + width
    end
    return chars
end

local function chinese_number_to_decimal(text)
    local chars = utf8_chars(text)
    if #chars == 0 then return nil end
    local total, section, number = 0, 0, 0
    local saw = false
    for _, char in ipairs(chars) do
        local digit = chinese_digit_value(char)
        if digit ~= nil then
            number = digit
            saw = true
        else
            local unit = chinese_unit_value(char)
            if unit then
                saw = true
                if number == 0 then number = 1 end
                if unit >= 1000 then
                    section = section + number * unit
                    total = total + section
                    section = 0
                else
                    section = section + number * unit
                end
                number = 0
            end
        end
    end
    if not saw then return nil end
    return total + section + number
end

local function normalize_chapter_number(text)
    local prefix, body, suffix = text:match("^(第)([^章卷部篇]+)([章卷部篇].*)$")
    if not prefix or not body or not suffix then return text end
    if body:match("^%d+$") then return prefix .. body .. suffix end
    local number = chinese_number_to_decimal(body)
    if number then return prefix .. tostring(number) .. suffix end
    return text
end

function Matcher.normalize_title(text)
    text = tostring(text or "")
    text = text:gsub("%s+", "")
    text = text:gsub("《", ""):gsub("》", "")
        :gsub("【", ""):gsub("】", "")
    text = text:gsub("：", ""):gsub("，", ""):gsub("、", "")
        :gsub("。", ""):gsub("！", ""):gsub("？", "")
        :gsub("—", ""):gsub("－", "")
    text = strip_ascii_punctuation(text)
    return normalize_chapter_number(text)
end

local function chapter_number(text)
    local normalized = Matcher.normalize_title(text)
    local digits = normalized:match("^第(%d+)[章卷部篇]")
    return digits and tonumber(digits) or nil
end

local function title_subject(text)
    local normalized = Matcher.normalize_title(text)
    return normalized:gsub("^第%d+[章卷部篇]", ""), normalized
end

local function common_prefix_len(a, b)
    local aa, bb = utf8_chars(a), utf8_chars(b)
    local n = math.min(#aa, #bb)
    local i = 0
    while i < n and aa[i + 1] == bb[i + 1] do i = i + 1 end
    return i, #aa, #bb
end

local function common_suffix_len(a, b)
    local aa, bb = utf8_chars(a), utf8_chars(b)
    local i, j = #aa, #bb
    local count = 0
    while i >= 1 and j >= 1 and aa[i] == bb[j] do
        count = count + 1
        i, j = i - 1, j - 1
    end
    return count, #aa, #bb
end

local function character_overlap(a, b)
    local aa, bb = utf8_chars(a), utf8_chars(b)
    local ca, cb = {}, {}
    for _, ch in ipairs(aa) do ca[ch] = (ca[ch] or 0) + 1 end
    for _, ch in ipairs(bb) do cb[ch] = (cb[ch] or 0) + 1 end
    local common = 0
    for ch, count in pairs(ca) do
        common = common + math.min(count, cb[ch] or 0)
    end
    local total = math.max(#aa, #bb)
    return total == 0 and 0 or common / total
end

function Matcher.similarity(want, have)
    local want_subject, want_normalized = title_subject(want)
    local have_subject, have_normalized = title_subject(have)
    if want_normalized == "" or have_normalized == "" then return 0 end
    if want_normalized == have_normalized then return 1 end

    local wp, hp = chapter_number(want_normalized), chapter_number(have_normalized)
    local wlen, hlen = #utf8_chars(want_subject), #utf8_chars(have_subject)

    -- Exact subject agreement is strong evidence even when one title has a
    -- chapter number and the other does not.
    if math.min(wlen, hlen) >= 4 then
        if want_subject:find(have_subject, 1, true)
            or have_subject:find(want_subject, 1, true) then
            if wp and hp and wp == hp then return 0.98 end
            return 0.90
        end
    end

    local prefix, wtotal, htotal = common_prefix_len(want_subject, have_subject)
    local suffix = common_suffix_len(want_subject, have_subject)
    local overlap = character_overlap(want_subject, have_subject)
    local base_len = math.max(wtotal, htotal)
    local score = overlap * 0.55
    if base_len > 0 then
        score = score + math.min(0.20, prefix / base_len * 0.20)
        score = score + math.min(0.15, suffix / base_len * 0.15)
    end
    if wp and hp and wp == hp then score = score + 0.20 end
    if math.min(wtotal, htotal) < 4 then score = math.min(score, 0.70) end
    if score > 1 then score = 1 end
    return score
end

local function related(want, have)
    local want_subject, want_normalized = title_subject(want)
    local have_subject, have_normalized = title_subject(have)
    if want_normalized == "" or have_normalized == "" then return false end
    if want_normalized == have_normalized then return true end
    if math.min(#utf8_chars(want_subject), #utf8_chars(have_subject)) < 4 then return false end
    return want_subject:find(have_subject, 1, true) ~= nil
        or have_subject:find(want_subject, 1, true) ~= nil
end

local function candidate_score(want, item)
    local have = Matcher.normalize_title(item and item.title)
    local normalized_want = Matcher.normalize_title(want)
    if normalized_want == "" or have == "" then return 0, "none" end
    if normalized_want == have then return 1, "exact" end
    if related(normalized_want, have) then
        return Matcher.similarity(normalized_want, have), "related"
    end
    return Matcher.similarity(normalized_want, have), "fuzzy"
end

function Matcher.find_candidate(weread_title, toc_items, last)
    local want = Matcher.normalize_title(weread_title)
    if want == "" then return nil end
    local best, second = nil, nil
    for i = (last or 0) + 1, #(toc_items or {}) do
        local score, kind = candidate_score(want, toc_items[i])
        if score > 0 then
            local candidate = { index = i, score = score, kind = kind }
            if not best or score > best.score then
                second = best
                best = candidate
            elseif not second or score > second.score then
                second = candidate
            end
        end
    end
    if not best then return nil end
    if best.kind == "fuzzy" then
        if best.score < FUZZY_THRESHOLD then return nil end
        if second and (best.score - second.score) < FUZZY_MARGIN then return nil end
    end
    return best
end

local function fill_holes(map, weread_chapters, toc_items)
    local anchors = {}
    for i, chapter in ipairs(weread_chapters or {}) do
        local uid = tostring(chapter.chapterUid or "")
        if uid ~= "" and map[uid] then
            anchors[#anchors + 1] = { weread_i = i, toc_i = map[uid] }
        end
    end
    for a = 1, math.max(0, #anchors - 1) do
        local left, right = anchors[a], anchors[a + 1]
        local holes = {}
        for i = left.weread_i + 1, right.weread_i - 1 do
            local chapter = weread_chapters[i]
            local uid = tostring(chapter.chapterUid or "")
            if uid ~= "" and not map[uid] then
                holes[#holes + 1] = chapter
            end
        end
        local span = right.toc_i - left.toc_i - 1
        if #holes > 0 and #holes == span then
            local ok, proposed = true, {}
            for k, hole in ipairs(holes) do
                local toc_item = toc_items[left.toc_i + k]
                if not toc_item or Matcher.similarity(hole.title, toc_item.title) < FILL_THRESHOLD then
                    ok = false
                    break
                end
                proposed[k] = left.toc_i + k
            end
            if ok then
                for k, hole in ipairs(holes) do
                    map[tostring(hole.chapterUid)] = proposed[k]
                end
            end
        end
    end
end

function Matcher.match(weread_chapters, toc_items)
    local map, meta = {}, {}
    local last = 0
    for _, chapter in ipairs(weread_chapters or {}) do
        local uid = tostring(chapter.chapterUid or "")
        if uid ~= "" then
            local candidate = Matcher.find_candidate(chapter.title, toc_items, last)
            if candidate then
                map[uid] = candidate.index
                meta[uid] = candidate
                last = candidate.index
            end
        end
    end
    fill_holes(map, weread_chapters, toc_items)
    return map, meta
end

Matcher.FUZZY_THRESHOLD = FUZZY_THRESHOLD
Matcher.FUZZY_MARGIN = FUZZY_MARGIN
Matcher.FILL_THRESHOLD = FILL_THRESHOLD

return Matcher
