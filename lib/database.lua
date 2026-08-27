local Database = {}
Database.__index = Database
local json = require("json")
local Crypto = require("lib.crypto")

local function items_have_thoughts(items)
    for _, item in ipairs(items or {}) do
        if type(item.content) == "string" and item.content:find("%S") then
            return true
        end
    end
    return false
end

function Database:new(settings)
    return setmetatable({ settings = settings }, self)
end

function Database:path(file)
    local base = self.settings:get("data_dir") or self.settings:get("cache_dir") or "."
    local document_path = tostring(file or "")
    local suffix = Crypto.sha256_hex(document_path):sub(1, 16)
    return base .. "/" .. suffix .. ".db"
end

function Database:saveBinding(file, binding)
    local db = self:open(file, true)
    local stmt = db:prepare([[INSERT INTO book(file,book_id,title,author,updated_at)
        VALUES(?,?,?,?,?) ON CONFLICT(file) DO UPDATE SET book_id=excluded.book_id,
        title=excluded.title,author=excluded.author,updated_at=excluded.updated_at]])
    stmt:reset():bind(file, binding.book_id, binding.title or "", binding.author or "", os.time()):step()
    stmt:close(); self:release(db)
end

function Database:saveRecords(file, records)
    local db, open_err = self:open(file, true)
    if not db then return nil, open_err end
    db:exec("BEGIN")
    local stmt = db:prepare([[INSERT INTO annotations(chapter_uid,range,text,pos0,pos1,items,fetched)
        VALUES(?,?,?,?,?,?,?) ON CONFLICT(chapter_uid,range) DO UPDATE SET
        text=excluded.text,pos0=excluded.pos0,pos1=excluded.pos1]])
    for _, r in ipairs(records or {}) do
        stmt:reset():bind(r.chapter_uid, r.range, r.text or "", r.pos0, r.pos1, "[]", 0):step()
    end
    stmt:close(); db:exec("COMMIT"); self:release(db)
end

function Database:getUnderlineCache(file, chapter_uid)
    local db = self:open(file, false)
    if not db then return nil end
    local stmt = db:prepare([[SELECT synckey,payload FROM underline_cache
        WHERE chapter_uid=?]])
    local row = stmt:reset():bind(chapter_uid):step()
    stmt:close(); self:release(db)
    if not row then return nil end
    return {
        synckey = tonumber(row[1]) or 0,
        items = json.decode(row[2] or "[]") or {},
    }
end

function Database:saveUnderlineCache(file, chapter_uid, synckey, items)
    local db, open_err = self:open(file, true)
    if not db then return nil, open_err end
    local stmt = db:prepare([[INSERT INTO underline_cache
        (chapter_uid,synckey,payload,updated_at) VALUES(?,?,?,?)
        ON CONFLICT(chapter_uid) DO UPDATE SET synckey=excluded.synckey,
        payload=excluded.payload,updated_at=excluded.updated_at]])
    stmt:reset():bind(chapter_uid, tonumber(synckey) or 0,
        json.encode(items or {}), os.time()):step()
    stmt:close(); self:release(db)
end

function Database:clear(file)
    if self._session_file == file then
        self:endSession()
    end
    local path = self:path(file)
    for _, suffix in ipairs({ "", "-wal", "-shm" }) do os.remove(path .. suffix) end
end

function Database:saveThoughts(file, chapter_uid, range, payload, fetched)
    local db, open_err = self:open(file, true)
    if not db then return nil, open_err end
    local stmt = db:prepare([[UPDATE annotations SET items=?,fetched=?
        WHERE chapter_uid=? AND range=?]])
    stmt:reset():bind(payload or "[]", fetched and 1 or 0, chapter_uid, range):step()
    stmt:close(); self:release(db)
end

function Database:getRanges(file, chapter_uid)
    local db = self:open(file, false)
    if not db then return {} end
    local stmt = db:prepare("SELECT range FROM annotations WHERE chapter_uid=? AND fetched=0 ORDER BY range")
    local rows, row = {}, stmt:reset():bind(chapter_uid):step()
    while row do
        rows[#rows + 1] = row[1]; row = stmt:step()
    end
    stmt:close(); self:release(db); return rows
end

function Database:getBinding(file)
    local db = self:open(file, false)
    if not db then return nil end
    local stmt = db:prepare("SELECT book_id,title,author FROM book WHERE file=?")
    local row = stmt:reset():bind(file):step()
    stmt:close(); self:release(db)
    if not row then return nil end
    return { book_id = row[1], title = row[2], author = row[3] }
end

function Database:getDocument(file)
    local db = self:open(file, false)
    if not db then return nil end
    local stmt = db:prepare("SELECT book_id,title,author FROM book WHERE file=?")
    local row = stmt:reset():bind(file):step()
    stmt:close()
    if not row then
        self:release(db); return nil
    end
    local value = { binding = { book_id = row[1], title = row[2], author = row[3] }, records = {} }
    local records = db:prepare(
    "SELECT chapter_uid,range,text,pos0,pos1,items,fetched FROM annotations WHERE pos0 IS NOT NULL AND pos0 != ''")
    local item = records:reset():step()
    while item do
        local items = json.decode(item[6] or "[]") or {}
        local fetched = tonumber(item[7]) or 0
        if fetched ~= 1 or items_have_thoughts(items) then
            value.records[#value.records + 1] = {
                chapter_uid = item[1],
                range = item[2],
                text = item[3],
                pos0 = item[4],
                pos1 = item[5],
                items = items,
                fetched = fetched,
            }
        end
        item = records:step()
    end
    records:close(); self:release(db)
    return value
end

function Database:beginSession(file, create)
    if self._session_db and self._session_file == file then
        return self._session_db
    end
    self:endSession()
    local db, err = self:open(file, create)
    if not db then return nil, err end
    self._session_db = db
    self._session_file = file
    return db
end

function Database:endSession()
    local db = self._session_db
    self._session_db = nil
    self._session_file = nil
    if db then db:close() end
end

function Database:release(db)
    if not db then return end
    if db == self._session_db then return end
    db:close()
end

function Database:open(file, create)
    if self._session_db and self._session_file == file then
        return self._session_db
    end
    local lfs = require("libs/libkoreader-lfs")
    local dir = (self:path(file):match("^(.*)/") or ".")
    local path = self:path(file)
    if not create and not lfs.attributes(path, "mode") then return nil end
    if not lfs.attributes(dir, "mode") then
        local created, mkdir_err = lfs.mkdir(dir)
        if not created and not lfs.attributes(dir, "mode") then
            return nil, tostring(mkdir_err or "database directory creation failed")
        end
    end
    local SQ3 = require("lua-ljsqlite3/init")
    local db = SQ3.open(path)
    db:exec("PRAGMA journal_mode=WAL")
    db:exec("PRAGMA synchronous=NORMAL")
    db:exec([[CREATE TABLE IF NOT EXISTS book (
        file TEXT PRIMARY KEY, book_id TEXT NOT NULL, title TEXT, author TEXT,
        updated_at INTEGER NOT NULL) WITHOUT ROWID]])
    db:exec([[CREATE TABLE IF NOT EXISTS annotations (
        chapter_uid TEXT NOT NULL, range TEXT NOT NULL, text TEXT,
        pos0 TEXT, pos1 TEXT, items TEXT, fetched INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(chapter_uid, range)) WITHOUT ROWID]])
    db:exec([[CREATE TABLE IF NOT EXISTS chapters (
        chapter_uid TEXT PRIMARY KEY, title TEXT, position INTEGER NOT NULL) WITHOUT ROWID]])
    db:exec([[CREATE TABLE IF NOT EXISTS underline_cache (
        chapter_uid TEXT PRIMARY KEY, synckey INTEGER NOT NULL,
        payload TEXT NOT NULL, updated_at INTEGER NOT NULL) WITHOUT ROWID]])
    db:exec([[CREATE TABLE IF NOT EXISTS meta (
        key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID]])
    return db
end

function Database:getChapterSynckey(file)
    local db = self:open(file, false)
    if not db then return 0 end
    local stmt = db:prepare("SELECT value FROM meta WHERE key=?")
    local row = stmt:reset():bind("chapter_synckey"):step()
    stmt:close(); self:release(db)
    return row and tonumber(row[1]) or 0
end

function Database:hasLocatedChapter(file, chapter_uid)
    local db = self:open(file, false)
    if not db then return false end
    local stmt = db:prepare(
        "SELECT 1 FROM annotations WHERE chapter_uid=? AND pos0 IS NOT NULL AND pos0 != '' LIMIT 1")
    local row = stmt:reset():bind(tostring(chapter_uid)):step()
    stmt:close(); self:release(db)
    return row ~= nil
end

function Database:pruneChapterRanges(file, chapter_uid, keep_ranges)
    local db, open_err = self:open(file, true)
    if not db then return nil, open_err end
    chapter_uid = tostring(chapter_uid)
    local keep = {}
    for _, range in ipairs(keep_ranges or {}) do
        keep[tostring(range)] = true
    end
    local stmt = db:prepare("SELECT range FROM annotations WHERE chapter_uid=?")
    local row = stmt:reset():bind(chapter_uid):step()
    local drop = {}
    while row do
        local range = tostring(row[1] or "")
        if range ~= "" and not keep[range] then
            drop[#drop + 1] = range
        end
        row = stmt:step()
    end
    stmt:close()
    if #drop > 0 then
        local del = db:prepare("DELETE FROM annotations WHERE chapter_uid=? AND range=?")
        for _, range in ipairs(drop) do
            del:reset():bind(chapter_uid, range):step()
        end
        del:close()
    end
    self:release(db)
    return drop
end

function Database:saveChapters(file, chapters, synckey)
    local db, open_err = self:open(file, true)
    if not db then return nil, open_err end
    db:exec("DELETE FROM chapters")
    local stmt = db:prepare("INSERT INTO chapters(chapter_uid,title,position) VALUES(?,?,?)")
    for i, chapter in ipairs(chapters or {}) do
        stmt:reset():bind(chapter.chapterUid, chapter.title or "", i):step()
    end
    stmt:close()
    if synckey ~= nil then
        local meta = db:prepare(
            "INSERT INTO meta(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value")
        meta:reset():bind("chapter_synckey", tostring(tonumber(synckey) or 0)):step()
        meta:close()
    end
    self:release(db)
end

function Database:listChapters(file)
    local db = self:open(file, false)
    if not db then return {} end
    local stmt = db:prepare("SELECT chapter_uid,title,position FROM chapters ORDER BY position")
    local rows, row = {}, stmt:reset():step()
    while row do
        rows[#rows + 1] = {
            chapterUid = tostring(row[1]),
            title = row[2] or "",
            position = tonumber(row[3]) or #rows + 1,
        }
        row = stmt:step()
    end
    stmt:close(); self:release(db)
    return rows
end

function Database:thoughtlessSet(file)
    local db = self:open(file, false)
    if not db then return {} end
    local stmt = db:prepare("SELECT chapter_uid,range,items FROM annotations WHERE fetched=1")
    local set, row = {}, stmt:reset():step()
    while row do
        local items = json.decode(row[3] or "[]") or {}
        if not items_have_thoughts(items) then
            set[tostring(row[1]) .. "\0" .. tostring(row[2])] = true
        end
        row = stmt:step()
    end
    stmt:close(); self:release(db)
    return set
end

function Database:cachedChapterSet(file)
    local db = self:open(file, false)
    if not db then return {} end
    local stmt = db:prepare("SELECT chapter_uid FROM underline_cache")
    local set, row = {}, stmt:reset():step()
    while row do
        set[tostring(row[1])] = true
        row = stmt:step()
    end
    stmt:close(); self:release(db)
    return set
end

return Database
