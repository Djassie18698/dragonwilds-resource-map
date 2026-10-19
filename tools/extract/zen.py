"""UE 5.6 cooked packages as stored in IoStore ("zen" packages): header, names, imports, exports.

Object references in a zen package are FPackageObjectIndex values (u64, the top two bits the kind):
  export:         index into this package's export map
  script import:  a hash naming a native object (/Script/...), resolved through the global script objects
  package import: (imported package index << 32) | imported public export hash index
"""
import struct

KIND_EXPORT, KIND_SCRIPT, KIND_PACKAGE, KIND_NULL = 0, 1, 2, 3  # FPackageObjectIndex kinds
NULL_INDEX = (1 << 64) - 1


def kind(index):
    return index >> 62


def read_name_batch(b, p):
    """FNameBatch: count, string bytes, hash version, hashes, 2-byte headers, strings. Returns names, end offset."""
    count, _string_bytes = struct.unpack_from('<II', b, p)
    p += 8
    if count == 0:
        return [], p
    p += 8 + count * 8          # hash version, hashes
    headers = b[p:p + count * 2]
    p += count * 2
    names = []
    for i in range(count):
        hi, lo = headers[i * 2], headers[i * 2 + 1]
        length = ((hi & 0x7F) << 8) | lo
        if hi & 0x80:
            names.append(b[p:p + length * 2].decode('utf-16le'))
            p += length * 2
        else:
            names.append(b[p:p + length].decode('latin1'))
            p += length
    return names, p


class Export:
    __slots__ = ('index', 'offset', 'size', 'name', 'outer', 'cls', 'super', 'template', 'hash', 'flags')


class Package:
    def __init__(self, data):
        self.data = data
        (has_versioning, self.header_size, name_index, _name_number, self.flags, self.cooked_header_size,
         hashes_off, imports_off, exports_off, bundles_off, _dep_headers_off, _dep_entries_off,
         imported_names_off) = struct.unpack_from('<IIIIIIiiiiiii', data, 0)
        if has_versioning:
            raise ValueError('versioned zen packages are not supported')
        self.names, _ = read_name_batch(data, 60)
        self.name = self.names[name_index]
        self.public_hashes = struct.unpack_from('<%dQ' % ((imports_off - hashes_off) // 8), data, hashes_off)
        self.imports = struct.unpack_from('<%dQ' % ((exports_off - imports_off) // 8), data, imports_off)
        self.exports = []
        for i in range((bundles_off - exports_off) // 72):
            o = exports_off + i * 72
            e = Export()
            e.index = i
            e.offset, e.size, name_idx, name_num, e.outer, e.cls, e.super, e.template, e.hash, e.flags = \
                struct.unpack_from('<QQIIQQQQQI', data, o)
            e.name = self.mapped(name_idx, name_num)
            self.exports.append(e)
        # Imported package names: a name batch, then each name's FName number (n > 0 appends _n-1).
        names, p = read_name_batch(data, imported_names_off)
        numbers = struct.unpack_from('<%di' % len(names), data, p) if names else ()
        self.imported_packages = [n if k == 0 else '%s_%d' % (n, k - 1) for n, k in zip(names, numbers)]

    def mapped(self, index, number):
        """FMappedName -> text (number n > 0 appends _n-1, as FName does)."""
        base = self.names[index & 0x3FFFFFFF]
        return base if number == 0 else '%s_%d' % (base, number - 1)

    def export_data(self, e):
        """An export's serialized bytes (export offsets count from the end of the header)."""
        start = self.header_size + e.offset
        return self.data[start:start + e.size]

    def fname(self, b, o):
        """An FName serialized in export data (name map index, number)."""
        index, number = struct.unpack_from('<II', b, o)
        return self.mapped(index, number)
