# Pluck's denoiser. Part of Pluck, under Pluck's own licence (not the film bridge's).
#
# It reads one job per line on stdin (JSON) and answers one line on stdout (JSON):
#   {"do": "denoise", "input": path, "output": path, "weights": path (AI only)}
#                                            -> {"ok": true, "version": 2}
#   {"do": "selftest"}                       -> {"ok": true, "roundtrip": worst relative error}
# The input is a linear sRGB float TIFF (extended: below 0 and above 1 too); the output is the
# same light without its noise, as a half-float OpenEXR with alpha. The noise always comes out in
# full: Pluck mixes the clean picture with the photo itself (the Amount) on the GPU, so a photo is
# worked out only once.
import json
import sys
import traceback

import numpy as np
import OpenImageIO as oiio

VERSION = 2


# MARK: - Light the networks and filters are made for

def _srgb(t):
    return np.where(t <= 0.0031308, 12.92 * t, 1.055 * np.power(np.maximum(t, 0.0031308), 1 / 2.4) - 0.055)


def _linear(e):
    return np.where(e <= 0.04045, e / 12.92, np.power(np.maximum((e + 0.055) / 1.055, 0), 2.4))


def exposure(rgb):
    """The gain and black offset that bring the photo to a normal exposure (its middle at 0.25),
    and lift its deepest noise above zero: high-ISO photos are mostly dark, and a dark picture's
    noise is a few steps that look like texture to a filter or a network."""
    sample = rgb[::7, ::7].reshape(-1, 3)
    luma = sample @ np.array([0.2126, 0.7152, 0.0722], np.float32)
    middle = float(np.median(np.maximum(luma, 0)))
    gain = float(np.clip(0.25 / max(middle, 1e-6), 0.5, 32))
    offset = float(np.clip(-np.percentile(sample.min(axis=1), 0.5), 0, 0.05))
    return gain, offset


def forward(x, gain, offset):
    """Linear light (any value) into 0…1 sRGB steps, and what fell below the offset (kept as it is).
    A Reinhard curve after the gain takes every highlight, however bright, below 1."""
    s = x + offset
    under = np.minimum(s, 0)
    s = (s - under) * gain
    return _srgb(s / (1 + s)).astype(np.float32), under.astype(np.float32)


def inverse(e, gain, offset, under):
    t = np.clip(_linear(e), 0, 0.999)
    return (t / (gain * (1 - t)) + under - offset).astype(np.float32)


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


def standard(e):
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
    """A tile's weight along one side: rising over the overlap, except at the picture's edge."""
    i = np.arange(n, dtype=np.float32)
    up = np.ones(n, np.float32) if start else np.minimum((i + 1) / overlap, 1)
    down = np.ones(n, np.float32) if end else np.minimum((n - i) / overlap, 1)
    return up * down


def network(e, weights, tile=512, overlap=32):
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
                part = torch.from_numpy(np.ascontiguousarray(e[y0:y1, x0:x1].transpose(2, 0, 1)))[None].to(device)
                ph, pw = (-(y1 - y0)) % 64, (-(x1 - x0)) % 64
                if ph or pw:
                    part = torch.nn.functional.pad(part, (0, pw, 0, ph), mode="reflect")
                done = model(part)[0, :, : y1 - y0, : x1 - x0].clamp(0, 1).cpu().numpy().transpose(1, 2, 0)
                weight = np.outer(_ramp(y1 - y0, overlap, y0 == 0, y1 == h), _ramp(x1 - x0, overlap, x0 == 0, x1 == w))[..., None]
                out[y0:y1, x0:x1] += done * weight
                total[y0:y1, x0:x1] += weight
    return out / np.maximum(total, 1e-6)


def keep_means(noisy, clean, reach=32, step=8):
    """Puts back what averaging in sRGB steps takes off the means (a few per cent in the shadows):
    the difference, blurred far wider than any noise (worked out at an eighth of the size)."""
    from scipy.ndimage import gaussian_filter, zoom
    h, w = clean.shape[:2]
    d = np.pad(noisy - clean, ((0, -h % step), (0, -w % step), (0, 0)), mode="edge")
    small = d.reshape(d.shape[0] // step, step, d.shape[1] // step, step, 3).mean(axis=(1, 3))
    small = gaussian_filter(small, (reach / step, reach / step, 0), mode="nearest")
    return clean + zoom(small, (step, step, 1), order=1)[:h, :w]


# MARK: - Jobs

def denoise(job):
    buf = oiio.ImageBuf(job["input"])
    pixels = np.asarray(buf.get_pixels(oiio.FLOAT))
    rgb = pixels[..., :3].astype(np.float32)
    gain, offset = exposure(rgb)
    e, under = forward(rgb, gain, offset)
    e = network(e, job["weights"]) if job.get("weights") else standard(e)
    _write(job["output"], keep_means(rgb, inverse(e, gain, offset, under)))
    return {"ok": True, "version": VERSION}


def selftest(_job=None):
    x = np.array([-0.01, 0, 1e-4, 0.18, 1, 4], np.float64)[:, None].repeat(3, 1).astype(np.float32)
    worst = 0.0
    for gain, offset in [(1.0, 0.0), (8.0, 0.002), (32.0, 0.0), (0.5, 0.05)]:
        e, under = forward(x, gain, offset)
        back = inverse(e, gain, offset, under)
        worst = max(worst, float(np.max(np.abs(back - x) / np.maximum(np.abs(x), 1e-2))))
    return {"ok": True, "roundtrip": worst, "version": VERSION}


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
            else:
                answer = {"error": f"unknown job {what}"}
        except Exception as error:
            answer = {"error": str(error), "trace": traceback.format_exc()[-1500:]}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
