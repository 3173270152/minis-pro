# Clean the eroded heightfield, export height grid + macro colour/normal textures for the game.
import numpy as np, os
from scipy import ndimage
from PIL import Image
h = np.load('gen/_work/h_ero.npy').astype(np.float32); b0 = np.load('gen/_work/h_base.npy').astype(np.float32); h = np.where(np.isfinite(h), h, b0)
b = np.load('gen/_work/h_base.npy').astype(np.float32)
m = ndimage.median_filter(h, 5)
g = ndimage.gaussian_filter(m, 2.0)
bad = np.abs(h - g) > 40.0
h = np.where(bad, g, m)
h = np.where(np.abs(h - b) > 400.0, ndimage.gaussian_filter(b, 2.0), h)
h = ndimage.gaussian_filter(h, 0.8)
N = h.shape[0]; ext = 60000.0; cell = 2 * ext / (N - 1)
yy, xx = np.meshgrid(np.linspace(-ext, ext, N), np.linspace(-ext, ext, N), indexing='ij')
d = np.sqrt(xx**2 + yy**2)
flat = np.clip((d - 1800) / 3200, 0, 1); flat = flat * flat * (3 - 2 * flat)
h = h * flat - 0.4
# height grid for runtime (1025^2 float32)
hs = h[::2, ::2].astype('<f4'); hs.tofile('gen/height.bin'); print('grid', hs.shape, float(h.max()))
gz, gx = np.gradient(h, cell)
slope = np.sqrt(gx**2 + gz**2)
nrm = np.dstack([-gx, np.ones_like(h), -gz]); nrm /= np.linalg.norm(nrm, axis=2, keepdims=True)
def save(a, name, size):
    Image.fromarray(a).resize((size, size), Image.LANCZOS).save(name)
os.makedirs('tex/terrain', exist_ok=True)
save(((nrm[..., [0, 2, 1]] * 0.5 + 0.5) * 255).astype(np.uint8), 'tex/terrain/macro_normal.png', 2048)
rng = np.random.default_rng(3)
n1 = ndimage.gaussian_filter(rng.standard_normal(h.shape), 6); n1 /= np.abs(n1).max()
strata = 0.5 + 0.5 * np.sin(h / 37.0 + n1 * 3.0)
sand = np.array([0.66, 0.53, 0.37]); grav = np.array([0.50, 0.44, 0.37]); rock = np.array([0.30, 0.25, 0.21]); rock2 = np.array([0.44, 0.36, 0.28]); snow = np.array([0.90, 0.92, 0.95])
rk = np.clip((slope - 0.25) / 0.35, 0, 1)
wash = np.clip(ndimage.gaussian_filter(-ndimage.laplace(h), 3) * 0.08, 0, 1) * (1 - rk)
c = sand[None, None] * (1 - np.clip(n1 * 0.5 + 0.5, 0, 1)[..., None] * 0.35) + grav[None, None] * (np.clip(n1 * 0.5 + 0.5, 0, 1)[..., None] * 0.35)
c = c * (1 - wash[..., None] * 0.25)
rc = rock[None, None] * (1 - strata[..., None]) + rock2[None, None] * strata[..., None]
c = c * (1 - rk[..., None]) + rc * rk[..., None]
sn = np.clip((h - 1500 - n1 * 250) / 300, 0, 1) * np.clip(1.2 - slope, 0, 1)
c = c * (1 - sn[..., None]) + snow[None, None] * sn[..., None]
ao = np.clip(1.0 + ndimage.gaussian_filter(ndimage.laplace(h), 4) * 0.02, 0.6, 1.0)
c = c * ao[..., None]
save((np.clip(c, 0, 1) ** (1 / 2.2) * 255).astype(np.uint8), 'tex/terrain/macro_color.png', 2048)
print('ok')
