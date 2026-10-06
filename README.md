# Resource Map for RuneScape: Dragonwilds

Shows ores, rocks, plants and other gatherables as icons on the world map
(and on the MiniMap mod's minimap). Press **F7** in game to choose which
resources to show.

A [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS) Lua mod. It runs only on the
player's own game, so nothing is needed on a server.

Release builds: Nexus Mods, *Resource Map - Ores, Plants & Gatherables*.

## Features

- 42 resources in three groups: ores, rocks & minerals, plants & materials
- Clickable F7 menu (mouse) to turn each resource on or off; saved in `settings.txt`
- Uses the game's own item icons
- Hides mined / harvested spots until they respawn (optional)
- Range (50-1000 m) and icon size (12-48) settings
- All settings also editable in game with Mod Menu (Esc > MODS)

## Install (players)

1. Install UE4SS for RuneScape: Dragonwilds.
2. Copy the `ResourceMarkers` folder to
   `<game>\RSDragonwilds\Binaries\Win64\ue4ss\Mods\`.
3. Make sure `ResourceMarkers\enabled.txt` exists, start the game, press F7.

## Code layout

```
ResourceMarkers/
  enabled.txt                 UE4SS loads the mod when this file exists
  modmenu.json                Settings page for the Mod Menu mod
  Scripts/
    main.lua                  Entry point: scan timer, key binding, Mod Menu polling
    Modules/
      categories.lua          The resources: how each is recognised, its group,
                              label, icon and default on/off
      markers.lua             Finds resource actors near the player and keeps one
                              map icon (MinimapPlugin MapIconComponent) per resource
      menu.lua                The F7 menu (UMG widgets built from Lua, mouse support)
      settings.lua            Loads/saves settings.txt
      modmenu.lua             Optional Mod Menu bridge (shared variables) and the
                              game-thread timer helper
      util.lua                Small helpers (logging, safe calls, local player)
```

## Notes for contributors

- **Game thread only.** Use `LoopInGameThreadWithDelay` /
  `ExecuteInGameThread` for anything that touches game objects. `LoopAsync`
  and `ExecuteWithDelay` run Lua on another thread and crash the game when it
  touches the engine at the same time (see `MM.every` in `modmenu.lua`).
- **Keep hooks minimal.** Inside a `RegisterHook` callback only copy the data
  you need and defer the real work with `ExecuteInGameThread`.
- **Wrap engine calls in `pcall`** (`Util.safe`): objects can become invalid
  between frames, e.g. while a world loads.
- `settings.txt` is per player and is not part of the repository.
- Test with UE4SS's console open (`UE4SS-settings.ini`: `ConsoleEnabled = 1`);
  the mod logs as `[ResourceMarkers]` in `UE4SS.log`.

## License

GPL-3.0. See [LICENSE](LICENSE).

Copyright (C) 2026 Djassie18698 and contributors.
