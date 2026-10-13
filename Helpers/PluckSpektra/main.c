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
    Images are raw float32 RGBA, linear sRGB, row by row from the top.
*/
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
      else answer_error("unknown job");
    }
    if(fd >= 0) unlink(tmpl);
    g_object_unref(parser);
    fflush(stdout);
  }
  free(line);
  return 0;
}
