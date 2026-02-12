-- abilities.lua
-- Shape-specific special abilities
-- Square: Laser Beam, Triangle: Triple Spikes, Rectangle: Falling Block, Circle: Rolling Boulder

local Physics = require("physics")
local Sounds  = require("sounds")
local Network = require("network")
local Map     = require("map")

local Abilities = {}

-- Will costs for each ability
Abilities.COSTS = {
    square    = 50,  -- Laser beam
    triangle  = 60,  -- Triple spikes (10 per spike)
    rectangle = 40,  -- Falling block
    circle    = 40,  -- Rolling boulder
}

-- Damage values
Abilities.DAMAGE = {
    square    = 30,  -- Laser (30 total over 1 second)
    triangle  = 15,  -- Per spike
    rectangle = 30,  -- Falling block
    circle    = 30,  -- Rolling boulder
}

-- Physics constants for ability projectiles
local ABILITY_GRAVITY = 600       -- gravity for ability projectiles (lighter than player gravity)
local ABILITY_BOUNCE = 0.5        -- bounce coefficient (energy retained)
local ABILITY_WALL_BOUNCE = 0.6   -- wall bounce coefficient

-- Knockback constant
local ABILITY_KNOCKBACK = 200

-- Callbacks for juice effects (set by main.lua)
Abilities.onHit = nil         -- function(x, y, damage) called when ability hits
Abilities.onKill = nil        -- function(x, y) called when a hit results in death

-- Active projectiles/effects
local activeSpikes = {}       -- Triangle spikes
local activeBlocks = {}       -- Rectangle falling blocks
local activeBoulders = {}     -- Circle rolling boulders
local activeLasers = {}       -- Square laser beams
local activeSparks = {}       -- Laser hit sparks
local activeDebris = {}       -- Block debris after tipping

-- ─────────────────────────────────────────────
-- Shared physics helper for ability projectiles
-- ─────────────────────────────────────────────
local function resolveAbilityGround(obj, radius)
    radius = radius or 0
    local footY = obj.y + radius
    if footY >= Physics.GROUND_Y then
        obj.y = Physics.GROUND_Y - radius
        if obj.vy > 0 then
            obj.vy = -obj.vy * ABILITY_BOUNCE
            obj.vx = obj.vx * 0.85  -- friction on bounce
            if math.abs(obj.vy) < 30 then
                obj.vy = 0
                obj.onGround = true
            end
        end
    end
end

local function resolveAbilityWalls(obj, radius)
    radius = radius or 0
    if obj.x - radius < Physics.WALL_LEFT then
        obj.x = Physics.WALL_LEFT + radius
        obj.vx = -obj.vx * ABILITY_WALL_BOUNCE
    elseif obj.x + radius > Physics.WALL_RIGHT then
        obj.x = Physics.WALL_RIGHT - radius
        obj.vx = -obj.vx * ABILITY_WALL_BOUNCE
    end
end

local function resolveAbilityPlatforms(obj, radius, dt)
    radius = radius or 0
    -- Only check if falling
    if obj.vy <= 0 then return end
    local footY = obj.y + radius
    local prevFootY = footY - obj.vy * dt
    for _, plat in ipairs(Map.platforms) do
        local platTop = plat.y - plat.h / 2
        local platLeft = plat.x - plat.w / 2
        local platRight = plat.x + plat.w / 2
        if obj.x > platLeft and obj.x < platRight then
            if prevFootY <= platTop and footY >= platTop then
                obj.y = platTop - radius
                if obj.vy > 0 then
                    obj.vy = -obj.vy * ABILITY_BOUNCE
                    obj.vx = obj.vx * 0.85
                    if math.abs(obj.vy) < 30 then
                        obj.vy = 0
                        obj.onGround = true
                    end
                end
                return
            end
        end
    end
end

local function applyAbilityPhysics(obj, dt, radius, useGravity)
    if useGravity ~= false then
        obj.vy = (obj.vy or 0) + ABILITY_GRAVITY * dt
    end
    obj.x = obj.x + (obj.vx or 0) * dt
    obj.y = obj.y + (obj.vy or 0) * dt
    resolveAbilityGround(obj, radius)
    resolveAbilityPlatforms(obj, radius, dt)
    resolveAbilityWalls(obj, radius)
end

-- ─────────────────────────────────────────────
-- Spawning functions
-- ─────────────────────────────────────────────

-- Square: Laser Beam (hitscan, instant damage over time)
function Abilities.spawnLaser(caster, facingRight, tx, ty)
    if caster.will < Abilities.COSTS.square then return false end
    caster.will = caster.will - Abilities.COSTS.square
    
    local dir = facingRight and 1 or -1
    local angle = 0
    if tx and ty then
        angle = math.atan2(ty - caster.y, tx - caster.x)
    else
        angle = (dir == 1) and 0 or math.pi
    end

    local laser = {
        owner = caster.id,
        x = caster.x,
        y = caster.y,
        angle = angle,
        dir = dir,
        duration = 1.0,      -- 1 second beam
        age = 0,
        damagePerHit = 1,    -- 1 damage per hit tick
        hitCooldown = {},    -- Per-player cooldown to prevent 60 damage/sec
        width = 800,         -- Beam length
        height = 8,          -- Beam thickness
    }
    table.insert(activeLasers, laser)
    Sounds.play("laser_fire")
    
    -- Apply squash to caster
    if caster.applySquash then
        caster:applySquash(1.3, 0.75, 0.2)
    end
    return true
end

-- Triangle: Triple Spike Shot
function Abilities.spawnSpikes(caster, facingRight)
    if caster.will < Abilities.COSTS.triangle then return false end
    caster.will = caster.will - Abilities.COSTS.triangle
    
    local dir = facingRight and 1 or -1
    local baseX = caster.x + dir * (caster.shapeWidth / 2 + 10)
    local baseY = caster.y
    
    -- Spawn three spikes: center, above, below (with slight upward/downward spread)
    local offsets = {0, -25, 25}
    local vyOffsets = {-30, -80, 20}  -- center arcs slightly, top arcs up, bottom arcs down
    for idx, yOffset in ipairs(offsets) do
        local spike = {
            type = "spike",
            owner = caster.id,
            x = baseX,
            y = baseY + yOffset,
            vx = 700 * dir,  -- Fast projectile
            vy = vyOffsets[idx],  -- Slight vertical arc
            damage = Abilities.DAMAGE.triangle,
            radius = 10,
            age = 0,
        }
        table.insert(activeSpikes, spike)
    end
    Sounds.play("spike_fire")
    
    -- Apply squash to caster
    if caster.applySquash then
        caster:applySquash(1.25, 0.8, 0.15)
    end
    return true
end

-- Rectangle: Falling Block (tips forward like a falling pillar)
function Abilities.spawnBlock(caster, facingRight)
    if caster.will < Abilities.COSTS.rectangle then return false end
    caster.will = caster.will - Abilities.COSTS.rectangle

    local dir = facingRight and 1 or -1
    local blockWidth = 120   -- Triple original size
    local blockHeight = 240  -- Triple original size
    local block = {
        type = "block",
        owner = caster.id,
        x = caster.x + dir * 100,           -- Spawn in front of player
        groundY = caster.y + caster.shapeHeight / 2, -- Store ground level relative to player
        y = (caster.y + caster.shapeHeight / 2) - blockHeight / 2,  -- Spawn relative to player's feet
        vx = 150 * dir,                     -- Move forward as it tips
        vy = 0,
        damage = Abilities.DAMAGE.rectangle,
        width = blockWidth,
        height = blockHeight,
        age = 0,
        rotation = 0,                       -- Current rotation (radians)
        rotationSpeed = 3.0 * dir,          -- Tipping speed (radians/sec)
        dir = dir,                          -- Direction for rotation pivot
    }
    table.insert(activeBlocks, block)
    Sounds.play("block_spawn")
    
    -- Apply squash to caster
    if caster.applySquash then
        caster:applySquash(0.85, 1.2, 0.15)
    end
    return true
end

-- Circle: Rolling Boulder
function Abilities.spawnBoulder(caster, facingRight)
    if caster.will < Abilities.COSTS.circle then return false end
    caster.will = caster.will - Abilities.COSTS.circle
    
    local dir = facingRight and 1 or -1
    local boulder = {
        type = "boulder",
        owner = caster.id,
        x = caster.x + dir * 50,
        groundY = caster.y + caster.shapeHeight / 2, -- Store ground level relative to player
        y = (caster.y + caster.shapeHeight / 2) - 35,  -- Spawn relative to player's feet
        vx = 350 * dir,             -- Rolling speed
        vy = 0,
        damage = Abilities.DAMAGE.circle,
        radius = 35,                -- Larger than player
        onGround = true,            -- starts on ground
        bounceCount = 0,            -- track bounces for wall bounce
        age = 0,
        rotation = 0,               -- For visual rolling
    }
    table.insert(activeBoulders, boulder)
    Sounds.play("boulder_roll")
    
    -- Apply squash to caster
    if caster.applySquash then
        caster:applySquash(1.15, 0.9, 0.12)
    end
    return true
end

-- ─────────────────────────────────────────────
-- Cast ability based on shape
-- ─────────────────────────────────────────────
function Abilities.cast(caster, shapeKey, facingRight, tx, ty)
    if shapeKey == "square" then
        return Abilities.spawnLaser(caster, facingRight, tx, ty)
    elseif shapeKey == "triangle" then
        return Abilities.spawnSpikes(caster, facingRight)
    elseif shapeKey == "rectangle" then
        return Abilities.spawnBlock(caster, facingRight)
    elseif shapeKey == "circle" then
        return Abilities.spawnBoulder(caster, facingRight)
    end
    return false
end

-- ─────────────────────────────────────────────
-- Helper: Apply damage to a player
-- ─────────────────────────────────────────────
local function applyDamage(player, damage, hitDir, isAuthority)
    if not isAuthority then return 0 end
    if player.invulnerable then return 0 end

    local prevLife = player.life
    local dmg = damage

    -- Armor absorbs damage
    if player.armor and player.armor > 0 then
        local absorbed = math.min(player.armor, dmg)
        dmg = dmg - absorbed
        player.armor = player.armor - absorbed
        if player.armor <= 0 then player.armor = 0 end
    end

    player.life = math.max(0, player.life - dmg)
    local actualDmg = prevLife - player.life

    if actualDmg > 0 then
        player.hitFlash = 0.25
        if player.applySquash then
            player:applySquash(0.7, 1.25, 0.15)
        end
        if player.applyKnockback and player.life > 0 then
            player:applyKnockback(hitDir, ABILITY_KNOCKBACK)
        end

        -- Trigger callbacks
        if Abilities.onHit then
            Abilities.onHit(player.x, player.y, actualDmg)
        end
        if Abilities.onKill and prevLife > 0 and player.life <= 0 then
            Abilities.onKill(player.x, player.y)
        end
    end

    return actualDmg
end

-- ─────────────────────────────────────────────
-- Update functions
-- ─────────────────────────────────────────────
function Abilities.update(dt, players)
    local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT

    -- Update lasers
    for i = #activeLasers, 1, -1 do
        local laser = activeLasers[i]
        laser.age = laser.age + dt
        laser.x = nil  -- Will be updated from caster position

        -- Find caster to update laser position
        for _, p in ipairs(players) do
            if p.id == laser.owner then
                laser.x = p.x
                laser.y = p.y
                -- Continuous aiming: update angle from player's current aim
                if p.aimX and p.aimY and (p.life or 0) > 0 then
                    -- Only update if aim vector is significant (avoid jitter at 0,0)
                    if p.aimX ~= 0 or p.aimY ~= 0 then
                        laser.angle = math.atan2(p.aimY - p.y, p.aimX - p.x)
                        -- DEBUG: Print updated angle
                        if math.random() < 0.01 then
                            print("Abilities: Laser owner " .. p.id .. " aim " .. math.floor(p.aimX) .. "," .. math.floor(p.aimY) .. " -> angle " .. laser.angle)
                        end
                    end
                end
                break
            end
        end

        if laser.age >= laser.duration or not laser.x then
            table.remove(activeLasers, i)
        else
            -- Update per-player hit cooldowns
            for pid, cooldown in pairs(laser.hitCooldown) do
                laser.hitCooldown[pid] = cooldown - dt
                if laser.hitCooldown[pid] <= 0 then
                    laser.hitCooldown[pid] = nil
                end
            end

            -- Check collision with players (damage with cooldown)
            for _, player in ipairs(players) do
                if player.id ~= laser.owner and (player.life or 0) > 0 then
                    -- Check if player is near laser line segment
                    local px, py = player.x, player.y
                    local lx1, ly1 = laser.x, laser.y
                    local lx2 = lx1 + math.cos(laser.angle) * laser.width
                    local ly2 = ly1 + math.sin(laser.angle) * laser.width

                    -- Point to line segment distance
                    local l2 = (lx2 - lx1)^2 + (ly2 - ly1)^2
                    if l2 == 0 then l2 = 0.0001 end
                    local t = ((px - lx1) * (lx2 - lx1) + (py - ly1) * (ly2 - ly1)) / l2
                    t = math.max(0, math.min(1, t))
                    local projX = lx1 + t * (lx2 - lx1)
                    local projY = ly1 + t * (ly2 - ly1)
                    local distSq = (px - projX)^2 + (py - projY)^2
                    
                    -- Player radius estimate (use max dimension for generous hit detection)
                    local pRadius = math.max(player.shapeWidth, player.shapeHeight) / 2
                    local laserRadius = laser.height / 2

                    if distSq < (pRadius + laserRadius)^2 then
                        -- Apply 1 damage per tick, with 1/30th second cooldown (~30 ticks per second = 30 damage/sec)
                        if not laser.hitCooldown[player.id] then
                            -- Hit direction based on laser angle
                            local hitDir = math.cos(laser.angle) > 0 and 1 or -1
                            applyDamage(player, laser.damagePerHit, hitDir, isAuthority)
                            laser.hitCooldown[player.id] = 0.033  -- ~30 damage per second

                            -- Spawn flying sparks at hit point
                            for _ = 1, math.random(3, 5) do
                                table.insert(activeSparks, {
                                    x = projX,
                                    y = projY,
                                    vx = (math.random() - 0.5) * 300 + hitDir * 100,
                                    vy = -math.random() * 200 - 50,
                                    age = 0,
                                    maxAge = 0.3 + math.random() * 0.3,
                                    r = 1.0,
                                    g = 0.5 + math.random() * 0.4,
                                    b = 0.1 + math.random() * 0.2,
                                    size = 2 + math.random() * 3,
                                })
                            end
                        end
                    end
                end
            end
        end
    end

    -- Update spikes (with gravity and platform collision)
    for i = #activeSpikes, 1, -1 do
        local spike = activeSpikes[i]
        spike.age = spike.age + dt

        -- Apply physics: gravity, ground bounce, platform collision, wall bounce
        applyAbilityPhysics(spike, dt, spike.radius, true)

        local hit = false

        -- Check player collision
        if not hit then
            for _, player in ipairs(players) do
                if player.id ~= spike.owner and (player.life or 0) > 0 then
                    local dx = spike.x - player.x
                    local dy = spike.y - player.y
                    local dist = math.sqrt(dx * dx + dy * dy)
                    local playerRadius = math.max(player.shapeWidth, player.shapeHeight) / 2
                    if dist < spike.radius + playerRadius then
                        local hitDir = spike.vx > 0 and 1 or -1
                        applyDamage(player, spike.damage, hitDir, isAuthority)
                        Sounds.play("spike_hit")
                        hit = true
                        break
                    end
                end
            end
        end

        if hit or spike.age > 3 then
            table.remove(activeSpikes, i)
        end
    end

    -- Update falling/tipping blocks
    for i = #activeBlocks, 1, -1 do
        local block = activeBlocks[i]
        block.age = block.age + dt

        -- Update rotation (tipping forward)
        if block.rotation then
            block.rotation = block.rotation + block.rotationSpeed * dt
            -- Move forward as it tips
            block.x = block.x + block.vx * dt
        else
            -- Legacy: falling from above (in case old blocks exist)
            block.vy = block.vy + Physics.GRAVITY * dt
            block.y = block.y + block.vy * dt
        end

        local hit = false

        -- Check if block has tipped over (rotation past ~80 degrees = 1.4 radians)
        if block.rotation and math.abs(block.rotation) >= 1.4 then
            Sounds.play("block_land")
            -- Spawn debris chunks that bounce around
            local pivotY = block.groundY or Physics.GROUND_Y
            local pivotX = block.x - block.dir * block.width / 2
            local tipX = pivotX + math.sin(block.rotation) * block.height
            local tipY = pivotY + (-math.cos(block.rotation) * block.height)
            for d = 1, 3 do
                table.insert(activeDebris, {
                    x = pivotX + (tipX - pivotX) * (d / 3),
                    y = tipY + (pivotY - tipY) * (d / 3) - 10,
                    vx = (math.random() - 0.5) * 300 + block.vx * 0.3,
                    vy = -math.random() * 200 - 100,
                    size = math.random(8, 16),
                    age = 0,
                    rotation = math.random() * math.pi * 2,
                    rotSpeed = (math.random() - 0.5) * 10,
                })
            end
            hit = true
        end

        -- Check ground collision for legacy falling blocks
        local groundY = block.groundY or Physics.GROUND_Y
        if not block.rotation and block.y + block.height / 2 >= groundY then
            Sounds.play("block_land")
            hit = true
        end

        -- Check player collision using rotated bounding box (simplified: use center + radius)
        if not hit then
            for _, player in ipairs(players) do
                if player.id ~= block.owner and (player.life or 0) > 0 then
                    -- Calculate block's effective hit area (sweep area during tip)
                    local blockCenterX, blockCenterY
                    if block.rotation then
                        -- Block pivots from base, calculate swept position
                        local pivotY2 = block.groundY or Physics.GROUND_Y
                        local pivotX2 = block.x - block.dir * block.width / 2
                        -- Tip of block position based on rotation
                        local tipOffsetX = math.sin(block.rotation) * block.height
                        local tipOffsetY = -math.cos(block.rotation) * block.height
                        blockCenterX = pivotX2 + tipOffsetX / 2
                        blockCenterY = pivotY2 + tipOffsetY / 2
                    else
                        blockCenterX = block.x
                        blockCenterY = block.y
                    end

                    -- Use a generous hit radius based on block dimensions
                    local hitRadius = block.height / 2
                    local dx = player.x - blockCenterX
                    local dy = player.y - blockCenterY
                    local dist = math.sqrt(dx * dx + dy * dy)
                    local playerRadius = math.max(player.shapeWidth, player.shapeHeight) / 2

                    if dist < hitRadius + playerRadius then
                        applyDamage(player, block.damage, block.dir or 0, isAuthority)
                        Sounds.play("block_hit")
                        hit = true
                        break
                    end
                end
            end
        end

        if hit or block.age > 3 then
            table.remove(activeBlocks, i)
        end
    end

    -- Update debris (bouncing block chunks)
    for i = #activeDebris, 1, -1 do
        local d = activeDebris[i]
        d.age = d.age + dt
        d.rotation = d.rotation + d.rotSpeed * dt
        applyAbilityPhysics(d, dt, d.size / 2, true)
        if d.age > 2.5 then
            table.remove(activeDebris, i)
        end
    end

    -- Update rolling boulders (with gravity, platform/ground/wall bounce)
    for i = #activeBoulders, 1, -1 do
        local boulder = activeBoulders[i]
        boulder.age = boulder.age + dt

        -- Apply physics: gravity, ground/platform bounce, wall bounce
        applyAbilityPhysics(boulder, dt, boulder.radius, true)
        boulder.rotation = boulder.rotation + (boulder.vx / boulder.radius) * dt

        local hit = false

        -- Check player collision
        if not hit then
            for _, player in ipairs(players) do
                if player.id ~= boulder.owner and (player.life or 0) > 0 then
                    local dx = boulder.x - player.x
                    local dy = boulder.y - player.y
                    local dist = math.sqrt(dx * dx + dy * dy)
                    local playerRadius = math.max(player.shapeWidth, player.shapeHeight) / 2
                    if dist < boulder.radius + playerRadius then
                        local hitDir = boulder.vx > 0 and 1 or -1
                        applyDamage(player, boulder.damage, hitDir, isAuthority)
                        Sounds.play("boulder_hit")
                        hit = true
                        break
                    end
                end
            end
        end

        -- Remove if speed is too low (stopped bouncing) or too old
        local speed = math.abs(boulder.vx) + math.abs(boulder.vy)
        if hit or boulder.age > 5 or (boulder.age > 2 and speed < 20) then
            table.remove(activeBoulders, i)
        end
    end

    -- Update laser sparks
    for i = #activeSparks, 1, -1 do
        local spark = activeSparks[i]
        spark.age = spark.age + dt
        spark.x = spark.x + spark.vx * dt
        spark.y = spark.y + spark.vy * dt
        spark.vy = spark.vy + 400 * dt  -- gravity on sparks
        if spark.age >= spark.maxAge then
            table.remove(activeSparks, i)
        end
    end
end

-- ─────────────────────────────────────────────
-- Draw functions
-- ─────────────────────────────────────────────
function Abilities.draw()
    -- Draw lasers
    for _, laser in ipairs(activeLasers) do
        if laser.x then
            local alpha = 1 - (laser.age / laser.duration) * 0.5
            local pulseWidth = laser.height + math.sin(laser.age * 30) * 3

            -- Outer glow
            love.graphics.setColor(1, 0.3, 0.3, alpha * 0.3)
            love.graphics.setLineWidth(pulseWidth + 8)
            local endX = laser.x + math.cos(laser.angle) * laser.width
            local endY = laser.y + math.sin(laser.angle) * laser.width
            love.graphics.line(laser.x, laser.y, endX, endY)

            -- Core beam
            love.graphics.setColor(1, 0.5, 0.5, alpha * 0.8)
            love.graphics.setLineWidth(pulseWidth)
            love.graphics.line(laser.x, laser.y, endX, endY)

            -- Bright center
            love.graphics.setColor(1, 0.9, 0.9, alpha)
            love.graphics.setLineWidth(pulseWidth * 0.4)
            love.graphics.line(laser.x, laser.y, endX, endY)
        end
    end

    -- Draw spikes
    for _, spike in ipairs(activeSpikes) do
        local dir = spike.vx > 0 and 1 or -1
        love.graphics.setColor(0.9, 0.7, 0.2, 1)
        -- Draw as triangle pointing in direction of travel
        local tipX = spike.x + dir * 15
        local baseX = spike.x - dir * 10
        love.graphics.polygon("fill",
            tipX, spike.y,
            baseX, spike.y - 8,
            baseX, spike.y + 8)
        -- Outline
        love.graphics.setColor(1, 0.85, 0.4, 1)
        love.graphics.setLineWidth(2)
        love.graphics.polygon("line",
            tipX, spike.y,
            baseX, spike.y - 8,
            baseX, spike.y + 8)
    end

    -- Draw falling/tipping blocks
    for _, block in ipairs(activeBlocks) do
        love.graphics.push()

        if block.rotation then
            -- Tipping block: pivot from bottom edge
            local pivotX = block.x - block.dir * block.width / 2
            local pivotY = block.groundY or Physics.GROUND_Y
            love.graphics.translate(pivotX, pivotY)
            love.graphics.rotate(block.rotation)

            -- Shadow (on ground, stretched based on rotation)
            love.graphics.setColor(0, 0, 0, 0.3)
            local shadowStretch = math.abs(math.sin(block.rotation)) * block.height * 0.3
            love.graphics.ellipse("fill", block.dir * block.width / 2, 0,
                block.width / 2 + shadowStretch, 10)

            -- Block (draw relative to pivot, block extends upward from pivot)
            love.graphics.setColor(0.6, 0.4, 0.2, 1)
            love.graphics.rectangle("fill",
                0, -block.height,
                block.width * block.dir, block.height)
            -- Outline
            love.graphics.setColor(0.8, 0.6, 0.3, 1)
            love.graphics.setLineWidth(3)
            love.graphics.rectangle("line",
                0, -block.height,
                block.width * block.dir, block.height)
        else
            -- Legacy falling block: no rotation
            love.graphics.translate(block.x, block.y)
            -- Shadow
            love.graphics.setColor(0, 0, 0, 0.3)
            love.graphics.rectangle("fill",
                -block.width / 2 + 3, -block.height / 2 + 3,
                block.width, block.height)
            -- Block
            love.graphics.setColor(0.6, 0.4, 0.2, 1)
            love.graphics.rectangle("fill",
                -block.width / 2, -block.height / 2,
                block.width, block.height)
            -- Outline
            love.graphics.setColor(0.8, 0.6, 0.3, 1)
            love.graphics.setLineWidth(3)
            love.graphics.rectangle("line",
                -block.width / 2, -block.height / 2,
                block.width, block.height)
        end

        love.graphics.pop()
    end

    -- Draw rolling boulders
    for _, boulder in ipairs(activeBoulders) do
        -- Shadow
        love.graphics.setColor(0, 0, 0, 0.3)
        local groundY = boulder.groundY or Physics.GROUND_Y
        love.graphics.ellipse("fill", boulder.x + 4, groundY + 3, boulder.radius * 0.8, 8)

        -- Boulder body
        love.graphics.setColor(0.5, 0.5, 0.55, 1)
        love.graphics.circle("fill", boulder.x, boulder.y, boulder.radius)

        -- Rolling texture lines
        love.graphics.setColor(0.4, 0.4, 0.45, 1)
        love.graphics.setLineWidth(3)
        for j = 0, 2 do
            local angle = boulder.rotation + j * (math.pi * 2 / 3)
            local innerR = boulder.radius * 0.3
            local outerR = boulder.radius * 0.8
            love.graphics.line(
                boulder.x + math.cos(angle) * innerR,
                boulder.y + math.sin(angle) * innerR,
                boulder.x + math.cos(angle) * outerR,
                boulder.y + math.sin(angle) * outerR)
        end

        -- Outline
        love.graphics.setColor(0.6, 0.6, 0.65, 1)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", boulder.x, boulder.y, boulder.radius)
    end

    -- Draw block debris (bouncing chunks)
    for _, d in ipairs(activeDebris) do
        local alpha = math.max(0, 1 - d.age / 2.5)
        love.graphics.push()
        love.graphics.translate(d.x, d.y)
        love.graphics.rotate(d.rotation)
        -- Shadow
        love.graphics.setColor(0, 0, 0, alpha * 0.2)
        love.graphics.rectangle("fill", -d.size/2 + 2, -d.size/2 + 2, d.size, d.size)
        -- Chunk
        love.graphics.setColor(0.6, 0.4, 0.2, alpha)
        love.graphics.rectangle("fill", -d.size/2, -d.size/2, d.size, d.size)
        -- Outline
        love.graphics.setColor(0.8, 0.6, 0.3, alpha * 0.8)
        love.graphics.setLineWidth(1)
        love.graphics.rectangle("line", -d.size/2, -d.size/2, d.size, d.size)
        love.graphics.pop()
    end

    -- Draw laser sparks (flying glowing particles)
    for _, spark in ipairs(activeSparks) do
        local progress = spark.age / spark.maxAge
        local alpha = 1 - progress * progress  -- fade out
        local size = spark.size * (1 - progress * 0.5)  -- shrink slightly

        -- Glow
        love.graphics.setColor(spark.r, spark.g, spark.b, alpha * 0.4)
        love.graphics.circle("fill", spark.x, spark.y, size * 2)

        -- Core
        love.graphics.setColor(spark.r, spark.g, spark.b, alpha)
        love.graphics.circle("fill", spark.x, spark.y, size)

        -- Bright center
        love.graphics.setColor(1, 1, 0.9, alpha * 0.8)
        love.graphics.circle("fill", spark.x, spark.y, size * 0.4)
    end
end

-- Clear all active abilities
function Abilities.clear()
    activeLasers = {}
    activeSpikes = {}
    activeBlocks = {}
    activeBoulders = {}
    activeSparks = {}
    activeDebris = {}
end

-- Check if any abilities are active (for network sync)
function Abilities.hasActive()
    return #activeLasers > 0 or #activeSpikes > 0 or #activeBlocks > 0 or #activeBoulders > 0 or #activeSparks > 0 or #activeDebris > 0
end

return Abilities
