-- player.lua
-- Player class: holds state, handles input, delegates physics

local Shapes      = require("shapes")
local Physics     = require("physics")
local Projectiles = require("projectiles")
local Config      = require("config")

local Player = {}
Player.__index = Player

-- Font cache for name rendering
local FONT_PATH = "assets/fonts/FredokaOne-Regular.ttf"
local _nameFont = nil

function Player.clearFontCache()
    _nameFont = nil
end

local function getNameFont()
    if not _nameFont then
        local scale = GLOBAL_SCALE or 1
        _nameFont = love.graphics.newFont(FONT_PATH, math.floor(14 * scale))
    end
    return _nameFont
end

-- Callback for damage visualization (set by main.lua)
-- function(x, y, damage) called when player receives damage via network sync
Player.onDamageReceived = nil

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
Player.PROJECTILE_KNOCKBACK = 180  -- knockback velocity when hit by projectile

function Player.new(id, controls)
    local self = setmetatable({}, Player)
    self.id          = id               -- 1, 2, ... up to 12
    self.controls    = controls         -- {left=key, right=key, jump=key, cast=key} or nil for remote
    self.isRemote    = false            -- true for network-controlled players
    self.name        = "Player " .. id  -- display name (can be set via network or config)
    self.shapeKey    = nil              -- set after selection
    self.x           = 0
    self.y           = 0
    self.aimX        = 0                -- Aim target X (world coords)
    self.aimY        = 0                -- Aim target Y (world coords)
    self.vx          = 0
    self.vy          = 0
    self.onGround    = false
    self.life        = 100
    self.maxLife      = 100
    self.will        = 100
    self.maxWill      = 100
    self.speed       = 425              -- 25% faster (was 340)
    self.jumpForce   = -750             -- increased proportionally with gravity for snappier jumps
    self.jumpForce2  = -950             -- higher second jump
    self.jumpCount   = 0                -- current number of jumps performed
    self.maxJumps    = 2                -- maximum number of jumps allowed (double jump)
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
    -- Landing detection
    self._wasOnGround    = true        -- previous frame's onGround state
    self._justLanded     = false       -- true for one frame after landing
    -- Idle breathing animation
    self._idleTime       = 0           -- time spent idle (not moving)
    -- Death detection
    self._prevLife       = 100         -- previous frame's life for death detection
    self._justDied       = false       -- true for one frame when player dies
    self._deathTime      = 0           -- time since death (for explosion animation)
    -- Squash/stretch animation
    self._squashX        = 1.0         -- horizontal scale (1.0 = normal)
    self._squashY        = 1.0         -- vertical scale (1.0 = normal)
    self._squashTimer    = 0           -- time remaining for squash effect
    self._squashDuration = 0           -- total duration of current squash
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
    self.onGround = true  -- Set initial ground state to prevent floating on first frame
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
    if self.jumpCount < self.maxJumps then
        if self.jumpCount == 0 then
            self.vy = self.jumpForce
        else
            self.vy = self.jumpForce2
        end
        self.onGround = false
        self.jumpCount = self.jumpCount + 1
        return true
    end
    return false
end

-- Stop jump (variable jump height)
function Player:stopJump()
    if self.vy < 0 and not self.isDashing then
        self.vy = self.vy * 0.5
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

-- Cast ability towards a specific point (x, y)
function Player:castAbilityAt(tx, ty)
    if self.will < Projectiles.WILL_COST then return false end
    if not Player.ABILITY_MAP[self.shapeKey] then return false end

    -- Only primary fire (fireball) supports aiming for now
    return Projectiles.spawnFireballAt(self, tx, ty)
end

function Player:update(dt)
    if self.isRemote then
        -- Remote players: position comes from network, only update cosmetics + will regen
        if self.hitFlash > 0 then
            self.hitFlash = self.hitFlash - dt
        end
        -- Tick squash/stretch for remote players (visual only)
        if self._squashTimer > 0 then
            self._squashTimer = self._squashTimer - dt
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

    -- Track previous ground state for landing detection
    local wasOnGround = self.onGround

    Physics.updatePlayer(self, dt)

    -- Detect landing (was in air, now on ground)
    self._justLanded = false
    if self.onGround and not wasOnGround then
        self._justLanded = true
        self.jumpCount = 0  -- Reset jump count on landing
    end
    self._wasOnGround = self.onGround

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

    -- Tick down squash/stretch animation
    if self._squashTimer > 0 then
        self._squashTimer = self._squashTimer - dt
    end

    -- Track idle time for breathing animation
    local isMoving = math.abs(self.vx) > 10 or not self.onGround
    if isMoving then
        self._idleTime = 0
    else
        self._idleTime = self._idleTime + dt
    end
end

-- Check if player just landed (and consume the event)
function Player:consumeLanding()
    if self._justLanded then
        self._justLanded = false
        return true
    end
    return false
end

-- Get idle breathing scale (1.0 to 1.02)
function Player:getBreathingScale()
    if self._idleTime < 0.3 then
        return 1.0  -- Don't start breathing immediately
    end
    -- Gentle sine wave breathing
    local breathCycle = math.sin((self._idleTime - 0.3) * 2.5) * 0.02
    return 1.0 + math.max(0, breathCycle)
end

-- Check if player just died (and consume the event)
function Player:consumeDeath()
    if self._justDied then
        self._justDied = false
        return true
    end
    return false
end

-- Check for death transition (call this after life changes)
function Player:checkDeath(dt)
    if self._prevLife > 0 and self.life <= 0 then
        self._justDied = true
        self._deathTime = 0
    end
    self._prevLife = self.life
    -- Track time since death
    if self.life <= 0 and dt then
        self._deathTime = self._deathTime + dt
    end
end

-- Apply squash/stretch effect (scaleX, scaleY, duration)
-- scaleX < 1 = squash horizontally, scaleY > 1 = stretch vertically
function Player:applySquash(scaleX, scaleY, duration)
    self._squashX = scaleX
    self._squashY = scaleY
    self._squashTimer = duration
    self._squashDuration = duration
end

-- Get current squash/stretch scale (returns scaleX, scaleY)
function Player:getSquashScale()
    if self._squashTimer <= 0 then
        return 1.0, 1.0
    end
    -- Ease back to 1.0 over time
    local t = self._squashTimer / self._squashDuration
    local easeT = t * t  -- Quadratic ease-out (fast start, slow end)
    local sx = 1.0 + (self._squashX - 1.0) * easeT
    local sy = 1.0 + (self._squashY - 1.0) * easeT
    return sx, sy
end

-- Apply knockback from a hit (direction: 1 = right, -1 = left)
function Player:applyKnockback(direction, force)
    force = force or Player.PROJECTILE_KNOCKBACK
    self.vx = self.vx + direction * force
    -- Small upward pop
    if self.onGround then
        self.vy = -80
    end
end

-- Apply state received from network
function Player:applyNetState(state)
	-- NOTE: network fields may legitimately be 0 or false; only treat missing fields as nil.
    if state.x ~= nil then self.x = state.x end
    if state.y ~= nil then self.y = state.y end
    if state.vx ~= nil then self.vx = state.vx end
    if state.vy ~= nil then self.vy = state.vy end
    if state.life ~= nil then
        -- Detect damage taken and trigger visual effects
        if state.life < self.life and self.life > 0 then
            local dmgTaken = self.life - state.life
            self.hitFlash = 0.25  -- flash when damaged
            self:applySquash(0.7, 1.25, 0.15)  -- squash effect
            -- Fire damage callback for damage numbers
            if Player.onDamageReceived then
                Player.onDamageReceived(self.x, self.y, dmgTaken)
            end
        end
        self.life = state.life
    end
    if state.will ~= nil then self.will = state.will end
    if state.aimX ~= nil then self.aimX = state.aimX end
    if state.aimY ~= nil then self.aimY = state.aimY end
    if state.facingRight ~= nil then self.facingRight = state.facingRight end
    if state.armor ~= nil then self.armor = state.armor end
    if state.damageBoost ~= nil then self.damageBoost = state.damageBoost end
    if state.damageBoostShots ~= nil then self.damageBoostShots = state.damageBoostShots end
    if state.isDashing ~= nil then
        if state.isDashing and not self.isDashing then
            self.dashImpactPlayed = false
        end
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
        aimX = math.floor(self.aimX),
        aimY = math.floor(self.aimY),
        facingRight = self.facingRight,
        armor = self.armor,
        damageBoost = self.damageBoost,
        damageBoostShots = self.damageBoostShots,
        isDashing = self.isDashing,
        dashDir = self.dashDir
    }
end

function Player:draw(isGameOver)
    if not self.shapeKey then return end

    -- Dead player handling
    local isDead = self.life <= 0
    if isDead then
        -- During explosion animation (first 0.8 seconds), don't draw the player at all
        if self._deathTime < 0.8 then
            return
        end
        -- After explosion, draw as grey silhouette
        local def = Shapes.get(self.shapeKey)
        if def then
            local w, h = def.width, def.height
            -- Fade in the silhouette
            local fadeIn = math.min(1, (self._deathTime - 0.8) / 0.3)
            love.graphics.setColor(0.3, 0.3, 0.35, 0.6 * fadeIn)  -- Grey silhouette
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
        return  -- Don't draw anything else for dead players
    end

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

    -- ── Shape with idle breathing + squash/stretch ──
    local breathScale = self:getBreathingScale()
    local squashX, squashY = self:getSquashScale()
    local finalScaleX = breathScale * squashX
    local finalScaleY = breathScale * squashY
    Shapes.drawShape(self.shapeKey, self.x, self.y, finalScaleX, finalScaleY)

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

    -- Draw player name above the shape
    if self.name and #self.name > 0 then
        local nameFont = getNameFont()
        local scale = GLOBAL_SCALE or 1
        local nameY = self.y - self.shapeHeight / 2 - 20
        
        love.graphics.push()
        -- Move to the center point where text should be
        love.graphics.translate(self.x, nameY)
        -- Inverse scale for sharp text
        love.graphics.scale(1/scale, 1/scale)
        
        love.graphics.setFont(nameFont)
        
        -- Text wrapper width also needs scaling
        local width = 200 * scale
        local offsetX = 100 * scale
        
        -- Background shadow for readability
        love.graphics.setColor(0, 0, 0, 0.5)
        love.graphics.printf(self.name, -offsetX + 1, 1, width, "center")
        -- Name text (white with slight tint based on player ID)
        local r, g, b = 1, 1, 1
        if self.id == 1 then r, g, b = 1, 0.9, 0.8
        elseif self.id == 2 then r, g, b = 0.8, 0.9, 1
        elseif self.id == 3 then r, g, b = 0.9, 1, 0.8
        end
        love.graphics.setColor(r, g, b, 0.9)
        love.graphics.printf(self.name, -offsetX, 0, width, "center")
        
        love.graphics.pop()
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

