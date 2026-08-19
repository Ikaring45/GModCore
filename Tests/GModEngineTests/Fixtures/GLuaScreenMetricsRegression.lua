-- Synthetic screen-metrics regression; no game source is embedded here.
assert(type(ScrW) == "function")
assert(type(ScrH) == "function")
assert(type(ScreenScale) == "function")
assert(type(ScreenScaleH) == "function")
assert(SScale == ScreenScale)

assert(ScrW() == 1600)
assert(ScrH() == 900)
assert(ScreenScale(64) == 160)
assert(ScreenScaleH(48) == 90)
assert(SScale(64) == 160)
assert(ScreenScale("32") == 80)

local ok = pcall(ScreenScale)
assert(not ok)
ok = pcall(ScreenScaleH, {})
assert(not ok)

GLUA_SCREEN_METRICS_REGRESSION_OK = true
