#!/usr/bin/env python3
"""Assemble the stock-format .fds image for the 240pee FDS port.

Inputs (produced by ld65 with fds.cfg, in the nes/ directory):
  bank0.bin bank1.bin bank2.bin fixed.bin  (full 16K areas, $FF filled)
  fdsmap.txt                               (segment extents + exports)

Each bank file is trimmed to its last used byte (from the map's
segment list).  The side holds six files:

  phys#  ID  name      dest    role
  0      1   BANK2     $6000   main code bank (boot + runtime)
  1      4   BANK0     $6000   compressed graphics data (runtime)
  2      5   BANK1     $6000   gate data (runtime)
  3      0   FIXED     $A000   fixed bank (boot)
  4      2   VECTORS   $DFF6   BIOS vector table (boot)
  5      3   -BYPASS-  $2000   $90: enable NMIs, skipping the BIOS
                               approval check (boot)
  6      6   PAD       $6000   2KB of zeros (never loaded).  Must sit
                               after -BYPASS-: the BIOS is still busy
                               skipping this file when the first vblank
                               NMI fires, which is what lets the bypass
                               pre-empt the approval check (error $20).
                               Without a trailing file the BIOS finishes
                               loading and runs the check first.
  7      48  TAIL      $6000   well-formed trailing file (never
                               loaded), so the block stream stays
                               well-formed all the way to the side
                               end instead of trailing off into
                               zero padding after PAD.

Boot files are exactly those with ID <= boot code (3), per the FDS
BIOS rule.  Block layout follows the documented FDS disk format;
no CRC bytes are stored in the .fds (as usual for the format).
"""
import os
import re
import struct
import sys

# Inputs and output live in the nes/ directory (this script is in
# nes/tools/), regardless of the working directory or checkout path.
BASE = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..') + '/'
SIDE_SIZE = 65500


def parse_map():
    text = open(BASE + 'fdsmap.txt').read()
    segs = {}
    m = re.search(r'Segment list:\n-+\n(.*?)\n\n', text, re.S)
    for line in m.group(1).splitlines():
        parts = line.split()
        if len(parts) >= 4 and parts[0] != 'Name':
            segs[parts[0]] = (int(parts[1], 16), int(parts[2], 16))
    syms = {}
    dbg = open(BASE + '240pee-fds.dbg').read()
    for name in ('nmi_handler', 'fds_boot', 'irq_handler'):
        mm = re.search(r'name="' + name + r'",.*?val=0x([0-9A-F]+)', dbg)
        syms[name] = int(mm.group(1), 16)
    return segs, syms


def trim(filename, size):
    data = open(BASE + filename, 'rb').read()
    return data[:size]


def main():
    segs, syms = parse_map()
    bank0 = trim('bank0.bin', segs['BANK00'][1] - 0x6000 + 1)
    bank1 = trim('bank1.bin', segs['GATEDATA'][1] - 0x6000 + 1)
    bank2 = trim('bank2.bin', segs['HELPDATA'][1] - 0x6000 + 1)
    fixed = trim('fixed.bin', segs['PB53TABLES'][1] - 0xA000 + 1)
    vec = b''.join(struct.pack('<H', a) for a in (
        syms['nmi_handler'], syms['nmi_handler'], syms['fds_boot'],
        syms['fds_boot'], syms['irq_handler']))
    files = [
        (0, 1, 'BANK2   ', 0x6000, 0, bank2),
        (1, 4, 'BANK0   ', 0x6000, 0, bank0),
        (2, 5, 'BANK1   ', 0x6000, 0, bank1),
        (3, 0, 'FIXED   ', 0xA000, 0, fixed),
        (4, 2, 'VECTORS ', 0xDFF6, 0, vec),
        (5, 3, '-BYPASS-', 0x2000, 0, b'\x90'),
        (6, 6, 'PAD     ', 0x6000, 0, bytes(2048)),
        (7, 48, 'TAIL    ', 0x6000, 0, bytes(256)),
    ]
    n = len(files)
    info = bytearray(56)
    info[0] = 1
    info[1:15] = b'*NINTENDO-HVC*'
    info[15] = 0
    info[16:20] = b'240P'
    info[20] = 0x20  # game type: normal
    info[25] = 3     # boot read file code: IDs 0-3 load at boot
    info[26:31] = b'\xff' * 5
    info[31:34] = bytes([0x34, 0x07, 0x13])
    info[34:44] = bytes([0x49, 0x61, 0, 0, 2, 0, 0, 0, 0, 0])
    info[44:47] = bytes([0x34, 0x10, 0x08])
    info[47:56] = bytes([0, 0x80, 0, 0, 7, 0, 0, 0, 0])
    side = bytearray()
    side += bytes(info)
    side += bytes([2, n])
    for num, fid, name, addr, ftype, data in files:
        hdr = struct.pack('<BBB', 3, num, fid)
        hdr += name.encode('ascii')
        hdr += struct.pack('<HHB', addr, len(data), ftype)
        assert len(hdr) == 16
        side += hdr
        side += b'\x04' + data
    assert len(side) <= SIDE_SIZE, len(side)
    side += bytes(SIDE_SIZE - len(side))
    header = b'FDS\x1a' + bytes([1]) + bytes(11)
    out = BASE + '240pee-fds.fds'
    open(out, 'wb').write(header + bytes(side))
    print(f'{out}: side {len(side)} bytes used of {SIDE_SIZE}')
    for num, fid, name, addr, ftype, data in files:
        print(f'  phys {num} id {fid} {name!r} addr ${addr:04X} '
              f'size {len(data)}')


if __name__ == '__main__':
    sys.exit(main())
