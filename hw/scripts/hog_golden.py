"""
From-scratch reimplementation of cv2.HOGDescriptor.compute(), built from
reading OpenCV's actual C++ source (modules/objdetect/src/hog.cpp) and its
fastAtan2 polynomial (modules/core/src/mathfuncs_core.simd.hpp), NOT calling
cv2's HOG at all. This is checked against REAL cv2.HOGDescriptor.compute()
output at the bottom of this file -- if it doesn't match closely, something
about my reading of the algorithm is wrong, and no RTL should be built
against it yet.
"""
import numpy as np
import cv2

# ---- notebook's exact HOG config ----
WIN_W, WIN_H = 32, 32
BLOCK_W, BLOCK_H = 16, 16
STRIDE_W, STRIDE_H = 8, 8
CELL_W, CELL_H = 8, 8
NBINS = 9
GAMMA_CORRECTION = False   # cv2.HOGDescriptor() default
SIGNED_GRADIENT = False    # cv2.HOGDescriptor() default
L2HYS_THRESHOLD = 0.2      # cv2.HOGDescriptor() default

NCELLS_X = BLOCK_W // CELL_W   # 2
NCELLS_Y = BLOCK_H // CELL_H   # 2
BLOCK_HIST_SIZE = NCELLS_X * NCELLS_Y * NBINS   # 36
NBLOCKS_X = (WIN_W - BLOCK_W) // STRIDE_W + 1   # 3
NBLOCKS_Y = (WIN_H - BLOCK_H) // STRIDE_H + 1   # 3

# ---- exact fastAtan2 polynomial coefficients (from OpenCV source) ----
_ATAN2_P1 = 0.9997878412794807 * (180 / np.pi)
_ATAN2_P3 = -0.3258083974640975 * (180 / np.pi)
_ATAN2_P5 = 0.1555786518463281 * (180 / np.pi)
_ATAN2_P7 = -0.04432655554792128 * (180 / np.pi)
_DBL_EPS = 2.2204460492503131e-16

def fast_atan2_deg(y, x):
    """Vectorized reimplementation of OpenCV's cv::fastAtan2 (degrees, 0-360)."""
    y = np.asarray(y, dtype=np.float32)
    x = np.asarray(x, dtype=np.float32)
    ax = np.abs(x); ay = np.abs(y)
    use_ax = ax >= ay
    c = np.where(use_ax, ay / (ax + _DBL_EPS), ax / (ay + _DBL_EPS)).astype(np.float32)
    c2 = c * c
    poly = (((_ATAN2_P7 * c2 + _ATAN2_P5) * c2 + _ATAN2_P3) * c2 + _ATAN2_P1) * c
    a = np.where(use_ax, poly, 90.0 - poly).astype(np.float32)
    a = np.where(x < 0, 180.0 - a, a)
    a = np.where(y < 0, 360.0 - a, a)
    return a

def reflect101(idx, size):
    """BORDER_REFLECT_101: e.g. for size=5: gcfedcba|abcdefg|gfedcba"""
    if size == 1:
        return np.zeros_like(idx)
    period = 2 * size - 2
    idx = np.mod(idx, period)
    idx = np.where(idx < 0, idx + period, idx)
    return np.where(idx >= size, period - idx, idx)

def compute_gradient(img):
    """img: (H,W) uint8 grayscale. Returns mag (H,W) float32, angle_deg (H,W) float32 [0,360)."""
    H, W = img.shape
    imgf = img.astype(np.float32)   # gammaCorrection=False -> identity LUT
    xs = np.arange(-1, W + 1)
    ys = np.arange(-1, H + 1)
    xmap = reflect101(xs, W)
    ymap = reflect101(ys, H)
    padded = imgf[np.ix_(ymap, xmap)]   # shape (H+2, W+2), index [y+1, x+1] = img at (ymap[y+1], xmap[x+1])
    dx = padded[1:-1, 2:] - padded[1:-1, :-2]
    dy = padded[2:, 1:-1] - padded[:-2, 1:-1]
    mag = np.sqrt(dx * dx + dy * dy).astype(np.float32)
    angle_deg = fast_atan2_deg(dy, dx)
    return mag, angle_deg, dx, dy

def gaussian_weight_table():
    """blockSize x blockSize Gaussian spatial weight, sigma=(blockW+blockH)/8."""
    sigma = (BLOCK_W + BLOCK_H) / 8.0
    scale = 1.0 / (2 * sigma * sigma)
    bh, bw = BLOCK_H * 0.5, BLOCK_W * 0.5
    w = np.zeros((BLOCK_H, BLOCK_W), dtype=np.float32)
    for i in range(BLOCK_H):
        for j in range(BLOCK_W):
            w[i, j] = np.exp(-((i - bh) ** 2 + (j - bw) ** 2) * scale)
    return w

def cell_splat_table():
    """For each pixel (i,j) in the block, bilinear splat weights into up to 4 cells.
    Returns dict (i,j) -> list of (cellX, cellY, weight)."""
    table = {}
    for i in range(BLOCK_H):
        for j in range(BLOCK_W):
            cellX = (j + 0.5) / CELL_W - 0.5
            cellY = (i + 0.5) / CELL_H - 0.5
            icx0 = int(np.floor(cellX)); icy0 = int(np.floor(cellY))
            icx1 = icx0 + 1; icy1 = icy0 + 1
            fx = cellX - icx0; fy = cellY - icy0
            entries = []
            for (cx, cy, w) in [(icx0, icy0, (1 - fx) * (1 - fy)),
                                 (icx1, icy0, fx * (1 - fy)),
                                 (icx0, icy1, (1 - fx) * fy),
                                 (icx1, icy1, fx * fy)]:
                if 0 <= cx < NCELLS_X and 0 <= cy < NCELLS_Y and w != 0:
                    entries.append((cx, cy, w))
            table[(i, j)] = entries
    return table

_GAUSS = gaussian_weight_table()
_SPLAT = cell_splat_table()
_ANGLE_SCALE = NBINS / (2 * np.pi if SIGNED_GRADIENT else np.pi)

def compute_block_hist(mag, angle_deg, y0, x0):
    """mag,angle_deg: full-image gradient arrays. y0,x0: block top-left in the window."""
    hist = np.zeros((NCELLS_X, NCELLS_Y, NBINS), dtype=np.float64)   # X-major: (icellX*ncells.height+icellY)*nbins
    angle_rad = np.deg2rad(angle_deg)
    for i in range(BLOCK_H):
        for j in range(BLOCK_W):
            m = mag[y0 + i, x0 + j] * _GAUSS[i, j]
            if m == 0:
                continue
            a = angle_rad[y0 + i, x0 + j] * _ANGLE_SCALE - 0.5
            hidx = int(np.floor(a))
            frac = a - hidx
            h0 = hidx % NBINS
            h1 = (hidx + 1) % NBINS
            for (cx, cy, cw) in _SPLAT[(i, j)]:
                hist[cx, cy, h0] += m * cw * (1 - frac)
                hist[cx, cy, h1] += m * cw * frac
    return hist.flatten()   # X-major matches OpenCV's histOfs = (icellX*ncells.height + icellY)*nbins

def l2hys_normalize(h):
    sz = len(h)
    n1 = np.sqrt(np.sum(h ** 2)) + sz * 0.1
    out = h / n1
    out = np.minimum(out, L2HYS_THRESHOLD)
    n2 = np.sqrt(np.sum(out ** 2)) + 1e-3
    return out / n2

def compute_hog(img):
    mag, angle_deg, dx, dy = compute_gradient(img)
    blocks = []
    for bx in range(NBLOCKS_X):
        for by in range(NBLOCKS_Y):
            y0 = by * STRIDE_H
            x0 = bx * STRIDE_W
            h = compute_block_hist(mag, angle_deg, y0, x0)
            h = l2hys_normalize(h)
            blocks.append(h)
    return np.concatenate(blocks).astype(np.float32)


if __name__ == "__main__":
    np.random.seed(123)
    img = np.random.randint(0, 256, (WIN_H, WIN_W), dtype=np.uint8)

    mine = compute_hog(img)

    hog_cv = cv2.HOGDescriptor(_winSize=(WIN_W, WIN_H), _blockSize=(BLOCK_W, BLOCK_H),
                                _blockStride=(STRIDE_W, STRIDE_H), _cellSize=(CELL_W, CELL_H),
                                _nbins=NBINS)
    real = hog_cv.compute(img).flatten()

    print("mine shape:", mine.shape, " real shape:", real.shape)
    diff = np.abs(mine - real)
    print("max abs diff:", diff.max())
    print("mean abs diff:", diff.mean())
    print("first 20 mine:", mine[:20])
    print("first 20 real:", real[:20])
    print("corr:", np.corrcoef(mine, real)[0, 1])
