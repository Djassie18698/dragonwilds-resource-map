# Resource Map for RuneScape: Dragonwilds

Shows everything in the world as icons on the world map and on a minimap: ores, rocks, plants, trees, runecrafting
spots, chests and more, plus your own dropped items, graves and storage. Press **F7** in game to choose what to show.

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod. It runs only on the player's own game, so nothing is needed
on a server.

Release builds: Nexus Mods, *Resource Map - Ores, Plants & Gatherables*.

## Features

- The whole map, not just around you: 67 layers in seven groups (my stuff, runecrafting, ores, rocks & minerals,
  plants & materials, trees, world)
- A round minimap in the top-right corner with the same icons (the game's own map, north up, following you)
- Icons are grouped per area, one icon per kind with the count underneath, so they never pile up; groups keep their
  size on screen as you zoom
- Groups around you unpack by themselves (within 100 m, on the minimap as you walk and when the map opens); left-click
  a group on the world map to unpack it, and it packs up again when you close the map
- Your own stuff, read from your save: dropped items, graves and storage chests, with what's inside in the tooltip
- Live: plants picked, rocks and trees destroyed and chests opened disappear and come back when they respawn; drops
  and pickups show as they happen
- Clickable F7 menu (mouse, or arrows and Enter) to turn each layer on or off, plus icon size, group distance, minimap
  and range; saved in `settings.txt`
- Uses the game's own item icons; the game's own icons (lodestones, markers, players) stay on top

Every icon costs the game's map a little time each frame, so with every layer on it gets slow; a handful of layers is
smooth. Everything except "My stuff" starts off.

## Install (players)

1. Install UE4SS for RuneScape: Dragonwilds. On Linux/Steam Deck the game's Steam launch options must start with
   `WINEDLLOVERRIDES="dwmapi=n,b"`.
2. Copy the `ResourceMarkers` folder to `<game>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\`.
3. Make sure `ResourceMarkers\enabled.txt` exists, start the game, load a world, press F7.

Upgrading from 1.x: replace the contents of the `ResourceMarkers` folder but keep your `settings.txt`: your resource
choices carry over. The range and "hide mined" settings are gone (the map covers the whole world and follows what's
used up by itself), and so is the Mod Menu page: settings are in the F7 menu and `settings.txt`. Restart the game after
updating (don't use UE4SS hot reload: icons would be added twice).

## How it works

- Where things are comes with the mod (`ResourceMarkers/data/`): every placed resource, plant, chest and spot, their
  respawn times and the item names, read from the game's files. It's the same for every player.
- When a world loads, the host (or a single player) has its save on their own PC: the mod reads it, never writes it,
  for your drops, graves, storage and what's used up. A guest has no save of the host's world: the map shows the world
  data, graves, and what happens while you play.
- From then on it follows the game's own events. Icon changes happen at the next frame, never inside the map's update.

## Settings (`settings.txt`)

`enabled`, `icon_size`, `group_m` (group distance), `minimap`, `minimap_m` (range), `counts`, `clickable` and
`cat.<id>` per layer are in the F7 menu. Only in the file: `menu_key`, `minimap_px` (minimap size on screen),
`minimap_frames` (it updates once every this many frames, 5) and `world_save` (a save to read instead of the world's
own, by its name in `SaveGames`).

UE4SS.log gets one `[ResourceMarkers]` line when the mod loads, and otherwise only warnings and errors.

## Code layout

```
ResourceMarkers/              What players copy: the release build
  enabled.txt                 UE4SS loads the mod when this file exists
  data/                       world.lua, foliage.lua, items.lua: read from the game by tools/extract
  Scripts/
    main.lua                  Entry point: world ready, map hooks, live events, F7 key
    Modules/
      categories.lua          The layers: how each is recognised, its group, label, icon and default on/off
      layers.lua              Icons from the snapshot: grouping, culling to the map's view, unpacking groups
      cluster.lua             Groups things per area
      icons.lua               The map icons (MinimapPlugin MapIconComponent), on one actor
      snapshot.lua            The world data merged with the save's state
      live.lua                Live state from the game's events and the in-game clock
      minimap.lua             The minimap: a second copy of the game's map widget in the HUD
      saves.lua, spud.lua     The save reader (the game saves with SPUD)
      menu.lua                The F7 menu (UMG widgets built from Lua, mouse support)
      settings.lua            Loads/saves settings.txt
      items.lua, util.lua     Item names; small helpers (logging, safe calls, local player)
tools/extract/                Rebuilds data/ from the installed game (Python 3 + lua5.4); run after game updates
tools/debug.lua               Debug builds only: verbose log lines, F9 switches map layers off one at a time
tools/spud-dump.lua           Lists a save's classes and properties
tests/                        Offline tests (run.sh): settings, the save reader, the whole mod against a fake UE4SS
install.sh                    Linux/Steam: tests, install, status, logs, extract, debug builds
```

## Notes for contributors

- **Game thread only, no timers.** Everything reacts to the game's own events and its map's updates; hooks only note
  what happened, and the work runs at the next engine tick (`ExecuteInGameThread`).
- **Keep hooks minimal.** Inside a `RegisterHook` callback only copy the data you need.
- **Never read from a null object**: check `IsValid` first. UE4SS crashes on it, past any `pcall`.
- **Check that an engine function exists** in the game before relying on it: the offline tests' fake UE4SS accepts
  any call.
- **Debug code**: lines starting with `--DEBUG ` are comments in the release build; `./install.sh debug` installs a
  copy with them on (plus `tools/debug.lua`), and `./install.sh` puts the release build back.
- After a game update: `./install.sh extract` (or `python3 tools/extract/extract.py --game <game folder>`), then
  `tests/run.sh`.
- `settings.txt` is per player and is not part of the repository; nor is the test save (`tests/fixtures/`, it holds
  players' names).

## Credits

Version 1 by Djassie18698: the F7 menu, the native map icon setup and the resource categories this version builds on.
Save format: [SPUD](https://github.com/sinbad/SPUD). Game assets © Jagex.

## License

GPL-3.0. See [LICENSE](LICENSE).

Copyright (C) 2026 Djassie18698 and contributors.
