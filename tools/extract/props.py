"""Unversioned property data: class layouts (native from the exe, Blueprint from their packages) and a decoder.

Index order (as the engine's FUnversionedStructSchema walks PropertyLink): a class's own properties first, then its
super's, and so on; each property takes ArrayDim slots. The data is a header (fragments of skipped / present indices
plus a mask of present-but-zero values) followed by the present non-zero values in index order.
"""
import struct

import schema as S

# Structs the engine serializes natively (binary), with their size; others are nested unversioned property blocks.
NATIVE_SIZES = {
    'Vector': 24, 'Vector3d': 24, 'Vector3f': 12, 'Rotator': 24, 'Rotator3d': 24, 'Rotator3f': 12, 'Quat': 32,
    'Quat4d': 32, 'Quat4f': 16, 'Vector2D': 16, 'Vector2f': 8, 'Vector4': 32, 'Vector4d': 32, 'Vector4f': 16,
    'Plane': 32, 'Plane4d': 32, 'Plane4f': 16, 'IntPoint': 8, 'Int32Point': 8, 'IntVector': 12, 'Int32Vector': 12,
    'IntVector4': 16, 'UintVector4': 16, 'Color': 4, 'LinearColor': 16, 'Guid': 16, 'Box': 49, 'Box3d': 49,
    'Box3f': 25, 'Box2D': 33, 'Box2d': 33, 'Box2f': 17, 'Matrix': 128, 'Matrix44d': 128, 'Matrix44f': 64,
    'DateTime': 8, 'Timespan': 8, 'FrameNumber': 4, 'Vector_NetQuantize': 24, 'Vector_NetQuantize10': 24,
    'Vector_NetQuantize100': 24, 'Vector_NetQuantizeNormal': 24, 'TwoVectors': 48, 'Sphere': 32,
    'PerPlatformFloat': 8, 'PerPlatformInt': 8, 'PerPlatformBool': 8, 'PerPlatformFrameRate': 12,
    'RichCurveKey': 27, 'SimpleCurveKey': 8, 'IntRect': 16, 'KeyHandleMap': 0,
}
FIXED = {S.BYTE: 1, S.INT8: 1, S.BOOL: 1, S.INT16: 2, S.UINT16: 2, S.INT: 4, S.UINT32: 4, S.FLOAT: 4,
         S.INT64: 8, S.UINT64: 8, S.DOUBLE: 8, S.LWC_REAL: 8, S.NAME: 8, S.OBJECT: 4, S.CLASS: 4,
         S.INTERFACE: 4, S.WEAKOBJECT: 4, S.LAZYOBJECT: 16, S.DELEGATE: 12}
# FField type names in Blueprint packages -> gen flags type
FIELD_TYPES = {'ByteProperty': S.BYTE, 'Int8Property': S.INT8, 'Int16Property': S.INT16, 'IntProperty': S.INT,
               'Int64Property': S.INT64, 'UInt16Property': S.UINT16, 'UInt32Property': S.UINT32,
               'UInt64Property': S.UINT64, 'FloatProperty': S.FLOAT, 'DoubleProperty': S.DOUBLE,
               'BoolProperty': S.BOOL, 'SoftClassProperty': S.SOFTCLASS, 'WeakObjectProperty': S.WEAKOBJECT,
               'LazyObjectProperty': S.LAZYOBJECT, 'SoftObjectProperty': S.SOFTOBJECT, 'ClassProperty': S.CLASS,
               'ObjectProperty': S.OBJECT, 'InterfaceProperty': S.INTERFACE, 'NameProperty': S.NAME,
               'StrProperty': S.STR, 'ArrayProperty': S.ARRAY, 'MapProperty': S.MAP, 'SetProperty': S.SET,
               'StructProperty': S.STRUCT, 'DelegateProperty': S.DELEGATE,
               'MulticastInlineDelegateProperty': S.MULTICAST_INLINE,
               'MulticastSparseDelegateProperty': S.MULTICAST_SPARSE, 'TextProperty': S.TEXT,
               'EnumProperty': S.ENUM, 'FieldPathProperty': S.FIELDPATH, 'OptionalProperty': S.OPTIONAL,
               'ClassPtrProperty': S.CLASS, 'ObjectPtrProperty': S.OBJECT, 'Utf8StrProperty': S.UTF8STR,
               'AnsiStrProperty': S.ANSISTR}


class Unsupported(Exception):
    pass


class Layouts:
    """Property lists of classes and structs, native or Blueprint, keyed by (package or None, name)."""

    def __init__(self, world, native):
        self.world, self.native = world, native
        self.cache = {}

    def get(self, ref):
        """ref = (package name or None, object name) -> {'super': ref|None, 'props': [Prop]} or None."""
        if ref in self.cache:
            return self.cache[ref]
        self.cache[ref] = None
        pkg_name, name = ref
        out = None
        if pkg_name is None:
            d = self.native.classes.get(name) or self.native.structs.get(name) or self.native.find_struct(name)
            if d is not None:
                out = {'super': (None, d['super']) if d['super'] else None, 'props': d['props']}
        else:
            out = self._blueprint(pkg_name, name)
        self.cache[ref] = out
        return out

    def index_list(self, ref):
        """Properties in unversioned index order (own first, then supers), each repeated ArrayDim times."""
        out = []
        while ref:
            d = self.get(ref)
            if d is None:
                raise Unsupported('no layout for %s' % (ref,))
            for p in d['props']:
                out.extend([p] * p.dim)
            ref = d['super']
        return out

    def _blueprint(self, pkg_name, name):
        pkg = self.world.package(pkg_name)
        if pkg is None:
            return None
        e = next((x for x in pkg.exports if x.name == name), None)
        if e is None:
            return None
        sup = self.world.resolve(pkg, e.super)
        b = pkg.export_data(e)
        try:
            props = self._struct_fields(pkg, b, e)
        except (struct.error, Unsupported, IndexError) as err:
            raise Unsupported('blueprint layout %s.%s: %s' % (pkg_name, name, err))
        return {'super': (sup[0], sup[1]) if sup else None, 'props': props}

    def _struct_fields(self, pkg, b, e):
        """UStruct::Serialize after the object's own properties: SuperStruct, Children, ChildProperties."""
        dec = Decoder(self, pkg)
        cls = self.world.resolve(pkg, e.cls)
        o = dec.skip_object(b, 0, (cls[0], cls[1]) if cls else None)
        o += 4                                  # SuperStruct
        n, = struct.unpack_from('<i', b, o)     # Children
        o += 4 + n * 4
        n, = struct.unpack_from('<i', b, o)     # ChildProperties
        o += 4
        props = []
        for _ in range(n):
            p, o = self._field(pkg, b, o)
            props.append(p)
        return props

    def _field(self, pkg, b, o):
        type_name = pkg.fname(b, o)
        o += 8
        t = FIELD_TYPES.get(type_name)
        if t is None:
            raise Unsupported('field type ' + type_name)
        name = pkg.fname(b, o)
        o += 8 + 4                              # Name, FlagsPrivate
        dim, _elem_size, flags = struct.unpack_from('<iiQ', b, o)
        o += 16
        o += 2 + 8 + 1                          # RepIndex, RepNotifyFunc, BlueprintReplicationCondition
        p = S.Prop(name, t, dim or 1)
        p.flags = flags
        if t in (S.OBJECT, S.WEAKOBJECT, S.LAZYOBJECT, S.SOFTOBJECT, S.INTERFACE):
            o += 4
        elif t in (S.CLASS, S.SOFTCLASS):
            o += 8
        elif t == S.STRUCT:
            ref = self.world.resolve_index(pkg, struct.unpack_from('<i', b, o)[0])
            p.struct = (ref[0], ref[1]) if ref else None
            o += 4
        elif t == S.BYTE:
            o += 4
        elif t == S.BOOL:
            o += 6
        elif t in (S.DELEGATE, S.MULTICAST_INLINE, S.MULTICAST_SPARSE):
            o += 4
        elif t == S.FIELDPATH:
            o += 8
        elif t in (S.ARRAY, S.SET, S.OPTIONAL):
            p.inner, o = self._field(pkg, b, o)
        elif t == S.MAP:
            p.inner, o = self._field(pkg, b, o)
            p.value, o = self._field(pkg, b, o)
        elif t == S.ENUM:
            o += 4
            p.inner, o = self._field(pkg, b, o)
        return p, o


def struct_ref(p):
    """A struct property's struct as a layout ref (native structs are named, Blueprint ones are refs)."""
    return p.struct if isinstance(p.struct, tuple) else (None, p.struct)


class Decoder:
    """Reads unversioned property blocks in one package's export data."""

    def __init__(self, layouts, pkg):
        self.layouts, self.pkg = layouts, pkg

    @staticmethod
    def header(b, o):
        frags = []
        while True:
            packed, = struct.unpack_from('<H', b, o)
            o += 2
            frags.append((packed & 0x7F, packed >> 9, bool(packed & 0x80)))
            if packed & 0x100:
                break
        zero_bits = sum(num for _, num, has_zero in frags if has_zero)
        mask = 0
        if zero_bits:
            if zero_bits <= 8:
                mask = b[o]
                o += 1
            elif zero_bits <= 16:
                mask, = struct.unpack_from('<H', b, o)
                o += 2
            else:
                words = (zero_bits + 31) // 32
                mask = int.from_bytes(b[o:o + words * 4], 'little')
                o += words * 4
        present, index, bit = [], 0, 0
        for skip, num, has_zero in frags:
            index += skip
            for _ in range(num):
                zero = False
                if has_zero:
                    zero = bool((mask >> bit) & 1)
                    bit += 1
                present.append((index, zero))
                index += 1
        return present, o

    def block(self, b, o, ref, want=None):
        """Reads one property block of class/struct ref. Returns ({name: value} for wanted names, end offset).
        want: names to decode (others are only skipped); None = decode everything decodable."""
        props = self.layouts.index_list(ref)
        present, o = self.header(b, o)
        values = {}
        for index, zero in present:
            if index >= len(props):
                raise Unsupported('property index %d beyond %d of %s' % (index, len(props), ref))
            p = props[index]
            if zero:
                continue
            if want is None or p.name in want:
                values[p.name], o = self.value(b, o, p)
            else:
                o = self.skip(b, o, p)
        return values, o

    def skip_object(self, b, o, cls_ref):
        """Skips an export's property block (and the object guid flag after it)."""
        _, o = self.block(b, o, cls_ref, want=())
        return o + 4

    def skip(self, b, o, p):
        size = FIXED.get(p.type)
        if size is not None:
            return o + size
        return self.value(b, o, p)[1]

    def value(self, b, o, p):
        t = p.type
        if t in FIXED:
            if t in (S.OBJECT, S.CLASS, S.INTERFACE, S.WEAKOBJECT):
                return struct.unpack_from('<i', b, o)[0], o + 4
            if t == S.NAME:
                return self.pkg.fname(b, o), o + 8
            if t in (S.DOUBLE, S.LWC_REAL):
                return struct.unpack_from('<d', b, o)[0], o + 8
            if t == S.FLOAT:
                return struct.unpack_from('<f', b, o)[0], o + 4
            if t in (S.INT, S.UINT32):
                return struct.unpack_from('<i' if t == S.INT else '<I', b, o)[0], o + 4
            if t in (S.BYTE, S.BOOL, S.INT8):
                return b[o], o + 1
            return None, o + FIXED[t]
        if t == S.ENUM:
            return self.value(b, o, p.inner) if p.inner is not None else (b[o], o + 1)
        if t in (S.STR, S.UTF8STR, S.ANSISTR):
            return self.fstring(b, o)
        if t in (S.SOFTOBJECT, S.SOFTCLASS):
            return self.soft_path(b, o)
        if t == S.TEXT:
            return self.text(b, o)
        if t == S.STRUCT:
            return self.struct_value(b, o, p)
        if t in (S.ARRAY, S.SET):
            if t == S.SET:
                n, = struct.unpack_from('<i', b, o)
                o += 4
                for _ in range(n):
                    o = self.skip(b, o, p.inner)
            n, = struct.unpack_from('<i', b, o)
            o += 4
            items = []
            for _ in range(n):
                v, o = self.value(b, o, p.inner)
                items.append(v)
            return items, o
        if t == S.MAP:
            n, = struct.unpack_from('<i', b, o)
            o += 4
            for _ in range(n):
                o = self.skip(b, o, p.inner)
            n, = struct.unpack_from('<i', b, o)
            o += 4
            items = []
            for _ in range(n):
                k, o = self.value(b, o, p.inner)
                v, o = self.value(b, o, p.value)
                items.append((k, v))
            return items, o
        if t in (S.MULTICAST_INLINE, S.MULTICAST_SPARSE):
            n, = struct.unpack_from('<i', b, o)
            return None, o + 4 + n * 12
        if t == S.FIELDPATH:
            n, = struct.unpack_from('<i', b, o)
            return None, o + 4 + n * 8 + 4
        if t == S.OPTIONAL:
            has = b[o]
            o += 1
            return self.value(b, o, p.inner) if has else (None, o)
        raise Unsupported('property type %s (%s)' % (S.TYPE_NAMES.get(t, t), p.name))

    def struct_value(self, b, o, p):
        ref = struct_ref(p)
        name = ref[1]
        if ref[0] is None and name in NATIVE_SIZES:
            size = NATIVE_SIZES[name]
            if name in ('Vector', 'Rotator', 'Vector3d', 'Rotator3d'):
                return struct.unpack_from('<3d', b, o), o + size
            return None, o + size
        if ref[0] is None and name in ('SoftObjectPath', 'SoftClassPath'):
            return self.soft_path(b, o)
        if ref[0] is None and name == 'GameplayTagContainer':
            n, = struct.unpack_from('<i', b, o)
            return None, o + 4 + n * 8
        return self.block(b, o, ref)

    def fstring(self, b, o):
        n, = struct.unpack_from('<i', b, o)
        o += 4
        if n >= 0:
            return b[o:o + n].decode('latin1').rstrip('\0'), o + n
        return b[o:o - n * 2].decode('utf-16le', 'replace').rstrip('\0'), o - n * 2

    def soft_path(self, b, o):
        pkg_name, asset = self.pkg.fname(b, o), self.pkg.fname(b, o + 8)
        sub, o = self.fstring(b, o + 16)
        return (pkg_name, asset, sub), o

    def text(self, b, o):
        _flags, history = struct.unpack_from('<ib', b, o)
        o += 5
        if history == -1:
            has, = struct.unpack_from('<I', b, o)
            o += 4
            if has:
                return self.fstring(b, o)
            return '', o
        if history == 0:
            _ns, o = self.fstring(b, o)
            _key, o = self.fstring(b, o)
            return self.fstring(b, o)
        if history == 11:   # a string table entry: (table object path, key), looked up by the caller
            table = self.pkg.fname(b, o)
            key, o = self.fstring(b, o + 8)
            return (table, key), o
        raise Unsupported('text history %d' % history)
