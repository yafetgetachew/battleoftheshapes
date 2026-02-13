-- selection.lua
-- Shape selection screen for up to 12 players (networked) - 4x3 grid layout

local Shapes = require("shapes")
local Projectiles = require("projectiles")

local Selection = {}

-- Fun font path (Fredoka One – bubbly rounded display font, OFL licensed)
local FONT_PATH = "assets/fonts/FredokaOne-Regular.ttf"

-- Cache fonts to avoid allocating every frame.
local _titleFont
local _subFont
local _statsFont
local _smallFont
local function ensureFonts()
    if _titleFont then return end
    local scale = GLOBAL_SCALE or 1
    _titleFont = love.graphics.newFont(FONT_PATH, math.floor(28 * scale))
    _subFont = love.graphics.newFont(FONT_PATH, math.floor(14 * scale))
    _statsFont = love.graphics.newFont(FONT_PATH, math.floor(11 * scale))
    _smallFont = love.graphics.newFont(FONT_PATH, math.floor(10 * scale))
end

function Selection.clearFontCache()
    _titleFont = nil
    _subFont = nil
    _statsFont = nil
    _smallFont = nil
end

function Selection.new(localPlayerId, playerCount)
    local self = {}
    self.localPlayerId = localPlayerId or 1
    self.playerCount = playerCount or 3
    self.choices    = {}
    self.confirmed  = {}
    self.connected  = {}  -- track which players are connected
    for i = 1, self.playerCount do
        self.choices[i] = 1
        self.confirmed[i] = false
        self.connected[i] = false
    end
    -- Mark host (pid 1) as connected if not server mode
    if self.localPlayerId >= 1 then
        self.connected[self.localPlayerId] = true
    end
    self.timer      = 0                -- animation timer
    return setmetatable(self, {__index = Selection})
end

-- Mark a player as connected
function Selection:setConnected(playerId, isConnected)
    if playerId >= 1 and playerId <= self.playerCount then
        self.connected[playerId] = isConnected
    end
end

-- Get count of connected players
function Selection:getConnectedCount()
    local count = 0
    for i = 1, self.playerCount do
        if self.connected[i] then count = count + 1 end
    end
    return count
end

-- Get count of ready players
function Selection:getReadyCount()
    local count = 0
    for i = 1, self.playerCount do
        if self.confirmed[i] then count = count + 1 end
    end
    return count
end

function Selection:keypressed(key, controls)
    local pid = self.localPlayerId
    if pid < 1 then return end  -- spectator (server mode) can't browse

    local leftKey = (controls and controls.left) or "a"
    local rightKey = (controls and controls.right) or "d"
    local confirmKey = (controls and controls.jump) or "space"

    if not self.confirmed[pid] then
        if key == leftKey then
            self.choices[pid] = self.choices[pid] - 1
            if self.choices[pid] < 1 then self.choices[pid] = #Shapes.order end
        elseif key == rightKey then
            self.choices[pid] = self.choices[pid] + 1
            if self.choices[pid] > #Shapes.order then self.choices[pid] = 1 end
        elseif key == confirmKey then
            self.confirmed[pid] = true
        end
    end
end

-- Called when a remote player's choice is received over the network
function Selection:setRemoteChoice(playerId, choiceIndex)
    if playerId >= 1 and playerId <= self.playerCount then
        self.choices[playerId] = choiceIndex
    end
end

-- Called when a remote player confirms over the network
function Selection:setRemoteConfirmed(playerId, shapeIndex)
    if playerId >= 1 and playerId <= self.playerCount then
        self.choices[playerId] = shapeIndex
        self.confirmed[playerId] = true
    end
end

function Selection:update(dt)
    self.timer = self.timer + dt
end

function Selection:isDone()
    -- Only check connected players - all connected must be confirmed
    -- Returns done status AND the connected count to prevent race conditions
    local connectedCount = 0
    local allConfirmed = true
    for i = 1, self.playerCount do
        if self.connected[i] then
            connectedCount = connectedCount + 1
            if not self.confirmed[i] then allConfirmed = false end
        end
    end
    -- Need at least 2 connected players to start, and all must be confirmed
    local isDone = connectedCount >= 2 and allConfirmed
    return isDone, connectedCount
end

function Selection:getChoices()
    local choices = {}
    for i = 1, self.playerCount do
        choices[i] = Shapes.order[self.choices[i]]
    end
    return unpack(choices)
end

function Selection:getLocalChoice()
    if self.localPlayerId < 1 then return 1 end  -- spectator
    return self.choices[self.localPlayerId]
end

function Selection:isLocalConfirmed()
    if self.localPlayerId < 1 then return true end  -- spectator is always "ready"
    return self.confirmed[self.localPlayerId]
end

function Selection:draw(gameWidth, gameHeight, controls, players)
    local W = gameWidth or 1280
    local H = gameHeight or 720
    ensureFonts()
    local titleFont = _titleFont
    local subFont = _subFont
    local statsFont = _statsFont
    local smallFont = _smallFont

    -- Background
    love.graphics.setColor(0.08, 0.08, 0.14)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title
    love.graphics.setColor(1, 1, 1)
    love.graphics.setFont(titleFont)
    DrawSharpText("B.O.T.S - Battle of the Shapes", 0, 20, W, "center")

    -- Status line: X/Y players ready
    love.graphics.setFont(subFont)
    local connectedCount = self:getConnectedCount()
    local readyCount = self:getReadyCount()
    if connectedCount < 2 then
        love.graphics.setColor(1, 0.6, 0.3)
        DrawSharpText("Waiting for players... (" .. connectedCount .. "/2 minimum)", 0, 52, W, "center")
    else
        love.graphics.setColor(0.7, 0.9, 0.7)
        DrawSharpText(readyCount .. "/" .. connectedCount .. " players ready", 0, 52, W, "center")
    end

    -- Controls hint for local player
    local leftName = (controls and controls.left) or "A"
    local rightName = (controls and controls.right) or "D"
    local confirmName = (controls and controls.jump) or "Space"
    love.graphics.setFont(smallFont)
    love.graphics.setColor(0.5, 0.5, 0.6)
    DrawSharpText(string.upper(leftName) .. "/" .. string.upper(rightName) .. " select • " .. string.upper(confirmName) .. " confirm", 0, 72, W, "center")

    -- 4x3 grid layout
    local cols = 4
    local rows = 3
    local cellW = 280
    local cellH = 190
    local gapX = 15
    local gapY = 12
    local totalW = cols * cellW + (cols - 1) * gapX
    local totalH = rows * cellH + (rows - 1) * gapY
    local startX = (W - totalW) / 2
    local startY = 95

    for p = 1, self.playerCount do
        local col = (p - 1) % cols
        local row = math.floor((p - 1) / cols)
        local px = startX + col * (cellW + gapX)
        local py = startY + row * (cellH + gapY)

        -- Cell background
        if self.connected[p] then
            love.graphics.setColor(0.12, 0.12, 0.22, 0.95)
        else
            love.graphics.setColor(0.08, 0.08, 0.12, 0.6)
        end
        love.graphics.rectangle("fill", px, py, cellW, cellH, 8, 8)

        -- Border
        if self.confirmed[p] then
            love.graphics.setColor(0.3, 1.0, 0.4, 0.9)
        elseif p == self.localPlayerId then
            love.graphics.setColor(0.6, 0.6, 1.0, 1.0)
        elseif self.connected[p] then
            love.graphics.setColor(0.4, 0.4, 0.6, 0.7)
        else
            love.graphics.setColor(0.2, 0.2, 0.3, 0.4)
        end
        love.graphics.setLineWidth(p == self.localPlayerId and 3 or 2)
        love.graphics.rectangle("line", px, py, cellW, cellH, 8, 8)

        if self.connected[p] then
            -- Player name
            love.graphics.setFont(subFont)
            love.graphics.setColor(1, 1, 1)
            local playerName = "Player " .. p
            if players and players[p] and players[p].name then
                playerName = players[p].name
            end
            DrawSharpText(playerName, px, py + 8, cellW, "center")

            -- Shape preview
            local shapeKey = Shapes.order[self.choices[p]]
            local def = Shapes.get(shapeKey)
            local cx = px + cellW / 2
            local cy = py + 75
            local bobOffset = math.sin(self.timer * 2.5 + p) * 4
            Shapes.drawShape(shapeKey, cx, cy + bobOffset, 1.2)

            -- Shape name
            love.graphics.setColor(0.9, 0.9, 0.9)
            love.graphics.setFont(statsFont)
            DrawSharpText(def.name, px, py + 115, cellW, "center")

            -- Stats (compact) - Row 1: HP, WP, DMG
            love.graphics.setFont(smallFont)
            local sy = py + 132
            love.graphics.setColor(0.9, 0.4, 0.4)
            DrawSharpText("HP:" .. def.life, px + 8, sy, 55, "left")
            love.graphics.setColor(0.4, 0.7, 1.0)
            DrawSharpText("WP:" .. def.will, px + 63, sy, 50, "left")
            love.graphics.setColor(1.0, 0.5, 0.2)
            DrawSharpText("DMG:" .. Projectiles.DAMAGE, px + 113, sy, 55, "left")
            -- Row 2: SPD, JMP
            local sy2 = sy + 14
            love.graphics.setColor(0.7, 0.7, 0.7)
            DrawSharpText("SPD:" .. def.speed, px + 8, sy2, 70, "left")
            DrawSharpText("JMP:" .. math.abs(def.jumpForce), px + 88, sy2, 80, "left")

            -- Navigation arrows (local player only, not confirmed)
            if p == self.localPlayerId and not self.confirmed[p] then
                love.graphics.setColor(1, 1, 1, 0.5)
                love.graphics.polygon("fill",
                    px + 15, cy,
                    px + 28, cy - 10,
                    px + 28, cy + 10)
                love.graphics.polygon("fill",
                    px + cellW - 15, cy,
                    px + cellW - 28, cy - 10,
                    px + cellW - 28, cy + 10)
            end

            -- Ready badge or waiting indicator
            if self.confirmed[p] then
                love.graphics.setColor(0.3, 1.0, 0.4)
                love.graphics.setFont(statsFont)
                DrawSharpText("✓ READY", px, py + cellH - 25, cellW, "center")
            elseif p == self.localPlayerId then
                love.graphics.setColor(0.8, 0.8, 0.4, 0.8)
                love.graphics.setFont(smallFont)
                DrawSharpText("Press " .. string.upper(confirmName) .. " to ready", px, py + cellH - 22, cellW, "center")
            else
                love.graphics.setColor(0.5, 0.5, 0.5)
                love.graphics.setFont(smallFont)
                DrawSharpText("Selecting...", px, py + cellH - 22, cellW, "center")
            end
        else
            -- Empty slot
            love.graphics.setFont(subFont)
            love.graphics.setColor(0.3, 0.3, 0.4, 0.6)
            DrawSharpText("Slot " .. p, px, py + cellH/2 - 20, cellW, "center")
            love.graphics.setFont(smallFont)
            love.graphics.setColor(0.25, 0.25, 0.3, 0.5)
            DrawSharpText("Waiting for player...", px, py + cellH/2, cellW, "center")
        end
    end
end

return Selection

