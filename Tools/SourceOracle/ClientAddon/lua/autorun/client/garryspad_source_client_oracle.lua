if not CLIENT or not hook or not vgui or not net or not net.Receive or not file then return end
if not concommand or not include then return end

local contextKey = "GarrysPAD_SourceClientOracleLaunchContext"
local launchContext = rawget(_G, contextKey)
if not launchContext then
    local expectedRunID = string.Trim(file.Read("garryspad_oracle_client/run_token.txt", "LUA") or "")
    if #expectedRunID ~= 32 or string.find(expectedRunID, "[^0-9a-f]") then return end

    local commandName = "garryspad_source_client_oracle_run"
    local launched = false
    concommand.Add(commandName, function(_, _, arguments)
        if launched then return end
        if #arguments ~= 1 or arguments[1] ~= expectedRunID then return end
        launched = true
        concommand.Remove(commandName)
        rawset(_G, contextKey, { run_id = expectedRunID })
        local ok, message = pcall(include, "autorun/client/garryspad_source_client_oracle.lua")
        rawset(_G, contextKey, nil)
        if not ok then ErrorNoHalt("[GarrysPAD Client Oracle] launch failed: " .. tostring(message) .. "\n") end
    end)
    return
end
rawset(_G, contextKey, nil)

local runID = tostring(launchContext.run_id or "")
if #runID ~= 32 or string.find(runID, "[^0-9a-f]") then return end

local hookPrefix = "GarrysPAD.SourceClientOracle."
local collecting = false
local completed = false
local gotNetworkReply = false
local panel

local result = {
    schema = 1,
    enabled = true,
    command_line_enabled = true,
    run_id = runID,
    command_line_run_id = runID,
    realm = "CLIENT",
    runtime = {},
    clock = {},
    entities = {},
    prediction_sequence = {},
    network = {},
    vgui = {},
    filesystem = {},
    material = {}
}

local function vec(value)
    return { x = value.x, y = value.y, z = value.z }
end

local function ang(value)
    return { pitch = value.p, yaw = value.y, roll = value.r }
end

local function colorRecord(value)
    return { r = value.r, g = value.g, b = value.b, a = value.a }
end

local function removeHooks()
    for _, name in ipairs({
        "CreateMove", "StartCommand", "SetupMove", "Move", "FinishMove",
        "PlayerTick", "Think", "Tick"
    }) do
        hook.Remove(name, hookPrefix .. name)
    end
end

local function finish(reason)
    if completed then return end
    completed = true
    collecting = false
    removeHooks()

    result.finish_reason = reason
    result.network.received_reply = gotNetworkReply
    result.clock.finish_cur_time = CurTime()
    result.clock.finish_frame_time = FrameTime()
    if IsValid(panel) then panel:Remove() end

    file.CreateDir("garryspad_oracle")
    local encoded = util.TableToJSON(result, true)
    if not encoded then
        ErrorNoHalt("[GarrysPAD Client Oracle] util.TableToJSON failed\n")
        return
    end
    file.Write("garryspad_oracle/client_latest.json", encoded)
    print("[GarrysPAD Client Oracle] RESULT data/garryspad_oracle/client_latest.json")
    timer.Simple(0.5, function() RunConsoleCommand("quit") end)
end

local function commandRecord(name, command)
    if not collecting or completed or #result.prediction_sequence >= 64 then return end
    local entry = {
        name = name,
        cur_time = CurTime(),
        frame_time = FrameTime(),
        first_time_predicted = IsFirstTimePredicted()
    }
    if command then
        entry.command_number = command:CommandNumber()
        entry.tick_count = command:TickCount()
        entry.buttons = command:GetButtons()
        entry.forward_move = command:GetForwardMove()
        entry.side_move = command:GetSideMove()
        entry.up_move = command:GetUpMove()
    end
    table.insert(result.prediction_sequence, entry)
end

hook.Add("CreateMove", hookPrefix .. "CreateMove", function(command)
    commandRecord("CreateMove", command)
end)
hook.Add("StartCommand", hookPrefix .. "StartCommand", function(_, command)
    commandRecord("StartCommand", command)
end)
hook.Add("SetupMove", hookPrefix .. "SetupMove", function(_, _, command)
    commandRecord("SetupMove", command)
end)
hook.Add("Move", hookPrefix .. "Move", function(_, _, command)
    commandRecord("Move", command)
end)
hook.Add("FinishMove", hookPrefix .. "FinishMove", function(_, _, command)
    commandRecord("FinishMove", command)
end)
hook.Add("PlayerTick", hookPrefix .. "PlayerTick", function()
    commandRecord("PlayerTick")
end)
hook.Add("Think", hookPrefix .. "Think", function()
    commandRecord("Think")
end)
hook.Add("Tick", hookPrefix .. "Tick", function()
    commandRecord("Tick")
end)

net.Receive("garryspad_oracle_reply", function(bitLength)
    gotNetworkReply = true
    result.network.reply_bit_length = bitLength
    result.network.server_received_bit_length = net.ReadUInt(16)
    result.network.unsigned = net.ReadUInt(8)
    result.network.signed = net.ReadInt(8)
    result.network.float = net.ReadFloat()
    result.network.nul_string = net.ReadString()
    result.network.vector = vec(net.ReadVector())
    result.network.angle = ang(net.ReadAngle())
    result.network.color = colorRecord(net.ReadColor(true))
    local echoedPlayer = net.ReadEntity()
    result.network.entity_index = IsValid(echoedPlayer) and echoedPlayer:EntIndex() or -1
end)

hook.Add("InitPostEntity", hookPrefix .. "InitPostEntity", function()
    hook.Remove("InitPostEntity", hookPrefix .. "InitPostEntity")

    local probesOK, probesError = xpcall(function()
        result.runtime.version = VERSION
        result.runtime.version_string = VERSIONSTR
        result.runtime.branch = BRANCH
        result.runtime.jit_arch = jit and jit.arch or "none"
        result.runtime.map = game.GetMap()
        result.runtime.single_player = game.SinglePlayer()

        result.clock.start_cur_time = CurTime()
        result.clock.frame_time = FrameTime()
        result.clock.real_frame_time = RealFrameTime()
        result.clock.tick_interval = engine.TickInterval()
        result.clock.first_time_predicted_outside_move = IsFirstTimePredicted()

        local localPlayer = LocalPlayer()
        result.entities.local_player_valid = IsValid(localPlayer)
        result.entities.local_player_index = IsValid(localPlayer) and localPlayer:EntIndex() or -1
        result.entities.world_valid = IsValid(Entity(0))
        result.entities.null_ent_index = NULL:EntIndex()

        result.filesystem.lua_case_probe = file.Read(
            "garryspad_oracle_client/caseprobe.txt",
            "LUA"
        )
        local files, directories = file.Find("garryspad_oracle_client/*", "LUA")
        result.filesystem.find_files = files
        result.filesystem.find_directories = directories

        local material = Material("models/debug/debugwhite")
        result.material.is_error = material:IsError()
        result.material.name = material:GetName()
        result.material.shader = material:GetShader()
        result.material.width = material:Width()
        result.material.height = material:Height()

        panel = vgui.Create("DPanel")
        panel:SetPos(13, 17)
        panel:SetSize(101, 53)
        local layoutCount = 0
        panel.PerformLayout = function(_, width, height)
            layoutCount = layoutCount + 1
            result.vgui.last_layout_width = width
            result.vgui.last_layout_height = height
        end
        result.vgui.layout_count_before = layoutCount
        panel:InvalidateLayout(true)
        result.vgui.layout_count_after_immediate = layoutCount
        panel:SetSize(103, 57)
        panel:InvalidateLayout(false)
        result.vgui.layout_count_after_deferred_request = layoutCount
        result.vgui.x, result.vgui.y = panel:GetPos()
        result.vgui.width, result.vgui.height = panel:GetSize()

        local label = vgui.Create("DLabel", panel)
        label:SetFont("DermaDefault")
        label:SetText("Garry's PAD 123")
        local measuredWidth, measuredHeight = surface.GetTextSize("Garry's PAD 123")
        result.vgui.surface_text_width = measuredWidth
        result.vgui.surface_text_height = measuredHeight
        label:SizeToContents()
        result.vgui.label_width, result.vgui.label_height = label:GetSize()

        timer.Simple(0, function()
            if completed then return end
            result.vgui.layout_count_after_deferred_tick = layoutCount
        end)

        net.Start("garryspad_oracle_ping")
        net.WriteUInt(0xA5, 8)
        net.WriteInt(-17, 8)
        net.WriteFloat(1 / 3)
        net.WriteString("oracle\0tail")
        net.WriteVector(Vector(1.25, -2.5, 3.75))
        net.WriteAngle(Angle(10.1, -20.2, 30.3))
        net.WriteColor(Color(1, 2, 3, 4), true)
        net.SendToServer()

        collecting = true
        timer.Simple(1.5, function()
            finish(gotNetworkReply and "complete" or "network-timeout")
        end)
    end, debug.traceback)

    if not probesOK then
        result.probe_error = probesError
        finish("probe-error")
    end
end)
