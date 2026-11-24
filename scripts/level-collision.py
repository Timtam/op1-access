"""An area level's collision as convex solids, for scripts/router-sim: the walker's router
run without the game, on the level's own collision.

Written for a player's report on 0.1.0 (2026-11-24): the walker found no way through the
Mountain Pass (F_Mount_1_1), an area the user's own save couldn't reach. Rebuilt with this,
the router failed the same way as in the player's log (pops 976 / 843, ledges 226 / 202)
and the one step at fault could be found (an invisible bridge deck, see main.lua's
nav_ground).

What collides in an area level (UE 4.18 cooked):
- The ground and the cliffs: StaticMeshActors with KSMapEditorBP_<level>_F_Ground_* /
  _F_Cliff_* meshes (also _TS_*), each with hundreds of convex collision elements.
- KSMapEditorBP_<level>_F_Collision (and _TS_Collision): a Blueprint with ~1000 thin
  BoxComponents, invisible fences along terrace edges.
- Every other mesh's simple collision (boxes, convexes) from its BodySetup: the Co_*
  collision meshes (chips, slopes, stairs), trees, rocks, fences. Components switched to
  NoCollision and meshes without collision are left out.
- BlockingVolumes: invisible walls, filled water and off-map areas, bridge decks. Channel 0
  (the router's floor and wall traces) doesn't see them, the capsule's own profile does.

Usage (the level extracted as in scripts/level-dump.py; repak from tools/):
    python -I -X utf8 scripts/level-collision.py <level.umap> "<game>/.../Paks/<pak>.pak" <out.lua>
        [--work <dir>] [--repak <repak.exe>]
The meshes and Blueprints the level uses are extracted into --work (default: next to
<out.lua>, folder "assets"); the pak's file list is kept there too. The output is game
data: keep it out of the repository.

Output: a Lua chunk returning { {flags, x0, x1, y0, y1, z0, z1, {nx, ny, nz, d, ...}}, ... }
-- each solid's bounds and its faces' planes (outward normals, n.p <= d inside); flags
1 = channel 0 sees it, 2 = the capsule's profile does, 4 = a KSMapEditor fence box.
"""
import importlib.util
import math
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("level_dump", os.path.join(HERE, "level-dump.py"))
ld = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ld)


def rotmat(pitch, yaw, roll):
    """UE's FRotationMatrix rows: the local X, Y and Z axes in world space"""
    sp, cp = math.sin(math.radians(pitch)), math.cos(math.radians(pitch))
    sy, cy = math.sin(math.radians(yaw)), math.cos(math.radians(yaw))
    sr, cr = math.sin(math.radians(roll)), math.cos(math.radians(roll))
    return ((cp * cy, cp * sy, sp),
            (sr * sp * cy - cr * sy, sr * sp * sy + cr * cy, -sr * cp),
            (-(cr * sp * cy + sr * sy), cy * sr - cr * sp * sy, cr * cp))


def apply(m, v):
    return (v[0] * m[0][0] + v[1] * m[1][0] + v[2] * m[2][0],
            v[0] * m[0][1] + v[1] * m[1][1] + v[2] * m[2][1],
            v[0] * m[0][2] + v[1] * m[1][2] + v[2] * m[2][2])


def box_corners(c, rot, hx, hy, hz):
    m = rotmat(*rot)
    out = []
    for sx in (-1, 1):
        for sy in (-1, 1):
            for sz in (-1, 1):
                d = apply(m, (sx * hx, sy * hy, sz * hz))
                out.append((c[0] + d[0], c[1] + d[1], c[2] + d[2]))
    return out


def planes(pts):
    """the faces of the convex hull of pts, as (nx, ny, nz, d); brute force over vertex
    triples (UE's convex elements have 8 to ~40 vertices)"""
    n = len(pts)
    if n < 4:
        return None
    span = max(max(p[i] for p in pts) - min(p[i] for p in pts) for i in range(3))
    eps = max(0.02, span * 1e-5)
    seen, out = set(), []
    for i in range(n):
        pi = pts[i]
        for j in range(i + 1, n):
            pj = pts[j]
            ax, ay, az = pj[0] - pi[0], pj[1] - pi[1], pj[2] - pi[2]
            for k in range(j + 1, n):
                pk = pts[k]
                bx, by, bz = pk[0] - pi[0], pk[1] - pi[1], pk[2] - pi[2]
                nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
                ln = math.sqrt(nx * nx + ny * ny + nz * nz)
                if ln < 1e-6:
                    continue
                nx, ny, nz = nx / ln, ny / ln, nz / ln
                d = nx * pi[0] + ny * pi[1] + nz * pi[2]
                mx, mn = -1e18, 1e18
                for p in pts:
                    s = nx * p[0] + ny * p[1] + nz * p[2] - d
                    mx, mn = max(mx, s), min(mn, s)
                    if mx > eps and mn < -eps:
                        break
                if mx <= eps:
                    key = (round(nx, 3), round(ny, 3), round(nz, 3), round(d, 1))
                    if key not in seen:
                        seen.add(key)
                        out.append((nx, ny, nz, d))
                elif mn >= -eps:
                    key = (round(-nx, 3), round(-ny, 3), round(-nz, 3), round(-d, 1))
                    if key not in seen:
                        seen.add(key)
                        out.append((-nx, -ny, -nz, -d))
    return out if len(out) >= 4 else None


def import_package(pkg, idx):
    """the package path ("/Game/...") of import idx (negative), or None"""
    if idx >= 0:
        return None
    imp = pkg.imports[-idx - 1]
    outer = imp["outer"]
    while outer < 0:
        o = pkg.imports[-outer - 1]
        if o["class"] == "Package":
            return o["name"]
        outer = o["outer"]
    return None


def no_collision(bi):
    return isinstance(bi, dict) and (bi.get("CollisionProfileName") == "NoCollision"
                                     or "NoCollision" in str(bi.get("CollisionEnabled")))


def world_transform(pkg, ci, depth=0):
    """a component's location, rotation, scale in the level (the parents' yaw only, as
    level-dump.py; the Blueprints here attach without pitch or roll)"""
    d = pkg.props(ci)
    loc = d.get("RelativeLocation", (0.0, 0.0, 0.0))
    rot = d.get("RelativeRotation", (0.0, 0.0, 0.0))
    sc = d.get("RelativeScale3D", (1.0, 1.0, 1.0))
    att = d.get("AttachParent")
    if att and att[0] == "ref" and att[1] > 0 and depth < 8:
        ploc, prot, psc = world_transform(pkg, att[1] - 1, depth + 1)
        x, y = ld.rotz(loc[0] * psc[0], loc[1] * psc[1], prot[1])
        loc = (ploc[0] + x, ploc[1] + y, ploc[2] + loc[2] * psc[2])
        rot = tuple(a + c for a, c in zip(prot, rot))
        sc = (sc[0] * psc[0], sc[1] * psc[1], sc[2] * psc[2])
    return loc, rot, sc


def main():
    args = sys.argv[1:]
    opts = {}
    for name in ("--work", "--repak"):
        if name in args:
            i = args.index(name)
            opts[name] = args[i + 1]
            del args[i:i + 2]
    if len(args) != 3:
        sys.exit(__doc__)
    umap, pak, out = args
    work = opts.get("--work") or os.path.join(os.path.dirname(os.path.abspath(out)), "assets")
    repak = opts.get("--repak") or os.path.join(HERE, "..", "tools", "repak", "repak.exe")
    os.makedirs(work, exist_ok=True)
    level = ld.Package(umap)

    # what the level places: meshes (with their package) and the collision Blueprints
    comps, packages = [], set()
    for i, e in enumerate(level.exports):
        c = level.cls(e)
        if c == "StaticMeshComponent":
            pr = level.props(i)
            sm = pr.get("StaticMesh")
            if not (isinstance(sm, tuple) and sm[0] == "ref" and sm[1] < 0):
                continue
            if no_collision(pr.get("BodyInstance")):
                continue
            path = import_package(level, sm[1])
            if not path:
                continue
            loc, rot, sc = world_transform(level, i)
            comps.append((path, loc, rot, sc))
            packages.add(path)
        elif c.startswith("KSMapEditorBP_") and c.endswith("_Collision_C"):
            path = import_package(level, e["class"])
            if path:
                rc = ld.root(level, i)
                tf = world_transform(level, rc) if rc is not None else ((0, 0, 0), (0, 0, 0), (1, 1, 1))
                comps.append(("BP:" + path, tf[0], tf[1], tf[2]))
                packages.add(path)

    # extract them (once; the pak's file list is kept in the work folder)
    listing_file = os.path.join(work, "pak-list.txt")
    if not os.path.exists(listing_file):
        res = subprocess.run([repak, "list", pak], capture_output=True, text=True, check=True)
        with open(listing_file, "w", encoding="utf-8", newline="\n") as f:
            f.write(res.stdout)
    in_pak = set(l.strip() for l in open(listing_file, encoding="utf-8"))
    want = []
    for path in sorted(packages):
        base = "Octopath_Traveler/Content/" + path[len("/Game/"):] if path.startswith("/Game/") else None
        if not base:
            continue
        for ext in (".uasset", ".uexp", ".ubulk"):
            f = base + ext
            if f in in_pak and not os.path.exists(os.path.join(work, f)):
                want.append(f)
    if want:
        cmd = [repak, "unpack", "-q", "-o", work]
        for f in want:
            cmd += ["-i", f]
        subprocess.run(cmd + [pak], check=True)

    def asset(path):
        f = os.path.join(work, "Octopath_Traveler/Content/" + path[len("/Game/"):] + ".uasset")
        return ld.Package(f) if os.path.exists(f) else None

    solids = []

    def add(pts, flags):
        pl = planes(pts)
        if not pl:
            return
        xs, ys, zs = [p[0] for p in pts], [p[1] for p in pts], [p[2] for p in pts]
        solids.append((flags, (min(xs), max(xs), min(ys), max(ys), min(zs), max(zs)), pl))

    # meshes: their BodySetup's simple collision
    geo = {}

    def mesh_elements(path):
        if path in geo:
            return geo[path]
        els = []
        p = asset(path)
        for i, e in enumerate(p.exports if p else []):
            if p.cls(e) != "BodySetup":
                continue
            pr = p.props(i)
            if no_collision(pr.get("DefaultInstance")):
                continue
            ag = pr.get("AggGeom", {}) or {}
            for ce in ag.get("ConvexElems", []):
                vs = [tuple(v) for v in ce.get("VertexData", [])]
                if vs:
                    els.append(("c", vs))
            for be in ag.get("BoxElems", []):
                els.append(("b", (tuple(be.get("Center", (0, 0, 0))), tuple(be.get("Rotation", (0, 0, 0))),
                                  be.get("X", 0) / 2, be.get("Y", 0) / 2, be.get("Z", 0) / 2)))
            for se in ag.get("SphylElems", []):   # (capsules: their box)
                r, ln = se.get("Radius", 0), se.get("Length", 0)
                els.append(("b", (tuple(se.get("Center", (0, 0, 0))), tuple(se.get("Rotation", (0, 0, 0))),
                                  r, r, ln / 2 + r)))
            for se in ag.get("SphereElems", []):
                r = se.get("Radius", 0)
                els.append(("b", (tuple(se.get("Center", (0, 0, 0))), (0, 0, 0), r, r, r)))
        geo[path] = els
        return els

    nmesh = nbox = 0
    for path, loc, rot, sc in comps:
        if path.startswith("BP:"):
            # a KSMapEditor collision Blueprint: its BoxComponent templates (fences)
            p = asset(path[3:])
            m = rotmat(*rot)
            for i, e in enumerate(p.exports if p else []):
                if p.cls(e) != "BoxComponent":
                    continue
                pr = p.props(i)
                if no_collision(pr.get("BodyInstance")):
                    continue
                be = pr.get("BoxExtent", (32.0, 32.0, 32.0))
                bs = pr.get("RelativeScale3D", (1.0, 1.0, 1.0))
                bl = pr.get("RelativeLocation", (0.0, 0.0, 0.0))
                d = apply(m, (bl[0] * sc[0], bl[1] * sc[1], bl[2] * sc[2]))
                c = (loc[0] + d[0], loc[1] + d[1], loc[2] + d[2])
                brot = tuple(a + b for a, b in zip(rot, pr.get("RelativeRotation", (0.0, 0.0, 0.0))))
                add(box_corners(c, brot, be[0] * bs[0] * sc[0], be[1] * bs[1] * sc[1], be[2] * bs[2] * sc[2]), 1 | 2 | 4)
                nbox += 1
            continue
        m = rotmat(*rot)

        def w(v):
            d = apply(m, (v[0] * sc[0], v[1] * sc[1], v[2] * sc[2]))
            return (loc[0] + d[0], loc[1] + d[1], loc[2] + d[2])
        for kind, el in mesh_elements(path):
            if kind == "c":
                add([w(v) for v in el], 1 | 2)
            else:
                cen, brot, hx, hy, hz = el
                add([w(v) for v in box_corners(cen, brot, hx, hy, hz)], 1 | 2)
            nmesh += 1

    # blocking volumes: the capsule's profile only
    nvol = 0
    for i, e in enumerate(level.exports):
        if level.cls(e) != "BlockingVolume":
            continue
        rc = ld.root(level, i)
        if rc is None:
            continue
        loc, rot, sc = world_transform(level, rc)
        body = level.props(rc).get("BrushBodySetup")
        if not (body and body[0] == "ref" and body[1] > 0):
            continue
        agg = level.props(body[1] - 1).get("AggGeom", {})
        m = rotmat(*rot)
        for ce in (agg.get("ConvexElems", []) if isinstance(agg, dict) else []):
            pts = []
            for v in ce.get("VertexData", []):
                d = apply(m, (v[0] * sc[0], v[1] * sc[1], v[2] * sc[2]))
                pts.append((loc[0] + d[0], loc[1] + d[1], loc[2] + d[2]))
            if pts:
                add(pts, 2)
                nvol += 1

    with open(out, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- %s's collision, written by scripts/level-collision.py (game data: not for the repository)\n"
                % os.path.splitext(os.path.basename(umap))[0])
        f.write("return {\n")
        for flags, b, pl in solids:
            f.write("{%d,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,{%s}},\n" % (flags, *b, ",".join("%.5f,%.5f,%.5f,%.2f" % q for q in pl)))
        f.write("}\n")
    print("%d solids: %d mesh elements, %d fence boxes, %d volume pieces -> %s" % (len(solids), nmesh, nbox, nvol, out))


if __name__ == "__main__":
    main()
