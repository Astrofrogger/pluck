# pluck-spektra

Pluck's film engine: a small program of its own, licensed under the GNU GPL version 3 or later
(see `COPYING`), that Pluck sends jobs to over stdin and stdout.

- `darktable/` is darktable's native C port of spektrafilm, copied unchanged from
  https://github.com/darktable-org/darktable at commit ddc0bc5cb679 (`src/common/spektra_sim.c`,
  `spektra_sim.h`, `spektra_core.c`, `spektra_core.h`, `data/kernels/grain.h`).
  Copyright (C) 2026 darktable developers, GPL-3.0-or-later.
- `shim/` provides the few GLib, json-glib and darktable functions those files use, so the
  program needs nothing but macOS. `shim/shim.c` includes darktable's two Gaussian helpers from
  `src/common/gaussian.c`, unchanged.
- `main.c` runs a picture through the film in the order of darktable's spektrafilm module
  (`src/iop/spektrafilm.c`, `process()`), and maps its settings the way the module does.

spektrafilm is Andrea Volpato's spectral film simulation (https://github.com/andreavolpato/spektrafilm,
GPL-3.0). The film and paper data (from https://github.com/darktable-org/darktable-spektrafilm)
is CC BY-SA 4.0 © Andrea Volpato and is downloaded separately, with its licence, when someone
asks for it.

Built by `scripts/build-app.sh` (Studio only).
