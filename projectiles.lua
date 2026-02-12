-- projectiles.lua
-- Projectile system: fireballs (horizontal)
-- with particle trails, collision detection, and hit effects

local Physics = require("physics")
local Sounds  = require("sounds")
local Dropbox = require("dropbox")
local Network = require("network")

-- Knockback constant (matches Player.PROJECTILE_KNOCKBACK, duplicated to avoid circular require)
local PROJECTILE_KNOCKBACK = 180

local Projectiles = {}

Projectiles.DAMAGE         = 15
Projectiles.WILL_COST      = 10
Projectiles.FIREBALL_SPEED = 600     -- px/s horizontal
Projectiles.FIREBALL_RADIUS = 12

-- Callbacks for juice effects (set by main.lua)
Projectiles.onHit = nil         -- function(x, y, damage) called when fireball hits
Projectiles.onKill = nil        -- function(x, y) called when a hit results in death

-- Active projectile list and hit-effect list
local active = {}
local effects = {}

-- ─────────────────────────────────────────────
-- Spawning
-- ─────────────────────────────────────────────

-- Helper: consume damage boost from caster and return total damage for this shot
local function _consumeBoost(caster)
    local dmg = Projectiles.DAMAGE
    if caster.damageBoostShots and caster.damageBoostShots > 0 then
        dmg = dmg + (caster.damageBoost or 0)
        caster.damageBoostShots = caster.damageBoostShots - 1
        if caster.damageBoostShots <= 0 then
            caster.damageBoost = 0
            caster.damageBoostShots = 0
        end
    end
    return dmg
end

-- Spawn a fireball from the caster toward the target horizontally
function Projectiles.spawnFireball(caster, target)
    if caster.will < Projectiles.WILL_COST then return false end
    caster.will = caster.will - Projectiles.WILL_COST
    local dir = (target.x > caster.x) and 1 or -1
    local dmg = _consumeBoost(caster)
    local proj = {
        type     = "fireball",
        owner    = caster.id,
        targetId = target.id,
        damage   = dmg,
        x        = caster.x + dir * (caster.shapeWidth / 2 + 10),
        y        = caster.y,
        vx       = Projectiles.FIREBALL_SPEED * dir,
        vy       = 0,
        radius   = Projectiles.FIREBALL_RADIUS,
        age      = 0,
        particles = {}
    }
    table.insert(active, proj)
    Sounds.play("fireball_cast")
    -- Apply squash/stretch to caster when shooting (stretch forward, squash vertically)
    if caster.applySquash then
        caster:applySquash(1.2, 0.85, 0.12)
    end
    return true
end

-- Spawn a fireball in a specific direction (for aim assist OFF)
function Projectiles.spawnFireballDirectional(caster, facingRight)
    if caster.will < Projectiles.WILL_COST then return false end
    caster.will = caster.will - Projectiles.WILL_COST
    local dir = facingRight and 1 or -1
    local dmg = _consumeBoost(caster)
    local proj = {
        type     = "fireball",
        owner    = caster.id,
        targetId = nil,  -- no specific target
        damage   = dmg,
        x        = caster.x + dir * (caster.shapeWidth / 2 + 10),
        y        = caster.y,
        vx       = Projectiles.FIREBALL_SPEED * dir,
        vy       = 0,
        radius   = Projectiles.FIREBALL_RADIUS,
        age      = 0,
        particles = {}
    }
    table.insert(active, proj)
    Sounds.play("fireball_cast")
    -- Apply squash/stretch to caster when shooting (stretch forward, squash vertically)
    if caster.applySquash then
        caster:applySquash(1.2, 0.85, 0.12)
    end
    return true
end

-- ─────────────────────────────────────────────
-- Update
-- ─────────────────────────────────────────────
function Projectiles.update(dt, players)
    -- Update active projectiles
    for i = #active, 1, -1 do
        local p = active[i]
        p.x   = p.x + p.vx * dt
        p.y   = p.y + p.vy * dt
        p.age = p.age + dt

        -- Spawn trail particles
        Projectiles._spawnTrail(p)

        -- Check collision with dropboxes first
        local hit = false
        if Dropbox.hitBox(p.x, p.y, Projectiles.FIREBALL_RADIUS) then
            Projectiles._spawnHitEffect(p.x, p.y, p.type)
            Sounds.play("fireball_hit")
            hit = true
        end

        -- Only host (or solo/demo) applies damage; clients just show effects
        local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT

	    -- Check collision with target player
	    if not hit then
	        for _, player in ipairs(players) do
	            -- Ignore dead players so projectiles don't fizzle on corpses / disconnected slots
	            if player.id ~= p.owner and (player.life or 0) > 0 then
	                if Projectiles._hitTest(p, player) then
	                    local prevLife = player.life
	                    local actualDmg = 0
	                    -- Only apply damage if we're the authority (host/solo/demo)
	                    if isAuthority and not player.invulnerable then
	                        local dmg = p.damage or Projectiles.DAMAGE
	                        actualDmg = dmg
	                        -- Armor absorbs damage first, then vanishes
	                        if player.armor and player.armor > 0 then
	                            local absorbed = math.min(player.armor, dmg)
	                            dmg = dmg - absorbed
	                            player.armor = player.armor - absorbed
	                            if player.armor <= 0 then player.armor = 0 end
	                        end
	                        player.life = math.max(0, player.life - dmg)
	                        actualDmg = prevLife - player.life
	                    end
	                    player.hitFlash = 0.25   -- flash duration (visual only)
	                    Projectiles._spawnHitEffect(p.x, p.y, p.type)
	                    Sounds.play("fireball_hit")

	                    -- Apply squash/stretch on hit (compress in hit direction)
	                    local hitDir = (p.vx > 0) and 1 or -1
	                    player:applySquash(0.7, 1.25, 0.15)  -- squash horizontally, stretch vertically

	                    -- Apply knockback (only if authority)
	                    if isAuthority and player.life > 0 then
	                        player:applyKnockback(hitDir, PROJECTILE_KNOCKBACK)
	                    end

	                    -- Trigger juice callbacks
	                    if Projectiles.onHit and actualDmg > 0 then
	                        Projectiles.onHit(player.x, player.y, actualDmg)
	                    end
	                    if Projectiles.onKill and prevLife > 0 and player.life <= 0 then
	                        Projectiles.onKill(player.x, player.y)
	                    end

	                    hit = true
	                    break
	                end
	            end
	        end
	    end

        -- Remove if hit, or off-screen
        if hit or Projectiles._isOffScreen(p) then
            table.remove(active, i)
        end
    end

    -- Update trail particles
    for i = #active, 1, -1 do
        Projectiles._updateParticles(active[i].particles, dt)
    end

    -- Update hit effects
    for i = #effects, 1, -1 do
        local e = effects[i]
        e.age = e.age + dt
        local isDeath = (e.projType == "death")
        for j = #e.particles, 1, -1 do
            local pt = e.particles[j]
            pt.x = pt.x + pt.vx * dt
            pt.y = pt.y + pt.vy * dt
            pt.vy = pt.vy + 300 * dt   -- gravity on sparks
            -- Slow down death particles for more dramatic effect
            if isDeath then
                pt.vx = pt.vx * (1 - 1.5 * dt)
            end
            pt.life = pt.life - dt
            if pt.life <= 0 then
                table.remove(e.particles, j)
            end
        end
        -- Death explosions last longer
        local maxAge = isDeath and 1.2 or 0.6
        if e.age > maxAge then
            table.remove(effects, i)
        end
    end
end

-- ─────────────────────────────────────────────
-- Draw
-- ─────────────────────────────────────────────
function Projectiles.draw()
    -- Draw trail particles (behind projectiles)
    for _, p in ipairs(active) do
        for _, pt in ipairs(p.particles) do
            local alpha = (pt.life / pt.maxLife) * 0.7
            love.graphics.setColor(1.0, 0.7, 0.2, alpha)
            love.graphics.circle("fill", pt.x, pt.y, pt.r)
        end
    end

    -- Draw projectiles
    for _, p in ipairs(active) do
        Projectiles._drawFireball(p)
    end

    -- Draw hit effects
    for _, e in ipairs(effects) do
        local isDash = (e.projType == "dash")
        local isDust = (e.projType == "dust")
        local isDeath = (e.projType == "death")

        -- Expanding ring (skip for dust and death)
        if not isDust and not isDeath then
            local ringAlpha = math.max(0, 1 - e.age / 0.4)
            local ringR = 10 + e.age * (isDash and 150 or 120)
            if isDash then
                love.graphics.setColor(0.4, 0.8, 1.0, ringAlpha * 0.6)
            else
                love.graphics.setColor(1.0, 0.8, 0.2, ringAlpha * 0.5)
            end
            love.graphics.setLineWidth(3)
            love.graphics.circle("line", e.x, e.y, ringR)
        end

        -- Death explosion: large expanding shockwave ring
        if isDeath then
            local ringAlpha = math.max(0, 1 - e.age / 0.6)
            local ringR = 20 + e.age * 200
            love.graphics.setColor(1.0, 0.6, 0.2, ringAlpha * 0.7)
            love.graphics.setLineWidth(4)
            love.graphics.circle("line", e.x, e.y, ringR)
            -- Inner glow
            love.graphics.setColor(1.0, 0.9, 0.5, ringAlpha * 0.3)
            love.graphics.circle("fill", e.x, e.y, math.max(0, 30 - e.age * 60))
        end

        -- Spark/dust/death particles
        for _, pt in ipairs(e.particles) do
            local alpha = math.max(0, pt.life / pt.maxLife)
            if isDeath and pt.color then
                love.graphics.setColor(pt.color[1], pt.color[2], pt.color[3], alpha)
            elseif isDust then
                love.graphics.setColor(0.6, 0.55, 0.5, alpha * 0.6)  -- Brownish dust
            elseif isDash then
                love.graphics.setColor(0.5, 0.85, 1.0, alpha)
            else
                love.graphics.setColor(1.0, 0.9, 0.3, alpha)
            end
            love.graphics.circle("fill", pt.x, pt.y, pt.r * (pt.life / pt.maxLife))
        end
    end
end

-- ─────────────────────────────────────────────
-- Private helpers
-- ─────────────────────────────────────────────

function Projectiles._drawFireball(p)
    local dir = p.vx > 0 and 1 or -1
    -- Outer glow
    love.graphics.setColor(1.0, 0.6, 0.0, 0.25)
    love.graphics.circle("fill", p.x, p.y, p.radius * 2.0)
    -- Core
    love.graphics.setColor(1.0, 0.7, 0.2, 0.9)
    love.graphics.circle("fill", p.x, p.y, p.radius)
    -- Hot center
    love.graphics.setColor(1.0, 1.0, 0.7, 0.8)
    love.graphics.circle("fill", p.x + dir * 2, p.y, p.radius * 0.45)
    -- Trailing flame
    love.graphics.setColor(1.0, 0.5, 0.1, 0.5)
    love.graphics.polygon("fill",
        p.x - dir * p.radius, p.y - 5,
        p.x - dir * (p.radius + 20 + math.sin(p.age * 14) * 5), p.y,
        p.x - dir * p.radius, p.y + 5)
end

function Projectiles._hitTest(proj, player)
    -- Circle vs AABB
    local cx, cy, r = proj.x, proj.y, proj.radius
    local px = player.x - player.shapeWidth / 2
    local py = player.y - player.shapeHeight / 2
    local pw = player.shapeWidth
    local ph = player.shapeHeight

    local closestX = math.max(px, math.min(cx, px + pw))
    local closestY = math.max(py, math.min(cy, py + ph))
    local dx = cx - closestX
    local dy = cy - closestY
    return (dx * dx + dy * dy) <= (r * r)
end

function Projectiles._isOffScreen(p)
    return p.x < -60 or p.x > 1340 or p.y > Physics.GROUND_Y + 60 or p.y < -200
end

function Projectiles._spawnTrail(p)
    -- Spawn 1-2 trail particles per frame
    for _ = 1, 2 do
        local pt = {
            x = p.x + (math.random() - 0.5) * p.radius,
            y = p.y + (math.random() - 0.5) * p.radius,
            vx = (math.random() - 0.5) * 30,
            vy = (math.random() - 0.5) * 30,
            r = math.random() * 4 + 2,
            life = 0.3 + math.random() * 0.2,
            maxLife = 0.5
        }
        -- trail drifts opposite to travel direction
        pt.vx = pt.vx - p.vx * 0.05
        pt.maxLife = pt.life
        table.insert(p.particles, pt)
    end
end

function Projectiles._updateParticles(particles, dt)
    for i = #particles, 1, -1 do
        local pt = particles[i]
        pt.x = pt.x + pt.vx * dt
        pt.y = pt.y + pt.vy * dt
        pt.life = pt.life - dt
        if pt.life <= 0 then
            table.remove(particles, i)
        end
    end
end

function Projectiles._spawnHitEffect(x, y, projType)
    local e = {
        x = x,
        y = y,
        projType = projType,
        age = 0,
        particles = {}
    }
    -- Burst of sparks
    for _ = 1, 16 do
        local angle = math.random() * math.pi * 2
        local speed = 100 + math.random() * 200
        table.insert(e.particles, {
            x = x,
            y = y,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed - 80,
            r = math.random() * 3 + 1.5,
            life = 0.3 + math.random() * 0.3,
            maxLife = 0.6
        })
    end
    table.insert(effects, e)
end

-- Spawn a dash impact particle burst (cyan/blue colored)
function Projectiles.spawnDashImpact(x, y)
    local e = {
        x = x,
        y = y,
        projType = "dash",
        age = 0,
        particles = {}
    }
    for _ = 1, 14 do
        local angle = math.random() * math.pi * 2
        local speed = 120 + math.random() * 250
        table.insert(e.particles, {
            x = x,
            y = y,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed - 60,
            r = math.random() * 3 + 1,
            life = 0.25 + math.random() * 0.3,
            maxLife = 0.55
        })
    end
    table.insert(effects, e)
end

-- Spawn landing dust particles (small puff when player lands)
function Projectiles.spawnLandingDust(x, y)
    local e = {
        x = x,
        y = y,
        projType = "dust",
        age = 0,
        particles = {}
    }
    -- Small horizontal burst of dust
    for _ = 1, 8 do
        local angle = math.random() * math.pi  -- Only upward half-circle
        local speed = 30 + math.random() * 50
        table.insert(e.particles, {
            x = x + (math.random() - 0.5) * 20,
            y = y,
            vx = math.cos(angle) * speed * (math.random() > 0.5 and 1 or -1),
            vy = -math.sin(angle) * speed * 0.5 - 10,
            r = math.random() * 3 + 2,
            life = 0.2 + math.random() * 0.15,
            maxLife = 0.35
        })
    end
    table.insert(effects, e)
end

-- Spawn death explosion (player blows up into fragments)
function Projectiles.spawnDeathExplosion(x, y, shapeKey)
    local e = {
        x = x,
        y = y,
        projType = "death",
        age = 0,
        particles = {}
    }
    -- Get player color based on shape
    local colors = {
        triangle = {1.0, 0.4, 0.4},   -- Red
        square = {0.4, 0.6, 1.0},     -- Blue
        circle = {0.4, 1.0, 0.5}      -- Green
    }
    local color = colors[shapeKey] or {1, 1, 1}

    -- Large burst of fragments
    for _ = 1, 24 do
        local angle = math.random() * math.pi * 2
        local speed = 150 + math.random() * 300
        table.insert(e.particles, {
            x = x + (math.random() - 0.5) * 20,
            y = y + (math.random() - 0.5) * 20,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed - 100,
            r = math.random() * 6 + 4,
            life = 0.6 + math.random() * 0.4,
            maxLife = 1.0,
            color = color
        })
    end
    -- Inner bright core particles
    for _ = 1, 12 do
        local angle = math.random() * math.pi * 2
        local speed = 50 + math.random() * 100
        table.insert(e.particles, {
            x = x,
            y = y,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed - 50,
            r = math.random() * 4 + 2,
            life = 0.3 + math.random() * 0.2,
            maxLife = 0.5,
            color = {1, 1, 0.8}  -- Bright yellow-white core
        })
    end
    table.insert(effects, e)
end

-- Clear all projectiles and effects (for round reset)
function Projectiles.clear()
    active = {}
    effects = {}
end

return Projectiles

