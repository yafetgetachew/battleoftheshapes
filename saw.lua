-- saw.lua
-- Rolling saw hazard system for B.O.T.S

local Physics = require("physics")
local Sounds  = require("sounds")
local Network = require("network")

local Saw = {}

-- Configuration
Saw.DAMAGE = 3                    -- damage per hit
Saw.HIT_COOLDOWN = 0.33           -- seconds between hits on same player (3 hits/sec max)
Saw.SIZE = 48                     -- diameter of the saw blade
Saw.MIN_INTERVAL = 8              -- minimum seconds between spawns
Saw.MAX_INTERVAL = 15             -- maximum seconds between spawns
Saw.WARNING_DURATION = 1.0        -- warning duration before saw drops
Saw.GRAVITY = Physics.GRAVITY * 0.8  -- slightly less gravity for more air time
Saw.BOUNCE = 0.85                 -- high bounce factor for bouncy behavior
Saw.FRICTION = 0.995              -- very low friction to keep moving
Saw.LIFETIME = 15                 -- longer lifetime for more bouncing
Saw.ROTATION_SPEED = 8            -- radians per second base rotation
Saw.INITIAL_VX_RANGE = 300        -- higher initial horizontal velocity
Saw.JITTER_CHANCE = 0.15          -- 15% chance per frame to add jitter
Saw.JITTER_STRENGTH = 150         -- random velocity jitter strength
Saw.MIN_BOUNCE_VY = 200           -- minimum vertical velocity when bouncing (keeps bouncing)

-- Callbacks for juice effects (set by main.lua)
Saw.onHit = nil                   -- function(x, y, damage, playerId) called when saw hits a player
Saw.onWarningStart = nil          -- function(x) called when warning appears
Saw.onSawSpawn = nil              -- function(x) called when saw actually spawns
Saw.onBounce = nil                -- function(x, y) called when saw bounces

-- State
local saws = {}           -- active saws
local warnings = {}       -- active warning indicators
local nextSpawnTimer = 6  -- countdown to next spawn
local hitCooldowns = {}   -- [sawId][playerId] = time remaining before can hit again
local sparks = {}         -- spark particle effects

local sawIdCounter = 0    -- unique ID for each saw

function Saw.reset()
    saws = {}
    warnings = {}
    hitCooldowns = {}
    sparks = {}
    nextSpawnTimer = Saw.MIN_INTERVAL + math.random() * (Saw.MAX_INTERVAL - Saw.MIN_INTERVAL)
    sawIdCounter = 0
end

-- Get current state for network sync (host → clients)
function Saw.getState()
    return {
        saws = saws,
        warnings = warnings,
        nextSpawnTimer = nextSpawnTimer,
        sawIdCounter = sawIdCounter
    }
end

-- Set state from network sync (clients receive from host)
function Saw.setState(state)
    if not state then return end
    saws = state.saws or {}
    warnings = state.warnings or {}
    nextSpawnTimer = state.nextSpawnTimer or 6
    sawIdCounter = state.sawIdCounter or 0
end

function Saw.update(dt, players)
    local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT

    if isAuthority then
        -- Spawn timer (host only)
        nextSpawnTimer = nextSpawnTimer - dt
        if nextSpawnTimer <= 0 then
            Saw._spawnWarning()
            nextSpawnTimer = Saw.MIN_INTERVAL + math.random() * (Saw.MAX_INTERVAL - Saw.MIN_INTERVAL)
        end

        -- Update warnings
        for i = #warnings, 1, -1 do
            local w = warnings[i]
            w.age = w.age + dt
            if w.age >= Saw.WARNING_DURATION then
                -- Spawn the actual saw
                Saw._spawnSaw(w.x)
                table.remove(warnings, i)
            end
        end

        -- Update hit cooldowns
        for sawId, playerCooldowns in pairs(hitCooldowns) do
            for pid, cd in pairs(playerCooldowns) do
                playerCooldowns[pid] = cd - dt
                if playerCooldowns[pid] <= 0 then
                    playerCooldowns[pid] = nil
                end
            end
        end

        -- Update saws with physics
        for i = #saws, 1, -1 do
            local saw = saws[i]
            saw.age = saw.age + dt

            -- Apply gravity
            saw.vy = saw.vy + Saw.GRAVITY * dt

            -- Add random jitter for jagged movement
            if math.random() < Saw.JITTER_CHANCE then
                saw.vx = saw.vx + (math.random() * 2 - 1) * Saw.JITTER_STRENGTH
                saw.vy = saw.vy + (math.random() * 2 - 1) * Saw.JITTER_STRENGTH * 0.5
            end

            -- Apply velocity
            saw.x = saw.x + saw.vx * dt
            saw.y = saw.y + saw.vy * dt

            -- Update rotation based on horizontal movement (erratic)
            saw.rotation = saw.rotation + (saw.vx / 50) * dt + Saw.ROTATION_SPEED * dt
            -- Add rotation jitter
            if math.random() < 0.1 then
                saw.rotation = saw.rotation + (math.random() * 2 - 1) * 0.5
            end

            -- Ground collision with bounce
            local halfSize = Saw.SIZE / 2
            if saw.y + halfSize >= Physics.GROUND_Y then
                saw.y = Physics.GROUND_Y - halfSize
                if saw.vy > 50 then
                    if Saw.onBounce then Saw.onBounce(saw.x, saw.y) end
                    -- Spawn sparks on ground bounce
                    Saw.spawnSparks(saw.x, Physics.GROUND_Y, 8, false)
                end
                -- Bounce with minimum velocity to keep bouncing
                saw.vy = -math.abs(saw.vy) * Saw.BOUNCE
                if math.abs(saw.vy) < Saw.MIN_BOUNCE_VY then
                    -- Re-energize the bounce to keep it going
                    saw.vy = -Saw.MIN_BOUNCE_VY * (0.8 + math.random() * 0.4)
                    -- Add some random horizontal kick
                    saw.vx = saw.vx + (math.random() * 2 - 1) * 100
                end
                saw.onGround = false  -- Never truly settle
                -- Less friction to keep moving
                saw.vx = saw.vx * Saw.FRICTION
            else
                saw.onGround = false
            end

            -- Wall collision with bounce
            if saw.x - halfSize < Physics.WALL_LEFT then
                saw.x = Physics.WALL_LEFT + halfSize
                saw.vx = math.abs(saw.vx) * Saw.BOUNCE
                -- Add vertical kick on wall bounce
                saw.vy = saw.vy - 50 - math.random() * 100
                if Saw.onBounce then Saw.onBounce(saw.x, saw.y) end
                -- Spawn sparks on wall bounce
                Saw.spawnSparks(Physics.WALL_LEFT, saw.y, 6, false)
            elseif saw.x + halfSize > Physics.WALL_RIGHT then
                saw.x = Physics.WALL_RIGHT - halfSize
                saw.vx = -math.abs(saw.vx) * Saw.BOUNCE
                -- Add vertical kick on wall bounce
                saw.vy = saw.vy - 50 - math.random() * 100
                if Saw.onBounce then Saw.onBounce(saw.x, saw.y) end
                -- Spawn sparks on wall bounce
                Saw.spawnSparks(Physics.WALL_RIGHT, saw.y, 6, false)
            end

            -- Player collision and damage
            if players then
                for _, player in ipairs(players) do
                    if player.life and player.life > 0 and not player.invulnerable then
                        if Saw._checkCollision(saw, player) then
                            Saw._hitPlayer(saw, player)
                        end
                    end
                end
            end

            -- Remove expired saws
            if saw.age >= Saw.LIFETIME then
                hitCooldowns[saw.id] = nil
                table.remove(saws, i)
            end
        end
    else
        -- Client: just update visual state (rotation, age)
        for _, saw in ipairs(saws) do
            saw.age = saw.age + dt
            saw.rotation = saw.rotation + (saw.vx / 50) * dt + Saw.ROTATION_SPEED * dt
        end
        for _, w in ipairs(warnings) do
            w.age = w.age + dt
        end
    end

    -- Update spark particles (both host and client)
    Saw._updateSparks(dt)
end

function Saw._spawnWarning()
    local margin = 80
    local x = Physics.WALL_LEFT + margin + math.random() * (Physics.WALL_RIGHT - Physics.WALL_LEFT - margin * 2)
    table.insert(warnings, {
        x = x,
        age = 0
    })
    if Saw.onWarningStart then
        Saw.onWarningStart(x)
    end
end

function Saw._spawnSaw(x)
    sawIdCounter = sawIdCounter + 1
    local saw = {
        id = sawIdCounter,
        x = x,
        y = -Saw.SIZE,  -- start above screen
        vx = (math.random() - 0.5) * Saw.INITIAL_VX_RANGE,  -- random horizontal velocity
        vy = 100 + math.random() * 100,  -- start with some downward velocity
        rotation = math.random() * math.pi * 2,  -- random initial rotation
        age = 0,
        onGround = false
    }
    table.insert(saws, saw)
    hitCooldowns[saw.id] = {}
    if Saw.onSawSpawn then
        Saw.onSawSpawn(x)
    end
end

function Saw._checkCollision(saw, player)
    -- Circle vs AABB collision
    local halfSize = Saw.SIZE / 2
    local halfPW = player.shapeWidth / 2
    local halfPH = player.shapeHeight / 2

    -- Find closest point on player AABB to saw center
    local closestX = math.max(player.x - halfPW, math.min(saw.x, player.x + halfPW))
    local closestY = math.max(player.y - halfPH, math.min(saw.y, player.y + halfPH))

    -- Calculate distance from closest point to saw center
    local dx = saw.x - closestX
    local dy = saw.y - closestY
    local distSq = dx * dx + dy * dy

    return distSq < (halfSize * halfSize)
end

function Saw._hitPlayer(saw, player)
    -- Check cooldown
    if hitCooldowns[saw.id] and hitCooldowns[saw.id][player.id] then
        return  -- Still on cooldown
    end

    -- Apply damage
    local prevLife = player.life
    local dmg = Saw.DAMAGE

    -- Armor absorbs damage first
    if player.armor and player.armor > 0 then
        local absorbed = math.min(player.armor, dmg)
        dmg = dmg - absorbed
        player.armor = player.armor - absorbed
        if player.armor <= 0 then player.armor = 0 end
    end

    player.life = math.max(0, player.life - dmg)
    local actualDmg = prevLife - player.life
    player.hitFlash = 0.15
    Sounds.play("player_hurt")

    -- Set cooldown
    if not hitCooldowns[saw.id] then
        hitCooldowns[saw.id] = {}
    end
    hitCooldowns[saw.id][player.id] = Saw.HIT_COOLDOWN

    -- Apply knockback (push player away from saw)
    local dx = player.x - saw.x
    local direction = dx >= 0 and 1 or -1
    player.vx = player.vx + direction * 200
    player.vy = player.vy - 150

    -- Spawn sparks at collision point
    local hitX = (saw.x + player.x) / 2
    local hitY = (saw.y + player.y) / 2
    Saw.spawnSparks(hitX, hitY, 12, true)

    -- Trigger juice callback
    if Saw.onHit and actualDmg > 0 then
        Saw.onHit(player.x, player.y, actualDmg, player.id)
    end
end

function Saw.draw()
    -- Draw warnings (in the sky, indicating where saw will drop)
    for _, w in ipairs(warnings) do
        local progress = w.age / Saw.WARNING_DURATION
        local pulse = 0.5 + 0.5 * math.sin(w.age * 15)
        local alpha = 0.4 + 0.4 * progress + 0.2 * pulse

        -- Warning line from top of screen to where saw will appear
        love.graphics.setColor(1.0, 0.3, 0.1, alpha * 0.5)
        love.graphics.setLineWidth(2 + progress * 4)
        love.graphics.line(w.x, 0, w.x, 60 + 40 * progress)

        -- Danger triangle at top
        local triSize = 15 + 10 * progress
        love.graphics.setColor(1.0, 0.4, 0.1, alpha)
        love.graphics.polygon("fill",
            w.x, 30 + triSize,
            w.x - triSize * 0.7, 30,
            w.x + triSize * 0.7, 30
        )

        -- Exclamation mark
        love.graphics.setColor(0, 0, 0, alpha)
        love.graphics.setLineWidth(3)
        love.graphics.line(w.x, 32, w.x, 45)
        love.graphics.circle("fill", w.x, 50, 2)

        -- Ground target indicator
        love.graphics.setColor(1.0, 0.3, 0.1, alpha * 0.3)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", w.x, Physics.GROUND_Y, 30 * progress)
    end

    -- Draw saws
    for _, saw in ipairs(saws) do
        local halfSize = Saw.SIZE / 2
        local fadeAlpha = 1.0
        -- Fade out in last 2 seconds
        if saw.age > Saw.LIFETIME - 2 then
            fadeAlpha = (Saw.LIFETIME - saw.age) / 2
        end

        love.graphics.push()
        love.graphics.translate(saw.x, saw.y)
        love.graphics.rotate(saw.rotation)

        -- Motion blur effect (when moving fast)
        local speed = math.sqrt(saw.vx * saw.vx + saw.vy * saw.vy)
        if speed > 100 then
            local blurAlpha = math.min(0.3, speed / 1000) * fadeAlpha
            love.graphics.setColor(0.7, 0.7, 0.7, blurAlpha)
            love.graphics.circle("fill", -saw.vx * 0.02, -saw.vy * 0.02, halfSize)
        end

        -- Outer blade (dark gray)
        love.graphics.setColor(0.3, 0.3, 0.35, fadeAlpha)
        love.graphics.circle("fill", 0, 0, halfSize)

        -- Blade teeth (lighter, jagged edge effect)
        love.graphics.setColor(0.5, 0.5, 0.55, fadeAlpha)
        local teeth = 12
        for i = 1, teeth do
            local angle = (i / teeth) * math.pi * 2
            local innerR = halfSize * 0.7
            local outerR = halfSize
            love.graphics.polygon("fill",
                math.cos(angle) * innerR, math.sin(angle) * innerR,
                math.cos(angle + 0.15) * outerR, math.sin(angle + 0.15) * outerR,
                math.cos(angle - 0.15) * outerR, math.sin(angle - 0.15) * outerR
            )
        end

        -- Center hub
        love.graphics.setColor(0.6, 0.1, 0.1, fadeAlpha)
        love.graphics.circle("fill", 0, 0, halfSize * 0.3)

        -- Center hole
        love.graphics.setColor(0.1, 0.1, 0.1, fadeAlpha)
        love.graphics.circle("fill", 0, 0, halfSize * 0.12)

        love.graphics.pop()

    end

    -- Draw spark particles
    for _, spark in ipairs(sparks) do
        for _, pt in ipairs(spark.particles) do
            local alpha = (pt.life / pt.maxLife)
            -- Yellow/orange gradient based on life
            local r = 1.0
            local g = 0.5 + 0.4 * alpha
            local b = 0.1 * alpha
            love.graphics.setColor(r, g, b, alpha)
            love.graphics.circle("fill", pt.x, pt.y, pt.r)
        end
    end

    love.graphics.setColor(1, 1, 1)
    love.graphics.setLineWidth(1)
end

-- Spawn spark particles at a location (called on bounce/hit)
function Saw.spawnSparks(x, y, count, isHit)
    count = count or 10
    local spark = {
        age = 0,
        particles = {}
    }
    for _ = 1, count do
        local angle = math.random() * math.pi * 2
        local speed = 80 + math.random() * 180
        -- For hits, sparks go more upward; for bounces, more outward
        local vyOffset = isHit and -100 or -50
        table.insert(spark.particles, {
            x = x + (math.random() - 0.5) * 10,
            y = y + (math.random() - 0.5) * 10,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed + vyOffset,
            r = math.random() * 2.5 + 1,
            life = 0.2 + math.random() * 0.3,
            maxLife = 0.5
        })
    end
    table.insert(sparks, spark)
end

-- Update spark particles (called from Saw.update)
function Saw._updateSparks(dt)
    for i = #sparks, 1, -1 do
        local spark = sparks[i]
        spark.age = spark.age + dt
        for j = #spark.particles, 1, -1 do
            local pt = spark.particles[j]
            pt.x = pt.x + pt.vx * dt
            pt.y = pt.y + pt.vy * dt
            pt.vy = pt.vy + 400 * dt  -- gravity on sparks
            pt.life = pt.life - dt
            if pt.life <= 0 then
                table.remove(spark.particles, j)
            end
        end
        -- Remove empty spark effects
        if #spark.particles == 0 then
            table.remove(sparks, i)
        end
    end
end

return Saw
