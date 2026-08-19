-- Original synthetic fixture for the host-backed engine.GetGames boundary.
assert(type(engine) == "table")
assert(type(engine.GetGames) == "function")
assert(type(engine.IsPlayingDemo) == "function")
assert(type(engine.IsRecordingDemo) == "function")
assert(engine.IsPlayingDemo() == false)
assert(engine.IsRecordingDemo() == true)

local games = engine.GetGames()
assert(type(games) == "table")
assert(#games == 2)

assert(games[1].depot == 220)
assert(games[1].title == "Half-Life 2")
assert(games[1].folder == "hl2")
assert(games[1].owned == true)
assert(games[1].installed == true)
assert(games[1].mounted == true)

assert(games[2].depot == 240)
assert(games[2].folder == "cstrike")
assert(games[2].owned == false)
assert(games[2].installed == false)
assert(games[2].mounted == false)

-- Results are caller-owned snapshots, not aliases of host state.
games[1].title = "changed by Lua"
games[2] = nil
local again = engine.GetGames()
assert(#again == 2)
assert(again[1].title == "Half-Life 2")
assert(again[2].folder == "cstrike")

GLUA_ENGINE_GAMES_REGRESSION_OK = true
