# [Dev] Hot Reload Mods

A **developer tool** for Project Zomboid **Build 42**. A single in-game watcher hot-reloads the Lua of any mod that opts in, with **no game restart**. It does nothing on its own; enable it alongside the mod(s) you're actively developing.

📦 **[Steam Workshop page](https://steamcommunity.com/sharedfiles/filedetails/?id=3764185018)**

## What it does

About once a second (while the game is unpaused) it watches a small *trigger* file in each opted-in mod. When you change that file from **outside** the game (your editor or a terminal), it re-runs that mod's listed Lua files via `getModFileReader` + `loadstring`, reloading **both already-loaded and brand-new files**, which the engine's own `reloadLuaFile` can't do. One watcher handles every enabled mod by id.

## Why (vs the built-in options)

Project Zomboid already has ways to reload Lua, but they're all **manual**:

- **F11 "Experimental Mod Reload"** (`reloadLuaFile`): one file at a time, selected and clicked in-game, requires `-debug`.
- **"Reset Lua" buttons**: a full Lua-state reset, manual, mostly on the title screen.

This mod is different:

- **Reloads brand-new files, not just already-loaded ones.** `reloadLuaFile` (and F11 on top of it) can *only* reload files that existed at boot; a `.lua` file you create mid-session throws `FileNotFoundException` because its path mapping is fixed at startup. This watcher loads new files too, so you can add files while the game runs and never restart.
- **Automatic.** A file bump from your editor fires the reload; no in-game clicking.
- **Whole filelist per mod.** Reloads every file you list in one go, in load order.
- **Live in a running save.** No title-screen reset, no restart.

## How to use it (mod authors)

1. Enable this mod in your save alongside the mod you're developing.
2. In your mod's Lua, register it (3 lines, and a harmless no-op when this mod isn't enabled, since nothing reads the table):

   ```lua
   HotReload = HotReload or {}
   HotReload.mods = HotReload.mods or {}
   HotReload.mods["YourModId"] = { enabled = YourMod.isDebug }  -- key = your mod.info id
   ```

   `enabled` is checked on every poll: pass your debug flag as a **bool or a function**, or omit it to fall back to the game's `-debug`. Ship release builds with debug **off** so this never runs for players.

3. Add two files to your mod:
   - `media/reload.trigger`: any value; you bump it to fire a reload.
   - `media/reload.filelist`: mod-relative Lua paths to reload, one per line in load order (blank lines and `#` comments are ignored):

     ```
     # shared files load first, then client
     media/lua/shared/MyMod_Util.lua
     media/lua/client/MyMod_Main.lua
     ```

4. Make the files you list **reload-safe.** Every file is re-run on each reload, so any file that registers an event handler must store the handler on a global and remove-then-add, or each reload stacks a duplicate (double tick/render loops). Files that only define functions or data need nothing:

   ```lua
   -- instead of a bare Events.OnTick.Add(onTick):
   if MyMod._onTick then Events.OnTick.Remove(MyMod._onTick) end
   MyMod._onTick = onTick
   Events.OnTick.Add(MyMod._onTick)
   ```

5. To reload, write a **new** value into your mod's `media/reload.trigger` from outside the game (save it from your editor, or `echo` a fresh value). Watch the console (or the in-game toast) for the `[HotReload] YourModId ... ok` confirmation.

## Notes & requirements

- **Lua only.** It re-runs `.lua` files (via `loadstring`); it does **not** reload assets: item icons/textures, item/recipe scripts (`.txt`), models, animations, or translations. Those still need a full game reload/restart.
- Reloads only fire while the game is **unpaused**. Changes made while paused are detected and deferred until you unpause.
- The trigger must actually **change value**: writing the same value again does nothing. Bump it (e.g. increment a number).
- **Build 42 only.** This is a dev tool, not meant for normal play; safe to leave disabled when you're not modding.
