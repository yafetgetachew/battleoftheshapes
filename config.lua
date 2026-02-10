-- config.lua
-- Configuration system for B.O.T.S
-- Handles saving and loading player preferences

local Config = {}

-- Default configuration
local defaultConfig = {
    controlScheme = "wasd",  -- "wasd" or "arrows"
    playerCount = "3",       -- "2" or "3"
    serverMode = "false"     -- "true" or "false" (dedicated server / relay mode)
}

-- Current configuration
local currentConfig = {}

-- Control scheme presets
Config.CONTROL_SCHEMES = {
    wasd = {
        left = "a",
        right = "d",
        jump = "space",
        cast = "w"
    },
    arrows = {
        left = "left",
        right = "right",
        jump = "return",
        cast = "up"
    }
}

-- Config file path
local CONFIG_FILE = "bots_config.txt"

-- Load configuration from file
function Config.load()
    -- Start with defaults
    for k, v in pairs(defaultConfig) do
        currentConfig[k] = v
    end
    
    -- Try to load from file
    if love.filesystem.getInfo(CONFIG_FILE) then
        local contents = love.filesystem.read(CONFIG_FILE)
        if contents then
            for line in contents:gmatch("[^\r\n]+") do
                local key, value = line:match("^([^=]+)=(.+)$")
                if key and value then
                    key = key:match("^%s*(.-)%s*$")  -- trim whitespace
                    value = value:match("^%s*(.-)%s*$")
                    currentConfig[key] = value
                end
            end
        end
    end
    
    return currentConfig
end

-- Save configuration to file
function Config.save()
    local lines = {}
    for k, v in pairs(currentConfig) do
        table.insert(lines, k .. "=" .. tostring(v))
    end
    local contents = table.concat(lines, "\n")
    love.filesystem.write(CONFIG_FILE, contents)
end

-- Get current control scheme name
function Config.getControlScheme()
    return currentConfig.controlScheme or "wasd"
end

-- Set control scheme
function Config.setControlScheme(scheme)
    if Config.CONTROL_SCHEMES[scheme] then
        currentConfig.controlScheme = scheme
        Config.save()
    end
end

-- Get controls for current scheme
function Config.getControls()
    local scheme = Config.getControlScheme()
    return Config.CONTROL_SCHEMES[scheme] or Config.CONTROL_SCHEMES.wasd
end

-- Get player count (2 or 3)
function Config.getPlayerCount()
    local val = tonumber(currentConfig.playerCount)
    if val == 2 then return 2 end
    return 3
end

-- Set player count
function Config.setPlayerCount(count)
    if count == 2 or count == 3 then
        currentConfig.playerCount = tostring(count)
        Config.save()
    end
end

-- Get server mode (dedicated relay)
function Config.getServerMode()
    return currentConfig.serverMode == "true"
end

-- Set server mode
function Config.setServerMode(enabled)
    currentConfig.serverMode = enabled and "true" or "false"
    Config.save()
end

return Config

