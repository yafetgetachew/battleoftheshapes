-- pacman.lua
-- Pacman monster hazard system for B.O.T.S
-- Monsters that roam the ground, bite players, and can be killed for health

local Physics = require("physics")
local Sounds  = require("sounds")
local Network = require("network")
local Map     = require("map")

local Pacman = {}

-- Configuration
Pacman.DAMAGE = 30                    -- damage per bite
Pacman.MONSTER_HP = 40                -- health points per monster
Pacman.MONSTER_SIZE = 48              -- diameter of monster
Pacman.MONSTER_SPEED = 175            -- horizontal movement speed (pixels/sec)
Pacman.FIRST_SPAWN_TIME = 30          -- first spawn at 30 seconds
Pacman.MIN_INTERVAL = 15              -- minimum seconds between subsequent spawns
Pacman.MAX_INTERVAL = 25              -- maximum seconds between subsequent spawns
Pacman.MONSTERS_PER_SPAWN = 4         -- spawn 4 monsters at once
Pacman.LIFETIME = 12                  -- seconds before despawn if not killed
Pacman.BITE_COOLDOWN = 0.8            -- seconds between bites on same player
Pacman.MOUTH_SPEED = 8                -- mouth animation speed (radians/sec)
Pacman.GRAVITY = 1800                 -- gravity for monsters (slightly less than player)
Pacman.FALL_OFF_CHANCE = 0.02         -- chance per second to fall off platform edge

-- Callbacks for juice effects (set by main.lua)
Pacman.onBite = nil                   -- function(x, y, damage, playerId)
Pacman.onKill = nil                   -- function(x, y, killerId)
Pacman.onSpawn = nil                  -- function()

-- State
local monsters = {}           -- active monsters
local nextSpawnTimer = 30     -- countdown to next spawn (first at 30 seconds)
local biteCooldowns = {}      -- [monsterId][playerId] = time remaining
local monsterIdCounter = 0    -- unique ID for each monster
local deathEffects = {}       -- death particle effects
local hasSpawnedOnce = false  -- track if first spawn has occurred

function Pacman.reset()
    monsters = {}
    biteCooldowns = {}
    deathEffects = {}
    monsterIdCounter = 0
    nextSpawnTimer = Pacman.FIRST_SPAWN_TIME
    hasSpawnedOnce = false
end

-- Get current state for network sync (host → clients)
function Pacman.getState()
    return {
        monsters = monsters,
        nextSpawnTimer = nextSpawnTimer,
        hasSpawnedOnce = hasSpawnedOnce
    }
end

-- Set state from network sync (clients receive from host)
function Pacman.setState(state)
    if not state then return end
    monsters = state.monsters or {}
    nextSpawnTimer = state.nextSpawnTimer or 30
    hasSpawnedOnce = state.hasSpawnedOnce or false
end

function Pacman.update(dt, players)
    -- Only host (or solo/demo) runs the authoritative simulation
    local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT

    if isAuthority then
        -- Spawn timer
        nextSpawnTimer = nextSpawnTimer - dt
        if nextSpawnTimer <= 0 then
            Pacman._spawnMonsters()
            -- After first spawn, use random interval
            if hasSpawnedOnce then
                nextSpawnTimer = Pacman.MIN_INTERVAL + math.random() * (Pacman.MAX_INTERVAL - Pacman.MIN_INTERVAL)
            else
                hasSpawnedOnce = true
                nextSpawnTimer = Pacman.MIN_INTERVAL + math.random() * (Pacman.MAX_INTERVAL - Pacman.MIN_INTERVAL)
            end
        end

        -- Update bite cooldowns
        for mId, playerCooldowns in pairs(biteCooldowns) do
            for pId, cd in pairs(playerCooldowns) do
                playerCooldowns[pId] = cd - dt
                if playerCooldowns[pId] <= 0 then
                    playerCooldowns[pId] = nil
                end
            end
        end

        -- Update monsters
        for i = #monsters, 1, -1 do
            local m = monsters[i]
            m.age = m.age + dt
            m.mouthAngle = m.mouthAngle + Pacman.MOUTH_SPEED * dt

            -- Initialize vy if not present
            if not m.vy then m.vy = 0 end
            if m.onGround == nil then m.onGround = true end

            -- Apply gravity
            m.vy = m.vy + Pacman.GRAVITY * dt

            -- Move horizontally and vertically
            m.x = m.x + m.vx * dt
            m.y = m.y + m.vy * dt

            local halfSize = Pacman.MONSTER_SIZE / 2
            m.onGround = false

            -- Check platform collisions (only when falling)
            if m.vy >= 0 then
                for _, plat in ipairs(Map.platforms) do
                    local platTop = plat.y - plat.h / 2
                    local platLeft = plat.x - plat.w / 2
                    local platRight = plat.x + plat.w / 2

                    -- Check if monster is above platform and within horizontal bounds
                    if m.x > platLeft and m.x < platRight then
                        local monsterBottom = m.y + halfSize
                        local prevBottom = monsterBottom - m.vy * dt

                        -- Landing on platform
                        if prevBottom <= platTop and monsterBottom >= platTop then
                            m.y = platTop - halfSize
                            m.vy = 0
                            m.onGround = true
                        end
                    end
                end
            end

            -- Ground collision
            if m.y + halfSize >= Physics.GROUND_Y then
                m.y = Physics.GROUND_Y - halfSize
                m.vy = 0
                m.onGround = true
            end

            -- Wall collision - reverse direction
            if m.x - halfSize < Physics.WALL_LEFT then
                m.x = Physics.WALL_LEFT + halfSize
                m.vx = math.abs(m.vx)
                m.direction = 1
            elseif m.x + halfSize > Physics.WALL_RIGHT then
                m.x = Physics.WALL_RIGHT - halfSize
                m.vx = -math.abs(m.vx)
                m.direction = -1
            end

            -- Check collision with players (bite)
            if players then
                for _, player in ipairs(players) do
                    if player.life and player.life > 0 and not player.invulnerable then
                        if Pacman._checkCollision(m, player) then
                            Pacman._bitePlayer(m, player)
                        end
                    end
                end
            end

            -- Remove expired monsters
            if m.age >= Pacman.LIFETIME then
                -- Clean up cooldowns
                biteCooldowns[m.id] = nil
                table.remove(monsters, i)
            elseif m.hp <= 0 then
                -- Monster killed - already handled in hitMonster
                biteCooldowns[m.id] = nil
                table.remove(monsters, i)
            end
        end
    else
        -- Client: just update visual state (mouth animation, age)
        for _, m in ipairs(monsters) do
            m.age = m.age + dt
            m.mouthAngle = m.mouthAngle + Pacman.MOUTH_SPEED * dt
        end
    end

    -- Update death effects (both host and client)
    Pacman._updateDeathEffects(dt)
end

-- Get all spawn locations (ground + platforms)
function Pacman._getSpawnLocations()
    local locations = {}

    -- Add ground as a spawn location
    table.insert(locations, {
        y = Physics.GROUND_Y,
        xMin = Physics.WALL_LEFT + 50,
        xMax = Physics.WALL_RIGHT - 50
    })

    -- Add platforms as spawn locations
    for _, plat in ipairs(Map.platforms) do
        table.insert(locations, {
            y = plat.y - plat.h / 2,  -- Top of platform
            xMin = plat.x - plat.w / 2 + 20,
            xMax = plat.x + plat.w / 2 - 20
        })
    end

    return locations
end

function Pacman._spawnMonsters()
    local spawnLocations = Pacman._getSpawnLocations()

    for i = 1, Pacman.MONSTERS_PER_SPAWN do
        monsterIdCounter = monsterIdCounter + 1

        -- Pick a random spawn location (ground or platform)
        local loc = spawnLocations[math.random(#spawnLocations)]
        local x = loc.xMin + math.random() * (loc.xMax - loc.xMin)
        local y = loc.y - Pacman.MONSTER_SIZE / 2

        -- Random direction
        local direction = math.random() > 0.5 and 1 or -1
        local speed = Pacman.MONSTER_SPEED * (0.85 + math.random() * 0.3)  -- Slight speed variation

        local monster = {
            id = monsterIdCounter,
            x = x,
            y = y,
            vy = 0,  -- Vertical velocity for gravity
            vx = direction * speed,
            direction = direction,
            hp = Pacman.MONSTER_HP,
            age = 0,
            mouthAngle = math.random() * math.pi * 2,  -- Random starting mouth phase
            onGround = true
        }
        table.insert(monsters, monster)
    end

    -- Trigger spawn callback
    if Pacman.onSpawn then
        Pacman.onSpawn()
    end
    Sounds.play("pacman_spawn")
end

function Pacman._checkCollision(monster, player)
    local halfSize = Pacman.MONSTER_SIZE / 2
    local dx = player.x - monster.x
    local dy = player.y - monster.y

    -- Simple circle collision
    local playerRadius = (player.shapeWidth or 40) / 2
    local combinedRadius = halfSize + playerRadius - 5  -- Small overlap tolerance

    return (dx * dx + dy * dy) < (combinedRadius * combinedRadius)
end

function Pacman._bitePlayer(monster, player)
    -- Check cooldown
    if biteCooldowns[monster.id] and biteCooldowns[monster.id][player.id] then
        return  -- Still on cooldown
    end

    -- Apply damage
    local prevLife = player.life
    local dmg = Pacman.DAMAGE

    -- Armor absorbs damage first
    if player.armor and player.armor > 0 then
        local absorbed = math.min(player.armor, dmg)
        dmg = dmg - absorbed
        player.armor = player.armor - absorbed
        if player.armor <= 0 then player.armor = 0 end
    end

    player.life = math.max(0, player.life - dmg)
    local actualDmg = prevLife - player.life
    player.hitFlash = 0.2
    Sounds.play("pacman_bite")

    -- Set cooldown
    if not biteCooldowns[monster.id] then
        biteCooldowns[monster.id] = {}
    end
    biteCooldowns[monster.id][player.id] = Pacman.BITE_COOLDOWN

    -- Apply knockback (push player away from monster)
    local dx = player.x - monster.x
    local direction = dx >= 0 and 1 or -1
    player.vx = player.vx + direction * 250
    player.vy = player.vy - 200

    -- Trigger juice callback
    if Pacman.onBite and actualDmg > 0 then
        Pacman.onBite(player.x, player.y, actualDmg, player.id)
    end
end

-- Called by projectiles/abilities to damage monsters
-- Returns true if a monster was hit, and the player who gets the kill reward
function Pacman.hitMonster(x, y, radius, damage, attackerId, players)
    local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT
    if not isAuthority then return false end

    for i = #monsters, 1, -1 do
        local m = monsters[i]
        local dx = x - m.x
        local dy = y - m.y
        local dist = math.sqrt(dx * dx + dy * dy)
        local hitRadius = radius + Pacman.MONSTER_SIZE / 2

        if dist < hitRadius then
            m.hp = m.hp - damage

            -- Visual feedback
            m.hitFlash = 0.15

            if m.hp <= 0 then
                -- Monster killed!
                Pacman._spawnDeathEffect(m.x, m.y)
                Sounds.play("pacman_death")

                -- Find the attacker and restore their health
                if players and attackerId then
                    for _, player in ipairs(players) do
                        if player.id == attackerId and player.life > 0 then
                            player.life = player.maxLife or 100
                            -- Trigger kill callback
                            if Pacman.onKill then
                                Pacman.onKill(m.x, m.y, attackerId)
                            end
                            break
                        end
                    end
                end

                -- Remove monster
                biteCooldowns[m.id] = nil
                table.remove(monsters, i)
            end

            return true
        end
    end

    return false
end

function Pacman._spawnDeathEffect(x, y)
    local effect = {
        x = x,
        y = y,
        age = 0,
        particles = {}
    }
    -- Yellow/orange burst of particles
    for _ = 1, 20 do
        local angle = math.random() * math.pi * 2
        local speed = 100 + math.random() * 200
        table.insert(effect.particles, {
            x = x + (math.random() - 0.5) * 20,
            y = y + (math.random() - 0.5) * 20,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed - 80,
            r = math.random() * 4 + 2,
            life = 0.4 + math.random() * 0.3,
            maxLife = 0.7
        })
    end
    table.insert(deathEffects, effect)
end

function Pacman._updateDeathEffects(dt)
    for i = #deathEffects, 1, -1 do
        local e = deathEffects[i]
        e.age = e.age + dt
        for j = #e.particles, 1, -1 do
            local pt = e.particles[j]
            pt.x = pt.x + pt.vx * dt
            pt.y = pt.y + pt.vy * dt
            pt.vy = pt.vy + 400 * dt  -- gravity
            pt.life = pt.life - dt
            if pt.life <= 0 then
                table.remove(e.particles, j)
            end
        end
        if #e.particles == 0 then
            table.remove(deathEffects, i)
        end
    end
end

function Pacman.draw()
    -- Draw monsters
    for _, m in ipairs(monsters) do
        local halfSize = Pacman.MONSTER_SIZE / 2
        local fadeAlpha = 1.0
        -- Fade out in last 2 seconds
        if m.age > Pacman.LIFETIME - 2 then
            fadeAlpha = (Pacman.LIFETIME - m.age) / 2
        end

        -- Hit flash
        local flashMod = 1.0
        if m.hitFlash and m.hitFlash > 0 then
            flashMod = 0.5 + 0.5 * math.sin(m.hitFlash * 30)
            m.hitFlash = m.hitFlash - 0.016  -- Approximate dt
        end

        love.graphics.push()
        love.graphics.translate(m.x, m.y)

        -- Flip based on direction
        if m.direction < 0 then
            love.graphics.scale(-1, 1)
        end

        -- Mouth animation (opening and closing)
        local mouthOpen = math.abs(math.sin(m.mouthAngle)) * 0.4  -- 0 to 0.4 radians

        -- Main body (yellow pacman)
        love.graphics.setColor(1.0 * flashMod, 0.85 * flashMod, 0.1, fadeAlpha)

        -- Draw as arc (pacman shape)
        local segments = 32
        local vertices = {0, 0}  -- Center
        for i = 0, segments do
            local angle = mouthOpen + (math.pi * 2 - mouthOpen * 2) * (i / segments)
            local px = math.cos(angle) * halfSize
            local py = math.sin(angle) * halfSize
            table.insert(vertices, px)
            table.insert(vertices, py)
        end
        love.graphics.polygon("fill", vertices)

        -- Eye
        love.graphics.setColor(0, 0, 0, fadeAlpha)
        love.graphics.circle("fill", halfSize * 0.2, -halfSize * 0.4, halfSize * 0.15)

        -- Health bar (above monster)
        love.graphics.pop()

        -- Draw health bar
        local barWidth = Pacman.MONSTER_SIZE * 0.8
        local barHeight = 4
        local barY = m.y - halfSize - 10
        local hpPercent = m.hp / Pacman.MONSTER_HP

        -- Background
        love.graphics.setColor(0.2, 0.2, 0.2, fadeAlpha * 0.8)
        love.graphics.rectangle("fill", m.x - barWidth/2, barY, barWidth, barHeight)

        -- Health
        local healthColor = hpPercent > 0.5 and {0.2, 0.8, 0.2} or (hpPercent > 0.25 and {0.8, 0.6, 0.1} or {0.8, 0.2, 0.2})
        love.graphics.setColor(healthColor[1], healthColor[2], healthColor[3], fadeAlpha)
        love.graphics.rectangle("fill", m.x - barWidth/2, barY, barWidth * hpPercent, barHeight)
    end

    -- Draw death effects
    for _, e in ipairs(deathEffects) do
        for _, pt in ipairs(e.particles) do
            local alpha = pt.life / pt.maxLife
            love.graphics.setColor(1.0, 0.85 * alpha + 0.15, 0.1 * alpha, alpha)
            love.graphics.circle("fill", pt.x, pt.y, pt.r)
        end
    end

    love.graphics.setColor(1, 1, 1)
end

return Pacman
