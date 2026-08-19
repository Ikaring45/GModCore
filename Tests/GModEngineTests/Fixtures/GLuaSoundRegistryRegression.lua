assert(type(sound) == "table")

assert(CHAN_REPLACE == -1)
assert(CHAN_AUTO == 0)
assert(CHAN_WEAPON == 1)
assert(CHAN_VOICE == 2)
assert(CHAN_ITEM == 3)
assert(CHAN_BODY == 4)
assert(CHAN_STREAM == 5)
assert(CHAN_STATIC == 6)
assert(CHAN_VOICE2 == 7)
assert(CHAN_VOICE_BASE == 8)
assert(CHAN_USER_BASE == 136)

-- Sound is the stock identity helper, not a decoded audio object.
local cue = "TTT.MessageCue"
assert(Sound(cue) == cue)

-- Original synthetic fixture shaped after the public SoundData contract.
sound.Add({
    name = "TTT.MessageCue",
    channel = CHAN_STATIC,
    volume = 1.0,
    pitch = 100,
    sound = "fixtures/logical-message-cue.wav"
})

local properties = sound.GetProperties("TTT.MessageCue")
assert(properties.name == "TTT.MessageCue")
assert(properties.channel == CHAN_STATIC)
assert(properties.level == 75)
assert(properties.volume == 1)
assert(properties.pitch == 100)
assert(properties.pitchstart == 100)
assert(properties.pitchend == 100)
assert(properties.sound == "fixtures/logical-message-cue.wav")

-- Returned property tables are snapshots, not aliases to host registry state.
properties.sound = "mutated.wav"
assert(sound.GetProperties("TTT.MessageCue").sound == "fixtures/logical-message-cue.wav")
assert(sound.GetProperties("not.registered") == nil)

sound.Add({
    name = "Synthetic.Range",
    channel = CHAN_AUTO,
    level = 80,
    volume = { 0.25, 0.75 },
    pitch = { 90, 110 },
    pitchstart = 95,
    pitchend = 105,
    sound = { "one.wav", "two.wav" }
})

local ranged = sound.GetProperties("Synthetic.Range")
assert(ranged.volume[1] == 0.25 and ranged.volume[2] == 0.75)
assert(ranged.pitch[1] == 90 and ranged.pitch[2] == 110)
assert(ranged.sound[1] == "one.wav" and ranged.sound[2] == "two.wav")

-- Override keeps one registration slot while replacing properties.
sound.Add({
    name = "TTT.MessageCue",
    channel = CHAN_ITEM,
    sound = "fixtures/replaced-message-cue.wav"
})
assert(sound.GetProperties("TTT.MessageCue").channel == CHAN_ITEM)
assert(sound.GetProperties("TTT.MessageCue").sound == "fixtures/replaced-message-cue.wav")

local names = sound.GetTable()
assert(#names == 2)
assert(names[1] == "TTT.MessageCue")
assert(names[2] == "Synthetic.Range")

sound.Play("TTT.MessageCue", Vector(1, 2, 3), 80, 120, 0.5, 4)
sound.Play("Synthetic.Range", Vector(-4, 5, 6))

GLUA_SOUND_REGRESSION_READY = true
