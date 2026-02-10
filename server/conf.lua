-- conf.lua for headless dedicated server
-- Disables all visual/audio modules for CLI operation

function love.conf(t)
    t.title = "B.O.T.S Dedicated Server"
    t.version = "11.4"

    -- Disable window entirely
    t.window = nil

    -- Disable all visual/audio modules
    t.modules.audio    = false
    t.modules.graphics = false
    t.modules.image    = false
    t.modules.joystick = false
    t.modules.keyboard = false
    t.modules.mouse    = false
    t.modules.physics  = false
    t.modules.sound    = false
    t.modules.touch    = false
    t.modules.video    = false
    t.modules.window   = false
    t.modules.font     = false

    -- Keep these enabled
    t.modules.event    = true
    t.modules.math     = true
    t.modules.system   = true
    t.modules.timer    = true
    t.modules.thread   = true
    t.modules.data     = true

    -- Console output (Windows)
    t.console = true
end

