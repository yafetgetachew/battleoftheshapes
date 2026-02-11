-- dropbox.lua
-- Dropbox system: crates that spawn randomly, drop life charges when shot

local Physics = require("physics")
local Sounds  = require("sounds")
local Network = require("network")

local Dropbox = {}

-- Configuration
Dropbox.SPAWN_INTERVAL = 15      -- seconds between spawns
Dropbox.BOX_SIZE = 40            -- width/height of the box
Dropbox.LIFE_HEAL = 30           -- health restored by life charge
Dropbox.CHARGE_SIZE = 24         -- size of the life charge pickup
Dropbox.CHARGE_LIFETIME = 10     -- seconds before charge despawns
Dropbox.CHARGE_BOB_SPEED = 3     -- bobbing animation speed

-- Physics constants for boxes
Dropbox.BOX_GRAVITY = 800        -- gravity for falling boxes (slightly less than player)
Dropbox.BOX_BOUNCE = 0.4         -- bounce factor when hitting ground
Dropbox.BOX_FRICTION = 0.92      -- horizontal friction
Dropbox.BOX_PUSH_FORCE = 300     -- force when player collides with box

-- State
local boxes = {}          -- active falling/landed boxes
local charges = {}        -- dropped life charges
local spawnTimer = 10     -- time until next box spawn (start at 10s for first spawn)

function Dropbox.reset()
    boxes = {}
    charges = {}
    spawnTimer = 10
end

function Dropbox.update(dt, players)
    -- Spawn timer
    spawnTimer = spawnTimer - dt
    if spawnTimer <= 0 then
        Dropbox._spawnBox()
        spawnTimer = Dropbox.SPAWN_INTERVAL
    end

    -- Update boxes with physics
    for i = #boxes, 1, -1 do
        local box = boxes[i]
        local halfSize = Dropbox.BOX_SIZE / 2

        -- Apply gravity
        box.vy = box.vy + Dropbox.BOX_GRAVITY * dt

        -- Apply velocity
        box.x = box.x + box.vx * dt
        box.y = box.y + box.vy * dt

        -- Horizontal friction when on ground
        if box.onGround then
            box.vx = box.vx * Dropbox.BOX_FRICTION
            if math.abs(box.vx) < 5 then box.vx = 0 end
        end

        -- Ground collision with bounce
        if box.y + halfSize >= Physics.GROUND_Y then
            box.y = Physics.GROUND_Y - halfSize
            if box.vy > 0 then
                box.vy = -box.vy * Dropbox.BOX_BOUNCE
                if math.abs(box.vy) < 30 then
                    box.vy = 0
                    box.onGround = true
                end
            end
        else
            box.onGround = false
        end

        -- Wall collision
        if box.x - halfSize < Physics.WALL_LEFT then
            box.x = Physics.WALL_LEFT + halfSize
            box.vx = -box.vx * 0.5
        elseif box.x + halfSize > Physics.WALL_RIGHT then
            box.x = Physics.WALL_RIGHT - halfSize
            box.vx = -box.vx * 0.5
        end

        -- Player collision
        for _, player in ipairs(players) do
            if player.life > 0 then
                Dropbox._resolvePlayerBoxCollision(player, box, dt)
            end
        end
    end

    -- Update life charges
    -- Only host (or solo/demo) applies healing; clients receive authoritative life from host
    local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT
    for i = #charges, 1, -1 do
        local charge = charges[i]
        charge.age = charge.age + dt

        -- Check player pickup
        for _, player in ipairs(players) do
            if player.life > 0 and Dropbox._playerTouchesCharge(player, charge) then
                -- Heal player (only if authority)
                if isAuthority then
                    player.life = math.min(player.maxLife, player.life + Dropbox.LIFE_HEAL)
                end
                player.hitFlash = 0.15  -- brief flash for feedback (visual only)
                Sounds.play("fireball_cast")  -- reuse sound for pickup
                table.remove(charges, i)
                break
            end
        end

        -- Remove expired charges
        if charge.age >= Dropbox.CHARGE_LIFETIME then
            table.remove(charges, i)
        end
    end
end

function Dropbox._spawnBox()
    local margin = 100
    local x = margin + math.random() * (Physics.WALL_RIGHT - Physics.WALL_LEFT - margin * 2)
    local box = {
        x = x,
        y = -Dropbox.BOX_SIZE,  -- start above screen
        vx = 0,
        vy = 0,
        onGround = false
    }
    table.insert(boxes, box)
end

-- Resolve collision between a player and a box
function Dropbox._resolvePlayerBoxCollision(player, box, dt)
    local halfBox = Dropbox.BOX_SIZE / 2
    local halfPW = player.shapeWidth / 2
    local halfPH = player.shapeHeight / 2

    -- AABB overlap check
    local bx1, by1 = box.x - halfBox, box.y - halfBox
    local bx2, by2 = box.x + halfBox, box.y + halfBox
    local px1, py1 = player.x - halfPW, player.y - halfPH
    local px2, py2 = player.x + halfPW, player.y + halfPH

    if not (px1 < bx2 and px2 > bx1 and py1 < by2 and py2 > by1) then
        return  -- no overlap
    end

    -- Calculate overlap on each axis
    local dx = box.x - player.x
    local dy = box.y - player.y
    local overlapX = (halfBox + halfPW) - math.abs(dx)
    local overlapY = (halfBox + halfPH) - math.abs(dy)

    if overlapX <= 0 or overlapY <= 0 then return end

    -- Resolve along the axis of least penetration
    if overlapX < overlapY then
        -- Push apart on X
        local sign = dx >= 0 and 1 or -1
        box.x = box.x + (overlapX / 2 + 1) * sign
        -- Apply velocity push to box
        box.vx = box.vx + Dropbox.BOX_PUSH_FORCE * sign * dt
        -- Small push back on player
        player.vx = player.vx - Dropbox.BOX_PUSH_FORCE * 0.3 * sign * dt
    else
        -- Push apart on Y
        local sign = dy >= 0 and 1 or -1
        if sign == -1 then
            -- Player is below box, push box up
            box.y = box.y + (overlapY + 1)
            box.vy = math.min(box.vy, -50)
        else
            -- Player is above box (standing on it)
            box.y = box.y + (overlapY / 2 + 1)
            player.y = player.y - (overlapY / 2 + 1)
            player.vy = math.min(player.vy, 0)
            player.onGround = true
            -- Box gets pushed down slightly
            box.vy = box.vy + 100 * dt
        end
    end
end

-- Called when a projectile hits a box - returns true if hit
function Dropbox.hitBox(projX, projY, projRadius)
    for i = #boxes, 1, -1 do
        local box = boxes[i]
        local halfSize = Dropbox.BOX_SIZE / 2
        -- Circle vs AABB collision
        local closestX = math.max(box.x - halfSize, math.min(projX, box.x + halfSize))
        local closestY = math.max(box.y - halfSize, math.min(projY, box.y + halfSize))
        local dx = projX - closestX
        local dy = projY - closestY
        if (dx * dx + dy * dy) <= (projRadius * projRadius) then
            -- Hit! Spawn life charge and remove box
            Dropbox._spawnCharge(box.x, box.y)
            table.remove(boxes, i)
            return true
        end
    end
    return false
end

function Dropbox._spawnCharge(x, y)
    local charge = {
        x = x,
        y = y,
        age = 0
    }
    table.insert(charges, charge)
end

function Dropbox._playerTouchesCharge(player, charge)
    local px = player.x - player.shapeWidth / 2
    local py = player.y - player.shapeHeight / 2
    local pw = player.shapeWidth
    local ph = player.shapeHeight
    local halfCharge = Dropbox.CHARGE_SIZE / 2
    -- AABB vs AABB
    return px < charge.x + halfCharge and px + pw > charge.x - halfCharge and
           py < charge.y + halfCharge and py + ph > charge.y - halfCharge
end

function Dropbox.draw()
    -- Draw boxes
    for _, box in ipairs(boxes) do
        local halfSize = Dropbox.BOX_SIZE / 2
        -- Box body (brown crate)
        love.graphics.setColor(0.6, 0.4, 0.2, 0.95)
        love.graphics.rectangle("fill", box.x - halfSize, box.y - halfSize, Dropbox.BOX_SIZE, Dropbox.BOX_SIZE)
        -- Crate lines
        love.graphics.setColor(0.4, 0.25, 0.1, 0.8)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", box.x - halfSize, box.y - halfSize, Dropbox.BOX_SIZE, Dropbox.BOX_SIZE)
        love.graphics.line(box.x - halfSize, box.y, box.x + halfSize, box.y)
        love.graphics.line(box.x, box.y - halfSize, box.x, box.y + halfSize)
        -- Question mark
        love.graphics.setColor(1, 1, 0.3, 0.9)
        love.graphics.printf("?", box.x - halfSize, box.y - 8, Dropbox.BOX_SIZE, "center")
    end

    -- Draw life charges
    for _, charge in ipairs(charges) do
        local bob = math.sin(charge.age * Dropbox.CHARGE_BOB_SPEED) * 4
        local halfSize = Dropbox.CHARGE_SIZE / 2
        local alpha = charge.age > Dropbox.CHARGE_LIFETIME - 2 and 
                      (0.5 + 0.5 * math.sin(charge.age * 10)) or 1  -- blink when expiring
        -- Glow
        love.graphics.setColor(0.2, 0.9, 0.3, alpha * 0.3)
        love.graphics.circle("fill", charge.x, charge.y + bob, halfSize * 1.5)
        -- Core
        love.graphics.setColor(0.3, 1.0, 0.4, alpha * 0.9)
        love.graphics.circle("fill", charge.x, charge.y + bob, halfSize)
        -- Cross (health symbol)
        love.graphics.setColor(1, 1, 1, alpha * 0.9)
        love.graphics.setLineWidth(3)
        love.graphics.line(charge.x - 6, charge.y + bob, charge.x + 6, charge.y + bob)
        love.graphics.line(charge.x, charge.y + bob - 6, charge.x, charge.y + bob + 6)
    end
    love.graphics.setLineWidth(1)
end

return Dropbox

