#!/usr/bin/env python3
"""Offline terrain generator for the Jiuquan-style launch site (Gobi plain + Qilian/Heishan-style ranges).

Run from the project root:  python3 gen/terrain_gen.py  [--stage all|height|bake] [--preview DIR]
Needs numpy, scipy, pillow.  Takes a few minutes; the game only LOADS the results:
  gen/terrain_mesh.bin   adaptive RTIN mesh (positions + indices), built into an ArrayMesh by scripts/bake.gd
  gen/height.bin         zstd-free raw uint16 2049x2049 heightfield (0.05 m steps) for World.height()
  tex/terrain/macro_color.png  2048^2 albedo (RGB) + baked sky-visibility AO (A)
  tex/terrain/macro_splat.png  2048^2 R rock, G scree/gravel, B dry-wash/riverbed, A snow
  tex/terrain/macro_normal.png 4096^2 world-space normal, R=x G=z (y reconstructed)
  tex/terrain/macro_height.exr 1024^2 half-float height for shader sun-shadow raymarching
Frame: x = east, z = south (north = -z), pad at (0,0); grid covers [-60 km, 60 km]^2, row index = z.
"""
import sys, os, time, struct, argparse
import numpy as np
from scipy import ndimage
from PIL import Image

EXT = 60000.0                 # half extent (m)
N1 = 2048                     # erosion grid (cells)
N2 = 4096                     # mesh/normal grid (cells)
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WORK = os.path.join(ROOT, "gen", "_work")
rng = np.random.default_rng(1234)

def log(*a):
    print("[%6.1fs]" % (time.time() - T0), *a, flush=True)

# ------------------------------------------------------------------ noise
_perm = np.random.default_rng(7).permutation(256)
_perm = np.concatenate([_perm, _perm]).astype(np.int32)
_ang = np.random.default_rng(8).uniform(0, 2 * np.pi, 256)
_gx, _gy = np.cos(_ang).astype(np.float32), np.sin(_ang).astype(np.float32)

def perlin(x, y, seed=0):
    """2D gradient noise, roughly in [-0.7, 0.7]. x, y float arrays (noise units)."""
    x = x + seed * 17.13; y = y + seed * 31.71
    xi = np.floor(x).astype(np.int32); yi = np.floor(y).astype(np.int32)
    xf = (x - xi).astype(np.float32); yf = (y - yi).astype(np.float32)
    xi &= 255; yi &= 255
    def g(ix, iy, dx, dy):
        h = _perm[_perm[ix] + iy]
        return _gx[h] * dx + _gy[h] * dy
    n00 = g(xi, yi, xf, yf); n10 = g(xi + 1, yi, xf - 1, yf)
    n01 = g(xi, yi + 1, xf, yf - 1); n11 = g(xi + 1, yi + 1, xf - 1, yf - 1)
    u = xf * xf * xf * (xf * (xf * 6 - 15) + 10); v = yf * yf * yf * (yf * (yf * 6 - 15) + 10)
    a = n00 + u * (n10 - n00); b = n01 + u * (n11 - n01)
    return a + v * (b - a)

def fbm(x, y, oct=6, lac=2.03, gain=0.5, seed=0):
    s = np.zeros_like(x, dtype=np.float32); a = 1.0; f = 1.0; norm = 0.0
    for o in range(oct):
        s += a * perlin(x * f, y * f, seed + o * 3); norm += a; a *= gain; f *= lac
    return s / norm

def ridged(x, y, oct=8, lac=2.07, gain=0.5, seed=0, offset=1.0):
    """Musgrave ridged multifractal, ~[0,1]."""
    s = np.zeros_like(x, dtype=np.float32); w = np.ones_like(x, dtype=np.float32); f = 1.0; a = 1.0; norm = 0.0
    for o in range(oct):
        n = offset - np.abs(perlin(x * f, y * f, seed + o * 5) * 1.5)
        n = n * n
        n *= w
        w = np.clip(n * 1.6, 0.0, 1.0)
        s += n * a; norm += a
        a *= gain; f *= lac
    return s / norm

# ------------------------------------------------------------------ base heightfield
def base_height(n):
    c = (np.arange(n + 1, dtype=np.float32) / n * 2.0 - 1.0) * EXT
    X, Z = np.meshgrid(c, c)                    # X east, Z south ; [row=z, col=x]
    xk, zk = X / 1000.0, Z / 1000.0             # km
    r = np.sqrt(xk * xk + zk * zk) + 1e-6
    # compass azimuth (0 = north = -z, 90 = east = +x)
    az = np.degrees(np.arctan2(xk, -zk)) % 360.0
    log("noise warp")
    # domain warp (km)
    wx = xk + 7.0 * fbm(xk / 23.0, zk / 23.0, 4, seed=11) + 2.0 * fbm(xk / 6.0, zk / 6.0, 3, seed=12)
    wz = zk + 7.0 * fbm(xk / 23.0 + 5.2, zk / 23.0 + 1.3, 4, seed=13) + 2.0 * fbm(xk / 6.0 + 3.1, zk / 6.0, 3, seed=14)
    wr = np.sqrt(wx * wx + wz * wz) + 1e-6
    waz = np.degrees(np.arctan2(wx, -wz)) % 360.0

    def sector(a, a0, a1, soft):     # smooth membership of azimuth interval [a0,a1] (deg, may wrap)
        d0 = (a - a0) % 360.0; span = (a1 - a0) % 360.0
        inside = np.clip(np.minimum(d0, span - d0) / soft, 0, 1)
        inside[d0 > span] = 0.0
        return inside * inside * (3 - 2 * inside)

    # --- main range (Qilian-like): arc ~30 km from the pad, sector SW -> W -> N -> NE, abrupt front, long back slope
    rc = 31.0 + 5.0 * fbm(waz / 40.0, np.zeros_like(waz) + 3.3, 3, seed=21) * 2.0
    dd = wr - rc
    prof = np.where(dd < 0, np.exp(-(dd / 4.5) ** 2), np.exp(-(dd / 13.0) ** 2))
    amp_az = sector(waz, 205.0, 45.0, 35.0) * (0.75 + 0.5 * fbm(waz / 30.0, np.ones_like(waz) * 7.7, 3, seed=22) * 2)
    m_main = prof * np.clip(amp_az, 0, 1.3)
    log("ridged main")
    rm = ridged(wx / 9.0, wz / 9.0, 9, seed=31)
    rm2 = ridged(wx / 3.2 + 9.1, wz / 3.2, 6, seed=37)
    main = m_main ** 1.15 * (2900.0 * (0.25 + 0.75 * rm) + 500.0 * rm2 * m_main)

    # --- Heishan-like dark hill belt 13-21 km W/SW: lower, more chaotic, isolated knobs
    dd2 = wr - (17.0 + 2.0 * fbm(waz / 25.0, np.ones_like(waz) * 1.1, 3, seed=41) * 2)
    m_h = np.exp(-(dd2 / 3.2) ** 2) * sector(waz, 215.0, 330.0, 25.0)
    rh = ridged(wx / 2.6 + 3.0, wz / 2.6 - 7.0, 7, seed=43)
    knob = np.clip(fbm(wx / 4.0, wz / 4.0, 4, seed=44) * 2.2 + 0.25, 0, 1)
    heishan = m_h * knob * (950.0 * rh)

    # --- scattered low inselbergs to the E and S (so the far horizon is never empty), 28-58 km
    m_i = smooth01((r - 26.0) / 10.0) * sector(az, 60.0, 200.0, 30.0)
    ins = np.clip(fbm(wx / 7.0 + 40.0, wz / 7.0, 5, seed=51) * 2.6 - 0.35, 0, 1) ** 1.6
    insel = m_i * ins * 650.0 * (0.5 + ridged(wx / 3.0, wz / 3.0 + 50.0, 6, seed=53))

    # far background range beyond the main one (N/W edge, keeps the skyline layered)
    m_far = smooth01((wr - 44.0) / 8.0) * sector(waz, 240.0, 20.0, 30.0)
    far = m_far * 2300.0 * ridged(wx / 11.0 - 20.0, wz / 11.0, 8, seed=61) ** 1.3

    mount = np.maximum.reduce([main, heishan, insel, far])
    # plain: gentle regional tilt up toward the main range + low undulation
    plain = 12.0 * fbm(xk / 4.0, zk / 4.0, 5, seed=71) + 4.0 * fbm(xk / 0.9, zk / 0.9, 3, seed=72)
    plain += 140.0 * smooth01((wr - 6.0) / 30.0) * sector(waz, 200.0, 50.0, 60.0)
    h = plain + mount
    return h.astype(np.float32), X, Z

def smooth01(t):
    t = np.clip(t, 0.0, 1.0); return t * t * (3 - 2 * t)

# ------------------------------------------------------------------ erosion
def thermal(h, cell, talus_deg=34.0, iters=40, k=0.25):
    tal = np.tan(np.radians(talus_deg)) * cell
    for _ in range(iters):
        p = np.pad(h, 1, mode="edge")
        d = np.zeros_like(h)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            nb = p[1 + dy:1 + dy + h.shape[0], 1 + dx:1 + dx + h.shape[1]]
            diff = h - nb - tal
            mv = np.where(diff > 0, diff * k * 0.25, 0.0)
            d -= mv
            # receive: neighbour's excess toward us
            nbd = nb - h - tal
            d += np.where(nbd > 0, nbd * k * 0.25, 0.0)
        h = h + d
    return h

def droplets(h, cell, n_drops, batch=200000, steps=72, inertia=0.08, cap_f=6.0, min_slope=0.01,
             erode=0.35, deposit=0.25, evap=0.02, grav=8.0, radius=2, seed=0, mask=None):
    """Vectorised particle hydraulic erosion. h in metres; works in cell units internally."""
    H = (h / cell).astype(np.float32)
    ny, nx = H.shape
    flat = H.reshape(-1)
    r = np.random.default_rng(seed)
    # erosion brush offsets/weights
    offs = []; wts = []
    for oy in range(-radius, radius + 1):
        for ox in range(-radius, radius + 1):
            d = np.hypot(ox, oy)
            if d <= radius + 0.01:
                offs.append((oy, ox)); wts.append(max(0.0, radius + 0.5 - d))
    wts = np.array(wts, np.float32); wts /= wts.sum()
    done = 0
    while done < n_drops:
        m = min(batch, n_drops - done); done += m
        if mask is None:
            px = r.uniform(radius + 1, nx - radius - 2, m).astype(np.float32)
            py = r.uniform(radius + 1, ny - radius - 2, m).astype(np.float32)
        else:
            idx = r.choice(mask.size, m, p=mask.reshape(-1))
            py = (idx // nx + r.uniform(0, 1, m)).astype(np.float32); px = (idx % nx + r.uniform(0, 1, m)).astype(np.float32)
            np.clip(px, radius + 1, nx - radius - 2, out=px); np.clip(py, radius + 1, ny - radius - 2, out=py)
        dx = np.zeros(m, np.float32); dy = np.zeros(m, np.float32)
        v = np.ones(m, np.float32); w = np.ones(m, np.float32); s = np.zeros(m, np.float32)
        for st in range(steps):
            ix = px.astype(np.int32); iy = py.astype(np.int32)
            fx = px - ix; fy = py - iy
            i00 = iy * nx + ix
            h00 = flat[i00]; h10 = flat[i00 + 1]; h01 = flat[i00 + nx]; h11 = flat[i00 + nx + 1]
            gx = (h10 - h00) * (1 - fy) + (h11 - h01) * fy
            gy = (h01 - h00) * (1 - fx) + (h11 - h10) * fx
            hc = h00 * (1 - fx) * (1 - fy) + h10 * fx * (1 - fy) + h01 * (1 - fx) * fy + h11 * fx * fy
            dx = dx * inertia - gx * (1 - inertia); dy = dy * inertia - gy * (1 - inertia)
            ln = np.sqrt(dx * dx + dy * dy)
            z = ln < 1e-6
            if z.any():
                a = r.uniform(0, 2 * np.pi, int(z.sum())).astype(np.float32); dx[z] = np.cos(a); dy[z] = np.sin(a); ln[z] = 1.0
            dx /= ln; dy /= ln
            nxp = px + dx; nyp = py + dy
            alive = (nxp >= radius + 1) & (nxp < nx - radius - 2) & (nyp >= radius + 1) & (nyp < ny - radius - 2)
            nxp = np.where(alive, nxp, px); nyp = np.where(alive, nyp, py)
            jx = nxp.astype(np.int32); jy = nyp.astype(np.int32); gfx = nxp - jx; gfy = nyp - jy
            j00 = jy * nx + jx
            hn = flat[j00] * (1 - gfx) * (1 - gfy) + flat[j00 + 1] * gfx * (1 - gfy) + flat[j00 + nx] * (1 - gfx) * gfy + flat[j00 + nx + 1] * gfx * gfy
            dh = np.where(alive, hn - hc, 0.0).astype(np.float32)
            cap = np.maximum(-dh, min_slope) * v * w * cap_f
            dep_mask = (s > cap) | (dh > 0)
            amt_dep = np.where(dh > 0, np.minimum(dh, s), (s - cap) * deposit)
            amt_dep = np.where(dep_mask, amt_dep, 0.0).astype(np.float32)
            amt_ero = np.where(dep_mask, 0.0, np.minimum((cap - s) * erode, -dh)).astype(np.float32)
            amt_ero = np.maximum(amt_ero, 0.0)
            if not alive.all():   # dying droplets drop everything
                amt_dep = np.where(alive, amt_dep, s); amt_ero = np.where(alive, amt_ero, 0.0)
            s = s + amt_ero - amt_dep
            # deposit bilinear at old pos
            delta = np.zeros_like(flat)
            np.add.at(delta, i00, amt_dep * (1 - fx) * (1 - fy)); np.add.at(delta, i00 + 1, amt_dep * fx * (1 - fy))
            np.add.at(delta, i00 + nx, amt_dep * (1 - fx) * fy); np.add.at(delta, i00 + nx + 1, amt_dep * fx * fy)
            for (oy, ox), wt in zip(offs, wts):
                np.add.at(delta, i00 + oy * nx + ox, -amt_ero * wt)
            flat += delta
            v = np.sqrt(np.maximum(v * v + dh * grav, 0.0)).astype(np.float32)
            w *= (1 - evap)
            px, py = nxp, nyp
            keep = alive & (w > 0.02)
            if not keep.all():
                px, py, dx, dy, v, w, s = px[keep], py[keep], dx[keep], dy[keep], v[keep], w[keep], s[keep]
                if px.size == 0: break
        log("  droplets", done, "/", n_drops)
    return (flat.reshape(ny, nx) * cell).astype(np.float32)

def hillshade(h, cell, path, az=315, alt=35, size=1024, col=None):
    gy, gx = np.gradient(h, cell)
    a = np.radians(az); e = np.radians(alt)
    L = np.array([np.sin(a) * np.cos(e), -np.cos(a) * np.cos(e), np.sin(e)])
    n = np.stack([-gx, -gy, np.ones_like(h)], -1); n /= np.linalg.norm(n, axis=-1, keepdims=True)
    s = np.clip((n * np.array([L[0], L[1], L[2]])).sum(-1), 0, 1)
    if col is None:
        img = (np.clip(s, 0, 1) ** 0.8 * 255).astype(np.uint8)
        im = Image.fromarray(img)
    else:
        im = Image.fromarray((np.clip(col * (0.35 + 0.9 * s[..., None]), 0, 1) ** (1 / 2.2) * 255).astype(np.uint8))
    im.resize((size, size), Image.LANCZOS).save(path)

# ------------------------------------------------------------------ main stages
def stage_height():
    cell = 2 * EXT / N1
    h, X, Z = base_height(N1)
    log("base done", h.min(), h.max())
    np.save(os.path.join(WORK, "h_base.npy"), h)
    hillshade(h, cell, os.path.join(WORK, "hs_base.png"))
    # erosion: emit more droplets on the mountains (where it matters)
    mt = np.clip((h - 60.0) / 400.0, 0.05, 1.0); mt = mt / mt.sum()
    h = thermal(h, cell, 38.0, 20)
    h = droplets(h, cell, 900000, steps=80, seed=1, mask=mt, radius=2)
    h = thermal(h, cell, 33.0, 25)
    h = droplets(h, cell, 500000, steps=60, seed=2, radius=1, erode=0.25, cap_f=4.0)
    log("eroded", h.min(), h.max())
    np.save(os.path.join(WORK, "h_ero.npy"), h)
    hillshade(h, cell, os.path.join(WORK, "hs_ero.png"))

if __name__ == "__main__":
    T0 = time.time()
    ap = argparse.ArgumentParser(); ap.add_argument("--stage", default="all")
    A = ap.parse_args()
    os.makedirs(WORK, exist_ok=True)
    if A.stage in ("all", "height"): stage_height()
