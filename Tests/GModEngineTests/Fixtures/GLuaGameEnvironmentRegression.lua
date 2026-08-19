assert(type(game) == "table")
assert(type(game.MaxPlayers) == "function")
assert(type(game.GetMap) == "function")
assert(type(game.SinglePlayer) == "function")
assert(type(game.IsDedicated) == "function")

assert(game.MaxPlayers() == 24)
assert(game.GetMap() == "ttt_minecraft_b5")
assert(game.SinglePlayer() == false)
assert(game.IsDedicated() == true)

GLUA_GAME_ENVIRONMENT_REGRESSION_OK = true
