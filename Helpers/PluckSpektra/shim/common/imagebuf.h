#pragma once
#include <string.h>
static inline void dt_iop_image_copy(float *const out, const float *const in, const size_t nfloats)
{
  memcpy(out, in, nfloats * sizeof(float));
}
