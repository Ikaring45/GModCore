-- Original synthetic SQLite compatibility fixture. No game source is embedded here.
assert(type(sql) == "table")
assert(type(sql.Query) == "function")
assert(type(sql.LastError) == "function")
assert(sql.m_strError == "")

assert(sql.Query([[
    CREATE TABLE fixture_items (
        id INTEGER PRIMARY KEY,
        label TEXT NOT NULL,
        optional TEXT
    );
]]) == nil)
assert(sql.Query("INSERT INTO fixture_items (label) VALUES ('alpha'), ('beta')") == nil)

local rows = sql.Query([[
    SELECT id, label, optional
    FROM fixture_items
    ORDER BY id
]])
assert(type(rows) == "table" and #rows == 2)
assert(type(rows[1].id) == "string" and rows[1].id == "1")
assert(rows[1].label == "alpha" and rows[1].optional == nil)
assert(rows[2].id == "2" and rows[2].label == "beta")

local multi = sql.Query([[
    INSERT INTO fixture_items (label) VALUES ('gamma');
    SELECT id, label FROM fixture_items WHERE label = 'gamma';
]])
assert(type(multi) == "table" and #multi == 1)
assert(multi[1].id == "3" and multi[1].label == "gamma")

assert(sql.Query("BEGIN") == nil)
assert(sql.Query("INSERT INTO fixture_items (label) VALUES ('rolled back')") == nil)
assert(sql.Query("ROLLBACK") == nil)
local count = sql.Query("SELECT COUNT(*) AS amount FROM fixture_items")
assert(count[1].amount == "3")

assert(sql.Query("SELECT * FROM fixture_items WHERE id = -1") == nil)

local syntax_result = sql.Query("SELEC deliberately_invalid")
assert(syntax_result == false)
assert(type(sql.m_strError) == "string" and #sql.m_strError > 0)
assert(sql.LastError() == sql.m_strError)
local remembered_error = sql.LastError()
assert(sql.Query("SELECT 1 AS still_usable")[1].still_usable == "1")
assert(sql.LastError() == remembered_error)

assert(sql.Query("ATTACH DATABASE ':memory:' AS forbidden") == false)
assert(#sql.m_strError > 0)
assert(sql.Query("DETACH DATABASE main") == false)
assert(#sql.m_strError > 0)
assert(sql.Query("VACUUM") == false)
assert(#sql.m_strError > 0)
assert(sql.Query("CREATE VIRTUAL TABLE forbidden_vtable USING fts5(value)") == false)
assert(#sql.m_strError > 0)
assert(sql.Query("SELECT load_extension('forbidden')") == false)
assert(#sql.m_strError > 0)

local observed_error
sql.m_strError = nil
setmetatable(sql, {
    __newindex = function(target, key, value)
        if key == "m_strError" then observed_error = value end
        rawset(target, key, value)
    end
})
assert(sql.Query("THIS IS NOT SQL") == false)
assert(observed_error == sql.m_strError and #observed_error > 0)
setmetatable(sql, nil)

local ok = pcall(sql.Query, {})
assert(not ok)

GLUA_SQL_REGRESSION_OK = true
