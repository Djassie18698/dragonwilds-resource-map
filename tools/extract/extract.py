#!/usr/bin/env python3
"""Builds the mod's data from the installed game's files: data/world.lua, data/foliage.lua and data/items.lua.

Reads the game's IoStore container and its exe (the native class layouts) and takes
  - every placed actor of the world's persistent level and streaming cells (class, class chain, position, vent type),
  - every interactable foliage instance (mesh, world position),
  - how long resources and chests take to come back (the game's respawn tables),
  - every item (name, kind, full durability per persistence id).
Placed things and foliage go through tools/extract/layers.lua, so the layer rules stay in Scripts/Modules/categories.lua;
items are written here. All three files are stamped with the game build.

Usage: python3 tools/extract/extract.py [--game DIR] [--keep FILE]
  --game  the game folder (default: Steam's RSDragonwilds)
  --keep  also keep what was read (before the layer rules) in FILE
Needs Python 3 (no packages) and lua5.4. Takes about half a minute.
"""
import argparse
import os
import re
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
DATA = os.path.join(ROOT, 'ResourceMarkers', 'data')
sys.path.insert(0, HERE)

import actors  # noqa: E402
import foliage  # noqa: E402
import items  # noqa: E402
import props  # noqa: E402
import resolve  # noqa: E402
import respawn  # noqa: E402
import schema  # noqa: E402

DEFAULT_GAME = os.path.expanduser('~/.local/share/Steam/steamapps/common/RSDragonwilds')
APP_ID = '1374490'
# Classes whose respawn time is worth looking up: resources (respawn components) and chests.
RESPAWNING = ('WorldActor', 'WorldChest', 'AnimaVent', 'FishingNodeV2', 'RuneEssenceGeyser')


class Game:
    """The installed game, opened once: containers, script objects, native and Blueprint class layouts."""

    def __init__(self, game_dir):
        exe = os.path.join(game_dir, 'RSDragonwilds', 'Binaries', 'Win64', 'RSDragonwilds-Win64-Shipping.exe')
        self.dir = game_dir
        self.world = resolve.World(game_dir)
        self.native = schema.Schema(exe)
        self.layouts = props.Layouts(self.world, self.native)
        self.actors = actors.Extractor(self.world, self.layouts)
        self.chain = self.actors.chain

    def stamp(self):
        """What identifies the game build: the main container's size (changes with any content patch) and Steam's
        build id when the app manifest is next to the game folder."""
        stamp = {'utoc_size': os.path.getsize(self.world.game.utoc_path)}
        manifest = os.path.join(os.path.dirname(os.path.dirname(self.dir)), 'appmanifest_%s.acf' % APP_ID)
        if os.path.exists(manifest):
            m = re.search(r'"buildid"\s+"(\d+)"', open(manifest, encoding='utf-8', errors='replace').read())
            if m:
                stamp['buildid'] = m.group(1)
        return stamp


def read_world(game):
    """Placed Blueprint actors, the chains of every Blueprint class, foliage instances and respawn times."""
    fx = foliage.Extractor(game.world, game.layouts)
    placed, chains, instances = [], {}, []
    for name in actors.world_packages(game.world):
        for rec in game.actors.actors(name):
            # Placed gameplay things are Blueprint actors; engine actors (meshes, lights, volumes) are left out.
            if 'x' in rec and rec['ref'][0] is not None:
                placed.append(rec)
                chains.setdefault(rec['class'], game.chain(rec['ref']))
        instances.extend(fx.instances(name))
    # Every Blueprint class, placed or not: things the game only spawns (a harvested plant) need their layer too.
    refs = {}
    for ref in game.actors.blueprint_classes():
        refs[ref[1]] = ref
        if ref[1] not in chains and len(game.chain(ref)) > 1:
            chains[ref[1]] = game.chain(ref)
    rs = respawn.Respawn(game.world, game.layouts, game.chain)
    respawns = {}
    for cls, chain in chains.items():
        if cls in refs and any(base in chain for base in RESPAWNING):
            s = rs.of(refs[cls])
            if s:
                respawns[cls] = s
    # Engine actors that don't decode don't matter; Blueprint actors and foliage do.
    problems = [(k, n) for k, n in game.actors.errors.items() if k[0] not in game.native.classes]
    problems += list(fx.errors.items())
    return placed, chains, instances, respawns, problems


def lua_string(s):
    out = s.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r')
    return '"' + ''.join(c if c >= ' ' else '\\%03d' % ord(c) for c in out) + '"'


def lua_table(d):
    return '{ ' + ', '.join('%s = %s' % (k, lua_string(v) if isinstance(v, str) else v) for k, v in sorted(d.items())) + ' }'


def write_extracted(path, stamp, placed, chains, instances, respawns):
    """What was read, for layers.lua (see its header for the format)."""
    with open(path, 'w', encoding='utf-8') as f:
        f.write('-- Read from the game by tools/extract/extract.py, before the layer rules.\n')
        f.write('return {\n  game = %s,\n  actors = {\n' % lua_table(stamp))
        for r in placed:
            extra = ',%s' % lua_string(r['extra']) if r.get('extra') else ''
            f.write('    {%s,%d,%d,%d%s},\n' % (lua_string(r['class']), round(r['x']), round(r['y']), round(r['z']), extra))
        f.write('  },\n  classes = {\n')
        for cls, chain in sorted(chains.items()):
            f.write('    [%s] = {%s},\n' % (lua_string(cls), ','.join(lua_string(c) for c in chain)))
        f.write('  },\n  respawn = {\n')
        for cls, s in sorted(respawns.items()):
            f.write('    [%s] = %d,\n' % (lua_string(cls), s))
        f.write('  },\n  foliage = {\n')
        for mesh, x, y, z in instances:
            f.write('    %s,%d,%d,%d,\n' % (lua_string(mesh), round(x), round(y), round(z)))
        f.write('  },\n}\n')


def write_items(path, stamp, catalog):
    with open(path, 'w', encoding='utf-8') as f:
        f.write('-- Generated by tools/extract from the game\'s item assets. Do not edit.\n')
        f.write('-- items[persistence id] = { name, kind ("Fuel", "Seed" or nil), full durability or nil }\n')
        f.write('return {\n  game = %s,\n  items = {\n' % lua_table(stamp))
        for pid, (name, kind, full) in sorted(catalog.items(), key=lambda kv: (kv[1][0].lower(), kv[0])):
            fields = [lua_string(name), lua_string(kind) if kind else 'nil'] + ([str(full)] if full else [])
            while fields[-1] == 'nil':
                fields.pop()
            f.write('    [%s] = { %s },\n' % (lua_string(pid), ', '.join(fields)))
        f.write('  },\n}\n')


def main():
    ap = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    ap.add_argument('--game', default=DEFAULT_GAME)
    ap.add_argument('--keep')
    args = ap.parse_args()
    t0 = time.time()
    game = Game(args.game)
    stamp = game.stamp()
    print('game %s: %d native classes, %d structs' % (lua_table(stamp), len(game.native.classes),
                                                       len(game.native.structs)))

    placed, chains, instances, respawns, problems = read_world(game)
    item_reader = items.Items(game.world, game.layouts, game.chain)
    catalog = item_reader.all()
    problems += list(item_reader.errors.items())
    print('read %d placed actors, %d classes, %d foliage instances, %d respawn times, %d items in %.0f s' %
          (len(placed), len(chains), len(instances), len(respawns), len(catalog), time.time() - t0))
    if problems:
        print('not readable (left out): %d' % sum(n for _, n in problems))
        for (cls, why), n in sorted(problems, key=lambda kv: -kv[1])[:6]:
            print('  %5d %s: %s' % (n, cls, why))

    extracted = args.keep or os.path.join(tempfile.mkdtemp(prefix='resourcemarkers-'), 'extracted.lua')
    write_extracted(extracted, stamp, placed, chains, instances, respawns)
    sys.stdout.flush()
    subprocess.run(['lua5.4', os.path.join(HERE, 'layers.lua'), extracted, DATA], check=True)
    write_items(os.path.join(DATA, 'items.lua'), stamp, catalog)
    print('items.lua: %d items' % len(catalog))
    print('wrote data/world.lua, data/foliage.lua and data/items.lua in %.0f s' % (time.time() - t0))


if __name__ == '__main__':
    main()
