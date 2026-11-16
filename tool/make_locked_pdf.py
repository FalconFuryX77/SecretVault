"""Writes a two-page PDF protected with a user password (PDF Standard
Security Handler, revision 2: RC4, 40-bit), for the viewer tests.

usage: python make_locked_pdf.py out.pdf password
"""
import hashlib
import sys

PAD = bytes.fromhex('28BF4E5E4E758A4164004E56FFFA01082E2E00B6D0683E802F0CA9FE6453697A')


def rc4(key, data):
    s = list(range(256))
    j = 0
    for i in range(256):
        j = (j + s[i] + key[i % len(key)]) & 0xFF
        s[i], s[j] = s[j], s[i]
    i = j = 0
    out = bytearray()
    for b in data:
        i = (i + 1) & 0xFF
        j = (j + s[i]) & 0xFF
        s[i], s[j] = s[j], s[i]
        out.append(b ^ s[(s[i] + s[j]) & 0xFF])
    return bytes(out)


def pad(pw):
    return (pw.encode('latin-1') + PAD)[:32]


def main(out, user_pw, owner_pw='owner-only'):
    file_id = hashlib.md5(b'vault test document').digest()
    o = rc4(hashlib.md5(pad(owner_pw)).digest()[:5], pad(user_pw))
    p = -44
    key = hashlib.md5(pad(user_pw) + o + p.to_bytes(4, 'little', signed=True) + file_id).digest()[:5]
    u = rc4(key, PAD)

    def obj_key(num):
        return hashlib.md5(key + num.to_bytes(3, 'little') + (0).to_bytes(2, 'little')).digest()[:10]

    pages = ['Payroll ledger 2026', 'Account 7731 paid twice']
    objs = {}
    objs[1] = b'<< /Type /Catalog /Pages 2 0 R >>'
    kids = ' '.join(f'{3 + i * 2} 0 R' for i in range(len(pages)))
    objs[2] = f'<< /Type /Pages /Kids [{kids}] /Count {len(pages)} >>'.encode()
    font = 3 + len(pages) * 2
    for i, text in enumerate(pages):
        page, content = 3 + i * 2, 4 + i * 2
        objs[page] = (f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {content} 0 R '
                      f'/Resources << /Font << /F1 {font} 0 R >> >> >>').encode()
        stream = f'BT /F1 28 Tf 72 700 Td ({text}) Tj ET'.encode()
        enc = rc4(obj_key(content), stream)
        objs[content] = b'<< /Length ' + str(len(enc)).encode() + b' >>\nstream\n' + enc + b'\nendstream'
    objs[font] = b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>'
    enc_obj = font + 1
    objs[enc_obj] = (b'<< /Filter /Standard /V 1 /R 2 /O <' + o.hex().encode() + b'> /U <' + u.hex().encode()
                     + b'> /P ' + str(p).encode() + b' >>')
    data = bytearray(b'%PDF-1.4\n')
    offsets = {}
    for n in sorted(objs):
        offsets[n] = len(data)
        data += f'{n} 0 obj\n'.encode() + objs[n] + b'\nendobj\n'
    xref = len(data)
    size = max(objs) + 1
    data += f'xref\n0 {size}\n0000000000 65535 f \n'.encode()
    for n in range(1, size):
        data += f'{offsets[n]:010d} 00000 n \n'.encode()
    fid = file_id.hex().encode()
    data += (b'trailer\n<< /Size ' + str(size).encode() + b' /Root 1 0 R /Encrypt ' + str(enc_obj).encode()
             + b' 0 R /ID [<' + fid + b'> <' + fid + b'>] >>\nstartxref\n' + str(xref).encode() + b'\n%%EOF\n')
    open(out, 'wb').write(data)


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
