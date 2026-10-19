#!/usr/bin/env python3
"""Checks the foliage extraction against what the game showed live: tools/collected/foliage-seen.txt, written by
a discovery build (local data, not in the repository).

Usage: python3 tools/extract/verify.py [--game DIR] [--collected FILE]
Reports how many of the live instances the extraction has within 1 m (same mesh).
"""
import argparse
import collections
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import actors  # noqa: E402
import extract  # noqa: E402
import foliage  # noqa: E402
import props  # noqa: E402
import resolve  # noqa: E402
import schema  # noqa: E402

TOLERANCE = 100.0   # game units
TILE = 12600        # half a foliage tile: positions inside +-TILE of the origin are component-local, not world


class Index:
    """Points by key (class or mesh) on a 5 m grid, each matched at most once."""

    def __init__(self, points):
        self.grid = collections.defaultdict(list)
        for key, x, y, payload in points:
            self.grid[(key, int(x // 500), int(y // 500))].append([x, y, payload, False])

    def take(self, key, x, y):
        gx, gy = int(x // 500), int(y // 500)
        best = None
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                for p in self.grid.get((key, gx + dx, gy + dy), ()):
                    d = ((p[0] - x) ** 2 + (p[1] - y) ** 2) ** 0.5
                    if not p[3] and d <= TOLERANCE and (best is None or d < best[0]):
                        best = (d, p)
        if best:
            best[1][3] = True
            return best[1][2]
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--game', default=extract.DEFAULT_GAME)
    ap.add_argument('--collected', default=os.path.join(HERE, '..', 'collected', 'foliage-seen.txt'))
    args = ap.parse_args()
    w = resolve.World(args.game)
    native = schema.Schema(os.path.join(args.game, 'RSDragonwilds', 'Binaries', 'Win64',
                                        'RSDragonwilds-Win64-Shipping.exe'))
    layouts = props.Layouts(w, native)
    ax, fx = actors.Extractor(w, layouts), foliage.Extractor(w, layouts)
    placed, inst = [], []
    for name in actors.world_packages(w):
        placed.extend(r for r in ax.actors(name) if 'x' in r)
        inst.extend(fx.instances(name))
    bp = [r for r in placed if r['ref'][0] is not None]
    unread = sum(n for (c, _), n in ax.errors.items() if c not in native.classes)
    print('extracted: %d actors with a position (%d Blueprint), %d foliage instances; %d Blueprint actors unread'
          % (len(placed), len(bp), len(inst), unread))

    if os.path.exists(args.collected):
        seen = {}
        for line in open(args.collected):
            parts = line.split()
            if line.startswith('#') or len(parts) != 5 or parts[1] == '?':
                continue
            x, y = float(parts[2]), float(parts[3])
            if abs(x) <= TILE and abs(y) <= TILE:
                continue   # a component-local position the collector wrote by mistake
            seen[(parts[1], round(x / 50), round(y / 50))] = (parts[1], x, y)
        idx = Index((m, x, y, True) for m, x, y, _ in inst)
        found = sum(1 for m, x, y in seen.values() if idx.take(m, x, y))
        print('live foliage: %d of %d instances within 1 m (%.2f%%)' % (found, len(seen), 100.0 * found / max(len(seen), 1)))


if __name__ == '__main__':
    main()
