-- HotReload -- a standalone dev hot-reload watcher. One in-game watcher reloads the Lua of every mod
-- that registers itself, with no game restart. Does nothing on its own.
--
-- Lives in shared/ because that is the only tier loaded in ALL three contexts: single-player, an MP
-- client, and a server process. client/ never loads on a server, server/ never loads at the menu.
--
-- HOW IT WORKS: ~once a second, for each registered mod whose `enabled` is true, it content-diffs that
-- mod's reload.trigger; when it changes it (re)loads every file in that mod's reload.filelist via
-- getModFileReader + loadstring -- which reloads BOTH already-loaded AND brand-new files (no restart),
-- unlike reloadLuaFile. getModFileReader takes a mod id, so ONE watcher reloads ANY enabled mod by id.

HotReload = HotReload or {}
HotReload.mods  = HotReload.mods  or {}   -- modId -> { enabled, trigger?, filelist? }  (written by each mod)
HotReload.state = HotReload.state or {}   -- modId -> { lastTrigger, deferred }         (owned by this file)

local WATCH_MS = 1000
local CLIENT_TIER = "media/lua/client/"

-- Asked per poll, never at file scope: during the boot pass the mode is not known yet and isServer()
-- reads false even on a run that is about to become a server.
local function isServerSide()
    local success, result = pcall(isServer)
    return success and result == true
end

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

-- Whole file as one string, or nil. Empty counts as nil: a writer that truncates before writing is
-- readable for an instant with zero lines, and treating that as a value fires one reload on the empty
-- read and a second on the real one.
local function fileValue(modId, path)
    local lines = readModFile(modId, path)
    if not lines then return nil end
    local value = table.concat(lines, "\n")
    if value == "" then return nil end
    return value
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

-- A server has no ISUI, so running a client file there throws on the first UI reference. The engine
-- never loads client/ on a server either, so skipping matches what a real boot does.
local function skipsOnThisSide(relPath, serverSide)
    return serverSide and relPath:sub(1, #CLIENT_TIER) == CLIENT_TIER
end

-- Say it in-game so a reload is visible without tabbing to the console. A server has no local player,
-- so there is nothing to say to and the print is the only report.
local function announce(modId, okCount, failCount, skipCount)
    pcall(function()
        local player = getSpecificPlayer(0)
        if not player then return end
        local message = ("[HotReload] %s: %d file(s)"):format(modId, okCount)
        if skipCount > 0 then message = message .. (" (%d skipped)"):format(skipCount) end
        if failCount > 0 then message = message .. (" -- %d FAILED"):format(failCount) end
        player:Say(message)
    end)
end

local nextPoll = 0
local function onTick()
    local now = nowMs()
    if now < nextPoll then return end
    nextPoll = now + WATCH_MS

    local serverSide = isServerSide()
    local side = serverSide and "server" or "client"

    -- A server reports isGamePaused() as TRUE from load onwards, so honouring it there would defer
    -- every reload forever. It cannot meaningfully pause anyway -- only a client can.
    local paused = false
    if not serverSide then pcall(function() paused = isGamePaused() end) end

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
                            print("[HotReload:" .. side .. "] " .. modId .. ": change detected -- deferred (game paused)")
                            state.deferred = true
                        end
                    else
                        state.deferred = false
                        state.lastTrigger = triggerValue
                        print("[HotReload:" .. side .. "] " .. modId .. ": trigger changed -- reloading")
                        local okCount, failCount, skipCount = 0, 0, 0
                        for _, relPath in ipairs(reloadList(modId, filelist)) do
                            if skipsOnThisSide(relPath, serverSide) then
                                skipCount = skipCount + 1
                                print("[HotReload:" .. side .. "] " .. modId .. "  skip " .. relPath .. "  -- client tier")
                            else
                                local success, err = loadOne(modId, relPath)
                                if success then okCount = okCount + 1 else failCount = failCount + 1 end
                                print("[HotReload:" .. side .. "] " .. modId .. "  " .. (success and "ok   " or "FAIL ") .. relPath
                                    .. (success and "" or "  -- " .. tostring(err)))
                            end
                        end
                        announce(modId, okCount, failCount, skipCount)
                    end
                end
            end
        end
    end
end

-- OnTickEvenPaused, not OnTick: on a server OnTick does not fire for ~40 s after load and the server
-- counts itself as paused, while OnTickEvenPaused runs throughout. On a client the two are the same
-- event rate, so nothing is lost by using one everywhere.
-- One handler watches ALL registered mods; reload-safe (stored on the global, swapped remove-then-add).
if HotReload._onTick then Events.OnTickEvenPaused.Remove(HotReload._onTick) end
HotReload._onTick = onTick
Events.OnTickEvenPaused.Add(onTick)
