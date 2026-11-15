"""OP1 Access translations (gettext style).

The mod's own texts are English in the code, wrapped in tr("..."), trf("... %s ...", x),
trn("1 ...", "%d ...", n) or N_("...") (main.lua). This script collects them into
Scripts/lang/op1access.pot and keeps the translations, Scripts/lang/<language>.po, in
step with it. Translate a .po with Poedit or any text editor (UTF-8); the mod picks the
file of the game's text language (de, fr, es, it, ja, ko, zh_cn, zh_tw).

  python scripts/i18n.py extract           write lang/op1access.pot
  python scripts/i18n.py update            extract, then merge it into every lang/*.po
  python scripts/i18n.py new <language>    start lang/<language>.po from the .pot
  python scripts/i18n.py check [language]  count what is translated; list what is not

A text no longer in the code stays in the .po as an obsolete entry (#~), so nothing
translated is lost; Poedit can purge them.
"""
import os, re, sys, glob, datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCRIPTS = os.path.join(ROOT, "scripts", "Mods", "OP1Access", "Scripts")
LANG = os.path.join(SCRIPTS, "lang")
POT = os.path.join(LANG, "op1access.pot")
SOURCES = ["main.lua"]
CALL = re.compile(r"(?<![\w.:])(trf|trn|tr|N_)\(\s*")


def lua_string(src, i):
    """Parse the Lua string literal starting at src[i] (a quote). Returns (text, end)."""
    q = src[i]
    j = i + 1
    out = bytearray()
    while j < len(src):
        c = src[j]
        if c == q:
            return out.decode("utf-8"), j + 1
        if c == "\\":
            n = src[j + 1]
            simple = {"n": b"\n", "t": b"\t", "r": b"\r", "a": b"\a", "\\": b"\\", '"': b'"', "'": b"'"}
            if n in simple:
                out += simple[n]
                j += 2
            elif n.isdigit():
                m = re.match(r"\d{1,3}", src[j + 1:])
                out.append(int(m.group(0)))
                j += 1 + len(m.group(0))
            elif n == "x":
                out.append(int(src[j + 2:j + 4], 16))
                j += 4
            elif n == "u":
                m = re.match(r"\{([0-9A-Fa-f]+)\}", src[j + 2:])
                out += chr(int(m.group(1), 16)).encode("utf-8")
                j += 2 + len(m.group(0))
            else:
                raise ValueError("unknown escape \\%s" % n)
        elif c == "\n":
            raise ValueError("newline in a string")
        else:
            out += c.encode("utf-8")
            j += 1
    raise ValueError("unterminated string")


def extract():
    """-> list of entries {id, plural, refs, fmt} in first-seen order."""
    entries, index, problems = [], {}, []
    for name in SOURCES:
        path = os.path.join(SCRIPTS, name)
        with open(path, encoding="utf-8") as f:
            src = f.read()
        for m in CALL.finditer(src):
            fn = m.group(1)
            i = m.end()
            line = src.count("\n", 0, m.start()) + 1
            # the call's line must not be a comment
            ls = src.rfind("\n", 0, m.start()) + 1
            if "--" in src[ls:m.start()]:
                continue
            if src[ls:m.start()].rstrip().endswith("function"):
                continue   # the definition itself
            if i >= len(src) or src[i] not in "\"'":
                continue   # tr(variable): a text marked elsewhere with N_("...")
            try:
                text, j = lua_string(src, i)
                plural = None
                rest = src[j:].lstrip()
                if fn == "trn":
                    if not rest.startswith(","):
                        raise ValueError("trn needs two texts")
                    k = j + (len(src[j:]) - len(rest)) + 1
                    while src[k] in " \t\r\n":
                        k += 1
                    plural, j = lua_string(src, k)
                    rest = src[j:].lstrip()
                if not rest.startswith((")", ",")):
                    problems.append("%s:%d: %s(\"%s\"...) is not one literal" % (name, line, fn, text[:40]))
            except Exception as e:
                problems.append("%s:%d: %s" % (name, line, e))
                continue
            key = (text, plural)
            e = index.get(key)
            if not e:
                e = {"id": text, "plural": plural, "refs": [], "fmt": fn in ("trf", "trn")}
                index[key] = e
                entries.append(e)
            e["refs"].append("%s:%d" % (name, line))
            if fn in ("trf", "trn"):
                e["fmt"] = True
    return entries, problems


def po_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")


def po_unescape(s):
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "t": "\t", "r": "\r"}.get(m.group(1), m.group(1)), s)


def header(lang):
    now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M%z") or "2026-01-01 00:00+0000"
    return ['msgid ""', 'msgstr ""', '"Project-Id-Version: OP1 Access\\n"',
            '"POT-Creation-Date: %s\\n"' % now, '"Language: %s\\n"' % lang,
            '"MIME-Version: 1.0\\n"', '"Content-Type: text/plain; charset=UTF-8\\n"',
            '"Content-Transfer-Encoding: 8bit\\n"', '"Plural-Forms: nplurals=2; plural=(n != 1);\\n"']


def write_entry(out, e, strs=None, fuzzy=False, obsolete=False):
    p = "#~ " if obsolete else ""
    if not obsolete:
        for i in range(0, len(e["refs"]), 6):
            out.append("#: " + " ".join(e["refs"][i:i + 6]))
    flags = (["fuzzy"] if fuzzy else []) + (["lua-format"] if e.get("fmt") else [])
    if flags and not obsolete:
        out.append("#, " + ", ".join(flags))
    out.append('%smsgid "%s"' % (p, po_escape(e["id"])))
    if e.get("plural") is not None:
        out.append('%smsgid_plural "%s"' % (p, po_escape(e["plural"])))
        strs = strs or ["", ""]
        out.append('%smsgstr[0] "%s"' % (p, po_escape(strs[0])))
        out.append('%smsgstr[1] "%s"' % (p, po_escape(strs[1] if len(strs) > 1 else "")))
    else:
        out.append('%smsgstr "%s"' % (p, po_escape((strs or [""])[0])))
    out.append("")


def write_pot(entries):
    os.makedirs(LANG, exist_ok=True)
    out = header("") + [""]
    for e in entries:
        write_entry(out, e)
    with open(POT, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))


def read_po(path):
    """-> (header lines, {(id, plural): {"strs": [...], "fuzzy": bool}}, order)"""
    entries, order, hdr = {}, [], []
    cur, field = None, None
    def finish():
        if cur is None:
            return
        if cur["id"] == "" and cur["plural"] is None:
            return
        key = (cur["id"], cur["plural"])
        entries[key] = {"strs": cur["strs"], "fuzzy": cur["fuzzy"], "obsolete": cur["obsolete"]}
        order.append(key)
    with open(path, encoding="utf-8") as f:
        lines = f.read().split("\n")
    in_header = True
    for raw in lines + [""]:
        line = raw.rstrip("\r")
        obsolete = line.startswith("#~ ")
        if obsolete:
            line = line[3:]
        if in_header:
            hdr.append(raw)
            if line.strip() == "":
                in_header = False
            continue
        if line.strip() == "":
            finish(); cur, field = None, None
            continue
        if line.startswith("#,") and not obsolete:
            cur = cur or {"id": None, "plural": None, "strs": [""], "fuzzy": False, "obsolete": False}
            cur["fuzzy"] = "fuzzy" in line
            continue
        if line.startswith("#") and not obsolete:
            continue
        m = re.match(r'(msgid|msgid_plural|msgstr|msgstr\[(\d)\]|msgctxt)\s+"(.*)"\s*$', line)
        if m:
            cur = cur or {"id": None, "plural": None, "strs": [""], "fuzzy": False, "obsolete": False}
            cur["obsolete"] = obsolete
            kind, idx, val = m.group(1), m.group(2), po_unescape(m.group(3))
            if kind == "msgid":
                cur["id"] = val; field = ("id", None)
            elif kind == "msgid_plural":
                cur["plural"] = val; field = ("plural", None)
            elif kind == "msgstr":
                cur["strs"] = [val]; field = ("strs", 0)
            elif kind.startswith("msgstr["):
                n = int(idx)
                while len(cur["strs"]) <= n:
                    cur["strs"].append("")
                cur["strs"][n] = val; field = ("strs", n)
            continue
        m = re.match(r'\s*"(.*)"\s*$', line)
        if m and cur is not None and field:
            val = po_unescape(m.group(1))
            if field[0] == "strs":
                cur["strs"][field[1]] += val
            else:
                cur[field[0]] = (cur[field[0]] or "") + val
    finish()
    return hdr, entries, order


def merge(path, entries):
    hdr, old, order = read_po(path)
    lang = os.path.splitext(os.path.basename(path))[0]
    out = [l for l in hdr if l.strip() != ""] if hdr else header(lang)
    if not any(l.startswith('msgid ""') for l in out):
        out = header(lang)
    out.append("")
    used = set()
    for e in entries:
        key = (e["id"], e["plural"])
        o = old.get(key)
        used.add(key)
        write_entry(out, e, o["strs"] if o else None, o["fuzzy"] if o else False)
    for key in order:
        if key not in used and any(s for s in old[key]["strs"]):
            write_entry(out, {"id": key[0], "plural": key[1], "refs": []}, old[key]["strs"], obsolete=True)
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(out))


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "check"
    if cmd in ("extract", "update", "new"):
        entries, problems = extract()
        for p in problems:
            print("warning: " + p)
        write_pot(entries)
        print("%d texts -> %s" % (len(entries), os.path.relpath(POT, ROOT)))
        if cmd == "new":
            path = os.path.join(LANG, argv[2] + ".po")
            if os.path.exists(path):
                print("exists: " + path); return 1
            out = header(argv[2]) + [""]
            for e in entries:
                write_entry(out, e)
            with open(path, "w", encoding="utf-8", newline="\n") as f:
                f.write("\n".join(out))
            print("started " + os.path.relpath(path, ROOT))
        if cmd == "update":
            for path in sorted(glob.glob(os.path.join(LANG, "*.po"))):
                merge(path, entries)
                print("merged " + os.path.relpath(path, ROOT))
        return 0
    if cmd == "check":
        entries, problems = extract()
        for p in problems:
            print("warning: " + p)
        langs = argv[2:] or [os.path.splitext(os.path.basename(p))[0] for p in sorted(glob.glob(os.path.join(LANG, "*.po")))]
        bad = 0
        for lang in langs:
            _, old, _ = read_po(os.path.join(LANG, lang + ".po"))
            missing = []
            for e in entries:
                o = old.get((e["id"], e["plural"]))
                if not o or o["fuzzy"] or not all(o["strs"]) or o.get("obsolete"):
                    missing.append(e)
                elif e["fmt"]:
                    want = re.findall(r"%[-+ #0]*\d*(?:\.\d+)?[sdifgqxXc%]", e["id"])
                    for s in o["strs"]:
                        got = re.findall(r"%[-+ #0]*\d*(?:\.\d+)?[sdifgqxXc%]", s)
                        if sorted(got) != sorted(want) and not e["plural"]:
                            print("%s: %%-codes differ: %r -> %r" % (lang, e["id"], s))
                            bad += 1
            print("%s: %d of %d translated" % (lang, len(entries) - len(missing), len(entries)))
            for e in missing:
                print("  missing: %r  (%s)" % (e["id"], e["refs"][0]))
            bad += len(missing)
        return 1 if bad else 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
