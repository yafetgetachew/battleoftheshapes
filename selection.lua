-- selection.lua
-- Shape selection screen for 3 players (networked)

local Shapes = require("shapes")

local Selection = {}

function Selection.new(localPlayerId)
    local self = {}
    self.localPlayerId = localPlayerId or 1
    self.choices    = {1, 1, 1}        -- current index for each player (1-based)
    self.confirmed  = {false, false, false}
    self.timer      = 0                -- animation timer
    return setmetatable(self, {__index = Selection})
end

function Selection:keypressed(key)
    local pid = self.localPlayerId

    if not self.confirmed[pid] then
        -- All local players use the same controls for their own panel
        if pid == 1 then
            if key == "a" then
                self.choices[1] = self.choices[1] - 1
                if self.choices[1] < 1 then self.choices[1] = #Shapes.order end
            elseif key == "d" then
                self.choices[1] = self.choices[1] + 1
                if self.choices[1] > #Shapes.order then self.choices[1] = 1 end
            elseif key == "space" then
                self.confirmed[1] = true
            end
        else
            -- Clients use arrow keys
            if key == "left" then
                self.choices[pid] = self.choices[pid] - 1
                if self.choices[pid] < 1 then self.choices[pid] = #Shapes.order end
            elseif key == "right" then
                self.choices[pid] = self.choices[pid] + 1
                if self.choices[pid] > #Shapes.order then self.choices[pid] = 1 end
            elseif key == "return" then
                self.confirmed[pid] = true
            end
        end
    end
end

-- Called when a remote player's choice is received over the network
function Selection:setRemoteChoice(playerId, choiceIndex)
    if playerId >= 1 and playerId <= 3 then
        self.choices[playerId] = choiceIndex
    end
end

-- Called when a remote player confirms over the network
function Selection:setRemoteConfirmed(playerId, shapeIndex)
    if playerId >= 1 and playerId <= 3 then
        self.choices[playerId] = shapeIndex
        self.confirmed[playerId] = true
    end
end

function Selection:update(dt)
    self.timer = self.timer + dt
end

function Selection:isDone()
    return self.confirmed[1] and self.confirmed[2] and self.confirmed[3]
end

function Selection:getChoices()
    return Shapes.order[self.choices[1]], Shapes.order[self.choices[2]], Shapes.order[self.choices[3]]
end

function Selection:getLocalChoice()
    return self.choices[self.localPlayerId]
end

function Selection:isLocalConfirmed()
    return self.confirmed[self.localPlayerId]
end

function Selection:draw()
    local W = love.graphics.getWidth()
    local H = love.graphics.getHeight()

    -- Background
    love.graphics.setColor(0.08, 0.08, 0.14)
    love.graphics.rectangle("fill", 0, 0, W, H)

    -- Title
    love.graphics.setColor(1, 1, 1)
    local titleFont = love.graphics.newFont(32)
    love.graphics.setFont(titleFont)
    love.graphics.printf("B.O.T.S - Battle of the Shapes", 0, 30, W, "center")

    local subFont = love.graphics.newFont(16)
    love.graphics.setFont(subFont)
    love.graphics.setColor(0.7, 0.7, 0.7)
    love.graphics.printf("Select Your Shape", 0, 72, W, "center")

    -- Draw panels for each player (3 across)
    local panelW = 370
    local panelH = 420
    local panelY = 110
    local gap = 20
    local totalW = panelW * 3 + gap * 2
    local startX = (W - totalW) / 2
    local labels = {"Player 1 (A/D + Space)", "Player 2 (Waiting...)", "Player 3 (Waiting...)"}
    if self.localPlayerId == 2 then
        labels[2] = "Player 2 (←/→ + Enter)"
    elseif self.localPlayerId == 3 then
        labels[3] = "Player 3 (←/→ + Enter)"
    end

    local statsFont = love.graphics.newFont(13)

    for p = 1, 3 do
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

