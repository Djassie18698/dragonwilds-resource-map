"""Names for object references across packages: native objects (global script objects) and other packages' exports."""
import struct

import iostore
import zen


class World:
    """Everything needed to name objects: the game's containers, script objects and a package cache."""

    def __init__(self, game_dir):
        self.game = iostore.Game(game_dir)
        self.cache = {}
        self._load_script_objects()

    def _load_script_objects(self):
        g = self.game.glob
        data = g.read_entry(0)
        names, p = zen.read_name_batch(data, 0)
        count, = struct.unpack_from('<i', data, p)
        p += 4
        self.script = {}   # global index -> (name, outer index)
        for i in range(count):
            idx, num, glob, outer, _cdo_class = struct.unpack_from('<IIQQQ', data, p + i * 32)
            name = names[idx & 0x3FFFFFFF]
            if num:
                name = '%s_%d' % (name, num - 1)
            self.script[glob] = (name, outer)

    def script_path(self, index):
        """/Script/Engine.StaticMeshComponent for a script import."""
        parts = []
        while index in self.script:
            name, outer = self.script[index]
            parts.append(name)
            index = outer
        parts.reverse()
        return parts[0] + ('.' + ':'.join(parts[1:]) if len(parts) > 1 else '') if parts else None

    def package(self, name):
        key = name.lower()
        if key not in self.cache:
            data = self.game.package_bytes(name)
            self.cache[key] = zen.Package(data) if data else None
        return self.cache[key]

    def resolve(self, pkg, index):
        """A reference from inside pkg -> (package name or None for native, object name, export or None, target pkg).
        Object name is the short name (StaticMeshComponent, BP_OreNode_Copper_A1_C)."""
        k = zen.kind(index)
        if index == zen.NULL_INDEX or k == zen.KIND_NULL:
            return None
        if k == zen.KIND_EXPORT:
            e = pkg.exports[index]
            return (pkg.name, e.name, e, pkg)
        if k == zen.KIND_SCRIPT:
            path = self.script_path(index)
            if path is None:
                return None
            return (None, path.rsplit('.', 1)[-1].rsplit(':', 1)[-1], None, None)
        return self.resolve_package_import(pkg, index)

    def resolve_package_import(self, pkg, index):
        pkg_index = (index >> 32) & 0x3FFFFFFF
        hash_index = index & 0xFFFFFFFF
        if pkg_index >= len(pkg.imported_packages) or hash_index >= len(pkg.public_hashes):
            return None
        target_name = pkg.imported_packages[pkg_index]
        h = pkg.public_hashes[hash_index]
        target = self.package(target_name)
        if target is None:
            return (target_name, None, None, None)
        for e in target.exports:
            if e.hash == h:
                return (target_name, e.name, e, target)
        return (target_name, None, None, target)

    def resolve_index(self, pkg, idx):
        """An FPackageIndex from export data: < 0 import -(idx+1), > 0 export idx-1, 0 null."""
        if idx < 0:
            return self.resolve(pkg, pkg.imports[-idx - 1])
        if idx > 0:
            e = pkg.exports[idx - 1]
            return (pkg.name, e.name, e, pkg)
        return None
