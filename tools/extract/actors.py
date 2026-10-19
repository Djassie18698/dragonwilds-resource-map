"""Placed actors of the world: class, class chain, position (the root component's), vent type."""
import collections
import struct

import props as P
import zen

WORLD_CELLS = '/Game/Maps/World/L_World/_Generated_/'
PERSISTENT = '/Game/Maps/World/L_World'


def world_packages(world):
    """The world's packages: the persistent level (always loaded) and its streaming cells."""
    cells = sorted(n for n in world.game.packages if n.startswith(WORLD_CELLS))
    return [PERSISTENT] + cells


class Extractor:
    def __init__(self, world, layouts):
        self.world, self.layouts = world, layouts
        self.errors = collections.Counter()      # (class, reason) -> count
        self._chains = {}

    def chain(self, ref):
        """Class names from the class up to Object: a Blueprint class's parent from its package's export map, a
        native class's from the exe."""
        if ref not in self._chains:
            out, r = [], ref
            while r and len(out) < 32:
                out.append(r[1])
                if r[0] is None:
                    sup = self.layouts.native.classes.get(r[1], {}).get('super')
                    r = (None, sup) if sup else None
                else:
                    pkg = self.world.package(r[0])
                    e = next((x for x in pkg.exports if x.name == r[1]), None) if pkg else None
                    s = self.world.resolve(pkg, e.super) if e else None
                    r = (s[0], s[1]) if s and s[1] else None
            self._chains[ref] = out
        return self._chains[ref]

    def blueprint_classes(self):
        """(package, class) of every Blueprint class named like one (BP_*), placed or not: things the game only
        spawns at runtime (a harvested plant, a geyser's essence rock) still need their layer."""
        for name in self.world.game.packages:
            base = name.rsplit('/', 1)[1]
            if base.startswith(('BP_', 'BPP_')):
                yield (name, base + '_C')

    def actors(self, pkg_name):
        data = self.world.game.package_bytes(pkg_name)
        if data is None:
            return
        pkg = zen.Package(data)
        level = next((e.index for e in pkg.exports if e.name == 'PersistentLevel'), None)
        if level is None:
            return
        dec = P.Decoder(self.layouts, pkg)
        for e in pkg.exports:
            if e.outer != level:
                continue
            cls = self.world.resolve(pkg, e.cls)
            if not cls or not cls[1]:
                continue
            ref = (cls[0], cls[1])
            if 'Actor' not in self.chain(ref):
                continue   # the level's other objects (its BSP model, settings objects)
            rec = {'class': cls[1], 'ref': ref, 'name': e.name, 'package': pkg_name}
            try:
                values, _ = dec.block(pkg.export_data(e), 0, ref, want={'RootComponent', 'AnimaVentData'})
            except (P.Unsupported, struct.error, IndexError, KeyError) as err:
                self.errors[(cls[1], 'actor: ' + str(err)[:80])] += 1
                yield rec
                continue
            vent = values.get('AnimaVentData')
            if vent:
                target = self.world.resolve_index(pkg, vent)
                rec['extra'] = target[1] if target else None
            root = values.get('RootComponent')
            if root and not 0 < root <= len(pkg.exports):
                self.errors[(cls[1], 'actor: RootComponent %d is not an export (misread)' % root)] += 1
                yield rec
                continue
            comp = pkg.exports[root - 1] if root else None
            if comp is None:   # nothing to place (level script, settings actors)
                yield rec
                continue
            ccls = self.world.resolve(pkg, comp.cls)
            try:
                cv, _ = dec.block(pkg.export_data(comp), 0, (ccls[0], ccls[1]),
                                  want={'RelativeLocation', 'AttachParent'})
            except (P.Unsupported, struct.error, IndexError, KeyError) as err:
                self.errors[(cls[1], 'root %s: %s' % (ccls[1], str(err)[:80]))] += 1
                yield rec
                continue
            loc = cv.get('RelativeLocation', (0.0, 0.0, 0.0))
            rec['x'], rec['y'], rec['z'] = loc
            if cv.get('AttachParent'):
                rec['attached'] = True
            yield rec
