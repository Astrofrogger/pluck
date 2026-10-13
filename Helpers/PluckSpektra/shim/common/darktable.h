/* pluck-spektra: what darktable's spektra engine needs from darktable itself. */
#pragma once
#include <glib.h>
#include <stdlib.h>
#define DT_DEBUG_PIPE 0
#define DT_DEBUG_DEV 0
#define dt_print(level, ...) ((void)0)
/* The helper runs the per-pixel stages in strips on every core itself. */
#define DT_OMP_FOR(...)
#define DT_OMP_DECLARE_SIMD(...)
static inline float *dt_alloc_align_float(size_t n)
{
  void *p = NULL;
  return posix_memalign(&p, 64, n * sizeof(float)) == 0 ? (float *)p : NULL;
}
static inline void dt_free_align(void *p) { free(p); }
