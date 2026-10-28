"""Media catalogue (MEDIA.DBS) reader. Trio Systems C-Index record store; records are
self-validating so we scan instead of walking the B-tree."""
import struct, collections

def scan_dbs(path):
    d = open(path, 'rb').read(); recs = {}
    for i in range(len(d) - 23):
        if d[i+1] != 1 or d[i+2] != 0x80: continue
        L = d[i]; n = L + 1
        if n < 78 or (n - 22) % 56 or i + n > len(d): continue
        recid, link, npic, nsnd, other, flag, varlen = struct.unpack_from('<IIHHHBI', d, i+3)
        if varlen != n - 11: continue
        items = []
        for k in range((n - 22) // 56):
            o = i + 22 + 56*k
            items.append((d[o], d[o+1:o+52].split(b'\0')[0].decode('cp1252'), struct.unpack_from('<I', d, o+52)[0]))
        if npic + nsnd + other != len(items): continue
        recs.setdefault(recid, (link >> 24, link & 0xffffff, items, i))
    return recs

if __name__ == '__main__':
    import sys
    r = scan_dbs(sys.argv[1])
    print(len(r), 'records')
    print(collections.Counter(v[0] for v in r.values()))
    print(collections.Counter(t for v in r.values() for t, _, _ in v[2]))
    for k in sorted(r)[:5] + sorted(r)[-5:]: print(k, r[k][:3])

def scan_lnk(path):
    """MEDIA.LNK: media file name -> [(db_code, entry)]."""
    import re
    d = open(path, 'rb').read(); out = {}
    for m in re.finditer(rb'\x01\x80\x00\x00\x00\x00([A-Z0-9_-]{1,8}\.[A-Z]{3})\x00', d):
        name = m.group(1).decode(); p = m.end(); n = d[p]; L = d[m.start() - 1]
        if L + 1 != 1 + 6 + len(name) + 1 + 8 + 8*n: continue   # self-check rejects stale/index copies
        out.setdefault(name, [struct.unpack_from('<II', d, p + 8 + 8*k) for k in range(n)])
    return out

def scan_utl(path):
    """MEDIA.UTL: picture/map file name -> (MEDIA.FIL offset, caption)."""
    import re
    d = open(path, 'rb').read(); out = {}
    for m in re.finditer(rb'\x01\x80\x00\x00\x00\x00([A-Z0-9_-]{1,8}\.(?:PIC|MAP))\x00(....)([^\x00]*)\x00', d, re.S):
        out.setdefault(m.group(1).decode(), (struct.unpack('<I', m.group(2))[0], m.group(3).decode('cp1252')))
    return out

def scan_ctg(path):
    """MEDIA.CTG: gallery category -> [picture file names]."""
    import re
    d = open(path, 'rb').read(); out = {}
    for m in re.finditer(rb'\x01\x80\x00\x00\x00\x00([^\x00@]{2,40})\x00(....)', d, re.S):
        n = struct.unpack('<I', m.group(2))[0]; p = m.end()
        if not 0 < n < 2000: continue
        names = [d[p+14*k: p+14*k+14].split(b'\0')[0] for k in range(n)]
        if all(re.fullmatch(rb'[A-Z0-9_-]{1,8}\.(PIC|MAP)', x) for x in names):
            out.setdefault(m.group(1).decode('cp1252'), [x.decode() for x in names])
    return out
