if not util or not util.AddNetworkString or not net or not net.Receive then return end
if not file or not concommand then return end

AddCSLuaFile("autorun/client/garryspad_source_client_oracle.lua")

local expectedRunID = string.Trim(file.Read("garryspad_oracle_client/run_token.txt", "LUA") or "")
if #expectedRunID ~= 32 or string.find(expectedRunID, "[^0-9a-f]") then return end

local commandName = "garryspad_source_client_oracle_run"
local armed = false
concommand.Add(commandName, function(_, _, arguments)
    if armed then return end
    if #arguments ~= 1 or arguments[1] ~= expectedRunID then return end
    armed = true
    concommand.Remove(commandName)

    util.AddNetworkString("garryspad_oracle_ping")
    util.AddNetworkString("garryspad_oracle_reply")

    net.Receive("garryspad_oracle_ping", function(bitLength, player)
        local unsigned = net.ReadUInt(8)
        local signed = net.ReadInt(8)
        local floatValue = net.ReadFloat()
        local nulString = net.ReadString()
        local vector = net.ReadVector()
        local angle = net.ReadAngle()
        local color = net.ReadColor(true)

        net.Start("garryspad_oracle_reply")
        net.WriteUInt(bitLength, 16)
        net.WriteUInt(unsigned, 8)
        net.WriteInt(signed, 8)
        net.WriteFloat(floatValue)
        net.WriteString(nulString)
        net.WriteVector(vector)
        net.WriteAngle(angle)
        net.WriteColor(color, true)
        net.WriteEntity(player)
        net.Send(player)
    end)
end)
