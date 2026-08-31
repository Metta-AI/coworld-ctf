#ifndef CTF_RUNTIME_SPIKE_WASMTIME_SHIM_H
#define CTF_RUNTIME_SPIKE_WASMTIME_SHIM_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <wasmtime.h>

#if defined(__APPLE__)
#include <mach/mach.h>
#else
#include <unistd.h>
#endif

_Static_assert(sizeof(wasmtime_func_t) == 16, "unexpected wasmtime_func_t ABI");
_Static_assert(sizeof(wasmtime_instance_t) == 16,
               "unexpected wasmtime_instance_t ABI");
_Static_assert(sizeof(wasmtime_memory_t) == 24,
               "unexpected wasmtime_memory_t ABI");
_Static_assert(sizeof(wasmtime_val_raw_t) == 16,
               "unexpected wasmtime_val_raw_t ABI");
_Static_assert(_Alignof(wasmtime_val_raw_t) == _Alignof(uint64_t),
               "unexpected wasmtime_val_raw_t alignment");

static inline int runtime_spike_abi_ok(void) {
  return sizeof(wasmtime_func_t) == 16 &&
         sizeof(wasmtime_instance_t) == 16 &&
         sizeof(wasmtime_memory_t) == 24 &&
         sizeof(wasmtime_val_raw_t) == 16 &&
         sizeof(wasmtime_valunion_t) >= 16 &&
         sizeof(wasmtime_valunion_t) <= 24;
}

static inline void runtime_spike_val_i32_set(wasmtime_val_t *val,
                                              int32_t value) {
  val->kind = WASMTIME_I32;
  val->of.i32 = value;
}

static inline int32_t runtime_spike_val_i32_get(const wasmtime_val_t *val) {
  return val->of.i32;
}

static inline void runtime_spike_val_i64_set(wasmtime_val_t *val,
                                              int64_t value) {
  val->kind = WASMTIME_I64;
  val->of.i64 = value;
}

static inline uint8_t runtime_spike_val_kind(const wasmtime_val_t *val) {
  return val->kind;
}

static inline wasmtime_func_t *
runtime_spike_extern_func(wasmtime_extern_t *item) {
  return &item->of.func;
}

static inline wasmtime_memory_t *
runtime_spike_extern_memory(wasmtime_extern_t *item) {
  return &item->of.memory;
}

static inline uint8_t runtime_spike_extern_kind(const wasmtime_extern_t *item) {
  return item->kind;
}

static inline void runtime_spike_extern_memory_copy(
    wasmtime_memory_t *memory, const wasmtime_extern_t *item) {
  *memory = item->of.memory;
}

static inline int runtime_spike_process_memory(uint64_t *resident,
                                               uint64_t *virtual_size) {
#if defined(__APPLE__)
  mach_task_basic_info_data_t info;
  mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
  kern_return_t status = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                   (task_info_t)&info, &count);
  if (status != KERN_SUCCESS) {
    return 0;
  }
  *resident = (uint64_t)info.resident_size;
  *virtual_size = (uint64_t)info.virtual_size;
  return 1;
#else
  FILE *statm = fopen("/proc/self/statm", "r");
  if (statm == NULL) {
    return 0;
  }
  unsigned long pages = 0;
  unsigned long resident_pages = 0;
  int matched = fscanf(statm, "%lu %lu", &pages, &resident_pages);
  fclose(statm);
  if (matched != 2) {
    return 0;
  }
  long page_size = sysconf(_SC_PAGESIZE);
  if (page_size <= 0) {
    return 0;
  }
  *resident = (uint64_t)resident_pages * (uint64_t)page_size;
  *virtual_size = (uint64_t)pages * (uint64_t)page_size;
  return 1;
#endif
}

static inline wasm_functype_t *runtime_spike_emit_functype(void) {
  wasm_valtype_t *param_items[2] = {
      wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32),
  };
  wasm_valtype_t *result_items[1] = {wasm_valtype_new(WASM_I32)};
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 2, param_items);
  wasm_valtype_vec_new(&results, 1, result_items);
  return wasm_functype_new(&params, &results);
}

static inline wasm_functype_t *runtime_spike_cover_functype(void) {
  wasm_valtype_t *param_items[6] = {
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32), wasm_valtype_new(WASM_I32),
  };
  wasm_valtype_t *result_items[1] = {wasm_valtype_new(WASM_I64)};
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 6, param_items);
  wasm_valtype_vec_new(&results, 1, result_items);
  return wasm_functype_new(&params, &results);
}

static inline wasm_functype_t *runtime_spike_log_functype(void) {
  wasm_valtype_t *param_items[3] = {
      wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32),
      wasm_valtype_new(WASM_I32),
  };
  wasm_valtype_vec_t params;
  wasm_valtype_vec_t results;
  wasm_valtype_vec_new(&params, 3, param_items);
  wasm_valtype_vec_new_empty(&results);
  return wasm_functype_new(&params, &results);
}

static inline wasmtime_error_t *runtime_spike_linker_define_func(
    wasmtime_linker_t *linker, const char *module, size_t module_len,
    const char *name, size_t name_len, const wasm_functype_t *ty,
    void *callback, void *data) {
  return wasmtime_linker_define_func(
      linker, module, module_len, name, name_len, ty,
      (wasmtime_func_callback_t)callback, data, NULL);
}

#endif
