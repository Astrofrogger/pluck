# Pluck's denoiser. Part of Pluck, under Pluck's own licence (not the film bridge's).
#
# It reads one job per line on stdin (JSON) and answers one line on stdout (JSON):
#   {"do": "denoise", "input": path, "output": path, "weights": path (AI only)}
#                                            -> {"ok": true, "version": 4}
#   {"do": "selftest"}                       -> {"ok": true, "roundtrip": worst relative error, "settled": bool}
#   {"do": "denoise_raw", ...}, {"do": "selftest_raw"}: a Bayer RAW's mosaic, in pluck_denoise_raw.py
# The input is a linear sRGB float TIFF (extended: below 0 and above 1 too); the output is the
# same light without its noise, as a half-float OpenEXR with alpha. The noise always comes out in
# full: Pluck mixes the clean picture with the photo itself (the Amount) on the GPU, so a photo is
# worked out only once.
#
# The denoisers are given what they are made for: a normally exposed picture in sRGB steps (0…1),
# with its camera noise as it is. One gain brings the photo's middle to a normal exposure; what that
# lifts past white is done again two stops darker (and once more) and blended in, in
# linear light; past that (no noise to speak of) the photo is kept. Each comes back exactly through
# the same steps. (Darker passes than needed tint a little: the network leans at a picture's ends.)
import json
import sys
import traceback

import numpy as np
import OpenImageIO as oiio

VERSION = 4  # PhotoRender.denoiseVersion
LUMA = np.array([0.2126, 0.7152, 0.0722], np.float32)
STEP, PASSES = 4, 2  # each highlights' pass is two stops darker; past the second the photo is kept


# MARK: - Light the networks and filters are made for

def _srgb(t):
    return np.where(t <= 0.0031308, 12.92 * t, 1.055 * np.power(np.maximum(t, 0.0031308), 1 / 2.4) - 0.055)


def _linear(e):
    return np.where(e <= 0.04045, e / 12.92, np.power(np.maximum((e + 0.055) / 1.055, 0), 2.4))


def _smooth(x, lo, hi):
    t = np.clip((x - lo) / (hi - lo), 0, 1)
    return t * t * (3 - 2 * t)


def exposure(rgb):
    """The gain that puts the photo's middle at a normal exposure (18% grey)."""
    middle = float(np.median(np.maximum(rgb[::7, ::7].reshape(-1, 3) @ LUMA, 0)))
    return float(np.clip(0.18 / max(middle, 1e-6), 0.25, 64))


def develop(rgb, gain, run, need=None):
    """The photo at a gain, in sRGB steps, cleaned by `run`, and back in linear light."""
    e = _srgb(np.clip(rgb * gain, 0, 1)).astype(np.float32)
    clean = (_linear(run(e, need)) / gain).astype(np.float32)
    return levels(rgb, clean, gain, need)


def levels(noisy, clean, gain, need=None, bins=64):
    """Puts back what the deepest shadows lose: their noise is cut off at black, so averaging it lifts nothing
    and the clean shadows come out too dark (most in red and blue, which turned them green). Per channel, the
    photo's mean minus the clean one at each (own level, brightness), over the whole picture: one global
    correction, so no halo and no blotch. (It also takes out the network's slight colour leanings.)"""
    from scipy.ndimage import gaussian_filter, map_coordinates
    s = (slice(None, None, 2), slice(None, None, 2))
    pick = np.ones(clean[s].shape[:2], bool) if need is None else need[s]
    if pick.sum() < 1000:
        return clean
    lum = _srgb(np.clip(clean @ LUMA * gain, 0, 1)) * (bins - 1)
    fade = (1 - _smooth(lum / (bins - 1), 0.85, 1.0)).astype(np.float32)
    out = clean.copy()
    for c in range(3):
        own = _srgb(np.clip(clean[..., c] * gain, 0, 1)) * (bins - 1)
        inside = pick & (own[s] < bins - 1) & (lum[s] < bins - 1)  # (what's past white says nothing about black)
        k = np.rint(own[s][inside]).astype(int) * bins + np.rint(lum[s][inside]).astype(int)
        count = gaussian_filter(np.bincount(k, minlength=bins * bins).reshape(bins, bins).astype(np.float64), 1.0)
        diff = gaussian_filter(np.bincount(k, (noisy[s][..., c] - clean[s][..., c])[inside].astype(np.float64),
                                           bins * bins).reshape(bins, bins), 1.0)
        d = diff / np.maximum(count, 1) * np.minimum(count / 500, 1)  # only where there's enough to tell
        out[..., c] += fade * map_coordinates(d, [np.clip(own, 0, bins - 1), np.clip(lum, 0, bins - 1)], order=1)
    return out


def clean(rgb, run):
    """The photo without its noise, `run` cleaning a 0…1 sRGB picture (only where `need` says, if it can)."""
    from scipy.ndimage import gaussian_filter, maximum_filter
    gain = exposure(rgb)
    bright = maximum_filter(gaussian_filter(np.maximum(rgb.max(axis=-1), 0), 1.0), 9)
    out = develop(rgb, gain, run)
    for _ in range(PASSES):
        high = _smooth(bright * gain, 0.45, 0.85)  # near white at this gain (kept clear of it)
        if not high.any():
            return settle(rgb, out)
        gain /= STEP
        out += high[..., None] * (develop(rgb, gain, run, high > 0) - out)
    keep = _smooth(bright * gain, 0.7, 0.95)[..., None]  # near white even at the last gain: no noise to speak of
    out += keep * (rgb - out)
    return settle(rgb, out)


def settle(noisy, clean):
    """Denoising averages: it never needs past what the photo has within 3 px. That takes off the network's
    overshoot at the hardest edges (a leaf against the sky), and anything else gone wrong."""
    from scipy.ndimage import maximum_filter, minimum_filter
    clean = np.where(np.isfinite(clean), clean, noisy)
    return np.clip(clean, minimum_filter(noisy, (7, 7, 1)), maximum_filter(noisy, (7, 7, 1))).astype(np.float32)


# MARK: - Standard: non-local means, luma at full size and colour at half

def _blocks(c, size=16):
    """Each block's brightness and the spread of its finest detail (demosaicing makes neighbours'
    noise alike, so their differences alone see too little of it)."""
    from scipy.ndimage import gaussian_filter
    detail = c - gaussian_filter(c, 2.0)
    h, w = (c.shape[0] // size) * size, (c.shape[1] // size) * size
    shape = (h // size, size, w // size, size)
    return c[:h, :w].reshape(shape).mean(axis=(1, 3)).ravel(), detail[:h, :w].reshape(shape).std(axis=(1, 3)).ravel()


def noise_curve(c, bins=8):
    """The noise at each brightness (0…1), from the flattest quarter of the blocks at it: in sRGB
    steps the shadows are noisier than the highlights."""
    level, spread = _blocks(c)
    edges = np.quantile(level, np.linspace(0, 1, bins + 1))
    centres, sigmas = [], []
    for lo, hi in zip(edges[:-1], edges[1:]):
        inside = (level >= lo) & (level <= hi)
        if inside.sum() >= 8:
            centres.append(float(np.median(level[inside])))
            sigmas.append(max(float(np.percentile(spread[inside], 25)) / 0.96, 1e-4))
    grid = np.linspace(0, 1, 257)
    return grid, np.interp(grid, centres, sigmas) if centres else np.full_like(grid, 1e-2)


def standard(e, _need=None):
    from skimage.restoration import denoise_nl_means
    from scipy.ndimage import zoom
    r, g, b = e[..., 0], e[..., 1], e[..., 2]
    y = 0.299 * r + 0.587 * g + 0.114 * b
    chroma = np.stack([b - y, r - y], -1)
    # Luma in steps of its own noise (integrating 1/noise over brightness), so one strength fits
    # the shadows and the highlights alike; and back.
    grid, sigma = noise_curve(y)
    steps = np.concatenate([[0], np.cumsum((1 / sigma[1:] + 1 / sigma[:-1]) / 2 * np.diff(grid))])
    flat = np.interp(y, grid, steps).astype(np.float32)
    flat = denoise_nl_means(flat, patch_size=5, patch_distance=6, h=1.2, sigma=1.0, fast_mode=True, preserve_range=True)
    y = np.interp(flat, steps, grid).astype(np.float32)
    # Colour noise is coarse (blotches a few pixels wide): it's taken out at half size, over a wider
    # reach, also in steps of the noise at each pixel's brightness.
    h, w = y.shape
    half = chroma[: h // 2 * 2, : w // 2 * 2].reshape(h // 2, 2, w // 2, 2, 2).mean(axis=(1, 3))
    scale = np.interp(y[: h // 2 * 2, : w // 2 * 2].reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3)), grid, sigma)[..., None]
    _, spread = _blocks(half[..., 0] / scale[..., 0])
    sc = max(float(np.percentile(spread, 25)) / 0.96, 1e-3)
    half = denoise_nl_means(half / scale, patch_size=5, patch_distance=8, h=2.0 * sc, sigma=sc, fast_mode=True,
                            channel_axis=-1, preserve_range=True) * scale
    up = zoom(half, (2, 2, 1), order=1)
    full = np.pad(up, ((0, h - up.shape[0]), (0, w - up.shape[1]), (0, 0)), mode="edge")
    cb, cr = full[..., 0], full[..., 1]
    r, b = y + cr, y + cb
    g = (y - 0.299 * r - 0.114 * b) / 0.587
    return np.clip(np.stack([r, g, b], -1), 0, 1).astype(np.float32)


# MARK: - AI: SCUNet (Apache 2.0), in tiles on the GPU

_MODEL = None


def _ramp(n, overlap, start, end):
    """A tile's weight along one side: a smooth rise over the overlap, except at the picture's edge."""
    i = np.arange(n, dtype=np.float32)
    up = np.ones(n, np.float32) if start else np.sin(np.minimum((i + 0.5) / overlap, 1) * np.pi / 2) ** 2
    down = np.ones(n, np.float32) if end else np.sin(np.minimum((n - i - 0.5) / overlap, 1) * np.pi / 2) ** 2
    return up * down


def network(e, weights, need=None, tile=512, overlap=96):
    """SCUNet over the picture in overlapping tiles, feathered together (only the tiles `need` touches)."""
    global _MODEL
    import torch
    from spandrel import ModelLoader
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    if _MODEL is None or _MODEL[0] != weights:
        _MODEL = (weights, ModelLoader().load_from_file(weights).model.eval().to(device))
    model = _MODEL[1]
    h, w = e.shape[:2]
    out = np.zeros_like(e)
    total = np.zeros((h, w, 1), np.float32)
    step = tile - overlap
    tops = sorted({min(y, max(h - tile, 0)) for y in range(0, h, step)})
    lefts = sorted({min(x, max(w - tile, 0)) for x in range(0, w, step)})
    with torch.no_grad():
        for y0 in tops:
            for x0 in lefts:
                y1, x1 = min(y0 + tile, h), min(x0 + tile, w)
                if need is not None and not need[y0:y1, x0:x1].any():
                    continue
                part = torch.from_numpy(np.ascontiguousarray(e[y0:y1, x0:x1].transpose(2, 0, 1)))[None].to(device)
                ph, pw = (-(y1 - y0)) % 64, (-(x1 - x0)) % 64
                if ph or pw:
                    part = torch.nn.functional.pad(part, (0, pw, 0, ph), mode="reflect")
                done = model(part)[0, :, : y1 - y0, : x1 - x0].clamp(0, 1).cpu().numpy().transpose(1, 2, 0)
                weight = np.outer(_ramp(y1 - y0, overlap, y0 == 0, y1 == h), _ramp(x1 - x0, overlap, x0 == 0, x1 == w))[..., None]
                out[y0:y1, x0:x1] += done * weight
                total[y0:y1, x0:x1] += weight
    return out / np.maximum(total, 1e-6)


# MARK: - Jobs

def denoise(job):
    buf = oiio.ImageBuf(job["input"])
    rgb = np.asarray(buf.get_pixels(oiio.FLOAT))[..., :3].astype(np.float32)
    weights = job.get("weights")
    run = (lambda e, need: network(e, weights, need)) if weights else standard
    _write(job["output"], clean(rgb, run))
    return {"ok": True, "version": VERSION}


def selftest(_job=None):
    # Through the steps and back with nothing cleaned: exact, from black to far past white.
    x = np.concatenate([np.zeros(64), np.geomspace(1e-4, 64, 448)]).astype(np.float32)
    x = np.tile(x[:, None, None], (1, 64, 3))
    x[..., 1] *= 0.5
    back = clean(x, lambda e, need: e)
    worst = float(np.max(np.abs(back - x) / np.maximum(np.abs(x), 1e-2)))
    # A cleaner gone wild (all black, all white) stays finite and within the photo's light.
    rng = np.random.default_rng(1)
    noisy = np.clip(rng.normal(0.02, 0.005, (64, 64, 3)), -0.01, None).astype(np.float32)
    noisy[16:48, 16:48] = 16
    settled = True
    for wild in (np.zeros_like, np.ones_like):
        safe = clean(noisy, lambda e, need: wild(e))
        settled &= bool(np.isfinite(safe).all() and safe.min() >= min(noisy.min(), 0) - 1e-3 and safe.max() <= noisy.max() + 1e-3)
    return {"ok": True, "roundtrip": worst, "settled": settled, "version": VERSION}


def _write(path, rgb):
    """Linear light as a half-float OpenEXR with alpha (Core Image reads it as it is)."""
    h, w = rgb.shape[:2]
    rgba = np.concatenate([rgb, np.ones((h, w, 1), np.float32)], -1).astype(np.float16)
    spec = oiio.ImageSpec(w, h, 4, oiio.HALF)
    spec.attribute("compression", "zip")
    output = oiio.ImageOutput.create(path)
    output.open(path, spec)
    output.write_image(rgba)
    output.close()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            job = json.loads(line)
            what = job.get("do")
            if what == "denoise":
                answer = denoise(job)
            elif what == "selftest":
                answer = selftest(job)
            elif what in ("denoise_raw", "selftest_raw"):
                # A Bayer RAW's own mosaic (pluck_denoise_raw.py); anything else answers unsupported.
                import pluck_denoise_raw as raw
                try:
                    answer = raw.denoise_raw(job) if what == "denoise_raw" else raw.selftest()
                except raw.Unsupported as why:
                    answer = {"ok": False, "unsupported": str(why)}
            else:
                answer = {"error": f"unknown job {what}"}
        except Exception as error:
            answer = {"error": str(error), "trace": traceback.format_exc()[-1500:]}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
