#!/usr/bin/env python3
"""Generate network.lua and lightning.lua for B.O.T.S"""
import os

BASE = os.path.dirname(os.path.abspath(__file__))

# ── network.lua ──
with open(os.path.join(BASE, "network.lua"), "w") as f:
    f.write(r'''-- network.lua
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
''')

print("network.lua written")

# ── lightning.lua ──
with open(os.path.join(BASE, "lightning.lua"), "w") as f:
    f.write(r'''-- lightning.lua
-- Random lightning strike system for B.O.T.S

local Physics = require("physics")

local Lightning = {}

Lightning.DAMAGE = 20
Lightning.STRIKE_RADIUS = 50       -- pixels from center that deal damage
Lightning.MIN_INTERVAL = 4         -- minimum seconds between strikes
Lightning.MAX_INTERVAL = 10        -- maximum seconds between strikes
Lightning.FLASH_DURATION = 0.5     -- how long the bolt is visible
Lightning.WARNING_DURATION = 1.0   -- how long the warning indicator shows

local strikes = {}       -- active lightning visual effects
local nextStrikeTimer = 5 -- countdown to next strike
local warnings = {}       -- active warning indicators

function Lightning.reset()
    strikes = {}
    warnings = {}
    nextStrikeTimer = Lightning.MIN_INTERVAL + math.random() * (Lightning.MAX_INTERVAL - Lightning.MIN_INTERVAL)
end

function Lightning.update(dt, players)
    -- Count down to next strike
    nextStrikeTimer = nextStrikeTimer - dt
    if nextStrikeTimer <= 0 then
        Lightning._spawnStrike(players)
        nextStrikeTimer = Lightning.MIN_INTERVAL + math.random() * (Lightning.MAX_INTERVAL - Lightning.MIN_INTERVAL)
    end

    -- Show warning before strike
    for i = #warnings, 1, -1 do
        local w = warnings[i]
        w.age = w.age + dt
        if w.age >= Lightning.WARNING_DURATION then
            -- Actually strike now
            Lightning._doStrike(w.x, players)
            table.remove(warnings, i)
        end
    end

    -- Update active strike visuals
    for i = #strikes, 1, -1 do
        local s = strikes[i]
        s.age = s.age + dt
        if s.age >= Lightning.FLASH_DURATION then
            table.remove(strikes, i)
        end
    end
end

function Lightning._spawnStrike(players)
    -- Pick a random X position on the playable area
    local x = Physics.WALL_LEFT + 60 + math.random() * (Physics.WALL_RIGHT - Physics.WALL_LEFT - 120)
    table.insert(warnings, {
        x = x,
        age = 0
    })
end

function Lightning._doStrike(x, players)
    -- Create visual bolt
    local bolt = {
        x = x,
        age = 0,
        segments = Lightning._generateBoltSegments(x)
    }
    table.insert(strikes, bolt)

    -- Damage players in radius
    if players then
        for _, player in ipairs(players) do
            if player.life and player.life > 0 then
                local dx = math.abs(player.x - x)
                if dx <= Lightning.STRIKE_RADIUS then
                    player.life = math.max(0, player.life - Lightning.DAMAGE)
                    player.hitFlash = 0.25
                end
            end
        end
    end
end

function Lightning._generateBoltSegments(x)
    local segments = {}
    local y = 0
    local cx = x
    local step = 30
    while y < Physics.GROUND_Y do
        local nx = cx + (math.random() - 0.5) * 60
        local ny = math.min(y + step + math.random() * 20, Physics.GROUND_Y)
        table.insert(segments, {x1 = cx, y1 = y, x2 = nx, y2 = ny})
        cx = nx
        y = ny
    end
    return segments
end

function Lightning.draw()
    -- Draw warnings (pulsing circle on ground)
    for _, w in ipairs(warnings) do
        local pulse = 0.5 + 0.5 * math.sin(w.age * 12)
        local alpha = 0.3 + 0.4 * pulse
        love.graphics.setColor(1.0, 1.0, 0.3, alpha)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", w.x, Physics.GROUND_Y, Lightning.STRIKE_RADIUS * (0.5 + 0.5 * (w.age / Lightning.WARNING_DURATION)))
        -- Small crosshair
        love.graphics.setColor(1.0, 1.0, 0.0, alpha * 0.6)
        love.graphics.line(w.x - 10, Physics.GROUND_Y, w.x + 10, Physics.GROUND_Y)
        love.graphics.line(w.x, Physics.GROUND_Y - 10, w.x, Physics.GROUND_Y + 10)
    end

    -- Draw active bolts
    for _, s in ipairs(strikes) do
        local alpha = 1.0 - (s.age / Lightning.FLASH_DURATION)

        -- Screen flash (subtle)
        love.graphics.setColor(1, 1, 1, alpha * 0.08)
        love.graphics.rectangle("fill", 0, 0, love.graphics.getWidth(), love.graphics.getHeight())

        -- Bolt glow (thick, faint)
        love.graphics.setColor(0.6, 0.6, 1.0, alpha * 0.3)
        love.graphics.setLineWidth(12)
        for _, seg in ipairs(s.segments) do
            love.graphics.line(seg.x1, seg.y1, seg.x2, seg.y2)
        end

        -- Bolt core (thin, bright)
        love.graphics.setColor(0.9, 0.9, 1.0, alpha * 0.9)
        love.graphics.setLineWidth(3)
        for _, seg in ipairs(s.segments) do
            love.graphics.line(seg.x1, seg.y1, seg.x2, seg.y2)
        end

        -- Ground impact flash
        love.graphics.setColor(1.0, 1.0, 0.8, alpha * 0.6)
        love.graphics.circle("fill", s.x, Physics.GROUND_Y, 20 + 30 * (1 - alpha))

        love.graphics.setLineWidth(1)
    end
end

-- Get current state for network sync (host sends to clients)
function Lightning.getState()
    return {
        strikes = strikes,
        warnings = warnings,
        nextStrikeTimer = nextStrikeTimer
    }
end

return Lightning
''')

print("lightning.lua written")

