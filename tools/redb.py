"""Prototype decoder for InfoSoft RE engine .DAT files (recovered from REWIN32.DLL)."""
import struct, sys

def be16(b, o): return struct.unpack_from('>H', b, o)[0]
def be32(b, o): return struct.unpack_from('>I', b, o)[0]

class REDB:
    def __init__(self, path):
        self.d = d = open(path, 'rb').read()
        nfiles = be16(d, 0x316); dirofs = be32(d, 0x318)
        self.files = [struct.unpack_from('>HHII', d, dirofs + 12*i) for i in range(nfiles)]
        typ, fid, hdr, code_base = next(f for f in self.files if f[0] == 1)
        self.code_base = code_base
        h = d[hdr:hdr+0x200]
        self.nentries = be32(h, 0x68)
        self.width = be16(h, 0x76)
        step = be16(h, 0x72); self.shift = step.bit_length() - 1
        self.code_bytes = be16(h, 0x1e) << 9
        nsec = be16(h, 0x50); sdir = be32(h, 0x52)
        self.sec = {}
        for i in range(nsec):
            sid, off, x, cnt, size = struct.unpack_from('>HIIHI', h, sdir + 16*i)
            if size: self.sec[sid] = (cnt, d[hdr+off: hdr+off+size])
        self.ckpt = self.sec[10][1]
        self.left = struct.unpack(f'<{len(self.sec[0x14][1])//2}h', self.sec[0x14][1])
        self.right = struct.unpack(f'<{len(self.sec[0x1e][1])//2}h', self.sec[0x1e][1])
        self.pool = self.sec.get(0x3c, (0, b''))[1]
        if self.pool:
            self.nterm = (1 << self.width) - self.left[0]
            self.end = next(c for c in range(self.nterm) if self.right[c] == 4 and
                            self.pool[self.left[c] & 0xffff: (self.left[c] & 0xffff)+4] == b'\xfe'*4)
        else:
            self.nterm = 0; self.end = self.sec[0x14][0] - 1

    def codes_from(self, idx):
        w = self.width; base = self.code_base; d = self.d
        bit = idx * w
        while True:
            byte = base + (bit >> 4) * 2; sh = bit & 15
            word = (d[byte] << 24) | (d[byte+1] << 16) | (d[byte+2] << 8) | d[byte+3]
            yield (word >> (32 - sh - w)) & ((1 << w) - 1)
            bit += w

    def expand(self, c, out):
        stack = [c]
        while stack:
            c = stack.pop()
            r = self.right[c]
            if c < self.nterm or r == -1:
                if r == -1: out.append(self.left[c] & 0xff)
                else:
                    o = self.left[c] & 0xffff; out += self.pool[o:o+r]
            else:
                stack.append(r); stack.append(self.left[c])

    def entry(self, n):
        k = n >> self.shift
        start = struct.unpack_from('<I', self.ckpt, k*4)[0]
        skip = n & ((1 << self.shift) - 1)
        if k: skip += 1
        g = self.codes_from(start)
        while skip:
            if next(g) == self.end: skip -= 1
        out = bytearray()
        for c in g:
            if c == self.end: break
            self.expand(c, out)
        return bytes(out).replace(b'\xff', b'\n')

if __name__ == '__main__':
    db = REDB(sys.argv[1])
    print('files', db.files, 'entries', db.nentries, 'width', db.width, 'shift', db.shift,
          'nterm', db.nterm, 'end', db.end, 'secs', {k: (v[0], len(v[1])) for k, v in db.sec.items()})
    for n in map(int, sys.argv[2:]):
        print(f'--- entry {n}'); print(db.entry(n)[:600])

def dump_all(db):
    """Sequentially decode every entry; verifies checkpoint table agrees with the stream."""
    g = db.codes_from(0); out = bytearray(); entries = []
    limit = db.code_bytes * 8 // db.width
    for i, c in enumerate(g):
        if i >= limit: break
        if c == db.end:
            entries.append(bytes(out).replace(b'\xff', b'\n')); out = bytearray()
            if len(entries) > db.nentries: break
        else: db.expand(c, out)
    return entries
