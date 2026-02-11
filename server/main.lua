-- server/main.lua
-- B.O.T.S Headless Dedicated Server
-- Run with: love server/ [--players 2|3] [--port 27015]

-- ─────────────────────────────────────────────
-- Add parent directory to require path
-- ─────────────────────────────────────────────
local serverDir = love.filesystem.getSource()
local parentDir = serverDir:match("(.+)/[^/]+$") or serverDir:match("(.+)\\[^\\]+$") or "."
package.path = parentDir .. "/?.lua;" .. package.path
package.cpath = parentDir .. "/?.so;" .. parentDir .. "/?.dll;" .. package.cpath

-- ─────────────────────────────────────────────
-- Stub out love.* APIs that game modules expect
-- ─────────────────────────────────────────────
love.graphics = love.graphics or {}
local gfxNoop = function() end
local gfxStubs = {
    "setColor", "setLineWidth", "setFont", "printf", "print",
    "rectangle", "circle", "ellipse", "polygon", "line",
    "push", "pop", "translate", "scale", "getDimensions",
    "setBackgroundColor", "newFont"
}
for _, name in ipairs(gfxStubs) do
    love.graphics[name] = love.graphics[name] or gfxNoop
end
love.graphics.getDimensions = function() return 1280, 720 end
love.graphics.newFont = function() return {} end
love.graphics.isActive = function() return false end
love.graphics.getWidth = function() return 1280 end
love.graphics.getHeight = function() return 720 end
love.graphics.origin = gfxNoop
love.graphics.clear = gfxNoop
love.graphics.present = gfxNoop
love.graphics.reset = gfxNoop

love.keyboard = love.keyboard or {}
love.keyboard.isDown = function() return false end

love.audio = love.audio or {}
love.audio.newSource = function() return { setVolume = gfxNoop, clone = function(self) return self end, play = gfxNoop } end

love.sound = love.sound or {}
love.sound.newSoundData = function() return { setSample = gfxNoop } end

love.window = love.window or {}
love.window.setFullscreen = love.window.setFullscreen or gfxNoop

love.filesystem.getInfo = love.filesystem.getInfo or function() return nil end
love.filesystem.read = love.filesystem.read or function() return nil end
love.filesystem.write = love.filesystem.write or gfxNoop

-- ─────────────────────────────────────────────
-- Parse command-line arguments
-- ─────────────────────────────────────────────
local maxPlayers = 3
local port = 27015

local args = arg or {}
for i = 1, #args do
    if args[i] == "--players" and args[i + 1] then
        local n = tonumber(args[i + 1])
        if n == 2 or n == 3 then maxPlayers = n end
    elseif args[i] == "--port" and args[i + 1] then
        local p = tonumber(args[i + 1])
        if p and p > 0 and p < 65536 then port = p end
    end
end

-- ─────────────────────────────────────────────
-- Require game modules
-- ─────────────────────────────────────────────
local Player      = require("player")
local Physics     = require("physics")
local Selection   = require("selection")
local Projectiles = require("projectiles")
local Network     = require("network")
local Lightning   = require("lightning")
local Sounds      = require("sounds")

-- Override port if specified
if port ~= 27015 then
    Network.PORT = port
end

-- ─────────────────────────────────────────────
-- Server state
-- ─────────────────────────────────────────────
local gameState = "waiting"  -- waiting, selection, countdown, playing, gameover
local players = {}
local selection = nil
local winner = nil
local countdownTimer = 0
local countdownValue = 3
local restartTimer = nil
local networkSyncTimer = 0
local TICK_RATE = Network.TICK_RATE
local processNetworkMessages, sendGameState, startCountdown, checkGameOver, restartGame

-- ─────────────────────────────────────────────
-- Logging
-- ─────────────────────────────────────────────
local function log(msg)
    print("[" .. os.date("%H:%M:%S") .. "] " .. msg)
end

-- ─────────────────────────────────────────────
-- Initialize server
-- ─────────────────────────────────────────────
function initServer()
    math.randomseed(os.time())
    Sounds.load()  -- will use stubs, no actual audio

    local ok, err = Network.startHost(maxPlayers, true)  -- true = dedicated server
    if not ok then
        log("ERROR: Failed to start server: " .. tostring(err))
        love.event.quit(1)
        return false
    end

    -- Create all players as remote
    players = {}
    for i = 1, maxPlayers do
        players[i] = Player.new(i, nil)
        players[i].isRemote = true
    end

    selection = Selection.new(0, maxPlayers)  -- pid 0 = spectator
    gameState = "waiting"

    log("========================================")
    log("  B.O.T.S Dedicated Server")
    log("  Port: " .. Network.PORT)
    log("  Players: " .. maxPlayers)
    log("  Waiting for connections...")
    log("========================================")
    return true
end

-- Forward declarations
local processNetworkMessages, sendGameState, checkGameOver, startCountdown

-- ─────────────────────────────────────────────
-- love.load
-- ─────────────────────────────────────────────
function love.load()
    if not initServer() then return end
end

-- ─────────────────────────────────────────────
-- love.update
-- ─────────────────────────────────────────────
function love.update(dt)
    dt = math.min(dt, 1/30)

    Network.update(dt)
    processNetworkMessages()

    if gameState == "waiting" then
        -- Just waiting for players to connect
        -- Transition to selection happens when first player connects

    elseif gameState == "selection" then
        selection:update(dt)
        if selection:isDone() then
            startCountdown()
        end

    elseif gameState == "countdown" then
        countdownTimer = countdownTimer - dt
        countdownValue = math.ceil(countdownTimer)
        if countdownTimer <= 0 then
            gameState = "playing"
            Lightning.reset()
            log("FIGHT!")
        end

    elseif gameState == "playing" then
        -- Update all players (will regen for remote players)
        for _, p in ipairs(players) do
            if p.life > 0 then
                p:update(dt)
            end
        end

        -- Resolve collisions
        Physics.resolveAllCollisions(players, dt)

        -- Update projectiles
        Projectiles.update(dt, players)

        -- Update lightning (host-authoritative)
        Lightning.update(dt, players)

        -- Network sync: broadcast all state
        networkSyncTimer = networkSyncTimer + dt
        if networkSyncTimer >= TICK_RATE then
            networkSyncTimer = 0
            sendGameState()
        end

        -- Check for game over
        checkGameOver()

    elseif gameState == "gameover" then
	        -- Auto-restart after a delay (non-blocking)
	        if restartTimer ~= nil then
	            restartTimer = restartTimer - dt
	            if restartTimer <= 0 then
	                restartTimer = nil
	                restartGame()
	            end
	        end
    end
end

-- ─────────────────────────────────────────────
-- Network message processing
-- ─────────────────────────────────────────────
processNetworkMessages = function()
    local messages = Network.getMessages()
    for _, msg in ipairs(messages) do
        if msg.type == "player_connected" then
            local connected = Network.getConnectedCount() - 1
            log("Player " .. msg.playerId .. " connected (" .. connected .. "/" .. maxPlayers .. ")")
            if gameState == "waiting" then
                gameState = "selection"
                log("Selection phase started")
            end

        elseif msg.type == "player_disconnected" then
            log("Player " .. msg.playerId .. " disconnected")
            if players[msg.playerId] then
                players[msg.playerId].life = 0
            end

        elseif msg.type == "sel_browse" then
            local data = msg.data
            if data and data.pid and data.idx then
                selection:setRemoteChoice(data.pid, data.idx)
                Network.relay(data.pid, "sel_browse", data, false)
            end

        elseif msg.type == "sel_confirm" then
            local data = msg.data
            if data and data.pid and data.idx then
                selection:setRemoteConfirmed(data.pid, data.idx)
                Network.relay(data.pid, "sel_confirm", data, true)
                log("Player " .. data.pid .. " confirmed shape")
            end

        elseif msg.type == "client_state" then
            local data = msg.data
            if data and data.pid and players[data.pid] and players[data.pid].isRemote then
                players[data.pid]:applyNetState({
                    x = data.x, y = data.y,
                    vx = data.vx, vy = data.vy,
                    facingRight = (data.facing == 1)
                })
            end

        elseif msg.type == "player_jump" then
            local data = msg.data
            if data and data.pid and players[data.pid] then
                players[data.pid]:jump()
                Network.relay(data.pid, "player_jump", data, true)
            end

        elseif msg.type == "player_cast" then
            local data = msg.data
            if data and data.pid and players[data.pid] then
                players[data.pid]:castAbilityAtNearest(players)
                Network.relay(data.pid, "player_cast", data, true)
            end
        end
    end
end

-- ─────────────────────────────────────────────
-- Game state sync (host → clients)
-- ─────────────────────────────────────────────
sendGameState = function()
    for i, p in ipairs(players) do
        local state = p:getNetState()
        Network.send("game_state", {
            pid = i,
            x = state.x, y = state.y,
            vx = state.vx, vy = state.vy,
            life = state.life, will = state.will,
            facing = state.facingRight and 1 or 0,
            armor = state.armor,
            dmgBoost = state.damageBoost,
            dmgShots = state.damageBoostShots
        }, false)
    end

    -- Send lightning state
    local lightningState = Lightning.getState()
    local ldata = {
        sc = #lightningState.strikes,
        wc = #lightningState.warnings,
        nt = lightningState.nextStrikeTimer
    }
    for i, strike in ipairs(lightningState.strikes) do
        ldata["s" .. i .. "x"] = strike.x
        ldata["s" .. i .. "a"] = strike.age
    end
    for i, warning in ipairs(lightningState.warnings) do
        ldata["w" .. i .. "x"] = warning.x
        ldata["w" .. i .. "a"] = warning.age
    end
    Network.send("lightning_sync", ldata, false)
end

-- ─────────────────────────────────────────────
-- Transition from selection → countdown
-- ─────────────────────────────────────────────
startCountdown = function()
    local choices = {selection:getChoices()}
    for i = 1, maxPlayers do
        players[i]:setShape(choices[i])
    end
    Projectiles.clear()

    -- Spawn positions
    local stageLeft = 250
    local stageRight = 1030
    if maxPlayers == 2 then
        players[1]:spawn(stageLeft, Physics.GROUND_Y - players[1].shapeHeight / 2)
        players[2]:spawn(stageRight, Physics.GROUND_Y - players[2].shapeHeight / 2)
    else
        local stageMiddle = (stageLeft + stageRight) / 2
        players[1]:spawn(stageLeft, Physics.GROUND_Y - players[1].shapeHeight / 2)
        players[2]:spawn(stageMiddle, Physics.GROUND_Y - players[2].shapeHeight / 2)
        players[3]:spawn(stageRight, Physics.GROUND_Y - players[3].shapeHeight / 2)
    end

    countdownTimer = 3.0
    countdownValue = 3
    gameState = "countdown"

    -- Tell clients
    local data = {}
    for i = 1, maxPlayers do
        data["s" .. i] = choices[i]
    end
    Network.send("start_countdown", data, true)

    log("Countdown started!")
end

-- ─────────────────────────────────────────────
-- Game over check
-- ─────────────────────────────────────────────
checkGameOver = function()
    local alive = {}
    for _, p in ipairs(players) do
        if p.life > 0 then
            table.insert(alive, p)
        end
    end
    if #alive <= 1 then
        if #alive == 1 then
            winner = alive[1].id
            log("Game Over! Player " .. winner .. " wins!")
        else
            winner = 0
            log("Game Over! Draw!")
        end
        gameState = "gameover"
        Network.send("game_over", {winner = winner}, true)
	        -- Auto-restart after 5 seconds (handled in love.update so we don't block networking)
	        restartTimer = 5
    end
end

-- ─────────────────────────────────────────────
-- Restart game (back to selection)
-- ─────────────────────────────────────────────
restartGame = function()
    winner = nil
    restartTimer = nil
    Projectiles.clear()
    Lightning.reset()
    networkSyncTimer = 0

    -- Reset players
    for i = 1, maxPlayers do
        players[i] = Player.new(i, nil)
        players[i].isRemote = true
    end

    selection = Selection.new(0, maxPlayers)

    local connected = Network.getConnectedCount() - 1
    if connected > 0 then
        gameState = "selection"
        Network.send("game_restart", {}, true)
        log("Game restarted — back to selection")
    else
        gameState = "waiting"
        log("No players connected — waiting...")
    end
end

-- ─────────────────────────────────────────────
-- Graceful shutdown
-- ─────────────────────────────────────────────
function love.quit()
    log("Server shutting down...")
    Network.stop()
end

