"""MEDIA.FIL blob store + Pegasus 'PIC' JPEG repair (recovered from CRL32.EXE / PEGASUS.DLL)."""
import struct, sys

# Base quantisation tables from PEGASUS.DLL @0x430750 / @0x430790 (zigzag order; == JPEG Annex K)
QBASE = [
 bytes([16,11,12,14,12,10,16,14,13,14,18,17,16,19,24,40,26,24,22,22,24,49,35,37,29,40,58,51,61,60,57,51,
        56,55,64,72,92,78,64,68,87,69,55,56,80,109,81,87,95,98,103,104,103,62,77,113,121,112,100,120,92,101,103,99]),
 bytes([17,18,18,24,21,24,47,26,26,47,99,66,56,66,99,99] + [99]*48),
]
# Standard Annex K Huffman tables (class<<4|id, bits[16], vals)
HUFF = [
 (0x00, [0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0], list(range(12))),
 (0x10, [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d], bytes.fromhex(
  '01020300041105122131410613516107227114328191a1082342b1c11552d1f02433627282090a161718191a25262728292a3435363738393a434445464748494a535455565758595a636465666768696a737475767778797a838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae1e2e3e4e5e6e7e8e9eaf1f2f3f4f5f6f7f8f9fa')),
 (0x01, [0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0], list(range(12))),
 (0x11, [0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77], bytes.fromhex(
  '000102031104052131061241510761711322328108144291a1b1c109233352f0156272d10a162434e125f11718191a262728292a35363738393a434445464748494a535455565758595a636465666768696a737475767778797a82838485868788898a92939495969798999aa2a3a4a5a6a7a8a9aab2b3b4b5b6b7b8b9bac2c3c4c5c6c7c8c9cad2d3d4d5d6d7d8d9dae2e3e4e5e6e7e8e9eaf2f3f4f5f6f7f8f9fa')),
]

def seg(marker, payload): return b'\xff' + bytes([marker]) + struct.pack('>H', len(payload) + 2) + payload

def iter_records(path):
    with open(path, 'rb') as f:
        while True:
            h = f.read(26)
            if len(h) < 26: return
            name = h[:14].split(b'\0')[0].decode('latin-1'); size = struct.unpack_from('<I', h, 14)[0]
            yield name, f.tell(), size
            f.seek(size, 1)

def repair_jpeg(j):
    """Insert the DQT/DHT segments Pegasus omits, derived from its APP1 'PIC' quality bytes."""
    assert j[:2] == b'\xff\xd8'
    out = bytearray(b'\xff\xd8'); i = 2; ql = qc = 32; have_dqt = have_dht = False
    while i < len(j):
        assert j[i] == 0xff, hex(i)
        m = j[i+1]; L = struct.unpack_from('>H', j, i+2)[0]; body = j[i+4:i+2+L]
        if m == 0xe1 and body[:4] == b'PIC\0': ql, qc = body[5], body[6]; i += 2 + L; continue
        if m == 0xdb: have_dqt = True
        if m == 0xc4: have_dht = True
        if m in (0xc0, 0xda) and not have_dqt:
            for tid, (base, q) in enumerate(zip(QBASE, (ql, qc))):
                out += seg(0xdb, bytes([tid]) + bytes(min(255, max(1, (b*q) >> 5)) for b in base))
            have_dqt = True
        if m == 0xda:
            if not have_dht:
                for tc, bits, vals in HUFF: out += seg(0xc4, bytes([tc]) + bytes(bits) + bytes(vals))
            out += j[i:]; return bytes(out)
        out += j[i:i+2+L]; i += 2 + L
    return bytes(out)

def picture(blob):
    """blob = BITMAPFILEHEADER + 68-byte BITMAPINFOHEADER(+JPEG fields) + palette + JFIF stream."""
    assert blob[:2] == b'BM'
    off = struct.unpack_from('<I', blob, 10)[0]
    w, h = struct.unpack_from('<ii', blob, 18); comp = blob[30:34]
    if comp == b'JPEG': return 'jpg', repair_jpeg(blob[off:]), (w, abs(h))
    return 'bmp', blob, (w, abs(h))

if __name__ == '__main__':
    import os
    src, out = sys.argv[1], sys.argv[2]; os.makedirs(out, exist_ok=True)
    lim = int(sys.argv[3]) if len(sys.argv) > 3 else 10**9
    with open(src, 'rb') as f:
        for k, (name, off, size) in enumerate(iter_records(src)):
            if k >= lim: break
            f.seek(off); blob = f.read(size)
            ext, data, dims = picture(blob)
            open(os.path.join(out, name.rsplit('.', 1)[0] + '.' + ext), 'wb').write(data)
            print(name, size, ext, dims)
