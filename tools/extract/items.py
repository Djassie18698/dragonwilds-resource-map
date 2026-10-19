"""Items: name, kind and full durability per persistence id (the id saves use), from the game's item assets.

Item assets are objects of ItemData or a subclass (in the game's Items folders, named ITEM_* or DA_*); a few items are
an item Blueprint's default object itself. Their names are string table entries (text history StringTableEntry: table
object path + key), looked up in the tables' packages; a "[PH] " (placeholder) prefix is dropped. Items without a name
(deleted ones) get their internal name, readable; a pattern (recipe unlocker) named like the item it unlocks gets
"Pattern: " in front, so the two can be told apart.
Kind is only what the mod's junk rules need: "Fuel" (FuelItemData) and "Seed" (the seed classes).
"""
import struct

import props as P

KINDS = {'FuelItemData': 'Fuel', 'SeedHeldEquipmentData': 'Seed', 'HeldTreeSeedData': 'Seed'}
# Items that are an item Blueprint's default object and get their name from that Blueprint's logic (the object itself
# has none): the string table entry the game shows for them. Without it they'd be "Unknown item" in tooltips.
ST_ITEM_NAMES = '/Game/Gameplay/Items/ST_ItemNames.ST_ItemNames'
NAMED_IN_BLUEPRINT = {
    'Pc6vpkbmfa3yXnaREyZM2g': (ST_ITEM_NAMES, 'Skilltome.BlackKnightFortress'),   # BP_Consumables_SkillTome
    'M3lV70TtklsLma-1TT8h2g': (ST_ITEM_NAMES, 'BramblemeadCape'),                 # BP_Consumables_RecipeUnlocker2
}
WANT = {'PersistenceID', 'Name', 'InternalName', 'BaseDurability'}


def candidates(world):
    """Packages that can hold item assets."""
    for name in world.game.packages:
        base = name.rsplit('/', 1)[1]
        if '/Items/' in name or base.startswith(('ITEM_', 'DA_')):
            yield name


class Items:
    def __init__(self, world, layouts, chain):
        self.world, self.layouts, self.chain = world, layouts, chain
        self._tables = {}
        self.errors = {}

    def string_table(self, path):
        """key -> text of a StringTable (path: its object path, /Game/X/ST_Y.ST_Y)."""
        pkg_name = path.split('.', 1)[0]
        if pkg_name not in self._tables:
            entries = {}
            pkg = self.world.package(pkg_name)
            e = pkg and next((x for x in pkg.exports if x.name == pkg_name.rsplit('/', 1)[1]), None)
            if e is not None:
                b = pkg.export_data(e)
                dec = P.Decoder(self.layouts, pkg)
                c = self.world.resolve(pkg, e.cls)
                _, o = dec.block(b, 0, (c[0], c[1]))
                _namespace, o = dec.fstring(b, o + 4)       # after the object guid flag
                n, = struct.unpack_from('<i', b, o)
                o += 4
                for _ in range(n):
                    key, o = dec.fstring(b, o)
                    entries[key], o = dec.fstring(b, o)
            self._tables[pkg_name] = entries
        return self._tables[pkg_name]

    def text(self, v):
        if isinstance(v, tuple):
            v = self.string_table(v[0]).get(v[1])
        if v and v.startswith('[PH] '):
            v = v[5:]
        return v or None

    def kind(self, ref):
        for name in self.chain(ref):
            if name in KINDS:
                return KINDS[name]
        return None

    def all(self):
        """persistence id -> (name, kind, full durability)."""
        out = {}
        for pkg_name in candidates(self.world):
            pkg = self.world.package(pkg_name)
            if pkg is None:
                continue
            dec = P.Decoder(self.layouts, pkg)
            for e in pkg.exports:
                c = self.world.resolve(pkg, e.cls)
                if not c or not c[1] or 'ItemData' not in self.chain((c[0], c[1])):
                    continue
                try:
                    v, _ = dec.block(pkg.export_data(e), 0, (c[0], c[1]), want=WANT)
                except (P.Unsupported, struct.error, IndexError, KeyError) as err:
                    key = (c[1], str(err)[:80])
                    self.errors[key] = self.errors.get(key, 0) + 1
                    continue
                pid = v.get('PersistenceID')
                if not pid or (e.name.startswith('Default__') and pid in out):
                    continue
                full = v.get('BaseDurability')
                name = (self.text(v.get('Name')) or readable(v.get('InternalName'))
                        or (self.text(NAMED_IN_BLUEPRINT[pid]) if pid in NAMED_IN_BLUEPRINT else None))
                if not name:
                    continue   # an item Blueprint's default object: a template, not an item
                pattern = 'ConsumableRecipeUnlocker' in self.chain((c[0], c[1]))
                out[pid] = [name, self.kind((c[0], c[1])), int(full) if full else None, pattern]
        names = {}
        for item in out.values():
            names[item[0]] = names.get(item[0], 0) + 1
        for item in out.values():
            if item[3] and names[item[0]] > 1:
                item[0] = 'Pattern: ' + item[0]
        return {pid: tuple(item[:3]) for pid, item in out.items()}


def readable(internal):
    """armour_t4_cape_attack -> Armour T4 Cape Attack."""
    if not internal:
        return None
    return ' '.join(w[:1].upper() + w[1:] for w in internal.replace('-', '_').split('_') if w)
