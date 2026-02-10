-- shapes.lua
-- Defines the shape types and their visual/attribute properties

local Shapes = {}

Shapes.definitions = {
    square = {
        name = "Square",
        color = {0.2, 0.6, 1.0},       -- blue
        width = 48,
        height = 48,
        life = 120,
        will = 80,
        speed = 260,
        jumpForce = -520,
        description = "Balanced fighter with solid defense.",
        draw = function(self, x, y, w, h)
            love.graphics.rectangle("fill", x - w/2, y - h/2, w, h)
            -- inner highlight
            love.graphics.setColor(1, 1, 1, 0.15)
            love.graphics.rectangle("fill", x - w/2 + 4, y - h/2 + 4, w - 8, h - 8)
        end
    },
    triangle = {
        name = "Triangle",
        color = {1.0, 0.3, 0.3},       -- red
        width = 52,
        height = 52,
        life = 90,
        will = 110,
        speed = 310,
        jumpForce = -560,
        description = "Fast and agile, but fragile.",
        draw = function(self, x, y, w, h)
            local vertices = {
                x,          y - h/2,
                x - w/2,   y + h/2,
                x + w/2,   y + h/2
            }
            love.graphics.polygon("fill", vertices)
            -- inner highlight
            love.graphics.setColor(1, 1, 1, 0.15)
            local s = 0.7
            local cx, cy = x, y + h * 0.08
            local inner = {
                cx,            cy - h/2 * s,
                cx - w/2 * s,  cy + h/2 * s,
                cx + w/2 * s,  cy + h/2 * s
            }
            love.graphics.polygon("fill", inner)
        end
    },
    circle = {
        name = "Circle",
        color = {0.3, 1.0, 0.4},       -- green
        width = 48,
        height = 48,
        life = 100,
        will = 100,
        speed = 280,
        jumpForce = -540,
        description = "Well-rounded with balanced stats.",
        draw = function(self, x, y, w, h)
            love.graphics.ellipse("fill", x, y, w/2, h/2)
            -- inner highlight
            love.graphics.setColor(1, 1, 1, 0.15)
            love.graphics.ellipse("fill", x - w*0.08, y - h*0.08, w/2 * 0.6, h/2 * 0.6)
        end
    },
    rectangle = {
        name = "Rectangle",
        color = {1.0, 0.8, 0.2},       -- yellow
        width = 64,
        height = 40,
        life = 140,
        will = 60,
        speed = 220,
        jumpForce = -500,
        description = "Tanky and tough, but slow.",
        draw = function(self, x, y, w, h)
            love.graphics.rectangle("fill", x - w/2, y - h/2, w, h)
            -- inner stripe pattern
            love.graphics.setColor(1, 1, 1, 0.1)
            for i = 0, 3 do
                love.graphics.rectangle("fill", x - w/2 + 4 + i * 16, y - h/2 + 4, 8, h - 8)
            end
        end
    }
}

-- Ordered list for selection screen
Shapes.order = {"square", "triangle", "circle", "rectangle"}

function Shapes.get(key)
    return Shapes.definitions[key]
end

function Shapes.drawShape(key, x, y, scale)
    scale = scale or 1.0
    local def = Shapes.definitions[key]
    if not def then return end
    local w, h = def.width * scale, def.height * scale
	-- Preserve caller's color; individual shape draw() functions may change it.
	local r, g, b, a = love.graphics.getColor()
	love.graphics.setColor(def.color)
	def.draw(def, x, y, w, h)
	love.graphics.setColor(r, g, b, a)
end

return Shapes

