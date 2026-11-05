# Pluck's earlier bridge to spektrafilm
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
# The input is a linear sRGB float TIFF; the output is a 16-bit sRGB TIFF. (Denoise is its own
# program now: pluck_denoise.py.)
import dataclasses
import json
import sys
import traceback

import numpy as np
import OpenImageIO as oiio

# spektrafilm itself is optional here: Pluck's films run in pluck-spektra, darktable's native
# port, and this script is kept for older film engines.
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
            else:
                answer = {"error": f"unknown job {what}"}
        except Exception as error:
            answer = {"error": str(error), "trace": traceback.format_exc()[-1500:]}
        sys.stdout.write(json.dumps(answer) + "\n")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
