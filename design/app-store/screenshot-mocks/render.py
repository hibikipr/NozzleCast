"""Renders NozzleCast's screenshot-mode mock images: plate covers (transparent PNG) and chamber
camera frames (JPEG). Units are millimetres. Usage:
Blender -b --factory-startup --python render.py -- <out_dir> [name ...]
"""
import bpy, bmesh, math, random, sys
from mathutils import Vector

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
OUT = argv[0] if argv else "/tmp"
ONLY = set(argv[1:])


# ---------- helpers ----------

def srgb_to_linear(c):
    return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4


def hex_color(h, a=1.0):
    h = h.lstrip("#")
    return tuple(srgb_to_linear(int(h[i:i + 2], 16) / 255) for i in (0, 2, 4)) + (a,)


def material(name, hexcol, rough=0.45, bump=0.0, noise_scale=0.6):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = hex_color(hexcol)
    bsdf.inputs["Roughness"].default_value = rough
    if bump > 0:
        tex = nt.nodes.new("ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = noise_scale
        b = nt.nodes.new("ShaderNodeBump")
        b.inputs["Strength"].default_value = bump
        nt.links.new(tex.outputs["Fac"], b.inputs["Height"])
        nt.links.new(b.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def layer_material(name, hexcol, rough=0.4):
    """Filament with faint horizontal layer lines (0.2 mm)."""
    m = material(name, hexcol, rough)
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    coord = nt.nodes.new("ShaderNodeTexCoord")
    sep = nt.nodes.new("ShaderNodeSeparateXYZ")
    mul = nt.nodes.new("ShaderNodeMath"); mul.operation = "MULTIPLY"; mul.inputs[1].default_value = math.pi * 2 / 0.4
    sin = nt.nodes.new("ShaderNodeMath"); sin.operation = "SINE"
    b = nt.nodes.new("ShaderNodeBump"); b.inputs["Strength"].default_value = 0.08; b.inputs["Distance"].default_value = 0.05
    nt.links.new(coord.outputs["Object"], sep.inputs[0])
    nt.links.new(sep.outputs["Z"], mul.inputs[0])
    nt.links.new(mul.outputs[0], sin.inputs[0])
    nt.links.new(sin.outputs[0], b.inputs["Height"])
    nt.links.new(b.outputs["Normal"], bsdf.inputs["Normal"])
    return m


def link(obj):
    bpy.context.scene.collection.objects.link(obj)
    return obj


def mesh_obj(name, verts, faces, mat=None):
    me = bpy.data.meshes.new(name)
    me.from_pydata(verts, [], faces)
    me.validate()
    me.update()
    o = link(bpy.data.objects.new(name, me))
    if mat:
        o.data.materials.append(mat)
    for p in o.data.polygons:
        p.use_smooth = False
    return o


def prism(name, poly, z0, z1, mat=None):
    n = len(poly)
    verts = [(x, y, z0) for x, y in poly] + [(x, y, z1) for x, y in poly]
    faces = [list(range(n))[::-1], list(range(n, 2 * n))]
    for i in range(n):
        j = (i + 1) % n
        faces.append([i, j, n + j, n + i])
    return mesh_obj(name, verts, faces, mat)


def ngon(r, n, rot=0.0):
    return [(r * math.cos(rot + 2 * math.pi * i / n), r * math.sin(rot + 2 * math.pi * i / n)) for i in range(n)]


def rounded_rect(w, h, r, seg=8):
    pts = []
    for cx, cy, a0 in ((w / 2 - r, h / 2 - r, 0), (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180), (w / 2 - r, -h / 2 + r, 270)):
        for k in range(seg + 1):
            a = math.radians(a0 + 90 * k / seg)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def boolean(obj, cutter, op="DIFFERENCE"):
    mod = obj.modifiers.new("bool", "BOOLEAN")
    mod.operation = op
    mod.solver = "EXACT"
    mod.object = cutter
    cutter.hide_render = True
    cutter.hide_viewport = True
    return mod


def lofted(name, rings, close_bottom=True, mat=None, thickness=1.0):
    """Rings of (x, y, z) points, bottom to top; open top, solidified wall."""
    n = len(rings[0])
    verts = [p for ring in rings for p in ring]
    faces = []
    for r in range(len(rings) - 1):
        for i in range(n):
            j = (i + 1) % n
            faces.append([r * n + i, r * n + j, (r + 1) * n + j, (r + 1) * n + i])
    if close_bottom:
        faces.append(list(range(n))[::-1])
    o = mesh_obj(name, verts, faces, mat)
    for p in o.data.polygons:
        p.use_smooth = True
    s = o.modifiers.new("wall", "SOLIDIFY")
    s.thickness = thickness
    s.offset = -1
    return o


# ---------- models (each returns its list of filament objects) ----------

def honeycomb(mat):
    R, w, base = 18.0, 1.6, 2.0
    heights = [52, 40, 30, 40, 30, 40, 30]
    centers = [(0, 0)] + [(math.sqrt(3) * R * math.cos(math.radians(30 + 60 * k)), math.sqrt(3) * R * math.sin(math.radians(30 + 60 * k))) for k in range(6)]
    objs = []
    for i, ((cx, cy), h) in enumerate(zip(centers, heights)):
        outer = prism(f"cell{i}", [(cx + x, cy + y) for x, y in ngon(R + 0.3, 6)], 0, h, mat)
        inner = prism(f"cell{i}_in", [(cx + x, cy + y) for x, y in ngon(R - w, 6)], base, h + 5)
        boolean(outer, inner)
        objs.append(outer)
    return objs


def gridfinity(mat):
    W, H, top = 83.5, 125.5, 47.0
    body = prism("bin", rounded_rect(W, H, 4), 5, top, mat)
    cav = prism("bin_in", rounded_rect(W - 2.4, H - 2.4, 2.8), 7, top + 5)
    boolean(body, cav)
    objs = [body]
    # stacking lip
    lip = prism("lip", rounded_rect(W, H, 4), top, top + 4.4, mat)
    lip_in = prism("lip_in", rounded_rect(W - 5.2, H - 5.2, 1.6), top - 1, top + 6)
    boolean(lip, lip_in)
    objs.append(lip)
    # divider
    objs.append(prism("div", [(-W / 2 + 1, -0.6), (W / 2 - 1, -0.6), (W / 2 - 1, 0.6), (-W / 2 + 1, 0.6)], 7, top - 6, mat))
    for ix in (-0.5, 0.5):
        for iy in (-1, 0, 1):
            cx, cy = ix * 42, iy * 42
            objs.append(prism(f"foot{ix}{iy}", [(cx + x, cy + y) for x, y in rounded_rect(35.6, 35.6, 1.6)], 0, 2.6, mat))
            objs.append(prism(f"foot2{ix}{iy}", [(cx + x, cy + y) for x, y in rounded_rect(40.8, 40.8, 3.2)], 2.6, 5.1, mat))
    return objs


def twist_vase(mat):
    H, N, P = 150.0, 80, 10
    rings = []
    for k in range(N + 1):
        t = k / N
        z = H * t
        s = 1 + 0.18 * math.sin(math.pi * t) - 0.12 * t
        rot = math.radians(140) * t
        ring = []
        for i in range(P * 6):
            a = 2 * math.pi * i / (P * 6)
            # smooth star: 10 lobes
            r = (34 + 5 * math.cos(P * a)) * s
            ring.append((r * math.cos(a + rot), r * math.sin(a + rot), z))
        rings.append(ring)
    return [lofted("vase", rings, mat=mat, thickness=1.0)]


def lampshade(mat):
    H, N, P = 120.0, 40, 192
    rings = []
    for k in range(N + 1):
        t = k / N
        base = 70 + (46 - 70) * t
        rings.append([((base * (1 + 0.035 * math.cos(24 * 2 * math.pi * i / P))) * math.cos(2 * math.pi * i / P),
                       (base * (1 + 0.035 * math.cos(24 * 2 * math.pi * i / P))) * math.sin(2 * math.pi * i / P), H * t) for i in range(P)])
    return [lofted("shade", rings, close_bottom=False, mat=mat, thickness=1.2)]


def phone_stand(mat):
    prof = [(0, 0), (95, 0), (95, 6), (68, 6), (33, 110), (25, 110), (58, 6), (8, 6), (8, 18), (0, 18)]
    # profile is in (x, z); extrude along y
    n = len(prof)
    wy = 70
    verts = [(x - 47, -wy / 2, z) for x, z in prof] + [(x - 47, wy / 2, z) for x, z in prof]
    faces = [list(range(n)), list(range(n, 2 * n))[::-1]]
    for i in range(n):
        j = (i + 1) % n
        faces.append([j, i, n + i, n + j])
    o = mesh_obj("stand", verts, faces, mat)
    # cable cut-out through the back support
    hole = prism("hole", rounded_rect(18, 26, 8), -100, 100)
    hole.rotation_euler = (0, math.radians(-73), 0)
    hole.location = (-6, 0, 50)
    boolean(o, hole)
    return [o]


def cable_clips(mat):
    objs = []
    for ix in range(4):
        for iy in range(3):
            cx, cy = (ix - 1.5) * 22, (iy - 1) * 22
            ring = prism(f"clip{ix}{iy}", [(cx + x, cy + y) for x, y in ngon(7.5, 48)], 0, 8, mat)
            hole = prism(f"cliph{ix}{iy}", [(cx + x, cy + y) for x, y in ngon(5.5, 48)], -1, 9)
            gap = prism(f"clipg{ix}{iy}", [(cx + 3, cy - 2.6), (cx + 10, cy - 3.6), (cx + 10, cy + 3.6), (cx + 3, cy + 2.6)], -1, 9)
            boolean(ring, hole)
            boolean(ring, gap)
            for p in ring.data.polygons:
                p.use_smooth = True
            tab = prism(f"clipt{ix}{iy}", [(cx - 12, cy - 4), (cx - 7, cy - 4), (cx - 7, cy + 4), (cx - 12, cy + 4)], 0, 8, mat)
            objs += [ring, tab]
    return objs


def letter(ch, size, loc, rot):
    cu = bpy.data.curves.new(f"t{ch}", "FONT")
    cu.body = ch
    cu.size = size
    cu.align_x = "CENTER"
    cu.align_y = "CENTER"
    cu.extrude = 1.5
    t = link(bpy.data.objects.new(f"t{ch}", cu))
    t.location = loc
    t.rotation_euler = rot
    dg = bpy.context.evaluated_depsgraph_get()
    me = bpy.data.meshes.new_from_object(t.evaluated_get(dg))
    m = link(bpy.data.objects.new(f"m{ch}", me))
    m.location, m.rotation_euler = t.location.copy(), t.rotation_euler.copy()
    bpy.data.objects.remove(t)
    return m


def cal_cube(mat):
    c = prism("cube", ngon(20 / math.sqrt(2), 4, math.radians(45)), 0, 20, mat)
    boolean(c, letter("X", 13, (0, -10, 10), (math.radians(90), 0, 0)))
    boolean(c, letter("Y", 13, (10, 0, 10), (math.radians(90), 0, math.radians(90))))
    boolean(c, letter("Z", 13, (0, 0, 20), (0, 0, 0)))
    return [c]


def headphone_stand(mat):
    base = prism("base", ngon(45, 96), 0, 8, mat)
    for p in base.data.polygons:
        p.use_smooth = True
    post = prism("post", rounded_rect(24, 14, 5), 8, 196, mat)
    # saddle: half annulus in xz, extruded along y
    arc = [(32 * math.cos(math.pi * k / 32), 32 * math.sin(math.pi * k / 32)) for k in range(33)] + \
          [(26 * math.cos(math.pi * k / 32), 26 * math.sin(math.pi * k / 32)) for k in range(32, -1, -1)]
    n = len(arc)
    verts = [(x, -32, 170 + z) for x, z in arc] + [(x, 32, 170 + z) for x, z in arc]
    faces = [list(range(n)), list(range(n, 2 * n))[::-1]]
    for i in range(n):
        j = (i + 1) % n
        faces.append([j, i, n + i, n + j])
    sad = mesh_obj("saddle", verts, faces, mat)
    for p in sad.data.polygons:
        p.use_smooth = True
    return [base, post, sad]


def planter(mat):
    H, N, P = 70.0, 12, 72
    rings = [[((45 + 15 * k / N) * math.cos(2 * math.pi * i / P), (45 + 15 * k / N) * math.sin(2 * math.pi * i / P), H * k / N) for i in range(P)] for k in range(N + 1)]
    cup = lofted("cup", rings, mat=mat, thickness=2.0)
    rim = prism("rim", ngon(65, 96), H - 4, H, mat)
    rim_in = prism("rim_in", ngon(59, 96), H - 5, H + 1)
    boolean(rim, rim_in)
    for p in rim.data.polygons:
        p.use_smooth = True
    for i in range(6):
        a = 2 * math.pi * i / 6
        h = prism(f"drain{i}", [(25 * math.cos(a) + x, 25 * math.sin(a) + y) for x, y in ngon(4, 24)], -1, 4)
        boolean(cup, h)
    return [cup, rim]


MODELS = {
    "honeycomb": (honeycomb, "#E8622C"),
    "gridfinity": (gridfinity, "#2F6B3A"),
    "twistvase": (twist_vase, "#F2F2F2"),
    "lampshade": (lampshade, "#D9A426"),
    "phonestand": (phone_stand, "#FF6B35"),
    "cableclips": (cable_clips, "#1F2A44"),
    "calcube": (cal_cube, "#4F7FE0"),
    "headphonestand": (headphone_stand, "#E2E2E2"),
    "planter": (planter, "#2E7D32"),
}


# ---------- scene ----------

def reset():
    bpy.ops.wm.read_factory_settings(use_empty=True)
    sc = bpy.context.scene
    sc.unit_settings.scale_length = 0.001
    sc.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for d in prefs.devices:
        d.use = d.type == "METAL"
    sc.cycles.device = "GPU"
    sc.cycles.use_denoising = True
    sc.view_settings.view_transform = "Standard"
    sc.view_settings.look = "None"
    w = bpy.data.worlds.new("w")
    sc.world = w
    w.use_nodes = True
    return sc


def bbox(objs):
    dg = bpy.context.evaluated_depsgraph_get()
    pts = []
    for o in objs:
        ev = o.evaluated_get(dg)
        pts += [ev.matrix_world @ Vector(c) for c in ev.bound_box]
    lo = Vector((min(p.x for p in pts), min(p.y for p in pts), min(p.z for p in pts)))
    hi = Vector((max(p.x for p in pts), max(p.y for p in pts), max(p.z for p in pts)))
    return lo, hi, pts


def add_camera(loc, target, lens):
    cd = bpy.data.cameras.new("cam")
    cd.lens = lens
    cd.clip_start = 1
    cd.clip_end = 100000
    cam = link(bpy.data.objects.new("cam", cd))
    cam.location = loc
    cam.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    bpy.context.scene.camera = cam
    return cam


def sun(rot, strength, color=(1, 1, 1), angle=0.2):
    ld = bpy.data.lights.new("sun", "SUN")
    ld.energy = strength
    ld.color = color
    ld.angle = angle
    o = link(bpy.data.objects.new("sun", ld))
    o.rotation_euler = [math.radians(a) for a in rot]
    return o


def area(loc, target, size, power, color=(1, 1, 1), size_y=None):
    ld = bpy.data.lights.new("area", "AREA")
    ld.shape = "RECTANGLE"
    ld.size = size
    ld.size_y = size_y or size
    ld.energy = power
    ld.color = color
    o = link(bpy.data.objects.new("area", ld))
    o.location = loc
    o.rotation_euler = (Vector(target) - Vector(loc)).to_track_quat("-Z", "Y").to_euler()
    return o


def render(path, fmt, w, h, samples):
    sc = bpy.context.scene
    sc.render.resolution_x = w
    sc.render.resolution_y = h
    sc.render.resolution_percentage = 100
    sc.cycles.samples = samples
    sc.render.image_settings.file_format = fmt
    if fmt == "PNG":
        sc.render.image_settings.color_mode = "RGBA"
        sc.render.image_settings.compression = 90
    else:
        sc.render.image_settings.color_mode = "RGB"
        sc.render.image_settings.quality = 82
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)
    print("WROTE", path)


def cover(name):
    sc = reset()
    fn, col = MODELS[name]
    objs = fn(layer_material("fil", col))
    sc.render.film_transparent = True
    bg = sc.world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.55, 0.55, 0.58, 1)
    bg.inputs["Strength"].default_value = 0.9
    sun((40, 0, -35), 3.2)
    sun((70, 0, 150), 1.0, (0.85, 0.9, 1.0))
    lo, hi, pts = bbox(objs)
    center = (lo + hi) / 2
    d = Vector((0.55, -1.0, 0.8)).normalized()
    cam = add_camera(center + d * 1000, center, 60)
    dg = bpy.context.evaluated_depsgraph_get()
    co, _ = cam.camera_fit_coords(dg, [c for p in pts for c in p])
    cam.location = center + (Vector(co) - center) * 1.12
    render(f"{OUT}/ScreenshotMock-cover-{name}.png", "PNG", 640, 640, 48)


def camera(name, frac, spaghetti=False, toolhead=True):
    sc = reset()
    fn, col = MODELS[name]
    objs = fn(layer_material("fil", col, 0.35))
    lo, hi, _ = bbox(objs)
    zcut = lo.z + (hi.z - lo.z) * frac
    if frac < 1:
        cutter = prism("cut", ngon(400, 4, math.radians(45)), zcut, 2000)
        for o in objs:
            boolean(o, cutter)
    # build plate: textured PEI, black-gold
    prism("plate", ngon(128 * math.sqrt(2), 4, math.radians(45)), -1.2, 0, material("pei", "#2B2A26", 0.75, bump=0.35, noise_scale=3.0))
    prism("bed", ngon(150 * math.sqrt(2), 4, math.radians(45)), -14, -1.2, material("bed", "#141415", 0.5))
    wall = material("wall", "#1E1F22", 0.7)
    prism("floor", ngon(600, 4, math.radians(45)), -200, -150, wall)
    prism("back", [(-300, 175), (300, 175), (300, 185), (-300, 185)], -200, 450, wall)
    prism("left", [(-185, -300), (-175, -300), (-175, 185), (-185, 185)], -200, 450, wall)
    prism("right", [(175, -300), (185, -300), (185, 185), (175, 185)], -200, 450, wall)
    if toolhead:
        th_z = (zcut if frac < 1 else hi.z) + 2
        tx, ty = 26.0, 18.0
        head = material("head", "#2A2B2E", 0.45)
        prism("head", rounded_rect(58, 52, 6), th_z + 14, th_z + 70, head)
        prism("hotend", rounded_rect(22, 22, 3), th_z + 4, th_z + 14, material("hot", "#8A8D91", 0.3))
        prism("nozzle", ngon(2.5, 16), th_z, th_z + 4, material("brass", "#B8862B", 0.25))
        for o in bpy.data.objects:
            if o.name in ("head", "hotend", "nozzle"):
                o.location = (tx, ty, 0)
        prism("rail", [(-180, ty + 20), (180, ty + 20), (180, ty + 40), (-180, ty + 40)], th_z + 40, th_z + 62, material("rail", "#3A3C40", 0.35))
    if spaghetti:
        rnd = random.Random(7)
        smat = layer_material("spag", col, 0.35)
        for k in range(9):
            cd = bpy.data.curves.new(f"s{k}", "CURVE")
            cd.dimensions = "3D"
            cd.bevel_depth = 0.25
            sp = cd.splines.new("NURBS")
            npts = 14
            sp.points.add(npts - 1)
            x, y, z = rnd.uniform(-40, 40), rnd.uniform(-40, 40), zcut + rnd.uniform(0, 6)
            for p in sp.points:
                x += rnd.uniform(-14, 14); y += rnd.uniform(-14, 14); z = max(zcut - 2, z + rnd.uniform(-3, 5))
                p.co = (x, y, z, 1)
            sp.use_endpoint_u = True
            sp.order_u = 4
            o = link(bpy.data.objects.new(f"s{k}", cd))
            o.data.materials.append(smat)
    bg = sc.world.node_tree.nodes["Background"]
    bg.inputs["Color"].default_value = (0.02, 0.02, 0.025, 1)
    bg.inputs["Strength"].default_value = 1.0
    # chamber LED strip, warm, top front; plus a dim fill
    area((0, -120, 330), (0, 30, 0), 260, 330 ** 2 * 2.4, (1.0, 0.93, 0.82), size_y=24)
    area((-160, -60, 200), (0, 0, 20), 80, 220 ** 2 * 0.6, (0.85, 0.9, 1.0))
    add_camera((-95, -150, 175), (8, 14, 14), 21)
    sc.view_settings.exposure = 1.3
    render(f"{OUT}/ScreenshotMock-camera-{name}.jpg", "JPEG", 1280, 720, 64)


JOBS = [
    *[("cover-" + n, (lambda n=n: cover(n))) for n in MODELS],
    ("camera-honeycomb", lambda: camera("honeycomb", 0.64)),
    ("camera-gridfinity", lambda: camera("gridfinity", 0.22)),
    ("camera-twistvase", lambda: camera("twistvase", 0.31)),
    ("camera-phonestand", lambda: camera("phonestand", 1.0, toolhead=False)),
    ("camera-lampshade", lambda: camera("lampshade", 0.42, spaghetti=True)),
]

for job, run in JOBS:
    if not ONLY or job in ONLY:
        run()
