-- selection.lua
-- Shape selection screen for 2 or 3 players (networked)

local Shapes = require("shapes")

local Selection = {}

-- Cache fonts to avoid allocating every frame.
local _titleFont
local _subFont
local _statsFont
local function ensureFonts()
    if _titleFont then return end
    _titleFont = love.graphics.newFont(32)
    _subFont = love.graphics.newFont(16)
    _statsFont = love.graphics.newFont(13)
end

function Selection.new(localPlayerId, playerCount)
    local self = {}
    self.localPlayerId = localPlayerId or 1
    self.playerCount = playerCount or 3
    self.choices    = {}
    self.confirmed  = {}
    for i = 1, self.playerCount do
        self.choices[i] = 1
        self.confirmed[i] = false
    end
    self.timer      = 0                -- animation timer
    return setmetatable(self, {__index = Selection})
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
    for i = 1, self.playerCount do
        if not self.confirmed[i] then return false end
    end
    return true
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

function Selection:draw(gameWidth, gameHeight, controls)
    local W = gameWidth or 1280
    local H = gameHeight or 720
	    ensureFonts()

    -- Background
    love.graphics.setColor(0.08, 0.08, 0.14)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title
    love.graphics.setColor(1, 1, 1)
	    love.graphics.setFont(_titleFont)
    love.graphics.printf("B.O.T.S - Battle of the Shapes", 0, 30, W, "center")

	    love.graphics.setFont(_subFont)
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.printf("Select Your Shape", 0, 72, W, "center")

    -- Draw panels for each player
    local panelW = self.playerCount == 2 and 450 or 370
    local panelH = 420
    local panelY = 110
    local gap = 20
    local totalW = panelW * self.playerCount + gap * (self.playerCount - 1)
    local startX = (W - totalW) / 2
    local labels = {}
    for i = 1, self.playerCount do
        labels[i] = "Player " .. i .. " (Waiting...)"
    end
    -- Show actual configured controls
    local leftName = (controls and controls.left) or "A"
    local rightName = (controls and controls.right) or "D"
    local confirmName = (controls and controls.jump) or "Space"
	    if self.localPlayerId >= 1 and self.localPlayerId <= self.playerCount then
	        labels[self.localPlayerId] = "Player " .. self.localPlayerId .. " (" .. string.upper(leftName) .. "/" .. string.upper(rightName) .. " + " .. string.upper(confirmName) .. ")"
	    end

	    local statsFont = _statsFont

    for p = 1, self.playerCount do
        local px = startX + (p - 1) * (panelW + gap)
        -- Panel background
        love.graphics.setColor(0.12, 0.12, 0.22, 0.9)
        love.graphics.rectangle("fill", px, panelY, panelW, panelH, 12, 12)

        -- Border (highlight if confirmed, extra bright if local player)
        if self.confirmed[p] then
            love.graphics.setColor(0.3, 1.0, 0.4, 0.8)
        elseif p == self.localPlayerId then
            love.graphics.setColor(0.5, 0.5, 0.8, 0.9)
        else
            love.graphics.setColor(0.3, 0.3, 0.5, 0.6)
        end
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", px, panelY, panelW, panelH, 12, 12)

        -- Player label
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(subFont)
        love.graphics.printf(labels[p], px, panelY + 12, panelW, "center")

        -- Draw the currently selected shape (large preview)
        local shapeKey = Shapes.order[self.choices[p]]
        local def = Shapes.get(shapeKey)
        local cx = px + panelW / 2
        local cy = panelY + 150
        local bobOffset = math.sin(self.timer * 2 + p) * 6
        Shapes.drawShape(shapeKey, cx, cy + bobOffset, 1.8)

        -- Shape name
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf(def.name, px, panelY + 210, panelW, "center")

        -- Stats
        love.graphics.setFont(statsFont)
        local sy = panelY + 235
        love.graphics.setColor(0.9, 0.3, 0.3)
        love.graphics.printf("Life: " .. def.life, px + 30, sy, panelW - 60, "left")
        love.graphics.setColor(0.4, 0.7, 1.0)
        love.graphics.printf("Will: " .. def.will, px + 30, sy, panelW - 60, "right")
        love.graphics.setColor(0.8, 0.8, 0.8)
        love.graphics.printf("Speed: " .. def.speed, px + 30, sy + 20, panelW - 60, "left")
        love.graphics.printf("Jump: " .. math.abs(def.jumpForce), px + 30, sy + 20, panelW - 60, "right")

        -- Description
        love.graphics.setColor(0.6, 0.6, 0.6)
        love.graphics.printf(def.description, px + 20, sy + 48, panelW - 40, "center")

        -- Navigation arrows (only for local player)
        if not self.confirmed[p] and p == self.localPlayerId then
            love.graphics.setColor(1, 1, 1, 0.6)
            love.graphics.polygon("fill",
                px + 20, panelY + 150,
                px + 38, panelY + 137,
                px + 38, panelY + 163)
            love.graphics.polygon("fill",
                px + panelW - 20, panelY + 150,
                px + panelW - 38, panelY + 137,
                px + panelW - 38, panelY + 163)
        end

        -- Confirmed badge
        if self.confirmed[p] then
            love.graphics.setColor(0.3, 1.0, 0.4)
            love.graphics.printf("✓ READY", px, panelY + panelH - 36, panelW, "center")
        end
    end
end

return Selection

