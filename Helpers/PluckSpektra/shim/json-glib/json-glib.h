/* pluck-spektra: the part of json-glib darktable's spektra engine uses,
   over a small parser. GPL-3.0-or-later. */
#pragma once
#include <glib.h>

typedef struct JsonNode JsonNode;
typedef struct JsonObject JsonObject;
typedef struct JsonArray JsonArray;
typedef struct JsonParser JsonParser;

JsonParser *json_parser_new(void);
gboolean json_parser_load_from_file(JsonParser *parser, const char *path, GError **error);
JsonNode *json_parser_get_root(JsonParser *parser);

gboolean json_node_holds_array(JsonNode *node);
gboolean json_node_holds_object(JsonNode *node);
#define JSON_NODE_HOLDS_ARRAY(n) json_node_holds_array(n)
#define JSON_NODE_HOLDS_OBJECT(n) json_node_holds_object(n)
#define JSON_NODE_HOLDS_NULL(n) json_node_is_null(n)
JsonObject *json_node_get_object(JsonNode *node);
JsonArray *json_node_get_array(JsonNode *node);
double json_node_get_double(JsonNode *node);
const char *json_node_get_string(JsonNode *node);
gboolean json_node_is_null(JsonNode *node);

gboolean json_object_has_member(JsonObject *object, const char *name);
JsonNode *json_object_get_member(JsonObject *object, const char *name);
JsonObject *json_object_get_object_member(JsonObject *object, const char *name);
JsonArray *json_object_get_array_member(JsonObject *object, const char *name);
const char *json_object_get_string_member(JsonObject *object, const char *name);
double json_object_get_double_member(JsonObject *object, const char *name);
gint64 json_object_get_int_member(JsonObject *object, const char *name);
gboolean json_object_get_boolean_member(JsonObject *object, const char *name);
GList *json_object_get_members(JsonObject *object);

guint json_array_get_length(JsonArray *array);
JsonNode *json_array_get_element(JsonArray *array, guint index);
JsonArray *json_array_get_array_element(JsonArray *array, guint index);
JsonObject *json_array_get_object_element(JsonArray *array, guint index);
double json_array_get_double_element(JsonArray *array, guint index);
