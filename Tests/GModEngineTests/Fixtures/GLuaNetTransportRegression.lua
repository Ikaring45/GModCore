-- Synthetic, project-authored probe for the native net transport boundary.
-- Production loads Garry's Mod's own extensions/net.lua; this fixture keeps
-- only the documented dispatch contract needed for deterministic XCTest.
net.Receivers = {}

function net.Receive(name, callback)
    net.Receivers[string.lower(name)] = callback
end

function net.Incoming(length, sender)
    local message_id = net.ReadHeader()
    local message_name = util.NetworkIDToString(message_id)
    assert(message_name ~= nil, "incoming NetworkString id was not pooled")
    local callback = net.Receivers[string.lower(message_name)]
    if callback ~= nil then
        callback(length - 16, sender)
    end
end

net.WriteBool = net.WriteBit
net.ReadBool = function() return net.ReadBit() == 1 end

net.Receive("TTT_RoundState", function(length, sender)
    ROUND_STATE_LENGTH = length
    ROUND_STATE_SENDER = sender
    ROUND_STATE_BYTES_LEFT, ROUND_STATE_BITS_LEFT = net.BytesLeft()
    ROUND_STATE_RECEIVED = net.ReadUInt(3)
    ROUND_STATE_FINAL_BYTES, ROUND_STATE_FINAL_BITS = net.BytesLeft()
end)

DISCARDED_RECEIVER_COUNT = 0
net.Receive("discarded_message", function()
    DISCARDED_RECEIVER_COUNT = DISCARDED_RECEIVER_COUNT + 1
end)

net.Receive("bit_mix", function(length)
    MIX_LENGTH = length
    MIX_A = net.ReadBit()
    MIX_B = net.ReadBit()
    MIX_C = net.ReadUInt(3)
    MIX_D = net.ReadUInt(8)
end)

net.Receive("receiver_error", function()
    assert(net.ReadUInt(3) == 6)
    error("intentional receiver failure")
end)

net.Receive("after_error", function()
    AFTER_ERROR_VALUE = net.ReadUInt(3)
end)

net.Receive("codec_mix", function(length)
    CODEC_LENGTH = length
    CODEC_PREFIX_BIT = net.ReadBit()
    CODEC_INT_ENCODED = net.ReadUInt(4)
    CODEC_INT_DECODED = net.ReadInt(4)
    CODEC_FLOAT_BITS = net.ReadUInt(32)
    CODEC_FLOAT_VALUE = net.ReadFloat()
    CODEC_NEGATIVE_ZERO = net.ReadFloat()
    CODEC_INFINITY = net.ReadFloat()
    CODEC_NAN = net.ReadFloat()
    CODEC_STRING = net.ReadString()
    CODEC_DATA = net.ReadData(4)
    CODEC_FINAL_BIT = net.ReadBit()
    CODEC_FINAL_BYTES, CODEC_FINAL_BITS = net.BytesLeft()
end)

net.Receive("signed_widths", function()
    for bits = 1, 32 do
        local magnitude = 2 ^ (bits - 1)
        assert(net.ReadInt(bits) == -magnitude)
        assert(net.ReadInt(bits) == magnitude - 1)
    end
    SIGNED_WIDTHS_RECEIVED = true
end)

net.Receive("data_default_length", function()
    DATA_DEFAULT_PREFIX = net.ReadBit()
    DATA_DEFAULT = net.ReadData(3)
end)

net.Receive("read_int_underflow", function()
    net.ReadInt(2)
end)

net.Receive("read_float_underflow", function()
    net.ReadFloat()
end)

net.Receive("read_data_underflow", function()
    net.ReadData(2)
end)

net.Receive("read_string_unterminated", function()
    net.ReadString()
end)

net.Receive("concurrent_pump", function()
    TEST_CONCURRENT_PUMP_GATE()
    CONCURRENT_PUMP_COUNT = (CONCURRENT_PUMP_COUNT or 0) + 1
end)

return true
