-- hud.lua
-- Heads-Up Display: health bars, will bars, player info

local Shapes = require("shapes")

local HUD = {}
-- Fun font path (Fredoka One – bubbly rounded display font, OFL licensed)
local FONT_PATH = "assets/fonts/FredokaOne-Regular.ttf"

-- Cache HUD fonts to avoid allocating new Font objects every frame.
local _nameFont
local _statFont

function HUD.clearFontCache()
    _nameFont = nil
    _statFont = nil
end

local function ensureFonts()
    if _nameFont then return end
    
    -- Use global scale from main.lua if available, otherwise 1
    local scale = GLOBAL_SCALE or 1
    
    _nameFont = love.graphics.newFont(FONT_PATH, math.floor(14 * scale))
    _statFont = love.graphics.newFont(FONT_PATH, math.floor(11 * scale))
end


local BAR_WIDTH  = 240
local BAR_HEIGHT = 18
local WILL_HEIGHT = 10
local MARGIN     = 20
local TOP_Y      = 14

-- Draw HUD for all players
function HUD.draw(players, gameWidth)
    local W = gameWidth or 1280
    local count = #players
    local gap = 20
    local totalW = BAR_WIDTH * count + gap * (count - 1)
    local startX = (W - totalW) / 2

    for i, player in ipairs(players) do
        local x = startX + (i - 1) * (BAR_WIDTH + gap)
        HUD.drawPlayerInfo(player, x, TOP_Y, false)
    end
end

function HUD.drawPlayerInfo(player, x, y)
	ensureFonts()
    local def = Shapes.get(player.shapeKey)
    if not def then return end
    
    local scale = GLOBAL_SCALE or 1
	local nameFont = _nameFont
	local statFont = _statFont
    
    -- Helper to draw text with inverse scaling for sharpness
    -- We are drawing inside the HUD which is top-level (not camera transformed),
    -- but it IS scaled by GLOBAL_SCALE in main.lua's draw stack.
    local function drawSharpText(text, tx, ty, limit, align, font)
        love.graphics.setFont(font)
        love.graphics.push()
        love.graphics.translate(tx, ty)
        love.graphics.scale(1/scale, 1/scale)
        -- scale up the width limit
        love.graphics.printf(text, 0, 0, limit * scale, align)
        love.graphics.pop()
    end

    -- Player name + shape
    love.graphics.setColor(def.color)
    local label = "P" .. player.id .. " - " .. def.name
    drawSharpText(label, x, y, BAR_WIDTH, "center", nameFont)

    -- ── Life bar ──
    local barY = y + 20
    -- Background
    love.graphics.setColor(0.2, 0.2, 0.2, 0.8)
    love.graphics.rectangle("fill", x, barY, BAR_WIDTH, BAR_HEIGHT, 4, 4)
    -- Fill
    local lifeRatio = math.max(0, player.life / player.maxLife)
    local fillColor = HUD.lerpColor(
        {0.9, 0.15, 0.15},  -- low health: red
        {0.2, 0.85, 0.3},   -- full health: green
        lifeRatio
    )
    love.graphics.setColor(fillColor[1], fillColor[2], fillColor[3], 0.9)
    love.graphics.rectangle("fill", x, barY, BAR_WIDTH * lifeRatio, BAR_HEIGHT, 4, 4)
    -- Border
    love.graphics.setColor(0.5, 0.5, 0.5, 0.6)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x, barY, BAR_WIDTH, BAR_HEIGHT, 4, 4)
    -- Text
    love.graphics.setColor(1, 1, 1)
    drawSharpText(
        math.floor(player.life) .. " / " .. player.maxLife,
        x, barY + 2, BAR_WIDTH, "center", statFont
    )

    -- ── Will bar ──
    local willY = barY + BAR_HEIGHT + 3
    -- Background
    love.graphics.setColor(0.15, 0.15, 0.25, 0.8)
    love.graphics.rectangle("fill", x, willY, BAR_WIDTH, WILL_HEIGHT, 3, 3)
    -- Fill
    local willRatio = math.max(0, player.will / player.maxWill)
    love.graphics.setColor(0.3, 0.5, 1.0, 0.85)
    love.graphics.rectangle("fill", x, willY, BAR_WIDTH * willRatio, WILL_HEIGHT, 3, 3)
    -- Border
    love.graphics.setColor(0.4, 0.4, 0.6, 0.5)
    love.graphics.rectangle("line", x, willY, BAR_WIDTH, WILL_HEIGHT, 3, 3)
    -- Will label
    love.graphics.setColor(0.8, 0.85, 1.0)
    drawSharpText(
        "Will: " .. math.floor(player.will),
        x, willY, BAR_WIDTH, "center", statFont
    )

    -- ── Buff indicators ──
    local buffY = willY + WILL_HEIGHT + 3
    local buffX = x
    love.graphics.setFont(statFont) -- Fallback if not using helper for some reason, but we will use helper
    if player.armor and player.armor > 0 then
        love.graphics.setColor(0.7, 0.7, 0.75, 0.9)
        drawSharpText("🛡 " .. math.floor(player.armor), buffX, buffY, BAR_WIDTH / 2, "center", statFont)
        buffX = buffX + BAR_WIDTH / 2
    end
    if player.damageBoostShots and player.damageBoostShots > 0 then
        love.graphics.setColor(1.0, 0.3, 0.2, 0.9)
        drawSharpText("⚔ x" .. player.damageBoostShots, buffX, buffY, BAR_WIDTH / 2, "center", statFont)
    end
end

-- Linearly interpolate between two {r,g,b} colors
function HUD.lerpColor(a, b, t)
    return {
        a[1] + (b[1] - a[1]) * t,
        a[2] + (b[2] - a[2]) * t,
        a[3] + (b[3] - a[3]) * t
    }
end

return HUD

