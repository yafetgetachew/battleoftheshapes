-- main.lua
-- B.O.T.S - Battle of the Shapes
-- Entry point for the LÖVE2D game (3-player LAN)

local Player      = require("player")
local Physics     = require("physics")
local Selection   = require("selection")
local HUD         = require("hud")
local Projectiles = require("projectiles")
local Abilities   = require("abilities")
local Network     = require("network")
local Lightning   = require("lightning")
local Sounds      = require("sounds")
local Config      = require("config")
local Dropbox     = require("dropbox")
local Background  = require("background")
local Map         = require("map")

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

-- Screen shake state (improved: frequency-based with falloff curve)
local screenShakeTimer = 0       -- remaining shake time (seconds)
local screenShakeIntensity = 0   -- current shake magnitude (pixels)
local screenShakeFrequency = 30  -- shake oscillation frequency (Hz)
local screenShakePhase = 0       -- current phase for smooth shake
local screenShakeDuration = 0    -- total duration (for falloff curve)

-- Camera state (dynamic framing + micro-zoom)
local cameraX, cameraY = 0, 0            -- current camera offset (world coords)
local cameraTargetX, cameraTargetY = 0, 0 -- target camera position
local cameraZoom = 1.0                    -- current zoom level
local cameraTargetZoom = 1.0              -- target zoom level
local cameraZoomTimer = 0                 -- remaining micro-zoom time

-- Hit pause state
local hitPauseTimer = 0  -- remaining freeze time (seconds)

-- Damage numbers
local damageNumbers = {}  -- {x, y, value, age, vx, vy}

-- Low health heartbeat state
local heartbeatTimer = 0       -- time until next heartbeat sound
local heartbeatPulse = 0       -- current pulse intensity (0-1) for visual

-- Demo mode state
local demoMode = false     -- true when playing demo mode with bots
local bots = {}            -- bot AI state for each bot player

-- Menu state
local menuChoice = 1       -- 1 = Host, 2 = Join, 3 = Demo, 4 = Settings
local joinAddress = ""
local menuStatus = ""
local settingsRow = 1      -- 1-4 for grid rows
local settingsCol = 1      -- 1-2 for grid columns (left/right)
local settingsEditingName = false  -- true when typing name
local settingsNameBuffer = ""      -- temporary buffer while typing name
local serverMode = false   -- true = dedicated server (host is relay only)
local ipHistoryIndex = 0   -- 0 = typing new IP, 1+ = selecting from history

-- Game over
local winner = nil

-- Scaling and resolution
local GAME_WIDTH = 1280
local GAME_HEIGHT = 720
-- Global scale factors (exported for other modules)
GLOBAL_SCALE = 1
GLOBAL_SCALE_X, GLOBAL_SCALE_Y = 1, 1
local offsetX, offsetY = 0, 0

-- Helper: Convert window coordinates to game coordinates
local function windowToGame(x, y)
    return (x - offsetX) / GLOBAL_SCALE, (y - offsetY) / GLOBAL_SCALE
end

-- Helper: Check if mouse is over a rectangle
local function isMouseOver(mx, my, x, y, w, h)
    return mx >= x and mx <= x + w and my >= y and my <= y + h
end

-- Fun font path (Fredoka One – bubbly rounded display font, OFL licensed)
local FONT_PATH = "assets/fonts/FredokaOne-Regular.ttf"

-- Font cache: avoid allocating new Font objects every frame.
-- Font cache: avoid allocating new Font objects every frame.
local _fontCache = {}
local function getFont(size)
    -- Adjust size based on global scale for crisp text
    local scaledSize = math.floor(size * GLOBAL_SCALE)
    if scaledSize < 1 then scaledSize = 1 end
    
    local f = _fontCache[scaledSize]
    if not f then
        f = love.graphics.newFont(FONT_PATH, scaledSize)
        _fontCache[scaledSize] = f
    end
    return f
end

-- Clear font cache (call on resize)
local function clearFontCache()
    _fontCache = {}
    -- Also clear other modules' font caches
    Player.clearFontCache()
    HUD.clearFontCache()
    Selection.clearFontCache()
    Dropbox.clearFontCache()
end

-- Helper to draw text with inverse scaling for sharpness
-- Should be used for all UI text drawn under GLOBAL_SCALE
function DrawSharpText(text, x, y, limit, align)
    love.graphics.push()
    love.graphics.translate(x, y)
    love.graphics.scale(1/GLOBAL_SCALE, 1/GLOBAL_SCALE)
    if limit then
        love.graphics.printf(text, 0, 0, limit * GLOBAL_SCALE, align)
    else
        love.graphics.print(text, 0, 0)
    end
    love.graphics.pop()
end

-- ─────────────────────────────────────────────
-- Juice helpers: screen shake, hit pause, damage numbers, camera
-- ─────────────────────────────────────────────

-- Trigger screen shake with frequency-based oscillation and falloff
local function addScreenShake(intensity, duration, frequency)
    screenShakeTimer = duration
    screenShakeDuration = duration
    screenShakeIntensity = intensity
    screenShakeFrequency = frequency or 30
    -- Randomize phase so consecutive shakes don't look identical
    screenShakePhase = math.random() * math.pi * 2
end

-- Trigger hit pause (freezes game for a brief moment)
local function addHitPause(duration)
    hitPauseTimer = math.max(hitPauseTimer, duration)
end

-- Trigger camera micro-zoom (punch in then ease back)
local function addCameraZoom(targetZoom, duration)
    cameraTargetZoom = targetZoom
    cameraZoomTimer = duration
end

-- Spawn a damage number at position
local function spawnDamageNumber(x, y, value)
    if not Config.getDamageNumbers() then return end
    table.insert(damageNumbers, {
        x = x,
        y = y - 20,  -- Start slightly above hit point
        value = math.floor(value + 0.5),
        age = 0,
        maxAge = 0.8,
        vx = (math.random() - 0.5) * 30,
        vy = -80  -- Float upward
    })
end

-- Initialize camera to correct position instantly (no interpolation)
local function initCamera(alivePlayers)
    local sumX, sumY = 0, 0
    local count = 0
    for _, p in ipairs(alivePlayers) do
        if p.life > 0 then
            sumX = sumX + p.x
            sumY = sumY + p.y
            count = count + 1
        end
    end
    if count > 0 then
        local centerX = sumX / count
        local centerY = sumY / count
        cameraTargetX = (centerX - GAME_WIDTH / 2) * 0.3
        cameraTargetY = math.max(-30, math.min(30, (centerY - 400) * 0.1))
        -- Set camera directly to target (no interpolation)
        cameraX = cameraTargetX
        cameraY = cameraTargetY
    else
        cameraX, cameraY = 0, 0
        cameraTargetX, cameraTargetY = 0, 0
    end
    cameraZoom = 1.0
    cameraTargetZoom = 1.0
    cameraZoomTimer = 0
end

-- Update camera to follow players with lead
local function updateCamera(dt, alivePlayers)
    -- Calculate center of alive players
    local sumX, sumY, sumVX = 0, 0, 0
    local count = 0
    for _, p in ipairs(alivePlayers) do
        if p.life > 0 then
            sumX = sumX + p.x
            sumY = sumY + p.y
            sumVX = sumVX + (p.vx or 0)
            count = count + 1
        end
    end

    if count > 0 then
        local centerX = sumX / count
        local centerY = sumY / count
        local avgVX = sumVX / count

        -- Add slight lead in movement direction
        local leadAmount = 30
        centerX = centerX + (avgVX / 300) * leadAmount

        -- Calculate offset from default center (GAME_WIDTH/2, vertical stays fixed)
        cameraTargetX = (centerX - GAME_WIDTH / 2) * 0.3
        cameraTargetY = math.max(-30, math.min(30, (centerY - 400) * 0.1))
    else
        cameraTargetX = 0
        cameraTargetY = 0
    end

    -- Smooth interpolation toward target
    local smoothing = 5 * dt
    cameraX = cameraX + (cameraTargetX - cameraX) * smoothing
    cameraY = cameraY + (cameraTargetY - cameraY) * smoothing

    -- Update zoom
    if cameraZoomTimer > 0 then
        cameraZoomTimer = cameraZoomTimer - dt
        if cameraZoomTimer <= 0 then
            cameraTargetZoom = 1.0
            cameraZoomTimer = 0
        end
    end
    -- Smooth zoom interpolation
    local zoomSmoothing = 8 * dt
    cameraZoom = cameraZoom + (cameraTargetZoom - cameraZoom) * zoomSmoothing
end

-- Calculate current screen shake offset (frequency-based with falloff)
local function getScreenShakeOffset()
    if screenShakeTimer <= 0 then
        return 0, 0
    end
    -- Falloff curve: starts at 1.0, decays to 0
    local progress = screenShakeTimer / screenShakeDuration
    local falloff = progress * progress  -- Quadratic falloff (fast decay at end)

    -- Frequency-based oscillation (smooth sine wave, not random jitter)
    local time = love.timer.getTime()
    local shakeX = math.sin(time * screenShakeFrequency + screenShakePhase) * screenShakeIntensity * falloff
    local shakeY = math.cos(time * screenShakeFrequency * 1.1 + screenShakePhase) * screenShakeIntensity * falloff * 0.7

    return shakeX, shakeY
end

-- Update damage numbers
local function updateDamageNumbers(dt)
    for i = #damageNumbers, 1, -1 do
        local dn = damageNumbers[i]
        dn.age = dn.age + dt
        dn.x = dn.x + dn.vx * dt
        dn.y = dn.y + dn.vy * dt
        dn.vy = dn.vy + 50 * dt  -- Slight gravity to arc upward then slow
        if dn.age >= dn.maxAge then
            table.remove(damageNumbers, i)
        end
    end
end

-- Draw damage numbers (call in world space)
local function drawDamageNumbers()
    for _, dn in ipairs(damageNumbers) do
        local progress = dn.age / dn.maxAge
        local alpha = 1 - progress * progress  -- Fade out
        local scale = 1 + progress * 0.3       -- Slight grow

        -- Color based on damage amount
        local r, g, b = 1, 0.9, 0.3  -- Yellow-orange default
        if dn.value >= 20 then
            r, g, b = 1, 0.3, 0.2  -- Red for big hits
        elseif dn.value >= 15 then
            r, g, b = 1, 0.5, 0.2  -- Orange for medium
        end

        local baseSize = 18 * scale
        local font = getFont(baseSize)
        
        love.graphics.push()
        -- Inverse scale for sharp text
        love.graphics.translate(dn.x, dn.y)
        love.graphics.scale(1/GLOBAL_SCALE, 1/GLOBAL_SCALE)
        
        love.graphics.setColor(0, 0, 0, alpha * 0.5)
        love.graphics.setFont(font)
        -- Note: coordinates are local to the translate now, so we draw relative to 0,0 matched to window pixels
        -- But wait, dn.x/y are in game coordinates. 
        -- When we draw in world space, the transform is:
        -- Translate(offsetX, offsetY) -> Scale(GLOBAL_SCALE) -> Translate(Camera...) -> Draw
        -- If we want sharp text in world space, we need the font to be size * GLOBAL_SCALE * CameraZoom?
        -- Actually, for damage numbers, simpler approach:
        -- They are drawn inside the camera transform.
        -- So the net scale at drawing time is GLOBAL_SCALE * cameraZoom.
        -- We should ideally generate fonts based on that, but camera zoom changes dynamically.
        -- For now, let's just use GLOBAL_SCALE and ignore zoom for font generation (it's close to 1.0 usually).
        
        -- To draw sharp text:
        -- 1. Font size = DesiredSize * TotalScale
        -- 2. Draw Scale = 1 / TotalScale
        
        -- However, we are inside a complex transform stack.
        -- Let's just use the global scale for font quality.
        -- We won't apply inverse scale in world space because that would fight the camera zoom.
        -- Instead, we simply rely on the fact that we created a large font.
        -- Wait, if we use a large font (size * scale) and draw it normally, it will be huge.
        -- We MUST scale it down by (1/scale).
        
        love.graphics.scale(1/GLOBAL_SCALE, 1/GLOBAL_SCALE) -- Only undo the global scale (monitor DPI/window size)
        -- We do NOT undo camera zoom.
        
        -- Text is drawn at 0,0 relative to push/translate.
        -- Original code: printf at (dn.x - 50, dn.y). 
        -- Since we translated to dn.x, dn.y, we draw at (-50 * GLOBAL_SCALE, 0).
        -- Wait, if we scale down, we need to draw at larger coordinates? 
        -- No.
        -- Transform:
        -- 1. Translate(dn.x, dn.y) (Game coords)
        -- 2. Scale(1/GLOBAL_SCALE) -> This shrinks the following drawing command.
        -- If we draw text at (0,0), it will be tiny.
        -- BUT, we are using a HUGE font (Size * GLOBAL_SCALE).
        -- So Huge Font * Tiny Scale = Normal Size on Screen (but high res).
        
        -- The offset needs to be scaled too?
        -- logic: 
        -- original: printf("text", x - 50, y, 100, "center")
        -- new: translate(x,y), scale(1/S), printf("text", -50 * S, 0, 100 * S, "center")
        
        local offset = 50 * GLOBAL_SCALE
        local width = 100 * GLOBAL_SCALE
        
        love.graphics.printf(tostring(dn.value), -offset + 1, 1, width, "center")

        love.graphics.setColor(r, g, b, alpha)
        love.graphics.printf(tostring(dn.value), -offset, 0, width, "center")
        
        love.graphics.pop()
    end
end

-- ─────────────────────────────────────────────
-- love.load
-- ─────────────────────────────────────────────
function love.load()
    love.graphics.setBackgroundColor(0.06, 0.06, 0.1)
    math.randomseed(os.time())

    -- Set fullscreen with native resolution
    love.window.setFullscreen(true, "desktop")
    updateScaling()

    -- Initialize parallax background
    Background.init()

    -- Load configuration
    Config.load()

    Sounds.load()
    -- Apply saved music mute setting
    Sounds.setMusicMuted(Config.getMusicMuted())

    -- Set up projectile hit callbacks for juice effects
    Projectiles.onHit = function(x, y, damage)
        spawnDamageNumber(x, y, damage)
        addHitPause(0.04)  -- 40ms hit pause on regular hits
        addScreenShake(3, 0.1, 45)
    end
    Projectiles.onKill = function(x, y)
        addHitPause(0.06)  -- Extra 60ms on kill (stacks with death explosion)
    end

    -- Set up abilities hit callbacks for juice effects
    Abilities.onHit = function(x, y, damage)
        spawnDamageNumber(x, y, damage)
        addHitPause(0.04)  -- 40ms hit pause on ability hits
        addScreenShake(4, 0.12, 40)
    end
    Abilities.onKill = function(x, y)
        addHitPause(0.06)  -- Extra 60ms on kill
    end

    -- Set up player damage callback for network damage numbers + juice
    Player.onDamageReceived = function(x, y, damage)
        spawnDamageNumber(x, y, damage)
        -- Add juice effects for clients (who don't get direct collision callbacks)
        -- Use generic values that feel good for most hits
        addHitPause(0.06)
        addScreenShake(5, 0.2, 30)
        Sounds.play("player_hurt") -- Ensure hurt sound plays if not already handled
    end

    -- Set up lightning hit callbacks for juice effects
    Lightning.onHit = function(x, y, damage)
        spawnDamageNumber(x, y, damage)
        addHitPause(0.05)  -- 50ms hit pause on lightning hit
    end
    Lightning.onWarningStart = function(x)
        Sounds.playLightningWarning()  -- Start warning sound ramp
    end

    -- Set up dash collision callbacks for juice effects
    Physics.onDashHit = function(x, y, damage)
        spawnDamageNumber(x, y, damage)
    end

    gameState = "splash"
    splashTimer = 0
end

-- Update scaling factors for proper aspect ratio
-- Update scaling factors for proper aspect ratio
function updateScaling()
    local windowWidth, windowHeight = love.graphics.getDimensions()
    GLOBAL_SCALE_X = windowWidth / GAME_WIDTH
    GLOBAL_SCALE_Y = windowHeight / GAME_HEIGHT

    -- Use uniform scaling to maintain aspect ratio
    local scale = math.min(GLOBAL_SCALE_X, GLOBAL_SCALE_Y)
    GLOBAL_SCALE_X = scale
    GLOBAL_SCALE_Y = scale
    GLOBAL_SCALE = scale -- Export for other modules

    -- Calculate letterbox/pillarbox offsets
    offsetX = (windowWidth - (GAME_WIDTH * GLOBAL_SCALE)) / 2
    offsetY = (windowHeight - (GAME_HEIGHT * GLOBAL_SCALE)) / 2
    
    -- Clear font caches as scale has changed
    clearFontCache()
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

    -- Hit pause: freeze game briefly on big impacts (but keep updating camera/shake)
    local realDt = dt
    if hitPauseTimer > 0 then
        hitPauseTimer = hitPauseTimer - realDt
        dt = 0  -- Freeze game simulation
    end

    -- Update parallax background (clouds drift) - use realDt so clouds keep moving during hit pause
    Background.update(realDt)

    if gameState == "splash" then
        splashTimer = splashTimer + dt
        if splashTimer >= 3.0 then
            gameState = "menu"
            Sounds.startMenuMusic()  -- Start menu music when entering menu
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
            Dropbox.reset()
            Sounds.startMusic()  -- Start background music when gameplay begins
            Background.onMatchStart()  -- Moon glow pulse
        end

    elseif gameState == "playing" then
        if demoMode then
            -- Demo mode: use local bot AI update
            updateDemoMode(dt)
        else
            Network.update(dt)
            processNetworkMessages()

            -- Update all players
            for _, p in ipairs(players) do
                if p.life > 0 then
                    p:update(dt)
                    -- Check for landing (sound + dust)
                    if p:consumeLanding() then
                        Sounds.play("land")
                        Projectiles.spawnLandingDust(p.x, p.y + p.shapeHeight / 2)
                    end
                end
            end

            -- Resolve collisions between all pairs
            Physics.resolveAllCollisions(players, dt)

            -- Spawn dash impact particles
            for _, impact in ipairs(Physics.consumeDashImpacts()) do
                Projectiles.spawnDashImpact(impact.x, impact.y)
                addScreenShake(6, 0.15, 40)
                addHitPause(0.05)  -- 50ms hit pause on dash impact
                addCameraZoom(1.02, 0.15)
            end

            -- Update projectiles
            Projectiles.update(dt, players)

            -- Update special abilities
            Abilities.update(dt, players)

            -- Update lightning (host-authoritative)
            if Network.getRole() == Network.ROLE_HOST or Network.getRole() == Network.ROLE_NONE then
                Lightning.update(dt, players)
            end

            -- Screen shake on lightning strike (works for host, client, and solo)
            if Lightning.consumeStrike() then
                addScreenShake(8, 0.3, 25)
                Background.onLightningStrike()  -- Brighten clouds
            end

            -- Update dropboxes
            Dropbox.update(dt, players)

            -- Check for player deaths (explosion effect)
            for _, p in ipairs(players) do
                p:checkDeath(dt)
                if p:consumeDeath() then
                    Sounds.play("death")
                    Projectiles.spawnDeathExplosion(p.x, p.y, p.shapeKey)
                    addScreenShake(12, 0.5, 20)
                    addHitPause(0.08)  -- 80ms hit pause on death
                    addCameraZoom(1.05, 0.25)
                end
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

            -- Continuous aiming: update local player aim position every frame
            local localPlayer = getLocalPlayer()
            if localPlayer and localPlayer.life > 0 then
                 local mx, my = love.mouse.getPosition()
                 local gameX = (mx - offsetX) / GLOBAL_SCALE
                 local gameY = (my - offsetY) / GLOBAL_SCALE
                 local W, H = GAME_WIDTH, GAME_HEIGHT
                 local worldX = (gameX - W/2) / cameraZoom + W/2 + cameraX
                 local worldY = (gameY - H/2) / cameraZoom + H/2 + cameraY
                 localPlayer.aimX = worldX
                 localPlayer.aimY = worldY
                 -- DEBUG: Print aim coords periodically
                 if math.random() < 0.01 then
                     print("Main: Player " .. localPlayer.id .. " aim set to " .. math.floor(worldX) .. ", " .. math.floor(worldY))
                 end
            end

            -- Check for game over (last player standing)
            checkGameOver()
        end

    elseif gameState == "gameover" then
        if not demoMode then
            Network.update(dt)
            processNetworkMessages()
        end
    end

    -- Decay screen shake (use realDt so shake continues during hit pause)
    if screenShakeTimer > 0 then
        screenShakeTimer = screenShakeTimer - realDt
        if screenShakeTimer <= 0 then
            screenShakeTimer = 0
            screenShakeIntensity = 0
        end
    end

    -- Update camera (use realDt so camera keeps moving during hit pause)
    -- Also update during countdown so camera is already positioned when game starts
    if gameState == "countdown" or gameState == "playing" or gameState == "gameover" then
        updateCamera(realDt, players)
    end

    -- Update damage numbers (use realDt so they keep floating during hit pause)
    updateDamageNumbers(realDt)

    -- Low health heartbeat (only during gameplay for local player)
    if gameState == "playing" then
        local lowHealth = false
        if localPlayer and localPlayer.life > 0 and localPlayer.life < localPlayer.maxLife * 0.25 then
            lowHealth = true
        end

        if lowHealth then
            heartbeatTimer = heartbeatTimer - dt
            if heartbeatTimer <= 0 then
                Sounds.play("heartbeat")
                heartbeatTimer = 0.8  -- Time between heartbeats
                heartbeatPulse = 1.0  -- Start visual pulse
            end
            -- Decay visual pulse
            heartbeatPulse = math.max(0, heartbeatPulse - dt * 3)
        else
            heartbeatTimer = 0
            heartbeatPulse = 0
        end
    end
end

-- ─────────────────────────────────────────────
-- love.draw
-- ─────────────────────────────────────────────
function love.draw()
    -- Apply scaling and offset for proper aspect ratio
    love.graphics.push()

    -- Get frequency-based screen shake offset
    -- Get frequency-based screen shake offset
    local shakeX, shakeY = getScreenShakeOffset()

    love.graphics.translate(offsetX + shakeX, offsetY + shakeY)
    love.graphics.scale(GLOBAL_SCALE, GLOBAL_SCALE)

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
        selection:draw(W, H, Config.getControls(), players)
        if serverMode then
            -- Server mode overlay on selection screen
	        love.graphics.setFont(getFont(16))
            love.graphics.setColor(1, 1, 0.4, 0.9)
            DrawSharpText("SERVER MODE — " .. menuStatus, 0, H - 40, W, "center")
        end
    else
        -- ── Sky gradient ──
        drawBackground(W, H)


        -- ── Ground ──
        drawGround(W, H)


        -- Apply camera transform for game world elements
        love.graphics.push()
        -- Zoom from center of screen
        love.graphics.translate(W/2, H/2)
        love.graphics.scale(cameraZoom, cameraZoom)
        love.graphics.translate(-W/2 - cameraX, -H/2 - cameraY)

        -- ── Platforms ──
        Map.draw()

        -- ── Player shadows ──
        for _, p in ipairs(players) do p:drawShadow() end

        -- ── Players ──
        local isGameOver = (gameState == "gameover")
        for _, p in ipairs(players) do p:draw(isGameOver) end

        -- ── Projectiles ──
        Projectiles.draw()

        -- ── Special Abilities ──
        Abilities.draw()

        -- ── Dropboxes ──
        Dropbox.draw()

        -- ── Lightning (world elements only) ──
        Lightning.draw(W, H)

        -- ── Damage numbers ──
        drawDamageNumbers()

        -- End camera transform
        love.graphics.pop()

        -- ── Foreground silhouettes (parallax depth cues) ──
        local parallaxOffset = Background.getParallaxOffset(players, W)
        Background.drawForeground(W, H, parallaxOffset)

        -- ── HUD (not affected by camera) ──
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
            elseif demoMode then
                drawDemoHint(W, H)
            else
                drawControlsHint(W, H)
            end
        end

        -- Low health red vignette overlay
        if heartbeatPulse > 0 then
            local alpha = heartbeatPulse * 0.4
            -- Draw red gradient vignette around screen edges
            love.graphics.setColor(0.8, 0.1, 0.1, alpha)
            local edgeSize = 80
            -- Top edge
            love.graphics.rectangle("fill", 0, 0, W, edgeSize)
            -- Bottom edge
            love.graphics.rectangle("fill", 0, H - edgeSize, W, edgeSize)
            -- Left edge
            love.graphics.rectangle("fill", 0, 0, edgeSize, H)
            -- Right edge
            love.graphics.rectangle("fill", W - edgeSize, 0, edgeSize, H)
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
        Sounds.startMenuMusic()
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
            -- Try dash first (double-tap detection)
            if localPlayer:handleKeyForDash(key) then
                Sounds.play("dash_whoosh")
                if Network.getRole() ~= Network.ROLE_NONE then
                    Network.send("player_dash", {pid = localPlayer.id, dir = localPlayer.dashDir}, true)
                end
            end
            if key == localPlayer.controls.jump then
                if localPlayer:jump() then
                    Sounds.play("jump")
                    if Network.getRole() ~= Network.ROLE_NONE then
                        Network.send("player_jump", {pid = localPlayer.id}, true)
                    end
                end
            end
            if key == localPlayer.controls.cast then
                -- Mouse aiming
                local mx, my = love.mouse.getPosition()
                -- Inverse camera transform:
                -- Screen -> Translate(-offsetX, -offsetY) -> Scale(1/scale) -> Translate(camX, camY) -> Translate(-W/2, -H/2) -> Scale(1/zoom) -> Translate(W/2, H/2)
                -- Actually easier: World = (Screen - Center) / Zoom + Center + Camera - Offset
                
                -- Step 1: Undo letterboxing/scaling
                local gameX = (mx - offsetX) / GLOBAL_SCALE
                local gameY = (my - offsetY) / GLOBAL_SCALE
                
                -- Step 2: Undo camera zoom/pan
                local W, H = GAME_WIDTH, GAME_HEIGHT
                local worldX = (gameX - W/2) / cameraZoom + W/2 + cameraX
                local worldY = (gameY - H/2) / cameraZoom + H/2 + cameraY

                localPlayer:castAbilityAt(worldX, worldY)

                if Network.getRole() ~= Network.ROLE_NONE then
                    Network.send("player_cast", {pid = localPlayer.id, tx = worldX, ty = worldY}, true)
                end
            end
            if key == localPlayer.controls.special then
                -- Mouse aiming for special ability
                local mx, my = love.mouse.getPosition()
                local gameX = (mx - offsetX) / GLOBAL_SCALE
                local gameY = (my - offsetY) / GLOBAL_SCALE
                local W, H = GAME_WIDTH, GAME_HEIGHT
                local worldX = (gameX - W/2) / cameraZoom + W/2 + cameraX
                local worldY = (gameY - H/2) / cameraZoom + H/2 + cameraY

                if Abilities.cast(localPlayer, localPlayer.shapeKey, localPlayer.facingRight, worldX, worldY) then
                    if Network.getRole() ~= Network.ROLE_NONE then
                        Network.send("player_special", {pid = localPlayer.id, tx = worldX, ty = worldY}, true)
                    end
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
-- love.keyreleased
-- ─────────────────────────────────────────────
function love.keyreleased(key)
    if gameState == "playing" then
         local pid = Network.getLocalPlayerId()
         if pid and players[pid] and not players[pid].isRemote then
             local p = players[pid]
             if p.controls and key == p.controls.jump then
                 p:stopJump()
                 if Network.getRole() ~= Network.ROLE_NONE then
                    -- Optional: Send network event for jump stop if needed for precise sync
                    -- Network.send("player_stop_jump", {pid = p.id}, true)
                 end
             end
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
    Abilities.clear()

    -- Find which players are connected/active
    local activePlayers = {}
    for i = 1, maxPlayers do
        if selection and selection.connected[i] then
            table.insert(activePlayers, i)
        elseif demoMode then
            -- In demo mode, all created players are active
            table.insert(activePlayers, i)
        end
    end

    -- Spawn positions (spread evenly across the stage)
    local stageLeft = 250
    local stageRight = 1030
    local stageWidth = stageRight - stageLeft
    local activeCount = #activePlayers

    if activeCount == 1 then
        -- Single player - center
        local pid = activePlayers[1]
        players[pid]:spawn((stageLeft + stageRight) / 2, Physics.GROUND_Y - players[pid].shapeHeight / 2)
    elseif activeCount == 2 then
        -- Two players - left and right
        players[activePlayers[1]]:spawn(stageLeft, Physics.GROUND_Y - players[activePlayers[1]].shapeHeight / 2)
        players[activePlayers[2]]:spawn(stageRight, Physics.GROUND_Y - players[activePlayers[2]].shapeHeight / 2)
    else
        -- 3+ players - spread evenly
        for idx, pid in ipairs(activePlayers) do
            local t = (idx - 1) / (activeCount - 1)  -- 0 to 1
            local x = stageLeft + t * stageWidth
            players[pid]:spawn(x, Physics.GROUND_Y - players[pid].shapeHeight / 2)
        end
    end

    countdownTimer = 3.0
    countdownValue = 3
    gameState = "countdown"

    -- Initialize camera to correct position immediately (prevents "floating" illusion)
    initCamera(players)

    if Network.getRole() == Network.ROLE_HOST then
        local data = {}
        for i = 1, maxPlayers do
            data["s" .. i] = choices[i]
        end
        -- Send active player list as flat keys (ap1=pid, ap2=pid, apc=count)
        data.apc = activeCount
        for idx, pid in ipairs(activePlayers) do
            data["ap" .. idx] = pid
        end
        Network.send("start_countdown", data, true)
    end
end

-- ─────────────────────────────────────────────
-- Drawing helpers
-- ─────────────────────────────────────────────
function drawBackground(W, H)
    -- Calculate parallax offset from player positions
    local parallaxOffset = Background.getParallaxOffset(players, W)
    Background.draw(W, H, parallaxOffset)
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

	love.graphics.setFont(getFont(72))
    love.graphics.setColor(1, 1, 1, 0.9)

    local text = countdownValue > 0 and tostring(countdownValue) or "FIGHT!"
    DrawSharpText(text, 0, H / 2 - 50, W, "center")
end

function drawControlsHint(W, H)
	love.graphics.setFont(getFont(11))
    love.graphics.setColor(1, 1, 1, 0.25)
    local pid = Network.getLocalPlayerId()
    local hint = "P" .. pid .. ": A/D move (double-tap dash) · Space jump · W cast · E special    |    ESC menu"
    if Config.getControlScheme() == "arrows" then
        hint = "Controls: Arrows to Move • Enter to Jump • Mouse to Aim/Shoot"
    end
    DrawSharpText(hint, 0, H - 22, W, "center")
end

function drawServerHint(W, H)
	love.graphics.setFont(getFont(11))
    love.graphics.setColor(1, 1, 0.4, 0.35)
    local connected = Network.getConnectedCount() - 1  -- subtract host itself
    local hint = "SERVER MODE — " .. connected .. "/" .. maxPlayers .. " players    |    ESC menu"
    DrawSharpText(hint, 0, H - 22, W, "center")
end

function drawDemoHint(W, H)
	love.graphics.setFont(getFont(11))
    love.graphics.setColor(0.4, 1, 0.6, 0.35)
    local hint = "DEMO MODE — P1: A/D move (double-tap dash) · Space jump · W cast · E special    |    ESC menu"
    DrawSharpText(hint, 0, H - 22, W, "center")
end

-- ─────────────────────────────────────────────
-- Splash Screen
-- ─────────────────────────────────────────────
function drawSplash(W, H)
    love.graphics.setColor(0.05, 0.05, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title with pulsing effect
    local pulse = 0.7 + 0.3 * math.sin(splashTimer * 2.5)
    love.graphics.setFont(getFont(64))
    love.graphics.setColor(1.0, 0.85, 0.2, pulse)
    DrawSharpText("BATTLE OF THE SHAPES", 0, H / 2 - 80, W, "center")

    love.graphics.setFont(getFont(28))
    love.graphics.setColor(0.7, 0.7, 0.9, pulse * 0.8)
    DrawSharpText("B.O.T.S", 0, H / 2 + 10, W, "center")

    if splashTimer > 1.0 then
        love.graphics.setFont(getFont(18))
        local blink = 0.4 + 0.6 * math.sin(splashTimer * 4)
        love.graphics.setColor(1, 1, 1, blink)
        DrawSharpText("Press any key to continue", 0, H / 2 + 80, W, "center")
    end
end

-- ─────────────────────────────────────────────
-- Menu Screen
-- ─────────────────────────────────────────────
function handleMenuKey(key)
    if key == "up" or key == "w" then
        menuChoice = menuChoice - 1
        if menuChoice < 1 then menuChoice = 4 end
        Sounds.play("menu_nav")
    elseif key == "down" or key == "s" then
        menuChoice = menuChoice + 1
        if menuChoice > 4 then menuChoice = 1 end
        Sounds.play("menu_nav")
    elseif key == "return" or key == "space" then
        Sounds.play("menu_select")
        if menuChoice == 1 then
            startAsHost()
        elseif menuChoice == 2 then
            -- Join by IP - switch to manual IP entry
            gameState = "connecting"
            menuStatus = "Enter host IP address then press Enter:"
            joinAddress = ""
        elseif menuChoice == 3 then
            -- Demo Mode
            startDemoMode()
        elseif menuChoice == 4 then
            -- Settings
            gameState = "settings"
        end
    end
end

function drawMenu(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

	love.graphics.setFont(getFont(42))
    love.graphics.setColor(1.0, 0.85, 0.2)
    DrawSharpText("B.O.T.S", 0, 80, W, "center")

	love.graphics.setFont(getFont(18))
    love.graphics.setColor(0.7, 0.7, 0.9)
    local pc = Config.getPlayerCount()
    local subtitle = "Battle of the Shapes - " .. pc .. " Player LAN"
    if Config.getServerMode() then
        subtitle = subtitle .. " (Server Mode)"
    end
    DrawSharpText(subtitle, 0, 140, W, "center")

	love.graphics.setFont(getFont(28))
    local menuY = 240
    local hostLabel = Config.getServerMode() and "Host Server" or "Host Game"
    local options = {hostLabel, "Join by IP", "Demo Mode", "Settings"}
    for i, opt in ipairs(options) do
        if i == menuChoice then
            love.graphics.setColor(1.0, 1.0, 0.4)
            DrawSharpText("> " .. opt .. " <", 0, menuY + (i - 1) * 50, W, "center")
        else
            love.graphics.setColor(0.6, 0.6, 0.6)
            DrawSharpText(opt, 0, menuY + (i - 1) * 50, W, "center")
        end
    end

	love.graphics.setFont(getFont(14))
	-- Show status/errors on the menu (e.g. host bind failures, disconnect messages).
	if menuStatus and #menuStatus > 0 then
		love.graphics.setColor(1.0, 0.45, 0.45)
		DrawSharpText(menuStatus, 0, H - 90, W, "center")
	end

	love.graphics.setColor(0.5, 0.5, 0.5)
	DrawSharpText("Use ↑/↓ to select, Enter to confirm", 0, H - 60, W, "center")
end

-- ─────────────────────────────────────────────
-- Settings Screen
-- ─────────────────────────────────────────────
function handleSettingsKey(key)
    -- Grid layout: 2 columns x 4 rows
    -- Left col (1): Control Scheme, Player Count, Server Mode, Player Name
    -- Right col (2): Aim Assist, Demo Invulnerable, Music, (empty)
    local maxRows = 4
    local maxCols = 2

    -- Handle name editing mode
    if settingsEditingName then
        if key == "return" or key == "escape" then
            -- Save and exit editing mode
            Config.setPlayerName(settingsNameBuffer)
            settingsEditingName = false
            Sounds.play("menu_nav")
        elseif key == "backspace" then
            settingsNameBuffer = settingsNameBuffer:sub(1, -2)
        end
        return  -- Don't process other keys while editing
    end

    if key == "up" or key == "w" then
        settingsRow = settingsRow - 1
        if settingsRow < 1 then settingsRow = maxRows end
        -- Skip row 4 col 2 (empty cell)
        if settingsRow == 4 and settingsCol == 2 then settingsRow = 3 end
        Sounds.play("menu_nav")
    elseif key == "down" or key == "s" then
        settingsRow = settingsRow + 1
        if settingsRow > maxRows then settingsRow = 1 end
        -- Skip row 4 col 2 (empty cell)
        if settingsRow == 4 and settingsCol == 2 then settingsRow = 1 end
        Sounds.play("menu_nav")
    elseif key == "left" or key == "a" then
        -- Navigate to left column
        if settingsCol > 1 then
            settingsCol = settingsCol - 1
            Sounds.play("menu_nav")
        end
    elseif key == "right" or key == "d" then
        -- Navigate to right column (but not on row 4)
        if settingsCol < maxCols and settingsRow < 4 then
            settingsCol = settingsCol + 1
            Sounds.play("menu_nav")
        end
    elseif key == "space" or key == "return" then
        -- Toggle/change the selected setting
        Sounds.play("menu_nav")
        if settingsCol == 1 then
            -- Left column
            if settingsRow == 1 then
                -- Toggle control scheme
                local current = Config.getControlScheme()
                Config.setControlScheme(current == "wasd" and "arrows" or "wasd")
            elseif settingsRow == 2 then
                -- Cycle player count (2-12)
                local current = Config.getPlayerCount()
                local next = current + 1
                if next > 12 then next = 2 end
                Config.setPlayerCount(next)
            elseif settingsRow == 3 then
                -- Toggle server mode
                Config.setServerMode(not Config.getServerMode())
            elseif settingsRow == 4 then
                -- Start editing player name
                settingsEditingName = true
                settingsNameBuffer = Config.getPlayerName() or ""
            end
        else
            -- Right column
            if settingsRow == 1 then
                -- Toggle aim assist
                Config.setAimAssist(not Config.getAimAssist())
            elseif settingsRow == 2 then
                -- Toggle demo invulnerability
                Config.setDemoInvulnerable(not Config.getDemoInvulnerable())
            elseif settingsRow == 3 then
                -- Toggle background music
                local newMuted = not Config.getMusicMuted()
                Config.setMusicMuted(newMuted)
                Sounds.setMusicMuted(newMuted)
            end
        end
    elseif key == "backspace" or key == "escape" then
        Sounds.play("menu_nav")
        gameState = "menu"
    end
end

-- Handle text input for name editing
function handleSettingsTextInput(text)
    if settingsEditingName then
        -- Limit name length to 12 characters
        if #settingsNameBuffer < 12 then
            settingsNameBuffer = settingsNameBuffer .. text
        end
    end
end

function drawSettings(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title
    love.graphics.setFont(getFont(32))
    love.graphics.setColor(1.0, 0.85, 0.2)
    DrawSharpText("Settings", 0, 40, W, "center")

    -- Grid layout: 2 columns x 4 rows
    local labelFont = getFont(14)
    local valueFont = getFont(18)
    local colWidth = 320
    local leftColX = W/2 - colWidth - 40
    local rightColX = W/2 + 40
    local startY = 100
    local rowHeight = 115

    -- Helper to draw a setting cell
    local function drawCell(col, row, label, value, isOn, detail, isEditing)
        local x = (col == 1) and leftColX or rightColX
        local y = startY + (row - 1) * rowHeight
        local isSelected = (settingsCol == col and settingsRow == row)

        -- Draw selection box
        if isSelected then
            love.graphics.setColor(0.2, 0.2, 0.3, 0.8)
            love.graphics.rectangle("fill", x - 10, y - 8, colWidth + 20, rowHeight - 20, 8, 8)
            local borderColor = isEditing and {0.4, 1.0, 0.4, 0.9} or {1.0, 0.85, 0.2, 0.8}
            love.graphics.setColor(borderColor)
            love.graphics.setLineWidth(2)
            love.graphics.rectangle("line", x - 10, y - 8, colWidth + 20, rowHeight - 20, 8, 8)
        end

        -- Label
        love.graphics.setFont(labelFont)
        love.graphics.setColor(isSelected and {1.0, 1.0, 0.4} or {0.6, 0.6, 0.6})
        DrawSharpText(label, x, y, colWidth, "center")

        -- Value
        love.graphics.setFont(valueFont)
        if isEditing then
            love.graphics.setColor(0.4, 1.0, 0.4)
        elseif isOn == nil then
            love.graphics.setColor(isSelected and {0.4, 0.9, 1.0} or {0.3, 0.6, 0.7})
        elseif isOn then
            love.graphics.setColor(isSelected and {0.4, 1.0, 0.4} or {0.3, 0.7, 0.3})
        else
            love.graphics.setColor(isSelected and {1.0, 0.5, 0.4} or {0.7, 0.4, 0.3})
        end

        local displayValue = isEditing and (value .. "_") or ("◀ " .. value .. " ▶")
        DrawSharpText(displayValue, x, y + 20, colWidth, "center")

        -- Detail (smaller, below value)
        if detail then
            love.graphics.setFont(getFont(11))
            love.graphics.setColor(0.45, 0.45, 0.5)
            DrawSharpText(detail, x, y + 44, colWidth, "center")
        end
    end

    -- Get current values
    local scheme = Config.getControlScheme()
    local pc = Config.getPlayerCount()
    local sm = Config.getServerMode()
    local aa = Config.getAimAssist()
    local di = Config.getDemoInvulnerable()
    local mm = Config.getMusicMuted()
    local playerName = Config.getPlayerName() or ""

    -- Left column
    drawCell(1, 1, "Controls",
        scheme == "wasd" and "WASD" or "Arrows", nil,
        scheme == "wasd" and "A/D • Space • W • E" or "←/→ • Enter • ↑ • ↓")
    drawCell(1, 2, "Players",
        pc .. " Players", pc >= 3,
        pc == 2 and "1v1 duel" or "Free-for-all")
    drawCell(1, 3, "Server Mode",
        sm and "ON" or "OFF", sm,
        sm and "Host is relay only" or "Host plays too")

    -- Player Name (row 4, col 1)
    local nameDisplay = settingsEditingName and settingsNameBuffer or (playerName ~= "" and playerName or "(default)")
    drawCell(1, 4, "Your Name",
        nameDisplay, nil,
        "Shown above your shape", settingsEditingName)

    -- Right column
    drawCell(2, 1, "Aim Assist",
        aa and "ON" or "OFF", aa,
        aa and "Auto-target enemies" or "Manual aiming")
    drawCell(2, 2, "Demo Invulnerable",
        di and "ON" or "OFF", di,
        di and "P1 invincible in demo" or "Normal damage")
    drawCell(2, 3, "Music",
        mm and "OFF" or "ON", not mm,
        mm and "Music muted" or "Music enabled")

    -- Instructions
    love.graphics.setFont(getFont(14))
    love.graphics.setColor(0.5, 0.5, 0.5)
    local instructions = settingsEditingName
        and "Type name • Enter to save • Esc to cancel"
        or "↑/↓/←/→ navigate  •  Space change  •  Esc back"
    DrawSharpText(instructions, 0, H - 50, W, "center")
end

function drawConnecting(W, H)
    love.graphics.setColor(0.06, 0.06, 0.1)
    love.graphics.rectangle("fill", 0, 0, W, H)

    love.graphics.setFont(getFont(20))
    love.graphics.setColor(1, 1, 1)
    DrawSharpText(menuStatus, 0, 80, W, "center")

    -- IP input area
    local inputY = 140
    love.graphics.setFont(getFont(16))
    love.graphics.setColor(0.6, 0.6, 0.6)
    DrawSharpText("Enter IP address:", 0, inputY, W, "center")

    love.graphics.setFont(getFont(28))
    if ipHistoryIndex == 0 then
        love.graphics.setColor(1.0, 1.0, 0.4)
    else
        love.graphics.setColor(0.5, 0.5, 0.5)
    end
    local display = joinAddress
    if #display == 0 then display = "_" end
    DrawSharpText(display, 0, inputY + 30, W, "center")

    -- IP History
    local history = Config.getIPHistory()
    if #history > 0 then
        local historyY = inputY + 90
        love.graphics.setFont(getFont(16))
        love.graphics.setColor(0.6, 0.6, 0.6)
        DrawSharpText("Recent connections (↑/↓ to select):", 0, historyY, W, "center")

        love.graphics.setFont(getFont(22))
        local maxDisplay = math.min(#history, 5)  -- Show max 5 entries
        for i = 1, maxDisplay do
            local y = historyY + 30 + (i - 1) * 35
            if i == ipHistoryIndex then
                love.graphics.setColor(1.0, 1.0, 0.4)
                DrawSharpText("> " .. history[i] .. " <", 0, y, W, "center")
            else
                love.graphics.setColor(0.7, 0.7, 0.7)
                DrawSharpText(history[i], 0, y, W, "center")
            end
        end
        if #history > maxDisplay then
            love.graphics.setFont(getFont(14))
            love.graphics.setColor(0.5, 0.5, 0.5)
            DrawSharpText("... and " .. (#history - maxDisplay) .. " more", 0, historyY + 30 + maxDisplay * 35, W, "center")
        end
    end

    love.graphics.setFont(getFont(14))
    love.graphics.setColor(0.5, 0.5, 0.5)
    DrawSharpText("Enter to connect  •  Backspace to go back", 0, H - 40, W, "center")
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
            -- Set player name from config
            local configName = Config.getPlayerName()
            if configName then players[1].name = configName end
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

-- love.textinput for IP address entry and settings name input
function love.textinput(text)
    if gameState == "settings" and settingsEditingName then
        -- Allow typing player name (alphanumeric and common symbols)
        handleSettingsTextInput(text)
    elseif gameState == "connecting" and not Network.isConnected() then
        -- Allow typing IP address
        if text:match("[0-9%.a-zA-Z:]") then
            joinAddress = joinAddress .. text
        end
    end
end

-- Override keypressed for connecting state - handle Enter/Backspace/arrows
function handleConnectingKey(key)
    local history = Config.getIPHistory()
    local historyCount = #history

    if key == "return" then
        local addressToUse = ""
        if ipHistoryIndex > 0 and ipHistoryIndex <= historyCount then
            -- Use selected history IP
            addressToUse = history[ipHistoryIndex]
        else
            -- Use typed address
            addressToUse = joinAddress
        end
        if #addressToUse > 0 then
            -- Store the address we're connecting to (for saving to history on success)
            joinAddress = addressToUse
            startAsClient(addressToUse)
        end
    elseif key == "up" then
        -- Navigate up in history (or wrap to bottom)
        if historyCount > 0 then
            if ipHistoryIndex == 0 then
                ipHistoryIndex = historyCount
            else
                ipHistoryIndex = ipHistoryIndex - 1
            end
        end
    elseif key == "down" then
        -- Navigate down in history (or wrap to typing mode)
        if historyCount > 0 then
            if ipHistoryIndex >= historyCount then
                ipHistoryIndex = 0
            else
                ipHistoryIndex = ipHistoryIndex + 1
            end
        end
    elseif key == "backspace" then
        if ipHistoryIndex > 0 then
            -- Exit history selection, go back to typing
            ipHistoryIndex = 0
        elseif #joinAddress > 0 then
            joinAddress = joinAddress:sub(1, -2)
        else
            Network.stop()
            gameState = "menu"
            menuStatus = ""
            ipHistoryIndex = 0
        end
    else
        -- If typing, reset history selection
        if ipHistoryIndex > 0 and key:match("^[%w%.:]$") then
            ipHistoryIndex = 0
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
            -- Mark player as connected in selection
            if selection then
                selection:setConnected(msg.playerId, true)
            end
            if serverMode then
                menuStatus = "Server mode on " .. Network.getHostAddress() .. ":" .. Network.PORT .. " (" .. connected .. "/" .. maxPlayers .. " players)"
                -- Send connected players info to the new client
                for i = 1, maxPlayers do
                    if selection and selection.connected[i] and i ~= msg.playerId then
                        Network.sendTo(msg.playerId, "player_status", {pid = i, connected = true}, true)
                    end
                end
                -- Relay to other clients that this player connected
                Network.relay(msg.playerId, "player_status", {pid = msg.playerId, connected = true}, true)
            else
                menuStatus = "Player " .. msg.playerId .. " connected (" .. connected .. "/" .. maxPlayers .. ")"
                -- Send host's name to new player
                local pid = Network.getLocalPlayerId()
                if players[pid] then
                    Network.sendTo(msg.playerId, "player_name", {pid = pid, name = players[pid].name}, true)
                end
                -- Also send names and connection status of all other connected players to the new player
                for i = 1, maxPlayers do
                    if i ~= msg.playerId then
                        if selection and selection.connected[i] then
                            Network.sendTo(msg.playerId, "player_status", {pid = i, connected = true}, true)
                        end
                        if i ~= pid and players[i] and players[i].name then
                            Network.sendTo(msg.playerId, "player_name", {pid = i, name = players[i].name}, true)
                        end
                    end
                end
                -- Relay to other clients that this player connected
                Network.relay(msg.playerId, "player_status", {pid = msg.playerId, connected = true}, true)
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
            -- Set player name from config
            local configName = Config.getPlayerName()
            if configName then players[pid].name = configName end
            -- Send our name to the server
            Network.send("player_name", {pid = pid, name = players[pid].name}, true)

            -- Save IP to history on successful connection
            if #joinAddress > 0 then
                Config.addIPToHistory(joinAddress)
            end

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
            -- Mark player as disconnected in selection
            if selection then
                selection:setConnected(msg.playerId, false)
                selection.confirmed[msg.playerId] = false  -- Also unconfirm
            end
            -- Relay to other clients
            Network.relay(msg.playerId, "player_status", {pid = msg.playerId, connected = false}, true)

        elseif msg.type == "disconnected" then
            -- Lost connection to server
            menuStatus = "Disconnected from server"
            gameState = "menu"
            Network.stop()
            Sounds.stopMusic()
            Sounds.startMenuMusic()

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

        elseif msg.type == "player_status" then
            -- Player connection status update
            local data = msg.data
            if data and data.pid then
                if selection then
                    selection:setConnected(data.pid, data.connected == true)
                end
            end

        elseif msg.type == "player_name" then
            -- Remote player sent their name
            local data = msg.data
            if data and data.pid and data.name then
                if players[data.pid] then
                    players[data.pid].name = data.name
                end
                -- Host relays to other clients
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "player_name", data, true)
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
                Abilities.clear()

                -- Get active players from host (flat keys: apc=count, ap1=pid, ap2=pid, ...)
                local activePlayers = {}
                local apc = data.apc
                if apc and apc > 0 then
                    for idx = 1, apc do
                        local pid = data["ap" .. idx]
                        if pid then
                            table.insert(activePlayers, pid)
                        end
                    end
                end
                -- Fallback: find connected players from selection
                if #activePlayers == 0 then
                    for i = 1, maxPlayers do
                        if selection and selection.connected[i] then
                            table.insert(activePlayers, i)
                        end
                    end
                end

                -- Spawn positions (spread evenly across the stage)
                local stageLeft = 250
                local stageRight = 1030
                local stageWidth = stageRight - stageLeft
                local activeCount = #activePlayers

                if activeCount == 1 then
                    local pid = activePlayers[1]
                    players[pid]:spawn((stageLeft + stageRight) / 2, Physics.GROUND_Y - players[pid].shapeHeight / 2)
                elseif activeCount == 2 then
                    players[activePlayers[1]]:spawn(stageLeft, Physics.GROUND_Y - players[activePlayers[1]].shapeHeight / 2)
                    players[activePlayers[2]]:spawn(stageRight, Physics.GROUND_Y - players[activePlayers[2]].shapeHeight / 2)
                else
                    for idx, pid in ipairs(activePlayers) do
                        local t = (idx - 1) / (activeCount - 1)
                        local x = stageLeft + t * stageWidth
                        players[pid]:spawn(x, Physics.GROUND_Y - players[pid].shapeHeight / 2)
                    end
                end

                countdownTimer = 3.0
                countdownValue = 3
                gameState = "countdown"
                -- Initialize camera to correct position immediately
                initCamera(players)
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
                Sounds.play("jump")
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
                if data.tx and data.ty then
                    players[data.pid]:castAbilityAt(data.tx, data.ty)
                else
                    players[data.pid]:castAbilityAtNearest(players)
                end
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "player_cast", data, true)
                end
            end

        elseif msg.type == "player_special" then
            -- Remote player used special ability
            local data = msg.data
            if data and data.pid and players[data.pid] then
                local p = players[data.pid]
                Abilities.cast(p, p.shapeKey, p.facingRight, data.tx, data.ty)
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "player_special", data, true)
                end
            end

        elseif msg.type == "player_dash" then
            -- Remote player dashed
            local data = msg.data
            if data and data.pid and players[data.pid] then
                players[data.pid]:dash(data.dir)
                Sounds.play("dash_whoosh")
                if Network.getRole() == Network.ROLE_HOST then
                    Network.relay(data.pid, "player_dash", data, true)
                end
            end

        elseif msg.type == "game_over" then
            local data = msg.data
            if data and data.winner ~= nil then
                winner = data.winner
                gameState = "gameover"
                Sounds.stopMusic()  -- Stop background music
                Sounds.play("victory")  -- Play victory fanfare
            end

        elseif msg.type == "game_restart" then
            -- Host told us to restart - go back to selection
            winner = nil
            Projectiles.clear()
            Abilities.clear()
            Lightning.reset()
            Dropbox.reset()
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

        elseif msg.type == "dropbox_sync" then
            -- Client receives dropbox state from host
            if Network.getRole() == Network.ROLE_CLIENT then
                local data = msg.data
                if data then
                    local newBoxes = {}
                    local newCharges = {}
                    local bc = data.bc or 0
                    local cc = data.cc or 0
                    for i = 1, bc do
                        local bx = data["b" .. i .. "x"]
                        local by = data["b" .. i .. "y"]
                        if bx and by then
                            newBoxes[i] = {
                                x = bx,
                                y = by,
                                vx = data["b" .. i .. "vx"] or 0,
                                vy = data["b" .. i .. "vy"] or 0,
                                onGround = (data["b" .. i .. "og"] or 0) == 1
                            }
                        end
                    end
                    for i = 1, cc do
                        local cx = data["c" .. i .. "x"]
                        local cy = data["c" .. i .. "y"]
                        if cx and cy then
                            newCharges[i] = {
                                x = cx,
                                y = cy,
                                age = data["c" .. i .. "a"] or 0,
                                kind = data["c" .. i .. "k"] or "health"
                            }
                        end
                    end
                    Dropbox.setState({
                        boxes = newBoxes,
                        charges = newCharges,
                        spawnTimer = data.st or 10
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
            facing = state.facingRight and 1 or 0,
            armor = state.armor,
            dmgBoost = state.damageBoost,
            dmgShots = state.damageBoostShots
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

    -- Send dropbox state to clients (single consolidated message)
    local dropboxState = Dropbox.getState()
    local ddata = {
        bc = #dropboxState.boxes,
        cc = #dropboxState.charges,
        st = dropboxState.spawnTimer
    }
    for i, box in ipairs(dropboxState.boxes) do
        ddata["b" .. i .. "x"] = box.x
        ddata["b" .. i .. "y"] = box.y
        ddata["b" .. i .. "vx"] = box.vx
        ddata["b" .. i .. "vy"] = box.vy
        ddata["b" .. i .. "og"] = box.onGround and 1 or 0
    end
    for i, charge in ipairs(dropboxState.charges) do
        ddata["c" .. i .. "x"] = charge.x
        ddata["c" .. i .. "y"] = charge.y
        ddata["c" .. i .. "a"] = charge.age
        ddata["c" .. i .. "k"] = charge.kind or "health"
    end
    Network.send("dropbox_sync", ddata, false)
end

-- Client sends its own player state to the host
function sendClientState()
    local pid = Network.getLocalPlayerId()
    local p = players[pid]
    if not p then return end
    local state = p:getNetState()
    -- Client only sends position/velocity/facing; host is authoritative for
    -- life, will, armor, and damage boost.
    Network.send("client_state", {
        pid = pid,
        x = state.x, y = state.y,
        vx = state.vx, vy = state.vy,
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
            facingRight = (data.facing == 1),
            armor = data.armor,
            damageBoost = data.dmgBoost,
            damageBoostShots = data.dmgShots
        })
    else
        -- Local player: only apply authoritative life/buffs from host
        if data.life ~= nil then
            -- Show damage number if life decreased
            if data.life < players[pid].life and players[pid].life > 0 then
                local dmg = players[pid].life - data.life
                spawnDamageNumber(players[pid].x, players[pid].y, dmg)
            end
            players[pid].life = data.life
        end
        if data.armor ~= nil then
            players[pid].armor = data.armor
        end
        if data.dmgBoost ~= nil then
            players[pid].damageBoost = data.dmgBoost
        end
        if data.dmgShots ~= nil then
            players[pid].damageBoostShots = data.dmgShots
        end
    end
end

-- ─────────────────────────────────────────────
-- Game over check (host-authoritative)
-- ─────────────────────────────────────────────
function checkGameOver()
    -- Only host (or solo/demo mode) determines game over
    -- Clients receive game_over message from host
    if Network.getRole() == Network.ROLE_CLIENT then
        return  -- clients don't check, they wait for host message
    end

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
        Sounds.stopMusic()  -- Stop background music
        Sounds.play("victory")  -- Play victory fanfare
        if Network.getRole() == Network.ROLE_HOST then
            Network.send("game_over", {winner = winner}, true)
        end
    end
end

function drawGameOver(W, H)
    -- Dimmed overlay
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", 0, 0, W, H)

	love.graphics.setFont(getFont(56))
    if winner and winner > 0 then
        love.graphics.setColor(1, 1, 0.3)
        DrawSharpText("Player " .. winner .. " Wins!", 0, H / 2 - 60, W, "center")
    else
        love.graphics.setColor(0.8, 0.8, 0.8)
        DrawSharpText("Draw!", 0, H / 2 - 60, W, "center")
    end

	love.graphics.setFont(getFont(20))
    love.graphics.setColor(1, 1, 1, 0.7)
    DrawSharpText("Press R to restart", 0, H / 2 + 20, W, "center")
end

-- ─────────────────────────────────────────────
-- Utility helpers
-- ─────────────────────────────────────────────
function returnToMenu()
    Network.stop()
    Sounds.stopMusic()  -- Stop gameplay music
    Sounds.startMenuMusic()  -- Start menu music
    players = {}
    selection = nil
    winner = nil
    Projectiles.clear()
    Abilities.clear()
    Lightning.reset()
    Dropbox.reset()
    gameState = "menu"
    menuStatus = ""
    menuChoice = 1
    joinAddress = ""
    networkSyncTimer = 0
    serverMode = false
    demoMode = false
    bots = {}
end

function getLocalPlayer()
    if serverMode then return nil end
    if demoMode then return players[1] end
    local pid = Network.getLocalPlayerId()
    return players[pid]
end

function restartGame()
    if demoMode then
        -- Demo mode: restart with same setup
        restartDemoMode()
        return
    end
    if Network.getRole() == Network.ROLE_NONE then
        -- Solo / no network: return to menu
        Sounds.stopMusic()
        Sounds.startMenuMusic()
        gameState = "menu"
        players = {}
        winner = nil
        menuStatus = ""
        menuChoice = 1
    else
        -- Networked: stay connected, go back to selection
        winner = nil
        Projectiles.clear()
        Abilities.clear()
        Lightning.reset()
        Dropbox.reset()
        selection = Selection.new(Network.getLocalPlayerId(), maxPlayers)
        gameState = "selection"
        -- Host tells clients to restart
        if Network.getRole() == Network.ROLE_HOST then
            Network.send("game_restart", {}, true)
        end
    end
end

-- ─────────────────────────────────────────────
-- Demo Mode with Bot AI
-- ─────────────────────────────────────────────

-- Bot AI state structure
local function createBotState(playerId)
    return {
        playerId = playerId,
        jumpTimer = math.random() * 2 + 0.5,      -- time until next jump
        castTimer = math.random() * 3 + 1,        -- time until next cast
        specialTimer = math.random() * 6 + 3,     -- time until next special ability
        moveTimer = math.random() * 1.5 + 0.5,    -- time until direction change
        moveDir = math.random() < 0.5 and -1 or 1 -- current move direction
    }
end

-- Update bot AI
local function updateBotAI(bot, player, dt, allPlayers)
    if player.life <= 0 then return end

    -- Random jumping
    bot.jumpTimer = bot.jumpTimer - dt
    if bot.jumpTimer <= 0 then
        player:jump()
        bot.jumpTimer = math.random() * 2.5 + 0.8  -- 0.8-3.3 seconds between jumps
    end

    -- Random casting (at nearest enemy)
    bot.castTimer = bot.castTimer - dt
    if bot.castTimer <= 0 then
        player:castAbilityAtNearest(allPlayers)
        bot.castTimer = math.random() * 2 + 0.5  -- 0.5-2.5 seconds between casts
    end

    -- Random special ability usage
    bot.specialTimer = bot.specialTimer - dt
    if bot.specialTimer <= 0 then
        -- Find nearest enemy for targeting
        local nearest = nil
        local nearestDist = math.huge
        for _, other in ipairs(allPlayers) do
            if other.id ~= player.id and other.life and other.life > 0 then
                local dist = math.abs(other.x - player.x)
                if dist < nearestDist then
                    nearestDist = dist
                    nearest = other
                end
            end
        end
        if nearest and player.shapeKey then
            local dir = nearest.x > player.x and 1 or -1
            player.facingRight = (dir == 1)
            Abilities.cast(player, player.shapeKey, dir > 0, nearest.x, nearest.y)
        end
        bot.specialTimer = math.random() * 8 + 4  -- 4-12 seconds between specials
    end

    -- Random movement direction changes
    bot.moveTimer = bot.moveTimer - dt
    if bot.moveTimer <= 0 then
        bot.moveDir = math.random() < 0.5 and -1 or 1
        bot.moveTimer = math.random() * 2 + 0.5  -- 0.5-2.5 seconds per direction
    end

    -- Apply movement
    player.vx = player.speed * bot.moveDir
    player.facingRight = bot.moveDir > 0

    -- Avoid walls - reverse direction if near edge
    if player.x < 100 then
        bot.moveDir = 1
        player.facingRight = true
    elseif player.x > 1180 then
        bot.moveDir = -1
        player.facingRight = false
    end
end

-- Start demo mode
function startDemoMode()
    demoMode = true
    maxPlayers = 3
    serverMode = false

    -- Create players: P1 is local human, P2 and P3 are bots
    players = {}
    players[1] = Player.new(1, Config.getControls())
    -- Set player name from config
    local configName = Config.getPlayerName()
    if configName then players[1].name = configName end
    players[2] = Player.new(2, nil)
    players[2].isRemote = false  -- not remote, but AI controlled
    players[2].name = "Bot 1"
    players[3] = Player.new(3, nil)
    players[3].isRemote = false
    players[3].name = "Bot 2"

    -- Assign random shapes to bots
    local Shapes = require("shapes")
    local shapeKeys = Shapes.order
    local humanShape = shapeKeys[math.random(#shapeKeys)]
    local bot1Shape = shapeKeys[math.random(#shapeKeys)]
    local bot2Shape = shapeKeys[math.random(#shapeKeys)]

    players[1]:setShape(humanShape)
    players[2]:setShape(bot1Shape)
    players[3]:setShape(bot2Shape)

    -- Apply demo invulnerability to P1 if setting is enabled
    players[1].invulnerable = Config.getDemoInvulnerable()

    -- Create bot AI states
    bots = {
        [2] = createBotState(2),
        [3] = createBotState(3)
    }

    -- Spawn positions
    Projectiles.clear()
    Abilities.clear()
    local stageLeft = 250
    local stageRight = 1030
    local stageMiddle = (stageLeft + stageRight) / 2
    players[1]:spawn(stageLeft, Physics.GROUND_Y - players[1].shapeHeight / 2)
    players[2]:spawn(stageMiddle, Physics.GROUND_Y - players[2].shapeHeight / 2)
    players[3]:spawn(stageRight, Physics.GROUND_Y - players[3].shapeHeight / 2)

    -- Start countdown
    countdownTimer = 3.0
    countdownValue = 3
    gameState = "countdown"
    Lightning.reset()
    Dropbox.reset()

    -- Initialize camera to correct position immediately
    initCamera(players)
end

-- Restart demo mode
function restartDemoMode()
    winner = nil
    Projectiles.clear()
    Abilities.clear()
    Lightning.reset()
    Dropbox.reset()
    startDemoMode()
end

-- Update demo mode (called from love.update when demoMode is true)
function updateDemoMode(dt)
    -- Update all players
    for _, p in ipairs(players) do
        if p.life > 0 then
            p:update(dt)
            -- Check for landing (sound + dust)
            if p:consumeLanding() then
                Sounds.play("land")
                Projectiles.spawnLandingDust(p.x, p.y + p.shapeHeight / 2)
            end
        end
    end

    -- Update bot AI
    for botId, bot in pairs(bots) do
        if players[botId] then
            updateBotAI(bot, players[botId], dt, players)
        end
    end

    -- Resolve collisions
    Physics.resolveAllCollisions(players, dt)

    -- Spawn dash impact particles
    for _, impact in ipairs(Physics.consumeDashImpacts()) do
        Projectiles.spawnDashImpact(impact.x, impact.y)
        addScreenShake(6, 0.15, 40)
        addHitPause(0.05)
        addCameraZoom(1.02, 0.15)
    end

    -- Update projectiles
    Projectiles.update(dt, players)

    -- Update special abilities
    Abilities.update(dt, players)

    -- Update lightning
    Lightning.update(dt, players)

    -- Screen shake on lightning strike
    if Lightning.consumeStrike() then
        addScreenShake(8, 0.3, 25)
        Background.onLightningStrike()  -- Brighten clouds
    end

    -- Update dropboxes
    Dropbox.update(dt, players)

    -- Check for player deaths (explosion effect)
    for _, p in ipairs(players) do
        p:checkDeath(dt)
        if p:consumeDeath() then
            Sounds.play("death")
            Projectiles.spawnDeathExplosion(p.x, p.y, p.shapeKey)
            addScreenShake(12, 0.5, 20)
            addHitPause(0.08)
            addCameraZoom(1.05, 0.25)
        end
    end

    -- Continuous aiming: update local player aim position every frame
    local localPlayer = players[1]  -- In demo mode, P1 is always local
    if localPlayer and localPlayer.life > 0 then
        local mx, my = love.mouse.getPosition()
        local gameX = (mx - offsetX) / GLOBAL_SCALE
        local gameY = (my - offsetY) / GLOBAL_SCALE
        local W, H = GAME_WIDTH, GAME_HEIGHT
        local worldX = (gameX - W/2) / cameraZoom + W/2 + cameraX
        local worldY = (gameY - H/2) / cameraZoom + H/2 + cameraY
        localPlayer.aimX = worldX
        localPlayer.aimY = worldY
    end

    -- Check for game over
    checkGameOver()
end

-- ─────────────────────────────────────────────
-- Mouse handling
-- ─────────────────────────────────────────────
function love.mousemoved(x, y, dx, dy, istouch)
    -- Normalize coordinates
    local gx, gy = windowToGame(x, y)
    local W, H = GAME_WIDTH, GAME_HEIGHT

    if gameState == "menu" then
        -- Menu items centered, verify coordinates from drawMenu
        local menuY = 240
        local itemHeight = 50
        local menuWidth = 400 -- clickable area width
        local menuX = (W - menuWidth) / 2
        
        for i = 1, 4 do
            local itemY = menuY + (i - 1) * itemHeight
            -- Check if mouse is roughly over the text item
            if isMouseOver(gx, gy, menuX, itemY, menuWidth, itemHeight) then
                if menuChoice ~= i then
                    menuChoice = i
                    Sounds.play("menu_nav")
                end
            end
        end

    elseif gameState == "settings" then
        if settingsEditingName then return end

        -- Grid layout parameters from drawSettings
        local colWidth = 320
        local leftColX = W/2 - colWidth - 40
        local rightColX = W/2 + 40
        local startY = 100
        local rowHeight = 115
        local maxRows = 4
        
        -- Check left column
        for r = 1, maxRows do
            local cellX = leftColX
            local cellY = startY + (r - 1) * rowHeight
            -- The box is drawn at x-10, y-8 with size colWidth+20, rowHeight-20
            if isMouseOver(gx, gy, cellX - 10, cellY - 8, colWidth + 20, rowHeight - 20) then
                if settingsCol ~= 1 or settingsRow ~= r then
                    settingsCol = 1
                    settingsRow = r
                    Sounds.play("menu_nav")
                end
            end
        end
        
        -- Check right column
        for r = 1, 3 do -- only 3 rows in right column
            local cellX = rightColX
            local cellY = startY + (r - 1) * rowHeight
             if isMouseOver(gx, gy, cellX - 10, cellY - 8, colWidth + 20, rowHeight - 20) then
                if settingsCol ~= 2 or settingsRow ~= r then
                    settingsCol = 2
                    settingsRow = r
                    Sounds.play("menu_nav")
                end
            end
        end
    end
end

function love.mousepressed(x, y, button, istouch, presses)
    if button == 1 then
        -- Left click behaviors
        if gameState == "menu" then
            local gx, gy = windowToGame(x, y)
            local W, H = GAME_WIDTH, GAME_HEIGHT
            local menuY = 240
            local itemHeight = 50
            local menuWidth = 400
            local menuX = (W - menuWidth) / 2
            
            local clickedItem = nil
            for i = 1, 4 do
                local itemY = menuY + (i - 1) * itemHeight
                if isMouseOver(gx, gy, menuX, itemY, menuWidth, itemHeight) then
                    clickedItem = i
                    break
                end
            end
            
            if clickedItem and clickedItem == menuChoice then
                handleMenuKey("return")
            end

        elseif gameState == "settings" then
             -- Similarly for settings
            if settingsEditingName then
                -- Check if we clicked outside to stop editing?
                 return
            end

            local gx, gy = windowToGame(x, y)
            local W, H = GAME_WIDTH, GAME_HEIGHT
            local colWidth = 320
            local leftColX = W/2 - colWidth - 40
            local rightColX = W/2 + 40
            local startY = 100
            local rowHeight = 115
            
            -- Check if clicked on current selection
            local clicked = false
            -- Left col
            if settingsCol == 1 then
                local r = settingsRow
                local cellX = leftColX
                local cellY = startY + (r - 1) * rowHeight
                if isMouseOver(gx, gy, cellX - 10, cellY - 8, colWidth + 20, rowHeight - 20) then
                    clicked = true
                end
            elseif settingsCol == 2 then
                local r = settingsRow
                local cellX = rightColX
                local cellY = startY + (r - 1) * rowHeight
                if isMouseOver(gx, gy, cellX - 10, cellY - 8, colWidth + 20, rowHeight - 20) then
                    clicked = true
                end
            end
            
            if clicked then
                handleSettingsKey("return")
            end
        end
    end
end