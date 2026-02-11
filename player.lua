-- player.lua
-- Player class: holds state, handles input, delegates physics

local Shapes      = require("shapes")
local Physics     = require("physics")
local Projectiles = require("projectiles")
local Config      = require("config")

local Player = {}
Player.__index = Player

-- Shape → ability type mapping (all shapes use fireball)
Player.ABILITY_MAP = {
    triangle  = "fireball",
    circle    = "fireball",
    square    = "fireball",
    rectangle = "fireball",
}

Player.WILL_REGEN = 10      -- will points recovered per second
Player.DASH_SPEED = 800     -- horizontal speed during dash (pixels/s)
Player.DASH_DURATION = 0.15 -- how long the dash lasts (seconds)
Player.DASH_COOLDOWN = 0.6  -- cooldown between dashes (seconds)
Player.DOUBLE_TAP_WINDOW = 0.25 -- max time between taps to trigger dash (seconds)
Player.DASH_SELF_DAMAGE = 10    -- damage to the dasher on collision
Player.DASH_TARGET_DAMAGE = 20  -- damage to the target on collision
Player.DASH_KNOCKBACK = 500     -- knockback velocity applied to target

function Player.new(id, controls)
    local self = setmetatable({}, Player)
    self.id          = id               -- 1, 2, or 3
    self.controls    = controls         -- {left=key, right=key, jump=key, cast=key} or nil for remote
    self.isRemote    = false            -- true for network-controlled players
    self.shapeKey    = nil              -- set after selection
    self.x           = 0
    self.y           = 0
    self.vx          = 0
    self.vy          = 0
    self.onGround    = false
    self.life        = 100
    self.maxLife      = 100
    self.will        = 100
    self.maxWill      = 100
    self.speed       = 280
    self.jumpForce   = -540
    self.shapeWidth  = 48
    self.shapeHeight = 48
    self.facingRight = (id == 1)
    self.hitFlash    = 0               -- remaining flash time (seconds)
    -- Buff state
    self.armor           = 0           -- absorbs up to 15 damage, then vanishes
    self.damageBoost     = 0           -- extra damage per shot (+10)
    self.damageBoostShots = 0          -- shots remaining with boost
    -- Dash state
    self.isDashing       = false       -- currently in a dash?
    self.dashTimer       = 0           -- remaining dash duration (seconds)
    self.dashCooldown    = 0           -- cooldown before next dash (seconds)
    self.dashDir         = 1           -- dash direction: 1 = right, -1 = left
    self._lastTapLeft    = 0           -- timestamp of last left-key press
    self._lastTapRight   = 0           -- timestamp of last right-key press
    -- Invulnerability (demo mode)
    self.invulnerable    = false
    return self
end

function Player:setShape(key)
    local def = Shapes.get(key)
    if not def then return end
    self.shapeKey    = key
    self.life        = def.life
    self.maxLife      = def.life
    self.will        = def.will
    self.maxWill      = def.will
    self.speed       = def.speed
    self.jumpForce   = def.jumpForce
    self.shapeWidth  = def.width
    self.shapeHeight = def.height
end

function Player:spawn(x, y)
    self.x  = x
    self.y  = y
    self.vx = 0
    self.vy = 0
end

function Player:handleInput(dt)
    if not self.controls then return end  -- no controls (e.g. bot players)
    -- During a dash, don't allow normal movement override
    if self.isDashing then return end
    local moving = false
    if love.keyboard.isDown(self.controls.left) then
        self.vx = -self.speed
        self.facingRight = false
        moving = true
    end
    if love.keyboard.isDown(self.controls.right) then
        self.vx = self.speed
        self.facingRight = true
        moving = true
    end
    -- If not pressing movement keys while on ground, let friction handle it
    if not moving and self.onGround then
        -- friction is applied in physics
    end
end

function Player:jump()
    if self.onGround then
        self.vy = self.jumpForce
        self.onGround = false
    end
end

-- Start a dash in the given direction (1 = right, -1 = left)
function Player:dash(dir)
    if self.isDashing then return false end
    if self.dashCooldown > 0 then return false end
    self.isDashing = true
    self.dashTimer = Player.DASH_DURATION
    self.dashCooldown = Player.DASH_COOLDOWN
    self.dashDir = dir
    self.facingRight = (dir == 1)
    self.vx = Player.DASH_SPEED * dir
    self.vy = 0  -- flatten vertical velocity during dash
    return true
end

-- Called from love.keypressed to detect double-tap
function Player:handleKeyForDash(key)
    if not self.controls then return false end
    if self.life <= 0 then return false end
    local now = love.timer.getTime()
    if key == self.controls.left then
        if (now - self._lastTapLeft) < Player.DOUBLE_TAP_WINDOW then
            self._lastTapLeft = 0
            return self:dash(-1)
        end
        self._lastTapLeft = now
    elseif key == self.controls.right then
        if (now - self._lastTapRight) < Player.DOUBLE_TAP_WINDOW then
            self._lastTapRight = 0
            return self:dash(1)
        end
        self._lastTapRight = now
    end
    return false
end

-- Cast fireball ability toward a target player
function Player:castAbility(target)
    if self.will < Projectiles.WILL_COST then return false end
    if not Player.ABILITY_MAP[self.shapeKey] then return false end
    return Projectiles.spawnFireball(self, target)
end

-- Cast fireball at nearest alive enemy from a list of all players
-- If aim assist is OFF, shoots in the direction the player is facing
function Player:castAbilityAtNearest(allPlayers)
    if self.will < Projectiles.WILL_COST then return false end
    if not Player.ABILITY_MAP[self.shapeKey] then return false end

    -- Check aim assist setting
    if Config.getAimAssist() then
        -- Aim assist ON: target nearest enemy
        local nearest = nil
        local nearestDist = math.huge
        for _, other in ipairs(allPlayers) do
            if other.id ~= self.id and other.life and other.life > 0 then
                local dist = math.abs(other.x - self.x)
                if dist < nearestDist then
                    nearestDist = dist
                    nearest = other
                end
            end
        end
        if nearest then
            return Projectiles.spawnFireball(self, nearest)
        end
        return false
    else
        -- Aim assist OFF: shoot in facing direction
        return Projectiles.spawnFireballDirectional(self, self.facingRight)
    end
end

function Player:update(dt)
    if self.isRemote then
        -- Remote players: position comes from network, only update cosmetics + will regen
        if self.hitFlash > 0 then
            self.hitFlash = self.hitFlash - dt
        end
        -- Will regen so host has accurate will values to broadcast
        if self.will < self.maxWill then
            self.will = math.min(self.maxWill, self.will + Player.WILL_REGEN * dt)
        end
        -- Tick dash state for remote players (visual only)
        if self.isDashing then
            self.dashTimer = self.dashTimer - dt
            if self.dashTimer <= 0 then
                self.isDashing = false
                self.dashTimer = 0
            end
        end
        if self.dashCooldown > 0 then
            self.dashCooldown = self.dashCooldown - dt
            if self.dashCooldown < 0 then self.dashCooldown = 0 end
        end
        return
    end

    self:handleInput(dt)
    Physics.updatePlayer(self, dt)

    -- Dash timer
    if self.isDashing then
        self.dashTimer = self.dashTimer - dt
        -- Keep dash velocity locked
        self.vx = Player.DASH_SPEED * self.dashDir
        if self.dashTimer <= 0 then
            self.isDashing = false
            self.dashTimer = 0
            -- Slow down after dash ends
            self.vx = self.speed * self.dashDir * 0.3
        end
    end

    -- Dash cooldown
    if self.dashCooldown > 0 then
        self.dashCooldown = self.dashCooldown - dt
        if self.dashCooldown < 0 then self.dashCooldown = 0 end
    end

    -- Passive will regeneration
    if self.will < self.maxWill then
        self.will = math.min(self.maxWill, self.will + Player.WILL_REGEN * dt)
    end

    -- Tick down hit flash
    if self.hitFlash > 0 then
        self.hitFlash = self.hitFlash - dt
    end
end

-- Apply state received from network
function Player:applyNetState(state)
	-- NOTE: network fields may legitimately be 0 or false; only treat missing fields as nil.
    if state.x ~= nil then self.x = state.x end
    if state.y ~= nil then self.y = state.y end
    if state.vx ~= nil then self.vx = state.vx end
    if state.vy ~= nil then self.vy = state.vy end
    if state.life ~= nil then self.life = state.life end
    if state.will ~= nil then self.will = state.will end
    if state.facingRight ~= nil then self.facingRight = state.facingRight end
    if state.armor ~= nil then self.armor = state.armor end
    if state.damageBoost ~= nil then self.damageBoost = state.damageBoost end
    if state.damageBoostShots ~= nil then self.damageBoostShots = state.damageBoostShots end
    if state.isDashing ~= nil then
        self.isDashing = state.isDashing
        if state.isDashing then
            self.dashTimer = Player.DASH_DURATION
            self.dashDir = state.dashDir or self.dashDir
        end
    end
end

-- Get state for sending over network
function Player:getNetState()
    return {
        id = self.id,
        x = math.floor(self.x * 10) / 10,
        y = math.floor(self.y * 10) / 10,
        vx = math.floor(self.vx),
        vy = math.floor(self.vy),
        life = math.floor(self.life),
        will = math.floor(self.will * 10) / 10,
        facingRight = self.facingRight,
        armor = self.armor,
        damageBoost = self.damageBoost,
        damageBoostShots = self.damageBoostShots,
        isDashing = self.isDashing,
        dashDir = self.dashDir
    }
end

function Player:draw()
    if not self.shapeKey then return end

    -- ── Buff auras (drawn behind the shape) ──
    local def = Shapes.get(self.shapeKey)
    if def then
        local auraRadius = math.max(def.width, def.height) * 0.75
        local time = love.timer.getTime()

        -- Armor aura – greyish pulsing shield
        if self.armor and self.armor > 0 then
            local pulse = 0.25 + 0.15 * math.sin(time * 3)
            love.graphics.setColor(0.7, 0.7, 0.75, pulse)
            love.graphics.circle("fill", self.x, self.y, auraRadius + 6)
            love.graphics.setColor(0.8, 0.8, 0.85, pulse * 0.6)
            love.graphics.setLineWidth(2)
            love.graphics.circle("line", self.x, self.y, auraRadius + 8)
        end

        -- Damage boost aura – reddish pulsing glow
        if self.damageBoostShots and self.damageBoostShots > 0 then
            local pulse = 0.2 + 0.15 * math.sin(time * 4)
            love.graphics.setColor(1.0, 0.2, 0.15, pulse)
            love.graphics.circle("fill", self.x, self.y, auraRadius + 4)
            love.graphics.setColor(1.0, 0.35, 0.2, pulse * 0.7)
            love.graphics.setLineWidth(2)
            love.graphics.circle("line", self.x, self.y, auraRadius + 6)
        end
    end

    -- ── Dash trail (drawn behind the shape) ──
    if self.isDashing then
        local trailAlpha = (self.dashTimer / Player.DASH_DURATION) * 0.4
        for i = 1, 3 do
            local offset = -self.dashDir * i * 14
            love.graphics.setColor(0.5, 0.8, 1.0, trailAlpha * (1 - i * 0.25))
            Shapes.drawShape(self.shapeKey, self.x + offset, self.y, 0.7)
        end
    end

    -- ── Shape ──
    Shapes.drawShape(self.shapeKey, self.x, self.y, 1.0)

    -- Hit flash overlay (white flash when damaged)
    if self.hitFlash > 0 then
        local flashAlpha = (self.hitFlash / 0.25) * 0.6
        love.graphics.setColor(1, 1, 1, flashAlpha)
        -- Redraw shape silhouette as white overlay
        if def then
            local w, h = def.width, def.height
            if self.shapeKey == "circle" then
                love.graphics.ellipse("fill", self.x, self.y, w/2, h/2)
            elseif self.shapeKey == "triangle" then
                love.graphics.polygon("fill",
                    self.x, self.y - h/2,
                    self.x - w/2, self.y + h/2,
                    self.x + w/2, self.y + h/2)
            else
                love.graphics.rectangle("fill", self.x - w/2, self.y - h/2, w, h)
            end
        end
    end

    -- Draw a small directional indicator (arrow under the shape)
    love.graphics.setColor(1, 1, 1, 0.5)
    local arrowY = self.y + self.shapeHeight / 2 + 8
    if self.facingRight then
        love.graphics.polygon("fill",
            self.x + 2, arrowY - 4,
            self.x + 10, arrowY,
            self.x + 2, arrowY + 4)
    else
        love.graphics.polygon("fill",
            self.x - 2, arrowY - 4,
            self.x - 10, arrowY,
            self.x - 2, arrowY + 4)
    end
end

-- Draw shadow on the ground beneath the player
function Player:drawShadow()
    if not self.shapeKey then return end
    local groundY = Physics.GROUND_Y
    local heightAboveGround = groundY - (self.y + self.shapeHeight / 2)
    local maxShadowDist = 300
    local alpha = math.max(0, 1 - heightAboveGround / maxShadowDist) * 0.3
    if alpha <= 0 then return end
    love.graphics.setColor(0, 0, 0, alpha)
    local sw = self.shapeWidth * (0.6 + 0.4 * (1 - heightAboveGround / maxShadowDist))
    love.graphics.ellipse("fill", self.x, groundY + 2, sw / 2, 5)
end

return Player

