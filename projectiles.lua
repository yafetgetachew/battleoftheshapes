-- projectiles.lua
-- Projectile system: fireballs (horizontal)
-- with particle trails, collision detection, and hit effects

local Physics = require("physics")

local Projectiles = {}

Projectiles.DAMAGE         = 30
Projectiles.WILL_COST      = 10
Projectiles.FIREBALL_SPEED = 600     -- px/s horizontal
Projectiles.FIREBALL_RADIUS = 12

-- Active projectile list and hit-effect list
local active = {}
local effects = {}

-- ─────────────────────────────────────────────
-- Spawning
-- ─────────────────────────────────────────────

-- Spawn a fireball from the caster toward the target horizontally
function Projectiles.spawnFireball(caster, target)
    if caster.will < Projectiles.WILL_COST then return false end
    caster.will = caster.will - Projectiles.WILL_COST
    local dir = (target.x > caster.x) and 1 or -1
    local proj = {
        type     = "fireball",
        owner    = caster.id,
        targetId = target.id,
        x        = caster.x + dir * (caster.shapeWidth / 2 + 10),
        y        = caster.y,
        vx       = Projectiles.FIREBALL_SPEED * dir,
        vy       = 0,
        radius   = Projectiles.FIREBALL_RADIUS,
        age      = 0,
        particles = {}
    }
    table.insert(active, proj)
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

        -- Check collision with target player
        local hit = false
        for _, player in ipairs(players) do
            if player.id ~= p.owner then
                if Projectiles._hitTest(p, player) then
                    player.life = math.max(0, player.life - Projectiles.DAMAGE)
                    player.hitFlash = 0.25   -- flash duration
                    Projectiles._spawnHitEffect(p.x, p.y, p.type)
                    hit = true
                    break
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
        for j = #e.particles, 1, -1 do
            local pt = e.particles[j]
            pt.x = pt.x + pt.vx * dt
            pt.y = pt.y + pt.vy * dt
            pt.vy = pt.vy + 300 * dt   -- gravity on sparks
            pt.life = pt.life - dt
            if pt.life <= 0 then
                table.remove(e.particles, j)
            end
        end
        if e.age > 0.6 then
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
        -- Expanding ring
        local ringAlpha = math.max(0, 1 - e.age / 0.4)
        local ringR = 10 + e.age * 120
        love.graphics.setColor(1.0, 0.8, 0.2, ringAlpha * 0.5)
        love.graphics.setLineWidth(3)
        love.graphics.circle("line", e.x, e.y, ringR)

        -- Spark particles
        for _, pt in ipairs(e.particles) do
            local alpha = math.max(0, pt.life / pt.maxLife)
            love.graphics.setColor(1.0, 0.9, 0.3, alpha)
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

-- Clear all projectiles and effects (for round reset)
function Projectiles.clear()
    active = {}
    effects = {}
end

return Projectiles

