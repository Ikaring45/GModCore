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

local function validateRequest(value)
    if not hasExactKeys(value, {
        "schema", "request_id", "model_path", "phy_path",
        "expected_mdl_sha256", "expected_phy_sha256", "ownership_reference",
        "policy", "limits"
    }) then return nil, "request shape" end
    if value.schema ~= 1 or value.request_id ~= requestID then return nil, "request identity" end
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
local result = {
    schema = 1,
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
        schema = 1,
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

local function writeAndQuit(value)
    if IsValid(spawnedEntity) then spawnedEntity:Remove() end
    spawnedEntity = nil
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

local function finishSuccess()
    if completed then return end
    completed = true
    result.finish_reason = "vphysics-attestation-complete"
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
        checksum = checksum
    }
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
    end, debug.traceback)
    if not ok then finishFailure(message) else finishSuccess() end
end

timer.Simple(request.limits.timeout_seconds, function()
    finishFailure("probe timeout")
end)
hook.Add("InitPostEntity", "GarrysPAD.SourceVPhysicsAttestation.Start", function()
    hook.Remove("InitPostEntity", "GarrysPAD.SourceVPhysicsAttestation.Start")
    timer.Simple(0, runProbe)
end)
