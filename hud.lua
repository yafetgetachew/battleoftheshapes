-- hud.lua
-- Heads-Up Display: health bars, will bars, player info

local Shapes = require("shapes")

local HUD = {}
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
    local scale = GLOBAL_SCALE or 1
    _nameFont = love.graphics.newFont(FONT_PATH, math.floor(14 * scale))
    _statFont = love.graphics.newFont(FONT_PATH, math.floor(11 * scale))
end

local BAR_WIDTH  = 240
local BAR_HEIGHT = 18
local WILL_HEIGHT = 10
local MARGIN     = 20
local TOP_Y      = 14

local function truncateText(text, maxLen)
    if not text then return "" end
    if #text <= maxLen then return text end
    return text:sub(1, maxLen - 1) .. "."
end

local function getPlayerDef(player)
    return Shapes.get(player.shapeKey)
end

local function drawSharpText(text, x, y, width, align, font)
    local scale = GLOBAL_SCALE or 1
    love.graphics.setFont(font)
    love.graphics.push()
    love.graphics.translate(x, y)
    love.graphics.scale(1 / scale, 1 / scale)
    love.graphics.printf(text, 0, 0, width * scale, align)
    love.graphics.pop()
end

local function getOrderedPlayers(players, localPlayerId)
    local ordered = {}
    local localEntry = nil
    for _, player in ipairs(players) do
        if player.id == localPlayerId then
            localEntry = player
        else
            ordered[#ordered + 1] = player
        end
    end
    table.sort(ordered, function(a, b) return a.id < b.id end)
    if localEntry then
        table.insert(ordered, 1, localEntry)
    end
    return ordered
end

-- Draw HUD for all players.
-- Uses a classic full-bar layout for up to 4 players, and a compact board for larger lobbies.
function HUD.draw(players, gameWidth, gameHeight, localPlayerId)
    local W = gameWidth or 1280
    local H = gameHeight or 720
    local count = #players
    if count <= 4 then
        local gap = 20
        local totalW = BAR_WIDTH * count + gap * (count - 1)
        local startX = (W - totalW) / 2
        for i, player in ipairs(players) do
            local x = startX + (i - 1) * (BAR_WIDTH + gap)
            HUD.drawPlayerInfo(player, x, TOP_Y, BAR_WIDTH)
        end
    else
        HUD.drawCompactBoard(players, W, H, localPlayerId)
    end
end

function HUD.drawCompactBoard(players, gameWidth, gameHeight, localPlayerId)
    ensureFonts()
    local nameFont = _nameFont
    local statFont = _statFont
    local ordered = getOrderedPlayers(players, localPlayerId)
    local count = #ordered
    local cols
    if count <= 6 then
        cols = 2
    elseif count <= 12 then
        cols = 4
    else
        cols = 5
    end
    local rows = math.ceil(count / cols)

    local panelX = MARGIN
    local panelY = 8
    local panelW = gameWidth - MARGIN * 2
    local panelPad = 10
    local headerH = 18
    local gapX = 10
    local gapY = 8
    local cardH = 44
    local innerW = panelW - panelPad * 2
    local cardW = math.floor((innerW - gapX * (cols - 1)) / cols)
    local panelH = panelPad * 2 + headerH + rows * cardH + gapY * (rows - 1)

    love.graphics.setColor(0.03, 0.04, 0.06, 0.78)
    love.graphics.rectangle("fill", panelX, panelY, panelW, panelH, 10, 10)
    love.graphics.setColor(0.35, 0.4, 0.5, 0.45)
    love.graphics.setLineWidth(2)
    love.graphics.rectangle("line", panelX, panelY, panelW, panelH, 10, 10)

    love.graphics.setColor(0.9, 0.94, 1.0, 0.9)
    drawSharpText("Arena Status", panelX + panelPad, panelY + 2, 220, "left", nameFont)
    love.graphics.setColor(0.7, 0.76, 0.86, 0.85)
    drawSharpText(count .. " players", panelX + panelW - 110, panelY + 5, 100, "right", statFont)

    for idx, player in ipairs(ordered) do
        local col = (idx - 1) % cols
        local row = math.floor((idx - 1) / cols)
        local x = panelX + panelPad + col * (cardW + gapX)
        local y = panelY + panelPad + headerH + row * (cardH + gapY)
        HUD.drawCompactPlayerInfo(player, x, y, cardW, cardH, player.id == localPlayerId)
    end
end

function HUD.drawCompactPlayerInfo(player, x, y, width, height, isLocal)
    ensureFonts()
    local statFont = _statFont
    local def = getPlayerDef(player)
    local color = def and def.color or {0.75, 0.75, 0.8}
    local life = math.max(0, player.life or 0)
    local maxLife = math.max(1, player.maxLife or 1)
    local will = math.max(0, player.will or 0)
    local maxWill = math.max(1, player.maxWill or 1)
    local lifeRatio = life / maxLife
    local willRatio = will / maxWill
    local isDead = life <= 0

    love.graphics.setColor(0.07, 0.08, 0.11, isDead and 0.45 or 0.82)
    love.graphics.rectangle("fill", x, y, width, height, 7, 7)
    love.graphics.setColor(color[1], color[2], color[3], isLocal and 0.95 or 0.6)
    love.graphics.setLineWidth(isLocal and 2 or 1)
    love.graphics.rectangle("line", x, y, width, height, 7, 7)

    love.graphics.setColor(0.95, 0.96, 1.0, isDead and 0.6 or 0.95)
    local name = player.name or ("Player " .. player.id)
    local label = "P" .. player.id .. " " .. truncateText(name, 12)
    drawSharpText(label, x + 6, y + 4, width - 12, "left", statFont)

    local hpText = math.floor(life) .. "/" .. math.floor(maxLife)
    drawSharpText(hpText, x + 6, y + 4, width - 12, "right", statFont)

    local barX = x + 6
    local barW = width - 12
    local lifeY = y + 18
    local willY = y + 30

    love.graphics.setColor(0.16, 0.16, 0.18, 0.9)
    love.graphics.rectangle("fill", barX, lifeY, barW, 8, 3, 3)
    local lifeColor = HUD.lerpColor({0.9, 0.15, 0.15}, {0.2, 0.85, 0.3}, lifeRatio)
    love.graphics.setColor(lifeColor[1], lifeColor[2], lifeColor[3], isDead and 0.45 or 0.95)
    love.graphics.rectangle("fill", barX, lifeY, barW * lifeRatio, 8, 3, 3)

    love.graphics.setColor(0.12, 0.14, 0.22, 0.95)
    love.graphics.rectangle("fill", barX, willY, barW, 5, 2, 2)
    love.graphics.setColor(0.35, 0.58, 1.0, isDead and 0.4 or 0.9)
    love.graphics.rectangle("fill", barX, willY, barW * willRatio, 5, 2, 2)

    local buffs = {}
    if player.armor and player.armor > 0 then
        buffs[#buffs + 1] = "AR " .. math.floor(player.armor)
    end
    if player.damageBoostShots and player.damageBoostShots > 0 then
        buffs[#buffs + 1] = "DMG x" .. player.damageBoostShots
    end
    if #buffs > 0 then
        drawSharpText(table.concat(buffs, "  "), x + 6, y + height - 11, width - 12, "right", statFont)
    end

    if isDead then
        love.graphics.setColor(1.0, 0.6, 0.6, 0.85)
        drawSharpText("KO", x, y + height - 11, width, "center", statFont)
    end
end

function HUD.drawPlayerInfo(player, x, y, width)
    ensureFonts()
    local def = getPlayerDef(player)
    if not def then return end
    local nameFont = _nameFont
    local statFont = _statFont
    local w = width or BAR_WIDTH

    -- Player name + shape
    love.graphics.setColor(def.color)
    drawSharpText("P" .. player.id .. " - " .. def.name, x, y, w, "center", nameFont)

    -- Life bar
    local barY = y + 20
    love.graphics.setColor(0.2, 0.2, 0.2, 0.8)
    love.graphics.rectangle("fill", x, barY, w, BAR_HEIGHT, 4, 4)
    local lifeRatio = math.max(0, player.life / player.maxLife)
    local fillColor = HUD.lerpColor({0.9, 0.15, 0.15}, {0.2, 0.85, 0.3}, lifeRatio)
    love.graphics.setColor(fillColor[1], fillColor[2], fillColor[3], 0.9)
    love.graphics.rectangle("fill", x, barY, w * lifeRatio, BAR_HEIGHT, 4, 4)
    love.graphics.setColor(0.5, 0.5, 0.5, 0.6)
    love.graphics.setLineWidth(1)
    love.graphics.rectangle("line", x, barY, w, BAR_HEIGHT, 4, 4)
    love.graphics.setColor(1, 1, 1)
    drawSharpText(math.floor(player.life) .. " / " .. player.maxLife, x, barY + 2, w, "center", statFont)

    -- Will bar
    local willY = barY + BAR_HEIGHT + 3
    love.graphics.setColor(0.15, 0.15, 0.25, 0.8)
    love.graphics.rectangle("fill", x, willY, w, WILL_HEIGHT, 3, 3)
    local willRatio = math.max(0, player.will / player.maxWill)
    love.graphics.setColor(0.3, 0.5, 1.0, 0.85)
    love.graphics.rectangle("fill", x, willY, w * willRatio, WILL_HEIGHT, 3, 3)
    love.graphics.setColor(0.4, 0.4, 0.6, 0.5)
    love.graphics.rectangle("line", x, willY, w, WILL_HEIGHT, 3, 3)
    love.graphics.setColor(0.8, 0.85, 1.0)
    drawSharpText("Will: " .. math.floor(player.will), x, willY, w, "center", statFont)

    -- Buff indicators
    local buffY = willY + WILL_HEIGHT + 3
    local buffX = x
    if player.armor and player.armor > 0 then
        love.graphics.setColor(0.7, 0.7, 0.75, 0.9)
        drawSharpText("AR " .. math.floor(player.armor), buffX, buffY, w / 2, "center", statFont)
        buffX = buffX + w / 2
    end
    if player.damageBoostShots and player.damageBoostShots > 0 then
        love.graphics.setColor(1.0, 0.3, 0.2, 0.9)
        drawSharpText("DMG x" .. player.damageBoostShots, buffX, buffY, w / 2, "center", statFont)
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
