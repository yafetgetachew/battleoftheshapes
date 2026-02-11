-- physics.lua
-- Handles gravity, ground collision, and player-vs-player collision

local Sounds  = require("sounds")
local Network = require("network")

local Physics = {}

Physics.GRAVITY       = 1200      -- pixels/s²
Physics.GROUND_Y      = 620       -- y-coordinate of the ground surface
Physics.FRICTION      = 0.88      -- horizontal velocity damping each frame
Physics.BOUNCE        = 0.0       -- bounce factor on ground hit
Physics.WALL_LEFT     = 0
Physics.WALL_RIGHT    = 1280
Physics.PUSH_FORCE    = 400       -- push-apart force for overlapping players

-- Apply gravity and integrate velocity for a single player
function Physics.applyGravity(player, dt)
    player.vy = player.vy + Physics.GRAVITY * dt
    player.y  = player.y + player.vy * dt
    player.x  = player.x + player.vx * dt
    -- Horizontal friction (only when on ground and not pressing keys)
    if player.onGround then
        player.vx = player.vx * Physics.FRICTION
    end
end

-- Resolve ground collision for a player
function Physics.resolveGround(player)
    local halfH = player.shapeHeight / 2
    if player.y + halfH >= Physics.GROUND_Y then
        player.y = Physics.GROUND_Y - halfH
        if player.vy > 0 then
            player.vy = -player.vy * Physics.BOUNCE
            if math.abs(player.vy) < 20 then
                player.vy = 0
            end
        end
        player.onGround = true
    else
        player.onGround = false
    end
end

-- Keep player within screen bounds (walls)
function Physics.resolveWalls(player)
    local halfW = player.shapeWidth / 2
    if player.x - halfW < Physics.WALL_LEFT then
        player.x = Physics.WALL_LEFT + halfW
        player.vx = 0
    elseif player.x + halfW > Physics.WALL_RIGHT then
        player.x = Physics.WALL_RIGHT - halfW
        player.vx = 0
    end
end

-- AABB overlap test between two players
function Physics.playersOverlap(p1, p2)
    local ax1 = p1.x - p1.shapeWidth / 2
    local ay1 = p1.y - p1.shapeHeight / 2
    local ax2 = p1.x + p1.shapeWidth / 2
    local ay2 = p1.y + p1.shapeHeight / 2

    local bx1 = p2.x - p2.shapeWidth / 2
    local by1 = p2.y - p2.shapeHeight / 2
    local bx2 = p2.x + p2.shapeWidth / 2
    local by2 = p2.y + p2.shapeHeight / 2

    return ax1 < bx2 and ax2 > bx1 and ay1 < by2 and ay2 > by1
end

Physics.COLLISION_DAMAGE = 2   -- damage dealt to the lower player on collision

-- Track dash impact particles and flag
Physics._dashImpacts = {}  -- list of {x, y} positions where dash impacts occurred

function Physics.consumeDashImpacts()
    local impacts = Physics._dashImpacts
    Physics._dashImpacts = {}
    return impacts
end

-- Resolve player-vs-player collision by pushing them apart
-- Also applies collision damage: the lower player (higher Y) takes damage
function Physics.resolvePlayerCollision(p1, p2, dt)
    if not Physics.playersOverlap(p1, p2) then
        return
    end

    -- Calculate overlap on each axis
    local overlapX, overlapY
    local dx = p1.x - p2.x
    local dy = p1.y - p2.y
    local halfW = (p1.shapeWidth + p2.shapeWidth) / 2
    local halfH = (p1.shapeHeight + p2.shapeHeight) / 2

    overlapX = halfW - math.abs(dx)
    overlapY = halfH - math.abs(dy)

    if overlapX <= 0 or overlapY <= 0 then return end

    -- Only host (or solo/demo) applies damage; clients receive authoritative life from host
    local isAuthority = Network.getRole() ~= Network.ROLE_CLIENT
    local Player = require("player")

    -- ── Dash collision ──
    if isAuthority and (p1.isDashing or p2.isDashing) then
        local dasher = p1.isDashing and p1 or p2
        local target = p1.isDashing and p2 or p1

        -- Apply damage to dasher (unless invulnerable)
        if not dasher.invulnerable then
            local dmg = Player.DASH_SELF_DAMAGE
            if dasher.armor and dasher.armor > 0 then
                local absorbed = math.min(dasher.armor, dmg)
                dmg = dmg - absorbed
                dasher.armor = dasher.armor - absorbed
                if dasher.armor <= 0 then dasher.armor = 0 end
            end
            dasher.life = math.max(0, dasher.life - dmg)
            dasher.hitFlash = 0.25
        end

        -- Apply damage to target (unless invulnerable)
        if not target.invulnerable then
            local dmg = Player.DASH_TARGET_DAMAGE
            if target.armor and target.armor > 0 then
                local absorbed = math.min(target.armor, dmg)
                dmg = dmg - absorbed
                target.armor = target.armor - absorbed
                if target.armor <= 0 then target.armor = 0 end
            end
            target.life = math.max(0, target.life - dmg)
            target.hitFlash = 0.25
        end

        -- Knockback the target
        target.vx = Player.DASH_KNOCKBACK * dasher.dashDir

        -- End the dash
        dasher.isDashing = false
        dasher.dashTimer = 0
        dasher.vx = dasher.speed * dasher.dashDir * 0.2

        -- Record impact for particle effects and sound
        local impactX = (dasher.x + target.x) / 2
        local impactY = (dasher.y + target.y) / 2
        table.insert(Physics._dashImpacts, {x = impactX, y = impactY})
        Sounds.play("dash_impact")
        return  -- skip normal collision resolution after dash impact
    end

    -- Apply collision damage to the lower player (higher Y = lower on screen)
    local lowerPlayer = (p1.y > p2.y) and p1 or p2
    if isAuthority and lowerPlayer.life and lowerPlayer.life > 0 then
        -- Skip if invulnerable
        if not lowerPlayer.invulnerable then
            local dmg = Physics.COLLISION_DAMAGE * dt
            -- Armor absorbs collision damage
            if lowerPlayer.armor and lowerPlayer.armor > 0 then
                local absorbed = math.min(lowerPlayer.armor, dmg)
                dmg = dmg - absorbed
                lowerPlayer.armor = lowerPlayer.armor - absorbed
                if lowerPlayer.armor <= 0 then lowerPlayer.armor = 0 end
            end
            local prevLife = lowerPlayer.life
            lowerPlayer.life = math.max(0, lowerPlayer.life - dmg)
            -- Play hurt sound on significant damage ticks (not every frame)
            if math.floor(prevLife) ~= math.floor(lowerPlayer.life) then
                Sounds.play("player_hurt")
            end
        end
    end

    -- Resolve along the axis of least penetration
    if overlapX < overlapY then
        -- Push apart on X
        local sign = dx >= 0 and 1 or -1
        local pushEach = overlapX / 2 + 0.5
        p1.x = p1.x + pushEach * sign
        p2.x = p2.x - pushEach * sign
        -- Apply a small velocity push
        p1.vx = p1.vx + Physics.PUSH_FORCE * sign * dt
        p2.vx = p2.vx - Physics.PUSH_FORCE * sign * dt
    else
        -- Push apart on Y
        local sign = dy >= 0 and 1 or -1
        local pushEach = overlapY / 2 + 0.5
        p1.y = p1.y + pushEach * sign
        p2.y = p2.y - pushEach * sign
        -- If one lands on top of the other, give them ground
        if sign == 1 then
            -- p1 is below p2
            p2.vy = math.min(p2.vy, 0)
            p2.onGround = true
        else
            p1.vy = math.min(p1.vy, 0)
            p1.onGround = true
        end
    end
end

-- Resolve collisions for all pairs in a list of players
function Physics.resolveAllCollisions(players, dt)
    for i = 1, #players do
        for j = i + 1, #players do
            if players[i].life > 0 and players[j].life > 0 then
                Physics.resolvePlayerCollision(players[i], players[j], dt)
            end
        end
    end
end

-- Full physics step for a single player
function Physics.updatePlayer(player, dt)
    Physics.applyGravity(player, dt)
    Physics.resolveGround(player)
    Physics.resolveWalls(player)
end

return Physics

