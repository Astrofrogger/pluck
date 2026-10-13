/* pluck-spektra: the small part of GLib that darktable's spektra engine uses,
   so the helper needs no libraries beyond the system's.
   Copyright (C) 2026. GPL-3.0-or-later, like the rest of this helper. */
#pragma once
#include <stdarg.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int gboolean;
typedef int gint;
typedef unsigned int guint;
typedef char gchar;
typedef double gdouble;
typedef int64_t gint64;
typedef uint64_t guint64;
typedef size_t gsize;
typedef void *gpointer;
typedef const void *gconstpointer;
#ifndef MIN
#define MIN(a, b) (((a) < (b)) ? (a) : (b))
#define MAX(a, b) (((a) > (b)) ? (a) : (b))
#endif
#ifndef CLAMP
#define CLAMP(x, lo, hi) (((x) > (hi)) ? (hi) : (((x) < (lo)) ? (lo) : (x)))
#endif
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif

typedef struct GError { int code; char *message; } GError;
void g_clear_error(GError **error);

typedef struct GList { void *data; struct GList *next; } GList;
void g_list_free(GList *list);

typedef guint (*GHashFunc)(gconstpointer key);
typedef gboolean (*GEqualFunc)(gconstpointer a, gconstpointer b);
typedef void (*GDestroyNotify)(gpointer data);
typedef struct GHashTable GHashTable;
GHashTable *g_hash_table_new_full(GHashFunc hash, GEqualFunc equal, GDestroyNotify key_free, GDestroyNotify value_free);
void g_hash_table_insert(GHashTable *table, gpointer key, gpointer value);
gpointer g_hash_table_lookup(GHashTable *table, gconstpointer key);
void g_hash_table_destroy(GHashTable *table);
guint g_str_hash(gconstpointer key);
gboolean g_str_equal(gconstpointer a, gconstpointer b);

void g_free(void *p);
void *g_malloc0(size_t n);
#define g_new(T, n) ((T *)calloc((size_t)(n), sizeof(T)))
#define g_new0(T, n) ((T *)calloc((size_t)(n), sizeof(T)))
char *g_strdup(const char *s);
size_t g_strlcpy(char *dst, const char *src, size_t size);
char *g_strdup_vprintf(const char *format, va_list args);
char *g_build_filename(const char *first, ...);
guint64 g_ascii_strtoull(const char *nptr, char **endptr, guint base);
#define g_atomic_int_inc(p) __atomic_add_fetch((p), 1, __ATOMIC_SEQ_CST)
#define g_atomic_int_dec_and_test(p) (__atomic_sub_fetch((p), 1, __ATOMIC_SEQ_CST) == 0)
#define g_warning(...) (fprintf(stderr, __VA_ARGS__), fputc('\n', stderr))
void g_object_unref(void *object);
