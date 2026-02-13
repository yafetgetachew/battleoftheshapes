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
local maxPlayers = 12     -- set by host on startHost()
local dedicatedServer = false  -- true = host is relay only, no local player



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

-- Returns the peers table (playerId -> peer) for iteration by the host
function Network.getConnectedPeers()
    return peers
end

function Network.startHost(playerCount, isServerMode)
    maxPlayers = playerCount or 3
    dedicatedServer = isServerMode or false
    role = Network.ROLE_HOST
    localPlayerId = dedicatedServer and 0 or 1  -- 0 means no local player
	-- enet.host_create(maxConnections) expects the number of *remote* peers.
	-- If the host is a player, it is not a peer connection.
	local maxConnections = dedicatedServer and maxPlayers or (maxPlayers - 1)
    host = enet.host_create("*:" .. Network.PORT, maxConnections, 2)
    if not host then
        return false, "Failed to create server on port " .. Network.PORT
    end
    peers = {}
    peerToId = {}
    incomingMessages = {}
    return true
end

function Network.getMaxPlayers()
    return maxPlayers
end

function Network.isDedicatedServer()
    return dedicatedServer
end

function Network.startClient(serverAddress)
    role = Network.ROLE_CLIENT
    host = enet.host_create(nil, 1, 2)
    if not host then
        return false, "Failed to create client"
    end
    -- Support ip:port format; default to Network.PORT if no port given
    local addr, port = serverAddress:match("^(.+):(%d+)$")
    if not addr then
        addr = serverAddress
        port = Network.PORT
    end
    serverPeer = host:connect(addr .. ":" .. port, 2)
    incomingMessages = {}
    return true
end

function Network.stop()
    if host then
        if role == Network.ROLE_HOST then
            for _, peer in pairs(peers) do
                pcall(function()
                    peer:disconnect_now()
                end)
            end
        elseif role == Network.ROLE_CLIENT and serverPeer then
            pcall(function()
                serverPeer:disconnect_now()
            end)
        end
        pcall(function()
            host:flush()
        end)
        pcall(function()
            host:destroy()
        end)
    end
    host = nil
    peers = {}
    peerToId = {}
    serverPeer = nil
    role = Network.ROLE_NONE
    localPlayerId = 1
    dedicatedServer = false
    incomingMessages = {}
end

local function serviceHost(timeoutMs)
    if not host then return nil end

    local ok, eventOrErr = pcall(host.service, host, timeoutMs or 0)
    if ok then
        return eventOrErr
    end

    local previousRole = role
    local errText = tostring(eventOrErr)

    -- ENet may throw from :service() when the socket becomes invalid.
    -- Tear everything down so future updates don't repeatedly throw.
    Network.stop()

    incomingMessages[#incomingMessages + 1] = {
        type = "network_error",
        source = "service",
        previousRole = previousRole,
        error = errText
    }
    if previousRole == Network.ROLE_CLIENT then
        incomingMessages[#incomingMessages + 1] = {
            type = "disconnected",
            reason = "service_error",
            error = errText
        }
    end
    return nil
end

-- ─────────────────────────────────────────────
-- Compact binary-ish encoding for high-frequency messages
-- Reduces 14 messages/tick → 1, and ~1400 bytes → ~400 bytes
-- ─────────────────────────────────────────────

-- Send a pre-encoded raw string (bypasses encodeMessage)
function Network.sendRaw(rawStr, reliable)
    local flag = reliable and "reliable" or "unreliable"
    if role == Network.ROLE_HOST then
        for _, peer in pairs(peers) do peer:send(rawStr, 0, flag) end
    elseif role == Network.ROLE_CLIENT and serverPeer then
        serverPeer:send(rawStr, 0, flag)
    end
end

-- Encode all game state into a single compact tick message
-- Format: T;pid,x,y,vx,vy,life,will,f,a,db,ds,aimX,aimY,dash,dashDir;...;L,sc,wc,nt,s1x,s1a,...,w1x,w1a,...;D,bc,cc,st,b1x,b1y,b1vx,b1vy,b1og,...,c1x,c1y,c1a,c1k,...;S,sc,wc,nt,s1id,s1x,s1y,s1vx,s1vy,s1rot,s1age,...,w1x,w1age,...;P,mc,nt,hs,idc,m1id,m1x,m1y,m1vx,m1vy,m1dir,m1hp,m1age,m1ma,m1og,...
function Network.encodeTick(playerStates, lightningState, dropboxState, sawState, pacmanState)
    local parts = {"T"}

    -- Player sections (only alive players)
    for _, ps in ipairs(playerStates) do
        parts[#parts + 1] = ps.pid .. "," .. ps.x .. "," .. ps.y .. ","
            .. ps.vx .. "," .. ps.vy .. "," .. ps.life .. "," .. ps.will .. ","
            .. ps.facing .. "," .. (ps.armor or 0) .. ","
            .. (ps.dmgBoost or 0) .. "," .. (ps.dmgShots or 0) .. ","
            .. (ps.aimX or 0) .. "," .. (ps.aimY or 0) .. ","
            .. (ps.dash or 0) .. "," .. (ps.dashDir or 0)
    end

    -- Lightning section
    local ls = lightningState
    local lparts = {"L", ls.sc or 0, ls.wc or 0, ls.nt or 5}
    if ls.strikes then
        for _, s in ipairs(ls.strikes) do
            lparts[#lparts + 1] = s.x
            lparts[#lparts + 1] = s.age
        end
    end
    if ls.warnings then
        for _, w in ipairs(ls.warnings) do
            lparts[#lparts + 1] = w.x
            lparts[#lparts + 1] = w.age
        end
    end
    parts[#parts + 1] = table.concat(lparts, ",")

    -- Dropbox section
    local ds = dropboxState
    local dparts = {"D", ds.bc or 0, ds.cc or 0, ds.st or 10}
    if ds.boxes then
        for _, b in ipairs(ds.boxes) do
            dparts[#dparts + 1] = b.x
            dparts[#dparts + 1] = b.y
            dparts[#dparts + 1] = b.vx
            dparts[#dparts + 1] = b.vy
            dparts[#dparts + 1] = b.og
        end
    end
    if ds.charges then
        for _, c in ipairs(ds.charges) do
            dparts[#dparts + 1] = c.x
            dparts[#dparts + 1] = c.y
            dparts[#dparts + 1] = c.age
            dparts[#dparts + 1] = c.kind
        end
    end
    parts[#parts + 1] = table.concat(dparts, ",")

    -- Saw section
    local ss = sawState or {}
    local sparts = {"S", ss.sc or 0, ss.wc or 0, ss.nt or 8, ss.idc or 0}
    if ss.saws then
        for _, s in ipairs(ss.saws) do
            sparts[#sparts + 1] = s.id
            sparts[#sparts + 1] = s.x
            sparts[#sparts + 1] = s.y
            sparts[#sparts + 1] = s.vx
            sparts[#sparts + 1] = s.vy
            sparts[#sparts + 1] = s.rotation
            sparts[#sparts + 1] = s.age
            sparts[#sparts + 1] = s.onGround and 1 or 0
        end
    end
    if ss.warnings then
        for _, w in ipairs(ss.warnings) do
            sparts[#sparts + 1] = w.x
            sparts[#sparts + 1] = w.age
        end
    end
    parts[#parts + 1] = table.concat(sparts, ",")

    -- Pacman section
    local ps = pacmanState or {}
    local pparts = {"P", ps.mc or 0, ps.nt or 30, ps.hs and 1 or 0, ps.idc or 0}
    if ps.monsters then
        for _, m in ipairs(ps.monsters) do
            pparts[#pparts + 1] = m.id
            pparts[#pparts + 1] = m.x
            pparts[#pparts + 1] = m.y
            pparts[#pparts + 1] = m.vx
            pparts[#pparts + 1] = m.vy or 0
            pparts[#pparts + 1] = m.direction
            pparts[#pparts + 1] = m.hp
            pparts[#pparts + 1] = m.age
            pparts[#pparts + 1] = m.mouthAngle
            pparts[#pparts + 1] = m.onGround or 0
        end
    end
    parts[#parts + 1] = table.concat(pparts, ",")

    return table.concat(parts, ";")
end

-- Decode a compact tick message
function Network.decodeTick(raw)
    local sections = {}
    for section in raw:gmatch("[^;]+") do
        sections[#sections + 1] = section
    end
    -- sections[1] = "T" (prefix)
    local playerStates = {}
    local lightningState = {}
    local dropboxState = {}
    local sawState = {}
    local pacmanState = {}

    for i = 2, #sections do
        local sec = sections[i]
        local firstChar = sec:sub(1, 1)
        if firstChar == "L" then
            -- Lightning: L,sc,wc,nt,s1x,s1a,...,w1x,w1a,...
            local vals = {}
            for v in sec:gmatch("[^,]+") do vals[#vals + 1] = v end
            local sc = tonumber(vals[2]) or 0
            local wc = tonumber(vals[3]) or 0
            local nt = tonumber(vals[4]) or 5
            local strikes = {}
            local idx = 5
            for s = 1, sc do
                strikes[s] = {
                    x = tonumber(vals[idx]) or 0,
                    age = tonumber(vals[idx + 1]) or 0
                }
                idx = idx + 2
            end
            local warnings = {}
            for w = 1, wc do
                warnings[w] = {
                    x = tonumber(vals[idx]) or 0,
                    age = tonumber(vals[idx + 1]) or 0
                }
                idx = idx + 2
            end
            lightningState = {sc = sc, wc = wc, nt = nt, strikes = strikes, warnings = warnings}
        elseif firstChar == "D" then
            -- Dropbox: D,bc,cc,st,b1x,b1y,b1vx,b1vy,b1og,...,c1x,c1y,c1a,c1k,...
            local vals = {}
            for v in sec:gmatch("[^,]+") do vals[#vals + 1] = v end
            local bc = tonumber(vals[2]) or 0
            local cc = tonumber(vals[3]) or 0
            local st = tonumber(vals[4]) or 10
            local boxes = {}
            local idx = 5
            for b = 1, bc do
                boxes[b] = {
                    x = tonumber(vals[idx]) or 0,
                    y = tonumber(vals[idx + 1]) or 0,
                    vx = tonumber(vals[idx + 2]) or 0,
                    vy = tonumber(vals[idx + 3]) or 0,
                    onGround = (tonumber(vals[idx + 4]) or 0) == 1
                }
                idx = idx + 5
            end
            local charges = {}
            for c = 1, cc do
                charges[c] = {
                    x = tonumber(vals[idx]) or 0,
                    y = tonumber(vals[idx + 1]) or 0,
                    age = tonumber(vals[idx + 2]) or 0,
                    kind = vals[idx + 3] or "health"
                }
                idx = idx + 4
            end
            dropboxState = {bc = bc, cc = cc, st = st, boxes = boxes, charges = charges}
        elseif firstChar == "S" then
            -- Saw: S,sc,wc,nt,idc,s1id,s1x,s1y,s1vx,s1vy,s1rot,s1age,s1og,...,w1x,w1age,...
            local vals = {}
            for v in sec:gmatch("[^,]+") do vals[#vals + 1] = v end
            local sc = tonumber(vals[2]) or 0
            local wc = tonumber(vals[3]) or 0
            local nt = tonumber(vals[4]) or 8
            local idc = tonumber(vals[5]) or 0
            local saws = {}
            local idx = 6
            for s = 1, sc do
                saws[s] = {
                    id = tonumber(vals[idx]) or 0,
                    x = tonumber(vals[idx + 1]) or 0,
                    y = tonumber(vals[idx + 2]) or 0,
                    vx = tonumber(vals[idx + 3]) or 0,
                    vy = tonumber(vals[idx + 4]) or 0,
                    rotation = tonumber(vals[idx + 5]) or 0,
                    age = tonumber(vals[idx + 6]) or 0,
                    onGround = (tonumber(vals[idx + 7]) or 0) == 1
                }
                idx = idx + 8
            end
            local warnings = {}
            for w = 1, wc do
                warnings[w] = {
                    x = tonumber(vals[idx]) or 0,
                    age = tonumber(vals[idx + 1]) or 0
                }
                idx = idx + 2
            end
            sawState = {sc = sc, wc = wc, nt = nt, sawIdCounter = idc, saws = saws, warnings = warnings}
        elseif firstChar == "P" then
            -- Pacman: P,mc,nt,hs,idc,m1id,m1x,m1y,m1vx,m1vy,m1dir,m1hp,m1age,m1ma,m1og,...
            local vals = {}
            for v in sec:gmatch("[^,]+") do vals[#vals + 1] = v end
            local mc = tonumber(vals[2]) or 0
            local nt = tonumber(vals[3]) or 30
            local hs = (tonumber(vals[4]) or 0) == 1
            local idc = tonumber(vals[5]) or 0
            local monsters = {}
            local idx = 6
            for m = 1, mc do
                monsters[m] = {
                    id = tonumber(vals[idx]) or 0,
                    x = tonumber(vals[idx + 1]) or 0,
                    y = tonumber(vals[idx + 2]) or 0,
                    vx = tonumber(vals[idx + 3]) or 0,
                    vy = tonumber(vals[idx + 4]) or 0,
                    direction = tonumber(vals[idx + 5]) or 1,
                    hp = tonumber(vals[idx + 6]) or 40,
                    age = tonumber(vals[idx + 7]) or 0,
                    mouthAngle = tonumber(vals[idx + 8]) or 0,
                    onGround = (tonumber(vals[idx + 9]) or 0) == 1
                }
                idx = idx + 10
            end
            pacmanState = {mc = mc, nt = nt, hasSpawnedOnce = hs, monsterIdCounter = idc, monsters = monsters}
        else
            -- Player: pid,x,y,vx,vy,life,will,f,a,db,ds[,aimX,aimY,dash,dashDir]
            local vals = {}
            for v in sec:gmatch("[^,]+") do vals[#vals + 1] = v end
            if #vals >= 11 then
                playerStates[#playerStates + 1] = {
                    pid = tonumber(vals[1]),
                    x = tonumber(vals[2]),
                    y = tonumber(vals[3]),
                    vx = tonumber(vals[4]),
                    vy = tonumber(vals[5]),
                    life = tonumber(vals[6]),
                    will = tonumber(vals[7]),
                    facing = tonumber(vals[8]),
                    armor = tonumber(vals[9]) or 0,
                    dmgBoost = tonumber(vals[10]) or 0,
                    dmgShots = tonumber(vals[11]) or 0,
                    aimX = tonumber(vals[12]),
                    aimY = tonumber(vals[13]),
                    dash = tonumber(vals[14]),
                    dashDir = tonumber(vals[15]) or 0
                }
            end
        end
    end

    return playerStates, lightningState, dropboxState, sawState, pacmanState
end

-- Encode compact client state: C;pid,x,y,vx,vy,facing,aimX,aimY,dash,dashDir
function Network.encodeClientState(pid, x, y, vx, vy, facing, aimX, aimY, dash, dashDir)
    return "C;" .. pid .. "," .. x .. "," .. y .. "," .. vx .. "," .. vy .. "," .. facing
        .. "," .. (aimX or 0) .. "," .. (aimY or 0) .. "," .. (dash or 0) .. "," .. (dashDir or 0)
end

-- Decode compact client state
function Network.decodeClientState(raw)
    -- Skip "C;" prefix
    local body = raw:sub(3)
    local vals = {}
    for v in body:gmatch("[^,]+") do vals[#vals + 1] = v end
    if #vals < 6 then return nil end
    return {
        pid = tonumber(vals[1]),
        x = tonumber(vals[2]),
        y = tonumber(vals[3]),
        vx = tonumber(vals[4]),
        vy = tonumber(vals[5]),
        facing = tonumber(vals[6]),
        aimX = tonumber(vals[7]),
        aimY = tonumber(vals[8]),
        dash = tonumber(vals[9]),
        dashDir = tonumber(vals[10]) or 0
    }
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
    local event = serviceHost(0)
    while event do
        if event.type == "connect" then
            if role == Network.ROLE_HOST then
                local assignedId = nil
                local startId = dedicatedServer and 1 or 2
                for pid = startId, maxPlayers do
                    if not peers[pid] then assignedId = pid; break end
                end
                if assignedId then
                    peers[assignedId] = event.peer
                    peerToId[event.peer] = assignedId
                    local encoded = encodeMessage("assign_id", {id = assignedId, maxPlayers = maxPlayers})
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
            local raw = event.data
            local prefix = raw:sub(1, 2)
            if prefix == "T;" then
                -- Compact tick message from host
                table.insert(incomingMessages, {type = "tick", raw = raw})
            elseif prefix == "C;" then
                -- Compact client state from a client
                local fromId = nil
                if role == Network.ROLE_HOST then
                    fromId = peerToId[event.peer]
                end
                table.insert(incomingMessages, {type = "client_state_compact", raw = raw, fromPlayerId = fromId})
            else
                local msgType, data = decodeMessage(raw)
                if msgType then
                    if role == Network.ROLE_CLIENT and msgType == "assign_id" then
                        localPlayerId = data.id
                        maxPlayers = data.maxPlayers or 3
                        table.insert(incomingMessages, {type = "id_assigned", playerId = data.id, maxPlayers = data.maxPlayers or 3})
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
        event = serviceHost(0)
    end

end

function Network.getMessages()
    local msgs = incomingMessages
    incomingMessages = {}
    return msgs
end

function Network.getHostAddress()
	-- LuaSocket is not bundled with LÖVE by default. Treat it as optional so
    -- the game/server doesn't crash in packaged builds.
    local ok, socket = pcall(require, "socket")
    if not ok or not socket or not socket.udp then
        return "127.0.0.1"
    end
    local s = socket.udp()
    if not s then return "127.0.0.1" end

    -- Best-effort: this may fail if offline/firewalled; still shouldn't crash.
    pcall(function() s:setpeername("8.8.8.8", 80) end)
    local ip = nil
    pcall(function() ip = s:getsockname() end)
    pcall(function() s:close() end)
    return ip or "127.0.0.1"
end

return Network
