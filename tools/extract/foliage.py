"""The game's interactable foliage (plants, trees, saplings): every instance of every InteractableFoliageISMComponent
in the world's packages, as mesh name + world position.

A component's instances (UInstancedStaticMeshComponent::PerInstanceSMData) follow its property block as a bulk
array: int32 element size (128: an FMatrix of doubles), int32 count, then the matrices. An instance's position in
the component is its matrix's translation row; the world position goes up the component's attach chain (each
link: scale, then rotation, then translation), ending at the actor's root component.
"""
import math
import struct

import props as P
import zen

FOLIAGE_BASE = 'InteractableFoliageISMComponent'
MATRIX = 128


def rotate(rot, v):
    """FRotator (pitch, yaw, roll in degrees) applied to a vector, as FRotationMatrix does."""
    if not rot or rot == (0.0, 0.0, 0.0):
        return v
    p, y, r = (math.radians(a) for a in rot)
    sp, cp, sy, cy, sr, cr = math.sin(p), math.cos(p), math.sin(y), math.cos(y), math.sin(r), math.cos(r)
    m0 = (cp * cy, cp * sy, sp)
    m1 = (sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp)
    m2 = (-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp)
    x, yy, z = v
    return (x * m0[0] + yy * m1[0] + z * m2[0], x * m0[1] + yy * m1[1] + z * m2[1],
            x * m0[2] + yy * m1[2] + z * m2[2])


def apply(t, v):
    loc, rot, scale = t
    v = (v[0] * scale[0], v[1] * scale[1], v[2] * scale[2])
    v = rotate(rot, v)
    return (v[0] + loc[0], v[1] + loc[1], v[2] + loc[2])


def instance_array(b, start):
    """Offset and count of the instance matrices after a component's property block, or (None, 0)."""
    for o in range(start, min(len(b) - 8, start + 512)):
        size, n = struct.unpack_from('<ii', b, o)
        if size == MATRIX and 0 <= n and o + 8 + n * MATRIX <= len(b):
            if n == 0:
                return o + 8, 0
            m = struct.unpack_from('<16d', b, o + 8)
            if abs(m[15] - 1.0) < 1e-6 and abs(m[3]) < 1e-6 and abs(m[7]) < 1e-6 and abs(m[11]) < 1e-6:
                return o + 8, n
    return None, 0


class Extractor:
    def __init__(self, world, layouts):
        self.world, self.layouts = world, layouts
        self.errors = {}
        self._is_foliage = {}

    def is_foliage(self, ref):
        if ref not in self._is_foliage:
            chain, r = [], ref
            while r:
                chain.append(r[1])
                d = self.layouts.get(r)
                r = d['super'] if d else None
            self._is_foliage[ref] = FOLIAGE_BASE in chain
        return self._is_foliage[ref]

    def instances(self, pkg_name):
        """Yields (mesh name, x, y, z) for every foliage instance in a world package."""
        data = self.world.game.package_bytes(pkg_name)
        if data is None or b'InteractableFoliageISMC' not in data:
            return
        pkg = zen.Package(data)
        dec = P.Decoder(self.layouts, pkg)
        transforms = {}

        def transform_of(index):
            """(loc, rot, scale, parent export index or None) of a scene component, decoded once."""
            if index not in transforms:
                e = pkg.exports[index]
                c = self.world.resolve(pkg, e.cls)
                v, _ = dec.block(pkg.export_data(e), 0, (c[0], c[1]),
                                 want={'RelativeLocation', 'RelativeRotation', 'RelativeScale3D', 'AttachParent'})
                parent = v.get('AttachParent')
                transforms[index] = ((v.get('RelativeLocation', (0.0, 0.0, 0.0)), v.get('RelativeRotation'),
                                      v.get('RelativeScale3D', (1.0, 1.0, 1.0))),
                                     parent - 1 if parent and parent > 0 else None)
            return transforms[index]

        for e in pkg.exports:
            c = self.world.resolve(pkg, e.cls)
            if not c or not c[1] or not self.is_foliage((c[0], c[1])):
                continue
            b = pkg.export_data(e)
            try:
                v, end = dec.block(b, 0, (c[0], c[1]))
                mesh = self.world.resolve_index(pkg, v.get('StaticMesh') or 0)
                at, n = instance_array(b, end)
                if at is None:
                    raise P.Unsupported('no instance array')
                chain, index = [], e.index
                while index is not None and len(chain) < 16:
                    t, index = transform_of(index)
                    chain.append(t)
            except (P.Unsupported, struct.error, IndexError, KeyError) as err:
                key = (c[1], str(err)[:80])
                self.errors[key] = self.errors.get(key, 0) + 1
                continue
            name = mesh[1] if mesh else '?'
            for i in range(n):
                m = struct.unpack_from('<3d', b, at + i * MATRIX + 96)
                for t in chain:
                    m = apply(t, m)
                yield name, m[0], m[1], m[2]
