if CLIENT then return end
if not hook or not file or not concommand or not include then return end

local contextKey = "GarrysPAD_SourceOracleLaunchContext"
local launchContext = rawget(_G, contextKey)
if not launchContext then
    local expectedRunID = string.Trim(file.Read("garryspad_oracle/run_token.txt", "LUA") or "")
    if #expectedRunID ~= 32 or string.find(expectedRunID, "[^0-9a-f]") then return end

    local commandName = "garryspad_source_oracle_run"
    local launched = false
    concommand.Add(commandName, function(_, _, arguments)
        if launched then return end
        if #arguments ~= 1 or arguments[1] ~= expectedRunID then return end
        launched = true
        concommand.Remove(commandName)
        rawset(_G, contextKey, { run_id = expectedRunID })
        local ok, message = pcall(include, "autorun/garryspad_source_oracle.lua")
        rawset(_G, contextKey, nil)
        if not ok then ErrorNoHalt("[GarrysPAD Source Oracle] launch failed: " .. tostring(message) .. "\n") end
    end)
    return
end
rawset(_G, contextKey, nil)

local runID = tostring(launchContext.run_id or "")
if #runID ~= 32 or string.find(runID, "[^0-9a-f]") then return end

local hookPrefix = "GarrysPAD.SourceOracle."
local completed = false
local result = {
    schema = 1,
    enabled = true,
    command_line_enabled = true,
    run_id = runID,
    command_line_run_id = runID,
    realm = "SERVER",
    runtime = {},
    clock = {},
    callback_sequence = {},
    entities = {},
    traces = {},
    filesystem = {},
    material = {}
}

local function vec(value)
    if not value then return nil end
    return { x = value.x, y = value.y, z = value.z }
end

local function traceRecord(trace)
    return {
        fraction = trace.Fraction,
        fraction_left_solid = trace.FractionLeftSolid,
        hit = trace.Hit,
        hit_world = trace.HitWorld,
        start_solid = trace.StartSolid,
        all_solid = trace.AllSolid,
        contents = trace.Contents,
        hit_pos = vec(trace.HitPos),
        hit_normal = vec(trace.HitNormal),
        normal = vec(trace.Normal),
        entity_index = IsValid(trace.Entity) and trace.Entity:EntIndex() or -1,
        entity_class = IsValid(trace.Entity) and trace.Entity:GetClass() or "NULL"
    }
end

local function protectedMethod(object, methodName)
    local method = object[methodName]
    local ok, value = pcall(method, object)
    local record = {
        ok = ok,
        type = type(value)
    }
    if ok then
        record.value = tostring(value)
    else
        record.error = tostring(value)
    end
    return record
end

local function finish(reason)
    if completed then return end
    completed = true

    hook.Remove("Tick", hookPrefix .. "Tick")
    hook.Remove("Think", hookPrefix .. "Think")
    if IsValid(result._think_entity) then result._think_entity:Remove() end
    result._think_entity = nil
    result.finish_reason = reason
    result.clock.finish_cur_time = CurTime()
    result.clock.finish_tick_interval = engine.TickInterval()

    file.CreateDir("garryspad_oracle")
    local relativePath = "garryspad_oracle/latest.json"
    local encoded = util.TableToJSON(result, true)
    if not encoded then
        ErrorNoHalt("[GarrysPAD Oracle] util.TableToJSON failed\n")
        return
    end
    file.Write(relativePath, encoded)
    print("[GarrysPAD Oracle] RESULT data/" .. relativePath)

    timer.Simple(0.5, function()
        game.ConsoleCommand("quit\n")
    end)
end

local function addSequence(name)
    if completed or #result.callback_sequence >= 32 then return end
    table.insert(result.callback_sequence, {
        name = name,
        cur_time = CurTime(),
        frame_time = FrameTime(),
        real_time = RealTime()
    })
    if #result.callback_sequence >= 16 then
        timer.Simple(0, function() finish("sequence-complete") end)
    end
end

hook.Add("InitPostEntity", hookPrefix .. "Start", function()
    hook.Remove("InitPostEntity", hookPrefix .. "Start")
    timer.Simple(6, function() finish("timeout") end)

    local probesOK, probesError = xpcall(function()

    result.runtime.version = VERSION
    result.runtime.version_string = VERSIONSTR
    result.runtime.branch = BRANCH
    result.runtime.is_windows = system.IsWindows()
    result.runtime.jit_arch = jit and jit.arch or "none"
    result.runtime.map = game.GetMap()

    result.clock.start_cur_time = CurTime()
    result.clock.frame_time = FrameTime()
    result.clock.tick_interval = engine.TickInterval()

    local null = Entity(-1)
    local world = Entity(0)
    result.entities.null_equals_NULL = null == NULL
    result.entities.null_is_valid = IsValid(null)
    result.entities.null_ent_index = protectedMethod(null, "EntIndex")
    result.entities.null_class = protectedMethod(null, "GetClass")
    result.entities.null_tostring = tostring(null)
    result.entities.world_is_valid = IsValid(world)
    result.entities.world_ent_index = world:EntIndex()
    result.entities.world_class = world:GetClass()

    local first = ents.Create("base_anim")
    first:Spawn()
    local firstIndex = first:EntIndex()
    first:Remove()
    local second = ents.Create("base_anim")
    second:Spawn()
    result.entities.removed_index = firstIndex
    result.entities.next_index = second:EntIndex()
    result.entities.immediate_index_reuse = firstIndex == second:EntIndex()
    second:Remove()

    local box = ents.Create("base_anim")
    box:SetPos(Vector(0, 0, 256))
    box:SetMoveType(MOVETYPE_NONE)
    box:SetSolid(SOLID_BBOX)
    box:Spawn()
    box:SetCollisionBounds(Vector(-16, -16, -16), Vector(16, 16, 16))
    box:CollisionRulesChanged()

    result.traces.line = traceRecord(util.TraceLine({
        start = Vector(-64, 0, 256),
        endpos = Vector(64, 0, 256),
        mask = MASK_SOLID
    }))
    result.traces.hull = traceRecord(util.TraceHull({
        start = Vector(-64, 0, 256),
        endpos = Vector(64, 0, 256),
        mins = Vector(-4, -4, -4),
        maxs = Vector(4, 4, 4),
        mask = MASK_SOLID
    }))
    result.traces.start_inside = traceRecord(util.TraceLine({
        start = Vector(0, 0, 256),
        endpos = Vector(64, 0, 256),
        mask = MASK_SOLID
    }))
    result.traces.all_inside = traceRecord(util.TraceLine({
        start = Vector(0, 0, 256),
        endpos = Vector(8, 0, 256),
        mask = MASK_SOLID
    }))
    box:Remove()

    result.filesystem.game_case_probe = file.Read(
        "LUA/GARRYSPAD_ORACLE/CASEPROBE.TXT",
        "GAME"
    )
    result.filesystem.lua_case_probe = file.Read(
        "garryspad_oracle/caseprobe.txt",
        "LUA"
    )
    local foundFiles, foundDirectories = file.Find("garryspad_oracle/*", "LUA")
    result.filesystem.find_files = foundFiles
    result.filesystem.find_directories = foundDirectories

    local material = Material("models/debug/debugwhite")
    result.material.is_error = material:IsError()
    result.material.name = material:GetName()
    result.material.shader = material:GetShader()
    result.material.width = material:Width()
    result.material.height = material:Height()

    local thinkerDefinition = {
        Type = "anim",
        Base = "base_anim",
        PrintName = "Garry's PAD Oracle Thinker"
    }
    thinkerDefinition.Initialize = function(self)
        self:SetMoveType(MOVETYPE_NONE)
        self:SetSolid(SOLID_NONE)
        self:NextThink(CurTime())
    end
    thinkerDefinition.Think = function(self)
        addSequence("entity_think")
        self:NextThink(CurTime())
        return true
    end
    scripted_ents.Register(thinkerDefinition, "garryspad_oracle_thinker")

    local thinker = ents.Create("garryspad_oracle_thinker")
    thinker:SetPos(Vector(0, 0, 512))
    thinker:Spawn()
    thinker:NextThink(CurTime())
    result._think_entity = thinker

    hook.Add("Tick", hookPrefix .. "Tick", function()
        addSequence("hook_tick")
    end)
    hook.Add("Think", hookPrefix .. "Think", function()
        addSequence("hook_think")
    end)

    end, debug.traceback)

    if not probesOK then
        result.probe_error = probesError
        finish("probe-error")
    end
end)
