#ifndef CTF_SHELL_WASMTIME_SHIM_H
#define CTF_SHELL_WASMTIME_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <wasmtime.h>

/* These are the by-value C API handles stored by the Nim binding. */
_Static_assert(sizeof(wasmtime_func_t) == 16, "unexpected wasmtime_func_t ABI");
_Static_assert(sizeof(wasmtime_instance_t) == 16,
               "unexpected wasmtime_instance_t ABI");
_Static_assert(sizeof(wasmtime_memory_t) == 24,
               "unexpected wasmtime_memory_t ABI");
_Static_assert(sizeof(wasmtime_val_raw_t) == 16,
               "unexpected wasmtime_val_raw_t ABI");
_Static_assert(_Alignof(wasmtime_val_raw_t) == _Alignof(uint64_t),
               "unexpected wasmtime_val_raw_t alignment");

static inline int shell_wasmtime_abi_ok(void) {
  return sizeof(wasmtime_func_t) == 16 &&
         sizeof(wasmtime_instance_t) == 16 &&
         sizeof(wasmtime_memory_t) == 24 &&
         sizeof(wasmtime_val_raw_t) == 16 &&
         sizeof(wasmtime_valunion_t) >= 16 &&
         sizeof(wasmtime_valunion_t) <= 24;
}

static inline size_t shell_wasmtime_func_size(void) {
  return sizeof(wasmtime_func_t);
}

static inline size_t shell_wasmtime_instance_size(void) {
  return sizeof(wasmtime_instance_t);
}

static inline size_t shell_wasmtime_memory_size(void) {
  return sizeof(wasmtime_memory_t);
}

static inline size_t shell_wasmtime_val_raw_size(void) {
  return sizeof(wasmtime_val_raw_t);
}

static inline size_t shell_wasmtime_val_raw_alignment(void) {
  return _Alignof(wasmtime_val_raw_t);
}

static inline const char *shell_wasmtime_version(void) {
  return WASMTIME_VERSION;
}

static inline void shell_wasmtime_val_i32_set(wasmtime_val_t *val,
                                               int32_t value) {
  val->kind = WASMTIME_I32;
  val->of.i32 = value;
}

static inline int32_t shell_wasmtime_val_i32_get(const wasmtime_val_t *val) {
  return val->of.i32;
}

static inline void shell_wasmtime_val_i64_set(wasmtime_val_t *val,
                                               int64_t value) {
  val->kind = WASMTIME_I64;
  val->of.i64 = value;
}

static inline uint8_t shell_wasmtime_extern_kind(
    const wasmtime_extern_t *item) {
  return item->kind;
}

static inline wasmtime_func_t *shell_wasmtime_extern_func(
    wasmtime_extern_t *item) {
  return &item->of.func;
}

static inline wasmtime_memory_t *shell_wasmtime_extern_memory(
    wasmtime_extern_t *item) {
  return &item->of.memory;
}

static inline wasm_functype_t *shell_wasmtime_emit_functype(void) {
  wasm_valtype_t *params_raw[2] = {
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32)};
  wasm_valtype_t *results_raw[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 2, params_raw);
  wasm_valtype_vec_new(&results, 1, results_raw);
  return wasm_functype_new(&params, &results);
}

static inline wasm_functype_t *shell_wasmtime_log_functype(void) {
  wasm_valtype_t *params_raw[3] = {
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 3, params_raw);
  wasm_valtype_vec_new_empty(&results);
  return wasm_functype_new(&params, &results);
}

static inline wasm_functype_t *shell_wasmtime_reachable_functype(void) {
  wasm_valtype_t *params_raw[2] = {
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32)};
  wasm_valtype_t *results_raw[1] = {wasm_valtype_new(WASM_I64)};
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 2, params_raw);
  wasm_valtype_vec_new(&results, 1, results_raw);
  return wasm_functype_new(&params, &results);
}

static inline wasm_functype_t *shell_wasmtime_cover_functype(void) {
  wasm_valtype_t *params_raw[6] = {
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32)};
  wasm_valtype_t *results_raw[1] = {wasm_valtype_new(WASM_I64)};
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 6, params_raw);
  wasm_valtype_vec_new(&results, 1, results_raw);
  return wasm_functype_new(&params, &results);
}

static inline wasmtime_error_t *shell_wasmtime_linker_define_func(
    wasmtime_linker_t *linker, const char *module, size_t module_len,
    const char *name, size_t name_len, const wasm_functype_t *ty,
    wasmtime_func_callback_t callback, void *data) {
  return wasmtime_linker_define_func(linker, module, module_len, name,
                                     name_len, ty, callback, data, NULL);
}

#endif
