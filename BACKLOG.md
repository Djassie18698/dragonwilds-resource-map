# Backlog

Open items, roughly in order. What's done is in the git history.

## Zoom-step hitches on the world map (measured 2026-10-05)
In game the mod costs nothing while walking (no calls in steady state; 16 ms frames with the usual layers, about 1 ms
for minimap plus icons). The hitches are on the world map: each zoom step regroups by destroying every icon and making
new ones, about 1 ms per icon (frames of 170-400 ms with the usual layers, about 1 s with all on). MapIconComponent
has setters for everything a regroup changes (SetIconTexture, SetIconTooltipText, SetIconLabel, SetIconDrawColor,
SetIconZOrder, SetIconSize, SetIconInteractable), so a regroup could reuse the icons it has (move and restyle them)
and only make or destroy the difference.

## Loading screen pause
A pause in the last third of the first loading screen (about 15 s reported). Everything the mod does at world load
happens there (ClientRestart is during the loading screen): reading the save, the snapshot, the icons around you for
every layer that's on, the minimap. A pause there is acceptable; measure each step before changing anything.

## Tooltips: name on hover, details on click
Hovering an icon shows the game's tooltip big and centred on the icon, so multi-line lists cover the map.
- Hover: just the name of the thing ("Rune Pickaxe", "Iron rock", "Grave of Someone").
- Click: details: contents of chests and graves, despawn timer, counts, durability, who dropped it. Shown somewhere
  that doesn't cover the icons (likely a panel like the F7 menu). `MapIconComponent` has `bIconInteractable` and a
  `ReceiveClicked(bIsLeftMouseButton)` event.

## Not live
Ore nodes (no event for running out short of hooking every hit; they follow the save and their respawn time) and
storage built or removed (from the save).

## Layer candidates nobody decided on yet
Bloodwood sap (7, a choppable rock), buried journal items (3), thorny root (Irit) (68), quest dig sites.

## Decided
- Opening groups with a controller: mouse only. The game's icon widgets only take mouse clicks, and A is its "open
  marker menu" action; using A would still open the marker menu, and a free button would need checking every frame.
- Game icons that render under the fog (fog interaction 2) are in another canvas than ours (3, above the fog); ours
  draw under the game's own (z-order -10 to -5; the game uses 0 and up).
