local networking = {}

local objectLib = require "object"
local cubeModel = objectLib.cubeModel

function networking.createObjectForPeer(peerID, objects, q, playerModel, playerModelRotationOffset, defaults)
    defaults = defaults or {}
    local startScale = tonumber(defaults.scale) or 1.35
    local model = playerModel or cubeModel
    local obj = {
        model = model,
        pos = { 0, 0, 0 },
        basePos = { 0, 0, 0 },
        rot = playerModelRotationOffset or q.identity(),
        color = { math.random(), math.random(), math.random() },
        isSolid = true,
        id = peerID,
        scale = { startScale, startScale, startScale },
        halfSize = { x = startScale, y = startScale, z = startScale },
        visualOffsetY = tonumber(defaults.visualOffsetY) or 0,
        modelHash = defaults.modelHash
    }

    table.insert(objects, obj)
    return obj
end

function networking.handlePacket(data, peers, objects, q, playerModel, playerModelRotationOffset, peerDefaults)
    if type(data) ~= "string" then
        return nil
    end

    local parts = {}
    for p in string.gmatch(data, "([^|]+)") do
        table.insert(parts, p)
    end

    if parts[1] ~= "STATE" then
        return nil
    end

    if #parts < 9 then
        return nil
    end

    local id = tonumber(parts[#parts])
    local px = tonumber(parts[2])
    local py = tonumber(parts[3])
    local pz = tonumber(parts[4])
    local rw = tonumber(parts[5])
    local rx = tonumber(parts[6])
    local ry = tonumber(parts[7])
    local rz = tonumber(parts[8])
    local remoteScale = (#parts >= 10) and tonumber(parts[9]) or nil
    local remoteModelHash = (#parts >= 11) and parts[10] or nil

    if not (id and px and py and pz and rw and rx and ry and rz) then
        return nil
    end

    if not peers[id] then
        local defaults = {}
        if type(peerDefaults) == "table" then
            for k, v in pairs(peerDefaults) do
                defaults[k] = v
            end
        end
        if remoteScale and remoteScale > 0 then
            defaults.scale = remoteScale
        end
        if remoteModelHash and remoteModelHash ~= "" then
            defaults.modelHash = remoteModelHash
        end
        peers[id] = networking.createObjectForPeer(id, objects, q, playerModel, playerModelRotationOffset, defaults)
    end

    local obj = peers[id]
    obj.basePos = { px, py, pz }
    obj.pos = { px, py + (obj.visualOffsetY or 0), pz }
    if remoteScale and remoteScale > 0 then
        obj.scale = { remoteScale, remoteScale, remoteScale }
        obj.halfSize = { x = remoteScale, y = remoteScale, z = remoteScale }
    end
    if remoteModelHash and remoteModelHash ~= "" then
        obj.modelHash = remoteModelHash
    end
    local baseRot = { w = rw, x = rx, y = ry, z = rz }
    if playerModelRotationOffset then
        obj.rot = q.normalize(q.multiply(baseRot, playerModelRotationOffset))
    else
        obj.rot = baseRot
    end

    return id
end

return networking
