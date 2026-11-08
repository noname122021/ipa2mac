#!/usr/bin/env python3
import struct
import sys

def parse_header(data: bytearray):
    magic = struct.unpack_from("<I", data, 0)[0]
    if magic == 0xfeedfacf:
        return "<", struct.unpack_from("<II", data, 16)
    if magic == 0xcffaedfe:
        return ">", struct.unpack_from(">II", data, 16)
    sys.exit("[-] Not a 64-bit Mach-O binary")

def has_dylib(data: bytearray, endian: str, ncmds: int, target: str) -> bool:
    offset = 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(f"{endian}II", data, offset)
        name_off = struct.unpack_from(f"{endian}I", data, offset + 8)[0] if cmd in (0xc, 0x80000018, 0xd, 0x18) else 0
        name = data[offset + name_off : offset + cmdsize].split(b"\x00", 1)[0].decode("utf-8", "ignore") if name_off else ""
        if name == target:
            return True
        offset += cmdsize
    return False

def insert_dylib(bin_path: str, dylib_path: str) -> None:
    with open(bin_path, "rb") as f:
        data = bytearray(f.read())
    endian, (ncmds, sizeofcmds) = parse_header(data)
    if has_dylib(data, endian, ncmds, dylib_path):
        print(f"[*] {dylib_path} already present")
        return
    cmds_end = 32 + sizeofcmds
    path_bytes = dylib_path.encode("utf-8") + b"\x00"
    cmdsize = (24 + len(path_bytes) + 7) & ~7
    pad = cmdsize - 24 - len(path_bytes)
    if len(data) < cmds_end + cmdsize or data[cmds_end : cmds_end + cmdsize] != b"\x00" * cmdsize:
        sys.exit(f"[-] Not enough zero-padding to insert LC_LOAD_DYLIB ({cmdsize} bytes needed)")
    cmd = struct.pack(f"{endian}IIIIII", 0xc, cmdsize, 24, 2, 0x10000, 0x10000) + path_bytes + (b"\x00" * pad)
    data[cmds_end : cmds_end + cmdsize] = cmd
    struct.pack_into(f"{endian}II", data, 16, ncmds + 1, sizeofcmds + cmdsize)
    with open(bin_path, "wb") as f:
        f.write(data)
    print(f"[+] Injected {dylib_path}")

if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(f"Usage: {sys.argv[0]} <binary> <dylib_path>")
    insert_dylib(sys.argv[1], sys.argv[2])
