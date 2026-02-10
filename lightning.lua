-- lightning.lua
-- Random lightning strike system for B.O.T.S

local Physics = require("physics")
local Sounds  = require("sounds")

local Lightning = {}

Lightning.DAMAGE = 20
Lightning.STRIKE_RADIUS = 50       -- pixels from center that deal damage
Lightning.MIN_INTERVAL = 4         -- minimum seconds between strikes
Lightning.MAX_INTERVAL = 10        -- maximum seconds between strikes
Lightning.FLASH_DURATION = 0.5     -- how long the bolt is visible
Lightning.WARNING_DURATION = 1.0   -- how long the warning indicator shows

local strikes = {}       -- active lightning visual effects
local nextStrikeTimer = 5 -- countdown to next strike
local warnings = {}       -- active warning indicators

function Lightning.reset()
    strikes = {}
    warnings = {}
    nextStrikeTimer = Lightning.MIN_INTERVAL + math.random() * (Lightning.MAX_INTERVAL - Lightning.MIN_INTERVAL)
end

function Lightning.update(dt, players)
    -- Count down to next strike
    nextStrikeTimer = nextStrikeTimer - dt
    if nextStrikeTimer <= 0 then
        Lightning._spawnStrike(players)
        nextStrikeTimer = Lightning.MIN_INTERVAL + math.random() * (Lightning.MAX_INTERVAL - Lightning.MIN_INTERVAL)
    end

    -- Show warning before strike
    for i = #warnings, 1, -1 do
        local w = warnings[i]
        w.age = w.age + dt
        if w.age >= Lightning.WARNING_DURATION then
            -- Actually strike now
            Lightning._doStrike(w.x, players)
            table.remove(warnings, i)
        end
    end

    -- Update active strike visuals
    for i = #strikes, 1, -1 do
        local s = strikes[i]
        s.age = s.age + dt
        if s.age >= Lightning.FLASH_DURATION then
            table.remove(strikes, i)
        end
    end
end

function Lightning._spawnStrike(players)
    -- Pick a random X position on the playable area
    local x = Physics.WALL_LEFT + 60 + math.random() * (Physics.WALL_RIGHT - Physics.WALL_LEFT - 120)
    table.insert(warnings, {
        x = x,
        age = 0
    })
end

function Lightning._doStrike(x, players)
    -- Create visual bolt
    local bolt = {
        x = x,
        age = 0,
        segments = Lightning._generateBoltSegments(x)
    }
    table.insert(strikes, bolt)
    Sounds.play("lightning")

    -- Damage players in radius
    if players then
        for _, player in ipairs(players) do
            if player.life and player.life > 0 then
                local dx = math.abs(player.x - x)
                if dx <= Lightning.STRIKE_RADIUS then
                    player.life = math.max(0, player.life - Lightning.DAMAGE)
                    player.hitFlash = 0.25
                    Sounds.play("player_hurt")
                end
            end
        end
    end
end

function Lightning._generateBoltSegments(x)
    local segments = {}
    local y = 0
    local cx = x
    local step = 30
    while y < Physics.GROUND_Y do
        local nx = cx + (math.random() - 0.5) * 60
        local ny = math.min(y + step + math.random() * 20, Physics.GROUND_Y)
        table.insert(segments, {x1 = cx, y1 = y, x2 = nx, y2 = ny})
        cx = nx
        y = ny
    end
    return segments
end

-- Public version for network sync
Lightning.generateBoltSegments = Lightning._generateBoltSegments

function Lightning.draw(gameWidth, gameHeight)
    -- Draw warnings (pulsing circle on ground)
    for _, w in ipairs(warnings) do
        local pulse = 0.5 + 0.5 * math.sin(w.age * 12)
        local alpha = 0.3 + 0.4 * pulse
        love.graphics.setColor(1.0, 1.0, 0.3, alpha)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", w.x, Physics.GROUND_Y, Lightning.STRIKE_RADIUS * (0.5 + 0.5 * (w.age / Lightning.WARNING_DURATION)))
        -- Small crosshair
        love.graphics.setColor(1.0, 1.0, 0.0, alpha * 0.6)
        love.graphics.line(w.x - 10, Physics.GROUND_Y, w.x + 10, Physics.GROUND_Y)
        love.graphics.line(w.x, Physics.GROUND_Y - 10, w.x, Physics.GROUND_Y + 10)
    end

    -- Draw active bolts
    for _, s in ipairs(strikes) do
        local alpha = 1.0 - (s.age / Lightning.FLASH_DURATION)

        -- Screen flash (subtle)
        love.graphics.setColor(1, 1, 1, alpha * 0.08)
        love.graphics.rectangle("fill", 0, 0, gameWidth or 1280, gameHeight or 720)

        -- Bolt glow (thick, faint)
        love.graphics.setColor(0.6, 0.6, 1.0, alpha * 0.3)
        love.graphics.setLineWidth(12)
        for _, seg in ipairs(s.segments) do
            love.graphics.line(seg.x1, seg.y1, seg.x2, seg.y2)
        end

        -- Bolt core (thin, bright)
        love.graphics.setColor(0.9, 0.9, 1.0, alpha * 0.9)
        love.graphics.setLineWidth(3)
        for _, seg in ipairs(s.segments) do
            love.graphics.line(seg.x1, seg.y1, seg.x2, seg.y2)
        end

        -- Ground impact flash
        love.graphics.setColor(1.0, 1.0, 0.8, alpha * 0.6)
        love.graphics.circle("fill", s.x, Physics.GROUND_Y, 20 + 30 * (1 - alpha))

        love.graphics.setLineWidth(1)
    end
end

-- Get current state for network sync (host sends to clients)
function Lightning.getState()
    return {
        strikes = strikes,
        warnings = warnings,
        nextStrikeTimer = nextStrikeTimer
    }
end

-- Apply state from network (clients receive from host)
function Lightning.setState(state)
    if state then
        strikes = state.strikes or {}
        warnings = state.warnings or {}
		-- Default when field is missing (nil)
		if state.nextStrikeTimer ~= nil then
			nextStrikeTimer = state.nextStrikeTimer
		else
			nextStrikeTimer = 5
		end
    end
end

return Lightning
