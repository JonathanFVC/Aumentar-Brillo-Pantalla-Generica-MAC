#!/usr/bin/env python3
"""Genera perfiles ICC v2 de pantalla (matriz + curva gamma) en ~/Library/ColorSync/Profiles. Detalle: README.md"""
import os, struct, datetime

SALIDA = os.path.expanduser("~/Library/ColorSync/Profiles")
D65 = (0.3127, 0.3290)
D50_XYZ = (0.9642, 1.0, 0.8249)

# (nombre, primarios xy R,G,B, blanco xy, gamma)
PERFILES = [
    ("sRGB gamma 2.2",         [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)], D65, 2.2),
    ("sRGB gamma 2.4",         [(0.640, 0.330), (0.300, 0.600), (0.150, 0.060)], D65, 2.4),
    ("Display P3 gamma 2.2",   [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)], D65, 2.2),
    ("Display P3 gamma 2.4",   [(0.680, 0.320), (0.265, 0.690), (0.150, 0.060)], D65, 2.4),
    ("Rec. 2020 gamma 2.2",    [(0.708, 0.292), (0.170, 0.797), (0.131, 0.046)], D65, 2.2),
    ("SMPTE-C gamma 2.2",      [(0.630, 0.340), (0.310, 0.595), (0.155, 0.070)], D65, 2.2),
    ("PAL EBU gamma 2.2",      [(0.640, 0.330), (0.290, 0.600), (0.150, 0.060)], D65, 2.2),
    ("ProPhoto gamma 2.2",     [(0.7347, 0.2653), (0.1596, 0.8404), (0.0366, 0.0001)], (0.3457, 0.3585), 2.2),
]

def xy_a_xyz(x, y): return (x / y, 1.0, (1 - x - y) / y)
def mul(a, b): return [[sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
def mulv(a, v): return [sum(a[i][k] * v[k] for k in range(3)) for i in range(3)]
def inv(m):
    a, b, c = m[0]; d, e, f = m[1]; g, h, i = m[2]
    det = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    return [[(e * i - f * h) / det, (c * h - b * i) / det, (b * f - c * e) / det],
            [(f * g - d * i) / det, (a * i - c * g) / det, (c * d - a * f) / det],
            [(d * h - e * g) / det, (b * g - a * h) / det, (a * e - b * d) / det]]

BRADFORD = [[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]]

def matriz_pcs(primarios, blanco):
    """Columnas = XYZ de R,G,B adaptados a D50 (Bradford)."""
    p = [xy_a_xyz(*xy) for xy in primarios]
    P = [[p[j][i] for j in range(3)] for i in range(3)]
    W = xy_a_xyz(*blanco)
    S = mulv(inv(P), W)
    M = [[P[i][j] * S[j] for j in range(3)] for i in range(3)]
    if abs(blanco[0] - 0.3457) > 1e-4:   # adaptar a D50 si el blanco no lo es
        rho_s = mulv(BRADFORD, W); rho_d = mulv(BRADFORD, D50_XYZ)
        D = [[rho_d[i] / rho_s[i] if i == j else 0 for j in range(3)] for i in range(3)]
        A = mul(inv(BRADFORD), mul(D, BRADFORD))
        M = mul(A, M)
    return M

def s15(v): return struct.pack(">i", int(round(v * 65536)))
def xyz_tag(x, y, z): return b"XYZ \x00\x00\x00\x00" + s15(x) + s15(y) + s15(z)
def pad4(b): return b + b"\x00" * ((4 - len(b) % 4) % 4)

def curva(gamma, n=1024):
    return b"curv\x00\x00\x00\x00" + struct.pack(">I", n) + b"".join(struct.pack(">H", round(65535 * (i / (n - 1)) ** gamma)) for i in range(n))

def desc_tag(texto):
    a = texto.encode("ascii") + b"\x00"
    return b"desc\x00\x00\x00\x00" + struct.pack(">I", len(a)) + a + struct.pack(">II", 0, 0) + struct.pack(">HB", 0, 0) + b"\x00" * 67

def texto_tag(t): return b"text\x00\x00\x00\x00" + t.encode("ascii") + b"\x00"

def construir(nombre, primarios, blanco, gamma):
    M = matriz_pcs(primarios, blanco)
    tags = [("desc", desc_tag(nombre)), ("cprt", texto_tag("Generado localmente (pantalla_jh207_generar_perfiles_icc.py), uso libre")),
            ("wtpt", xyz_tag(*D50_XYZ)),
            ("rXYZ", xyz_tag(M[0][0], M[1][0], M[2][0])), ("gXYZ", xyz_tag(M[0][1], M[1][1], M[2][1])), ("bXYZ", xyz_tag(M[0][2], M[1][2], M[2][2])),
            ("rTRC", curva(gamma)), ("gTRC", curva(gamma)), ("bTRC", curva(gamma))]
    # las tres curvas son idénticas: se comparte el mismo bloque
    n = len(tags)
    offset = 128 + 4 + 12 * n
    tabla = b""; cuerpo = b""; vistos = {}
    for sig, datos in tags:
        if datos in vistos: off, tam = vistos[datos]
        else:
            off, tam = offset + len(cuerpo), len(datos); cuerpo += pad4(datos); vistos[datos] = (off, tam)
        tabla += sig.encode() + struct.pack(">II", off, tam)
    ahora = datetime.datetime.now()
    cab = struct.pack(">I4sI4s4s4s", 0, b"\x00\x00\x00\x00", 0x02400000, b"mntr", b"RGB ", b"XYZ ")
    cab += struct.pack(">6H", ahora.year, ahora.month, ahora.day, ahora.hour, ahora.minute, ahora.second)
    cab += b"acsp" + b"APPL" + struct.pack(">I", 0) + b"\x00" * 4 + b"\x00" * 4 + b"\x00" * 8 + struct.pack(">I", 0)
    cab += s15(D50_XYZ[0]) + s15(D50_XYZ[1]) + s15(D50_XYZ[2]) + b"\x00" * 4 + b"\x00" * 16 + b"\x00" * 28
    assert len(cab) == 128, len(cab)
    todo = cab + struct.pack(">I", n) + tabla + cuerpo
    return struct.pack(">I", len(todo)) + todo[4:]

if __name__ == "__main__":
    os.makedirs(SALIDA, exist_ok=True)
    for nombre, prim, blanco, g in PERFILES:
        ruta = os.path.join(SALIDA, nombre + ".icc")
        open(ruta, "wb").write(construir(nombre, prim, blanco, g))
        print("creado:", ruta)
