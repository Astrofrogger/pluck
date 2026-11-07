# Pluck's raw-domain denoiser. Part of Pluck, under Pluck's own licence (as pluck_denoise.py, which runs it).
# Written from scratch; uses rawpy (MIT, wraps LibRaw LGPL-2.1/CDDL), NumPy, PyTorch and tifffile (BSD),
# and the DRUNet weights from KAIR (MIT). The network below is a fresh definition of DRUNet's published
# architecture (Zhang et al., "Plug-and-Play Image Restoration", 2021), shaped to load them.
#
# The noise is taken out of the sensor's own mosaic, before any demosaicing, where each pixel's noise is
# still independent and follows the sensor's physics: variance = a*x + b (photon shot noise plus read
# noise), fitted from the photo itself. The cleaned mosaic is written back as a DNG, and so is the
# untouched one, in the same wrapper (and Apple's lens correction, fitted from two decodes, as a
# WarpRectilinear opcode): Pluck decodes both the same way and mixes them (the Amount), so they line up.
#
#   {"do": "denoise_raw", "input": raw, "output": clean dng, "noisy": dng, "weights": drunet_color.pth,
#    "lens": [off.tif, on.tif] (optional: Apple's half-size decodes without and with its lens correction)}
#       -> {"ok": true, "version": 1, "a": .., "b": .., "warp": [k0..k3] or null, "seconds": ..}
#       or {"ok": false, "unsupported": why} (not a Bayer RAW: Pluck uses its other denoiser)
import struct
import time

import numpy as np

VERSION = 1  # PhotoRender.rawDenoiseVersion


class Unsupported(Exception):
    pass


# MARK: - Mosaic in, mosaic out

def read(path):
    """The photo's Bayer mosaic as four half-size planes (R, G1, G2, B), 0…1 above the black, and what's
    needed to write it back."""
    import rawpy
    try:
        raw = rawpy.imread(path)
    except (rawpy.LibRawError, OSError) as why:
        raise Unsupported(f"not a RAW file LibRaw reads ({type(why).__name__})")
    with raw:
        desc = raw.color_desc.decode()
        if raw.raw_type != rawpy.RawType.Flat or raw.num_colors != 3 or len(desc) != 4 or sorted(desc) != list("BGGR"):
            raise Unsupported("not a Bayer RGB sensor (X-Trans, Foveon, monochrome or linear DNG)")
        colors = raw.raw_colors_visible
        cfa = colors[:2, :2]
        if not (np.tile(cfa, (4, 4)) == colors[:8, :8]).all():
            raise Unsupported("CFA is not a 2x2 pattern")
        mosaic = raw.raw_image_visible.astype(np.float32)
        h, w = mosaic.shape
        mosaic = mosaic[: h // 2 * 2, : w // 2 * 2]
        black = np.array(raw.black_level_per_channel, np.float32)  # per colour index
        white = float(raw.white_level)
        letters = [desc[cfa[i, j]] for i in range(2) for j in range(2)]
        if sorted(letters) != list("BGGR"):
            raise Unsupported("CFA is not RGGB in some order")
        blacks = np.array([black[cfa[i, j]] for i in range(2) for j in range(2)], np.float32)
        cells = [mosaic[i::2, j::2] for i in range(2) for j in range(2)]
        greens = [k for k, c in enumerate(letters) if c == "G"]
        order = [letters.index("R"), greens[0], greens[1], letters.index("B")]
        planes = np.stack([(cells[k] - blacks[k]) / (white - blacks[k]) for k in order])
        wb = list(raw.camera_whitebalance)  # by colour index R G B G
        meta = {
            "order": order, "cfa": [int("RGB".index(c)) for c in letters], "shape": mosaic.shape,
            "xyz_to_cam": np.array(raw.rgb_xyz_matrix[:3], np.float64),
            "neutral": [wb[1] / wb[0], 1.0, wb[1] / wb[2]] if wb[0] > 0 and wb[2] > 0 else [0.5, 1.0, 0.5],
            "flip": raw.sizes.flip, "crop": _crop(raw.sizes, mosaic.shape),
        }
    return planes, meta


def _crop(sizes, shape):
    """The decode's frame inside the mosaic: left, top, width, height."""
    h, w = shape
    left, top, cw, ch = sizes.crop_left_margin, sizes.crop_top_margin, sizes.crop_width, sizes.crop_height
    if not cw or not ch:
        return 0, 0, w, h
    if left == 0 and top == 0:
        # shortcut: LibRaw gives no margins for Sony's 6000x4000 crop; centred, as Apple's ARW decode places it
        # (measured). Upgrade to per-make margins if another camera lands off by a few pixels (the self-test shows it).
        left, top = (w - cw) // 2, (h - ch) // 2
    return left, top, cw, ch


def unpack(planes, meta):
    h, w = meta["shape"]
    out = np.empty((h, w), np.float32)
    for p, k in enumerate(meta["order"]):
        out[k // 2::2, k % 2::2] = planes[p]
    return out


def _rational(values, den=10000):
    flat = []
    for v in values:
        flat += [int(round(float(v) * den)), den]
    return tuple(flat)


def write_dng(path, mosaic, meta, make_model=("", ""), warp=None):
    """The mosaic (0…1 above black) as an uncompressed 16-bit CFA DNG, four times finer than the camera's
    14 bits so the cleaned values aren't rounded back to steps."""
    import tifffile
    black, white = 2048, 65532
    codes = np.clip(np.round(mosaic * (white - black) + black), 0, 65535).astype(np.uint16)
    orientation = {0: 1, 3: 3, 5: 8, 6: 6}.get(meta["flip"], 1)
    left, top, cw, ch = meta["crop"]
    make, model = make_model
    tags = [
        (271, 2, 0, make, True), (272, 2, 0, model, True), (274, 3, 1, orientation, True),
        (33421, 3, 2, (2, 2), True), (33422, 1, 4, tuple(meta["cfa"]), True),
        (50706, 1, 4, (1, 4, 0, 0), True), (50707, 1, 4, (1, 3, 0, 0), True),
        (50708, 2, 0, f"{make} {model}".strip() or "Pluck", True),
        (50713, 3, 2, (1, 1), True), (50714, 4, 1, black, True), (50717, 4, 1, white, True),
        (50719, 4, 2, (left, top), True), (50720, 4, 2, (cw, ch), True),
        (50721, 10, 9, _rational(meta["xyz_to_cam"].ravel()), True),
        (50778, 3, 1, 21, True),  # ColorMatrix1 is LibRaw's D65 matrix
        (50728, 5, 3, _rational(meta["neutral"], den=1000000), True),
    ]
    if warp is not None:
        tags.append((51022, 7, 0, _warp_rectilinear(warp), True))  # OpcodeList3
    tifffile.imwrite(path, codes, photometric=32803, compression=None, extratags=tags, metadata=None, subfiletype=0)


def _warp_rectilinear(k, centre=(0.5, 0.5)):
    """A DNG WarpRectilinear opcode (one plane, radial terms only), big-endian as the spec has it."""
    params = struct.pack(">I6d2d", 1, *(list(k) + [0.0] * 4)[:4], 0.0, 0.0, *centre)
    return struct.pack(">I", 1) + struct.pack(">IIII", 1, 0x01030000, 1, len(params)) + params


# MARK: - Apple's lens correction, as a radial warp

def _shift(p, q):
    """Where q's content sits against p's (phase correlation, to a tenth of a pixel or so)."""
    F = np.fft.fft2(q - q.mean()) * np.conj(np.fft.fft2(p - p.mean()))
    r = np.fft.ifft2(F / (np.abs(F) + 1e-9)).real
    s = r.shape[0]
    iy, ix = np.unravel_index(r.argmax(), r.shape)

    def fine(m, z, c):  # parabola through the peak and its neighbours
        return 0.0 if abs(m - 2 * z + c) < 1e-12 else 0.5 * (m - c) / (m - 2 * z + c)
    dy = iy + fine(r[iy - 1, ix], r[iy, ix], r[(iy + 1) % s, ix])
    dx = ix + fine(r[iy, ix - 1], r[iy, ix], r[iy, (ix + 1) % s])
    return (dy if dy < s / 2 else dy - s), (dx if dx < s / 2 else dx - s), float(r.max())


def fit_warp(off_path, on_path, meta):
    """Apple's lens correction (decodes of the ARW without and with it) as WarpRectilinear's radial terms, or
    None (no correction to speak of, or too little detail to measure it)."""
    import tifffile

    def luma(f):
        x = tifffile.imread(f)[..., :3].astype(np.float32).mean(-1)
        return x / max(float(np.percentile(x, 99.5)), 1e-6)
    off, on = luma(off_path), luma(on_path)
    if off.shape != on.shape:
        return None
    H, W = off.shape
    left, top, cw, ch = meta["crop"]
    scale = cw / W  # the half-size decode to the mosaic's pixels
    s, P, Q = 128, [], []
    for y0 in range(32, H - s - 32, 75):
        for x0 in range(32, W - s - 32, 75):
            p, q = on[y0:y0 + s, x0:x0 + s], off[y0:y0 + s, x0:x0 + s]
            if p.std() < 0.02:
                continue
            dy, dx, peak = _shift(p, q)
            if peak < 0.15 or abs(dy) > s / 4 or abs(dx) > s / 4:
                continue
            P.append((x0 + s / 2, y0 + s / 2))
            Q.append((x0 + s / 2 + dx, y0 + s / 2 + dy))
    if len(P) < 12:
        return None
    # Into the mosaic's coordinates, where the opcode works (its centre is the mosaic's).
    P = np.array(P) * scale + (left, top)
    Q = np.array(Q) * scale + (left, top)
    h, w = meta["shape"]
    c = np.array([w / 2, h / 2])
    m = np.hypot(*c)
    rp, rq = np.hypot(*(P - c).T) / m, np.hypot(*(Q - c).T) / m
    use = rp > 0.15
    for _ in range(3):  # drop the matches that don't fit (repeating texture, moving things)
        A = np.stack([np.ones(use.sum()), rp[use] ** 2, rp[use] ** 4, rp[use] ** 6], 1)
        k = np.linalg.lstsq(A, rq[use] / rp[use], rcond=None)[0]
        miss = np.abs(rq - rp * (np.stack([np.ones_like(rp), rp ** 2, rp ** 4, rp ** 6], 1) @ k)) * m
        use = (rp > 0.15) & (miss < max(1.0, 3 * float(np.median(miss[rp > 0.15]))))
        if use.sum() < 12:
            return None
    k = [float(v) for v in k]
    # No correction worth a warp: under half a pixel at the corners.
    corner = abs(sum(k) - 1) * m
    return None if corner < 0.5 else k


# MARK: - The noise, from the photo itself

def fit_noise(planes):
    """variance = a*x + b, robustly: the finest diagonal Haar detail of each plane (white noise passes it at
    unit gain, smooth light doesn't), its trimmed spread in brightness bins, then a line through them with the
    outliers (texture) dropped."""
    p = planes[:, : planes.shape[1] // 2 * 2, : planes.shape[2] // 2 * 2]
    a_, b_, c_, d_ = p[:, 0::2, 0::2], p[:, 0::2, 1::2], p[:, 1::2, 0::2], p[:, 1::2, 1::2]
    mean = ((a_ + b_ + c_ + d_) / 4).ravel()
    diag = ((a_ - b_ - c_ + d_) / 2).ravel()
    keep = (mean > np.percentile(mean, 0.1)) & (mean < 0.9)
    mean, diag = mean[keep], diag[keep]
    edges = np.unique(np.quantile(mean, np.linspace(0, 1, 41)))
    xs, vs, ns = [], [], []
    for lo, hi in zip(edges[:-1], edges[1:]):
        inside = (mean >= lo) & (mean < hi)
        if inside.sum() < 500:
            continue
        d = diag[inside]
        xs.append(float(np.median(mean[inside])))
        # Mean |d| below its 90th percentile, scaled for a Gaussian: robust to texture like a MAD, but not
        # stepped by the raw's coarse codes (Sony's shadows come in 4-DN steps).
        dev = np.abs(d - np.median(d))
        vs.append(float((dev[dev <= np.percentile(dev, 90)].mean() / 0.65745) ** 2))
        ns.append(int(inside.sum()))
    if len(xs) < 4:
        raise Unsupported("too little of the photo to measure its noise")
    xs, vs, ns = np.array(xs), np.array(vs), np.array(ns, float)
    use = np.ones(len(xs), bool)
    for _ in range(4):
        wts = ns[use] / np.maximum(vs[use], 1e-12) ** 2  # relative errors alike in every bin
        A = np.stack([xs[use], np.ones(use.sum())], 1)
        a, b = np.linalg.lstsq(A * np.sqrt(wts)[:, None], vs[use] * np.sqrt(wts), rcond=None)[0]
        model = a * xs + b
        use = np.abs(vs - model) <= 0.25 * np.maximum(model, 1e-12)  # texture only ever adds variance
        if use.sum() < 4:
            use = np.ones(len(xs), bool)
    return max(float(a), 1e-7), float(b)


# MARK: - Generalized Anscombe transform and its exact unbiased inverse

def gat(x, a, b):
    """Poisson-Gaussian light (variance a*x + b) to unit-variance Gaussian."""
    return (2.0 / a) * np.sqrt(np.maximum(a * x + 0.375 * a * a + b, 0.0))


def gat_inverse(D, a, b):
    """Mäkitalo and Foi's closed-form approximation of the exact unbiased inverse (2011, 2013)."""
    s2 = b / (a * a)
    D = np.maximum(D, 1.0)  # below that the asymptotic terms diverge; it's black there anyway
    r = np.sqrt(1.5)
    return a * (0.25 * D * D + 0.25 * r / D - 1.375 / (D * D) + 0.625 * r / (D ** 3) - 0.125 - s2)


# MARK: - DRUNet

def _net():
    import torch.nn as nn

    class Res(nn.Module):
        def __init__(self, c):
            super().__init__()
            self.res = nn.Sequential(nn.Conv2d(c, c, 3, 1, 1, bias=False), nn.ReLU(inplace=True),
                                     nn.Conv2d(c, c, 3, 1, 1, bias=False))

        def forward(self, x):
            return x + self.res(x)

    class DRUNet(nn.Module):
        def __init__(self, channels, nc=(64, 128, 256, 512), nb=4):
            super().__init__()
            self.m_head = nn.Conv2d(channels + 1, nc[0], 3, 1, 1, bias=False)
            for i in range(3):
                setattr(self, f"m_down{i + 1}", nn.Sequential(*[Res(nc[i]) for _ in range(nb)],
                                                              nn.Conv2d(nc[i], nc[i + 1], 2, 2, 0, bias=False)))
            self.m_body = nn.Sequential(*[Res(nc[3]) for _ in range(nb)])
            for i in range(3):
                setattr(self, f"m_up{i + 1}", nn.Sequential(nn.ConvTranspose2d(nc[i + 1], nc[i], 2, 2, 0, bias=False),
                                                            *[Res(nc[i]) for _ in range(nb)]))
            self.m_tail = nn.Conv2d(nc[0], channels, 3, 1, 1, bias=False)

        def forward(self, x):
            x1 = self.m_head(x)
            x2 = self.m_down1(x1)
            x3 = self.m_down2(x2)
            x4 = self.m_down3(x3)
            y = self.m_body(x4)
            y = self.m_up3(y + x4)
            y = self.m_up2(y + x3)
            y = self.m_up1(y + x2)
            return self.m_tail(y + x1)

    return DRUNet


_MODELS = {}


def model(weights):
    import torch
    if weights not in _MODELS:
        device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
        net = _net()(3)
        net.load_state_dict(torch.load(weights, map_location="cpu", weights_only=True), strict=True)
        _MODELS[weights] = (net.eval().to(device), device)
    return _MODELS[weights]


def _ramp(n, overlap, start, end):
    i = np.arange(n, dtype=np.float32)
    up = np.ones(n, np.float32) if start else np.clip((i + 0.5) / overlap, 0, 1)
    down = np.ones(n, np.float32) if end else np.clip((n - i - 0.5) / overlap, 0, 1)
    return up * down


def run(net_device, u, sigma, tile=768, overlap=64):
    """u: (N, C, H, W) in about 0…1 with white Gaussian noise of `sigma`, tiled with feathered overlaps."""
    import torch
    net, device = net_device
    n, c, h, w = u.shape
    out = np.zeros_like(u)
    total = np.zeros((1, 1, h, w), np.float32)
    step = tile - overlap
    tops = sorted({min(y, max(h - tile, 0)) for y in range(0, h, step)})
    lefts = sorted({min(x, max(w - tile, 0)) for x in range(0, w, step)})
    with torch.no_grad():
        for y0 in tops:
            for x0 in lefts:
                y1, x1 = min(y0 + tile, h), min(x0 + tile, w)
                part = torch.from_numpy(np.ascontiguousarray(u[:, :, y0:y1, x0:x1])).to(device)
                ph, pw = (-(y1 - y0)) % 8, (-(x1 - x0)) % 8
                if ph or pw:
                    part = torch.nn.functional.pad(part, (0, pw, 0, ph), mode="replicate")
                level = torch.full((n, 1, part.shape[2], part.shape[3]), float(sigma), device=device)
                done = net(torch.cat([part, level], 1))[:, :, : y1 - y0, : x1 - x0].cpu().numpy()
                weight = np.outer(_ramp(y1 - y0, overlap, y0 == 0, y1 == h), _ramp(x1 - x0, overlap, x0 == 0, x1 == w))
                out[:, :, y0:y1, x0:x1] += done * weight
                total[:, :, y0:y1, x0:x1] += weight
    return out / np.maximum(total, 1e-6)


def denoise_planes(planes, a, b, clean_rgb):
    """The four planes without their noise, in the same light. `clean_rgb(u, sigma)` cleans (1, 3, H, W)."""
    u = gat(planes, a, b)  # unit noise
    # The network's 0…1 range spans the photo's own light (a dark photo uses a sliver of the sensor's).
    S = float(gat(np.percentile(planes, 99.9), a, b))
    u = (u / S).astype(np.float32)
    g = (u[1] + u[2]) / 2
    rgb = clean_rgb(np.stack([u[0], g, u[3]])[None], 1.0 / S)[0]
    # The two greens as one: their difference is mostly noise (measured: edges 96.6% kept against 98% with a
    # second network for it, not worth its 130 MB).
    clean = np.stack([rgb[0], rgb[1], rgb[1], rgb[2]])
    x = gat_inverse(clean * S, a, b).astype(np.float32)
    # Clipped highlights stay the camera's (a denoised clip would no longer read as clipped).
    keep = np.clip((planes - 0.9) / 0.08, 0, 1)
    return x + keep * (planes - x)


def make_model(path):
    """The camera's make and model from a TIFF-based RAW (ARW, NEF, DNG, ...). Others (CR3, RAF, ...) aren't
    written back as a DNG yet: unsupported, for the other denoiser, rather than an error every time."""
    import tifffile
    try:
        with tifffile.TiffFile(path) as t:
            tags = t.pages[0].tags
            return (str(tags["Make"].value) if "Make" in tags else "", str(tags["Model"].value) if "Model" in tags else "")
    except Exception as why:
        raise Unsupported(f"not a TIFF-based RAW ({type(why).__name__})")


def denoise_raw(job):
    t0 = time.time()
    planes, meta = read(job["input"])
    mm = make_model(job["input"])
    a, b = fit_noise(planes)
    lens = job.get("lens")
    warp = fit_warp(lens[0], lens[1], meta) if lens else None
    t1 = time.time()
    net = model(job["weights"])
    clean = denoise_planes(planes, a, b, lambda u, sigma: run(net, u, sigma))
    t2 = time.time()
    write_dng(job["output"], unpack(clean, meta), meta, mm, warp)
    write_dng(job["noisy"], unpack(planes, meta), meta, mm, warp)
    return {"ok": True, "version": VERSION, "a": a, "b": b, "warp": warp,
            "seconds": {"prepare": t1 - t0, "network": t2 - t1, "write": time.time() - t2, "total": time.time() - t0}}


# MARK: - Self-check

def selftest():
    rng = np.random.default_rng(3)
    a, b = 2e-4, 4e-7
    # The inverse undoes the transform's bias: E[f(noisy)] mapped back lands on the light.
    worst = 0.0
    for x in [0.002, 0.01, 0.05, 0.3]:
        z = rng.poisson(x / a, 400000) * a + rng.normal(0, np.sqrt(b), 400000)
        worst = max(worst, abs(gat_inverse(np.mean(gat(z, a, b)), a, b) - x) / x)
        assert abs(np.std(gat(z, a, b)) - 1) < 0.08
    assert worst < 0.02, worst
    # The fit finds a and b on a synthetic ramp.
    light = np.tile(np.linspace(0.0, 0.8, 1024, dtype=np.float32) ** 2, (4, 512, 1))
    noisy = (rng.poisson(light / a) * a + rng.normal(0, np.sqrt(b), light.shape)).astype(np.float32)
    fa, fb = fit_noise(noisy)
    assert abs(fa / a - 1) < 0.05 and abs(fb - b) < 0.5 * b + 2e-8, (fa, fb)
    # With an ideal cleaner (each column's mean in the transformed domain, the light being the same down a
    # column), the planes come back unbiased.
    truth = np.tile(np.linspace(0.01, 0.6, 256, dtype=np.float32), (4, 128, 1))
    shot = (rng.poisson(truth / a) * a + rng.normal(0, np.sqrt(b), truth.shape)).astype(np.float32)

    def oracle(u, sigma):
        return np.broadcast_to(u.mean(2, keepdims=True), u.shape).copy()
    back = denoise_planes(shot, a, b, oracle)
    bias = float(np.abs(back.mean((1, 2)) / truth.mean((1, 2)) - 1).max())
    assert bias < 0.01, bias
    meta = {"order": [0, 1, 2, 3], "shape": (256, 512)}
    assert (unpack(truth, meta)[0::2, 0::2] == truth[0]).all() and (unpack(truth, meta)[1::2, 1::2] == truth[3]).all()
    # The opcode is the size the DNG spec gives it: count, then id/version/flags/size, then 1 + 8 doubles.
    assert len(_warp_rectilinear([1, 0, 0, 0])) == 4 + 16 + 4 + 64
    # A RAW that isn't TIFF-based (CR3, RAF) is unsupported, not an error.
    import tempfile
    with tempfile.NamedTemporaryFile(suffix=".CR3") as f:
        f.write(b"\x00\x00\x00\x18ftypcrx " + bytes(64))
        f.flush()
        try:
            make_model(f.name)
            raise AssertionError("a CR3 read as TIFF")
        except Unsupported:
            pass
    return {"ok": True, "inverse_bias": worst, "fit_a": fa, "fit_b": fb, "oracle_bias": bias, "version": VERSION}
