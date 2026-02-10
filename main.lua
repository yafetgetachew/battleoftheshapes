-- main.lua
-- B.O.T.S - Battle of the Shapes
-- Entry point for the LÖVE2D game (3-player LAN)

local Player      = require("player")
local Physics     = require("physics")
local Selection   = require("selection")
local HUD         = require("hud")
local Projectiles = require("projectiles")
local Network     = require("network")
local Lightning   = require("lightning")
local Sounds      = require("sounds")

-- Game states: "splash", "menu", "connecting", "selection", "countdown", "playing", "gameover"
local gameState
local selection
local players = {}         -- {player1, player2, player3}
local countdownTimer
local countdownValue
local splashTimer = 0
local networkSyncTimer = 0

-- Menu state
local menuChoice = 1       -- 1 = Host, 2 = Join
local joinAddress = ""
local menuStatus = ""

-- Lobby browser state
local lobbyList = {}
local lobbyChoice = 1

-- Game over
local winner = nil

-- Parallax / background
local bgStars = {}

-- ─────────────────────────────────────────────
-- love.load
-- ─────────────────────────────────────────────
function love.load()
    love.graphics.setBackgroundColor(0.06, 0.06, 0.1)
    math.randomseed(os.time())

    -- Generate background stars
    for i = 1, 80 do
        bgStars[i] = {
            x = math.random() * 1280,
            y = math.random() * 600,
            r = math.random() * 2 + 0.5,
            brightness = math.random() * 0.5 + 0.2
        }
    end

    Sounds.load()
    gameState = "splash"
    splashTimer = 0
end

-- ─────────────────────────────────────────────
-- love.update
-- ─────────────────────────────────────────────
function love.update(dt)
    -- Cap delta to avoid physics tunneling on lag spikes
    dt = math.min(dt, 1/30)

    if gameState == "splash" then
        splashTimer = splashTimer + dt
        if splashTimer >= 3.0 then
            gameState = "menu"
        end

    elseif gameState == "menu" then
        -- Nothing to update, handled by keypressed

    elseif gameState == "browsing" then
        Network.updateDiscovery(dt)
        lobbyList = Network.getDiscoveredLobbies()
        if #lobbyList > 0 then
            lobbyChoice = math.max(1, math.min(lobbyChoice, #lobbyList))
        end

    elseif gameState == "connecting" then
        Network.update(dt)
        processNetworkMessages()

    elseif gameState == "selection" then
        Network.update(dt)
        processNetworkMessages()
        selection:update(dt)

        -- Host broadcasts selection state periodically
        if Network.getRole() == Network.ROLE_HOST then
            networkSyncTimer = networkSyncTimer + dt
            if networkSyncTimer >= 0.1 then
                networkSyncTimer = 0
                -- Send local choice to clients
                Network.send("sel_browse", {pid = 1, idx = selection:getLocalChoice()}, false)
            end
        elseif Network.getRole() == Network.ROLE_CLIENT then
            networkSyncTimer = networkSyncTimer + dt
            if networkSyncTimer >= 0.1 then
                networkSyncTimer = 0
                local pid = Network.getLocalPlayerId()
                Network.send("sel_browse", {pid = pid, idx = selection:getLocalChoice()}, false)
            end
        end

        if selection:isDone() then
            startCountdown()
        end

    elseif gameState == "countdown" then
        Network.update(dt)
        processNetworkMessages()
        countdownTimer = countdownTimer - dt
        countdownValue = math.ceil(countdownTimer)
        if countdownTimer <= 0 then
            gameState = "playing"
            Lightning.reset()
        end

    elseif gameState == "playing" then
        Network.update(dt)
        processNetworkMessages()

        -- Update all players
        for _, p in ipairs(players) do
            if p.life > 0 then
                p:update(dt)
            end
        end

        -- Resolve collisions between all pairs
        Physics.resolveAllCollisions(players, dt)

        -- Update projectiles
        Projectiles.update(dt, players)

        -- Update lightning (host-authoritative)
        if Network.getRole() == Network.ROLE_HOST or Network.getRole() == Network.ROLE_NONE then
            Lightning.update(dt, players)
        end

        -- Host sends game state to clients
        if Network.getRole() == Network.ROLE_HOST then
            networkSyncTimer = networkSyncTimer + dt
            if networkSyncTimer >= Network.TICK_RATE then
                networkSyncTimer = 0
                sendGameState()
            end
        end

        -- Check for game over (last player standing)
        checkGameOver()

    elseif gameState == "gameover" then
        Network.update(dt)
        processNetworkMessages()
    end
end

-- ─────────────────────────────────────────────
-- love.draw
-- ─────────────────────────────────────────────
function love.draw()
    local W = love.graphics.getWidth()
    local H = love.graphics.getHeight()

    if gameState == "splash" then
        drawSplash(W, H)
        return
    end

    if gameState == "menu" then
        drawMenu(W, H)
        return
    end

    if gameState == "browsing" then
        drawLobbyBrowser(W, H)
        return
    end

    if gameState == "connecting" then
        drawConnecting(W, H)
        return
    end

    if gameState == "selection" then
        selection:draw()
        return
    end

    -- ── Sky gradient ──
    drawBackground(W, H)

    -- ── Ground ──
    drawGround(W, H)

    -- ── Player shadows ──
    for _, p in ipairs(players) do p:drawShadow() end

    -- ── Players ──
    for _, p in ipairs(players) do p:draw() end

    -- ── Projectiles ──
    Projectiles.draw()

    -- ── Lightning ──
    Lightning.draw()

    -- ── HUD ──
    HUD.draw(players)

    -- ── Countdown overlay ──
    if gameState == "countdown" then
        drawCountdown(W, H)
    end

    -- ── Game Over overlay ──
    if gameState == "gameover" then
        drawGameOver(W, H)
    end

    -- ── Controls hint ──
    if gameState == "playing" then
        drawControlsHint(W, H)
    end
end

-- ─────────────────────────────────────────────
-- love.keypressed
-- ─────────────────────────────────────────────
function love.keypressed(key)
    if key == "escape" then
        Network.stop()
        love.event.quit()
        return
    end

    if gameState == "splash" then
        gameState = "menu"
        return
    end

    if gameState == "menu" then
        handleMenuKey(key)
        return
    end

    if gameState == "browsing" then
        handleBrowsingKey(key)
        return
    end

    if gameState == "connecting" then
        handleConnectingKey(key)
        return
    end

    if gameState == "selection" then
        local prevChoice = selection:getLocalChoice()
        local prevConfirmed = selection:isLocalConfirmed()
        selection:keypressed(key)

        -- Send selection changes over network
        local newChoice = selection:getLocalChoice()
        local newConfirmed = selection:isLocalConfirmed()
        local pid = Network.getLocalPlayerId()

        if newConfirmed and not prevConfirmed then
            Network.send("sel_confirm", {pid = pid, idx = newChoice}, true)
        end
        return
    end

    if gameState == "playing" then
        local localPlayer = getLocalPlayer()
        if localPlayer and localPlayer.life > 0 and localPlayer.controls then
            if key == localPlayer.controls.jump then
                localPlayer:jump()
                if Network.getRole() ~= Network.ROLE_NONE then
                    Network.send("player_jump", {pid = localPlayer.id}, true)
                end
            end
            if key == localPlayer.controls.cast then
                localPlayer:castAbilityAtNearest(players)
                if Network.getRole() ~= Network.ROLE_NONE then
                    Network.send("player_cast", {pid = localPlayer.id}, true)
                end
            end
        end
    end

    if gameState == "gameover" then
        if key == "r" then
            restartGame()
        end
    end
end

-- ─────────────────────────────────────────────
-- Helper: Transition from selection → countdown
-- ─────────────────────────────────────────────
function startCountdown()
    local shape1, shape2, shape3 = selection:getChoices()
    players[1]:setShape(shape1)
    players[2]:setShape(shape2)
    players[3]:setShape(shape3)
    Projectiles.clear()

    -- Spawn positions (spread across the stage)
    players[1]:spawn(250, Physics.GROUND_Y - players[1].shapeHeight / 2)
    players[2]:spawn(640, Physics.GROUND_Y - players[2].shapeHeight / 2)
    players[3]:spawn(1030, Physics.GROUND_Y - players[3].shapeHeight / 2)

    countdownTimer = 3.0
    countdownValue = 3
    gameState = "countdown"

    if Network.getRole() == Network.ROLE_HOST then
        Network.send("start_countdown", {s1 = shape1, s2 = shape2, s3 = shape3}, true)
    end
end

-- ─────────────────────────────────────────────
-- Drawing helpers
-- ─────────────────────────────────────────────
function drawBackground(W, H)
    -- Gradient sky
    local topColor    = {0.05, 0.05, 0.12}
    local bottomColor = {0.12, 0.10, 0.20}
    for y = 0, Physics.GROUND_Y, 4 do
        local t = y / Physics.GROUND_Y
        love.graphics.setColor(
            topColor[1] + (bottomColor[1] - topColor[1]) * t,
            topColor[2] + (bottomColor[2] - topColor[2]) * t,
            topColor[3] + (bottomColor[3] - topColor[3]) * t
        )
        love.graphics.rectangle("fill", 0, y, W, 4)
    end

    -- Stars
    for _, star in ipairs(bgStars) do
        local flicker = star.brightness + math.sin(love.timer.getTime() * 1.5 + star.x) * 0.1
        love.graphics.setColor(1, 1, 1, flicker)
        love.graphics.circle("fill", star.x, star.y, star.r)
    end
end

function drawGround(W, H)
    local groundY = Physics.GROUND_Y

    -- Main ground
    love.graphics.setColor(0.18, 0.22, 0.18)
    love.graphics.rectangle("fill", 0, groundY, W, H - groundY)

    -- Top edge highlight
    love.graphics.setColor(0.3, 0.45, 0.3)
    love.graphics.setLineWidth(3)
    love.graphics.line(0, groundY, W, groundY)

    -- Grass tufts
    love.graphics.setColor(0.25, 0.5, 0.25, 0.6)
    for x = 10, W - 10, 28 do
        local h = 4 + math.sin(x * 0.3) * 3
        love.graphics.rectangle("fill", x, groundY - h, 3, h)
    end

    -- Sub-ground texture lines
    love.graphics.setColor(0.14, 0.18, 0.14, 0.5)
    for y = groundY + 15, H, 20 do
        love.graphics.line(0, y, W, y)
    end
end

function drawCountdown(W, H)
    -- Dimmed overlay
    love.graphics.setColor(0, 0, 0, 0.5)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local bigFont = love.graphics.newFont(72)
    love.graphics.setFont(bigFont)
    love.graphics.setColor(1, 1, 1, 0.9)

    local text = countdownValue > 0 and tostring(countdownValue) or "FIGHT!"
    love.graphics.printf(text, 0, H / 2 - 50, W, "center")
end

function drawControlsHint(W, H)
    local hintFont = love.graphics.newFont(11)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(1, 1, 1, 0.25)
    local pid = Network.getLocalPlayerId()
    local hint = "P" .. pid .. ": A/D move · Space jump · W cast    |    ESC quit"
    love.graphics.printf(hint, 0, H - 22, W, "center")
end

-- ─────────────────────────────────────────────
-- Splash Screen
-- ─────────────────────────────────────────────
function drawSplash(W, H)
    love.graphics.setColor(0.05, 0.05, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title with pulsing effect
    local pulse = 0.7 + 0.3 * math.sin(splashTimer * 2.5)
    local bigFont = love.graphics.newFont(64)
    love.graphics.setFont(bigFont)
    love.graphics.setColor(1.0, 0.85, 0.2, pulse)
    love.graphics.printf("BATTLE OF THE SHAPES", 0, H / 2 - 80, W, "center")

    local subFont = love.graphics.newFont(24)
    love.graphics.setFont(subFont)
    love.graphics.setColor(0.7, 0.7, 0.9, pulse * 0.8)
    love.graphics.printf("B.O.T.S", 0, H / 2 + 10, W, "center")

    if splashTimer > 1.0 then
        local smallFont = love.graphics.newFont(16)
        love.graphics.setFont(smallFont)
        local blink = 0.4 + 0.6 * math.sin(splashTimer * 4)
        love.graphics.setColor(1, 1, 1, blink)
        love.graphics.printf("Press any key to continue", 0, H / 2 + 80, W, "center")
    end
end

-- ─────────────────────────────────────────────
-- Menu Screen
-- ─────────────────────────────────────────────
function handleMenuKey(key)
    if key == "up" or key == "w" then
        menuChoice = menuChoice - 1
        if menuChoice < 1 then menuChoice = 2 end
    elseif key == "down" or key == "s" then
        menuChoice = menuChoice + 1
        if menuChoice > 2 then menuChoice = 1 end
    elseif key == "return" or key == "space" then
        if menuChoice == 1 then
            startAsHost()
        elseif menuChoice == 2 then
            -- Join game - switch to lobby browser
            gameState = "browsing"
            lobbyList = {}
            lobbyChoice = 1
            lobbyRefreshTimer = 0
            Network.startDiscovery()
        end
    end
end

function drawMenu(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local titleFont = love.graphics.newFont(42)
    love.graphics.setFont(titleFont)
    love.graphics.setColor(1.0, 0.85, 0.2)
    love.graphics.printf("B.O.T.S", 0, 80, W, "center")

    local subFont = love.graphics.newFont(18)
    love.graphics.setFont(subFont)
    love.graphics.setColor(0.7, 0.7, 0.9)
    love.graphics.printf("Battle of the Shapes - 3 Player LAN", 0, 140, W, "center")

    local menuFont = love.graphics.newFont(28)
    love.graphics.setFont(menuFont)
    local menuY = 260
    local options = {"Host Game", "Join Game"}
    for i, opt in ipairs(options) do
        if i == menuChoice then
            love.graphics.setColor(1.0, 1.0, 0.4)
            love.graphics.printf("> " .. opt .. " <", 0, menuY + (i - 1) * 60, W, "center")
        else
            love.graphics.setColor(0.6, 0.6, 0.6)
            love.graphics.printf(opt, 0, menuY + (i - 1) * 60, W, "center")
        end
    end

    local hintFont = love.graphics.newFont(14)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.printf("Use ↑/↓ to select, Enter to confirm", 0, H - 60, W, "center")
end

function drawConnecting(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local font = love.graphics.newFont(20)
    love.graphics.setFont(font)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(menuStatus, 0, H / 2 - 60, W, "center")

    local addrFont = love.graphics.newFont(28)
    love.graphics.setFont(addrFont)
    love.graphics.setColor(1.0, 1.0, 0.4)
    local display = joinAddress
    if #display == 0 then display = "_" end
    love.graphics.printf(display, 0, H / 2, W, "center")

    local hintFont = love.graphics.newFont(14)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.printf("Backspace to go back to menu", 0, H - 40, W, "center")
end

-- ─────────────────────────────────────────────
-- Lobby Browser
-- ─────────────────────────────────────────────
function handleBrowsingKey(key)
    if key == "up" then
        lobbyChoice = lobbyChoice - 1
        if lobbyChoice < 1 then lobbyChoice = math.max(1, #lobbyList) end
    elseif key == "down" then
        lobbyChoice = lobbyChoice + 1
        if lobbyChoice > math.max(1, #lobbyList) then lobbyChoice = 1 end
    elseif key == "return" or key == "space" then
        if #lobbyList > 0 and lobbyList[lobbyChoice] then
            Network.stopDiscovery()
            startAsClient(lobbyList[lobbyChoice].ip)
        end
    elseif key == "backspace" then
        Network.stopDiscovery()
        gameState = "menu"
        menuStatus = ""
    elseif key == "r" then
        -- Manual refresh (lobbies auto-refresh, but clear stale ones)
        lobbyChoice = 1
    end
end

function drawLobbyBrowser(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local titleFont = love.graphics.newFont(32)
    love.graphics.setFont(titleFont)
    love.graphics.setColor(1.0, 0.85, 0.2)
    love.graphics.printf("LAN Game Browser", 0, 60, W, "center")

    local subFont = love.graphics.newFont(16)
    love.graphics.setFont(subFont)
    love.graphics.setColor(0.5, 0.5, 0.7)
    love.graphics.printf("Searching for games on local network...", 0, 110, W, "center")

    local listFont = love.graphics.newFont(22)
    love.graphics.setFont(listFont)
    if #lobbyList == 0 then
        love.graphics.setColor(0.4, 0.4, 0.4)
        love.graphics.printf("No games found", 0, H / 2 - 20, W, "center")
    else
        local startY = 170
        for i, lobby in ipairs(lobbyList) do
            local y = startY + (i - 1) * 50
            if i == lobbyChoice then
                love.graphics.setColor(0.15, 0.15, 0.3)
                love.graphics.rectangle("fill", W/2 - 280, y - 5, 560, 40, 6, 6)
                love.graphics.setColor(1.0, 1.0, 0.4)
                love.graphics.printf("> " .. lobby.ip .. "  (" .. lobby.playerCount .. "/3 players) <", 0, y + 5, W, "center")
            else
                love.graphics.setColor(0.6, 0.6, 0.6)
                love.graphics.printf(lobby.ip .. "  (" .. lobby.playerCount .. "/3 players)", 0, y + 5, W, "center")
            end
        end
    end

    local hintFont = love.graphics.newFont(14)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.printf("↑/↓ select · Enter join · R refresh · Backspace back", 0, H - 40, W, "center")
end

-- ─────────────────────────────────────────────
-- Networking: start as host or client
-- ─────────────────────────────────────────────
function startAsHost()
    local ok, err = Network.startHost()
    if ok then
        -- Create all 3 players; host is P1
        players[1] = Player.new(1, {left = "a", right = "d", jump = "space", cast = "w"})
        players[2] = Player.new(2, nil)
        players[2].isRemote = true
        players[3] = Player.new(3, nil)
        players[3].isRemote = true

        selection = Selection.new(1)
        gameState = "selection"
        menuStatus = "Hosting on " .. Network.getHostAddress() .. ":" .. Network.PORT
    else
        menuStatus = "Error: " .. tostring(err)
    end
end

function startAsClient(address)
    local ok, err = Network.startClient(address)
    if ok then
        menuStatus = "Connecting to " .. address .. "..."
    else
        menuStatus = "Error: " .. tostring(err)
        gameState = "menu"
    end
end

-- love.textinput for IP address entry
function love.textinput(text)
    if gameState == "connecting" and not Network.isConnected() then
        -- Allow typing IP address
        if text:match("[0-9%.a-zA-Z]") then
            joinAddress = joinAddress .. text
        end
    end
end

-- Override keypressed for connecting state - handle Enter/Backspace
function handleConnectingKey(key)
    if key == "return" and #joinAddress > 0 then
        startAsClient(joinAddress)
    elseif key == "backspace" then
        if #joinAddress > 0 then
            joinAddress = joinAddress:sub(1, -2)
        else
            Network.stop()
            gameState = "menu"
            menuStatus = ""
        end
    end
end

-- ─────────────────────────────────────────────
-- Network message processing
-- ─────────────────────────────────────────────
function processNetworkMessages()
    local messages = Network.getMessages()
    for _, msg in ipairs(messages) do
        if msg.type == "player_connected" then
            -- A new client connected (host only)
            menuStatus = "Player " .. msg.playerId .. " connected"

        elseif msg.type == "id_assigned" then
            -- Client received their player ID
            local pid = msg.playerId
            players[1] = Player.new(1, nil)
            players[1].isRemote = true
            players[2] = Player.new(2, nil)
            players[2].isRemote = true
            players[3] = Player.new(3, nil)
            players[3].isRemote = true
            -- Set local player
            players[pid].isRemote = false
            players[pid].controls = {left = "a", right = "d", jump = "space", cast = "w"}

            selection = Selection.new(pid)
            gameState = "selection"

        elseif msg.type == "server_full" then
            menuStatus = "Server is full!"
            gameState = "menu"

        elseif msg.type == "player_disconnected" then
            -- A client disconnected (host only)
            if players[msg.playerId] then
                players[msg.playerId].life = 0
            end

        elseif msg.type == "disconnected" then
            -- Lost connection to server
            menuStatus = "Disconnected from server"
            gameState = "menu"
            Network.stop()

        elseif msg.type == "sel_browse" then
            -- Remote player is browsing shapes
            local data = msg.data
            if data and data.pid and data.idx then
                selection:setRemoteChoice(data.pid, data.idx)
            end

        elseif msg.type == "sel_confirm" then
            -- Remote player confirmed their shape
            local data = msg.data
            if data and data.pid and data.idx then
                selection:setRemoteConfirmed(data.pid, data.idx)
                -- Host relays to other clients
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "sel_confirm", data, true)
                end
            end

        elseif msg.type == "start_countdown" then
            -- Client received countdown start from host
            local data = msg.data
            if data then
                players[1]:setShape(data.s1)
                players[2]:setShape(data.s2)
                players[3]:setShape(data.s3)
                Projectiles.clear()
                players[1]:spawn(250, Physics.GROUND_Y - players[1].shapeHeight / 2)
                players[2]:spawn(640, Physics.GROUND_Y - players[2].shapeHeight / 2)
                players[3]:spawn(1030, Physics.GROUND_Y - players[3].shapeHeight / 2)
                countdownTimer = 3.0
                countdownValue = 3
                gameState = "countdown"
            end

        elseif msg.type == "game_state" then
            -- Client receives authoritative game state from host
            local data = msg.data
            if data then
                applyGameState(data)
            end

        elseif msg.type == "player_jump" then
            -- Remote player jumped
            local data = msg.data
            if data and data.pid and players[data.pid] then
                players[data.pid]:jump()
                -- Host relays to other clients
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "player_jump", data, true)
                end
            end

        elseif msg.type == "player_cast" then
            -- Remote player cast ability
            local data = msg.data
            if data and data.pid and players[data.pid] then
                players[data.pid]:castAbilityAtNearest(players)
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "player_cast", data, true)
                end
            end

        elseif msg.type == "game_over" then
            local data = msg.data
            if data and data.winner then
                winner = data.winner
                gameState = "gameover"
            end

        elseif msg.type == "game_restart" then
            -- Host told us to restart - go back to selection
            winner = nil
            Projectiles.clear()
            Lightning.reset()
            selection = Selection.new(Network.getLocalPlayerId())
            gameState = "selection"
        end
    end
end

-- ─────────────────────────────────────────────
-- Game state sync (host → clients)
-- ─────────────────────────────────────────────
function sendGameState()
    for i, p in ipairs(players) do
        local state = p:getNetState()
        Network.send("game_state", {
            pid = i,
            x = state.x, y = state.y,
            vx = state.vx, vy = state.vy,
            life = state.life, will = state.will,
            facing = state.facingRight and 1 or 0
        }, false)
    end
end

function applyGameState(data)
    if not data.pid then return end
    local pid = data.pid
    if not players[pid] then return end
    -- Only apply state for remote players (don't override local prediction)
    if not players[pid].isRemote then return end
    players[pid]:applyNetState({
        x = data.x, y = data.y,
        vx = data.vx, vy = data.vy,
        life = data.life, will = data.will,
        facingRight = (data.facing == 1)
    })
end

-- ─────────────────────────────────────────────
-- Game over check
-- ─────────────────────────────────────────────
function checkGameOver()
    local alive = {}
    for _, p in ipairs(players) do
        if p.life > 0 then
            table.insert(alive, p)
        end
    end
    if #alive <= 1 then
        if #alive == 1 then
            winner = alive[1].id
        else
            winner = 0  -- draw
        end
        gameState = "gameover"
        if Network.getRole() == Network.ROLE_HOST then
            Network.send("game_over", {winner = winner}, true)
        end
    end
end

function drawGameOver(W, H)
    -- Dimmed overlay
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local bigFont = love.graphics.newFont(56)
    love.graphics.setFont(bigFont)
    love.graphics.setColor(1, 1, 0.3)
    if winner and winner > 0 then
        love.graphics.printf("Player " .. winner .. " Wins!", 0, H / 2 - 60, W, "center")
    else
        love.graphics.printf("Draw!", 0, H / 2 - 60, W, "center")
    end

    local smallFont = love.graphics.newFont(20)
    love.graphics.setFont(smallFont)
    love.graphics.setColor(1, 1, 1, 0.7)
    love.graphics.printf("Press R to restart", 0, H / 2 + 20, W, "center")
end

-- ─────────────────────────────────────────────
-- Utility helpers
-- ─────────────────────────────────────────────
function getLocalPlayer()
    local pid = Network.getLocalPlayerId()
    return players[pid]
end

function restartGame()
    if Network.getRole() == Network.ROLE_NONE then
        -- Solo / no network: return to menu
        gameState = "menu"
        players = {}
        winner = nil
        menuStatus = ""
        menuChoice = 1
    else
        -- Networked: stay connected, go back to selection
        winner = nil
        Projectiles.clear()
        Lightning.reset()
        selection = Selection.new(Network.getLocalPlayerId())
        gameState = "selection"
        -- Host tells clients to restart
        if Network.getRole() == Network.ROLE_HOST then
            Network.send("game_restart", {}, true)
        end
    end
end