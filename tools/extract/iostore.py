"""Reads the game's IoStore containers (Content/Paks/*.utoc + .ucas): chunks by id or by file path.

Dragonwilds ships them uncompressed and unencrypted (TOC version 8), so a chunk is a run of raw blocks.
"""
import os
import struct

EXPORT_BUNDLE_DATA = 1   # EIoChunkType of a package (header and exports)
NONE = 0xFFFFFFFF


class Container:
    def __init__(self, base):
        self.base = base
        toc = open(base + '.utoc', 'rb').read()
        if toc[:16] != b'-==--==--==--==-':
            raise ValueError(base + '.utoc: not an IoStore TOC')
        (header_size, entry_count, block_count, block_entry_size, method_count, method_length, self.block_size,
         dir_index_size, _partition_count) = struct.unpack_from('<9I', toc, 20)
        perfect_seeds, = struct.unpack_from('<I', toc, 84)
        no_perfect_hash, = struct.unpack_from('<I', toc, 96)
        if method_count:
            raise ValueError(base + ': compressed containers are not supported')
        pos = header_size
        self.ids = [toc[pos + i * 12: pos + i * 12 + 12] for i in range(entry_count)]
        pos += entry_count * 12
        self.offlen = [(int.from_bytes(toc[pos + i * 10: pos + i * 10 + 5], 'big'),
                        int.from_bytes(toc[pos + i * 10 + 5: pos + i * 10 + 10], 'big')) for i in range(entry_count)]
        pos += entry_count * 10
        pos += perfect_seeds * 4 + no_perfect_hash * 4
        self.blocks = [int.from_bytes(toc[pos + i * block_entry_size: pos + i * block_entry_size + 5], 'little')
                       for i in range(block_count)]
        pos += block_count * block_entry_size
        self.paths = {}
        if dir_index_size:
            self._read_dir_index(toc, pos, pos + dir_index_size)
        self.ucas = open(base + '.ucas', 'rb')

    def _read_dir_index(self, toc, p, end):
        def fstring():
            nonlocal p
            n, = struct.unpack_from('<i', toc, p)
            p += 4
            if n < 0:
                s = toc[p:p - n * 2].decode('utf-16le')
                p += -n * 2
            else:
                s = toc[p:p + n].decode('latin1')
                p += n
            return s.rstrip('\0')
        mount = fstring()
        n, = struct.unpack_from('<I', toc, p); p += 4
        dirs = [struct.unpack_from('<4I', toc, p + i * 16) for i in range(n)]; p += n * 16
        n, = struct.unpack_from('<I', toc, p); p += 4
        files = [struct.unpack_from('<3I', toc, p + i * 12) for i in range(n)]; p += n * 12
        n, = struct.unpack_from('<I', toc, p); p += 4
        strings = [fstring() for _ in range(n)]
        stack = [(0, mount)]
        while stack:
            d, prefix = stack.pop()
            name, child, sibling, first_file = dirs[d]
            here = prefix + ('' if name == NONE else strings[name] + '/')
            f = first_file
            while f != NONE:
                fname, nxt, entry = files[f]
                self.paths[here + strings[fname]] = entry
                f = nxt
            c = child
            while c != NONE:
                stack.append((c, here))
                c = dirs[c][2]

    def read_entry(self, i):
        off, length = self.offlen[i]
        out = []
        while length > 0:
            bi, within = divmod(off, self.block_size)
            take = min(length, self.block_size - within)
            self.ucas.seek(self.blocks[bi] + within)
            out.append(self.ucas.read(take))
            off += take
            length -= take
        return b''.join(out)

    def chunk_type(self, i):
        return self.ids[i][11]


class Game:
    """The game's main container plus the global one (script objects)."""

    def __init__(self, game_dir):
        paks = os.path.join(game_dir, 'RSDragonwilds', 'Content', 'Paks')
        self.main = Container(os.path.join(paks, 'RSDragonwilds-Windows'))
        self.glob = Container(os.path.join(paks, 'global'))
        self.utoc_path = os.path.join(paks, 'RSDragonwilds-Windows.utoc')
        # package name (/Game/..., /Plugin/...) -> TOC entry of its export bundle. Package names are
        # case-insensitive in the engine (references may spell a folder NPCS where the file says NPCs).
        self.packages = {}
        self._by_lower = {}
        for path, entry in self.main.paths.items():
            if path.endswith(('.uasset', '.umap')) and self.main.chunk_type(entry) == EXPORT_BUNDLE_DATA:
                name = package_name(path)
                self.packages[name] = entry
                self._by_lower[name.lower()] = entry

    def package_bytes(self, name):
        entry = self.packages.get(name)
        if entry is None:
            entry = self._by_lower.get(name.lower())
        return self.main.read_entry(entry) if entry is not None else None


def package_name(path):
    """../../../RSDragonwilds/Content/Maps/X.umap -> /Game/Maps/X; ../../../RSDragonwilds/Plugins/.../P/Content/Y
    -> /P/Y; ../../../Engine/Content/Z -> /Engine/Z; ../../../Engine/Plugins/.../P/Content/W -> /P/W."""
    path = path.rsplit('.', 1)[0]
    parts = path.split('/')
    if 'Content' not in parts:
        return path
    i = len(parts) - 1 - parts[::-1].index('Content')
    root = parts[i - 1]
    if root == 'RSDragonwilds':
        root = 'Game'
    return '/' + root + '/' + '/'.join(parts[i + 1:])
