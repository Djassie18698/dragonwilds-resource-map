"""How long things take to come back, per class, from the game's data tables.

Resources: the class's ResourceRespawnComponent template (in its Blueprint or a parent's) names a row of
DT_ResourceRespawnSettings (SpawnSettings.ResourceRespawnSettingsRowHandle); the row holds the duration.
Chests: the class's default object names a row of DT_LootChest_RespawnProfiles (ChestRespawnProfile).
Durations are in-game time (every row in this game says RespawnTimeIsInGameTime).
"""
import struct

import props as P

RESOURCE_TABLE = '/Game/Gameplay/RespawnProfiles/DT_ResourceRespawnSettings'
CHEST_TABLE = '/Game/Gameplay/Items/LootDropTables/DT_LootChest_RespawnProfiles'


def seconds(duration):
    d = duration or {}
    return ((d.get('Days', 0) * 24 + d.get('Hours', 0)) * 60 + d.get('Minutes', 0)) * 60 + d.get('Seconds', 0)


class Respawn:
    def __init__(self, world, layouts, chain):
        self.world, self.layouts, self.chain = world, layouts, chain   # chain(ref) -> class names up to Object
        self.resource_rows = self._table(RESOURCE_TABLE, lambda v: seconds(v.get('RespawnTime', {}).get('RespawnDuration')))
        self.chest_rows = self._table(CHEST_TABLE, lambda v: seconds(v.get('InGameRespawnTime')))
        self._row = {}

    def _table(self, name, duration):
        """Row name -> seconds of a DataTable: its object properties, the object guid flag, then the rows."""
        pkg = self.world.package(name)
        e = pkg.exports[0]
        c = self.world.resolve(pkg, e.cls)
        b = pkg.export_data(e)
        dec = P.Decoder(self.layouts, pkg)
        v, o = dec.block(b, 0, (c[0], c[1]))
        row_struct = self.world.resolve_index(pkg, v['RowStruct'])
        o += 4
        n, = struct.unpack_from('<i', b, o)
        o += 4
        rows = {}
        for _ in range(n):
            row = pkg.fname(b, o)
            rv, o = dec.block(b, o + 8, (row_struct[0], row_struct[1]))
            rows[row] = duration(rv)
        return rows

    def _blueprints(self, ref):
        """The Blueprint classes from ref up to the first native one."""
        out = []
        while ref and ref[0] and len(out) < 32:
            out.append(ref)
            pkg = self.world.package(ref[0])
            e = next((x for x in pkg.exports if x.name == ref[1]), None) if pkg else None
            s = self.world.resolve(pkg, e.super) if e else None
            ref = (s[0], s[1]) if s and s[1] else None
        return out

    def _own_row(self, ref):
        """The respawn row this Blueprint itself sets (its respawn component template or chest profile), or None."""
        if ref in self._row:
            return self._row[ref]
        self._row[ref] = None
        pkg = self.world.package(ref[0])
        dec = P.Decoder(self.layouts, pkg)
        for e in pkg.exports:
            c = self.world.resolve(pkg, e.cls)
            if not c or not c[1]:
                continue
            names = self.chain((c[0], c[1]))
            try:
                if 'ResourceRespawnComponent' in names:
                    v, _ = dec.block(pkg.export_data(e), 0, (c[0], c[1]), want={'SpawnSettings'})
                    row = ((v.get('SpawnSettings') or {}).get('ResourceRespawnSettingsRowHandle') or {}).get('RowName')
                    if row in self.resource_rows:
                        self._row[ref] = self.resource_rows[row]
                        break
                elif e.name.startswith('Default__') and 'WorldChest' in names:
                    v, _ = dec.block(pkg.export_data(e), 0, (c[0], c[1]), want={'ChestRespawnProfile'})
                    row = (v.get('ChestRespawnProfile') or {}).get('RowName')
                    if row in self.chest_rows:
                        self._row[ref] = self.chest_rows[row]
                        break
            except (P.Unsupported, struct.error, IndexError, KeyError):
                continue
        return self._row[ref]

    def of(self, ref):
        """Seconds of in-game time a thing of this class takes to come back, or None (doesn't respawn / unknown)."""
        for r in self._blueprints(ref):
            s = self._own_row(r)
            if s:
                return s
        return None
