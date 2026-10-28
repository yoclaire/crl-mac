import struct, sys
class PE:
    def __init__(s, p):
        d = s.d = open(p, 'rb').read()
        pe = struct.unpack_from('<I', d, 0x3c)[0]; n = struct.unpack_from('<H', d, pe+6)[0]
        opt = struct.unpack_from('<H', d, pe+20)[0]; s.base = struct.unpack_from('<I', d, pe+24+28)[0]
        s.secs = [struct.unpack_from('<8sIIII', d, pe+24+opt+40*i) for i in range(n)]
    def off(s, va):
        for _, vs, v, rs, ro in s.secs:
            if s.base+v <= va < s.base+v+max(vs, rs): return ro + va - s.base - v
    def u32(s, va): return struct.unpack_from('<I', s.d, s.off(va))[0]
    def bytes(s, va, n): o = s.off(va); return s.d[o:o+n]
