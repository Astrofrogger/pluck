# Pluck's denoise engine, and its earlier bridge to spektrafilm
# (https://github.com/andreavolpato/spektrafilm), the spectral film simulation by Andrea Volpato. This script runs as its own program, next to Pluck, and
# is licensed under the GNU GPL version 3 like spektrafilm. Film and paper profiles are
# CC BY-SA 4.0 by Andrea Volpato.
#
# It reads one job per line on stdin (JSON) and answers one line on stdout (JSON):
#   {"do": "profiles"}                       -> {"film": [...], "print": [...]}
#   {"do": "schema"}                         -> every setting, with its default
#   {"do": "render", "input": path, "output": path, "film": name, "print": name,
#    "preview": bool, "max_size": int, "set": {"camera.exposure_compensation_ev": 0.5, ...}}
#                                            -> {"ok": true} or {"error": "..."}
#   {"do": "denoise", "input": path, "output": path, "strength": 0…1}
#                                            -> {"ok": true}
# The input is a linear sRGB float TIFF; the output is a 16-bit sRGB TIFF (a denoise writes a
# linear half-float OpenEXR, to go on being developed).
import dataclasses
import json
import sys
import traceback

import numpy as np
import OpenImageIO as oiio

# spektrafilm itself is optional here: Pluck's films run in pluck-spektra, darktable's native
# port, and this script is kept for denoising (and older film engines).
try:
    from spektrafilm.runtime.api import digest_params, init_params, simulate
    from spektrafilm.runtime.process import simulate_preview
except ImportError:
    pass


def profiles():
    """Every film and printing paper, with its full name and the paper it's made for."""
    from importlib.resources import files
    folder = files("spektrafilm") / "data" / "profiles"
    film, paper = [], []
    for entry in sorted(folder.iterdir(), key=lambda e: e.name):
        if not entry.name.endswith(".json"):
            continue
        try:
            info = json.loads(entry.read_text()).get("info", {})
        except Exception:
            continue
        item = {"id": entry.name[:-5], "name": info.get("name") or entry.name[:-5], "type": info.get("type", ""),
                "use": info.get("use", ""), "print": info.get("target_print")}
        (paper if info.get("stage") == "printing" else film).append(item)
    return {"film": film, "print": paper}


def schema():
    params = init_params()
    out = {}

    def walk(obj, prefix):
        if not dataclasses.is_dataclass(obj):
            return
        for field in dataclasses.fields(obj):
            if field.name in ("film", "print", "taps", "debug"):
                continue
            value = getattr(obj, field.name)
            key = f"{prefix}{field.name}"
            if dataclasses.is_dataclass(value):
                walk(value, key + ".")
            elif isinstance(value, (bool, int, float, str)) or (isinstance(value, tuple) and all(isinstance(v, (int, float)) for v in value)):
                out[key] = list(value) if isinstance(value, tuple) else value
    walk(params, "")
    return out


def apply(params, settings):
    for key, value in settings.items():
        target = params
        parts = key.split(".")
        for part in parts[:-1]:
            target = getattr(target, part)
        current = getattr(target, parts[-1])
        if isinstance(current, tuple):
            value = tuple(value)
        elif isinstance(current, bool):
            value = bool(value)
        elif isinstance(current, int) and not isinstance(current, bool):
            value = int(value)
        elif isinstance(current, float):
            value = float(value)
        setattr(target, parts[-1], value)


def render(job):
    buf = oiio.ImageBuf(job["input"])
    image = np.asarray(buf.get_pixels(oiio.FLOAT))[..., :3].astype(np.float64)
    params = init_params(film_profile=job.get("film", "kodak_portra_400"), print_profile=job.get("print", "kodak_portra_endura"))
    params.io.input_color_space = "sRGB"
    params.io.input_cctf_decoding = False
    params.io.output_color_space = "sRGB"
    params.io.output_cctf_encoding = True
    # spektrafilm's lookup tables for the enlarger and scanner: over three times faster, and the
    # same picture (under 0.1/255 apart). A job can still turn them off.
    params.settings.use_enlarger_lut = True
    params.settings.use_scanner_lut = True
    params.settings.use_fast_stats = True
    apply(params, job.get("set", {}))
    if job.get("preview"):
        params.settings.preview_max_size = int(job.get("max_size", 1024))
        result = simulate_preview(image, params)
    else:
        result = simulate(image, params)
    result = np.clip(np.asarray(result, dtype=np.float32), 0, 1)
    spec = oiio.ImageSpec(result.shape[1], result.shape[0], 3, oiio.UINT16)
    out = oiio.ImageOutput.create(job["output"])
    out.open(job["output"], spec)
    out.write_image(result)
    out.close()
    return {"ok": True, "width": int(result.shape[1]), "height": int(result.shape[0])}


def _encode(x):
    x = np.clip(x, 0, None)
    return np.where(x <= 0.0031308, x * 12.92, 1.055 * np.power(x, 1 / 2.4) - 0.055)


def _decode(x):
    return np.where(x <= 0.04045, x / 12.92, np.power((np.clip(x, 0, None) + 0.055) / 1.055, 2.4))


def _noise_level(x):
    """The typical difference between neighbours, which edges hardly change."""
    d = (x[:, 1:] - x[:, :-1]).ravel()[::7]
    return float(np.median(np.abs(d)) / (0.6745 * np.sqrt(2)))


def denoise(job):
    """Noise reduction before developing: the colour blotches go (non-local means at half size on
    the colour), and the grain on the brightness is smoothed by non-local means, which compares
    patches of the picture and keeps edges and texture."""
    from skimage.restoration import denoise_nl_means
    from skimage.transform import resize
    strength = min(max(float(job.get("strength", 0.5)), 0), 1)
    if job.get("weights"):
        return _ai_denoise(job, strength)
    buf = oiio.ImageBuf(job["input"])
    linear = np.asarray(buf.get_pixels(oiio.FLOAT))[..., :3]
    # Highlights over white are kept aside, so they survive the round trip.
    over = np.clip(linear - 1, 0, None)
    rgb = _encode(np.clip(linear, 0, 1)).astype(np.float32)
    y = 0.2126 * rgb[..., 0] + 0.7152 * rgb[..., 1] + 0.0722 * rgb[..., 2]
    cb, cr = rgb[..., 2] - y, rgb[..., 0] - y
    h, w = y.shape
    small = np.stack([cb, cr], -1)[::2, ::2]
    sigma = max(_noise_level(small[..., 0]), _noise_level(small[..., 1]), 1e-4)
    small = denoise_nl_means(small, h=sigma * (0.8 + 1.6 * strength), sigma=sigma, patch_size=5, patch_distance=6,
                             fast_mode=True, channel_axis=-1)
    chroma = resize(small, (h, w, 2), order=1, anti_aliasing=False).astype(np.float32)
    sigma = max(_noise_level(y), 1e-4)
    clean = denoise_nl_means(y, h=sigma * (0.5 + 0.9 * strength), sigma=sigma, patch_size=5, patch_distance=5,
                             fast_mode=True).astype(np.float32)
    y = y + (clean - y) * min(1.0, 0.35 + strength)
    out = np.empty_like(rgb)
    out[..., 0] = y + chroma[..., 1]
    out[..., 2] = y + chroma[..., 0]
    out[..., 1] = (y - 0.2126 * out[..., 0] - 0.0722 * out[..., 2]) / 0.7152
    result = (_decode(out) + over).astype(np.float32)
    _write_linear(job["output"], result)
    return {"ok": True}


_MODEL = None


def _ai_denoise(job, strength):
    """AI denoise: SCUNet (Apache 2.0, trained on real camera noise) through spandrel (MIT), on
    the GPU when there is one, in overlapping tiles so any size fits in memory."""
    global _MODEL
    import torch
    from spandrel import ModelLoader
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    if _MODEL is None:
        _MODEL = ModelLoader().load_from_file(job["weights"]).model.eval().to(device)
    buf = oiio.ImageBuf(job["input"])
    linear = np.asarray(buf.get_pixels(oiio.FLOAT))[..., :3]
    over = np.clip(linear - 1, 0, None)
    rgb = _encode(np.clip(linear, 0, 1)).astype(np.float32)
    h, w = rgb.shape[:2]
    tile, pad = 512, 32
    out = np.zeros_like(rgb)
    weight = np.zeros((h, w, 1), np.float32)
    ramp = np.minimum(np.arange(tile + 2 * pad), np.arange(tile + 2 * pad)[::-1]).astype(np.float32)
    ramp = np.clip(ramp / pad, 0.05, 1)
    with torch.no_grad():
        for y in range(0, h, tile):
            for x in range(0, w, tile):
                y0, x0 = max(y - pad, 0), max(x - pad, 0)
                y1, x1 = min(y + tile + pad, h), min(x + tile + pad, w)
                part = torch.from_numpy(rgb[y0:y1, x0:x1].transpose(2, 0, 1)[None].copy()).to(device)
                # The network wants sizes it can halve a few times.
                ph, pw = (-part.shape[2]) % 64, (-part.shape[3]) % 64
                if ph or pw:
                    part = torch.nn.functional.pad(part, (0, pw, 0, ph), mode="reflect")
                done = _MODEL(part)[0, :, : y1 - y0, : x1 - x0].clamp(0, 1).cpu().numpy().transpose(1, 2, 0)
                # Tiles fade into each other where they overlap (no seams).
                wt = (ramp[: y1 - y0, None] * ramp[None, : x1 - x0])[..., None]
                out[y0:y1, x0:x1] += done * wt
                weight[y0:y1, x0:x1] += wt
    out /= np.maximum(weight, 1e-6)
    blended = rgb + (out - rgb) * strength
    _write_linear(job["output"], (_decode(blended) + over).astype(np.float32))
    return {"ok": True}


def _write_linear(path, rgb):
    """Linear light as a half-float OpenEXR with alpha (Core Image reads three-channel float
    TIFFs wrongly when it reads them in tiles)."""
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
            if what == "profiles":
                answer = profiles()
            elif what == "schema":
                answer = schema()
            elif what == "render":
                answer = render(job)
            elif what == "denoise":
                answer = denoise(job)
            else:
                answer = {"error": f"unknown job {what}"}
        except Exception as error:
            answer = {"error": str(error), "trace": traceback.format_exc()[-1500:]}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
