-- config.lua
-- Configuration system for B.O.T.S
-- Handles saving and loading player preferences

local Config = {}

-- Default configuration
local defaultConfig = {
    controlScheme = "wasd",  -- "wasd" or "arrows"
    playerCount = "3",       -- "2" or "3" (or up to "12")
    serverMode = "false",    -- "true" or "false" (dedicated server / relay mode)
    aimAssist = "true",      -- "true" or "false" (auto-aim at nearest enemy)
    demoInvulnerable = "false", -- "true" or "false" (invulnerable in demo mode)
    musicMuted = "false",    -- "true" or "false" (background music muted)
    damageNumbers = "true",  -- "true" or "false" (show floating damage numbers)
    playerName = ""          -- Player's display name (empty = "Player N")
}

-- IP history (stored separately, not in defaultConfig)
local ipHistory = {}

-- Current configuration
local currentConfig = {}

-- Control scheme presets
Config.CONTROL_SCHEMES = {
    wasd = {
        left = "a",
        right = "d",
        jump = "space",
        cast = "w",
        special = "e"       -- secondary ability
    },
    arrows = {
        left = "left",
        right = "right",
        jump = "return",
        cast = "up",
        special = "down"    -- secondary ability
    }
}

-- Config file paths
local CONFIG_FILE = "bots_config.txt"
local IP_HISTORY_FILE = "bots_ip_history.txt"
local MAX_IP_HISTORY = 10  -- Maximum number of IPs to remember

-- Load configuration from file
function Config.load()
    -- Start with defaults
    for k, v in pairs(defaultConfig) do
        currentConfig[k] = v
    end

    -- Try to load config from file
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

    -- Load IP history
    ipHistory = {}
    if love.filesystem.getInfo(IP_HISTORY_FILE) then
        local contents = love.filesystem.read(IP_HISTORY_FILE)
        if contents then
            for line in contents:gmatch("[^\r\n]+") do
                local ip = line:match("^%s*(.-)%s*$")  -- trim whitespace
                if ip and #ip > 0 then
                    table.insert(ipHistory, ip)
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

-- Get player count (2-12)
function Config.getPlayerCount()
    local val = tonumber(currentConfig.playerCount)
    if val and val >= 2 and val <= 12 then return val end
    return 3  -- default
end

-- Set player count (2-12)
function Config.setPlayerCount(count)
    if count >= 2 and count <= 12 then
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

-- Get aim assist setting
function Config.getAimAssist()
    return currentConfig.aimAssist ~= "false"  -- default true
end

-- Set aim assist
function Config.setAimAssist(enabled)
    currentConfig.aimAssist = enabled and "true" or "false"
    Config.save()
end

-- Get demo invulnerability setting
function Config.getDemoInvulnerable()
    return currentConfig.demoInvulnerable == "true"
end

-- Set demo invulnerability
function Config.setDemoInvulnerable(enabled)
    currentConfig.demoInvulnerable = enabled and "true" or "false"
    Config.save()
end

-- Get music muted setting
function Config.getMusicMuted()
    return currentConfig.musicMuted == "true"
end

-- Set music muted
function Config.setMusicMuted(muted)
    currentConfig.musicMuted = muted and "true" or "false"
    Config.save()
end

-- Get damage numbers setting
function Config.getDamageNumbers()
    return currentConfig.damageNumbers ~= "false"  -- default true
end

-- Set damage numbers
function Config.setDamageNumbers(enabled)
    currentConfig.damageNumbers = enabled and "true" or "false"
    Config.save()
end

-- Get IP history (most recent first)
function Config.getIPHistory()
    return ipHistory
end

-- Add IP to history (moves to front if already exists)
function Config.addIPToHistory(ip)
    if not ip or #ip == 0 then return end

    -- Remove if already exists
    for i = #ipHistory, 1, -1 do
        if ipHistory[i] == ip then
            table.remove(ipHistory, i)
        end
    end

    -- Add to front
    table.insert(ipHistory, 1, ip)

    -- Trim to max size
    while #ipHistory > MAX_IP_HISTORY do
        table.remove(ipHistory)
    end

    -- Save to file
    local contents = table.concat(ipHistory, "\n")
    love.filesystem.write(IP_HISTORY_FILE, contents)
end

-- Get player name
function Config.getPlayerName()
    local name = currentConfig.playerName
    if name and #name > 0 then
        return name
    end
    return nil  -- nil means use default "Player N"
end

-- Set player name
function Config.setPlayerName(name)
    currentConfig.playerName = name or ""
    Config.save()
end

return Config

