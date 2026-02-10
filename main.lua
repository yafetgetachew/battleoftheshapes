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
local Config      = require("config")

-- Game states: "splash", "menu", "settings", "connecting", "selection", "countdown", "playing", "gameover"
-- (Note: "browsing" state was removed - use "Join by IP" instead)
local gameState
local selection
local players = {}         -- {player1, player2, ...}
local maxPlayers = 3       -- 2 or 3, set by host from Config
local countdownTimer
local countdownValue
local splashTimer = 0
local networkSyncTimer = 0

-- Menu state
local menuChoice = 1       -- 1 = Host, 2 = Join, 3 = Settings
local joinAddress = ""
local menuStatus = ""
local settingsRow = 1      -- 1 = Control Scheme, 2 = Player Count, 3 = Server Mode
local serverMode = false   -- true = dedicated server (host is relay only)

-- Game over
local winner = nil

-- Parallax / background
local bgStars = {}

-- Scaling and resolution
local GAME_WIDTH = 1280
local GAME_HEIGHT = 720
local scaleX, scaleY, offsetX, offsetY = 1, 1, 0, 0

-- ─────────────────────────────────────────────
-- love.load
-- ─────────────────────────────────────────────
function love.load()
    love.graphics.setBackgroundColor(0.06, 0.06, 0.1)
    math.randomseed(os.time())

    -- Set fullscreen with native resolution
    love.window.setFullscreen(true, "desktop")
    updateScaling()

    -- Generate background stars
    for i = 1, 80 do
        bgStars[i] = {
            x = math.random() * GAME_WIDTH,
            y = math.random() * 600,
            r = math.random() * 2 + 0.5,
            brightness = math.random() * 0.5 + 0.2
        }
    end

    -- Load configuration
    Config.load()

    Sounds.load()
    gameState = "splash"
    splashTimer = 0
end

-- Update scaling factors for proper aspect ratio
function updateScaling()
    local windowWidth, windowHeight = love.graphics.getDimensions()
    scaleX = windowWidth / GAME_WIDTH
    scaleY = windowHeight / GAME_HEIGHT

    -- Use uniform scaling to maintain aspect ratio
    local scale = math.min(scaleX, scaleY)
    scaleX = scale
    scaleY = scale

    -- Calculate letterbox/pillarbox offsets
    offsetX = (windowWidth - (GAME_WIDTH * scaleX)) / 2
    offsetY = (windowHeight - (GAME_HEIGHT * scaleY)) / 2
end

function love.resize(w, h)
    updateScaling()
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

    elseif gameState == "settings" then
        -- Nothing to update, handled by keypressed

    elseif gameState == "connecting" then
        Network.update(dt)
        processNetworkMessages()

    elseif gameState == "selection" then
        Network.update(dt)
        processNetworkMessages()
        selection:update(dt)

        -- Host broadcasts selection state periodically (only if playing, not in server mode)
        if Network.getRole() == Network.ROLE_HOST and not serverMode then
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

        -- Network sync: host broadcasts all state, clients send their own state
        if Network.getRole() ~= Network.ROLE_NONE then
            networkSyncTimer = networkSyncTimer + dt
            if networkSyncTimer >= Network.TICK_RATE then
                networkSyncTimer = 0
                if Network.getRole() == Network.ROLE_HOST then
                    sendGameState()
                else
                    -- Client sends local player state to host
                    sendClientState()
                end
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
    -- Apply scaling and offset for proper aspect ratio
    love.graphics.push()
    love.graphics.translate(offsetX, offsetY)
    love.graphics.scale(scaleX, scaleY)

    local W = GAME_WIDTH
    local H = GAME_HEIGHT

    if gameState == "splash" then
        drawSplash(W, H)
    elseif gameState == "menu" then
        drawMenu(W, H)
    elseif gameState == "settings" then
        drawSettings(W, H)
    elseif gameState == "connecting" then
        drawConnecting(W, H)
    elseif gameState == "selection" then
        selection:draw(W, H, Config.getControls())
        if serverMode then
            -- Server mode overlay on selection screen
            local overlayFont = love.graphics.newFont(16)
            love.graphics.setFont(overlayFont)
            love.graphics.setColor(1, 1, 0.4, 0.9)
            love.graphics.printf("SERVER MODE — " .. menuStatus, 0, H - 40, W, "center")
        end
    else
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
        Lightning.draw(W, H)

        -- ── HUD ──
        HUD.draw(players, W)

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
            if serverMode then
                drawServerHint(W, H)
            else
                drawControlsHint(W, H)
            end
        end
    end

    -- Restore graphics state
    love.graphics.pop()
end

-- ─────────────────────────────────────────────
-- love.keypressed
-- ─────────────────────────────────────────────
function love.keypressed(key)
    if key == "escape" then
        if gameState == "menu" then
            -- Quit from menu
            Network.stop()
            love.event.quit()
        else
            -- Return to main menu from any other state
            returnToMenu()
        end
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

    if gameState == "settings" then
        handleSettingsKey(key)
        return
    end

    if gameState == "connecting" then
        handleConnectingKey(key)
        return
    end

    if gameState == "selection" then
        if not serverMode then
            local prevChoice = selection:getLocalChoice()
            local prevConfirmed = selection:isLocalConfirmed()
            selection:keypressed(key, Config.getControls())

            -- Send selection changes over network
            local newChoice = selection:getLocalChoice()
            local newConfirmed = selection:isLocalConfirmed()
            local pid = Network.getLocalPlayerId()

            if newConfirmed and not prevConfirmed then
                Network.send("sel_confirm", {pid = pid, idx = newChoice}, true)
            end
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
    local choices = {selection:getChoices()}
    for i = 1, maxPlayers do
        players[i]:setShape(choices[i])
    end
    Projectiles.clear()

    -- Spawn positions (spread evenly across the stage)
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

    if Network.getRole() == Network.ROLE_HOST then
        local data = {}
        for i = 1, maxPlayers do
            data["s" .. i] = choices[i]
        end
        Network.send("start_countdown", data, true)
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
    local hint = "P" .. pid .. ": A/D move · Space jump · W cast    |    ESC menu"
    love.graphics.printf(hint, 0, H - 22, W, "center")
end

function drawServerHint(W, H)
    local hintFont = love.graphics.newFont(11)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(1, 1, 0.4, 0.35)
    local connected = Network.getConnectedCount() - 1  -- subtract host itself
    local hint = "SERVER MODE — " .. connected .. "/" .. maxPlayers .. " players    |    ESC menu"
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
        if menuChoice < 1 then menuChoice = 3 end
    elseif key == "down" or key == "s" then
        menuChoice = menuChoice + 1
        if menuChoice > 3 then menuChoice = 1 end
    elseif key == "return" or key == "space" then
        if menuChoice == 1 then
            startAsHost()
        elseif menuChoice == 2 then
            -- Join by IP - switch to manual IP entry
            gameState = "connecting"
            menuStatus = "Enter host IP address then press Enter:"
            joinAddress = ""
        elseif menuChoice == 3 then
            -- Settings
            gameState = "settings"
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
    local pc = Config.getPlayerCount()
    local subtitle = "Battle of the Shapes - " .. pc .. " Player LAN"
    if Config.getServerMode() then
        subtitle = subtitle .. " (Server Mode)"
    end
    love.graphics.printf(subtitle, 0, 140, W, "center")

    local menuFont = love.graphics.newFont(28)
    love.graphics.setFont(menuFont)
    local menuY = 240
    local hostLabel = Config.getServerMode() and "Host Server" or "Host Game"
    local options = {hostLabel, "Join by IP", "Settings"}
    for i, opt in ipairs(options) do
        if i == menuChoice then
            love.graphics.setColor(1.0, 1.0, 0.4)
            love.graphics.printf("> " .. opt .. " <", 0, menuY + (i - 1) * 55, W, "center")
        else
            love.graphics.setColor(0.6, 0.6, 0.6)
            love.graphics.printf(opt, 0, menuY + (i - 1) * 55, W, "center")
        end
    end

    local hintFont = love.graphics.newFont(14)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.printf("Use ↑/↓ to select, Enter to confirm", 0, H - 60, W, "center")
end

-- ─────────────────────────────────────────────
-- Settings Screen
-- ─────────────────────────────────────────────
function handleSettingsKey(key)
    local maxRows = 3
    if key == "up" or key == "w" then
        settingsRow = settingsRow - 1
        if settingsRow < 1 then settingsRow = maxRows end
    elseif key == "down" or key == "s" then
        settingsRow = settingsRow + 1
        if settingsRow > maxRows then settingsRow = 1 end
    elseif key == "left" or key == "a" or key == "right" or key == "d" then
        if settingsRow == 1 then
            -- Toggle control scheme
            local current = Config.getControlScheme()
            if current == "wasd" then
                Config.setControlScheme("arrows")
            else
                Config.setControlScheme("wasd")
            end
        elseif settingsRow == 2 then
            -- Toggle player count
            local current = Config.getPlayerCount()
            if current == 2 then
                Config.setPlayerCount(3)
            else
                Config.setPlayerCount(2)
            end
        elseif settingsRow == 3 then
            -- Toggle server mode
            Config.setServerMode(not Config.getServerMode())
        end
    elseif key == "backspace" then
        gameState = "menu"
    end
end

function drawSettings(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    local titleFont = love.graphics.newFont(36)
    love.graphics.setFont(titleFont)
    love.graphics.setColor(1.0, 0.85, 0.2)
    love.graphics.printf("Settings", 0, 80, W, "center")

    local labelFont = love.graphics.newFont(24)
    local valueFont = love.graphics.newFont(32)
    local detailFont = love.graphics.newFont(18)

    -- Row 1: Control Scheme
    local row1Y = 170
    love.graphics.setFont(labelFont)
    if settingsRow == 1 then
        love.graphics.setColor(1.0, 1.0, 0.4)
    else
        love.graphics.setColor(0.6, 0.6, 0.6)
    end
    love.graphics.printf("Control Scheme:", 0, row1Y, W, "center")

    love.graphics.setFont(valueFont)
    local scheme = Config.getControlScheme()
    if scheme == "wasd" then
        if settingsRow == 1 then
            love.graphics.setColor(0.4, 1.0, 0.4)
        else
            love.graphics.setColor(0.3, 0.7, 0.3)
        end
        love.graphics.printf("< WASD + Space >", 0, row1Y + 35, W, "center")
    else
        if settingsRow == 1 then
            love.graphics.setColor(0.4, 0.8, 1.0)
        else
            love.graphics.setColor(0.3, 0.6, 0.7)
        end
        love.graphics.printf("< Arrows + Enter >", 0, row1Y + 35, W, "center")
    end

    love.graphics.setFont(detailFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    if scheme == "wasd" then
        love.graphics.printf("Move: A/D  •  Jump: Space  •  Cast: W", 0, row1Y + 72, W, "center")
    else
        love.graphics.printf("Move: ←/→  •  Jump: Enter  •  Cast: ↑", 0, row1Y + 72, W, "center")
    end

    -- Row 2: Player Count
    local row2Y = 305
    love.graphics.setFont(labelFont)
    if settingsRow == 2 then
        love.graphics.setColor(1.0, 1.0, 0.4)
    else
        love.graphics.setColor(0.6, 0.6, 0.6)
    end
    love.graphics.printf("Player Count:", 0, row2Y, W, "center")

    love.graphics.setFont(valueFont)
    local pc = Config.getPlayerCount()
    if settingsRow == 2 then
        love.graphics.setColor(1.0, 0.85, 0.2)
    else
        love.graphics.setColor(0.7, 0.6, 0.2)
    end
    love.graphics.printf("< " .. pc .. " Players >", 0, row2Y + 35, W, "center")

    love.graphics.setFont(detailFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    if pc == 2 then
        love.graphics.printf("1v1 duel mode", 0, row2Y + 72, W, "center")
    else
        love.graphics.printf("3-player free-for-all", 0, row2Y + 72, W, "center")
    end

    -- Row 3: Server Mode
    local row3Y = 440
    love.graphics.setFont(labelFont)
    if settingsRow == 3 then
        love.graphics.setColor(1.0, 1.0, 0.4)
    else
        love.graphics.setColor(0.6, 0.6, 0.6)
    end
    love.graphics.printf("Server Mode:", 0, row3Y, W, "center")

    love.graphics.setFont(valueFont)
    local sm = Config.getServerMode()
    if sm then
        if settingsRow == 3 then
            love.graphics.setColor(0.4, 1.0, 0.4)
        else
            love.graphics.setColor(0.3, 0.7, 0.3)
        end
        love.graphics.printf("< ON >", 0, row3Y + 35, W, "center")
    else
        if settingsRow == 3 then
            love.graphics.setColor(1.0, 0.5, 0.4)
        else
            love.graphics.setColor(0.7, 0.4, 0.3)
        end
        love.graphics.printf("< OFF >", 0, row3Y + 35, W, "center")
    end

    love.graphics.setFont(detailFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    if sm then
        love.graphics.printf("Host is relay only — does not play", 0, row3Y + 72, W, "center")
    else
        love.graphics.printf("Host joins the game as a player", 0, row3Y + 72, W, "center")
    end

    local hintFont = love.graphics.newFont(14)
    love.graphics.setFont(hintFont)
    love.graphics.setColor(0.5, 0.5, 0.5)
    love.graphics.printf("↑/↓ select  •  ←/→ change  •  Backspace to go back", 0, H - 60, W, "center")
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
-- Networking: start as host or client
-- ─────────────────────────────────────────────
function startAsHost()
    maxPlayers = Config.getPlayerCount()
    serverMode = Config.getServerMode()
    local ok, err = Network.startHost(maxPlayers, serverMode)
    if ok then
        players = {}
        if serverMode then
            -- Dedicated server: all players are remote clients
            for i = 1, maxPlayers do
                players[i] = Player.new(i, nil)
                players[i].isRemote = true
            end
            -- No local selection — host just waits
            selection = Selection.new(0, maxPlayers)  -- pid 0 = spectator
            gameState = "selection"
            menuStatus = "Server mode on " .. Network.getHostAddress() .. ":" .. Network.PORT .. " (waiting for " .. maxPlayers .. " players)"
        else
            -- Normal mode: host is P1
            players[1] = Player.new(1, Config.getControls())
            for i = 2, maxPlayers do
                players[i] = Player.new(i, nil)
                players[i].isRemote = true
            end
            selection = Selection.new(1, maxPlayers)
            gameState = "selection"
            menuStatus = "Hosting on " .. Network.getHostAddress() .. ":" .. Network.PORT
        end
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
        if text:match("[0-9%.a-zA-Z:]") then
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
            local connected = Network.getConnectedCount() - 1  -- subtract host
            if serverMode then
                menuStatus = "Server mode on " .. Network.getHostAddress() .. ":" .. Network.PORT .. " (" .. connected .. "/" .. maxPlayers .. " players)"
            else
                menuStatus = "Player " .. msg.playerId .. " connected (" .. connected .. "/" .. maxPlayers .. ")"
            end

        elseif msg.type == "id_assigned" then
            -- Client received their player ID and max player count
            local pid = msg.playerId
            maxPlayers = msg.maxPlayers or 3
            players = {}
            for i = 1, maxPlayers do
                players[i] = Player.new(i, nil)
                players[i].isRemote = true
            end
            -- Set local player
            players[pid].isRemote = false
            players[pid].controls = Config.getControls()

            selection = Selection.new(pid, maxPlayers)
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
                -- Host relays to other clients
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "sel_browse", data, false)
                end
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
                for i = 1, maxPlayers do
                    players[i]:setShape(data["s" .. i])
                end
                Projectiles.clear()
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
            end

        elseif msg.type == "game_state" then
            -- Client receives authoritative game state from host
            local data = msg.data
            if data then
                applyGameState(data)
            end

        elseif msg.type == "client_state" then
            -- Host receives a client's player state
            if Network.getRole() == Network.ROLE_HOST then
                local data = msg.data
                if data and data.pid and players[data.pid] and players[data.pid].isRemote then
                    players[data.pid]:applyNetState({
                        x = data.x, y = data.y,
                        vx = data.vx, vy = data.vy,
                        facingRight = (data.facing == 1)
                    })
                end
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
            selection = Selection.new(Network.getLocalPlayerId(), maxPlayers)
            gameState = "selection"

        elseif msg.type == "lightning_sync" then
            -- Client receives consolidated lightning state from host
            if Network.getRole() == Network.ROLE_CLIENT then
                local data = msg.data
                if data then
                    local strikes = {}
                    local warnings = {}
                    local sc = data.sc or 0
                    local wc = data.wc or 0
                    for i = 1, sc do
                        local sx = data["s" .. i .. "x"]
                        local sa = data["s" .. i .. "a"]
                        if sx then
                            strikes[i] = {
                                x = sx,
                                age = sa or 0,
                                segments = Lightning.generateBoltSegments(sx)
                            }
                        end
                    end
                    for i = 1, wc do
                        local wx = data["w" .. i .. "x"]
                        local wa = data["w" .. i .. "a"]
                        if wx then
                            warnings[i] = {
                                x = wx,
                                age = wa or 0
                            }
                        end
                    end
                    Lightning.setState({
                        strikes = strikes,
                        warnings = warnings,
                        nextStrikeTimer = data.nt or 5
                    })
                end
            end
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

    -- Send lightning state to clients (single consolidated message)
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

-- Client sends its own player state to the host
function sendClientState()
    local pid = Network.getLocalPlayerId()
    local p = players[pid]
    if not p then return end
    local state = p:getNetState()
    Network.send("client_state", {
        pid = pid,
        x = state.x, y = state.y,
        vx = state.vx, vy = state.vy,
        life = state.life, will = state.will,
        facing = state.facingRight and 1 or 0
    }, false)
end

function applyGameState(data)
    if not data.pid then return end
    local pid = data.pid
    if not players[pid] then return end

    if players[pid].isRemote then
        -- Remote players: apply full state from host
        players[pid]:applyNetState({
            x = data.x, y = data.y,
            vx = data.vx, vy = data.vy,
            life = data.life, will = data.will,
            facingRight = (data.facing == 1)
        })
    else
        -- Local player: only apply authoritative life from host
        -- (host computes lightning damage that client can't compute locally)
        if data.life then
            players[pid].life = data.life
        end
    end
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
function returnToMenu()
    Network.stop()
    players = {}
    selection = nil
    winner = nil
    Projectiles.clear()
    Lightning.reset()
    gameState = "menu"
    menuStatus = ""
    menuChoice = 1
    joinAddress = ""
    networkSyncTimer = 0
    serverMode = false
end

function getLocalPlayer()
    if serverMode then return nil end
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
        selection = Selection.new(Network.getLocalPlayerId(), maxPlayers)
        gameState = "selection"
        -- Host tells clients to restart
        if Network.getRole() == Network.ROLE_HOST then
            Network.send("game_restart", {}, true)
        end
    end
end