/* The two Gaussian helpers spektra_core.c uses, from darktable's
   src/common/gaussian.c (GPL-3.0-or-later). */
#pragma once
void dt_gaussian_yvv_coeffs(const float sigma, float out[4]);
int dt_gaussian_kernel_1d(const float sigma, float *const kernel, const int max_radius);
