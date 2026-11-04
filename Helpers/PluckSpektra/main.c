/*
    pluck-spektra: Pluck's film engine, a separate program built from darktable's
    native port of spektrafilm (src/common/spektra_sim.c, spektra_core.c), with
    the processing order of darktable's spektrafilm module (src/iop/spektrafilm.c,
    process()). spektrafilm is Andrea Volpato's spectral film simulation; film
    modelling powered by spektrafilm (https://github.com/andreavolpato/spektrafilm).

    Copyright (C) 2026 darktable developers (the engine and the order of the steps),
    and the Pluck authors (this driver).

    This program is free software: you can redistribute it and/or modify it under
    the terms of the GNU General Public License as published by the Free Software
    Foundation, either version 3 of the License, or (at your option) any later
    version. See COPYING.

    It reads one job per line on stdin (JSON) and answers one line on stdout:
      {"do":"profiles","pack":dir}            -> {"film":[...],"print":[...]}
      {"do":"schema"}                         -> every setting: default, range
      {"do":"render","pack":dir,"input":f,"output":f,"width":w,"height":h,
       "film":stock,"print":stock,"full_long_edge":px,"set":{name:value,...}}
                                              -> {"ok":true}
      {"do":"tables","part":"film"|"paper"|"pair","pack":dir,"film":stock,"print":stock|null,
       "set":{...},"output":f}                -> {"ok":true}, one part of the per-pixel tables (.pft)
      {"do":"checktables","pack":dir,"film":stock,"print":stock|null,"set":{...},
       "tables":{"film":f,"paper":f,"pair":f},"samples":k}
                                              -> {"max_error":e,"mean_error":e}
    Images are raw float32 RGBA, linear sRGB, row by row from the top.
*/
#include <compression.h>
#include <dirent.h>
#include <dispatch/dispatch.h>
#include <glib.h>
#include <json-glib/json-glib.h>
#include <math.h>
#include <string.h>

#include "common/darktable.h"
#include "spektra_core.h"
#include "spektra_sim.h"

/* the module's constants (src/iop/spektrafilm.c) */
#define SF_HALATION_FIRST_SIGMA_UM 65.0f
#define SF_SCATTER_CORE_CLAMP_UM 2.2f
#define SF_SCATTER_TAIL_CLAMP_UM 9.7f
#define SF_GLARE_ROUGHNESS 0.7f
#define SF_GLARE_BLUR_PX 0.5f
#define SF_GRAIN_BLUR_MIN 0.05f
#define SF_GRAIN_DYE_BLUR_UM 2.0f
#define SF_PUSH_PULL_GAMMA_PER_STOP 1.15f
#define SF_LUT_STEPS 33

/* ------------------------------------------------------------- settings -- */

/* darktable's module parameters, by name, with its defaults and ranges. */
typedef struct setting_t { const char *name; float def, min, max; int flag; } setting_t;

static const setting_t SETTINGS[] = {
  { "exposure_ev", 0, -12, 12, 0 },          { "print_exposure_ev", 0, -3, 3, 0 },
  { "print_auto_exposure", 0, 0, 1, 1 },     { "print_contrast", 1, 0.5f, 2, 0 },
  { "filter_m", 0, -60, 60, 0 },             { "filter_y", 0, -60, 60, 0 },
  { "couplers_amount", 1, 0, 1, 0 },         { "couplers_diffusion_um", 20, 0, 60, 0 },
  { "couplers_tail_um", 200, 0, 400, 0 },    { "couplers_tail_weight", 0.03f, 0, 1, 0 },
  { "couplers_inhibition_same", 1, 0, 3, 0 },{ "couplers_inhibition_inter", 1, 0, 3, 0 },
  { "preflash_exposure", 0, 0, 2, 0 },       { "preflash_m_shift", 0, -60, 60, 0 },
  { "preflash_y_shift", 0, -60, 60, 0 },     { "scan_film", 0, 0, 1, 1 },
  { "halation_on", 1, 0, 1, 1 },             { "scatter_amount", 1, 0, 1, 0 },
  { "scatter_scale", 1, 0.2f, 4, 0 },        { "halation_amount", 1, 0, 8, 0 },
  { "halation_scale", 1, 0.2f, 4, 0 },       { "boost_ev", 0, 0, 10, 0 },
  { "boost_range", 0.3f, 0, 1, 0 },          { "protect_ev", 4, 0, 6, 0 },
  { "diffusion_on", 0, 0, 1, 1 },            { "diffusion_filter_family", 0, 0, 3, 2 },
  { "diffusion_strength", 0.5f, 0, 2, 0 },   { "diffusion_scale", 1, 0.2f, 4, 0 },
  { "diffusion_warmth", 0, -1.5f, 1.5f, 0 }, { "print_diffusion_on", 0, 0, 1, 1 },
  { "print_diffusion_filter_family", 0, 0, 3, 2 }, { "print_diffusion_strength", 0.5f, 0, 2, 0 },
  { "print_diffusion_scale", 1, 0.2f, 4, 0 },{ "print_diffusion_warmth", 0, -1.5f, 1.5f, 0 },
  { "grain_on", 1, 0, 1, 1 },                { "grain_amount", 1, 0, 8, 0 },
  { "grain_blur", 1, 0.2f, 4, 0 },           { "grain_granularity", 1, 0, 4, 0 },
  { "grain_uniformity", 1, 0.5f, 1.03f, 0 }, { "grain_sublayer_scale", 1, 0, 2, 0 },
  { "grain_density_min", 1, 0, 4, 0 },       { "grain_dye_cloud", 1, 0, 4, 0 },
  { "film_format_mm", 36, 5, 250, 0 },       { "output_luminance_boost", 1, 0.5f, 4, 0 },
  { "output_scale", 1, 0.5f, 4, 0 },         { "grain_usm_sigma", 0.7f, 0, 3, 0 },
  { "grain_usm_amount", 1.5f, 0, 2, 0 },     { "film_gamma_factor", 1, 0.25f, 4, 0 },
  { "film_gamma_factor_fast", 1, 0.25f, 4, 0 }, { "film_gamma_factor_slow", 1, 0.25f, 4, 0 },
  { "film_developer_exhaustion", 0, 0, 1, 0 }, { "push_pull_stops", 0, -4, 4, 0 },
  { "scan_blur", 0, 0, 4, 0 },               { "scan_usm_sigma", 0.7f, 0, 3, 0 },
  { "scan_usm_amount", 0.7f, 0, 2, 0 },      { "glare_percent", 0, 0, 1, 0 },
  { "development_min", 0, 0, 15, 0 },        { "print_development_min", 0, 0, 15, 0 },
  { "adaptation_bandwidth", 1, 0, 1, 1 },    { "adaptation_surface", 0, 0, 1, 1 },
  { "gamut_compress", 1, 0, 1, 1 },          { "print_gamma_r", 1, 0.5f, 2, 0 },
  { "print_gamma_g", 1, 0.5f, 2, 0 },        { "print_gamma_b", 1, 0.5f, 2, 0 },
};
#define NSETTINGS (sizeof SETTINGS / sizeof SETTINGS[0])

typedef struct { float v[NSETTINGS]; } params_t;

static int setting_index(const char *name)
{
  for(size_t i = 0; i < NSETTINGS; i++)
    if(!strcmp(SETTINGS[i].name, name)) return (int)i;
  return -1;
}

static float P(const params_t *p, const char *name) { const int i = setting_index(name); return i < 0 ? 0 : p->v[i]; }

static void params_from(params_t *p, JsonObject *set)
{
  for(size_t i = 0; i < NSETTINGS; i++) p->v[i] = SETTINGS[i].def;
  if(!set) return;
  GList *members = json_object_get_members(set);
  for(GList *m = members; m; m = m->next)
  {
    const int i = setting_index(m->data);
    if(i >= 0) p->v[i] = fminf(fmaxf((float)json_object_get_double_member(set, m->data), SETTINGS[i].min), SETTINGS[i].max);
  }
  g_list_free(members);
}

/* ------------------------------------------------------------- the sim -- */

static sf_pack_t *pack = NULL;
static char pack_dir[1024];
static sf_sim_t *sim = NULL;
static char sim_key[4096];

/* The parts of the settings the tables are built from (the rest act per render). */
static const char *BUILD_KEYS[] = {
  "exposure_ev", "push_pull_stops", "print_exposure_ev", "print_auto_exposure", "filter_m", "filter_y",
  "couplers_amount", "grain_granularity", "grain_uniformity", "grain_sublayer_scale", "grain_density_min",
  "couplers_diffusion_um", "couplers_tail_um", "couplers_tail_weight", "couplers_inhibition_same",
  "couplers_inhibition_inter", "preflash_exposure", "preflash_m_shift", "preflash_y_shift", "scan_film",
  "adaptation_bandwidth", "adaptation_surface", "output_luminance_boost", "gamut_compress", "output_scale",
  "print_contrast", "print_gamma_r", "print_gamma_g", "print_gamma_b", "film_gamma_factor",
  "film_gamma_factor_fast", "film_gamma_factor_slow", "film_developer_exhaustion", "development_min",
  "print_development_min", NULL };

static char *build_sim(const char *dir, const char *film_stock, const char *paper_stock, const params_t *p)
{
  char key[4096];
  int n = snprintf(key, sizeof key, "%s|%s|%s", dir, film_stock, paper_stock ? paper_stock : "");
  for(int i = 0; BUILD_KEYS[i]; i++) n += snprintf(key + n, sizeof key - n, "|%g", P(p, BUILD_KEYS[i]));
  if(sim && !strcmp(key, sim_key)) return NULL;
  if(sim) { sf_sim_free(sim); sim = NULL; }
  char *err = NULL;
  if(!pack || strcmp(pack_dir, dir))
  {
    if(pack) sf_pack_free(pack);
    pack = sf_pack_load(dir, &err, NULL);
    if(!pack) return err ? err : g_strdup("the film data couldn't be read");
    g_strlcpy(pack_dir, dir, sizeof pack_dir);
  }
  char path[2048];
  snprintf(path, sizeof path, "%s/profiles/%s.json", dir, film_stock);
  sf_profile_t *film = sf_profile_load(path, P(p, "development_min"), &err);
  if(!film) return err ? err : g_strdup("this film couldn't be read");
  sf_profile_t *paper = NULL;
  const int scan_film = P(p, "scan_film") > 0.5f;
  if(!scan_film)
  {
    snprintf(path, sizeof path, "%s/profiles/%s.json", dir, paper_stock ? paper_stock : "");
    paper = sf_profile_load(path, P(p, "print_development_min"), &err);
    if(!paper) { sf_profile_free(film); return err ? err : g_strdup("this paper couldn't be read"); }
  }

  /* as darktable's _ensure_sim() */
  sf_sim_params_t sp;
  sf_sim_params_defaults(&sp);
  sp.exposure_comp_ev = P(p, "exposure_ev") - P(p, "push_pull_stops");
  sp.print_exposure = powf(2.0f, P(p, "print_exposure_ev"));
  sp.print_exposure_compensation = P(p, "print_auto_exposure") > 0.5f;
  sp.m_filter_shift = P(p, "filter_m");
  sp.y_filter_shift = P(p, "filter_y");
  sp.couplers_active = P(p, "couplers_amount") > 0.0f;
  sp.couplers_amount = P(p, "couplers_amount");
  sp.grain_rms_scale = P(p, "grain_granularity");
  sp.grain_uniformity_scale = P(p, "grain_uniformity");
  sp.grain_particle_scale = P(p, "grain_sublayer_scale");
  sp.grain_density_min_scale = P(p, "grain_density_min");
  sp.coupler_diffusion_um = P(p, "couplers_diffusion_um");
  sp.coupler_tail_um = P(p, "couplers_tail_um");
  sp.coupler_tail_weight = P(p, "couplers_tail_weight");
  sp.inhibition_samelayer = P(p, "couplers_inhibition_same");
  sp.inhibition_interlayer = P(p, "couplers_inhibition_inter");
  sp.preflash_exposure = P(p, "preflash_exposure");
  sp.preflash_m_shift = P(p, "preflash_m_shift");
  sp.preflash_y_shift = P(p, "preflash_y_shift");
  sp.scan_film = scan_film;
  sp.adaptation_bandwidth = P(p, "adaptation_bandwidth") > 0.5f;
  sp.adaptation_surface = P(p, "adaptation_surface") > 0.5f;
  sp.lut_steps = SF_LUT_STEPS;
  sp.out_luminance_boost = P(p, "output_luminance_boost");
  if(P(p, "gamut_compress") < 0.5f) sp.output_compress = SF_OUTPUT_COMPRESS_OFF;
  sp.out_scale = P(p, "output_scale");
  if(P(p, "print_contrast") != 1.0f || P(p, "print_gamma_r") != 1.0f || P(p, "print_gamma_g") != 1.0f
     || P(p, "print_gamma_b") != 1.0f)
  {
    sp.morph_active = true;
    sp.morph_gamma = P(p, "print_contrast");
    sp.morph_gamma_r = P(p, "print_gamma_r");
    sp.morph_gamma_g = P(p, "print_gamma_g");
    sp.morph_gamma_b = P(p, "print_gamma_b");
  }
  if(P(p, "film_gamma_factor") != 1.0f || P(p, "film_gamma_factor_fast") != 1.0f || P(p, "film_gamma_factor_slow") != 1.0f
     || P(p, "film_developer_exhaustion") != 0.0f || P(p, "push_pull_stops") != 0.0f)
  {
    sp.film_morph_active = true;
    sp.film_morph_gamma = P(p, "film_gamma_factor") * powf(SF_PUSH_PULL_GAMMA_PER_STOP, P(p, "push_pull_stops"));
    sp.film_morph_gamma_fast = P(p, "film_gamma_factor_fast");
    sp.film_morph_gamma_slow = P(p, "film_gamma_factor_slow");
    sp.film_morph_developer_exhaustion = P(p, "film_developer_exhaustion");
  }
  /* Pluck hands over linear sRGB and takes linear sRGB back. */
  sf_sim_params_set_input_srgb(&sp);
  sf_sim_params_set_output_srgb(&sp);

  sim = sf_sim_build(pack, film, paper, &sp, &err);
  sf_profile_free(film);
  if(paper) sf_profile_free(paper);
  if(!sim) return err ? err : g_strdup("the film couldn't be set up");
  g_strlcpy(sim_key, key, sizeof sim_key);
  return NULL;
}

/* ------------------------------------------------- every core, in strips -- */

#define STRIPS 64
typedef void (^strip_fn)(size_t start, size_t count);
static void strips(size_t npix, strip_fn fn)
{
  const size_t per = (npix + STRIPS - 1) / STRIPS;
  dispatch_apply(STRIPS, DISPATCH_APPLY_AUTO, ^(size_t i) {
    const size_t start = i * per;
    if(start < npix) fn(start, MIN(per, npix - start));
  });
}

static inline float pow10f_(float x) { return powf(10.0f, x); }
static inline float log10f_(float x) { return log10f(x); }

/* ---------------------------------------------------------------- render -- */

/* darktable's process() (src/iop/spektrafilm.c), step for step. */
static char *render(const float *in, float *out, int w, int h, const params_t *pr, float full_long_edge)
{
  const size_t npix = (size_t)w * h;
  const float pixel_um = P(pr, "film_format_mm") * 1000.0f / fmaxf(full_long_edge, 1.0f);
  /* Pluck renders previews smaller than the photo: fixed pixel radii shrink with it. */
  const float preview_scale = fminf((float)MAX(w, h) / fmaxf(full_long_edge, 1.0f), 1.0f);
  float *plane = dt_alloc_align_float(npix * 3), *corr = dt_alloc_align_float(npix * 3), *scratch = dt_alloc_align_float(npix);
  if(!plane || !corr || !scratch)
  {
    free(plane); free(corr); free(scratch);
    return g_strdup("not enough memory");
  }
  const sf_sim_t *s = sim;

  /* 1) camera exposure */
  strips(npix, ^(size_t a, size_t n) { sf_sim_expose(s, in + a * 4, plane + a * 3, n, 4, 3); });

  /* 2) highlight boost, diffusion filter, halation, on linear exposure */
  sf_boost_highlights(plane, w, h, P(pr, "boost_ev"), P(pr, "boost_range"), P(pr, "protect_ev"));
  if(P(pr, "diffusion_on") > 0.5f)
    sf_diffusion_filter(plane, w, h, 0, 0, (double)pixel_um, (int)P(pr, "diffusion_filter_family"),
                        P(pr, "diffusion_strength"), P(pr, "diffusion_scale"), P(pr, "diffusion_warmth"));
  if(P(pr, "halation_on") > 0.5f && (P(pr, "scatter_amount") > 0.0f || P(pr, "halation_amount") > 0.0f))
  {
    double hal_strength[3], hal_sigma_um;
    sf_sim_halation_params(s, hal_strength, &hal_sigma_um);
    hal_sigma_um = fmin(hal_sigma_um, (double)SF_HALATION_FIRST_SIGMA_UM);
    double sc_core[3], sc_tail[3], sc_w[3];
    sf_sim_scatter_params(s, sc_core, sc_tail, sc_w);
    for(int c = 0; c < 3; c++)
    {
      sc_core[c] = fmin(sc_core[c], (double)SF_SCATTER_CORE_CLAMP_UM);
      sc_tail[c] = fmin(sc_tail[c], (double)SF_SCATTER_TAIL_CLAMP_UM);
    }
    sf_halation(plane, w, h, 0, 0, (double)pixel_um, sc_core, sc_tail, sc_w, P(pr, "scatter_amount"), P(pr, "scatter_scale"),
                P(pr, "halation_amount"), P(pr, "halation_scale"), hal_strength, hal_sigma_um);
  }

  /* 3) development: log exposure, DIR coupler inhibition (diffused), density curves */
  strips(npix, ^(size_t a, size_t n) { sf_sim_lograw(plane + a * 3, n, 3); });
  const int couplers = P(pr, "couplers_amount") > 0.0f;
  if(couplers)
  {
    strips(npix, ^(size_t a, size_t n) { sf_sim_develop_corr(s, plane + a * 3, corr + a * 3, n, 3); });
    double cdiff_um, ctail_um, ctail_w;
    sf_sim_coupler_diffusion(s, &cdiff_um, &ctail_um, &ctail_w);
    const float csigma = (float)cdiff_um / fmaxf(pixel_um, 1e-3f);
    if(ctail_w > 0.0)
    {
      const float amp[3] = { SF_EXPTAIL_A0, SF_EXPTAIL_A1, SF_EXPTAIL_A2 };
      const float rat[3] = { SF_EXPTAIL_R0, SF_EXPTAIL_R1, SF_EXPTAIL_R2 };
      const float tail_px = (float)ctail_um / fmaxf(pixel_um, 1e-3f);
      float *mix = dt_alloc_align_float(npix * 3), *tmp = dt_alloc_align_float(npix * 3);
      if(mix && tmp)
      {
        const float wbase = 1.0f - (float)ctail_w;
        memcpy(tmp, corr, sizeof(float) * npix * 3);
        if(csigma > 0.1f) sf_blur_plane3_wide(tmp, w, h, 0, 0, csigma, scratch);
        for(size_t i = 0; i < npix * 3; i++) mix[i] = wbase * tmp[i];
        for(int g3 = 0; g3 < 3; g3++)
        {
          memcpy(tmp, corr, sizeof(float) * npix * 3);
          const float ts = rat[g3] * tail_px;
          if(ts > 0.1f) sf_blur_plane3_wide(tmp, w, h, 0, 0, ts, scratch);
          const float wk = (float)ctail_w * amp[g3];
          for(size_t i = 0; i < npix * 3; i++) mix[i] = fmaf(wk, tmp[i], mix[i]);
        }
        memcpy(corr, mix, sizeof(float) * npix * 3);
      }
      else if(csigma > 0.1f)
        sf_blur_plane3_wide(corr, w, h, 0, 0, csigma, scratch);
      free(mix);
      free(tmp);
    }
    else if(csigma > 0.1f)
      sf_blur_plane3_wide(corr, w, h, 0, 0, csigma, scratch);
  }
  float *corr_in = couplers ? corr : NULL;
  strips(npix, ^(size_t a, size_t n) { sf_sim_develop(s, plane + a * 3, corr_in ? corr_in + a * 3 : NULL, plane + a * 3, n, 3, 3); });

  /* 4) grain on the developed density */
  if(P(pr, "grain_on") > 0.5f && P(pr, "grain_amount") > 0.0f)
  {
    float *gbuf = corr;
    const float amount = P(pr, "grain_amount");
    const int mono = sf_sim_film_bw(s);
    const float npart_scale = (pixel_um * pixel_um) / (SF_GRAIN_REF_UM * SF_GRAIN_REF_UM);
    float grms[3], gunif[3], gdmin[3], gdmin_unused[3];
    sf_sim_grain_dmin_total(s, gdmin);
    sf_sim_film_grain3(s, grms, gunif, gdmin_unused);
    __block sf_grain_layers_t layers;
    sf_sim_grain_layers(s, &layers);
    const int nsub = layers.n;
    float dye_sigma[3][SF_GRAIN_MAX_SUBLAYERS];
    for(int c = 0; c < 3; c++)
      for(int sl = 0; sl < nsub; sl++)
      {
        const float npart_c = (float)layers.layer_npart[sl][c] * npart_scale;
        const float od_particle = (float)layers.layer_dmax[sl][c] / fmaxf(npart_c, 1e-6f);
        dye_sigma[c][sl] = SF_GRAIN_DYE_BLUR_UM * P(pr, "grain_dye_cloud") * sqrtf(fmaxf(od_particle, 0.0f)) * preview_scale;
      }
    float *raw[SF_GRAIN_MAX_SUBLAYERS] = { 0 };
    int raw_ok = 1;
    for(int sl = 0; sl < nsub; sl++) if(!(raw[sl] = dt_alloc_align_float(npix))) raw_ok = 0;
    if(!raw_ok)
      memset(gbuf, 0, npix * 3 * sizeof(float));
    else
    {
      float **rawp = raw;
      const int n_out_ch = mono ? 1 : 3;
      for(int oc = 0; oc < n_out_ch; oc++)
      {
        const int channel_idx = mono ? 1 : oc, seed_ch = mono ? 0 : oc;
        const float unif_ch = gunif[channel_idx];
        strips(npix, ^(size_t a, size_t n) {
          for(size_t k = a; k < a + n; k++)
          {
            const int x = (int)(k % (size_t)w), y = (int)(k / (size_t)w);
            const float density = mono ? (plane[k * 3] + plane[k * 3 + 1] + plane[k * 3 + 2]) / 3.0f : plane[k * 3 + channel_idx];
            float samp[SF_GRAIN_MAX_SUBLAYERS];
            sf_grain_raw_samples_ml(&layers, density, channel_idx, seed_ch, (uint32_t)x, (uint32_t)y, unif_ch, npart_scale, samp);
            for(int sl = 0; sl < nsub; sl++) rawp[sl][k] = samp[sl];
          }
        });
        for(int sl = 0; sl < nsub; sl++) sf_blur_plane1(raw[sl], w, h, dye_sigma[channel_idx][sl], NULL, scratch);
        const float floor_c = gdmin[channel_idx];
        strips(npix, ^(size_t a, size_t n) {
          for(size_t k = a; k < a + n; k++)
          {
            float total = 0.0f;
            for(int sl = 0; sl < nsub; sl++) total += rawp[sl][k];
            const float density = mono ? (plane[k * 3] + plane[k * 3 + 1] + plane[k * 3 + 2]) / 3.0f : plane[k * 3 + channel_idx];
            const float delta = (total - floor_c - density) * amount;
            if(mono) gbuf[k * 3] = gbuf[k * 3 + 1] = gbuf[k * 3 + 2] = delta;
            else gbuf[k * 3 + oc] = delta;
          }
        });
      }
    }
    for(int sl = 0; sl < nsub; sl++) free(raw[sl]);
    for(size_t k = 0; k < npix * 3; k++) plane[k] += gbuf[k];
    sf_blur_plane3(plane, w, h, P(pr, "grain_blur") > SF_GRAIN_BLUR_MIN ? 0.8f * P(pr, "grain_blur") * preview_scale
                                                                          : 0.8f * SF_GRAIN_BLUR_MIN * preview_scale, scratch);
    if(P(pr, "grain_usm_sigma") > 0.0f && P(pr, "grain_usm_amount") > 0.0f)
      sf_multiplicative_unsharp_mask3(plane, w, h, P(pr, "grain_usm_sigma") * preview_scale, P(pr, "grain_usm_amount"), gdmin, corr, scratch);
  }

  /* 5) print exposure and development (not when the film itself is scanned) */
  if(P(pr, "scan_film") < 0.5f)
  {
    strips(npix, ^(size_t a, size_t n) { sf_sim_print_expose(s, plane + a * 3, plane + a * 3, n, 3, 3); });
    sf_diffusion_plan_t pplan;
    if(P(pr, "print_diffusion_on") > 0.5f
       && sf_diffusion_build_plan((int)P(pr, "print_diffusion_filter_family"), P(pr, "print_diffusion_strength"),
                                  P(pr, "print_diffusion_warmth"), &pplan)
       && pplan.p_s > 0.0f)
    {
      for(size_t k = 0; k < npix * 3; k++) plane[k] = pow10f_(plane[k]);
      sf_diffusion_filter(plane, w, h, 0, 0, (double)pixel_um, (int)P(pr, "print_diffusion_filter_family"),
                          P(pr, "print_diffusion_strength"), P(pr, "print_diffusion_scale"), P(pr, "print_diffusion_warmth"));
      for(size_t k = 0; k < npix * 3; k++) plane[k] = log10f_(fmaxf(plane[k], 0.0f) + 1e-10f);
    }
    strips(npix, ^(size_t a, size_t n) { sf_sim_print_develop(s, plane + a * 3, plane + a * 3, n, 3, 3); });
  }

  /* 6) scanning, then the scanner's optics and the viewing glare */
  strips(npix, ^(size_t a, size_t n) { sf_sim_scan(s, plane + a * 3, plane + a * 3, n, 3, 3); });
  if(P(pr, "scan_blur") > 0.0f) sf_blur_plane3(plane, w, h, P(pr, "scan_blur") * preview_scale, scratch);
  if(P(pr, "scan_usm_sigma") > 0.0f && P(pr, "scan_usm_amount") > 0.0f)
    sf_unsharp_mask3(plane, w, h, P(pr, "scan_usm_sigma") * preview_scale, P(pr, "scan_usm_amount"), corr, scratch);
  if(P(pr, "scan_film") < 0.5f && P(pr, "glare_percent") > 0.0f)
    sf_glare(plane, w, h, P(pr, "glare_percent"), SF_GLARE_ROUGHNESS, SF_GLARE_BLUR_PX * preview_scale, 0, 0, scratch);

  /* RGBA, as Core Image reads floats */
  for(size_t k = 0; k < npix; k++)
  {
    out[k * 4] = plane[k * 3]; out[k * 4 + 1] = plane[k * 3 + 1]; out[k * 4 + 2] = plane[k * 3 + 2]; out[k * 4 + 3] = 1.0f;
  }
  free(plane); free(corr); free(scratch);
  return NULL;
}

/* ----------------------------------------------------------------- jobs -- */

static void json_string(FILE *f, const char *s)
{
  fputc('"', f);
  for(; s && *s; s++)
  {
    if(*s == '"' || *s == '\\') { fputc('\\', f); fputc(*s, f); }
    else if((unsigned char)*s < 0x20) fprintf(f, "\\u%04x", *s);
    else fputc(*s, f);
  }
  fputc('"', f);
}

static void answer_error(const char *message)
{
  fputs("{\"error\":", stdout);
  json_string(stdout, message);
  fputs("}\n", stdout);
}

static int compare_names(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }

static void profiles(const char *dir)
{
  char path[2048];
  snprintf(path, sizeof path, "%s/profiles", dir);
  DIR *d = opendir(path);
  if(!d) { answer_error("the film data isn't there"); return; }
  /* sorted, so the menus stay in order */
  char *names[256];
  int count = 0;
  for(struct dirent *e; (e = readdir(d)) && count < 256;)
  {
    const size_t n = strlen(e->d_name);
    if(n > 5 && !strcmp(e->d_name + n - 5, ".json")) names[count++] = g_strdup(e->d_name);
  }
  closedir(d);
  qsort(names, count, sizeof(char *), compare_names);
  for(int pass = 0; pass < 2; pass++)
  {
    fputs(pass == 0 ? "{\"film\":[" : "],\"print\":[", stdout);
    int first = 1;
    for(int i = 0; i < count; i++)
    {
      snprintf(path, sizeof path, "%s/profiles/%s", dir, names[i]);
      JsonParser *parser = json_parser_new();
      if(json_parser_load_from_file(parser, path, NULL))
      {
        JsonObject *info = json_object_get_object_member(json_node_get_object(json_parser_get_root(parser)), "info");
        const char *stage = json_object_get_string_member(info, "stage");
        const int printing = stage && !strcmp(stage, "printing");
        if(info && printing == pass)
        {
          if(!first) fputc(',', stdout);
          first = 0;
          fputs("{\"id\":", stdout); json_string(stdout, json_object_get_string_member(info, "stock"));
          fputs(",\"name\":", stdout); json_string(stdout, json_object_get_string_member(info, "name"));
          fputs(",\"type\":", stdout); json_string(stdout, json_object_get_string_member(info, "type"));
          fputs(",\"use\":", stdout); json_string(stdout, json_object_get_string_member(info, "use"));
          const char *target = json_object_get_string_member(info, "target_print");
          fputs(",\"print\":", stdout);
          if(target) json_string(stdout, target); else fputs("null", stdout);
          const char *model = json_object_get_string_member(info, "channel_model");
          fprintf(stdout, ",\"bw\":%s}", model && !strcmp(model, "bw") ? "true" : "false");
        }
      }
      g_object_unref(parser);
    }
  }
  fputs("]}\n", stdout);
  for(int i = 0; i < count; i++) free(names[i]);
}

static void schema(void)
{
  fputc('{', stdout);
  for(size_t i = 0; i < NSETTINGS; i++)
  {
    if(i) fputc(',', stdout);
    json_string(stdout, SETTINGS[i].name);
    fprintf(stdout, ":{\"default\":%g,\"min\":%g,\"max\":%g,\"kind\":\"%s\"}", SETTINGS[i].def, SETTINGS[i].min, SETTINGS[i].max,
            SETTINGS[i].flag == 1 ? "flag" : SETTINGS[i].flag == 2 ? "choice" : "number");
  }
  fputs("}\n", stdout);
}

static void render_job(JsonObject *job)
{
  const char *dir = json_object_get_string_member(job, "pack");
  const char *input = json_object_get_string_member(job, "input"), *output = json_object_get_string_member(job, "output");
  const int w = (int)json_object_get_int_member(job, "width"), h = (int)json_object_get_int_member(job, "height");
  const char *film = json_object_get_string_member(job, "film"), *paper = json_object_get_string_member(job, "print");
  if(!dir || !input || !output || !film || w <= 0 || h <= 0) { answer_error("incomplete job"); return; }
  params_t p;
  params_from(&p, json_object_get_object_member(job, "set"));
  char *err = build_sim(dir, film, paper, &p);
  if(err) { answer_error(err); free(err); return; }
  const size_t npix = (size_t)w * h;
  float *in = malloc(npix * 4 * sizeof(float)), *out = malloc(npix * 4 * sizeof(float));
  FILE *f = fopen(input, "rb");
  const int read_ok = f && in && fread(in, sizeof(float), npix * 4, f) == npix * 4;
  if(f) fclose(f);
  if(!read_ok || !out) { free(in); free(out); answer_error("the picture couldn't be read"); return; }
  double full = json_object_has_member(job, "full_long_edge") ? json_object_get_double_member(job, "full_long_edge") : MAX(w, h);
  err = render(in, out, w, h, &p, (float)full);
  free(in);
  if(err) { free(out); answer_error(err); free(err); return; }
  f = fopen(output, "wb");
  const int write_ok = f && fwrite(out, sizeof(float), npix * 4, f) == npix * 4;
  if(f) fclose(f);
  free(out);
  if(!write_ok) { answer_error("the picture couldn't be written"); return; }
  fputs("{\"ok\":true}\n", stdout);
}

/* --------------------------------------------------------------- tables -- */

/* Pluck's own film (Sources/Pluck/Studio/Film*.swift) runs the per-pixel chain on the GPU from
   tables dumped here, in three parts that are shared:
     film/<film>.pft          the film's exposure and development (and its scan, when it's
                              looked at without a print), and the spatial effects' numbers;
     paper/<paper>.pft        the paper's curves and its scan, which don't depend on the film;
     pair/<film>__<paper>.pft the enlarger between the two, and the scanner's black/white fit
                              (its end points come from the film).
   Each file: "PFT1", a UInt32 little-endian header length, the UTF-8 JSON header (padded with
   spaces so the blobs start 16-byte aligned in the file), then the blobs. A blob's offset counts
   from the end of the header and is a multiple of 16; "size" bytes are stored there, LZFSE
   compressed when "codec" is "lzfse" (to "raw_size" bytes). Those bytes are "filter"
   "delta_shuffle": the little-endian f32 or f16 values' bit patterns as integers, each minus the
   one a channel earlier (modulo 2^32 or 2^16), with byte i of value k at i*count + k.
   Every grid is node-aligned (node i at lo + i*(hi-lo)/(n-1)), interpolated linearly and clamped
   at its ends. In a 2D or 3D blob the first input runs fastest: expose_q[v][u][c] and
   print_expose/scan/scan_y[v2][v1][v0][c]. The 1D curves sit on the sim's log-exposure
   grid at PFT_UP times its density, so the sim's own linear curves come out exactly. */

#define PFT_XY 256       /* expose_q: nodes per axis, u = |1-x| and v = y/(1-x) in [0,1] */
#define PFT_UP 4
#define PFT_NLE ((SF_NLE - 1) * PFT_UP + 1)
#define PFT_RECV 256
#define PFT_N 33         /* pair print_expose: nodes per density axis (the job's "n") */
#define PFT_N_SCAN 65    /* the film's scan: nodes per density axis ("n_scan") */
#define PFT_N_PAPER 81   /* the paper's scan and scan_y: nodes per density axis ("n_scan") */
#define PFT_N_DLOG 33    /* the paper's scan_dlog: nodes per density axis ("n_dlog") */
#define PFT_OWN_SCAN 0.1f /* a pair brings its own scan past this |ln(m / paper's m)| */
#define PFT_N_OWN 97     /* a pair's own scan: nodes per density axis ("n_scan") */

typedef struct ftab_t
{
  /* film */
  char film[256];
  int bw, couplers, has_scan, n_scan, xy_half;
  float expose_m[9], ev_scale0, scan_ev_scale0, le0, le_step, coupler_m[9];
  float recv_lo[3], recv_hi[3], scan_lo[3], scan_hi[3];
  float *expose_q, *silver, *receive, *curves, *scan;
  /* paper */
  char paper[256];
  int n_pscan, n_dlog;
  float print_le0, print_le_step, ref_m, ref_q, pscan_lo[3], pscan_hi[3];
  float *print_curves, *pscan, *pscan_y, *pscan_dlog;
  /* pair */
  char pair_film[256], pair_paper[256];
  int n, bw_on, baked;
  float print_log_offset0, bw_m, bw_q, baked_ev, pe_lo[3], pe_hi[3];
  int n_own;
  float own_lo[3], own_hi[3];
  float *print_expose, *own_scan;
} ftab_t;

static void ftab_free(ftab_t *t)
{
  free(t->expose_q); free(t->silver); free(t->receive); free(t->curves); free(t->scan);
  free(t->print_curves); free(t->pscan); free(t->pscan_y); free(t->pscan_dlog); free(t->print_expose); free(t->own_scan);
  memset(t, 0, sizeof *t);
}

/* half floats, round to nearest even, so the in-memory tables are what the file holds */
static uint16_t half_from(float f)
{
  union { float f; uint32_t u; } v = { f };
  const uint16_t sign = (uint16_t)((v.u >> 16) & 0x8000u);
  const uint32_t a = v.u & 0x7fffffffu;
  if(a >= 0x7f800000u) return sign | (a > 0x7f800000u ? 0x7e00u : 0x7c00u);
  if(a >= 0x47800000u) return sign | 0x7c00u;
  if(a < 0x38800000u) return sign | (uint16_t)lrintf(fabsf(f) * 16777216.0f);
  uint32_t h = (((a >> 23) - 112u) << 10) | ((a & 0x7fffffu) >> 13);
  const uint32_t rest = a & 0x1fffu;
  if(rest > 0x1000u || (rest == 0x1000u && (h & 1u))) h++;
  return sign | (uint16_t)h;
}

static float half_to(uint16_t h)
{
  const uint32_t e = (h >> 10) & 0x1fu, m = h & 0x3ffu;
  const float f = e == 0 ? ldexpf((float)m, -24) : e == 31 ? (m ? NAN : INFINITY) : ldexpf((float)(m | 0x400u), (int)e - 25);
  return (h & 0x8000u) ? -f : f;
}

static inline float half_round(float f) { return half_to(half_from(f)); }

/* the sim's own expose lookup (spektra_sim.c: tri2quad_f, mitchell_weight_f, cubic_interp_2d_f) */
static inline int ft_safe_index(int idx, int L)
{
  if(idx < 0) return -idx;
  if(idx >= L) return 2 * (L - 1) - idx;
  return idx;
}

static inline void ft_base_frac(float coord, int L, int *base, float *frac)
{
  if(!(coord > 0.0f)) { *base = 0; *frac = 0.0f; return; }
  if(coord >= (float)(L - 1)) { *base = L - 2; *frac = 1.0f; return; }
  *base = (int)floorf(coord);
  *frac = coord - *base;
}

static inline float ft_mitchell(float t)
{
  const float B = 1.0f / 3.0f, C = 1.0f / 3.0f;
  const float x = fabsf(t);
  if(x < 1.0f)
    return (1.0f / 6.0f) * fmaf((12.0f - 9.0f * B - 6.0f * C) * x * x, x, fmaf((-18.0f + 12.0f * B + 6.0f * C) * x, x, (6.0f - 2.0f * B)));
  if(x < 2.0f)
    return (1.0f / 6.0f) * fmaf((-B - 6.0f * C) * x * x, x, fmaf((6.0f * B + 30.0f * C) * x, x, fmaf((-12.0f * B - 48.0f * C), x, (8.0f * B + 24.0f * C))));
  return 0.0f;
}

/* film raw exposure per unit of X+Y+Z at the square's (qx, qy) */
static void ft_expose_at(const sf_sim_gpu_t *g, float qx, float qy, float out[3])
{
  const int L = g->tc_n;
  int xb, yb;
  float xf, yf, wx[4], wy[4];
  ft_base_frac(qx * (float)(L - 1), L, &xb, &xf);
  ft_base_frac(qy * (float)(L - 1), L, &yb, &yf);
  for(int i = 0; i < 4; i++) { wx[i] = ft_mitchell(xf + 1.0f - i); wy[i] = ft_mitchell(yf + 1.0f - i); }
  float acc[3] = { 0, 0, 0 }, wsum = 0.0f;
  for(int i = 0; i < 4; i++)
    for(int j = 0; j < 4; j++)
    {
      const float w = wx[i] * wy[j], *px = g->tc_lut + ((size_t)ft_safe_index(xb - 1 + i, L) * L + ft_safe_index(yb - 1 + j, L)) * 3;
      wsum += w;
      for(int c = 0; c < 3; c++) acc[c] = fmaf(w, px[c], acc[c]);
    }
  for(int c = 0; c < 3; c++) out[c] = wsum != 0.0f ? acc[c] / wsum : acc[c];
}

/* the sim's linear curve lookup on its own log-exposure grid (interp_curve_uniform_f) */
static inline float ft_sim_curve(const float *curves, float x, float le0, float inv_step, int c)
{
  const float t = (x - le0) * inv_step;
  if(t <= 0.0f) return curves[c];
  if(t >= (float)(SF_NLE - 1)) return curves[(SF_NLE - 1) * 3 + c];
  const int i = (int)t;
  return fmaf(t - i, curves[(i + 1) * 3 + c] - curves[i * 3 + c], curves[i * 3 + c]);
}

/* Pluck's side: linear lookups, clamped (NaN lands on the first node) */
static inline float ft_clampi(float t, int n) { return t > 0.0f ? (t < (float)(n - 1) ? t : (float)(n - 1)) : 0.0f; }

static inline float ft_lin1(const float *tab, int n, float t, int c)
{
  t = ft_clampi(t, n);
  const int i = MIN((int)t, n - 2);
  const float f = t - i;
  return tab[i * 3 + c] + f * (tab[(i + 1) * 3 + c] - tab[i * 3 + c]);
}

static void ft_lin2(const float *tab, int n, float tx, float ty, float out[3])
{
  tx = ft_clampi(tx, n); ty = ft_clampi(ty, n);
  const int x = MIN((int)tx, n - 2), y = MIN((int)ty, n - 2);
  const float fx = tx - x, fy = ty - y;
  const float *p00 = tab + ((size_t)y * n + x) * 3, *p01 = p00 + 3, *p10 = p00 + (size_t)n * 3, *p11 = p10 + 3;
  for(int c = 0; c < 3; c++)
  {
    const float a = p00[c] + fx * (p01[c] - p00[c]), b = p10[c] + fx * (p11[c] - p10[c]);
    out[c] = a + fy * (b - a);
  }
}

static void ft_lin3(const float *tab, int n, const float lo[3], const float hi[3], const float d[3], float out[3])
{
  int i[3];
  float f[3];
  for(int k = 0; k < 3; k++)
  {
    const float t = ft_clampi((d[k] - lo[k]) / (hi[k] - lo[k]) * (float)(n - 1), n);
    i[k] = MIN((int)t, n - 2);
    f[k] = t - i[k];
  }
  const size_t s0 = 3, s1 = (size_t)n * 3, s2 = (size_t)n * n * 3;
  const float *p = tab + i[2] * s2 + i[1] * s1 + i[0] * s0;
  for(int c = 0; c < 3; c++)
  {
    const float c00 = p[c] + f[0] * (p[s0 + c] - p[c]);
    const float c10 = p[s1 + c] + f[0] * (p[s1 + s0 + c] - p[s1 + c]);
    const float c01 = p[s2 + c] + f[0] * (p[s2 + s0 + c] - p[s2 + c]);
    const float c11 = p[s2 + s1 + c] + f[0] * (p[s2 + s1 + s0 + c] - p[s2 + s1 + c]);
    const float c0 = c00 + f[1] * (c10 - c00), c1 = c01 + f[1] * (c11 - c01);
    out[c] = c0 + f[2] * (c1 - c0);
  }
}

static float ft_lin3_1(const float *tab, int n, const float lo[3], const float hi[3], const float d[3])
{
  int i[3];
  float f[3];
  for(int k = 0; k < 3; k++)
  {
    const float t = ft_clampi((d[k] - lo[k]) / (hi[k] - lo[k]) * (float)(n - 1), n);
    i[k] = MIN((int)t, n - 2);
    f[k] = t - i[k];
  }
  const size_t s1 = (size_t)n, s2 = (size_t)n * n;
  const float *p = tab + i[2] * s2 + i[1] * s1 + i[0];
  const float c00 = p[0] + f[0] * (p[1] - p[0]), c10 = p[s1] + f[0] * (p[s1 + 1] - p[s1]);
  const float c01 = p[s2] + f[0] * (p[s2 + 1] - p[s2]), c11 = p[s2 + s1] + f[0] * (p[s2 + s1 + 1] - p[s2 + s1]);
  const float c0 = c00 + f[1] * (c10 - c00), c1 = c01 + f[1] * (c11 - c01);
  return c0 + f[2] * (c1 - c0);
}

/* The evaluation recipe (docs/superpowers/plans/2026-11-04-instant-film.md, with the changes in
   task-2-report.md), as Pluck runs it. `scanned`: the film is looked at without a print. */
static void ftab_pixel_le(const ftab_t *t, const float rgb[3], float ev, float pev, int scanned, float out[3],
                          float le_out[3], float d_out[3])
{
  float xyz[3], e[3], le[3], silver[3], d[3];
  for(int i = 0; i < 3; i++) xyz[i] = t->expose_m[i * 3] * rgb[0] + t->expose_m[i * 3 + 1] * rgb[1] + t->expose_m[i * 3 + 2] * rgb[2];
  const float b = xyz[0] + xyz[1] + xyz[2], inv_b = 1.0f / fmaxf(b, 1e-10f);
  /* chromaticity to the exposure table's coordinates: u = |1-x| and v = y/(1-x), each clamped to [0,1] */
  const float cx = xyz[0] * inv_b, cy = xyz[1] * inv_b;
  const float u = fminf(fabsf(1.0f - cx), 1.0f), v = CLAMP(cy / fmaxf(1.0f - cx, 1e-10f), 0.0f, 1.0f);
  ft_lin2(t->expose_q, PFT_XY, u * (PFT_XY - 1), v * (PFT_XY - 1), e);
  const float bb = isfinite(b) ? b : 0.0f, scale = (scanned ? t->scan_ev_scale0 : t->ev_scale0) * exp2f(ev);
  for(int c = 0; c < 3; c++) le[c] = log10f(fmaxf(bb * e[c] * scale, 0.0f) + 1e-10f);
  for(int c = 0; c < 3; c++) silver[c] = ft_lin1(t->silver, PFT_NLE, (le[c] - t->le0) / t->le_step, c);
  for(int c = 0; c < 3; c++)
  {
    const float corr = t->coupler_m[c * 3] * silver[0] + t->coupler_m[c * 3 + 1] * silver[1] + t->coupler_m[c * 3 + 2] * silver[2];
    const float recv = ft_lin1(t->receive, PFT_RECV, (corr - t->recv_lo[c]) / (t->recv_hi[c] - t->recv_lo[c]) * (PFT_RECV - 1), c);
    d[c] = ft_lin1(t->curves, PFT_NLE, (le[c] - recv - t->le0) / t->le_step, c);
  }
  if(le_out) memcpy(le_out, le, sizeof le);
  if(d_out) memcpy(d_out, d, sizeof d);
  if(scanned) { ft_lin3(t->scan, t->n_scan, t->scan_lo, t->scan_hi, d, out); return; }
  float pe[3], pd[3];
  ft_lin3(t->print_expose, t->n, t->pe_lo, t->pe_hi, d, pe);
  for(int c = 0; c < 3; c++)
    pd[c] = ft_lin1(t->print_curves, PFT_NLE, (pe[c] + t->print_log_offset0 + pev * 0.30103f - t->print_le0) / t->print_le_step, c);
  /* a pair whose black/white fit is far from the paper's own brings its own scan */
  if(t->own_scan) { ft_lin3(t->own_scan, t->n_own, t->own_lo, t->own_hi, pd, out); return; }
  /* the paper's scan holds the colour under the paper's own black/white fit; the pair's fit (its
     end points come from the film) only rescales the viewed colour, by the ratio of the two */
  ft_lin3(t->pscan, t->n_pscan, t->pscan_lo, t->pscan_hi, pd, out);
  const float y = ft_lin3_1(t->pscan_y, t->n_pscan, t->pscan_lo, t->pscan_hi, pd);
  const float ref = CLAMP(t->ref_m * y + t->ref_q, 0.0f, 1.0f);
  const float fit = t->bw_on ? CLAMP(t->bw_m * y + t->bw_q, 0.0f, 1.0f) : y;
  if(!(ref > 0.0f) || !(fit > 0.0f)) { out[0] = out[1] = out[2] = 0.0f; return; }
  const float ratio = fit / ref, lr = logf(ratio);
  float dl[3];
  ft_lin3(t->pscan_dlog, t->n_dlog, t->pscan_lo, t->pscan_hi, pd, dl);
  for(int c = 0; c < 3; c++) out[c] = ratio * out[c] + lr * dl[c];
}

static void ftab_pixel(const ftab_t *t, const float rgb[3], float ev, float pev, int scanned, float out[3])
{
  ftab_pixel_le(t, rgb, ev, pev, scanned, out, NULL, NULL);
}

/* a 3D table through one of the sim's own stages at every node, rounded to half */
typedef void (^ft_eval_fn)(const float *in, float *out, size_t n);
static float *ft_grid3(int n, const float lo[3], const float hi[3], float minus, ft_eval_fn fn)
{
  const size_t n3 = (size_t)n * n * n;
  float *grid = malloc(n3 * 3 * sizeof(float)), *out = malloc(n3 * 3 * sizeof(float));
  if(!grid || !out) { free(grid); free(out); return NULL; }
  for(size_t k = 0; k < n3; k++)
  {
    const size_t i[3] = { k % n, (k / n) % n, k / ((size_t)n * n) };
    for(int c = 0; c < 3; c++) grid[k * 3 + c] = lo[c] + (hi[c] - lo[c]) * (float)i[c] / (float)(n - 1);
  }
  strips(n3, ^(size_t a, size_t cnt) { fn(grid + a * 3, out + a * 3, cnt); });
  for(size_t k = 0; k < n3 * 3; k++) out[k] = half_round(out[k] - minus);
  free(grid);
  return out;
}

/* a 1D curve of the sim's, on the finer grid */
static float *ft_curve_up(const sf_sim_gpu_t *g, const float *curves)
{
  float *v = malloc(sizeof(float) * PFT_NLE * 3);
  if(!v) return NULL;
  const double le_step = 1.0 / (double)g->inv_le_step;
  for(int i = 0; i < PFT_NLE; i++)
    for(int c = 0; c < 3; c++) v[i * 3 + c] = ft_sim_curve(curves, (float)(g->le0 + i * (le_step / PFT_UP)), g->le0, g->inv_le_step, c);
  return v;
}

/* The film part. `with_scan`: the sim is built without a print, and its scan is dumped too. */
static char *ftab_make_film(const sf_sim_t *s, const params_t *p, int with_scan, int n_scan, int xy_half, ftab_t *t)
{
  sf_sim_gpu_t *g = sf_sim_gpu_export(s);
  if(!g) return g_strdup("the film couldn't be set up");
  t->bw = sf_sim_film_bw(s);
  t->couplers = g->couplers_active;
  t->xy_half = xy_half;
  memcpy(t->expose_m, g->m_in, sizeof t->expose_m);
  /* printed, the camera exposure is just 2^(exposure_ev - push_pull_stops); a scanned slide adds
     the scanner's mid-grey correction (ev_scale in sf_sim_build) */
  t->ev_scale0 = g->has_print ? g->ev_scale : (float)pow(2.0, (double)(0.0f - P(p, "push_pull_stops")));
  const double le_step = 1.0 / (double)g->inv_le_step;
  t->le0 = g->le0;
  t->le_step = (float)(le_step / PFT_UP);
  for(int m = 0; m < 3; m++)
    for(int k = 0; k < 3; k++) t->coupler_m[m * 3 + k] = t->couplers ? g->couplers_M[k * 3 + m] : 0.0f;

  t->expose_q = malloc(sizeof(float) * PFT_XY * PFT_XY * 3);
  t->silver = calloc(PFT_NLE * 3, sizeof(float));
  t->curves = ft_curve_up(g, t->couplers ? g->curves_before : g->curves_norm);
  t->receive = malloc(sizeof(float) * PFT_RECV * 3);
  if(!t->expose_q || !t->silver || !t->curves || !t->receive) { sf_sim_gpu_free(g); return g_strdup("not enough memory"); }
  for(int y = 0; y < PFT_XY; y++)
    for(int x = 0; x < PFT_XY; x++)
    {
      float *e = t->expose_q + ((size_t)y * PFT_XY + x) * 3;
      const float u = (float)x / (PFT_XY - 1);
      ft_expose_at(g, u * u, (float)y / (PFT_XY - 1), e);
      if(xy_half) for(int c = 0; c < 3; c++) e[c] = half_round(e[c]);
    }

  /* development: silver after the donor term */
  float smin[3] = { INFINITY, INFINITY, INFINITY }, smax[3] = { -INFINITY, -INFINITY, -INFINITY };
  if(t->couplers)
    for(int i = 0; i < PFT_NLE; i++)
      for(int c = 0; c < 3; c++)
      {
        const float dn = ft_sim_curve(g->curves_norm, (float)(g->le0 + i * (le_step / PFT_UP)), g->le0, g->inv_le_step, c);
        float sv = g->film_positive ? g->film_dmax[c] - dn : dn;
        if(g->couplers_donor_lm) sv = sv * (g->couplers_donor_K[c] + g->couplers_donor_Dref[c]) / (g->couplers_donor_K[c] + sv);
        t->silver[i * 3 + c] = sv;
        smin[c] = fminf(smin[c], sv);
        smax[c] = fmaxf(smax[c], sv);
      }
  /* the inhibitor received, over every correction the silver can make (blurring stays inside it) */
  for(int m = 0; m < 3; m++)
  {
    float lo = 0.0f, hi = 0.0f;
    if(t->couplers)
      for(int k = 0; k < 3; k++)
      {
        const float a = smin[k] * t->coupler_m[m * 3 + k], b = smax[k] * t->coupler_m[m * 3 + k];
        lo += fminf(a, b);
        hi += fmaxf(a, b);
      }
    const float pad = 0.02f * (hi - lo) + 1e-3f;
    t->recv_lo[m] = lo - pad;
    t->recv_hi[m] = hi + pad;
    for(int i = 0; i < PFT_RECV; i++)
    {
      const float c = t->recv_lo[m] + (t->recv_hi[m] - t->recv_lo[m]) * (float)i / (PFT_RECV - 1);
      t->receive[i * 3 + m] = (t->couplers && g->couplers_recv_lm)
                                  ? c * (g->couplers_recv_Kr[m] + g->couplers_recv_cref[m]) / (g->couplers_recv_Kr[m] + c)
                                  : c;
    }
  }
  if(with_scan && !g->has_print)
  {
    t->has_scan = 1;
    t->n_scan = n_scan;
    t->scan_ev_scale0 = g->ev_scale;
    for(int c = 0; c < 3; c++)
    {
      t->scan_lo[c] = g->scan_lo[c];
      t->scan_hi[c] = (float)((double)g->scan_lo[c] + 1.0 / (double)g->scan_inv_range[c]);
    }
  }
  sf_sim_gpu_free(g);
  if(t->has_scan && !(t->scan = ft_grid3(n_scan, t->scan_lo, t->scan_hi, 0.0f, ^(const float *in, float *out, size_t n) {
       sf_sim_scan(s, in, out, n, 3, 3);
     })))
    return g_strdup("not enough memory");
  return NULL;
}

static inline double ft_srgb_to_linear(double v) { return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }

/* the paper's reference black/white fit: its thinnest and densest points to the scanner's white
   and black, at the scanner's default levels (a positive paper is never fitted: m = 1, q = 0) */
static void ft_ref_fit(const sf_sim_t *s, const char *paper_type, const float lo[3], const float hi[3], float *m, float *q)
{
  *m = 1.0f;
  *q = 0.0f;
  if(paper_type && !strcmp(paper_type, "positive")) return;
  sf_sim_params_t dp;
  sf_sim_params_defaults(&dp);
  float ends[6], xyz[6];
  for(int c = 0; c < 3; c++) { ends[c] = lo[c]; ends[3 + c] = hi[c]; }
  sf_sim_scan_xyz(s, ends, xyz, 2);
  /* the ends as the scanner sees them, before the output's luminance boost (which the fit then
     acts on, as in the sim) */
  sf_sim_gpu_t *g = sf_sim_gpu_export(s);
  const double boost = g && g->out_luminance_boost > 0.0f ? g->out_luminance_boost : 1.0;
  sf_sim_gpu_free(g);
  const double yw = xyz[1] / boost, yb = xyz[4] / boost, wl = ft_srgb_to_linear(dp.scan_white_level), bl = ft_srgb_to_linear(dp.scan_black_level);
  if(fabs(yw - yb) > 1e-9)
  {
    *m = (float)((wl - bl) / (yw - yb));
    *q = (float)(bl - *m * yb);
  }
}

/* the paper's type, from its profile */
static char *ft_paper_type(const char *dir, const char *paper)
{
  char path[2048];
  snprintf(path, sizeof path, "%s/profiles/%s.json", dir, paper);
  char *type = NULL;
  JsonParser *pp = json_parser_new();
  if(json_parser_load_from_file(pp, path, NULL))
  {
    JsonObject *info = json_object_get_object_member(json_node_get_object(json_parser_get_root(pp)), "info");
    const char *ty = info ? json_object_get_string_member(info, "type") : NULL;
    type = ty ? g_strdup(ty) : NULL;
  }
  g_object_unref(pp);
  return type;
}

/* The paper part: its curves, and its scan to the finished colour under the paper's own
   black/white fit (the paper's white and black, placed at the scanner's levels), with the viewed
   Y before any fit. None of it depends on the film the sim was built with. */
static char *ftab_make_paper(const sf_sim_t *s, const char *paper_type, int n_pscan, int n_dlog, ftab_t *t)
{
  sf_sim_gpu_t *g = sf_sim_gpu_export(s);
  if(!g) return g_strdup("the film couldn't be set up");
  if(!g->has_print) { sf_sim_gpu_free(g); return g_strdup("a paper needs a print"); }
  t->n_pscan = n_pscan;
  t->n_dlog = n_dlog;
  t->print_le0 = g->le0;
  t->print_le_step = (float)(1.0 / (double)g->inv_le_step / PFT_UP);
  t->print_curves = ft_curve_up(g, g->print_curves);
  for(int c = 0; c < 3; c++)
  {
    t->pscan_lo[c] = g->scan_lo[c];
    t->pscan_hi[c] = (float)((double)g->scan_lo[c] + 1.0 / (double)g->scan_inv_range[c]);
  }
  sf_sim_gpu_free(g);
  if(!t->print_curves) return g_strdup("not enough memory");
  ft_ref_fit(s, paper_type, t->pscan_lo, t->pscan_hi, &t->ref_m, &t->ref_q);
  const float rm = t->ref_m, rq = t->ref_q;
  t->pscan = ft_grid3(n_pscan, t->pscan_lo, t->pscan_hi, 0.0f, ^(const float *in, float *out, size_t n) {
    sf_sim_scan_xyz(s, in, out, n);
    for(size_t k = 0; k < n; k++)
    {
      float *v = out + k * 3;
      const float y = v[1], yc = CLAMP(fmaf(rm, y, rq), 0.0f, 1.0f), sc = yc / (y + 1e-10f);
      for(int c = 0; c < 3; c++) v[c] *= sc;
    }
    sf_sim_scan_finish(s, out, out, n);
  });
  /* how far the finish is from scaling with the light: d F(s x) / d ln s - F(x), at s = 1 */
  t->pscan_dlog = ft_grid3(n_dlog, t->pscan_lo, t->pscan_hi, 0.0f, ^(const float *in, float *out, size_t n) {
    float *x = malloc(n * 9 * sizeof(float)), *f = malloc(n * 9 * sizeof(float));
    if(!x || !f) { free(x); free(f); memset(out, 0, n * 3 * sizeof(float)); return; }
    sf_sim_scan_xyz(s, in, x, n);
    const float delta = 0.02f, up = expf(delta), down = expf(-delta);
    for(size_t k = 0; k < n; k++)
    {
      float *v = x + k * 3;
      const float y = v[1], yc = CLAMP(fmaf(rm, y, rq), 0.0f, 1.0f), sc = yc / (y + 1e-10f);
      for(int c = 0; c < 3; c++)
      {
        v[c] *= sc;
        x[(n + k) * 3 + c] = v[c] * up;
        x[(2 * n + k) * 3 + c] = v[c] * down;
      }
    }
    sf_sim_scan_finish(s, x, f, 3 * n);
    for(size_t k = 0; k < n * 3; k++) out[k] = (f[3 * n + k] - f[6 * n + k]) / (2.0f * delta) - f[k];
    free(x); free(f);
  });
  /* Y alone, as one channel */
  float *y3 = ft_grid3(n_pscan, t->pscan_lo, t->pscan_hi, 0.0f, ^(const float *in, float *out, size_t n) {
    sf_sim_scan_xyz(s, in, out, n);
  });
  const size_t n3 = (size_t)n_pscan * n_pscan * n_pscan;
  if(y3 && (t->pscan_y = malloc(n3 * sizeof(float))))
    for(size_t k = 0; k < n3; k++) t->pscan_y[k] = y3[k * 3 + 1];
  free(y3);
  if(!t->pscan || !t->pscan_y || !t->pscan_dlog) return g_strdup("not enough memory");
  return NULL;
}

/* The pair part: the enlarger, and the scanner's fit whose end points come from the film.
   `baked_ev`: the exposure_ev the sim was built with (0, unless auto print exposure ties the
   enlarger to it). */
static char *ftab_make_pair(const sf_sim_t *s, const char *paper_type, int n, int n_scan, int own, ftab_t *t)
{
  sf_sim_gpu_t *g = sf_sim_gpu_export(s);
  if(!g) return g_strdup("the film couldn't be set up");
  if(!g->has_print) { sf_sim_gpu_free(g); return g_strdup("a pair needs a print"); }
  t->n = n;
  t->print_log_offset0 = g->log10_print_exposure;
  t->bw_on = g->scan_bw_on;
  t->bw_m = g->scan_bw_m;
  t->bw_q = g->scan_bw_q;
  for(int c = 0; c < 3; c++)
  {
    t->pe_lo[c] = g->enl_lo[c];
    t->pe_hi[c] = (float)((double)g->enl_lo[c] + 1.0 / (double)g->enl_inv_range[c]);
  }
  for(int c = 0; c < 3; c++)
  {
    t->pscan_lo[c] = g->scan_lo[c];
    t->pscan_hi[c] = (float)((double)g->scan_lo[c] + 1.0 / (double)g->scan_inv_range[c]);
  }
  const float lpe = g->log10_print_exposure;
  sf_sim_gpu_free(g);
  if(!(t->print_expose = ft_grid3(n, t->pe_lo, t->pe_hi, lpe, ^(const float *in, float *out, size_t cnt) {
       sf_sim_print_expose(s, in, out, cnt, 3, 3);
     })))
    return g_strdup("not enough memory");
  /* far from the paper's own fit, rescaling the paper's scan isn't close enough: the pair brings
     its own (one shipped pair; and every pair baked for auto print exposure, which is made for
     one photo anyway) */
  float rm, rq;
  ft_ref_fit(s, paper_type, t->pscan_lo, t->pscan_hi, &rm, &rq);
  const int ref_fitted = !(rm == 1.0f && rq == 0.0f);
  if(own || t->bw_on != ref_fitted || (t->bw_on && fabsf(logf(t->bw_m / rm)) > PFT_OWN_SCAN))
  {
    t->n_own = n_scan;
    memcpy(t->own_lo, t->pscan_lo, sizeof t->own_lo);
    memcpy(t->own_hi, t->pscan_hi, sizeof t->own_hi);
    if(!(t->own_scan = ft_grid3(n_scan, t->pscan_lo, t->pscan_hi, 0.0f, ^(const float *in, float *out, size_t cnt) {
         sf_sim_scan(s, in, out, cnt, 3, 3);
       })))
      return g_strdup("not enough memory");
  }
  return NULL;
}

static void ft_floats(FILE *f, const float *v, int n)
{
  fputc('[', f);
  for(int i = 0; i < n; i++) fprintf(f, i ? ",%.9g" : "%.9g", v[i]);
  fputc(']', f);
}

static void ft_doubles(FILE *f, const double *v, int n)
{
  fputc('[', f);
  for(int i = 0; i < n; i++) fprintf(f, i ? ",%.9g" : "%.9g", v[i]);
  fputc(']', f);
}

static void ftab_write_spatial(FILE *f, const sf_sim_t *s)
{
  double hs[3], hsig, core[3], tail[3], w[3], csize, ctail, cw;
  sf_sim_halation_params(s, hs, &hsig);
  sf_sim_scatter_params(s, core, tail, w);
  for(int c = 0; c < 3; c++)
  {
    core[c] = fmin(core[c], (double)SF_SCATTER_CORE_CLAMP_UM);
    tail[c] = fmin(tail[c], (double)SF_SCATTER_TAIL_CLAMP_UM);
  }
  sf_sim_coupler_diffusion(s, &csize, &ctail, &cw);
  fputs("{\"halation_strength\":", f); ft_doubles(f, hs, 3);
  fprintf(f, ",\"halation_first_sigma_um\":%.9g,\"scatter_core_um\":", fmin(hsig, (double)SF_HALATION_FIRST_SIGMA_UM));
  ft_doubles(f, core, 3);
  fputs(",\"scatter_tail_um\":", f); ft_doubles(f, tail, 3);
  fputs(",\"scatter_tail_weight\":", f); ft_doubles(f, w, 3);
  fprintf(f, ",\"coupler_core_um\":%.9g,\"coupler_tail_um\":%.9g,\"coupler_tail_weight\":%.9g", csize, ctail, cw);
  sf_grain_layers_t L;
  sf_sim_grain_layers(s, &L);
  float rms[3], unif[3], dmin[3], floor_c[3];
  sf_sim_film_grain3(s, rms, unif, dmin);
  sf_sim_grain_dmin_total(s, floor_c);
  fprintf(f, ",\"grain_mono\":%s,\"grain_sublayers\":%d", sf_sim_film_bw(s) ? "true" : "false", L.n);
  const char *names[] = { "grain_layer_dmax", "grain_layer_dmin", "grain_layer_particles_ref" };
  for(int k = 0; k < 3; k++)
  {
    fprintf(f, ",\"%s\":[", names[k]);
    for(int l = 0; l < L.n; l++)
    {
      if(l) fputc(',', f);
      ft_doubles(f, k == 0 ? L.layer_dmax[l] : k == 1 ? L.layer_dmin[l] : L.layer_npart[l], 3);
    }
    fputc(']', f);
  }
  fputs(",\"grain_uniformity\":", f); ft_floats(f, unif, 3);
  fputs(",\"grain_rms_catalogue\":", f); ft_floats(f, rms, 3);
  fputs(",\"grain_floor\":", f); ft_floats(f, floor_c, 3);
  fputs(",\"grain_total_curve\":[", f);
  for(int i = 0; i < SF_NLE; i++) { if(i) fputc(',', f); ft_floats(f, L.layer_curve_total[i], 3); }
  fputs("],\"grain_layer_curves\":[", f);
  for(int l = 0; l < L.n; l++)
  {
    fputs(l ? ",[" : "[", f);
    for(int i = 0; i < SF_NLE; i++) { if(i) fputc(',', f); ft_floats(f, L.layer_curve[i][l], 3); }
    fputc(']', f);
  }
  fputs("]}", f);
}

typedef struct ft_blob_t
{
  const char *name;
  const float *data;
  int half, rank, shape[4];
  const float *lo, *hi;
  uint8_t *packed;
  size_t raw_size, size, offset;
  int lzfse;
} ft_blob_t;

/* little-endian bytes, then LZFSE when it makes them smaller */
static int ft_pack(ft_blob_t *b)
{
  size_t count = 1;
  for(int r = 0; r < b->rank; r++) count *= b->shape[r];
  for(size_t k = 0; k < count; k++)
    if(!isfinite(b->data[k])) return 0;
  b->raw_size = count * (b->half ? 2 : 4);
  uint8_t *raw = malloc(b->raw_size), *packed = malloc(b->raw_size + 4096);
  if(!raw || !packed) { free(raw); free(packed); return 0; }
  for(size_t k = 0; k < count; k++)
  {
    if(b->half)
    {
      const uint16_t v = half_from(b->data[k]);
      raw[2 * k] = v & 0xff; raw[2 * k + 1] = v >> 8;
    }
    else
    {
      union { float f; uint32_t u; } v = { b->data[k] };
      for(int i = 0; i < 4; i++) raw[4 * k + i] = (v.u >> (8 * i)) & 0xff;
    }
  }
  /* the filter: each value minus the one before it in the same channel (as integers, modulo the
     width), then the bytes regrouped by significance; smooth tables pack about twice as small */
  const int es = b->half ? 2 : 4, ch = b->shape[b->rank - 1];
  uint8_t *flt = malloc(b->raw_size);
  if(!flt) { free(raw); free(packed); return 0; }
  for(size_t k = count; k-- > 0;)
  {
    uint32_t v = 0, prev = 0;
    for(int i = 0; i < es; i++) v |= (uint32_t)raw[k * es + i] << (8 * i);
    if(k >= (size_t)ch)
      for(int i = 0; i < es; i++) prev |= (uint32_t)raw[(k - ch) * es + i] << (8 * i);
    const uint32_t d = v - prev;
    for(int i = 0; i < es; i++) flt[i * count + k] = (d >> (8 * i)) & 0xff;
  }
  free(raw);
  raw = flt;
  const size_t n = compression_encode_buffer(packed, b->raw_size + 4096, raw, b->raw_size, NULL, COMPRESSION_LZFSE);
  if(n > 0 && n < b->raw_size) { b->packed = packed; b->size = n; b->lzfse = 1; free(raw); }
  else { b->packed = raw; b->size = b->raw_size; b->lzfse = 0; free(packed); }
  return 1;
}

/* One .pft: `head` is the header's JSON object so far, without its closing brace. */
/* a number in the header that isn't finite (printed as nan or inf, never inside a string) */
static int ft_head_finite(const char *head)
{
  int quoted = 0;
  for(const char *p = head; *p; p++)
  {
    if(*p == '\\' && quoted && p[1]) { p++; continue; }
    if(*p == '"') quoted = !quoted;
    else if(!quoted && (*p == 'n' || *p == 'i') && (!strncmp(p, "nan", 3) || !strncmp(p, "inf", 3))) return 0;
  }
  return 1;
}

static char *ft_write_file(const char *path, const char *head, ft_blob_t *blobs, int nblobs)
{
  if(!ft_head_finite(head)) return g_strdup("the film's numbers aren't finite");
  char *err = NULL;
  size_t at = 0;
  for(int b = 0; b < nblobs; b++)
  {
    if(!blobs[b].data) continue;
    if(!ft_pack(&blobs[b]))
    {
      char message[256];
      snprintf(message, sizeof message, "the film's %s table isn't finite", blobs[b].name);
      err = g_strdup(message);
      break;
    }
    blobs[b].offset = at;
    at = (at + blobs[b].size + 15) & ~(size_t)15;
  }
  char *json = NULL;
  size_t json_len = 0;
  FILE *h = err ? NULL : open_memstream(&json, &json_len);
  if(h)
  {
    fputs(head, h);
    fputs(",\"blobs\":{", h);
    for(int b = 0, first = 1; b < nblobs; b++)
    {
      if(!blobs[b].data) continue;
      fprintf(h, "%s\"%s\":{\"offset\":%zu,\"size\":%zu,\"raw_size\":%zu,\"codec\":\"%s\",\"filter\":\"delta_shuffle\",\"dtype\":\"%s\",\"shape\":[", first ? "" : ",",
              blobs[b].name, blobs[b].offset, blobs[b].size, blobs[b].raw_size, blobs[b].lzfse ? "lzfse" : "none",
              blobs[b].half ? "f16" : "f32");
      first = 0;
      for(int r = 0; r < blobs[b].rank; r++) fprintf(h, r ? ",%d" : "%d", blobs[b].shape[r]);
      fputc(']', h);
      if(blobs[b].lo) { fputs(",\"lo\":", h); ft_floats(h, blobs[b].lo, 3); fputs(",\"hi\":", h); ft_floats(h, blobs[b].hi, 3); }
      fputc('}', h);
    }
    fputs("}}", h);
    while((8 + ftell(h)) % 16) fputc(' ', h);
    fclose(h);
  }
  else if(!err) err = g_strdup("not enough memory");

  if(!err)
  {
    char tmp[2048];
    snprintf(tmp, sizeof tmp, "%s.part", path);
    FILE *f = fopen(tmp, "wb");
    int ok = f != NULL;
    if(f)
    {
      const uint32_t len = (uint32_t)json_len;
      const uint8_t len_le[4] = { len & 0xff, (len >> 8) & 0xff, (len >> 16) & 0xff, len >> 24 };
      ok = fwrite("PFT1", 1, 4, f) == 4 && fwrite(len_le, 1, 4, f) == 4 && fwrite(json, 1, json_len, f) == json_len;
      size_t pos = 0;
      static const uint8_t zeros[16] = { 0 };
      for(int b = 0; b < nblobs && ok; b++)
      {
        if(!blobs[b].data) continue;
        ok = fwrite(zeros, 1, blobs[b].offset - pos, f) == blobs[b].offset - pos
             && fwrite(blobs[b].packed, 1, blobs[b].size, f) == blobs[b].size;
        pos = blobs[b].offset + blobs[b].size;
      }
      if(fclose(f) != 0) ok = 0;
    }
    if(!ok || rename(tmp, path) != 0) { unlink(tmp); err = g_strdup("the tables couldn't be written"); }
  }
  free(json);
  for(int b = 0; b < nblobs; b++) free(blobs[b].packed);
  return err;
}

static char *ftab_write_film(const ftab_t *t, const sf_sim_t *s, const char *path)
{
  char *head = NULL;
  size_t len = 0;
  FILE *h = open_memstream(&head, &len);
  if(!h) return g_strdup("not enough memory");
  fputs("{\"part\":\"film\",\"film\":", h); json_string(h, t->film);
  fprintf(h, ",\"bw\":%s,\"constants\":{\"expose_m\":", t->bw ? "true" : "false");
  ft_floats(h, t->expose_m, 9);
  fprintf(h, ",\"ev_scale0\":%.9g,\"le0\":%.9g,\"le_step\":%.9g,\"couplers\":%s,\"coupler_m\":", t->ev_scale0, t->le0, t->le_step,
          t->couplers ? "true" : "false");
  ft_floats(h, t->coupler_m, 9);
  if(t->has_scan) fprintf(h, ",\"scan_ev_scale0\":%.9g", t->scan_ev_scale0); else fputs(",\"scan_ev_scale0\":null", h);
  fputs("},\"spatial\":", h);
  ftab_write_spatial(h, s);
  fclose(h);
  ft_blob_t blobs[] = {
    { "expose_q", t->expose_q, t->xy_half, 3, { PFT_XY, PFT_XY, 3 } },
    { "silver", t->silver, 0, 2, { PFT_NLE, 3 } },
    { "receive", t->receive, 0, 2, { PFT_RECV, 3 }, t->recv_lo, t->recv_hi },
    { "curves", t->curves, 0, 2, { PFT_NLE, 3 } },
    { "scan", t->scan, 1, 4, { t->n_scan, t->n_scan, t->n_scan, 3 }, t->scan_lo, t->scan_hi },
  };
  char *err = ft_write_file(path, head, blobs, sizeof blobs / sizeof blobs[0]);
  free(head);
  return err;
}

static char *ftab_write_paper(const ftab_t *t, const char *path)
{
  char *head = NULL;
  size_t len = 0;
  FILE *h = open_memstream(&head, &len);
  if(!h) return g_strdup("not enough memory");
  fputs("{\"part\":\"paper\",\"paper\":", h); json_string(h, t->paper);
  fprintf(h, ",\"constants\":{\"print_le0\":%.9g,\"print_le_step\":%.9g,\"scan_ref_m\":%.9g,\"scan_ref_q\":%.9g}", t->print_le0,
          t->print_le_step, t->ref_m, t->ref_q);
  fclose(h);
  ft_blob_t blobs[] = {
    { "print_curves", t->print_curves, 0, 2, { PFT_NLE, 3 } },
    { "scan", t->pscan, 1, 4, { t->n_pscan, t->n_pscan, t->n_pscan, 3 }, t->pscan_lo, t->pscan_hi },
    { "scan_y", t->pscan_y, 1, 4, { t->n_pscan, t->n_pscan, t->n_pscan, 1 }, t->pscan_lo, t->pscan_hi },
    { "scan_dlog", t->pscan_dlog, 1, 4, { t->n_dlog, t->n_dlog, t->n_dlog, 3 }, t->pscan_lo, t->pscan_hi },
  };
  char *err = ft_write_file(path, head, blobs, sizeof blobs / sizeof blobs[0]);
  free(head);
  return err;
}

static char *ftab_write_pair(const ftab_t *t, const char *path)
{
  char *head = NULL;
  size_t len = 0;
  FILE *h = open_memstream(&head, &len);
  if(!h) return g_strdup("not enough memory");
  fputs("{\"part\":\"pair\",\"film\":", h); json_string(h, t->film);
  fputs(",\"paper\":", h); json_string(h, t->paper);
  fprintf(h, ",\"constants\":{\"print_log_offset0\":%.9g,\"scan_bw\":%s,\"scan_bw_m\":%.9g,\"scan_bw_q\":%.9g", t->print_log_offset0,
          t->bw_on ? "true" : "false", t->bw_m, t->bw_q);
  if(t->baked) fprintf(h, ",\"baked_exposure_ev\":%.9g}", t->baked_ev); else fputs(",\"baked_exposure_ev\":null}", h);
  fclose(h);
  ft_blob_t blobs[] = {
    { "print_expose", t->print_expose, 1, 4, { t->n, t->n, t->n, 3 }, t->pe_lo, t->pe_hi },
    { "scan", t->own_scan, 1, 4, { t->n_own, t->n_own, t->n_own, 3 }, t->own_lo, t->own_hi },
  };
  char *err = ft_write_file(path, head, blobs, 2);
  free(head);
  return err;
}

/* ---- reading back (checktables) */

typedef struct ft_file_t { uint8_t *file; size_t size; const uint8_t *data; size_t dsize; JsonParser *parser; JsonObject *head, *blobs; } ft_file_t;

static void ft_close(ft_file_t *f)
{
  if(f->parser) g_object_unref(f->parser);
  free(f->file);
  memset(f, 0, sizeof *f);
}

static char *ft_open(const char *path, const char *part, ft_file_t *out)
{
  memset(out, 0, sizeof *out);
  FILE *f = path ? fopen(path, "rb") : NULL;
  if(!f) return g_strdup("the tables aren't there");
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  uint8_t *file = size > 8 ? malloc((size_t)size) : NULL;
  const int read_ok = file && fread(file, 1, (size_t)size, f) == (size_t)size;
  fclose(f);
  if(!read_ok || memcmp(file, "PFT1", 4)) { free(file); return g_strdup("these aren't film tables"); }
  const uint32_t hlen = (uint32_t)file[4] | ((uint32_t)file[5] << 8) | ((uint32_t)file[6] << 16) | ((uint32_t)file[7] << 24);
  if((size_t)hlen > (size_t)size - 8) { free(file); return g_strdup("the tables are cut short"); }
  out->file = file;
  out->size = (size_t)size;
  out->data = file + 8 + hlen;
  out->dsize = (size_t)size - 8 - hlen;
  /* the shim parses files: the header goes through one */
  char tmpl[] = "/tmp/pluck-spektra-pft-XXXXXX";
  const int fd = mkstemp(tmpl);
  const int written = fd >= 0 && write(fd, file + 8, hlen) == (ssize_t)hlen;
  if(fd >= 0) close(fd);
  out->parser = json_parser_new();
  const int parsed = written && json_parser_load_from_file(out->parser, tmpl, NULL);
  if(fd >= 0) unlink(tmpl);
  out->head = parsed ? json_node_get_object(json_parser_get_root(out->parser)) : NULL;
  out->blobs = out->head && json_object_has_member(out->head, "blobs") ? json_object_get_object_member(out->head, "blobs") : NULL;
  const char *p = out->head ? json_object_get_string_member(out->head, "part") : NULL;
  if(!out->blobs || !p) { ft_close(out); return g_strdup("the tables' header can't be read"); }
  if(strcmp(p, part)) { ft_close(out); return g_strdup("these tables are another part"); }
  return NULL;
}

/* a 3D blob's nodes per axis, 0 when it isn't there */
static int ft_blob_n(JsonObject *blobs, const char *name)
{
  JsonObject *b = json_object_has_member(blobs, name) ? json_object_get_object_member(blobs, name) : NULL;
  JsonArray *sh = b ? json_object_get_array_member(b, "shape") : NULL;
  return sh && json_array_get_length(sh) == 4 ? (int)json_array_get_double_element(sh, 0) : 0;
}

/* one blob as floats, checked against the shape the recipe needs */
static float *ft_blob(const ft_file_t *f, const char *name, const int *shape, int rank, float lo[3], float hi[3])
{
  JsonObject *b = json_object_has_member(f->blobs, name) ? json_object_get_object_member(f->blobs, name) : NULL;
  if(!b) return NULL;
  JsonArray *sh = json_object_get_array_member(b, "shape");
  if(!sh || (int)json_array_get_length(sh) != rank) return NULL;
  size_t count = 1;
  for(int r = 0; r < rank; r++)
  {
    const double e = json_array_get_double_element(sh, r);
    if(shape[r] < 1 || shape[r] > 4096 || e != (double)shape[r]) return NULL;
    count *= (size_t)shape[r];
    if(count > ((size_t)1 << 28)) return NULL;
  }
  const char *dtype = json_object_get_string_member(b, "dtype"), *codec = json_object_get_string_member(b, "codec");
  const int half = dtype && !strcmp(dtype, "f16");
  if(!half && !(dtype && !strcmp(dtype, "f32"))) return NULL;
  const int lzfse = codec && !strcmp(codec, "lzfse");
  if(!lzfse && !(codec && !strcmp(codec, "none"))) return NULL;
  const double offset = json_object_get_double_member(b, "offset"), size = json_object_get_double_member(b, "size");
  const double raw = json_object_get_double_member(b, "raw_size");
  const size_t raw_size = count * (half ? 2 : 4);
  /* whole numbers, inside the file */
  if(!(offset >= 0 && size >= 0 && offset == floor(offset) && size == floor(size)) || offset > (double)f->dsize
     || size > (double)f->dsize - offset)
    return NULL;
  if(raw != (double)raw_size || (!lzfse && (size_t)size != raw_size)) return NULL;
  if(lo)
  {
    JsonArray *l = json_object_get_array_member(b, "lo"), *u = json_object_get_array_member(b, "hi");
    if(!l || !u || json_array_get_length(l) != 3 || json_array_get_length(u) != 3) return NULL;
    for(int c = 0; c < 3; c++)
    {
      lo[c] = (float)json_array_get_double_element(l, c);
      hi[c] = (float)json_array_get_double_element(u, c);
      if(!isfinite(lo[c]) || !isfinite(hi[c]) || !(hi[c] > lo[c])) return NULL;
    }
  }
  uint8_t *bytes = malloc(raw_size);
  float *v = malloc(count * sizeof(float));
  int ok = bytes && v;
  if(ok && lzfse) ok = compression_decode_buffer(bytes, raw_size, f->data + (size_t)offset, (size_t)size, NULL, COMPRESSION_LZFSE) == raw_size;
  else if(ok) memcpy(bytes, f->data + (size_t)offset, raw_size);
  const char *filter = json_object_get_string_member(b, "filter");
  const int shuffled = filter && !strcmp(filter, "delta_shuffle");
  if(filter && !shuffled && strcmp(filter, "none")) ok = 0;
  const int es = half ? 2 : 4, ch = shape[rank - 1];
  uint32_t *bits = ok ? malloc(count * sizeof(uint32_t)) : NULL;
  if(!bits) ok = 0;
  for(size_t k = 0; ok && k < count; k++)
  {
    uint32_t w = 0;
    for(int i = 0; i < es; i++) w |= (uint32_t)(shuffled ? bytes[i * count + k] : bytes[k * es + i]) << (8 * i);
    if(shuffled && k >= (size_t)ch) w += bits[k - ch];
    bits[k] = half ? (w & 0xffffu) : w;
  }
  for(size_t k = 0; ok && k < count; k++)
  {
    if(half) v[k] = half_to((uint16_t)bits[k]);
    else
    {
      union { float f; uint32_t u; } x = { .u = bits[k] };
      v[k] = x.f;
    }
  }
  free(bits);
  free(bytes);
  if(!ok) { free(v); return NULL; }
  return v;
}

static int ft_read_floats(JsonObject *o, const char *name, float *out, int n)
{
  JsonArray *a = json_object_has_member(o, name) ? json_object_get_array_member(o, name) : NULL;
  if(!a || (int)json_array_get_length(a) != n) return 0;
  for(int i = 0; i < n; i++) out[i] = (float)json_array_get_double_element(a, i);
  return 1;
}

static JsonObject *ft_constants(const ft_file_t *f)
{
  return json_object_has_member(f->head, "constants") ? json_object_get_object_member(f->head, "constants") : NULL;
}

static char *ftab_read_film(const char *path, ftab_t *t)
{
  ft_file_t f;
  char *err = ft_open(path, "film", &f);
  if(err) return err;
  JsonObject *k = ft_constants(&f);
  const char *film = json_object_get_string_member(f.head, "film");
  g_strlcpy(t->film, film ? film : "", sizeof t->film);
  t->bw = json_object_get_boolean_member(f.head, "bw");
  t->n_scan = ft_blob_n(f.blobs, "scan");
  t->has_scan = t->n_scan >= 2;
  const int sxy[] = { PFT_XY, PFT_XY, 3 }, sle[] = { PFT_NLE, 3 }, srecv[] = { PFT_RECV, 3 };
  const int s3[] = { t->n_scan, t->n_scan, t->n_scan, 3 };
  if(!k || !ft_read_floats(k, "expose_m", t->expose_m, 9) || !ft_read_floats(k, "coupler_m", t->coupler_m, 9)
     || !(t->expose_q = ft_blob(&f, "expose_q", sxy, 3, NULL, NULL)) || !(t->silver = ft_blob(&f, "silver", sle, 2, NULL, NULL))
     || !(t->receive = ft_blob(&f, "receive", srecv, 2, t->recv_lo, t->recv_hi))
     || !(t->curves = ft_blob(&f, "curves", sle, 2, NULL, NULL))
     || (t->has_scan && !(t->scan = ft_blob(&f, "scan", s3, 4, t->scan_lo, t->scan_hi))))
    err = g_strdup("the film's tables are damaged");
  else
  {
    t->couplers = json_object_get_boolean_member(k, "couplers");
    t->ev_scale0 = (float)json_object_get_double_member(k, "ev_scale0");
    t->scan_ev_scale0 = (float)json_object_get_double_member(k, "scan_ev_scale0");
    t->le0 = (float)json_object_get_double_member(k, "le0");
    t->le_step = (float)json_object_get_double_member(k, "le_step");
  }
  ft_close(&f);
  return err;
}

static char *ftab_read_paper(const char *path, ftab_t *t)
{
  ft_file_t f;
  char *err = ft_open(path, "paper", &f);
  if(err) return err;
  JsonObject *k = ft_constants(&f);
  const char *paper = json_object_get_string_member(f.head, "paper");
  g_strlcpy(t->paper, paper ? paper : "", sizeof t->paper);
  t->n_pscan = ft_blob_n(f.blobs, "scan");
  t->n_dlog = ft_blob_n(f.blobs, "scan_dlog");
  float ylo[3], yhi[3];
  const int sle[] = { PFT_NLE, 3 }, s3[] = { t->n_pscan, t->n_pscan, t->n_pscan, 3 }, s1[] = { t->n_pscan, t->n_pscan, t->n_pscan, 1 };
  const int sd[] = { t->n_dlog, t->n_dlog, t->n_dlog, 3 };
  if(!k || t->n_pscan < 2 || t->n_dlog < 2 || !(t->print_curves = ft_blob(&f, "print_curves", sle, 2, NULL, NULL))
     || !(t->pscan = ft_blob(&f, "scan", s3, 4, t->pscan_lo, t->pscan_hi)) || !(t->pscan_y = ft_blob(&f, "scan_y", s1, 4, ylo, yhi))
     || !(t->pscan_dlog = ft_blob(&f, "scan_dlog", sd, 4, ylo, yhi)))
    err = g_strdup("the paper's tables are damaged");
  else
  {
    t->print_le0 = (float)json_object_get_double_member(k, "print_le0");
    t->print_le_step = (float)json_object_get_double_member(k, "print_le_step");
    t->ref_m = (float)json_object_get_double_member(k, "scan_ref_m");
    t->ref_q = (float)json_object_get_double_member(k, "scan_ref_q");
  }
  ft_close(&f);
  return err;
}

static char *ftab_read_pair(const char *path, ftab_t *t)
{
  ft_file_t f;
  char *err = ft_open(path, "pair", &f);
  if(err) return err;
  JsonObject *k = ft_constants(&f);
  t->n = ft_blob_n(f.blobs, "print_expose");
  const int s3[] = { t->n, t->n, t->n, 3 };
  const int n_own = ft_blob_n(f.blobs, "scan"), so[] = { n_own, n_own, n_own, 3 };
  float olo[3], ohi[3];
  if(!k || t->n < 2 || !(t->print_expose = ft_blob(&f, "print_expose", s3, 4, t->pe_lo, t->pe_hi))
     || (n_own && !(t->own_scan = ft_blob(&f, "scan", so, 4, olo, ohi))))
    err = g_strdup("the pair's tables are damaged");
  else
  {
    if(n_own) { t->n_own = n_own; memcpy(t->own_lo, olo, sizeof olo); memcpy(t->own_hi, ohi, sizeof ohi); }
    t->print_log_offset0 = (float)json_object_get_double_member(k, "print_log_offset0");
    t->bw_on = json_object_get_boolean_member(k, "scan_bw");
    t->bw_m = (float)json_object_get_double_member(k, "scan_bw_m");
    t->bw_q = (float)json_object_get_double_member(k, "scan_bw_q");
    JsonNode *be = json_object_has_member(k, "baked_exposure_ev") ? json_object_get_member(k, "baked_exposure_ev") : NULL;
    t->baked = be && !json_node_is_null(be);
    t->baked_ev = t->baked ? (float)json_node_get_double(be) : 0.0f;
    const char *pf = json_object_get_string_member(f.head, "film"), *pp = json_object_get_string_member(f.head, "paper");
    g_strlcpy(t->pair_film, pf ? pf : "", sizeof t->pair_film);
    g_strlcpy(t->pair_paper, pp ? pp : "", sizeof t->pair_paper);
  }
  ft_close(&f);
  return err;
}

/* the job's settings, with a film shown without a print scanned directly */
static const char *ft_params(JsonObject *job, params_t *p)
{
  params_from(p, json_object_has_member(job, "set") ? json_object_get_object_member(job, "set") : NULL);
  JsonNode *pn = json_object_has_member(job, "print") ? json_object_get_member(job, "print") : NULL;
  const char *paper = pn && !json_node_is_null(pn) ? json_node_get_string(pn) : NULL;
  if(!paper || !*paper) { p->v[setting_index("scan_film")] = 1.0f; paper = NULL; }
  return P(p, "scan_film") > 0.5f ? NULL : paper;
}


static int ft_int(JsonObject *job, const char *name, int def)
{
  return json_object_has_member(job, name) ? (int)json_object_get_int_member(job, name) : def;
}

/* {"do":"tables","part":"film"|"paper"|"pair",...}: one part, from the job's settings. The
   exposures act in Pluck's recipe, not in the tables; only auto print exposure ties the enlarger
   to the camera exposure, and then a pair holds for that exposure_ev alone. */
static void tables_job(JsonObject *job)
{
  const char *dir = json_object_get_string_member(job, "pack"), *film = json_object_get_string_member(job, "film");
  const char *output = json_object_get_string_member(job, "output"), *part = json_object_get_string_member(job, "part");
  if(!dir || !film || !output || !part) { answer_error("incomplete job"); return; }
  const int is_film = !strcmp(part, "film"), is_paper = !strcmp(part, "paper"), is_pair = !strcmp(part, "pair");
  if(!is_film && !is_paper && !is_pair) { answer_error("unknown part"); return; }
  params_t p;
  params_from(&p, json_object_has_member(job, "set") ? json_object_get_object_member(job, "set") : NULL);
  JsonNode *pn = json_object_has_member(job, "print") ? json_object_get_member(job, "print") : NULL;
  const char *paper = pn && !json_node_is_null(pn) ? json_node_get_string(pn) : NULL;
  if(paper && !*paper) paper = NULL;
  const int scan_film = P(&p, "scan_film") > 0.5f;
  const int n = ft_int(job, "n", PFT_N), n_scan = ft_int(job, "n_scan", is_paper ? PFT_N_PAPER : PFT_N_SCAN);
  const int n_dlog = ft_int(job, "n_dlog", PFT_N_DLOG);
  if(n < 2 || n > 129 || n_scan < 2 || n_scan > 129 || n_dlog < 2 || n_dlog > 129) { answer_error("n is out of range"); return; }
  if((is_paper || is_pair) && !paper) { answer_error("this part needs a print"); return; }

  params_t b = p;
  const int baked = is_pair && P(&p, "print_auto_exposure") > 0.5f;
  b.v[setting_index("print_exposure_ev")] = 0.0f;
  if(!baked) b.v[setting_index("exposure_ev")] = 0.0f;
  /* the film part comes from a sim without a print, and holds the scan of the film (no print
     given, or scan_film on); given a print and scan_film off, from that print's sim instead,
     with no scan: the film tables are the same either way */
  const int film_printed = is_film && paper && !scan_film;
  b.v[setting_index("scan_film")] = (is_film && !film_printed) ? 1.0f : 0.0f;
  char *err = build_sim(dir, film, (is_film && !film_printed) ? NULL : paper, &b);
  if(err) { answer_error(err); free(err); return; }
  ftab_t t;
  memset(&t, 0, sizeof t);
  g_strlcpy(t.film, film, sizeof t.film);
  g_strlcpy(t.paper, paper ? paper : "", sizeof t.paper);
  if(is_film)
  {
    err = ftab_make_film(sim, &b, scan_film || !paper, n_scan, json_object_get_boolean_member(job, "expose_f16"), &t);
    if(!err) err = ftab_write_film(&t, sim, output);
  }
  else if(is_paper)
  {
    char *type = ft_paper_type(dir, paper);
    err = ftab_make_paper(sim, type, n_scan, n_dlog, &t);
    free(type);
    if(!err) err = ftab_write_paper(&t, output);
  }
  else
  {
    t.baked = baked;
    t.baked_ev = P(&b, "exposure_ev");
    char *type = ft_paper_type(dir, paper);
    err = ftab_make_pair(sim, type, n, ft_int(job, "n_scan", PFT_N_OWN), baked || json_object_get_boolean_member(job, "own_scan"), &t);
    free(type);
    if(!err) err = ftab_write_pair(&t, output);
  }
  ftab_free(&t);
  if(err) { answer_error(err); free(err); return; }
  fputs("{\"ok\":true}\n", stdout);
}

static inline float ft_random(uint32_t *state)
{
  *state ^= *state << 13; *state ^= *state >> 17; *state ^= *state << 5;
  return (float)(*state >> 8) / 16777216.0f;
}

/* The tables through the recipe against the sim's own per-pixel chain (no spatial effects), on
   scene pixels from 8 stops under to 6 over a mid grey: greys, colours, and some outside sRGB.
   "tables": {"film":path, "paper":path, "pair":path}; a film without a print needs only "film". */
static void checktables_job(JsonObject *job)
{
  const char *dir = json_object_get_string_member(job, "pack"), *film = json_object_get_string_member(job, "film");
  JsonObject *paths = json_object_has_member(job, "tables") ? json_object_get_object_member(job, "tables") : NULL;
  if(!dir || !film || !paths) { answer_error("incomplete job"); return; }
  params_t p;
  const char *paper = ft_params(job, &p);
  const int scanned = !paper;
  ftab_t t;
  memset(&t, 0, sizeof t);
  char *err = ftab_read_film(json_object_get_string_member(paths, "film"), &t);
  if(!err && scanned && !t.has_scan) err = g_strdup("these film tables have no scan of the film");
  if(!err && !scanned) err = ftab_read_paper(json_object_get_string_member(paths, "paper"), &t);
  if(!err && !scanned) err = ftab_read_pair(json_object_get_string_member(paths, "pair"), &t);
  /* the tables must be the ones this job describes */
  if(!err && strcmp(t.film, film)) err = g_strdup("these film tables are for another film");
  if(!err && !scanned && strcmp(t.paper, paper)) err = g_strdup("these paper tables are for another paper");
  if(!err && !scanned && (strcmp(t.pair_film, film) || strcmp(t.pair_paper, paper))) err = g_strdup("these pair tables are for another pair");
  if(!err && !scanned && (t.baked != (P(&p, "print_auto_exposure") > 0.5f) || (t.baked && t.baked_ev != P(&p, "exposure_ev"))))
    err = g_strdup("these pair tables are for another exposure");
  if(!err) err = build_sim(dir, film, paper, &p);
  if(err) { ftab_free(&t); answer_error(err); free(err); return; }
  const size_t npix = json_object_has_member(job, "samples") ? (size_t)MAX(json_object_get_int_member(job, "samples"), 1) : 20000;
  float *in = malloc(npix * 3 * sizeof(float)), *ref = malloc(npix * 3 * sizeof(float)), *corr = malloc(npix * 3 * sizeof(float));
  if(!in || !ref || !corr) { free(in); free(ref); free(corr); ftab_free(&t); answer_error("not enough memory"); return; }
  uint32_t state = 0x9e3779b9u;
  for(size_t k = 0; k < npix; k++)
  {
    const float kind = ft_random(&state), stops = -8.0f + 14.0f * ft_random(&state);
    float c[3];
    for(int i = 0; i < 3; i++)
    {
      const float r = ft_random(&state);
      c[i] = kind < 0.1f ? 1.0f : kind < 0.9f ? powf(r, 1.5f) : 1.1f * r - 0.1f;
    }
    float y = 0.2126f * c[0] + 0.7152f * c[1] + 0.0722f * c[2];
    if(y < 0.02f) { c[0] = c[1] = c[2] = 1.0f; y = 1.0f; }
    for(int i = 0; i < 3; i++) in[k * 3 + i] = c[i] / y * 0.18f * exp2f(stops);
  }
  const sf_sim_t *s = sim;
  const int couplers = P(&p, "couplers_amount") > 0.0f;
  strips(npix, ^(size_t a, size_t n) {
    float *pl = ref + a * 3, *cr = corr + a * 3;
    sf_sim_expose(s, in + a * 3, pl, n, 3, 3);
    sf_sim_lograw(pl, n, 3);
    if(couplers) sf_sim_develop_corr(s, pl, cr, n, 3);
    sf_sim_develop(s, pl, couplers ? cr : NULL, pl, n, 3, 3);
    if(!scanned)
    {
      sf_sim_print_expose(s, pl, pl, n, 3, 3);
      sf_sim_print_develop(s, pl, pl, n, 3, 3);
    }
    sf_sim_scan(s, pl, pl, n, 3, 3);
  });
  const float ev = P(&p, "exposure_ev"), pev = P(&p, "print_exposure_ev");
  double sum = 0.0, worst = 0.0;
  size_t counted = 0, wk = 0;
  for(size_t k = 0; k < npix; k++)
  {
    float out[3];
    ftab_pixel(&t, in + k * 3, ev, pev, scanned, out);
    for(int c = 0; c < 3; c++)
    {
      if(!isfinite(ref[k * 3 + c])) continue;
      const double e = isfinite(out[c]) ? fabs((double)out[c] - ref[k * 3 + c]) : 1e30;
      sum += e;
      if(e > worst) { worst = e; wk = k; }
      counted++;
    }
  }
  if(getenv("PLUCK_SPEKTRA_DETAIL"))
  {
    /* the worst pixel, stage by stage, on stderr */
    float a[3], le[3], d[3], cr[3], o[3], tle[3], td[3];
    sf_sim_expose(s, in + wk * 3, a, 1, 3, 3);
    sf_sim_lograw(a, 1, 3);
    memcpy(le, a, sizeof le);
    if(couplers) sf_sim_develop_corr(s, a, cr, 1, 3);
    sf_sim_develop(s, a, couplers ? cr : NULL, d, 1, 3, 3);
    ftab_pixel_le(&t, in + wk * 3, ev, pev, scanned, o, tle, td);
    fprintf(stderr, "worst %g at rgb %g %g %g\n sim le %g %g %g d %g %g %g\n", worst, in[wk * 3], in[wk * 3 + 1], in[wk * 3 + 2],
            le[0], le[1], le[2], d[0], d[1], d[2]);
    fprintf(stderr, " tables le %g %g %g d %g %g %g\n", tle[0], tle[1], tle[2], td[0], td[1], td[2]);
    fprintf(stderr, " sim out %g %g %g  tables out %g %g %g\n", ref[wk * 3], ref[wk * 3 + 1], ref[wk * 3 + 2], o[0], o[1], o[2]);
    sf_sim_gpu_t *g = sf_sim_gpu_export(s);
    if(g)
    {
      float xyz[3], e1[3], e2[3];
      const float *rgb = in + wk * 3;
      for(int i = 0; i < 3; i++) xyz[i] = g->m_in[i * 3] * rgb[0] + g->m_in[i * 3 + 1] * rgb[1] + g->m_in[i * 3 + 2] * rgb[2];
      const float b = xyz[0] + xyz[1] + xyz[2], cx = xyz[0] / b, cy = xyz[1] / b;
      const float qx = CLAMP((1.0f - cx) * (1.0f - cx), 0.0f, 1.0f), qy = CLAMP(cy / fmaxf(1.0f - cx, 1e-10f), 0.0f, 1.0f);
      ft_expose_at(g, qx, qy, e1);
      ft_lin2(t.expose_q, PFT_XY, fminf(fabsf(1.0f - cx), 1.0f) * (PFT_XY - 1), qy * (PFT_XY - 1), e2);
      fprintf(stderr, " b %g xy %g %g q %g %g exact %g %g %g table %g %g %g ev_scale sim %g tables %g/%g\n", b, cx, cy, qx, qy, e1[0], e1[1], e1[2], e2[0], e2[1], e2[2], g->ev_scale, t.ev_scale0, t.scan_ev_scale0);
      sf_sim_gpu_free(g);
    }
    if(!scanned)
    {
      float spe[3], spd[3], tpe[3], tpd[3], srgb[3], trgb[3];
      sf_sim_print_expose(s, d, spe, 1, 3, 3);
      sf_sim_print_develop(s, spe, spd, 1, 3, 3);
      ft_lin3(t.print_expose, t.n, t.pe_lo, t.pe_hi, td, tpe);
      for(int c = 0; c < 3; c++)
      {
        tpe[c] += t.print_log_offset0 + pev * 0.30103f;
        tpd[c] = ft_lin1(t.print_curves, PFT_NLE, (tpe[c] - t.print_le0) / t.print_le_step, c);
      }
      sf_sim_scan(s, spd, srgb, 1, 3, 3);
      ft_lin3(t.pscan, t.n_pscan, t.pscan_lo, t.pscan_hi, spd, trgb);
      fprintf(stderr, " pe sim %g %g %g tables %g %g %g\n pd sim %g %g %g tables %g %g %g\n scan(sim pd) sim %g %g %g paper table %g %g %g\n",
              spe[0], spe[1], spe[2], tpe[0], tpe[1], tpe[2], spd[0], spd[1], spd[2], tpd[0], tpd[1], tpd[2], srgb[0], srgb[1], srgb[2], trgb[0], trgb[1], trgb[2]);
    }
  }
  free(in); free(ref); free(corr);
  ftab_free(&t);
  fprintf(stdout, "{\"max_error\":%.9g,\"mean_error\":%.9g}\n", worst, counted ? sum / counted : 0.0);
}

int main(void)
{
  char *line = NULL;
  size_t cap = 0;
  ssize_t len;
  while((len = getline(&line, &cap, stdin)) > 0)
  {
    JsonParser *parser = json_parser_new();
    char tmpl[] = "/tmp/pluck-spektra-job-XXXXXX";
    /* the shim parses files: the line goes through one */
    const int fd = mkstemp(tmpl);
    if(fd >= 0) { write(fd, line, (size_t)len); close(fd); }
    if(fd < 0 || !json_parser_load_from_file(parser, tmpl, NULL)) answer_error("not a job");
    else
    {
      JsonObject *job = json_node_get_object(json_parser_get_root(parser));
      const char *what = json_object_get_string_member(job, "do");
      if(!what) answer_error("not a job");
      else if(!strcmp(what, "profiles")) profiles(json_object_get_string_member(job, "pack"));
      else if(!strcmp(what, "schema")) schema();
      else if(!strcmp(what, "render")) render_job(job);
      else if(!strcmp(what, "tables")) tables_job(job);
      else if(!strcmp(what, "checktables")) checktables_job(job);
      else answer_error("unknown job");
    }
    if(fd >= 0) unlink(tmpl);
    g_object_unref(parser);
    fflush(stdout);
  }
  free(line);
  return 0;
}
