if CLIENT then return end
if not file or not util or not concommand or not hook or not timer then return end

-- This probe is intentionally not connected to a launcher. A future runner
-- must first prove that installed addons/user Lua and network access are
-- disabled, then copy this fixed tree plus generated request/token files into
-- its handle-owned mount. Loading the addon alone never runs the probe.

local contextKey = "GarrysPAD_SourceVPhysicsAttestationLaunchContext"
local requestPath = "garryspad_vphysics_attestation/request.json"
local tokenPath = "garryspad_vphysics_attestation/run_token.txt"
local commandName = "garryspad_source_vphysics_attestation_run"
local launchContext = rawget(_G, contextKey)

local function validHex(value, count)
    return type(value) == "string" and #value == count and
        not string.find(value, "[^0-9a-f]")
end

local function readBoundedLUA(path, maximumBytes)
    local handle = file.Open(path, "rb", "LUA")
    if not handle then return nil end
    local size = handle:Size()
    if type(size) ~= "number" or size % 1 ~= 0 or size < 1 or size > maximumBytes then
        handle:Close()
        return nil
    end
    local bytes = handle:Read(size)
    handle:Close()
    if type(bytes) ~= "string" or #bytes ~= size then return nil end
    return bytes
end

local function loadSmallRequest()
    local encoded = readBoundedLUA(requestPath, 65536)
    if type(encoded) ~= "string" or #encoded < 2 then return nil end
    local value = util.JSONToTable(encoded)
    if type(value) ~= "table" or not validHex(value.request_id, 32) then return nil end
    return value
end

if not launchContext then
    local expectedRunID = string.Trim(readBoundedLUA(tokenPath, 64) or "")
    local request = loadSmallRequest()
    if not validHex(expectedRunID, 32) or not request then return end

    local launched = false
    concommand.Add(commandName, function(_, _, arguments)
        if launched then return end
        if #arguments ~= 2 or arguments[1] ~= expectedRunID or
            arguments[2] ~= request.request_id then return end
        launched = true
        concommand.Remove(commandName)
        rawset(_G, contextKey, {
            run_id = expectedRunID,
            request_id = request.request_id
        })
        local ok, message = pcall(
            include,
            "autorun/server/garryspad_source_vphysics_attestation.lua"
        )
        rawset(_G, contextKey, nil)
        if not ok then
            ErrorNoHalt("[GarrysPAD VPhysics Attestation] launch failed: " ..
                tostring(message) .. "\n")
        end
    end)
    return
end
rawset(_G, contextKey, nil)

local runID = tostring(launchContext.run_id or "")
local requestID = tostring(launchContext.request_id or "")
if not validHex(runID, 32) or not validHex(requestID, 32) then return end

local hardCaps = {
    maximum_mdl_bytes = 33554432,
    maximum_phy_bytes = 33554432,
    maximum_solids = 64,
    maximum_convexes = 1024,
    maximum_vertices_per_convex = 16384,
    maximum_total_vertices = 65536,
    maximum_result_bytes = 8388608,
    timeout_seconds = 60
}

local function isInteger(value, minimum, maximum)
    return type(value) == "number" and value == value and value ~= math.huge and
        value ~= -math.huge and value % 1 == 0 and value >= minimum and value <= maximum
end

local function isFinite(value)
    return type(value) == "number" and value == value and
        value ~= math.huge and value ~= -math.huge
end

local function hasExactKeys(value, names)
    if type(value) ~= "table" then return false end
    local expected = {}
    for _, name in ipairs(names) do expected[name] = true end
    local count = 0
    for name in pairs(value) do
        if not expected[name] then return false end
        count = count + 1
    end
    return count == #names
end

local function validLogicalPath(value, extension)
    if type(value) ~= "string" or #value < 12 or #value > 240 then return false end
    if value ~= string.lower(value) or string.sub(value, 1, 7) ~= "models/" then return false end
    if string.sub(value, -#extension) ~= extension or string.find(value, "\\", 1, true) then
        return false
    end
    if string.find(value, "//", 1, true) or string.find(value, "/../", 1, true) or
        string.find(value, "/./", 1, true) then return false end
    return string.match(value, "^models/[a-z0-9_./%-]+%.[a-z]+$") ~= nil
end

local fixedSurfaceInputs = {
    {
        path = "sourceengine/scripts/surfaceproperties_manifest.txt",
        sha256 = "d8bead334f07cd9f7cdfa30d691076b242ee469727aa0f0dcb734f3699d92a11"
    },
    {
        path = "sourceengine/scripts/surfaceproperties.txt",
        sha256 = "b75f463e4a5b351c0f9a155c100659ae0384003ae910d092a07398e611056e32"
    },
    {
        path = "sourceengine/scripts/surfaceproperties_hl2.txt",
        sha256 = "6eb6c622f9d566515d0909d610c6f7213d327ed69545807696d74162ee3c0280"
    }
}

local function exactIntegerVector(value, x, y, z)
    return hasExactKeys(value, { "x", "y", "z" }) and
        value.x == x and value.y == y and value.z == z
end

local function validateSurfaceProbe(value)
    if not hasExactKeys(value, {
        "schema", "provenance", "requested_surface_names", "world_traces",
        "controlled_pair"
    }) or value.schema ~= 1 then return false end
    local provenance = value.provenance
    if not hasExactKeys(provenance, {
        "app_id", "branch", "build_id", "request_id", "vphysics",
        "surface_inputs", "map"
    }) or provenance.app_id ~= 4020 or provenance.branch ~= "x86-64" or
        provenance.build_id ~= "24721267" or provenance.request_id ~= requestID then
        return false
    end
    if not hasExactKeys(provenance.vphysics, { "path", "sha256" }) or
        provenance.vphysics.path ~= "bin/win64/vphysics.dll" or
        provenance.vphysics.sha256 ~=
            "4ebd6149f885dfc518a44dd32dda64cbd6ebb3f938d43bdead70e80771b7e414" then
        return false
    end
    if not hasExactKeys(provenance.map, { "path", "sha256" }) or
        provenance.map.path ~= "garrysmod/maps/gm_flatgrass.bsp" or
        provenance.map.sha256 ~=
            "4dfd95ecb8f77a093e3079697b04c5be5675e8595c05639aaf57ad1541024d76" then
        return false
    end
    if type(provenance.surface_inputs) ~= "table" or
        #provenance.surface_inputs ~= #fixedSurfaceInputs then return false end
    for index, expected in ipairs(fixedSurfaceInputs) do
        local actual = provenance.surface_inputs[index]
        if not hasExactKeys(actual, { "path", "sha256" }) or
            actual.path ~= expected.path or actual.sha256 ~= expected.sha256 then
            return false
        end
    end
    if type(value.requested_surface_names) ~= "table" or
        #value.requested_surface_names ~= 2 or
        value.requested_surface_names[1] ~= "plastic" or
        value.requested_surface_names[2] ~= "rubber" then return false end
    if type(value.world_traces) ~= "table" or #value.world_traces ~= 2 then
        return false
    end
    local traces = {
        { id = "flatgrass-center", x = 0, y = 0 },
        { id = "flatgrass-offset", x = 1024, y = 1024 }
    }
    for index, expected in ipairs(traces) do
        local actual = value.world_traces[index]
        if not hasExactKeys(actual, { "id", "start", "end" }) or
            actual.id ~= expected.id or
            not exactIntegerVector(actual.start, expected.x, expected.y, 4096) or
            not exactIntegerVector(actual["end"], expected.x, expected.y, -4096) then
            return false
        end
    end
    local pair = value.controlled_pair
    return hasExactKeys(pair, {
        "pair_id", "moving_surface_name", "fixed_surface_name",
        "anchor_trace_id", "separation_units", "impact_speed_units_per_second",
        "sample_delay_milliseconds", "maximum_friction_snapshots"
    }) and pair.pair_id == "plastic-against-rubber" and
        pair.moving_surface_name == "plastic" and
        pair.fixed_surface_name == "rubber" and
        pair.anchor_trace_id == "flatgrass-center" and
        pair.separation_units == 256 and pair.impact_speed_units_per_second == 128 and
        pair.sample_delay_milliseconds == 50 and pair.maximum_friction_snapshots == 16
end

local function validateRequest(value)
    if not hasExactKeys(value, {
        "schema", "request_id", "model_path", "phy_path",
        "expected_mdl_sha256", "expected_phy_sha256", "ownership_reference",
        "policy", "limits", "surface_probe"
    }) then return nil, "request shape" end
    if value.schema ~= 2 or value.request_id ~= requestID then return nil, "request identity" end
    if not validLogicalPath(value.model_path, ".mdl") or
        not validLogicalPath(value.phy_path, ".phy") or
        value.phy_path ~= string.sub(value.model_path, 1, -5) .. ".phy" then
        return nil, "logical model paths"
    end
    if not validHex(value.expected_mdl_sha256, 64) or
        not validHex(value.expected_phy_sha256, 64) then return nil, "owned hashes" end
    if type(value.ownership_reference) ~= "string" or
        #value.ownership_reference < 1 or #value.ownership_reference > 128 then
        return nil, "ownership reference"
    end
    if not hasExactKeys(value.policy, {
        "search_path", "allow_workshop", "allow_installed_addons",
        "allow_user_lua", "allow_network"
    }) or value.policy.search_path ~= "GAME" or value.policy.allow_workshop ~= false or
        value.policy.allow_installed_addons ~= false or value.policy.allow_user_lua ~= false or
        value.policy.allow_network ~= false then return nil, "execution policy" end
    if not hasExactKeys(value.limits, {
        "maximum_mdl_bytes", "maximum_phy_bytes", "maximum_solids",
        "maximum_convexes", "maximum_vertices_per_convex",
        "maximum_total_vertices", "maximum_result_bytes", "timeout_seconds"
    }) then return nil, "limits shape" end
    local minimums = {
        maximum_mdl_bytes = 80, maximum_phy_bytes = 16, maximum_solids = 1,
        maximum_convexes = 1, maximum_vertices_per_convex = 3,
        maximum_total_vertices = 3, maximum_result_bytes = 4096,
        timeout_seconds = 5
    }
    for name, maximum in pairs(hardCaps) do
        if not isInteger(value.limits[name], minimums[name], maximum) then
            return nil, "limit " .. name
        end
    end
    if value.limits.maximum_vertices_per_convex > value.limits.maximum_total_vertices then
        return nil, "vertex limits"
    end
    if not validateSurfaceProbe(value.surface_probe) then
        return nil, "surface probe contract"
    end
    return value
end

local request, requestError = validateRequest(loadSmallRequest())
if not request then
    ErrorNoHalt("[GarrysPAD VPhysics Attestation] rejected request: " ..
        tostring(requestError) .. "\n")
    return
end

local completed = false
local spawnedEntity = nil
local spawnedEntities = {}
local result = {
    schema = 2,
    kind = "owned-model-vphysics-attestation",
    enabled = true,
    command_line_enabled = true,
    run_id = runID,
    command_line_run_id = runID,
    request_id = requestID,
    realm = "SERVER",
    model_path = request.model_path,
    phy_path = request.phy_path,
    policy = request.policy
}

local function smallFailure(reason)
    return {
        schema = 2,
        kind = "owned-model-vphysics-attestation",
        enabled = true,
        command_line_enabled = true,
        run_id = runID,
        command_line_run_id = runID,
        request_id = requestID,
        realm = "SERVER",
        finish_reason = "probe-error",
        model_path = request.model_path,
        phy_path = request.phy_path,
        probe_error = tostring(reason)
    }
end

local function appendSurfaceIssue(response, issue)
    if not response or type(issue) ~= "string" then return end
    for _, existing in ipairs(response.issues or {}) do
        if existing == issue then return end
    end
    response.issues[#response.issues + 1] = issue
end

local function writeJSONAndQuit(value)
    file.CreateDir("garryspad_vphysics_attestation")
    local encoded = util.TableToJSON(value, false)
    if type(encoded) ~= "string" or #encoded > request.limits.maximum_result_bytes then
        encoded = util.TableToJSON(smallFailure("result exceeds maximum_result_bytes"), false)
    end
    if type(encoded) == "string" and #encoded <= request.limits.maximum_result_bytes then
        file.Write("garryspad_vphysics_attestation/latest.json", encoded)
    end
    timer.Simple(0.25, function() game.ConsoleCommand("quit\n") end)
end

local function writeAndQuit(value)
    local expectedRemovals = #spawnedEntities
    for _, entity in ipairs(spawnedEntities) do
        if IsValid(entity) then entity:Remove() end
    end
    spawnedEntity = nil
    timer.Simple(0, function()
        local removed = 0
        for _, entity in ipairs(spawnedEntities) do
            if not IsValid(entity) then removed = removed + 1 end
        end
        if value.surface_response then
            value.surface_response.cleanup = {
                spawned_entity_count = expectedRemovals,
                removed_entity_count = removed,
                clean = removed == expectedRemovals
            }
            if removed ~= expectedRemovals then
                appendSurfaceIssue(value.surface_response, "cleanup-incomplete")
                value.surface_response.status = "partial"
                value.finish_reason = "vphysics-attestation-partial"
            end
        elseif removed ~= expectedRemovals then
            value = smallFailure("entity cleanup incomplete")
        end
        spawnedEntities = {}
        writeJSONAndQuit(value)
    end)
end

local function finishSuccess()
    if completed then return end
    completed = true
    if not result.surface_response or
        result.surface_response.status ~= "complete" then
        result.finish_reason = "vphysics-attestation-partial"
    else
        result.finish_reason = "vphysics-attestation-complete"
    end
    writeAndQuit(result)
end

local function finishFailure(reason)
    if completed then return end
    completed = true
    writeAndQuit(smallFailure(reason))
end

local function vectorRecord(value, field)
    if not value or not isFinite(value.x) or not isFinite(value.y) or
        not isFinite(value.z) then error(field .. " is not a finite Vector") end
    return { x = value.x, y = value.y, z = value.z }
end

local function angleRecord(value, field)
    if not value or not isFinite(value.p) or not isFinite(value.y) or
        not isFinite(value.r) then error(field .. " is not a finite Angle") end
    return { pitch = value.p, yaw = value.y, roll = value.r }
end

local function readBoundedGAME(path, maximumBytes)
    local handle = file.Open(path, "rb", "GAME")
    if not handle then error("missing GAME file " .. path) end
    local ok, value = pcall(function()
        local size = handle:Size()
        if not isInteger(size, 1, maximumBytes) then error("file size cap " .. path) end
        local bytes = handle:Read(size)
        if type(bytes) ~= "string" or #bytes ~= size then error("short read " .. path) end
        return bytes
    end)
    handle:Close()
    if not ok then error(value) end
    return value
end

local function int32LE(bytes, oneBasedOffset, field)
    local a, b, c, d = string.byte(bytes, oneBasedOffset, oneBasedOffset + 3)
    if not d then error("truncated " .. field) end
    local unsigned = a + b * 256 + c * 65536 + d * 16777216
    if unsigned >= 2147483648 then return unsigned - 4294967296 end
    return unsigned
end

local function validatePHYEnvelope(bytes)
    if #bytes < 16 then error("truncated phyheader_t") end
    local headerBytes = int32LE(bytes, 1, "phyheader_t.size")
    local identifier = int32LE(bytes, 5, "phyheader_t.id")
    local solidCount = int32LE(bytes, 9, "phyheader_t.solidCount")
    local checksum = int32LE(bytes, 13, "phyheader_t.checkSum")
    if headerBytes ~= 16 or identifier ~= 0 or
        not isInteger(solidCount, 1, request.limits.maximum_solids) then
        error("unsupported PHY envelope")
    end
    local cursor = 17
    for solidIndex = 1, solidCount do
        local byteCount = int32LE(bytes, cursor, "solid byte count")
        cursor = cursor + 4
        if not isInteger(byteCount, 1, request.limits.maximum_phy_bytes) or
            cursor + byteCount - 1 > #bytes then error("invalid PHY solid frame") end
        cursor = cursor + byteCount
    end
    if cursor > #bytes or string.byte(bytes, #bytes) ~= 0 then
        error("invalid PHY KeyValues tail")
    end
    return {
        header_byte_count = headerBytes,
        identifier = identifier,
        solid_count = solidCount,
        checksum = checksum,
        keyvalues_one_based_offset = cursor
    }
end

local function newSurfaceResponse()
    return {
        schema = 1,
        kind = "source-surface-material-response-attestation",
        status = "partial",
        provenance = request.surface_probe.provenance,
        surface_lookups = {},
        model_route = {},
        world_traces = {},
        controlled_pairs = {},
        collision_samples = {},
        cleanup = {
            spawned_entity_count = 0,
            removed_entity_count = 0,
            clean = false
        },
        issues = {}
    }
end

local function surfaceFloat(value)
    if not isFinite(value) then return nil end
    return string.format("%.9g", value)
end

local function surfaceVector(value)
    if not value or not isFinite(value.x) or not isFinite(value.y) or
        not isFinite(value.z) then return nil end
    return {
        x = string.format("%.9g", value.x),
        y = string.format("%.9g", value.y),
        z = string.format("%.9g", value.z)
    }
end

local function validSurfaceIndex(value)
    return isInteger(value, 0, 65535)
end

local function appendSurfaceRoute(response, stage, name, suppliedIndex)
    if type(name) ~= "string" or #name < 1 or #name > 128 then
        appendSurfaceIssue(response, "missing-" .. stage .. "-surface")
        return nil
    end
    local index = suppliedIndex
    if index == nil then index = util.GetSurfaceIndex(name) end
    if not validSurfaceIndex(index) then
        appendSurfaceIssue(response, "unknown-" .. stage .. "-surface")
        return nil
    end
    local reverse = util.GetSurfacePropName(index)
    if type(reverse) ~= "string" or reverse ~= name then
        appendSurfaceIssue(response, "reverse-mismatch-" .. stage)
        return nil
    end
    local record = {
        stage = stage,
        surface_name = name,
        surface_index = index,
        reverse_name = reverse
    }
    response.model_route[#response.model_route + 1] = record
    return record
end

local function recordRequestedSurfaces(response)
    local seenNames = {}
    local seenIndices = {}
    for _, name in ipairs(request.surface_probe.requested_surface_names) do
        if seenNames[name] then
            appendSurfaceIssue(response, "duplicate-requested-surface")
        else
            seenNames[name] = true
            local index = util.GetSurfaceIndex(name)
            if not validSurfaceIndex(index) then
                appendSurfaceIssue(response, "unknown-requested-surface-" .. name)
            elseif seenIndices[index] then
                appendSurfaceIssue(response, "duplicate-requested-surface-index")
            else
                seenIndices[index] = true
                local reverse = util.GetSurfacePropName(index)
                local data = util.GetSurfaceData(index)
                if type(reverse) ~= "string" or reverse ~= name then
                    appendSurfaceIssue(response, "reverse-mismatch-requested-" .. name)
                elseif type(data) ~= "table" or data.name ~= name then
                    appendSurfaceIssue(response, "missing-requested-surface-data-" .. name)
                else
                    local friction = surfaceFloat(data.friction)
                    local elasticity = surfaceFloat(data.elasticity)
                    local density = surfaceFloat(data.density)
                    local thickness = surfaceFloat(data.thickness)
                    local dampening = surfaceFloat(data.dampening)
                    if not friction or not elasticity or not density or not thickness or
                        not dampening or not isInteger(data.material, 0, 255) then
                        appendSurfaceIssue(response, "nonfinite-requested-surface-data-" .. name)
                    else
                        response.surface_lookups[#response.surface_lookups + 1] = {
                            requested_name = name,
                            surface_index = index,
                            reverse_name = reverse,
                            data = {
                                name = data.name,
                                friction_coefficient = friction,
                                elasticity = elasticity,
                                density = density,
                                thickness = thickness,
                                dampening = dampening,
                                material = data.material
                            }
                        }
                    end
                end
            end
        end
    end
end

local function extractPHYSurfaceName(phy, phyHeader, response)
    local tail = string.lower(string.sub(phy, phyHeader.keyvalues_one_based_offset))
    local matches = {}
    for name in string.gmatch(tail, '"surfaceprop"%s*"([^"%z]+)"') do
        matches[#matches + 1] = name
    end
    if #matches ~= 1 or not string.match(matches[1] or "", "^[a-z0-9_%-]+$") then
        appendSurfaceIssue(response,
            #matches == 0 and "missing-phy-surfaceprop" or "duplicate-phy-surfaceprop")
        return nil
    end
    return matches[1]
end

local function recordWorldTraces(response)
    local anchors = {}
    for _, definition in ipairs(request.surface_probe.world_traces) do
        local startPosition = Vector(
            definition.start.x, definition.start.y, definition.start.z
        )
        local endPosition = Vector(
            definition["end"].x, definition["end"].y, definition["end"].z
        )
        local trace = util.TraceLine({
            start = startPosition,
            endpos = endPosition,
            mask = MASK_SOLID_BRUSHONLY
        })
        local hitPosition = surfaceVector(trace.HitPos)
        local fraction = surfaceFloat(trace.Fraction)
        local index = trace.SurfaceProps
        local reverse = validSurfaceIndex(index) and util.GetSurfacePropName(index) or nil
        local surfaceData = validSurfaceIndex(index) and util.GetSurfaceData(index) or nil
        if trace.Hit ~= true or trace.HitWorld ~= true or not hitPosition or not fraction or
            type(trace.HitTexture) ~= "string" or #trace.HitTexture < 1 or
            #trace.HitTexture > 256 or type(reverse) ~= "string" or #reverse < 1 or
            #reverse > 128 or type(surfaceData) ~= "table" or
            surfaceData.name ~= reverse then
            appendSurfaceIssue(response, "invalid-world-trace-" .. definition.id)
        else
            response.world_traces[#response.world_traces + 1] = {
                id = definition.id,
                start = definition.start,
                ["end"] = definition["end"],
                hit = trace.Hit,
                hit_world = trace.HitWorld,
                hit_position = hitPosition,
                fraction = fraction,
                hit_texture = trace.HitTexture,
                surface_index = index,
                reverse_name = reverse,
                surface_data_name = surfaceData.name
            }
            anchors[definition.id] = trace.HitPos
        end
    end
    return anchors
end

local function appendCollisionSample(response, data)
    if type(data) ~= "table" or not validSurfaceIndex(data.OurSurfaceProps) or
        not validSurfaceIndex(data.TheirSurfaceProps) then
        appendSurfaceIssue(response, "missing-collision-surface-indices")
        return false
    end
    local ourName = util.GetSurfacePropName(data.OurSurfaceProps)
    local theirName = util.GetSurfacePropName(data.TheirSurfaceProps)
    if ourName ~= request.surface_probe.controlled_pair.moving_surface_name or
        theirName ~= request.surface_probe.controlled_pair.fixed_surface_name then
        appendSurfaceIssue(response, "controlled-pair-callback-mismatch")
        return false
    end
    local vectors = {
        hit_position = surfaceVector(data.HitPos),
        hit_normal = surfaceVector(data.HitNormal),
        hit_speed = surfaceVector(data.HitSpeed),
        our_old_velocity = surfaceVector(data.OurOldVelocity),
        their_old_velocity = surfaceVector(data.TheirOldVelocity),
        our_new_velocity = surfaceVector(data.OurNewVelocity),
        their_new_velocity = surfaceVector(data.TheirNewVelocity),
        our_old_angular_velocity = surfaceVector(data.OurOldAngularVelocity),
        their_old_angular_velocity = surfaceVector(data.TheirOldAngularVelocity)
    }
    local speed = surfaceFloat(data.Speed)
    local deltaTime = surfaceFloat(data.DeltaTime)
    for _, value in pairs(vectors) do
        if not value then
            appendSurfaceIssue(response, "nonfinite-collision-velocity")
            return false
        end
    end
    if not speed or not deltaTime then
        appendSurfaceIssue(response, "nonfinite-collision-scalar")
        return false
    end
    appendSurfaceRoute(response, "callback_our", ourName, data.OurSurfaceProps)
    appendSurfaceRoute(response, "callback_their", theirName, data.TheirSurfaceProps)
    response.collision_samples[#response.collision_samples + 1] = {
        sample_id = "controlled-pair-collision",
        pair_id = request.surface_probe.controlled_pair.pair_id,
        our_surface_index = data.OurSurfaceProps,
        their_surface_index = data.TheirSurfaceProps,
        our_surface_name = ourName,
        their_surface_name = theirName,
        hit_position = vectors.hit_position,
        hit_normal = vectors.hit_normal,
        hit_speed = vectors.hit_speed,
        our_old_velocity = vectors.our_old_velocity,
        their_old_velocity = vectors.their_old_velocity,
        our_new_velocity = vectors.our_new_velocity,
        their_new_velocity = vectors.their_new_velocity,
        our_old_angular_velocity = vectors.our_old_angular_velocity,
        their_old_angular_velocity = vectors.their_old_angular_velocity,
        speed = speed,
        delta_time = deltaTime
    }
    return true
end

local function recordFrictionSnapshots(
    response, physics, movingIndex, fixedIndex, reportMissing
)
    local snapshots = physics:GetFrictionSnapshot()
    if type(snapshots) ~= "table" then
        appendSurfaceIssue(response, "missing-friction-snapshots")
        return
    end
    local maximum = request.surface_probe.controlled_pair.maximum_friction_snapshots
    for _, snapshot in ipairs(snapshots) do
        if #response.controlled_pairs >= maximum then break end
        if type(snapshot) == "table" and snapshot.Material == movingIndex and
            snapshot.MaterialOther == fixedIndex then
            local coefficient = surfaceFloat(snapshot.FrictionCoefficient)
            local normalForce = surfaceFloat(snapshot.NormalForce)
            local energy = surfaceFloat(snapshot.EnergyAbsorbed)
            local normal = surfaceVector(snapshot.Normal)
            local contactPoint = surfaceVector(snapshot.ContactPoint)
            local movingName = util.GetSurfacePropName(snapshot.Material)
            local fixedName = util.GetSurfacePropName(snapshot.MaterialOther)
            if coefficient and normalForce and energy and normal and contactPoint and
                movingName == request.surface_probe.controlled_pair.moving_surface_name and
                fixedName == request.surface_probe.controlled_pair.fixed_surface_name then
                response.controlled_pairs[#response.controlled_pairs + 1] = {
                    pair_id = request.surface_probe.controlled_pair.pair_id,
                    snapshot_ordinal = #response.controlled_pairs,
                    material = snapshot.Material,
                    material_other = snapshot.MaterialOther,
                    material_name = movingName,
                    material_other_name = fixedName,
                    friction_coefficient = coefficient,
                    normal_force = normalForce,
                    energy_absorbed = energy,
                    normal = normal,
                    contact_point = contactPoint
                }
            else
                appendSurfaceIssue(response, "invalid-friction-snapshot")
            end
        end
    end
    if reportMissing and #response.controlled_pairs == 0 then
        appendSurfaceIssue(response, "missing-controlled-pair-friction")
    end
end

local function finalizeSurfaceResponse(response)
    if #response.issues == 0 and
        #response.surface_lookups == #request.surface_probe.requested_surface_names and
        #response.model_route == 5 and
        #response.world_traces == #request.surface_probe.world_traces and
        #response.controlled_pairs >= 1 and #response.collision_samples == 1 then
        response.status = "complete"
    else
        if #response.issues == 0 then
            appendSurfaceIssue(response, "surface-observation-incomplete")
        end
        response.status = "partial"
    end
    result.surface_response = response
    finishSuccess()
end

local function runProbe()
    local ok, message = xpcall(function()
        local mdl = readBoundedGAME(request.model_path, request.limits.maximum_mdl_bytes)
        local phy = readBoundedGAME(request.phy_path, request.limits.maximum_phy_bytes)
        local mdlSHA = string.lower(util.SHA256(mdl))
        local phySHA = string.lower(util.SHA256(phy))
        if mdlSHA ~= request.expected_mdl_sha256 or phySHA ~= request.expected_phy_sha256 then
            error("owned model SHA-256 mismatch")
        end
        if string.sub(mdl, 1, 4) ~= "IDST" then error("MDL magic is not IDST") end
        local mdlVersion = int32LE(mdl, 5, "studiohdr_t.version")
        local mdlChecksum = int32LE(mdl, 9, "studiohdr_t.checksum")
        if mdlVersion ~= 48 then error("MDL version is not 48") end
        local phyHeader = validatePHYEnvelope(phy)
        if phyHeader.checksum ~= mdlChecksum then error("MDL/PHY checksum mismatch") end

        local validModel = util.IsValidModel(request.model_path)
        local validProp = util.IsValidProp(request.model_path)
        if validModel ~= true or validProp ~= true then error("model is not a valid prop") end

        local entity = ents.Create("prop_physics")
        if not IsValid(entity) then error("prop_physics creation failed") end
        spawnedEntity = entity
        spawnedEntities[#spawnedEntities + 1] = entity
        entity:SetModel(request.model_path)
        entity:SetPos(Vector(0, 0, 0))
        entity:SetAngles(Angle(0, 0, 0))
        entity:Spawn()
        entity:Activate()
        if not IsValid(entity) then error("prop_physics spawn failed") end
        local physics = entity:GetPhysicsObject()
        if not IsValid(physics) then error("physics object 0 is invalid") end
        physics:EnableMotion(false)
        physics:SetPos(Vector(0, 0, 0), true)
        physics:SetAngles(Angle(0, 0, 0))

        local entityOrigin = vectorRecord(entity:GetPos(), "Entity:GetPos")
        local entityAngles = angleRecord(entity:GetAngles(), "Entity:GetAngles")
        local obbMinimum = vectorRecord(entity:OBBMins(), "Entity:OBBMins")
        local obbMaximum = vectorRecord(entity:OBBMaxs(), "Entity:OBBMaxs")
        local collisionMinimum, collisionMaximum = entity:GetCollisionBounds()
        local collisionMinimumRecord = vectorRecord(
            collisionMinimum,
            "Entity:GetCollisionBounds minimum"
        )
        local collisionMaximumRecord = vectorRecord(
            collisionMaximum,
            "Entity:GetCollisionBounds maximum"
        )
        if entityOrigin.x ~= 0 or entityOrigin.y ~= 0 or entityOrigin.z ~= 0 or
            entityAngles.pitch ~= 0 or entityAngles.yaw ~= 0 or entityAngles.roll ~= 0 then
            error("spawned entity transform differs from the fixed probe transform")
        end
        if obbMinimum.x > obbMaximum.x or obbMinimum.y > obbMaximum.y or
            obbMinimum.z > obbMaximum.z then error("reversed Entity OBB") end
        if collisionMinimumRecord.x > collisionMaximumRecord.x or
            collisionMinimumRecord.y > collisionMaximumRecord.y or
            collisionMinimumRecord.z > collisionMaximumRecord.z then
            error("reversed Entity collision bounds")
        end

        local meshConvexes = physics:GetMeshConvexes()
        if type(meshConvexes) ~= "table" or #meshConvexes < 1 or
            #meshConvexes > request.limits.maximum_convexes then
            error("GetMeshConvexes count is unavailable or capped")
        end
        local convexes = {}
        local verticesPerConvex = {}
        local totalVertices = 0
        local topologyParts = {}
        for convexIndex, convex in ipairs(meshConvexes) do
            if type(convex) ~= "table" or #convex < 3 or #convex % 3 ~= 0 or
                #convex > request.limits.maximum_vertices_per_convex then
                error("invalid convex triangle list")
            end
            totalVertices = totalVertices + #convex
            if totalVertices > request.limits.maximum_total_vertices then
                error("total convex vertices exceed cap")
            end
            verticesPerConvex[convexIndex] = #convex
            topologyParts[#topologyParts + 1] = "c" .. convexIndex .. ":" .. #convex .. ";"
            local outputConvex = {}
            for vertexIndex, vertex in ipairs(convex) do
                local position = vectorRecord(vertex.pos, "convex vertex")
                outputConvex[vertexIndex] = position
                topologyParts[#topologyParts + 1] = string.format(
                    "%.9g,%.9g,%.9g;", position.x, position.y, position.z
                )
            end
            convexes[convexIndex] = outputConvex
        end

        local minimum, maximum = physics:GetAABB()
        local minimumRecord = vectorRecord(minimum, "PhysObj:GetAABB minimum")
        local maximumRecord = vectorRecord(maximum, "PhysObj:GetAABB maximum")
        if minimumRecord.x > maximumRecord.x or minimumRecord.y > maximumRecord.y or
            minimumRecord.z > maximumRecord.z then error("reversed PhysObj AABB") end
        local centerOfMass = vectorRecord(physics:GetMassCenter(), "PhysObj:GetMassCenter")
        local inertia = vectorRecord(physics:GetInertia(), "PhysObj:GetInertia")
        if inertia.x < 0 or inertia.y < 0 or inertia.z < 0 then error("negative inertia") end
        local mass = physics:GetMass()
        if not isFinite(mass) or mass <= 0 then error("invalid PhysObj mass") end
        local material = physics:GetMaterial()
        if type(material) ~= "string" or #material < 1 or #material > 128 then
            error("invalid PhysObj material")
        end

        result.runtime = {
            version = VERSION,
            version_string = VERSIONSTR,
            branch = BRANCH,
            is_windows = system.IsWindows(),
            jit_arch = jit and jit.arch or "none",
            map = game.GetMap()
        }
        result.files = {
            mdl = {
                byte_count = #mdl,
                sha256 = mdlSHA,
                magic = "IDST",
                version = mdlVersion,
                checksum = mdlChecksum
            },
            phy = {
                byte_count = #phy,
                sha256 = phySHA,
                header_byte_count = phyHeader.header_byte_count,
                identifier = phyHeader.identifier,
                solid_count = phyHeader.solid_count,
                checksum = phyHeader.checksum
            }
        }
        result.validity = {
            util_is_valid_model = validModel,
            util_is_valid_prop = validProp
        }
        result.entity_collision = {
            origin = entityOrigin,
            angles = entityAngles,
            obb = { minimum = obbMinimum, maximum = obbMaximum },
            collision_bounds = {
                minimum = collisionMinimumRecord,
                maximum = collisionMaximumRecord
            }
        }
        result.physics = {
            object_index = 0,
            convex_count = #convexes,
            total_vertex_count = totalVertices,
            vertices_per_convex = verticesPerConvex,
            topology_sha256 = string.lower(util.SHA256(table.concat(topologyParts))),
            aabb = { minimum = minimumRecord, maximum = maximumRecord },
            center_of_mass = centerOfMass,
            inertia = inertia,
            mass = mass,
            material = material,
            convexes = convexes
        }

        local response = newSurfaceResponse()
        recordRequestedSurfaces(response)
        local anchors = recordWorldTraces(response)
        appendSurfaceRoute(response, "mdl_bone", entity:GetBoneSurfaceProp(0))
        local phySurface = extractPHYSurfaceName(phy, phyHeader, response)
        if phySurface then appendSurfaceRoute(response, "phy_solid", phySurface) end
        appendSurfaceRoute(response, "physobj", material)

        local pair = request.surface_probe.controlled_pair
        local anchor = anchors[pair.anchor_trace_id]
        if not anchor then
            appendSurfaceIssue(response, "missing-controlled-pair-anchor")
            finalizeSurfaceResponse(response)
            return
        end

        local fixedEntity = ents.Create("prop_physics")
        if not IsValid(fixedEntity) then
            appendSurfaceIssue(response, "fixed-pair-entity-create-failed")
            finalizeSurfaceResponse(response)
            return
        end
        spawnedEntities[#spawnedEntities + 1] = fixedEntity
        fixedEntity:SetModel(request.model_path)
        fixedEntity:SetPos(anchor + Vector(0, 0, 512))
        fixedEntity:SetAngles(Angle(0, 0, 0))
        fixedEntity:Spawn()
        fixedEntity:Activate()
        local fixedPhysics = fixedEntity:GetPhysicsObject()
        if not IsValid(fixedPhysics) then
            appendSurfaceIssue(response, "fixed-pair-physics-missing")
            finalizeSurfaceResponse(response)
            return
        end
        fixedPhysics:EnableGravity(false)
        fixedPhysics:EnableMotion(false)
        fixedPhysics:SetMaterial(pair.fixed_surface_name)
        fixedPhysics:SetPos(anchor + Vector(0, 0, 512), true)
        fixedPhysics:SetAngles(Angle(0, 0, 0))

        physics:EnableGravity(false)
        physics:EnableDrag(false)
        physics:SetMaterial(pair.moving_surface_name)
        physics:SetPos(
            anchor + Vector(0, 0, 512 + pair.separation_units),
            true
        )
        physics:SetAngles(Angle(0, 0, 0))

        local movingIndex = util.GetSurfaceIndex(pair.moving_surface_name)
        local fixedIndex = util.GetSurfaceIndex(pair.fixed_surface_name)
        if not validSurfaceIndex(movingIndex) or not validSurfaceIndex(fixedIndex) or
            util.GetSurfacePropName(movingIndex) ~= pair.moving_surface_name or
            util.GetSurfacePropName(fixedIndex) ~= pair.fixed_surface_name then
            appendSurfaceIssue(response, "controlled-pair-surface-resolution-failed")
            finalizeSurfaceResponse(response)
            return
        end

        local collisionCaptured = false
        entity:AddCallback("PhysicsCollide", function(_, collision)
            if completed or collisionCaptured or collision.HitEntity ~= fixedEntity then return end
            collisionCaptured = true
            local callbackOK, callbackError = xpcall(function()
                appendCollisionSample(response, collision)
                recordFrictionSnapshots(
                    response, physics, movingIndex, fixedIndex, false
                )
                if #response.controlled_pairs > 0 then
                    finalizeSurfaceResponse(response)
                    return
                end
                timer.Simple(pair.sample_delay_milliseconds / 1000, function()
                    if completed then return end
                    local sampleOK, sampleError = xpcall(function()
                        if not IsValid(physics) then
                            appendSurfaceIssue(response, "moving-pair-physics-removed")
                        else
                            recordFrictionSnapshots(
                                response, physics, movingIndex, fixedIndex, true
                            )
                        end
                        finalizeSurfaceResponse(response)
                    end, debug.traceback)
                    if not sampleOK then finishFailure(sampleError) end
                end)
            end, debug.traceback)
            if not callbackOK then finishFailure(callbackError) end
        end)
        physics:EnableMotion(true)
        physics:SetVelocityInstantaneous(
            Vector(0, 0, -pair.impact_speed_units_per_second)
        )
        physics:Wake()
    end, debug.traceback)
    if not ok then finishFailure(message) end
end

timer.Simple(request.limits.timeout_seconds, function()
    finishFailure("probe timeout")
end)
local started = false
local function startProbeOnce()
    if started then return end
    started = true
    hook.Remove("InitPostEntity", "GarrysPAD.SourceVPhysicsAttestation.Start")
    timer.Simple(0, runProbe)
end
hook.Add("InitPostEntity", "GarrysPAD.SourceVPhysicsAttestation.Start", startProbeOnce)

-- A +command placed after +map can be delivered after InitPostEntity has
-- already fired. Keep the event path as the primary route, but allow the same
-- token-authenticated command to start against an already-created world.
if IsValid(game.GetWorld()) and game.GetMap() ~= "" then
    timer.Simple(0.25, startProbeOnce)
end
