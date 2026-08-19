local files, directories = file.Find("terrortown/gamemode/lang/*.lua", "LUA")
assert(table.concat(files, ",") == "Alpha.lua,english.lua,zulu.LUA")
assert(#directories == 0)

local descending = file.Find("terrortown/gamemode/lang/*.lua", "LUA", "namedesc")
assert(table.concat(descending, ",") == "zulu.LUA,english.lua,Alpha.lua")

local question = file.Find("terrortown/gamemode/lang/?????.lua", "LUA")
assert(#question == 1 and question[1] == "Alpha.lua")

local loaded = {}
for _, name in ipairs(files) do
    loaded[#loaded + 1] = include("lang/" .. name)
end
assert(table.concat(loaded, ",") == "alpha,english,zulu")

assert(file.Exists("terrortown/gamemode/lang", "LUA"))
assert(file.IsDir("terrortown/gamemode/lang", "LUA"))
assert(file.Exists("terrortown/gamemode/lang/english.lua", "LUA"))
assert(not file.IsDir("terrortown/gamemode/lang/english.lua", "LUA"))
assert(file.Read("terrortown/gamemode/lang/english.lua", "LUA") == "return 'english'")

assert(file.Write("Mixed/Hello.TXT", "one"))
assert(file.Append("mixed/hello.txt", "-two"))
assert(file.Read("MIXED/HELLO.TXT") == "one-two")
assert(file.Size("mixed/hello.txt", "DATA") == 7)
assert(not file.Write("blocked/script.lua", "return true"))
assert(not file.Write("日本語.txt", "not permitted by GMod's DATA filename rules"))

local stream = assert(file.Open("Stream/Value.TXT", "wb", "DATA"))
stream:Write("streamed")
stream:Close()
assert(file.Read("stream/value.txt") == "streamed")

file.CreateDir("Empty/Deep")
assert(file.Exists("empty/deep", "DATA") and file.IsDir("empty/deep", "DATA"))
local dataFiles, dataDirectories = file.Find("empty/*", "DATA")
assert(#dataFiles == 0 and #dataDirectories == 1 and dataDirectories[1] == "deep")
assert(file.Delete("empty/deep"))
assert(not file.Exists("empty/deep", "DATA"))

assert(file.Rename("rename_me.txt", "renamed/result.txt"))
assert(not file.Exists("rename_me.txt", "DATA"))
assert(file.Read("renamed/result.txt") == "from-lower-mount")

assert(file.Delete("legacy.txt"))
assert(not file.Exists("legacy.txt", "DATA"))
assert(file.Delete("lower_empty_deleted"))
assert(not file.Exists("lower_empty_deleted", "DATA"))
assert(file.Delete("lower_empty_recreated"))
assert(file.Write("lower_empty_recreated/new.txt", "reborn"))
assert(file.Read("lower_empty_recreated/new.txt") == "reborn")
local rootFiles = file.Find("*", "DATA")
for _, name in ipairs(rootFiles) do assert(name ~= "legacy.txt") end

local invalidFiles, invalidDirectories = file.Find("../*", "GAME")
assert(invalidFiles == nil and invalidDirectories == nil)
assert(file.Read("../secret.txt", "GAME") == nil)
assert(not file.Write("../escape.txt", "no"))
assert(not file.Delete("lua/includes/init.lua", "GAME"))

GLUA_FILE_LIBRARY_REGRESSION_OK = true
