#!/usr/bin/env python3
"""
Reference implementation of the EasyEDA -> Altium "part file" converter.

The PowerShell helper (ee_fetch.ps1) is a line-by-line port of this file.
This version exists so the conversion logic can be unit tested and so that
Python users have an alternative helper.

Output format (UTF-8, one record per line, TAB separated):
  all lengths  : integer 1/100 mil  ("cmil")   -> Altium: MilsToCoord(v / 100)
  all angles   : integer millidegrees           -> Altium: v / 1000
  booleans     : 0 / 1
Y axis is already flipped to Altium's Y-up convention.
"""
import json
import math
import re
import sys

U = 1000  # cmil per EasyEDA unit (1 EasyEDA unit = 10 mil = 1000 cmil)

# EasyEDA footprint layer id -> Altium layer token
LAYER_MAP = {
    "1": "TOP", "2": "BOTTOM", "3": "TOPOVERLAY", "4": "BOTTOMOVERLAY",
    "5": "TOPPASTE", "6": "BOTTOMPASTE", "7": "TOPSOLDER", "8": "BOTTOMSOLDER",
    "10": "MECH1", "11": "MULTI", "12": "MECH15", "13": "MECH13", "14": "MECH14",
    "15": "MECH15", "99": "MECH9", "100": "MECH10", "101": "MECH11",
}
REGION_LAYERS = {"1", "2", "3", "4"}

# EasyEDA pin type -> Altium TPinElectrical ordinal
# Altium: 0 Input, 1 IO, 2 Output, 3 OpenCollector, 4 Passive, 5 HiZ, 6 OpenEmitter, 7 Power
PIN_ELEC = {"0": 4, "1": 0, "2": 2, "3": 1, "4": 7}


def f(s, default=0.0):
    try:
        v = float(s)
        if math.isnan(v):
            return default
        return v
    except (TypeError, ValueError):
        return default


def ci(v):
    """round half up to integer for output (same as PowerShell port)"""
    return str(int(math.floor(v + 0.5)))


def clean(s):
    return str(s if s is not None else "").replace("\t", " ").replace("\r", " ").replace("\n", " ").strip()


def get(lst, i, default=""):
    return lst[i] if i < len(lst) else default


def show(s):
    s = (s or "").strip().lower()
    return 0 if s in ("0", "false", "hide", "none") else 1


# --------------------------------------------------------------------------
# geometry helpers
# --------------------------------------------------------------------------
def svg_arc_center(x1, y1, rx, ry, phi_deg, large, sweep, x2, y2):
    """SVG endpoint -> center parameterisation (circular arcs; rx used).
    Works in whatever coordinate system the inputs are in.
    Returns (cx, cy, r) or None."""
    if rx == 0 or ry == 0:
        return None
    r = abs(rx)
    dx2 = (x1 - x2) / 2.0
    dy2 = (y1 - y2) / 2.0
    d2 = dx2 * dx2 + dy2 * dy2
    if d2 == 0:
        return None
    if d2 > r * r:
        r = math.sqrt(d2)
    sign = -1.0 if large == sweep else 1.0
    sq = (r * r - d2) / d2
    coef = sign * math.sqrt(max(sq, 0.0))
    # with phi = 0 (EasyEDA always uses 0 for circular arcs)
    cxp = coef * dy2
    cyp = -coef * dx2
    cx = cxp + (x1 + x2) / 2.0
    cy = cyp + (y1 + y2) / 2.0
    return cx, cy, r


def arc_record(sx, sy, ex, ey, rx, ry, large, sweep):
    """Inputs in EasyEDA (Y-down) absolute units. Returns (cx, cy, r, a_start, a_end)
    already converted to Altium's Y-up frame, CCW from a_start to a_end (degrees)."""
    c = svg_arc_center(sx, sy, rx, ry, 0, large, sweep, ex, ey)
    if c is None:
        return None
    cx, cy, r = c
    # angles in Y-up frame (negate dy)
    a1 = math.degrees(math.atan2(-(sy - cy), sx - cx)) % 360.0
    a2 = math.degrees(math.atan2(-(ey - cy), ex - cx)) % 360.0
    # SVG sweep=1 => positive-angle direction in Y-down => clockwise visually
    if sweep:
        a_start, a_end = a2, a1
    else:
        a_start, a_end = a1, a2
    return cx, cy, r, a_start, a_end


def tokenize_path(path):
    return re.findall(r"[MmLlHhVvAaZzCcQqSsTt]|-?\d*\.?\d+(?:[eE][-+]?\d+)?", path or "")


def path_to_polylines(path, arc_segments=12):
    """Very small SVG path interpreter: M L H V A Z (+ C/Q approximated by end point).
    Returns list of (points_list, closed_flag) in input coordinates."""
    toks = tokenize_path(path)
    out = []
    pts = []
    cx = cy = 0.0
    start = (0.0, 0.0)
    i = 0
    cmd = None
    closed = False

    def num():
        nonlocal i
        v = float(toks[i])
        i += 1
        return v

    while i < len(toks):
        t = toks[i]
        if re.match(r"[A-Za-z]", t):
            cmd = t
            i += 1
            if cmd in "Zz":
                if pts:
                    out.append((pts, True))
                pts = []
                cx, cy = start
                continue
        if cmd is None:
            i += 1
            continue
        try:
            if cmd in "Mm":
                x, y = num(), num()
                if cmd == "m":
                    x += cx; y += cy
                if len(pts) > 1:
                    out.append((pts, False))
                pts = [(x, y)]
                cx, cy = x, y
                start = (x, y)
                cmd = "L" if cmd == "M" else "l"
            elif cmd in "Ll":
                x, y = num(), num()
                if cmd == "l":
                    x += cx; y += cy
                pts.append((x, y)); cx, cy = x, y
            elif cmd in "Hh":
                x = num()
                if cmd == "h":
                    x += cx
                pts.append((x, cy)); cx = x
            elif cmd in "Vv":
                y = num()
                if cmd == "v":
                    y += cy
                pts.append((cx, y)); cy = y
            elif cmd in "Aa":
                rx, ry, _rot, la, sw, x, y = num(), num(), num(), num(), num(), num(), num()
                if cmd == "a":
                    x += cx; y += cy
                c = svg_arc_center(cx, cy, rx, ry, 0, int(la), int(sw), x, y)
                if c:
                    ccx, ccy, r = c
                    a1 = math.atan2(cy - ccy, cx - ccx)
                    a2 = math.atan2(y - ccy, x - ccx)
                    da = a2 - a1
                    if int(sw):
                        while da <= 0: da += 2 * math.pi
                    else:
                        while da >= 0: da -= 2 * math.pi
                    n = max(2, int(abs(da) / (2 * math.pi) * 36))
                    for k in range(1, n + 1):
                        a = a1 + da * k / n
                        pts.append((ccx + r * math.cos(a), ccy + r * math.sin(a)))
                else:
                    pts.append((x, y))
                cx, cy = x, y
            elif cmd in "Cc":
                vals = [num() for _ in range(6)]
                x, y = vals[4], vals[5]
                if cmd == "c":
                    x += cx; y += cy
                pts.append((x, y)); cx, cy = x, y
            elif cmd in "QqSs":
                vals = [num() for _ in range(4)]
                x, y = vals[2], vals[3]
                if cmd in "qs":
                    x += cx; y += cy
                pts.append((x, y)); cx, cy = x, y
            elif cmd in "Tt":
                x, y = num(), num()
                if cmd == "t":
                    x += cx; y += cy
                pts.append((x, y)); cx, cy = x, y
            else:
                i += 1
        except (IndexError, ValueError):
            break
    if len(pts) > 1:
        out.append((pts, False))
    return out


def parse_points(s):
    v = [f(x) for x in (s or "").replace(",", " ").split()]
    return [(v[k], v[k + 1]) for k in range(0, len(v) - 1, 2)]


# --------------------------------------------------------------------------
# symbol
# --------------------------------------------------------------------------
def symbol_origin(ds):
    """Origin (EasyEDA units) chosen so the first pin's hot-spot lands on a 100 mil grid."""
    head = ds.get("head") or {}
    hx, hy = f(head.get("x")), f(head.get("y"))
    for s in ds.get("shape") or []:
        if s and s.startswith("P~"):
            p0 = s.split("^^")[0].split("~")
            px, py = f(get(p0, 4)), f(get(p0, 5))
            return (px - 10.0 * math.floor((px - hx) / 10.0 + 0.5),
                    py - 10.0 * math.floor((py - hy) / 10.0 + 0.5))
    return hx, hy


def convert_symbol(ds, out, origin=None):
    shapes = [s for s in (ds.get("shape") or []) if s]
    ox, oy = origin if origin is not None else symbol_origin(ds)

    def X(x):
        return (x - ox) * U

    def Y(y):
        return -(y - oy) * U

    for s in shapes:
        kind = s.split("~")[0]
        if kind == "P":
            seg = [x.split("~") for x in s.split("^^")]
            st = seg[0]
            hot_x, hot_y = f(get(st, 4)), f(get(st, 5))
            elec = PIN_ELEC.get(get(st, 2, "0"), 4)
            # pin line path, e.g. "M355,285h10" or "M 445 315 h -10"
            path = get(seg[2], 0) if len(seg) > 2 else ""
            polys = path_to_polylines(path)
            length = 10.0
            dx, dy = -1.0, 0.0  # direction from hotspot to body (EasyEDA frame)
            if polys and len(polys[0][0]) >= 2:
                (ax, ay), (bx, by) = polys[0][0][0], polys[0][0][-1]
                # whichever end is closer to the hotspot is the hotspot end
                if math.hypot(ax - hot_x, ay - hot_y) <= math.hypot(bx - hot_x, by - hot_y):
                    dx, dy = bx - ax, by - ay
                else:
                    dx, dy = ax - bx, ay - by
                length = math.hypot(dx, dy)
            else:
                rot = f(get(st, 6))
                dx, dy = {0: (-1, 0), 90: (0, 1), 180: (1, 0), 270: (0, -1)}.get(int(rot) % 360, (1, 0))
            # Altium pin: Location = body end, orientation points from body to hotspot
            body_x, body_y = hot_x + (dx if length else 0), hot_y + (dy if length else 0)
            if abs(dx) >= abs(dy):
                orient = 180 if dx > 0 else 0    # body to the right of hotspot -> pin points left
            else:
                orient = 90 if dy > 0 else 270   # body below hotspot (Y-down) -> pin points up
            if length <= 0:
                length = 10.0
            # re-derive body end exactly along the orientation axis
            if orient == 0:
                body_x, body_y = hot_x - length, hot_y
            elif orient == 180:
                body_x, body_y = hot_x + length, hot_y
            elif orient == 90:
                body_x, body_y = hot_x, hot_y + length
            else:
                body_x, body_y = hot_x, hot_y - length
            name_seg = seg[3] if len(seg) > 3 else []
            num_seg = seg[4] if len(seg) > 4 else []
            dot_seg = seg[5] if len(seg) > 5 else []
            clk_seg = seg[6] if len(seg) > 6 else []
            name = get(name_seg, 4)
            designator = get(num_seg, 4) or get(st, 3)
            show_name = show(get(name_seg, 0, "1")) if name_seg else 1
            show_des = show(get(num_seg, 0, "1")) if num_seg else 1
            dot = show(get(dot_seg, 0, "0")) if dot_seg else 0
            clk = show(get(clk_seg, 0, "0")) if clk_seg else 0
            out.append(["SPIN", ci(X(body_x)), ci(Y(body_y)), ci(length * U), str(orient),
                        str(elec), str(show_name), str(show_des), str(dot), str(clk),
                        clean(designator), clean(name)])
        elif kind == "R":
            p = s.split("~")
            x, y, rx, ry, w, h = (f(get(p, i)) for i in range(1, 7))
            fill = 0 if get(p, 10, "none").lower() in ("none", "") else 1
            out.append(["SRECT", ci(X(x)), ci(Y(y + h)), ci(X(x + w)), ci(Y(y)), str(fill),
                        ci(rx * U), ci(ry * U)])
        elif kind == "E":
            p = s.split("~")
            cx, cy, rx, ry = (f(get(p, i)) for i in range(1, 5))
            fill = 0 if get(p, 8, "none").lower() in ("none", "") else 1
            out.append(["SELLIPSE", ci(X(cx)), ci(Y(cy)), ci(rx * U), ci(ry * U), str(fill)])
        elif kind == "C":
            p = s.split("~")
            cx, cy, r = f(get(p, 1)), f(get(p, 2)), f(get(p, 3))
            fill = 0 if get(p, 7, "none").lower() in ("none", "") else 1
            out.append(["SELLIPSE", ci(X(cx)), ci(Y(cy)), ci(r * U), ci(r * U), str(fill)])
        elif kind == "A":
            p = s.split("~")
            toks = tokenize_path(get(p, 1))
            try:
                mi = toks.index("M") if "M" in toks else toks.index("m")
                ai = toks.index("A") if "A" in toks else toks.index("a")
                sx, sy = float(toks[mi + 1]), float(toks[mi + 2])
                rx, ry = float(toks[ai + 1]), float(toks[ai + 2])
                la, sw = int(float(toks[ai + 4])), int(float(toks[ai + 5]))
                ex, ey = float(toks[ai + 6]), float(toks[ai + 7])
                if toks[ai] == "a":
                    ex += sx; ey += sy
            except (ValueError, IndexError):
                continue
            rec = arc_record(sx, sy, ex, ey, rx, ry, la, sw)
            if rec:
                cx, cy, r, a1, a2 = rec
                out.append(["SARC", ci(X(cx)), ci(Y(cy)), ci(r * U), ci(a1 * 1000), ci(a2 * 1000)])
        elif kind in ("PL", "PG"):
            p = s.split("~")
            pts = parse_points(get(p, 1))
            if len(pts) >= 2:
                fill = 0
                if kind == "PG":
                    fill = 0 if get(p, 5, "none").lower() in ("none", "") else 1
                rec = ["SPOLY", "1" if kind == "PG" else "0", str(fill), str(len(pts))]
                for (x, y) in pts:
                    rec += [ci(X(x)), ci(Y(y))]
                out.append(rec)
        elif kind == "PT":
            p = s.split("~")
            fill = 0 if get(p, 5, "none").lower() in ("none", "") else 1
            for pts, closed in path_to_polylines(get(p, 1)):
                if len(pts) >= 2:
                    rec = ["SPOLY", "1" if closed else "0", str(fill if closed else 0), str(len(pts))]
                    for (x, y) in pts:
                        rec += [ci(X(x)), ci(Y(y))]
                    out.append(rec)
        elif kind == "T":
            p = s.split("~")
            # T~mark~x~y~rotation~color~font~size~bold~italic~baseline~type~text~visible~anchor~id~locked
            txt = get(p, 12)
            if txt and show(get(p, 13, "1")):
                size_pt = f(re.sub(r"[^0-9.]", "", get(p, 7)) or 7, 7.0)
                out.append(["STEXT", ci(X(f(get(p, 2)))), ci(Y(f(get(p, 3)))),
                            ci(((360 - f(get(p, 4))) % 360) * 1000), ci(size_pt), clean(txt)])
    return out


# --------------------------------------------------------------------------
# footprint
# --------------------------------------------------------------------------
def convert_footprint(ds, out, model_info=None):
    """model_info: optional dict with OBJ bounding box: {'xmin','xmax','ymin','ymax','zmin'} (mm)"""
    head = ds.get("head", {})
    canvas = (ds.get("canvas") or "").split("~")
    if len(canvas) > 17 and canvas[16] != "" and canvas[17] != "":
        ox, oy = f(canvas[16]), f(canvas[17])
    else:
        ox, oy = f(head.get("x")), f(head.get("y"))

    def X(x):
        return (x - ox) * U

    def Y(y):
        return -(y - oy) * U

    if not ds.get("shape"):
        out.append(["WARN", "EasyEDA returned no footprint shapes for this part"])
    for s in ds.get("shape") or []:
        if not s:
            continue
        p = s.split("~")
        kind = p[0]
        if kind == "PAD":
            shape = get(p, 1)
            cx, cy, w, h = f(get(p, 2)), f(get(p, 3)), f(get(p, 4)), f(get(p, 5))
            layer = get(p, 6)
            number = get(p, 8)
            hole_r = f(get(p, 9))
            pts = parse_points(get(p, 10))
            rot = f(get(p, 11)) % 360.0
            hole_len = f(get(p, 13))
            plated = 0 if get(p, 15, "Y").strip().upper().startswith("N") else 1
            lay = {"1": "TOP", "2": "BOTTOM"}.get(layer, "MULTI")
            if hole_r > 0:
                lay = "MULTI"
            if shape == "RECT":
                ashape = "RECT"
            elif shape in ("OVAL", "ELLIPSE"):
                ashape = "ROUND"
            elif shape == "POLYGON" and len(pts) >= 3:
                # approximate: rect pad = bounding box of the polygon in the pad's local frame
                a = math.radians(rot)
                lx = []; ly = []
                for (px, py) in pts:
                    dx, dy = px - cx, -(py - cy)  # Y-up
                    lx.append(dx * math.cos(-a) - dy * math.sin(-a))
                    ly.append(dx * math.sin(-a) + dy * math.cos(-a))
                w, h = max(lx) - min(lx), max(ly) - min(ly)
                # polygon may not be centred on cx,cy -> shift centre
                mx, my = (max(lx) + min(lx)) / 2.0, (max(ly) + min(ly)) / 2.0
                cx += mx * math.cos(a) - my * math.sin(a)
                cy -= mx * math.sin(a) + my * math.cos(a)
                ashape = "RECT"
                out.append(["WARN", "Pad %s is a custom polygon; approximated by a %s x %s mil rectangle"
                            % (clean(number), ci(w * 10), ci(h * 10))])
            else:
                ashape = "ROUND"
            hole_d = hole_r * 2.0
            slot_len = 0.0
            hole_rot = 0
            if hole_r > 0 and hole_len > 0 and hole_len > hole_d + 1e-6:
                slot_len = hole_len
                hole_rot = 90 if h > w else 0
            out.append(["FPAD", clean(number), ashape, ci(X(cx)), ci(Y(cy)), ci(w * U), ci(h * U),
                        ci(rot * 1000), lay, ci(hole_d * U), ci(slot_len * U), str(hole_rot * 1000), str(plated)])
        elif kind == "TRACK":
            width, layer = f(get(p, 1)), get(p, 2)
            al = LAYER_MAP.get(layer)
            pts = parse_points(get(p, 4))
            if al:
                for k in range(len(pts) - 1):
                    (x1, y1), (x2, y2) = pts[k], pts[k + 1]
                    out.append(["FTRACK", al, ci(X(x1)), ci(Y(y1)), ci(X(x2)), ci(Y(y2)), ci(width * U)])
        elif kind == "RECT":
            # RECT~x~y~w~h~layer~id~locked~strokeWidth
            x, y, w, h = f(get(p, 1)), f(get(p, 2)), f(get(p, 3)), f(get(p, 4))
            al = LAYER_MAP.get(get(p, 5))
            sw = f(get(p, 8), 0.0) or 0.6
            if al:
                c = [(x, y), (x + w, y), (x + w, y + h), (x, y + h), (x, y)]
                for k in range(4):
                    (x1, y1), (x2, y2) = c[k], c[k + 1]
                    out.append(["FTRACK", al, ci(X(x1)), ci(Y(y1)), ci(X(x2)), ci(Y(y2)), ci(sw * U)])
        elif kind == "CIRCLE":
            cx, cy, r, width = f(get(p, 1)), f(get(p, 2)), f(get(p, 3)), f(get(p, 4))
            al = LAYER_MAP.get(get(p, 5))
            if al and r > 0:
                out.append(["FARC", al, ci(X(cx)), ci(Y(cy)), ci(r * U), "0", "360000", ci(width * U)])
        elif kind == "ARC":
            width, layer, path = f(get(p, 1)), get(p, 2), get(p, 4)
            al = LAYER_MAP.get(layer)
            toks = tokenize_path(path)
            if not al:
                continue
            try:
                mi = [k for k, t in enumerate(toks) if t in ("M", "m")][0]
                ai = [k for k, t in enumerate(toks) if t in ("A", "a")][0]
                sx, sy = float(toks[mi + 1]), float(toks[mi + 2])
                rx, ry = float(toks[ai + 1]), float(toks[ai + 2])
                la, sw = int(float(toks[ai + 4])), int(float(toks[ai + 5]))
                ex, ey = float(toks[ai + 6]), float(toks[ai + 7])
                if toks[ai] == "a":
                    ex += sx; ey += sy
            except (ValueError, IndexError):
                continue
            rec = arc_record(sx, sy, ex, ey, rx, ry, la, sw)
            if rec:
                cx, cy, r, a1, a2 = rec
                out.append(["FARC", al, ci(X(cx)), ci(Y(cy)), ci(r * U), ci(a1 * 1000), ci(a2 * 1000), ci(width * U)])
        elif kind == "HOLE":
            cx, cy, r = f(get(p, 1)), f(get(p, 2)), f(get(p, 3))
            out.append(["FHOLE", ci(X(cx)), ci(Y(cy)), ci(2 * r * U)])
        elif kind == "VIA":
            cx, cy, dia, hr = f(get(p, 1)), f(get(p, 2)), f(get(p, 3)), f(get(p, 5))
            out.append(["FVIA", ci(X(cx)), ci(Y(cy)), ci(dia * U), ci(2 * hr * U)])
        elif kind == "SOLIDREGION":
            layer, path, rtype = get(p, 1), get(p, 3), get(p, 4)
            if layer in REGION_LAYERS and rtype in ("solid", ""):
                al = LAYER_MAP[layer]
                for pts, _closed in path_to_polylines(path):
                    if len(pts) >= 3:
                        rec = ["FREGION", al, str(len(pts))]
                        for (x, y) in pts:
                            rec += [ci(X(x)), ci(Y(y))]
                        out.append(rec)
        elif kind == "SVGNODE":
            try:
                node = json.loads(s[len("SVGNODE~"):])
            except ValueError:
                continue
            attrs = node.get("attrs", {})
            if attrs.get("c_etype") != "outline3D" or not attrs.get("uuid") \
                    or any(r[0] == "MODEL" for r in out):
                continue  # only the first 3D model is used
            co = (attrs.get("c_origin") or "0,0").split(",")
            tx = (f(get(co, 0)) - ox) * 0.254          # mm, Altium frame
            ty = -(f(get(co, 1)) - oy) * 0.254
            tz = f(attrs.get("z")) * 0.254
            # outline-centre correction (same heuristic as easyeda2kicad)
            xs, ys = [], []
            for ch in node.get("childNodes", []) or []:
                for (px, py) in parse_points((ch.get("attrs") or {}).get("points", "")):
                    xs.append((px - ox) * 0.254)
                    ys.append(-(py - oy) * 0.254)
            if xs:
                cxm, cym = (min(xs) + max(xs)) / 2.0, (min(ys) + max(ys)) / 2.0
                if abs(cxm - tx) > 0.1 or abs(cym - ty) > 0.1:
                    tx, ty = cxm, cym
            rot = (attrs.get("c_rotation") or "0,0,0").split(",")
            rx, ry, rz = f(get(rot, 0)), f(get(rot, 1)), f(get(rot, 2))
            out.append(["MODEL", clean(attrs.get("uuid")), clean(attrs.get("title")),
                        "%.4f" % tx, "%.4f" % ty, "%.4f" % tz,
                        "%.3f" % rx, "%.3f" % ry, "%.3f" % rz])
    return out


def finalize_model(lines, objbox):
    """Turn MODEL line (mm floats) + OBJ bbox into the integer F3D record."""
    res = [r for r in lines if r[0] != "MODEL"]
    for rec in [r for r in lines if r[0] == "MODEL"]:
        tx, ty, tz = float(rec[3]), float(rec[4]), float(rec[5])
        rx, ry, rz = float(rec[6]), float(rec[7]), float(rec[8])
        ocx = ocy = zmin = 0.0
        if objbox:
            ocx = (objbox[0] + objbox[1]) / 2.0
            ocy = (objbox[2] + objbox[3]) / 2.0
            zmin = objbox[4]
        # model origin -> centre of the mesh, rotated with the model about Z
        a = math.radians(rz)
        offx = -ocx * math.cos(a) + ocy * math.sin(a)
        offy = -ocx * math.sin(a) - ocy * math.cos(a)
        mm2c = 100000.0 / 25.4  # cmil per mm
        res.append(["F3D", rec[1] + ".step", ci((tx + offx) * mm2c), ci((ty + offy) * mm2c),
                    ci((tz - zmin) * mm2c), ci(rx * 1000), ci(ry * 1000), ci(rz * 1000)])
    return res


def obj_bbox(text):
    xs = []; ys = []; zs = []
    for line in text.splitlines():
        if line.startswith("v "):
            pr = line.split()
            if len(pr) >= 4:
                xs.append(f(pr[1])); ys.append(f(pr[2])); zs.append(f(pr[3]))
    if not xs:
        return None
    return (min(xs), max(xs), min(ys), max(ys), min(zs))


# EasyEDA internal c_para fields that are not useful as Altium parameters
PARAM_SKIP = {"PRE", "NAME", "NAMEALIAS", "PACKAGE", "CONTRIBUTOR", "SPICEPRE",
              "SPICESYMBOLNAME", "TIMESTAMP", "LINK"}


def norm_key(k):
    """Parameter-name key: upper case, letters and digits only."""
    return re.sub(r"[^A-Z0-9]", "", str(k).upper())


def as_dict(v):
    """EasyEDA sometimes sends nested objects as JSON text instead of objects."""
    if isinstance(v, dict):
        return v
    if isinstance(v, str) and v.strip().startswith("{"):
        try:
            d = json.loads(v)
            return d if isinstance(d, dict) else {}
        except ValueError:
            return {}
    return {}


def convert(result, lcsc=""):
    out = []
    ds = as_dict(result.get("dataStr"))
    cpara = (ds.get("head") or {}).get("c_para") or {}
    pkg = as_dict(result.get("packageDetail"))
    pds = as_dict(pkg.get("dataStr"))
    pcpara = (pds.get("head") or {}).get("c_para") or {}
    lcsc = lcsc or ((result.get("lcsc") or {}).get("number")) or cpara.get("Supplier Part", "")
    name = cpara.get("name") or result.get("title") or lcsc
    fpname = pcpara.get("package") or pkg.get("title") or (name + "_FP")
    prefix = (cpara.get("pre") or "U?").replace("?", "")
    desc = result.get("description") or ""
    mfr = cpara.get("Manufacturer") or ""
    mpn = cpara.get("Manufacturer Part") or name
    url = ((result.get("lcsc") or {}).get("url")) or ""
    out.append(["META", "NAME", clean(name)])
    out.append(["META", "LCSC", clean(lcsc)])
    out.append(["META", "FOOTPRINT", clean(fpname)])
    out.append(["META", "PREFIX", clean(prefix or "U")])
    out.append(["META", "DESC", clean(desc or (mfr + " " + mpn).strip())])
    # Parameters keep EasyEDA's own names; the Altium script renames/normalises them
    # with the user's parameter map.
    emitted = set()

    def add_param(k, v):
        nk = norm_key(k)
        if not nk or nk in emitted:
            return
        emitted.add(nk)
        v = clean(v)
        if v and v not in ("null", "-"):
            out.append(["PARAM", clean(k), v])

    for k, v in (("Manufacturer", mfr), ("Manufacturer Part", mpn),
                 ("Supplier", cpara.get("Supplier") or "LCSC"), ("Supplier Part", lcsc),
                 ("Package", fpname), ("Datasheet", url),
                 ("JLCPCB Part Class", cpara.get("JLCPCB Part Class") or ""),
                 ("Value", cpara.get("Value") or "")):
        add_param(k, v)
    for k, v in cpara.items():
        if isinstance(v, str) and norm_key(k) not in PARAM_SKIP:
            add_param(k, v)
    # multi-unit symbols (EasyEDA "subparts"): one Altium part per unit, shared origin
    subparts = [as_dict(sp.get("dataStr")) for sp in (result.get("subparts") or []) if isinstance(sp, dict)]
    subparts = [sp for sp in subparts if sp.get("shape")]
    if subparts:
        origin = symbol_origin(subparts[0])
        for k, sp in enumerate(subparts, 1):
            out.append(["SPART", str(k)])
            convert_symbol(sp, out, origin)
    else:
        convert_symbol(ds, out)
    if not any(r[0] == "SPIN" for r in out):
        out.append(["WARN", "EasyEDA returned no symbol pins for this part"])
    convert_footprint(pds, out)
    return out


def to_text(lines):
    return "\n".join("\t".join(r) for r in lines) + "\n"


def fetch_and_convert(lcsc, outdir, no_model=False):
    """Same behaviour/output files as ee_fetch.ps1 (used when cUsePython = True)."""
    import os
    import urllib.request
    lcsc = lcsc.strip().upper()
    if lcsc.isdigit():
        lcsc = "C" + lcsc
    cache = os.path.join(outdir, "cache")
    mdir = os.path.join(outdir, "3D")
    for d in (outdir, cache, mdir):
        os.makedirs(d, exist_ok=True)
    status = os.path.join(cache, lcsc + ".status.txt")
    part = os.path.join(cache, lcsc + ".part.txt")
    hdr = {"User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/124.0",
           "Accept": "application/json, text/javascript, */*; q=0.01"}

    def get(url):
        with urllib.request.urlopen(urllib.request.Request(url, headers=hdr), timeout=60) as r:
            return r.read()

    try:
        raw = get("https://easyeda.com/api/products/%s/components?version=6.4.19.5" % lcsc).decode("utf-8")
        open(os.path.join(cache, lcsc + ".json"), "w", encoding="utf-8").write(raw)
        data = json.loads(raw)
        res = data.get("result")
        if not res:
            raise RuntimeError("EasyEDA has no symbol/footprint for '%s' (%s)" % (lcsc, data.get("message", "part not found")))
        if not res.get("packageDetail"):
            raise RuntimeError("'%s' has a symbol but no footprint on EasyEDA." % lcsc)
        lines = convert(res, lcsc)
        models = [r for r in lines if r[0] == "MODEL"]
        objbox = None
        if models and not no_model:
            uuid = models[0][1]
            try:
                step = os.path.join(mdir, uuid + ".step")
                if not os.path.exists(step) or os.path.getsize(step) < 100:
                    open(step, "wb").write(get("https://modules.easyeda.com/qAxj6KHrDKw4blvCG8QJPs7Y/" + uuid))
                boxf = os.path.join(mdir, uuid + ".bbox.txt")
                if os.path.exists(boxf):
                    objbox = tuple(float(x) for x in open(boxf).read().split())
                else:
                    objbox = obj_bbox(get("https://modules.easyeda.com/3dmodel/" + uuid).decode("utf-8", "ignore"))
                    if objbox:
                        open(boxf, "w").write(" ".join(repr(v) for v in objbox))
                lines = finalize_model(lines, objbox)
            except Exception as e:  # noqa: BLE001
                lines = [r for r in lines if r[0] != "MODEL"] + [["WARN", "3D model could not be downloaded: " + clean(e)]]
        else:
            lines = [r for r in lines if r[0] != "MODEL"]
        open(part, "w", encoding="utf-8-sig", newline="\r\n").write(to_text(lines))
        open(status, "w", encoding="utf-8-sig").write("OK\t" + part + "\n")
        return 0
    except Exception as e:  # noqa: BLE001
        open(status, "w", encoding="utf-8-sig").write("ERROR\t" + clean(e) + "\n")
        print("ERROR", e)
        return 2


if __name__ == "__main__":
    import argparse
    import os
    ap = argparse.ArgumentParser(description="EasyEDA -> Altium part converter")
    ap.add_argument("json", nargs="?", help="saved API response to convert (prints part file)")
    ap.add_argument("obj", nargs="?", help="optional OBJ model for 3D offset")
    ap.add_argument("--lcsc", help="LCSC number to download, e.g. C2040")
    ap.add_argument("--outdir", default=os.path.join(os.path.dirname(os.path.abspath(__file__)), "Libraries"))
    ap.add_argument("--no-model", action="store_true")
    a = ap.parse_args()
    if a.lcsc:
        sys.exit(fetch_and_convert(a.lcsc, a.outdir, a.no_model))
    data = json.load(open(a.json, encoding="utf-8"))
    res = data.get("result", data)
    lines = convert(res)
    objbox = obj_bbox(open(a.obj, encoding="utf-8", errors="ignore").read()) if a.obj else None
    sys.stdout.write(to_text(finalize_model(lines, objbox)))
