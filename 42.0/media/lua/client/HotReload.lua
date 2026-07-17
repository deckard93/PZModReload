-- HotReload -- a standalone dev hot-reload watcher. A single in-game watcher reloads the Lua of every
-- mod that registers itself, with no game restart. Does nothing on its own.
--
-- HOW IT WORKS: ~once a second, while UNPAUSED, for each registered mod whose `enabled` is true, it
-- content-diffs that mod's reload.trigger; when it changes it (re)loads every file in that mod's
-- reload.filelist via getModFileReader + loadstring -- which reloads BOTH already-loaded AND brand-new
-- files (no restart), unlike reloadLuaFile. getModFileReader takes a mod id, so ONE watcher reads and
-- reloads ANY enabled mod's files by id.

HotReload = HotReload or {}
HotReload.mods  = HotReload.mods  or {}   -- modId -> { enabled, trigger?, filelist? }  (written by each mod)
HotReload.state = HotReload.state or {}   -- modId -> { lastTrigger, deferred }         (owned by this file)

local WATCH_MS = 1000

local function nowMs()
    local success, timestamp = pcall(getTimestampMs)
    return (success and timestamp) or 0
end

local function isEnabled(config)
    local enabled = config.enabled
    if type(enabled) == "function" then local success, result = pcall(enabled); return success and result == true end
    if enabled ~= nil then return enabled == true end
    local success, gameDebug = pcall(isDebugEnabled)   -- default (omitted): the game's own -debug flag
    return success and gameDebug == true
end

local function readModFile(modId, path)          -- the file's lines (table) or nil
    local success, reader = pcall(getModFileReader, modId, path, false)
    if not success or not reader then return nil end
    local lines = {}
    while true do
        local line = reader:readLine()
        if line == nil then break end
        lines[#lines + 1] = line
    end
    pcall(function() reader:close() end)
    return lines
end

local function fileValue(modId, path)            -- whole file as one string, or nil
    local lines = readModFile(modId, path)
    return lines and table.concat(lines, "\n") or nil
end

local function reloadList(modId, path)           -- parsed filelist (blank lines / '#' comments skipped)
    local files = {}
    for _, rawLine in ipairs(readModFile(modId, path) or {}) do
        local trimmed = rawLine:gsub("^%s+", ""):gsub("%s+$", "")
        if trimmed ~= "" and trimmed:sub(1, 1) ~= "#" then files[#files + 1] = trimmed end
    end
    return files
end

local function loadOne(modId, relPath)           -- success, err ; loads NEW and already-loaded files alike
    local lines = readModFile(modId, relPath)
    if not lines then return false, "cannot read " .. relPath end
    local chunk, err = loadstring(table.concat(lines, "\n"), "@" .. relPath)
    if not chunk then return false, err end
    return pcall(chunk)
end

local nextPoll = 0
local function onTick()
    local now = nowMs()
    if now < nextPoll then return end
    nextPoll = now + WATCH_MS

    local paused = false; pcall(function() paused = isGamePaused() end)

    for modId, config in pairs(HotReload.mods) do
        if type(config) == "table" and isEnabled(config) then
            local trigger  = config.trigger  or "media/reload.trigger"
            local filelist = config.filelist or "media/reload.filelist"
            local state = HotReload.state[modId]; if not state then state = {}; HotReload.state[modId] = state end
            local triggerValue = fileValue(modId, trigger)
            if triggerValue ~= nil then
                if state.lastTrigger == nil then
                    state.lastTrigger = triggerValue           -- baseline: first successful read (no reload)
                elseif triggerValue ~= state.lastTrigger then
                    if paused then
                        if not state.deferred then
                            print("[HotReload] " .. modId .. ": change detected -- deferred (game paused)")
                            state.deferred = true
                        end
                    else
                        state.deferred = false
                        state.lastTrigger = triggerValue
                        print("[HotReload] " .. modId .. ": trigger changed -- reloading")
                        local okCount, failCount = 0, 0
                        for _, relPath in ipairs(reloadList(modId, filelist)) do
                            local success, err = loadOne(modId, relPath)
                            if success then okCount = okCount + 1 else failCount = failCount + 1 end
                            print("[HotReload] " .. modId .. "  " .. (success and "ok   " or "FAIL ") .. relPath
                                .. (success and "" or "  -- " .. tostring(err)))
                        end
                        -- announce in-game so the reload is visible without tabbing to the console
                        pcall(function()
                            local player = getSpecificPlayer(0)
                            if player then
                                local message = ("[HotReload] %s: %d file(s)"):format(modId, okCount)
                                if failCount > 0 then message = message .. (" -- %d FAILED"):format(failCount) end
                                player:Say(message)
                            end
                        end)
                    end
                end
            end
        end
    end
end

-- One handler watches ALL registered mods; reload-safe (stored on the global, swapped remove-then-add).
if HotReload._onTick then Events.OnTick.Remove(HotReload._onTick) end
HotReload._onTick = onTick
Events.OnTick.Add(onTick)
