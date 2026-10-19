"""Class and struct layouts of the game's native (C++) types, read from the game's exe.

Cooked packages store properties "unversioned": by index into the class's property list, with no names or types.
Those lists live in the exe as the engine's generated reflection tables (UECodeGen_Private::FClassParams,
FStructParams and their property parameter arrays), which this module decodes the way the engine constructs
its FProperty lists at startup (ConstructFProperties: containers consume the entries before them as inners).

Layout notes (UE 5.6, shipping build):
  FClassRegisterCompiledInInfo   { Z_Construct_UClass_X, X::StaticClass, L"UX", &Info }        32 bytes
  FClassParams  { StaticClass, ConfigName, CppClassInfo, DependentSingletons, Functions, PropertyArray,
                  Interfaces, u32 NumDeps:4|NumFunctions:11|NumProperties:11|NumInterfaces:6, u32 ClassFlags }
  FStructParams { OuterFunc, SuperFunc, StructOpsFunc, NameUTF8, PropertyArray, u16 NumProperties, ... }
  FPropertyParamsBase { NameUTF8, RepNotify, u64 PropertyFlags, u8 GenFlags, u32 ObjectFlags, Setter, Getter,
                        u16 ArrayDim, u16 Offset, (type-specific pointer at +56) }
"""
import mmap
import struct

# EPropertyGenFlags (& TYPE_MASK)
BYTE, INT8, INT16, INT, INT64, UINT16, UINT32, UINT64 = 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07
FLOAT, DOUBLE, BOOL, SOFTCLASS, WEAKOBJECT, LAZYOBJECT, SOFTOBJECT = 0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F, 0x10
CLASS, OBJECT, INTERFACE, NAME, STR, ARRAY, MAP, SET, STRUCT = 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19
DELEGATE, MULTICAST_INLINE, MULTICAST_SPARSE, TEXT, ENUM, FIELDPATH, LWC_REAL, OPTIONAL = \
    0x1A, 0x1B, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x21
UTF8STR, ANSISTR = 0x23, 0x24
TYPE_MASK = 0x3F
TYPE_NAMES = {BYTE: 'Byte', INT8: 'Int8', INT16: 'Int16', INT: 'Int', INT64: 'Int64', UINT16: 'UInt16',
              UINT32: 'UInt32', UINT64: 'UInt64', FLOAT: 'Float', DOUBLE: 'Double', BOOL: 'Bool',
              SOFTCLASS: 'SoftClass', WEAKOBJECT: 'WeakObject', LAZYOBJECT: 'LazyObject', SOFTOBJECT: 'SoftObject',
              CLASS: 'Class', OBJECT: 'Object', INTERFACE: 'Interface', NAME: 'Name', STR: 'Str', ARRAY: 'Array',
              MAP: 'Map', SET: 'Set', STRUCT: 'Struct', DELEGATE: 'Delegate', MULTICAST_INLINE: 'MulticastInline',
              MULTICAST_SPARSE: 'MulticastSparse', TEXT: 'Text', ENUM: 'Enum', FIELDPATH: 'FieldPath',
              LWC_REAL: 'LwcReal', OPTIONAL: 'Optional', UTF8STR: 'Utf8Str', ANSISTR: 'AnsiStr'}
READ_MORE = {ARRAY: 1, SET: 1, MAP: 2, ENUM: 1, OPTIONAL: 1}


class Prop:
    __slots__ = ('name', 'type', 'dim', 'struct', 'inner', 'value', 'flags')

    def __init__(self, name, type_, dim):
        self.name, self.type, self.dim = name, type_, dim
        self.struct = self.inner = self.value = None
        self.flags = 0

    def __repr__(self):
        t = TYPE_NAMES.get(self.type, hex(self.type))
        if self.type == STRUCT:
            t += '<%s>' % (self.struct[1] if isinstance(self.struct, tuple) else self.struct,)
        elif self.inner is not None:
            t += '<%r%s>' % (self.inner, ', %r' % self.value if self.value is not None else '')
        return '%s:%s%s' % (self.name, t, '[%d]' % self.dim if self.dim != 1 else '')


class Exe:
    def __init__(self, path):
        f = open(path, 'rb')
        self.m = m = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ)
        pe, = struct.unpack_from('<I', m, 0x3C)
        nsec, = struct.unpack_from('<H', m, pe + 6)
        optsz, = struct.unpack_from('<H', m, pe + 20)
        self.base, = struct.unpack_from('<Q', m, pe + 24 + 24)
        self.sections = {}
        for i in range(nsec):
            o = pe + 24 + optsz + i * 40
            name = m[o:o + 8].rstrip(b'\0').decode()
            vsize, va, rsize, raw = struct.unpack_from('<IIII', m, o + 8)
            self.sections[name] = (self.base + va, vsize, raw, rsize)
        self.text = self.sections['.text']
        self.rdata = self.sections['.rdata']
        self.data = self.sections['.data']

    def off(self, va):
        for sva, vsize, raw, rsize in self.sections.values():
            if sva <= va < sva + min(vsize, rsize):
                return raw + (va - sva)
        return None

    def va(self, off):
        """The address a file offset is loaded at."""
        for sva, vsize, raw, rsize in self.sections.values():
            if raw <= off < raw + rsize:
                return sva + (off - raw)
        return None

    def is_data(self, va):
        return (self.rdata[0] <= va < self.rdata[0] + self.rdata[1]) or \
               (self.data[0] <= va < self.data[0] + self.data[1])

    def q(self, va, n=1):
        o = self.off(va)
        return struct.unpack_from('<%dQ' % n, self.m, o) if n > 1 else struct.unpack_from('<Q', self.m, o)[0]

    def cstr(self, va):
        o = self.off(va) if va else None
        if o is None:
            return None
        e = self.m.find(b'\0', o, o + 256)
        s = self.m[o:e]
        return s.decode('latin1') if s and all(32 < c < 127 for c in s) else None

    def wstr(self, va):
        o = self.off(va) if va else None
        if o is None:
            return None
        out = []
        while len(out) < 128:
            c, = struct.unpack_from('<H', self.m, o)
            if c == 0:
                break
            if not (32 < c < 127):
                return None
            out.append(chr(c))
            o += 2
        return ''.join(out) if out else None

    def section_qwords(self, name):
        sva, vsize, raw, rsize = self.sections[name]
        n = min(vsize, rsize) // 8
        return sva, memoryview(self.m)[raw:raw + n * 8].cast('Q')

    def lea_targets(self, fn_va, span=160):
        """Targets of rip-relative LEAs in the first bytes of a function (following one leading jmp)."""
        o = self.off(fn_va)
        if o is None:
            return []
        if self.m[o] == 0xE9:   # jmp rel32 (incremental-link style thunk)
            fn_va = fn_va + 5 + struct.unpack_from('<i', self.m, o + 1)[0]
            o = self.off(fn_va)
        code = self.m[o:o + span]
        out = []
        for i in range(len(code) - 7):
            if code[i] in (0x48, 0x4C) and code[i + 1] == 0x8D and (code[i + 2] & 0xC7) == 0x05:
                disp, = struct.unpack_from('<i', code, i + 3)
                out.append(fn_va + i + 7 + disp)
        return out


class Schema:
    """classes: name -> {'super': name|None, 'props': [Prop]}; structs: name -> {'super', 'props'}."""

    def __init__(self, exe_path):
        self.exe = Exe(exe_path)
        self.classes, self.structs = {}, {}
        self._struct_by_fn = {}
        self._read()

    def _read(self):
        exe = self.exe
        names_by_static, names_by_construct = {}, {}
        # Registration records: (Z_Construct_UClass_X, X::StaticClass, L"UX", &Info).
        for sec in ('.rdata', '.data'):
            sva, qs = exe.section_qwords(sec)
            text0, text1 = exe.text[0], exe.text[0] + exe.text[1]
            for i in range(len(qs) - 3):
                a = qs[i]
                if not (text0 <= a < text1):
                    continue
                b = qs[i + 1]
                if not (text0 <= b < text1):
                    continue
                c = qs[i + 2]
                if not exe.is_data(c):
                    continue
                name = exe.wstr(c)
                if name and len(name) > 1 and name[0] in 'UA' and name[1].isupper() and \
                        name.replace('_', 'a').isalnum():
                    names_by_construct[a] = name[1:]
                    names_by_static[b] = name[1:]
        self.names_by_construct = names_by_construct
        # Class params: first qword is the class's StaticClass function, next its config name.
        statics = set(names_by_static)
        for sec in ('.rdata', '.data'):
            sva, qs = exe.section_qwords(sec)
            for i in range(len(qs) - 8):
                a = qs[i]
                if a not in statics:
                    continue
                config, cpp_info, deps, funcs, props, ifaces, packed = qs[i + 1], qs[i + 2], qs[i + 3], qs[i + 4], \
                    qs[i + 5], qs[i + 6], qs[i + 7]
                # Every generated class has C++ type info and depends on at least its package; the config section
                # name is optional.
                if not exe.is_data(cpp_info) or (config and exe.cstr(config) is None):
                    continue
                bits = packed & 0xFFFFFFFF
                n_deps, n_props, n_ifaces = bits & 0xF, (bits >> 15) & 0x7FF, (bits >> 26) & 0x3F
                if n_deps == 0 or not exe.is_data(deps) or (props == 0) != (n_props == 0) or \
                        (ifaces == 0) != (n_ifaces == 0):
                    continue
                if props and not (exe.is_data(props) and self._valid_params(props, n_props)):
                    continue
                name = names_by_static[a]
                if name in self.classes:
                    continue
                sup = None
                if n_deps and deps and exe.is_data(deps):
                    for fn in exe.q(deps, n_deps) if n_deps > 1 else (exe.q(deps),):
                        if fn in names_by_construct:
                            sup = names_by_construct[fn]
                            break
                n_funcs = (bits >> 4) & 0x7FF
                self.classes[name] = {'super': sup, 'props': self._props(props, n_props) if props else [],
                                      'functions': self._functions(funcs, n_funcs)}

    def _functions(self, array_va, count):
        """Names of a class's native functions (FClassFunctionLinkInfo: CreateFuncPtr, NameUTF8)."""
        exe = self.exe
        if not array_va or not count or exe.off(array_va) is None or exe.off(array_va + count * 16 - 1) is None:
            return []
        return [exe.cstr(exe.q(array_va + i * 16 + 8)) for i in range(count)]

    def _valid_params(self, array_va, count):
        """Whether array_va holds count pointers to property parameters (each starting with a name)."""
        exe = self.exe
        if count == 0:
            return True
        if exe.off(array_va) is None or exe.off(array_va + count * 8 - 1) is None:
            return False
        for p in (exe.q(array_va, count) if count > 1 else (exe.q(array_va),)):
            if exe.off(p) is None or exe.off(p + 63) is None or exe.cstr(exe.q(p)) is None:
                return False
        return True

    def _props(self, array_va, count):
        exe = self.exe
        if not array_va or count == 0:
            return []
        params = list(exe.q(array_va, count)) if count > 1 else [exe.q(array_va)]
        out = []
        pos = len(params)

        def construct():
            nonlocal pos
            pos -= 1
            p = params[pos]
            name = exe.cstr(exe.q(p)) or '?'
            o = exe.off(p)
            flags = exe.m[o + 24]
            t = flags & TYPE_MASK
            dim, = struct.unpack_from('<H', exe.m, o + 48)
            prop = Prop(name, t, dim or 1)
            prop.flags, = struct.unpack_from('<Q', exe.m, o + 16)
            if t == STRUCT:
                prop.struct = self.struct_name(struct.unpack_from('<Q', exe.m, o + 56)[0])
            more = READ_MORE.get(t, 0)
            inners = []
            while more and pos > 0:
                inners.append(construct())
                more -= 1
            if t == MAP and len(inners) == 2:
                prop.inner, prop.value = inners[0], inners[1]
            elif inners:
                prop.inner = inners[0]
            return prop

        while pos > 0:
            out.append(construct())
        out.reverse()
        return out

    def find_struct(self, name):
        """A struct's layout by name, for structs no property refers to (DataTable row structs): the FStructParams
        whose NameUTF8 (at +24) is that name."""
        if name in self.structs:
            return self.structs[name]
        exe = self.exe
        raw = exe.rdata[2]
        needle = b'\0' + name.encode() + b'\0'
        at = exe.m.find(needle, raw)
        while at != -1:
            va = exe.va(at + 1)
            ref = exe.m.find(struct.pack('<Q', va), raw)
            while ref != -1:
                base = exe.va(ref) - 24
                try:
                    outer, sup, ops, name_p, props_p, packed = exe.q(base, 6)
                except (struct.error, TypeError):
                    break
                n_props = packed & 0xFFFF
                if name_p == va and (props_p == 0 or self._valid_params(props_p, n_props)):
                    self.structs[name] = {'super': self.struct_name(sup) if sup else None,
                                          'props': self._props(props_p, n_props) if props_p and n_props else []}
                    return self.structs[name]
                ref = exe.m.find(struct.pack('<Q', va), ref + 1)
            at = exe.m.find(needle, at + 1)
        return None

    def struct_name(self, fn):
        """Name of the struct a Z_Construct_UScriptStruct_F... function builds (reads its FStructParams)."""
        if fn in self._struct_by_fn:
            return self._struct_by_fn[fn]
        self._struct_by_fn[fn] = None
        exe = self.exe
        for target in exe.lea_targets(fn):
            if not exe.is_data(target):
                continue
            try:
                outer, sup, ops, name_p, props, packed = exe.q(target, 6)
            except struct.error:
                continue
            name = exe.cstr(name_p) if exe.is_data(name_p) else None
            if not name:
                continue
            n_props = packed & 0xFFFF
            if props and not (exe.is_data(props) and self._valid_params(props, n_props)):
                continue
            self._struct_by_fn[fn] = name
            if name not in self.structs:
                self.structs[name] = {'super': None, 'props': []}
                self.structs[name]['super'] = self.struct_name(sup) if sup else None
                self.structs[name]['props'] = self._props(props, n_props) if props and n_props else []
            return name
        return None
