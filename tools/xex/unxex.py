import struct, sys
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes

RETAIL_KEY = bytes([0x20,0xB1,0x85,0xA5,0x9D,0x28,0xFD,0xC3,
                    0x40,0x58,0x3F,0xBB,0x08,0x96,0xBF,0x91])

def aes_cbc_dec(key, data, iv=b'\0'*16):
    d = Cipher(algorithms.AES(key), modes.CBC(iv)).decryptor()
    return d.update(data) + d.finalize()

def parse(path):
    d = open(path,'rb').read()
    assert d[:4] == b'XEX2'
    flags, hsize, resv, sec_off, opt_cnt = struct.unpack('>IIIII', d[4:24])
    opts = {}
    for i in range(opt_cnt):
        k, v = struct.unpack('>II', d[24+i*8:32+i*8])
        opts[k] = v
    return d, hsize, sec_off, opts

d, hsize, sec_off, opts = parse(sys.argv[1])
print('header_size', hex(hsize), 'security_offset', hex(sec_off))

sec = sec_off
sec_hdr_size, image_size = struct.unpack('>II', d[sec:sec+8])
load_address = struct.unpack('>I', d[sec+0x110:sec+0x114])[0]
aes_key = d[sec+0x150:sec+0x160]
print('security hdr', hex(sec_hdr_size), 'image_size', hex(image_size), 'load', hex(load_address))
print('aes_key', aes_key.hex())

session_key = aes_cbc_dec(RETAIL_KEY, aes_key)
print('session_key', session_key.hex())

ff = opts[0x3FF]
info_size, enc, comp = struct.unpack('>IHH', d[ff:ff+8])
print('file_format: info_size', info_size, 'enc', enc, 'comp', comp)

src = hsize
p = src
out = bytearray()
iv = b'\0'*16
blocks = (info_size - 8)//8
for n in range(blocks):
    ds, zs = struct.unpack('>II', d[ff+8+n*8: ff+16+n*8])
    chunk = d[p:p+ds]
    if enc == 1:
        dec = Cipher(algorithms.AES(session_key), modes.CBC(iv)).decryptor()
        plain = dec.update(chunk) + dec.finalize()
        iv = chunk[-16:] if len(chunk) >= 16 else iv
    else:
        plain = chunk
    out += plain
    out += b'\0'*zs
    p += ds
    print(f'  block {n}: data={ds} zero={zs} -> out {len(out)}')

open(sys.argv[2],'wb').write(out)
print('imagen escrita:', len(out), 'bytes; esperado', hex(image_size))
open(sys.argv[2]+'.meta','w').write(f'{load_address} {image_size}')
