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

#endif
