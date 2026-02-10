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
local peers = {}          -- playerId -> peer
local peerToId = {}       -- peer userdata -> playerId (reverse lookup)
local serverPeer = nil
local localPlayerId = 1
local incomingMessages = {}

-- UDP Discovery / Broadcasting
local DISCOVERY_PORT = 27016
local discoverySocket = nil
local broadcastSocket = nil
local discoveredLobbies = {}
local broadcastTimer = 0
local BROADCAST_INTERVAL = 1.0

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
    peerToId = {}
    incomingMessages = {}
    Network._startBroadcast()
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
    Network.stopDiscovery()
    Network._stopBroadcast()
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
    peerToId = {}
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
                    peerToId[event.peer] = assignedId
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
                    if role == Network.ROLE_HOST then
                        fromId = peerToId[event.peer]
                    end
                    table.insert(incomingMessages, {type = msgType, data = data, fromPlayerId = fromId})
                end
            end
        elseif event.type == "disconnect" then
            if role == Network.ROLE_HOST then
                local disconnectedId = peerToId[event.peer]
                if disconnectedId then
                    peers[disconnectedId] = nil
                    peerToId[event.peer] = nil
                    table.insert(incomingMessages, {type = "player_disconnected", playerId = disconnectedId})
                end
            elseif role == Network.ROLE_CLIENT then
                serverPeer = nil
                table.insert(incomingMessages, {type = "disconnected"})
            end
        end
        event = host:service(0)
    end

    -- Host broadcasts presence on LAN
    if role == Network.ROLE_HOST then
        Network._updateBroadcast(dt)
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

-- ─────────────────────────────────────────────
-- UDP Discovery (client-side)
-- ─────────────────────────────────────────────
function Network.startDiscovery()
    local socket = require("socket")
    discoverySocket = socket.udp()
    discoverySocket:setsockname("*", DISCOVERY_PORT)
    discoverySocket:settimeout(0)
    discoveredLobbies = {}
end

function Network.stopDiscovery()
    if discoverySocket then
        discoverySocket:close()
        discoverySocket = nil
    end
    discoveredLobbies = {}
end

function Network.updateDiscovery(dt)
    if not discoverySocket then return end
    local data, ip, port = discoverySocket:receivefrom()
    while data do
        local prefix, hostName, playerCount = data:match("^(BOTS_LOBBY)|(.+)|(%d+)$")
        if prefix then
            local found = false
            for _, lobby in ipairs(discoveredLobbies) do
                if lobby.ip == ip then
                    lobby.hostName = hostName
                    lobby.playerCount = tonumber(playerCount)
                    lobby.lastSeen = love.timer.getTime()
                    found = true
                    break
                end
            end
            if not found then
                table.insert(discoveredLobbies, {
                    ip = ip,
                    hostName = hostName,
                    playerCount = tonumber(playerCount),
                    lastSeen = love.timer.getTime()
                })
            end
        end
        data, ip, port = discoverySocket:receivefrom()
    end
    -- Remove stale lobbies (not seen in 5 seconds)
    local now = love.timer.getTime()
    for i = #discoveredLobbies, 1, -1 do
        if now - discoveredLobbies[i].lastSeen > 5 then
            table.remove(discoveredLobbies, i)
        end
    end
end

function Network.getDiscoveredLobbies()
    return discoveredLobbies
end

-- ─────────────────────────────────────────────
-- UDP Broadcasting (host-side)
-- ─────────────────────────────────────────────
function Network._startBroadcast()
    local socket = require("socket")
    broadcastSocket = socket.udp()
    broadcastSocket:setoption("broadcast", true)
    broadcastSocket:settimeout(0)
    broadcastTimer = 0
end

function Network._stopBroadcast()
    if broadcastSocket then
        broadcastSocket:close()
        broadcastSocket = nil
    end
end

function Network._updateBroadcast(dt)
    if not broadcastSocket then return end
    broadcastTimer = broadcastTimer + dt
    if broadcastTimer >= BROADCAST_INTERVAL then
        broadcastTimer = 0
        local playerCount = Network.getConnectedCount()
        local hostName = Network.getHostAddress()
        local msg = "BOTS_LOBBY|" .. hostName .. "|" .. tostring(playerCount)
        broadcastSocket:sendto(msg, "255.255.255.255", DISCOVERY_PORT)
    end
end

return Network
