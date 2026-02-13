-- sounds.lua
-- Procedurally generated sound effects for B.O.T.S

local Sounds = {}

local loaded = false
local sfx = {}
local bgMusicTracks = {}  -- Array of gameplay background music tracks
local currentBgMusic = nil  -- Currently selected background track
local menuMusic = nil  -- Menu music
local musicMuted = false
local gameplayMusicPlaying = false
local menuMusicPlaying = false

-- Generate a SoundData with a given generator function
-- generator(t, duration) returns sample value in [-1, 1]
local function generateSound(duration, sampleRate, generator)
    local samples = math.floor(duration * sampleRate)
    local sd = love.sound.newSoundData(samples, sampleRate, 16, 1)
    for i = 0, samples - 1 do
        local t = i / sampleRate
        local val = generator(t, duration)
        -- Clamp
        val = math.max(-1, math.min(1, val))
        sd:setSample(i, val)
    end
    return love.audio.newSource(sd, "static")
end

function Sounds.load()
    if loaded then return end
    loaded = true

    local sr = 44100

    -- Fireball cast: short punchy "whoosh" with rising pitch
    sfx.fireball_cast = generateSound(0.25, sr, function(t, dur)
        local env = (1 - t / dur) * (1 - t / dur)
        local freq = 200 + t * 2000
        local noise = (math.random() * 2 - 1) * 0.3
        local tone = math.sin(2 * math.pi * freq * t) * 0.5
        return (tone + noise) * env
    end)
    sfx.fireball_cast:setVolume(0.4)

    -- Fireball hit: crunchy impact burst
    sfx.fireball_hit = generateSound(0.3, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        local freq = 120 - t * 200
        local tone = math.sin(2 * math.pi * freq * t) * 0.6
        local noise = (math.random() * 2 - 1) * 0.5
        -- Initial click
        local click = 0
        if t < 0.01 then click = (1 - t / 0.01) * 0.8 end
        return (tone + noise + click) * env
    end)
    sfx.fireball_hit:setVolume(0.5)

    -- Player hurt: short distorted buzz
    sfx.player_hurt = generateSound(0.2, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env * env
        local freq = 180 + math.sin(t * 60) * 80
        local val = math.sin(2 * math.pi * freq * t)
        -- Clip for distortion
        val = math.max(-0.6, math.min(0.6, val * 1.5))
        return val * env
    end)
    sfx.player_hurt:setVolume(0.35)

    -- Lightning strike: thunder crack
    sfx.lightning = generateSound(0.6, sr, function(t, dur)
        local env
        if t < 0.05 then
            env = t / 0.05
        else
            env = (1 - (t - 0.05) / (dur - 0.05))
            env = env * env
        end
        local noise = (math.random() * 2 - 1)
        local rumble = math.sin(2 * math.pi * 40 * t) * 0.4
        local crack = 0
        if t < 0.08 then
            crack = math.sin(2 * math.pi * 800 * t) * (1 - t / 0.08) * 0.5
        end
        return (noise * 0.6 + rumble + crack) * env
    end)
    sfx.lightning:setVolume(0.5)

    -- Lightning warning: rising electric buzz/crackle that builds tension
    sfx.lightning_warning = generateSound(1.0, sr, function(t, dur)
        -- Envelope: starts quiet, builds to loud
        local env = (t / dur) * (t / dur)  -- Quadratic rise
        -- Electric buzz with rising pitch
        local baseFreq = 60 + t * 200
        local buzz = math.sin(2 * math.pi * baseFreq * t) * 0.3
        -- Crackling noise that intensifies
        local crackle = (math.random() * 2 - 1) * 0.2 * (t / dur)
        -- High-pitched whine that rises
        local whine = math.sin(2 * math.pi * (400 + t * 600) * t) * 0.15 * (t / dur)
        return (buzz + crackle + whine) * env * 0.8
    end)
    sfx.lightning_warning:setVolume(0.35)

    -- Saw warning: metallic grinding buildup
    sfx.saw_warning = generateSound(1.0, sr, function(t, dur)
        -- Envelope: starts quiet, builds to loud
        local env = (t / dur) * (t / dur)  -- Quadratic rise
        -- Metallic grinding frequencies
        local baseFreq = 120 + t * 150
        local grind = math.sin(2 * math.pi * baseFreq * t) * 0.25
        -- Add metallic harmonics
        local metal = math.sin(2 * math.pi * baseFreq * 3.3 * t) * 0.15
        -- Rising whine
        local whine = math.sin(2 * math.pi * (200 + t * 400) * t) * 0.15 * (t / dur)
        -- Gritty noise
        local noise = (math.random() * 2 - 1) * 0.15 * (t / dur)
        return (grind + metal + whine + noise) * env * 0.7
    end)
    sfx.saw_warning:setVolume(0.35)

    -- Saw spawn: heavy metallic thunk when saw drops
    sfx.saw_spawn = generateSound(0.3, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        -- Low metallic thud
        local freq = 100 - t * 50
        local tone = math.sin(2 * math.pi * freq * t) * 0.5
        -- Metallic clang
        local clang = math.sin(2 * math.pi * 800 * t) * 0.3 * (1 - t / 0.1)
        if t > 0.1 then clang = 0 end
        return (tone + clang) * env
    end)
    sfx.saw_spawn:setVolume(0.4)

    -- Saw bounce: impact sound when saw hits ground
    sfx.saw_bounce = generateSound(0.2, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env * env
        -- Heavy metallic bounce
        local freq = 150 - t * 100
        local tone = math.sin(2 * math.pi * freq * t) * 0.6
        -- Sharp click
        local click = 0
        if t < 0.02 then click = (1 - t / 0.02) * 0.5 end
        -- Metallic ring
        local ring = math.sin(2 * math.pi * 600 * t) * 0.2 * (1 - t / dur)
        return (tone + click + ring) * env
    end)
    sfx.saw_bounce:setVolume(0.35)

    -- Pacman spawn: organic creature spawn with warbling
    sfx.pacman_spawn = generateSound(0.4, sr, function(t, dur)
        local env = math.min(1, t / 0.05) * (1 - (t - 0.05) / (dur - 0.05))
        -- Warbling creature sound with rising pitch
        local baseFreq = 150 + t * 200
        local warble = math.sin(2 * math.pi * 12 * t) * 30  -- Warble effect
        local freq = baseFreq + warble
        local tone = math.sin(2 * math.pi * freq * t) * 0.5
        -- Add harmonic for richness
        local harmonic = math.sin(2 * math.pi * freq * 1.5 * t) * 0.2
        -- Organic noise
        local noise = (math.random() * 2 - 1) * 0.15 * env
        return (tone + harmonic + noise) * env
    end)
    sfx.pacman_spawn:setVolume(0.4)

    -- Pacman bite: quick chomping sound
    sfx.pacman_bite = generateSound(0.15, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env * env
        -- Sharp bite with descending pitch
        local freq = 300 - t * 200
        local tone = math.sin(2 * math.pi * freq * t) * 0.6
        -- Click at start for bite impact
        local click = 0
        if t < 0.01 then click = (1 - t / 0.01) * 0.5 end
        -- Small noise for texture
        local noise = (math.random() * 2 - 1) * 0.2 * env
        return (tone + click + noise) * env
    end)
    sfx.pacman_bite:setVolume(0.4)

    -- Pacman death: organic creature death with descending warble
    sfx.pacman_death = generateSound(0.5, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        -- Descending pitch with warble
        local baseFreq = 200 - t * 150
        local warble = math.sin(2 * math.pi * 8 * t) * 20 * (1 - t / dur)
        local freq = baseFreq + warble
        local tone = math.sin(2 * math.pi * freq * t) * 0.5
        -- Harmonic for richness
        local harmonic = math.sin(2 * math.pi * freq * 0.75 * t) * 0.25
        -- Organic noise that fades
        local noise = (math.random() * 2 - 1) * 0.2 * env
        return (tone + harmonic + noise) * env
    end)
    sfx.pacman_death:setVolume(0.45)

    -- Dash whoosh: short rising pitch airy whoosh
    sfx.dash_whoosh = generateSound(0.15, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        local freq = 300 + t * 3000
        local noise = (math.random() * 2 - 1) * 0.5
        local tone = math.sin(2 * math.pi * freq * t) * 0.3
        return (tone + noise) * env
    end)
    sfx.dash_whoosh:setVolume(0.35)

    -- Dash impact: punchy low thud on collision
    sfx.dash_impact = generateSound(0.25, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env * env
        local freq = 80 - t * 100
        local tone = math.sin(2 * math.pi * freq * t) * 0.7
        local noise = (math.random() * 2 - 1) * 0.3
        local click = 0
        if t < 0.015 then click = (1 - t / 0.015) * 0.9 end
        return (tone + noise + click) * env
    end)
    sfx.dash_impact:setVolume(0.45)

    -- Jump: short bouncy "boing" with rising pitch
    sfx.jump = generateSound(0.15, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        local freq = 300 + t * 800
        local tone = math.sin(2 * math.pi * freq * t) * 0.5
        local harmonic = math.sin(2 * math.pi * freq * 2 * t) * 0.2
        return (tone + harmonic) * env
    end)
    sfx.jump:setVolume(0.25)

    -- Land: soft thud when hitting ground
    sfx.land = generateSound(0.12, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env * env
        local freq = 60 + (1 - t / dur) * 40
        local tone = math.sin(2 * math.pi * freq * t) * 0.6
        local noise = (math.random() * 2 - 1) * 0.2
        return (tone + noise) * env
    end)
    sfx.land:setVolume(0.3)

    -- Heartbeat: low rhythmic thump for low health warning
    sfx.heartbeat = generateSound(0.3, sr, function(t, dur)
        local env = 0
        -- Double-beat pattern (lub-dub)
        if t < 0.08 then
            env = math.sin(t / 0.08 * math.pi)
        elseif t > 0.12 and t < 0.18 then
            env = math.sin((t - 0.12) / 0.06 * math.pi) * 0.7
        end
        local freq = 45
        local tone = math.sin(2 * math.pi * freq * t)
        return tone * env * 0.8
    end)
    sfx.heartbeat:setVolume(0.4)

    -- Victory fanfare: triumphant ascending notes
    sfx.victory = generateSound(1.0, sr, function(t, dur)
        local env = 0
        local freq = 0
        -- Three ascending notes
        if t < 0.25 then
            env = math.min(1, t / 0.05) * (1 - (t / 0.25) * 0.3)
            freq = 440  -- A4
        elseif t < 0.5 then
            local lt = t - 0.25
            env = math.min(1, lt / 0.05) * (1 - (lt / 0.25) * 0.3)
            freq = 554  -- C#5
        elseif t < 0.85 then
            local lt = t - 0.5
            env = math.min(1, lt / 0.05) * (1 - (lt / 0.35) * 0.5)
            freq = 659  -- E5
        else
            local lt = t - 0.85
            env = (1 - lt / 0.15)
            freq = 880  -- A5
        end
        local tone = math.sin(2 * math.pi * freq * t) * 0.4
        local harmonic = math.sin(2 * math.pi * freq * 2 * t) * 0.15
        local harmonic2 = math.sin(2 * math.pi * freq * 3 * t) * 0.08
        return (tone + harmonic + harmonic2) * env
    end)
    sfx.victory:setVolume(0.5)

    -- Death explosion: dramatic boom with descending pitch
    sfx.death = generateSound(0.5, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        -- Low rumbling boom
        local freq = 80 - t * 60
        local boom = math.sin(2 * math.pi * freq * t) * 0.6
        -- Noise burst
        local noise = (math.random() * 2 - 1) * 0.4 * env * env
        -- Initial crack
        local crack = 0
        if t < 0.03 then
            crack = (1 - t / 0.03) * 0.8
        end
        return (boom + noise + crack) * env
    end)
    sfx.death:setVolume(0.6)

    -- Menu navigation sound: short click/blip
    sfx.menu_nav = generateSound(0.08, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        local freq = 600 + t * 400
        local tone = math.sin(2 * math.pi * freq * t) * 0.4
        local click = 0
        if t < 0.01 then click = (1 - t / 0.01) * 0.3 end
        return (tone + click) * env
    end)
    sfx.menu_nav:setVolume(0.3)

    -- Menu select sound: confirmation beep
    sfx.menu_select = generateSound(0.12, sr, function(t, dur)
        local env = (1 - t / dur)
        local freq = 800
        local tone = math.sin(2 * math.pi * freq * t) * 0.4
        local harmonic = math.sin(2 * math.pi * freq * 1.5 * t) * 0.2
        return (tone + harmonic) * env
    end)
    sfx.menu_select:setVolume(0.35)

    -- ═══════════════════════════════════════════════
    -- Shape-specific ability sounds (loaded from files)
    -- ═══════════════════════════════════════════════

    -- Square: Laser fire
    if love.filesystem.getInfo("assets/sounds/lazer.mp3") then
        sfx.laser_fire = love.audio.newSource("assets/sounds/lazer.mp3", "static")
        sfx.laser_fire:setVolume(0.5)
    end

    -- Triangle: Spike/Arrow fire
    if love.filesystem.getInfo("assets/sounds/arrows.mp3") then
        sfx.spike_fire = love.audio.newSource("assets/sounds/arrows.mp3", "static")
        sfx.spike_fire:setVolume(0.5)
    end

    -- Triangle: Spike hit - sharp impact (procedural fallback)
    sfx.spike_hit = generateSound(0.15, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env * env
        local freq = 200 - t * 150
        local tone = math.sin(2 * math.pi * freq * t) * 0.5
        local click = t < 0.008 and (1 - t / 0.008) * 0.7 or 0
        return (tone + click) * env
    end)
    sfx.spike_hit:setVolume(0.4)

    -- Rectangle: Block spawn/slam
    if love.filesystem.getInfo("assets/sounds/rectangle-slam.mp3") then
        sfx.block_spawn = love.audio.newSource("assets/sounds/rectangle-slam.mp3", "static")
        sfx.block_spawn:setVolume(0.5)
        -- Also use for hit and land
        sfx.block_hit = love.audio.newSource("assets/sounds/rectangle-slam.mp3", "static")
        sfx.block_hit:setVolume(0.55)
        sfx.block_land = love.audio.newSource("assets/sounds/rectangle-slam.mp3", "static")
        sfx.block_land:setVolume(0.45)
    end

    -- Circle: Boulder roll
    if love.filesystem.getInfo("assets/sounds/rock-roll.mp3") then
        sfx.boulder_roll = love.audio.newSource("assets/sounds/rock-roll.mp3", "static")
        sfx.boulder_roll:setVolume(0.5)
    end

    -- Circle: Boulder hit - heavy impact (procedural fallback)
    sfx.boulder_hit = generateSound(0.35, sr, function(t, dur)
        local env = (1 - t / dur)
        env = env * env
        local freq = 70 - t * 50
        local tone = math.sin(2 * math.pi * freq * t) * 0.6
        local noise = (math.random() * 2 - 1) * 0.35 * env
        local crack = t < 0.025 and (1 - t / 0.025) * 0.7 or 0
        return (tone + noise + crack) * env
    end)
    sfx.boulder_hit:setVolume(0.5)

    -- Load gameplay background music tracks (but don't auto-play)
    local bgFiles = {"assets/sounds/background.mp3", "assets/sounds/background2.mp3"}
    for _, filename in ipairs(bgFiles) do
        if love.filesystem.getInfo(filename) then
            local track = love.audio.newSource(filename, "stream")
            track:setLooping(true)
            track:setVolume(0.4)
            table.insert(bgMusicTracks, track)
        end
    end

    -- Load menu music
    if love.filesystem.getInfo("assets/sounds/menu.mp3") then
        menuMusic = love.audio.newSource("assets/sounds/menu.mp3", "stream")
        menuMusic:setLooping(true)
        menuMusic:setVolume(0.35)
    end
end

function Sounds.play(name)
    if not sfx[name] then return end
    -- Clone so multiple can play simultaneously
    local s = sfx[name]:clone()
    s:play()
end

-- Play the lightning warning sound (1-second buildup before strike)
function Sounds.playLightningWarning()
    if not sfx.lightning_warning then return end
    local s = sfx.lightning_warning:clone()
    s:play()
end

-- Play the saw warning sound (1-second buildup before saw drops)
function Sounds.playSawWarning()
    if not sfx.saw_warning then return end
    local s = sfx.saw_warning:clone()
    s:play()
end

-- Start gameplay background music (randomly selects a track)
function Sounds.startMusic()
    if #bgMusicTracks == 0 or musicMuted then return end

    -- Stop menu music if playing
    if menuMusic and menuMusicPlaying then
        menuMusic:stop()
        menuMusicPlaying = false
    end

    -- Stop any currently playing gameplay music
    if currentBgMusic then
        currentBgMusic:stop()
    end

    -- Randomly select a track
    local trackIndex = math.random(1, #bgMusicTracks)
    currentBgMusic = bgMusicTracks[trackIndex]
    currentBgMusic:play()
    gameplayMusicPlaying = true
end

-- Stop gameplay background music (called when leaving gameplay)
function Sounds.stopMusic()
    if currentBgMusic then
        currentBgMusic:stop()
        gameplayMusicPlaying = false
    end
end

-- Start menu music
function Sounds.startMenuMusic()
    if not menuMusic or musicMuted then return end

    -- Stop gameplay music if playing
    if currentBgMusic and gameplayMusicPlaying then
        currentBgMusic:stop()
        gameplayMusicPlaying = false
    end

    if not menuMusicPlaying then
        menuMusic:play()
        menuMusicPlaying = true
    end
end

-- Stop menu music
function Sounds.stopMenuMusic()
    if menuMusic then
        menuMusic:stop()
        menuMusicPlaying = false
    end
end

-- Set music muted state
function Sounds.setMusicMuted(muted)
    musicMuted = muted
    if muted then
        -- Stop all music
        if currentBgMusic then
            currentBgMusic:stop()
        end
        if menuMusic then
            menuMusic:stop()
        end
    else
        -- Resume appropriate music based on state
        if gameplayMusicPlaying and currentBgMusic then
            currentBgMusic:play()
        elseif menuMusicPlaying and menuMusic then
            menuMusic:play()
        end
    end
end

-- Get music muted state
function Sounds.isMusicMuted()
    return musicMuted
end

return Sounds

