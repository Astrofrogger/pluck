/* pluck-spektra: implementations behind the GLib / json-glib / darktable shim.
   Copyright (C) 2026. GPL-3.0-or-later.

   The two Gaussian helpers at the end are darktable's own (src/common/gaussian.c,
   Copyright (C) darktable developers, GPL-3.0-or-later), copied unchanged. */
#include <glib.h>
#include <json-glib/json-glib.h>
#include <math.h>
#include <ctype.h>

/* ------------------------------------------------------------------ glib -- */

void g_free(void *p) { free(p); }
void *g_malloc0(size_t n) { return calloc(1, n ? n : 1); }
char *g_strdup(const char *s) { return s ? strdup(s) : NULL; }
size_t g_strlcpy(char *dst, const char *src, size_t size) { return strlcpy(dst, src ? src : "", size); }

char *g_strdup_vprintf(const char *format, va_list args)
{
  char *out = NULL;
  if(vasprintf(&out, format, args) < 0) return NULL;
  return out;
}

char *g_build_filename(const char *first, ...)
{
  size_t cap = 256, len = 0;
  char *out = malloc(cap);
  out[0] = 0;
  va_list ap;
  va_start(ap, first);
  for(const char *part = first; part; part = va_arg(ap, const char *))
  {
    size_t n = strlen(part);
    if(len + n + 2 > cap) { cap = (len + n + 2) * 2; out = realloc(out, cap); }
    if(len > 0 && out[len - 1] != '/') out[len++] = '/';
    while(len > 0 && *part == '/') part++, n--;
    memcpy(out + len, part, n);
    len += n;
    out[len] = 0;
  }
  va_end(ap);
  return out;
}

guint64 g_ascii_strtoull(const char *nptr, char **endptr, guint base) { return strtoull(nptr, endptr, (int)base); }

void g_clear_error(GError **error)
{
  if(error && *error) { free((*error)->message); free(*error); *error = NULL; }
}

void g_list_free(GList *list)
{
  while(list) { GList *next = list->next; free(list); list = next; }
}

guint g_str_hash(gconstpointer key)
{
  guint h = 5381;
  for(const unsigned char *p = key; *p; p++) h = h * 33 + *p;
  return h;
}

gboolean g_str_equal(gconstpointer a, gconstpointer b) { return strcmp(a, b) == 0; }

struct GHashTable
{
  GHashFunc hash;
  GEqualFunc equal;
  GDestroyNotify key_free, value_free;
  size_t count, cap;
  gpointer *keys, *values;
};

GHashTable *g_hash_table_new_full(GHashFunc hash, GEqualFunc equal, GDestroyNotify key_free, GDestroyNotify value_free)
{
  GHashTable *t = calloc(1, sizeof *t);
  t->hash = hash; t->equal = equal; t->key_free = key_free; t->value_free = value_free;
  return t;
}

/* A few dozen entries at most (illuminants, filters): a list is plenty. */
void g_hash_table_insert(GHashTable *t, gpointer key, gpointer value)
{
  for(size_t i = 0; i < t->count; i++)
    if(t->equal(t->keys[i], key))
    {
      if(t->key_free) t->key_free(key);
      if(t->value_free && t->values[i] != value) t->value_free(t->values[i]);
      t->values[i] = value;
      return;
    }
  if(t->count == t->cap)
  {
    t->cap = t->cap ? t->cap * 2 : 16;
    t->keys = realloc(t->keys, t->cap * sizeof(gpointer));
    t->values = realloc(t->values, t->cap * sizeof(gpointer));
  }
  t->keys[t->count] = key;
  t->values[t->count++] = value;
}

gpointer g_hash_table_lookup(GHashTable *t, gconstpointer key)
{
  if(!t) return NULL;
  for(size_t i = 0; i < t->count; i++)
    if(t->equal(t->keys[i], key)) return t->values[i];
  return NULL;
}

void g_hash_table_destroy(GHashTable *t)
{
  if(!t) return;
  for(size_t i = 0; i < t->count; i++)
  {
    if(t->key_free) t->key_free(t->keys[i]);
    if(t->value_free) t->value_free(t->values[i]);
  }
  free(t->keys); free(t->values); free(t);
}

/* ------------------------------------------------------------------ json -- */

enum { J_NULL, J_BOOL, J_NUMBER, J_STRING, J_ARRAY, J_OBJECT };

struct JsonNode { int type; double number; gboolean flag; char *string; JsonArray *array; JsonObject *object; };
struct JsonArray { guint count, cap; JsonNode **items; };
struct JsonObject { guint count, cap; char **names; JsonNode **values; };
struct JsonParser { JsonNode *root; };

static void node_free(JsonNode *n);

static void array_free(JsonArray *a)
{
  if(!a) return;
  for(guint i = 0; i < a->count; i++) node_free(a->items[i]);
  free(a->items); free(a);
}

static void object_free(JsonObject *o)
{
  if(!o) return;
  for(guint i = 0; i < o->count; i++) { free(o->names[i]); node_free(o->values[i]); }
  free(o->names); free(o->values); free(o);
}

static void node_free(JsonNode *n)
{
  if(!n) return;
  free(n->string); array_free(n->array); object_free(n->object); free(n);
}

typedef struct { const char *p, *end; } cursor_t;

static void skip(cursor_t *c) { while(c->p < c->end && isspace((unsigned char)*c->p)) c->p++; }

static JsonNode *parse_value(cursor_t *c, int depth);

static char *parse_string(cursor_t *c)
{
  if(c->p >= c->end || *c->p != '"') return NULL;
  c->p++;
  size_t cap = 32, len = 0;
  char *out = malloc(cap);
  while(c->p < c->end && *c->p != '"')
  {
    char ch = *c->p++;
    if(ch == '\\' && c->p < c->end)
    {
      char e = *c->p++;
      switch(e)
      {
        case 'n': ch = '\n'; break;
        case 't': ch = '\t'; break;
        case 'r': ch = '\r'; break;
        case 'b': ch = '\b'; break;
        case 'f': ch = '\f'; break;
        case 'u':
        {
          unsigned code = 0;
          for(int i = 0; i < 4 && c->p < c->end; i++)
          {
            char h = *c->p++;
            code = code * 16 + (unsigned)(isdigit((unsigned char)h) ? h - '0' : (tolower((unsigned char)h) - 'a' + 10));
          }
          /* UTF-8 (the profiles only ever name stocks and sources). */
          char buf[4]; int n = 0;
          if(code < 0x80) buf[n++] = (char)code;
          else if(code < 0x800) { buf[n++] = (char)(0xC0 | (code >> 6)); buf[n++] = (char)(0x80 | (code & 0x3F)); }
          else { buf[n++] = (char)(0xE0 | (code >> 12)); buf[n++] = (char)(0x80 | ((code >> 6) & 0x3F)); buf[n++] = (char)(0x80 | (code & 0x3F)); }
          if(len + n + 1 > cap) { cap = (len + n + 1) * 2; out = realloc(out, cap); }
          memcpy(out + len, buf, n); len += n;
          continue;
        }
        default: ch = e;
      }
    }
    if(len + 2 > cap) { cap *= 2; out = realloc(out, cap); }
    out[len++] = ch;
  }
  if(c->p < c->end) c->p++; /* closing quote */
  out[len] = 0;
  return out;
}

static JsonNode *parse_value(cursor_t *c, int depth)
{
  skip(c);
  if(c->p >= c->end || depth > 64) return NULL;
  JsonNode *n = calloc(1, sizeof *n);
  char ch = *c->p;
  if(ch == '{')
  {
    c->p++;
    n->type = J_OBJECT;
    n->object = calloc(1, sizeof(JsonObject));
    skip(c);
    if(c->p < c->end && *c->p == '}') { c->p++; return n; }
    for(;;)
    {
      skip(c);
      char *name = parse_string(c);
      skip(c);
      if(!name || c->p >= c->end || *c->p != ':') { free(name); node_free(n); return NULL; }
      c->p++;
      JsonNode *value = parse_value(c, depth + 1);
      if(!value) { free(name); node_free(n); return NULL; }
      JsonObject *o = n->object;
      if(o->count == o->cap)
      {
        o->cap = o->cap ? o->cap * 2 : 8;
        o->names = realloc(o->names, o->cap * sizeof(char *));
        o->values = realloc(o->values, o->cap * sizeof(JsonNode *));
      }
      o->names[o->count] = name;
      o->values[o->count++] = value;
      skip(c);
      if(c->p < c->end && *c->p == ',') { c->p++; continue; }
      if(c->p < c->end && *c->p == '}') { c->p++; return n; }
      node_free(n);
      return NULL;
    }
  }
  if(ch == '[')
  {
    c->p++;
    n->type = J_ARRAY;
    n->array = calloc(1, sizeof(JsonArray));
    skip(c);
    if(c->p < c->end && *c->p == ']') { c->p++; return n; }
    for(;;)
    {
      JsonNode *value = parse_value(c, depth + 1);
      if(!value) { node_free(n); return NULL; }
      JsonArray *a = n->array;
      if(a->count == a->cap) { a->cap = a->cap ? a->cap * 2 : 16; a->items = realloc(a->items, a->cap * sizeof(JsonNode *)); }
      a->items[a->count++] = value;
      skip(c);
      if(c->p < c->end && *c->p == ',') { c->p++; continue; }
      if(c->p < c->end && *c->p == ']') { c->p++; return n; }
      node_free(n);
      return NULL;
    }
  }
  if(ch == '"') { n->type = J_STRING; n->string = parse_string(c); return n; }
  if(!strncmp(c->p, "true", 4)) { c->p += 4; n->type = J_BOOL; n->flag = TRUE; return n; }
  if(!strncmp(c->p, "false", 5)) { c->p += 5; n->type = J_BOOL; return n; }
  if(!strncmp(c->p, "null", 4)) { c->p += 4; n->type = J_NULL; return n; }
  /* Python's json writes NaN and Infinity for non-finite floats. */
  if(!strncmp(c->p, "NaN", 3)) { c->p += 3; n->type = J_NUMBER; n->number = NAN; return n; }
  if(!strncmp(c->p, "Infinity", 8)) { c->p += 8; n->type = J_NUMBER; n->number = INFINITY; return n; }
  if(!strncmp(c->p, "-Infinity", 9)) { c->p += 9; n->type = J_NUMBER; n->number = -INFINITY; return n; }
  char *end = NULL;
  n->number = strtod(c->p, &end);
  if(end == c->p) { free(n); return NULL; }
  c->p = end;
  n->type = J_NUMBER;
  return n;
}

JsonParser *json_parser_new(void) { return calloc(1, sizeof(JsonParser)); }

gboolean json_parser_load_from_file(JsonParser *parser, const char *path, GError **error)
{
  FILE *f = fopen(path, "rb");
  char *text = NULL;
  long size = 0;
  if(f)
  {
    fseek(f, 0, SEEK_END);
    size = ftell(f);
    fseek(f, 0, SEEK_SET);
    text = malloc((size_t)size + 1);
    if(fread(text, 1, (size_t)size, f) != (size_t)size) { free(text); text = NULL; }
    fclose(f);
  }
  if(!text)
  {
    if(error) { *error = calloc(1, sizeof(GError)); asprintf(&(*error)->message, "cannot read %s", path); }
    return FALSE;
  }
  text[size] = 0;
  cursor_t c = { text, text + size };
  node_free(parser->root);
  parser->root = parse_value(&c, 0);
  free(text);
  if(!parser->root)
  {
    if(error) { *error = calloc(1, sizeof(GError)); asprintf(&(*error)->message, "%s is not valid JSON", path); }
    return FALSE;
  }
  return TRUE;
}

JsonNode *json_parser_get_root(JsonParser *parser) { return parser ? parser->root : NULL; }

void g_object_unref(void *object)
{
  JsonParser *parser = object;
  if(!parser) return;
  node_free(parser->root);
  free(parser);
}

gboolean json_node_holds_array(JsonNode *n) { return n && n->type == J_ARRAY; }
gboolean json_node_holds_object(JsonNode *n) { return n && n->type == J_OBJECT; }
JsonObject *json_node_get_object(JsonNode *n) { return n && n->type == J_OBJECT ? n->object : NULL; }
JsonArray *json_node_get_array(JsonNode *n) { return n && n->type == J_ARRAY ? n->array : NULL; }
double json_node_get_double(JsonNode *n)
{
  if(!n) return 0.0;
  if(n->type == J_NUMBER) return n->number;
  if(n->type == J_BOOL) return n->flag ? 1.0 : 0.0;
  if(n->type == J_STRING && n->string) return strtod(n->string, NULL);
  return 0.0;
}
const char *json_node_get_string(JsonNode *n) { return n && n->type == J_STRING ? n->string : NULL; }
gboolean json_node_is_null(JsonNode *n) { return !n || n->type == J_NULL; }

JsonNode *json_object_get_member(JsonObject *o, const char *name)
{
  if(!o || !name) return NULL;
  for(guint i = 0; i < o->count; i++)
    if(!strcmp(o->names[i], name)) return o->values[i];
  return NULL;
}
gboolean json_object_has_member(JsonObject *o, const char *name) { return json_object_get_member(o, name) != NULL; }
JsonObject *json_object_get_object_member(JsonObject *o, const char *name) { return json_node_get_object(json_object_get_member(o, name)); }
JsonArray *json_object_get_array_member(JsonObject *o, const char *name) { return json_node_get_array(json_object_get_member(o, name)); }
const char *json_object_get_string_member(JsonObject *o, const char *name) { return json_node_get_string(json_object_get_member(o, name)); }
double json_object_get_double_member(JsonObject *o, const char *name) { return json_node_get_double(json_object_get_member(o, name)); }
gint64 json_object_get_int_member(JsonObject *o, const char *name) { return (gint64)json_node_get_double(json_object_get_member(o, name)); }
gboolean json_object_get_boolean_member(JsonObject *o, const char *name)
{
  JsonNode *n = json_object_get_member(o, name);
  return n && ((n->type == J_BOOL && n->flag) || (n->type == J_NUMBER && n->number != 0));
}

GList *json_object_get_members(JsonObject *o)
{
  GList *head = NULL, **tail = &head;
  for(guint i = 0; o && i < o->count; i++)
  {
    GList *l = calloc(1, sizeof(GList));
    l->data = o->names[i];
    *tail = l;
    tail = &l->next;
  }
  return head;
}

guint json_array_get_length(JsonArray *a) { return a ? a->count : 0; }
JsonNode *json_array_get_element(JsonArray *a, guint i) { return a && i < a->count ? a->items[i] : NULL; }
JsonArray *json_array_get_array_element(JsonArray *a, guint i) { return json_node_get_array(json_array_get_element(a, i)); }
JsonObject *json_array_get_object_element(JsonArray *a, guint i) { return json_node_get_object(json_array_get_element(a, i)); }
double json_array_get_double_element(JsonArray *a, guint i) { return json_node_get_double(json_array_get_element(a, i)); }

/* -------------------------------------- darktable's gaussian.c (unchanged) -- */

void dt_gaussian_yvv_coeffs(const float sigma,
                            float out[4])
{
  const double s = (double)sigma;
  const double q = (s >= 2.5) ? (0.98711 * s - 0.96330)
                              : (3.97156 - 4.14554 * sqrt(1.0 - 0.26891 * s));
  const double q2 = q * q, q3 = q2 * q;
  const double b0 = 1.57825 + 2.44413 * q + 1.4281 * q2 + 0.422205 * q3;
  const double b1 = 2.44413 * q + 2.85619 * q2 + 1.26661 * q3;
  const double b2 = -(1.4281 * q2 + 1.26661 * q3);
  const double b3 = 0.422205 * q3;
  out[1] = (float)(b1 / b0);
  out[2] = (float)(b2 / b0);
  out[3] = (float)(b3 / b0);
  out[0] = (float)(1.0 - (b1 + b2 + b3) / b0);
}

int dt_gaussian_kernel_1d(const float sigma,
                          float *const kernel,
                          const int max_radius)
{
  int radius = (int)(3.0f * sigma + 0.5f);
  if(radius < 1) radius = 1;
  if(radius > max_radius) radius = max_radius;
  double sum = 0.0;
  const double inv2s2 = 1.0 / (2.0 * (double)sigma * (double)sigma);
  for(int i = -radius; i <= radius; i++)
  {
    const double v = exp(-(double)(i * i) * inv2s2);
    kernel[i + radius] = (float)v;
    sum += v;
  }
  const float invsum = (float)(1.0 / sum);
  for(int i = 0; i < 2 * radius + 1; i++) kernel[i] *= invsum;
  return radius;
}
