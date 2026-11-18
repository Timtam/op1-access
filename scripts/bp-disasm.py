"""Kismet bytecode disassembler for cooked UE 4.18 Blueprints (Octopath Traveler's pak,
extracted with repak). One statement per line with its in-memory offset; jump targets are
in-memory offsets too (an object reference takes 8 bytes there, 4 on disk). Names come
from the package: self.X = a member, L.X = a local, out.X = an out parameter.
Usage: python -I scripts/bp-disasm.py <x.uasset> [function ...]   (no function = all)
Example: what opens the skip widget -- EventManagerBP.uasset, PlayAfterFadeOut.
Uses level-dump.py's Package (same folder) for names, imports and exports.
"""
import importlib.util
import os
import struct
import sys

spec = importlib.util.spec_from_file_location(
    "leveldump", os.path.join(os.path.dirname(os.path.abspath(__file__)), "level-dump.py"))
ld = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ld)
if len(sys.argv) < 2:
    sys.exit(__doc__)
path = sys.argv[1]
pkg = ld.Package(path)
pkg.e = open(path[:-7] + ".uexp", "rb").read()
want = set(sys.argv[2:])


def objname(idx):
    if idx == 0:
        return "null"
    if idx < 0:
        im = pkg.imports[-idx - 1]
        return im["name"]
    return pkg.exports[idx - 1]["name"]


class Dis:
    def __init__(self, b):
        self.b, self.p, self.mem = b, 0, 0

    def u8(self):
        v = self.b[self.p]
        self.p += 1
        self.mem += 1
        return v

    def u16(self):
        v = struct.unpack_from("<H", self.b, self.p)[0]
        self.p += 2
        self.mem += 2
        return v

    def i32(self):
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        self.mem += 4
        return v

    def i64(self):
        v = struct.unpack_from("<q", self.b, self.p)[0]
        self.p += 8
        self.mem += 8
        return v

    def f32(self):
        v = struct.unpack_from("<f", self.b, self.p)[0]
        self.p += 4
        self.mem += 4
        return v

    def obj(self):
        v = struct.unpack_from("<i", self.b, self.p)[0]
        self.p += 4
        self.mem += 8
        return objname(v)

    def fname(self):
        i, n = struct.unpack_from("<ii", self.b, self.p)
        self.p += 8
        self.mem += 12   # FScriptName in memory: ComparisonIndex, DisplayIndex, Number
        s = pkg.names[i] if 0 <= i < len(pkg.names) else "?%d" % i
        return s if n == 0 else "%s_%d" % (s, n - 1)

    def cstr(self):
        e = self.b.index(b"\0", self.p)
        s = self.b[self.p:e].decode("latin-1")
        self.mem += e + 1 - self.p
        self.p = e + 1
        return s

    def wstr(self):
        q = self.p
        while self.b[q:q + 2] != b"\0\0":
            q += 2
        s = self.b[self.p:q].decode("utf-16-le")
        self.mem += q + 2 - self.p
        self.p = q + 2
        return s

    def params(self):
        out = []
        while True:
            if self.b[self.p] == 0x16:
                self.u8()
                return out
            out.append(self.expr())

    def expr(self):
        op = self.u8()
        if op == 0x00: return "L." + self.obj()
        if op == 0x01: return "self." + self.obj()
        if op == 0x02: return "def." + self.obj()
        if op == 0x04: return "return " + self.expr()
        if op == 0x06: return "jump %04x" % self.i32()
        if op == 0x07:
            t = self.i32()
            return "if not (%s) jump %04x" % (self.expr(), t)
        if op == 0x09:
            self.u16(); self.u8()
            return "assert " + self.expr()
        if op == 0x0B: return "nothing"
        if op == 0x0F:
            self.obj()
            a = self.expr()
            return "%s = %s" % (a, self.expr())
        if op == 0x12 or op == 0x19 or op == 0x1A:
            o = self.expr()
            self.i32()
            self.obj()
            return "%s->%s" % (o, self.expr())
        if op == 0x13: c = self.obj(); return "MetaCast<%s>(%s)" % (c, self.expr())
        if op == 0x14 or op == 0x5F or op == 0x60 or op == 0x43 or op == 0x44:
            a = self.expr()
            return "%s = %s" % (a, self.expr())
        if op == 0x15: return "EndParmValue"
        if op == 0x17: return "self"
        if op == 0x18: self.i32(); return "skip " + self.expr()
        if op == 0x1B or op == 0x45:
            f = self.fname()
            return "%s(%s)" % (f, ", ".join(self.params()))
        if op == 0x1C or op == 0x46 or op == 0x68 or op == 0x63:
            f = self.obj()
            return "%s(%s)" % (f, ", ".join(self.params()))
        if op == 0x1D: return str(self.i32())
        if op == 0x1E: return "%gf" % self.f32()
        if op == 0x1F: return repr(self.cstr())
        if op == 0x20: return "obj:" + self.obj()
        if op == 0x21: return "name:" + self.fname()
        if op == 0x22 or op == 0x23: return "vec(%g,%g,%g)" % (self.f32(), self.f32(), self.f32())
        if op == 0x24: return "byte:%d" % self.u8()
        if op == 0x25: return "0"
        if op == 0x26: return "1"
        if op == 0x27: return "true"
        if op == 0x28: return "false"
        if op == 0x29:
            k = self.u8()
            if k == 0: return 'text""'
            if k == 1:
                s = self.expr(); key = self.expr(); ns = self.expr()
                return "text(%s, key=%s, ns=%s)" % (s, key, ns)
            if k == 2 or k == 3: return "text(%s)" % self.expr()
            if k == 4:
                t = self.obj(); a = self.expr(); b2 = self.expr()
                return "strtable(%s, %s, %s)" % (t, a, b2)
            return "text?%d" % k
        if op == 0x2A: return "None"
        if op == 0x2B: return "transform(" + ",".join("%g" % self.f32() for _ in range(10)) + ")"
        if op == 0x2C: return str(self.u8())
        if op == 0x2D: return "NoInterface"
        if op == 0x2E: c = self.obj(); return "Cast<%s>(%s)" % (c, self.expr())
        if op == 0x2F:
            s = self.obj(); self.i32()
            items = []
            while self.b[self.p] != 0x30:
                items.append(self.expr())
            self.u8()
            return "%s{%s}" % (s, ", ".join(items))
        if op == 0x31:
            a = self.expr()
            items = []
            while self.b[self.p] != 0x32:
                items.append(self.expr())
            self.u8()
            return "%s = [%s]" % (a, ", ".join(items))
        if op == 0x34: return repr(self.wstr())
        if op == 0x35 or op == 0x36: return str(self.i64())
        if op == 0x38: k = self.u8(); return "prim%d(%s)" % (k, self.expr())
        if op == 0x42: pr = self.obj(); return "%s.%s" % (self.expr(), pr)
        if op == 0x48: return "out." + self.obj()
        if op == 0x4B: return "delegate:" + self.fname()
        if op == 0x4C: return "push %04x" % self.i32()
        if op == 0x4D: return "pop"
        if op == 0x4E: return "jump computed " + self.expr()
        if op == 0x4F: return "pop if not (%s)" % self.expr()
        if op == 0x51: return "iface(%s)" % self.expr()
        if op in (0x52, 0x54, 0x55): c = self.obj(); return "icast<%s>(%s)" % (c, self.expr())
        if op == 0x53: return "end"
        if op == 0x5A or op == 0x5E or op == 0x50: return "trace"
        if op == 0x5B: return "skipoff %04x" % self.i32()
        if op == 0x5C or op == 0x62:
            a = self.expr()
            return "%s += %s" % (a, self.expr())
        if op == 0x5D: return "clear " + self.expr()
        if op == 0x61:
            f = self.fname(); a = self.expr(); o = self.expr()
            return "bind %s(%s, %s)" % (f, a, o)
        if op == 0x64: pr = self.obj(); return "frame.%s = %s" % (pr, self.expr())
        if op == 0x65:
            self.obj(); n = self.i32()
            items = []
            while self.b[self.p] != 0x66:
                items.append(self.expr())
            self.u8()
            return "[%s]" % ", ".join(items)
        if op == 0x67: return "soft(%s)" % self.expr()
        if op == 0x69:
            n = self.u16(); self.i32()
            idx = self.expr()
            cases = []
            for _ in range(n):
                c = self.expr(); self.i32(); r = self.expr()
                cases.append("%s: %s" % (c, r))
            d = self.expr()
            return "switch(%s){%s; default: %s}" % (idx, "; ".join(cases), d)
        if op == 0x6A:
            k = self.u8()
            if k == 4: self.fname()
            return "instr%d" % k
        if op == 0x6B:
            a = self.expr()
            return "%s[%s]" % (a, self.expr())
        raise ValueError("opcode %02x at %d" % (op, self.p - 1))


for e in pkg.exports:
    if pkg.cls(e) != "Function" or (want and e["name"] not in want):
        continue
    off = e["off"] - pkg.total
    b = pkg.e[off:off + e["size"]]
    n = struct.unpack_from("<i", b, 0x10)[0]
    start = 0x14 + 4 * n
    memsize, stsize = struct.unpack_from("<ii", b, start)
    code = b[start + 8:start + 8 + stsize]
    print("== %s (%d bytes on disk, %d in memory)" % (e["name"], stsize, memsize))
    d = Dis(code)
    while d.p < len(code):
        at = d.mem
        try:
            s = d.expr()
        except Exception as ex:  # noqa
            print("  !! %s" % ex)
            break
        print("  %04x  %s" % (at, s))
