-- sounds.lua
-- Procedurally generated sound effects for B.O.T.S

local Sounds = {}

local loaded = false
local sfx = {}

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
end

function Sounds.play(name)
    if not sfx[name] then return end
    -- Clone so multiple can play simultaneously
    local s = sfx[name]:clone()
    s:play()
end

return Sounds

