-- network.lua
-- ENet-based LAN networking for B.O.T.S (3-player)
-- Player 1 = host/server, Players 2 & 3 = clients

local enet = require("enet")

local Network = {}
Network.PORT = 27015
Network.TICK_RATE = 1/30

Network.ROLE_NONE   = "none"
Network.ROLE_HOST   = "host"
Network.ROLE_CLIENT = "client"

local role = Network.ROLE_NONE
local host = nil
local peers = {}
local serverPeer = nil
local localPlayerId = 1
local incomingMessages = {}

local function encodeMessage(msgType, data)
    local parts = {msgType}
    if data then
        for k, v in pairs(data) do
            if type(v) == "table" then
                for sk, sv in pairs(v) do
                    table.insert(parts, k .. "." .. sk .. "=" .. tostring(sv))
                end
            else
                table.insert(parts, k .. "=" .. tostring(v))
            end
        end
    end
    return table.concat(parts, "|")
end

local function decodeMessage(str)
    local parts = {}
    for part in str:gmatch("[^|]+") do
        table.insert(parts, part)
    end
    if #parts < 1 then return nil end
    local msgType = parts[1]
    local data = {}
    for i = 2, #parts do
        local key, val = parts[i]:match("^(.-)=(.+)$")
        if key and val then
            local parent, child = key:match("^(.-)%.(.+)$")
            if parent and child then
                if not data[parent] then data[parent] = {} end
                if val == "true" then data[parent][child] = true
                elseif val == "false" then data[parent][child] = false
                elseif tonumber(val) then data[parent][child] = tonumber(val)
                else data[parent][child] = val end
            else
                if val == "true" then data[key] = true
                elseif val == "false" then data[key] = false
                elseif tonumber(val) then data[key] = tonumber(val)
                else data[key] = val end
            end
        end
    end
    return msgType, data
end

function Network.getRole() return role end
function Network.getLocalPlayerId() return localPlayerId end

function Network.isConnected()
    if role == Network.ROLE_HOST then return true
    elseif role == Network.ROLE_CLIENT then
        return serverPeer ~= nil and serverPeer:state() == "connected"
    end
    return false
end

function Network.getConnectedCount()
    if role == Network.ROLE_HOST then
        local count = 1
        for _, _ in pairs(peers) do count = count + 1 end
        return count
    end
    return 0
end

function Network.startHost()
    role = Network.ROLE_HOST
    localPlayerId = 1
    host = enet.host_create("*:" .. Network.PORT, 3, 2)
    if not host then
        return false, "Failed to create server on port " .. Network.PORT
    end
    peers = {}
    incomingMessages = {}
    return true
end

function Network.startClient(serverAddress)
    role = Network.ROLE_CLIENT
    host = enet.host_create(nil, 1, 2)
    if not host then
        return false, "Failed to create client"
    end
    serverPeer = host:connect(serverAddress .. ":" .. Network.PORT, 2)
    incomingMessages = {}
    return true
end

function Network.stop()
    if host then
        if role == Network.ROLE_HOST then
            for _, peer in pairs(peers) do peer:disconnect_now() end
        elseif role == Network.ROLE_CLIENT and serverPeer then
            serverPeer:disconnect_now()
        end
        host:flush()
        host:destroy()
    end
    host = nil
    peers = {}
    serverPeer = nil
    role = Network.ROLE_NONE
    localPlayerId = 1
    incomingMessages = {}
end

function Network.send(msgType, data, reliable)
    local encoded = encodeMessage(msgType, data)
    local flag = reliable and "reliable" or "unreliable"
    if role == Network.ROLE_HOST then
        for _, peer in pairs(peers) do peer:send(encoded, 0, flag) end
    elseif role == Network.ROLE_CLIENT and serverPeer then
        serverPeer:send(encoded, 0, flag)
    end
end

function Network.sendTo(playerId, msgType, data, reliable)
    if role ~= Network.ROLE_HOST then return end
    local peer = peers[playerId]
    if peer then
        local encoded = encodeMessage(msgType, data)
        local flag = reliable and "reliable" or "unreliable"
        peer:send(encoded, 0, flag)
    end
end

function Network.relay(fromPlayerId, msgType, data, reliable)
    if role ~= Network.ROLE_HOST then return end
    local encoded = encodeMessage(msgType, data)
    local flag = reliable and "reliable" or "unreliable"
    for pid, peer in pairs(peers) do
        if pid ~= fromPlayerId then peer:send(encoded, 0, flag) end
    end
end

function Network.update(dt)
    if not host then return end
    local event = host:service(0)
    while event do
        if event.type == "connect" then
            if role == Network.ROLE_HOST then
                local assignedId = nil
                if not peers[2] then assignedId = 2
                elseif not peers[3] then assignedId = 3 end
                if assignedId then
                    peers[assignedId] = event.peer
                    event.peer.playerId = assignedId
                    local encoded = encodeMessage("assign_id", {id = assignedId})
                    event.peer:send(encoded, 0, "reliable")
                    table.insert(incomingMessages, {type = "player_connected", playerId = assignedId})
                else
                    local encoded = encodeMessage("server_full", {})
                    event.peer:send(encoded, 0, "reliable")
                    event.peer:disconnect_later()
                end
            elseif role == Network.ROLE_CLIENT then
                table.insert(incomingMessages, {type = "connected"})
            end
        elseif event.type == "receive" then
            local msgType, data = decodeMessage(event.data)
            if msgType then
                if role == Network.ROLE_CLIENT and msgType == "assign_id" then
                    localPlayerId = data.id
                    table.insert(incomingMessages, {type = "id_assigned", playerId = data.id})
                elseif role == Network.ROLE_CLIENT and msgType == "server_full" then
                    table.insert(incomingMessages, {type = "server_full"})
                else
                    local fromId = nil
                    if role == Network.ROLE_HOST and event.peer.playerId then
                        fromId = event.peer.playerId
                    end
                    table.insert(incomingMessages, {type = msgType, data = data, fromPlayerId = fromId})
                end
            end
        elseif event.type == "disconnect" then
            if role == Network.ROLE_HOST then
                local disconnectedId = event.peer.playerId
                if disconnectedId then
                    peers[disconnectedId] = nil
                    table.insert(incomingMessages, {type = "player_disconnected", playerId = disconnectedId})
                end
            elseif role == Network.ROLE_CLIENT then
                serverPeer = nil
                table.insert(incomingMessages, {type = "disconnected"})
            end
        end
        event = host:service(0)
    end
end

function Network.getMessages()
    local msgs = incomingMessages
    incomingMessages = {}
    return msgs
end

function Network.getHostAddress()
    local socket = require("socket")
    local s = socket.udp()
    s:setpeername("8.8.8.8", 80)
    local ip = s:getsockname()
    s:close()
    return ip or "127.0.0.1"
end

return Network
