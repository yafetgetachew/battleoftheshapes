-- player.lua
-- Player class: holds state, handles input, delegates physics

local Shapes      = require("shapes")
local Physics     = require("physics")
local Projectiles = require("projectiles")

local Player = {}
Player.__index = Player

-- Shape → ability type mapping (all shapes use fireball)
Player.ABILITY_MAP = {
    triangle  = "fireball",
    circle    = "fireball",
    square    = "fireball",
    rectangle = "fireball",
}

Player.WILL_REGEN = 10  -- will points recovered per second

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

-- Cast fireball ability toward a target player
function Player:castAbility(target)
    if self.will < Projectiles.WILL_COST then return false end
    if not Player.ABILITY_MAP[self.shapeKey] then return false end
    return Projectiles.spawnFireball(self, target)
end

-- Cast fireball at nearest alive enemy from a list of all players
function Player:castAbilityAtNearest(allPlayers)
    if self.will < Projectiles.WILL_COST then return false end
    if not Player.ABILITY_MAP[self.shapeKey] then return false end

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
        return
    end

    self:handleInput(dt)
    Physics.updatePlayer(self, dt)

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
    if state.x then self.x = state.x end
    if state.y then self.y = state.y end
    if state.vx then self.vx = state.vx end
    if state.vy then self.vy = state.vy end
    if state.life then self.life = state.life end
    if state.will then self.will = state.will end
    if state.facingRight ~= nil then self.facingRight = state.facingRight end
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
        facingRight = self.facingRight
    }
end

function Player:draw()
    if not self.shapeKey then return end
    Shapes.drawShape(self.shapeKey, self.x, self.y, 1.0)

    -- Hit flash overlay (white flash when damaged)
    if self.hitFlash > 0 then
        local flashAlpha = (self.hitFlash / 0.25) * 0.6
        love.graphics.setColor(1, 1, 1, flashAlpha)
        -- Redraw shape silhouette as white overlay
        local def = Shapes.get(self.shapeKey)
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

