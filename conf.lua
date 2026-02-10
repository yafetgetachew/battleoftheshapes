function love.conf(t)
    t.title = "B.O.T.S - Battle of the Shapes"
    t.version = "11.4"
    t.window.width = 1280
    t.window.height = 720
    t.window.fullscreen = true
    t.window.fullscreentype = "desktop"
    t.window.resizable = false
    t.window.vsync = 1
    t.modules.audio = true
    t.modules.event = true
    t.modules.graphics = true
    t.modules.image = true
    t.modules.joystick = false
    t.modules.keyboard = true
    t.modules.math = true
    t.modules.mouse = true
    t.modules.physics = false
    t.modules.sound = true
    t.modules.system = true
    t.modules.timer = true
    t.modules.touch = false
    t.modules.video = false
    t.modules.window = true
    t.modules.thread = true
end

