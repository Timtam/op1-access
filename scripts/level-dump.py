"""What a level holds where: blocking volumes, bridges, triggers -- for debugging the walker.

The game's invisible walls are BlockingVolume actors in the cooked area levels: convex
"Box brushes" the router's channel-0 traces don't see (only the character's own collision
does). On the path to the Maiya caves (F_Sea_1_1) they fill the water from z -475 to 1525,
and the bridge's deck is four thin ones (z 425..507). This lists them in world coordinates,
next to the actors (static meshes, blueprints) with their positions.

1. Extract a level from the game's pak (repak, see tools/), both files:
       repak unpack -q -o <out> -i Octopath_Traveler/Content/Level/Area/Sea/F_Sea_1_1.umap
           -i Octopath_Traveler/Content/Level/Area/Sea/F_Sea_1_1.uexp "<game>/.../Paks/...pak"
2. python -I -X utf8 scripts/level-dump.py <out>/.../F_Sea_1_1.umap volumes
       ... classes              how many exports of each class
       ... volumes              blocking volumes: actor, then each convex in world x/y/z
       ... actors [text]        actors with class, mesh, location, yaw, scale (filtered)

UE 4.18 unversioned cooked packages (as scripts/level-links.py): the summary, name map,
imports and exports, then each export's tagged properties. Transforms: the root
component's RelativeLocation/Rotation/Scale3D (an attached component adds its parent's
location; parents' rotation is applied to the yaw only). A volume's shape: its
BrushComponent's BrushBodySetup -> AggGeom -> ConvexElems -> VertexData (local space).
"""
import math
import os
import struct
import sys
from collections import Counter

BIN = {"Vector": "<3f", "Rotator": "<3f", "Vector2D": "<2f", "Quat": "<4f", "IntPoint": "<2i",
       "LinearColor": "<4f", "Color": "<4B", "Guid": "<4I", "Vector4": "<4f", "IntVector": "<3i"}


class Package:
    def __init__(self, umap):
        self.h = open(umap, "rb").read()
        uexp = umap[:-5] + ".uexp"
        self.e = open(uexp, "rb").read() if os.path.exists(uexp) else b""
        b, self.o = self.h, 0
        assert self.i32() == -1641380927, "not a package"  # 0x9E2A83C1
        legacy = self.i32()
        if legacy != -4:
            self.i32()
        ver = self.i32() or 516  # unversioned: the engine's own, 4.18
        self.i32()
        if legacy <= -2:
            n = self.i32()
            self.o += n * 8 if legacy == -2 else n * 20
        self.total = self.i32()
        self.fstr()
        self.i32()
        name_count, name_off = self.i32(), self.i32()
        self.i32(), self.i32()  # gatherable text
        exp_count, exp_off = self.i32(), self.i32()
        imp_count, imp_off = self.i32(), self.i32()
        self.o = name_off
        self.names = []
        for _ in range(name_count):
            self.names.append(self.fstr())
            if ver >= 504:
                self.o += 4  # name hashes
        self.o = imp_off
        self.imports = []
        for _ in range(imp_count):
            self.fn()  # class package
            cls = self.fn()
            outer = self.i32()
            self.imports.append({"class": cls, "outer": outer, "name": self.fn()})
        self.o = exp_off
        self.exports = []
        for _ in range(exp_count):
            ci, _si = self.i32(), self.i32()
            if ver >= 508:
                self.i32()  # template
            outer, name = self.i32(), self.fn()
            self.i32()  # flags
            if ver >= 511:
                size, off = self.i64(), self.i64()
            else:
                size, off = self.i32(), self.i32()
            self.o += 12 + 16 + 4
            if ver >= 365:
                self.o += 4
            if ver >= 485:
                self.o += 4
            if ver >= 507:
                self.o += 20
            self.exports.append({"class": ci, "outer": outer, "name": name, "size": size, "off": off})

    # header readers
    def i32(self):
        v = struct.unpack_from("<i", self.h, self.o)[0]
        self.o += 4
        return v

    def i64(self):
        v = struct.unpack_from("<q", self.h, self.o)[0]
        self.o += 8
        return v

    def fstr(self):
        n = self.i32()
        if n == 0:
            return ""
        if n > 0:
            s = self.h[self.o:self.o + n - 1].decode("latin-1")
            self.o += n
            return s
        s = self.h[self.o:self.o + (-n - 1) * 2].decode("utf-16-le")
        self.o += -n * 2
        return s

    def fn(self):
        i, n = self.i32(), self.i32()
        return self.name(i, n)

    def name(self, i, n):
        s = self.names[i] if 0 <= i < len(self.names) else "?%d" % i
        return s if n == 0 else "%s_%d" % (s, n - 1)

    def ref(self, idx):
        if idx > 0:
            return self.exports[idx - 1]["name"]
        if idx < 0:
            return self.imports[-idx - 1]["name"]
        return None

    def cls(self, ex):
        c = ex["class"]
        if c < 0:
            return self.imports[-c - 1]["name"]
        return "export:" + self.exports[c - 1]["name"] if c > 0 else "?"

    def props(self, i):
        ex = self.exports[i]
        off = ex["off"] - self.total
        b = self.e[off:off + ex["size"]]
        try:
            return Props(self, b).read(0, len(b))[0]
        except Exception as err:  # an unknown layout: what was read so far is lost
            return {"_err": str(err)}


class Props:
    def __init__(self, pkg, b):
        self.p, self.b = pkg, b

    def fname(self, o):
        i, n = struct.unpack_from("<ii", self.b, o)
        return self.p.name(i, n), o + 8

    def tag(self, o):
        name, o = self.fname(o)
        if name == "None":
            return None, o
        typ, o = self.fname(o)
        size, aidx = struct.unpack_from("<ii", self.b, o)
        o += 8
        t = {"name": name, "type": typ, "size": size, "aidx": aidx}
        if typ == "StructProperty":
            t["struct"], o = self.fname(o)
            o += 16
        elif typ == "BoolProperty":
            t["bool"] = self.b[o]
            o += 1
        elif typ in ("ByteProperty", "EnumProperty"):
            t["enum"], o = self.fname(o)
        elif typ in ("ArrayProperty", "SetProperty"):
            t["inner"], o = self.fname(o)
        elif typ == "MapProperty":
            t["inner"], o = self.fname(o)
            t["vtype"], o = self.fname(o)
        if self.b[o]:
            o += 16
        return t, o + 1

    def read(self, o, end):
        out = {}
        while o < end:
            t, o = self.tag(o)
            if t is None:
                return out, o
            key = t["name"] if t["aidx"] == 0 else "%s[%d]" % (t["name"], t["aidx"])
            out[key] = self.value(t, o)
            o += t["size"]
        return out, o

    def struct(self, sname, o, end):
        if sname in BIN:
            return struct.unpack_from(BIN[sname], self.b, o), o + struct.calcsize(BIN[sname])
        if sname == "Box":
            v = struct.unpack_from("<6fB", self.b, o)
            return (v[0:3], v[3:6]), o + 25
        return self.read(o, end)

    def value(self, t, o):
        typ, b = t["type"], self.b
        if typ == "BoolProperty":
            return bool(t["bool"])
        if typ == "IntProperty":
            return struct.unpack_from("<i", b, o)[0]
        if typ == "FloatProperty":
            return struct.unpack_from("<f", b, o)[0]
        if typ == "ObjectProperty":
            return ("ref", struct.unpack_from("<i", b, o)[0])
        if typ in ("NameProperty", "EnumProperty"):
            return self.fname(o)[0]
        if typ == "ByteProperty":
            return self.fname(o)[0] if t["size"] == 8 else b[o]
        if typ == "StructProperty":
            return self.struct(t["struct"], o, o + t["size"])[0]
        if typ == "ArrayProperty":
            n = struct.unpack_from("<i", b, o)[0]
            p, end = o + 4, o + t["size"]
            if t["inner"] == "StructProperty":
                it, p = self.tag(p)
                items = []
                for _ in range(n):
                    v, p = self.struct(it["struct"], p, end)
                    items.append(v)
                return items
            if t["inner"] == "ObjectProperty":
                return [("ref", struct.unpack_from("<i", b, p + 4 * k)[0]) for k in range(n)]
            return ("array", t["inner"], n)
        return ("raw", typ, t["size"])


def transform(pkg, ci, depth=0):
    """world location, rotation, scale of component export ci"""
    d = pkg.props(ci)
    loc = d.get("RelativeLocation", (0, 0, 0))
    rot = d.get("RelativeRotation", (0, 0, 0))
    sc = d.get("RelativeScale3D", (1, 1, 1))
    att = d.get("AttachParent")
    if att and att[0] == "ref" and att[1] > 0 and depth < 5:
        ploc, prot, psc = transform(pkg, att[1] - 1, depth + 1)
        x, y = rotz(loc[0] * psc[0], loc[1] * psc[1], prot[1])
        return (ploc[0] + x, ploc[1] + y, ploc[2] + loc[2] * psc[2]), tuple(a + c for a, c in zip(prot, rot)), sc
    return loc, rot, sc


def rotz(x, y, yaw):
    c, s = math.cos(math.radians(yaw)), math.sin(math.radians(yaw))
    return x * c - y * s, x * s + y * c


def root(pkg, ai):
    rc = pkg.props(ai).get("RootComponent")
    return rc[1] - 1 if rc and rc[0] == "ref" and rc[1] > 0 else None


def main():
    pkg = Package(sys.argv[1])
    cmd = sys.argv[2] if len(sys.argv) > 2 else "classes"
    if cmd == "classes":
        for k, v in Counter(pkg.cls(e) for e in pkg.exports).most_common():
            print(v, k)
    elif cmd == "volumes":
        for i, e in enumerate(pkg.exports):
            if pkg.cls(e) != "BlockingVolume":
                continue
            rc = root(pkg, i)
            if rc is None:
                continue
            loc, rot, sc = transform(pkg, rc)
            body = pkg.props(rc).get("BrushBodySetup")
            convex = []
            if body and body[0] == "ref" and body[1] > 0:
                agg = pkg.props(body[1] - 1).get("AggGeom", {})
                convex = agg.get("ConvexElems", []) if isinstance(agg, dict) else []
            print("%s at (%.0f,%.0f,%.0f) yaw %.1f scale (%.2f,%.2f,%.2f): %d convex" % (
                e["name"], loc[0], loc[1], loc[2], rot[1], sc[0], sc[1], sc[2], len(convex)))
            for ce in convex:
                pts = []
                for v in ce.get("VertexData", []) if isinstance(ce, dict) else []:
                    x, y = rotz(v[0] * sc[0], v[1] * sc[1], rot[1])
                    pts.append((loc[0] + x, loc[1] + y, loc[2] + v[2] * sc[2]))
                if pts:
                    xs, ys, zs = zip(*pts)
                    print("    %2d verts: x %.0f..%.0f  y %.0f..%.0f  z %.0f..%.0f" % (
                        len(pts), min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)))
    elif cmd == "actors":
        pat = sys.argv[3].lower() if len(sys.argv) > 3 else ""
        for i, e in enumerate(pkg.exports):
            c = pkg.cls(e)
            if not (c == "StaticMeshActor" or c.endswith("_C") or c in ("Landscape", "BlockingVolume")):
                continue
            rc = root(pkg, i)
            mesh, loc, rot, sc = "", (0, 0, 0), (0, 0, 0), (1, 1, 1)
            if rc is not None:
                sm = pkg.props(rc).get("StaticMesh")
                if sm and sm[0] == "ref":
                    mesh = pkg.ref(sm[1]) or ""
                loc, rot, sc = transform(pkg, rc)
            line = "%-26s %-34s %-28s (%.0f,%.0f,%.0f) yaw %.0f scale (%.2f,%.2f,%.2f)" % (
                c, e["name"], mesh, loc[0], loc[1], loc[2], rot[1], sc[0], sc[1], sc[2])
            if pat in line.lower():
                print(line)
    else:
        sys.exit("commands: classes | volumes | actors [text]")


if __name__ == "__main__":
    main()
