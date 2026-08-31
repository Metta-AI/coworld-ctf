## Narrow Wasmtime v48 C API used by the production shell runtime.
##
## This binding deliberately contains no spike imports. Ownership is explicit:
## configs are consumed by Engine creation; errors, traps, modules, Stores, and
## Engines are deleted exactly once by `runtime.nim`.

import std/os

const
  WasmtimeHeader* = "wasmtime_shim.h"
  ShellIncludeDir = currentSourcePath().parentDir()
  WasmtimeCapiRoot = static(getEnv("WASMTIME_C_API"))

when WasmtimeCapiRoot.len == 0:
  {.error: "WASMTIME_C_API is required for the shell runtime; run " &
    "tools/runtime_spike/fetch_deps.sh and set WASMTIME_C_API to the " &
    "printed wasmtime-c-api path".}

{.passC: "-I" & ShellIncludeDir.}
{.passC: "-I" & WasmtimeCapiRoot / "include".}
{.passL: "-L" & WasmtimeCapiRoot / "lib".}
{.passL: "-lwasmtime".}
{.passL: "-Wl,-rpath," & WasmtimeCapiRoot / "lib".}

type
  WasmConfig* {.importc: "wasm_config_t", header: WasmtimeHeader.} = object
  WasmEngine* {.importc: "wasm_engine_t", header: WasmtimeHeader.} = object
  WasmFuncType* {.importc: "wasm_functype_t", header: WasmtimeHeader.} = object
  WasmTrap* {.importc: "wasm_trap_t", header: WasmtimeHeader.} = object
  WasmtimeContext* {.importc: "wasmtime_context_t",
      header: WasmtimeHeader.} = object
  WasmtimeError* {.importc: "wasmtime_error_t",
      header: WasmtimeHeader.} = object
  WasmtimeExtern* {.importc: "wasmtime_extern_t",
      header: WasmtimeHeader.} = object
  WasmtimeFunc* {.importc: "wasmtime_func_t",
      header: WasmtimeHeader.} = object
  WasmtimeInstance* {.importc: "wasmtime_instance_t",
      header: WasmtimeHeader.} = object
  WasmtimeModule* {.importc: "wasmtime_module_t",
      header: WasmtimeHeader.} = object
  WasmtimeLinker* {.importc: "wasmtime_linker_t",
      header: WasmtimeHeader.} = object
  WasmtimeMemory* {.importc: "wasmtime_memory_t",
      header: WasmtimeHeader.} = object
  WasmtimeCaller* {.importc: "wasmtime_caller_t",
      header: WasmtimeHeader.} = object
  WasmtimePoolingConfig* {.
      importc: "wasmtime_pooling_allocation_config_t",
      header: WasmtimeHeader.} = object
  WasmtimeStore* {.importc: "wasmtime_store_t",
      header: WasmtimeHeader.} = object
  WasmtimeVal* {.importc: "wasmtime_val_t", header: WasmtimeHeader.} = object
  WasmtimeConstVal* {.importc: "const wasmtime_val_t",
      header: WasmtimeHeader.} = object

  WasmByteVec* {.importc: "wasm_byte_vec_t", header: WasmtimeHeader,
      bycopy.} = object
    size*: csize_t
    data*: ptr uint8

  WasmtimeCallback* = proc(env: pointer; caller: ptr WasmtimeCaller;
      args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
      nresults: csize_t): ptr WasmTrap {.cdecl.}

const
  WasmtimeStrategyCranelift* = 1'u8
  WasmtimeExternFunc* = 0'u8
  WasmtimeExternMemory* = 3'u8

proc wasmConfigNew*(): ptr WasmConfig {.importc: "wasm_config_new",
    header: WasmtimeHeader.}
proc wasmConfigDelete*(config: ptr WasmConfig) {.importc: "wasm_config_delete",
    header: WasmtimeHeader.}
proc wasmEngineNewWithConfig*(config: ptr WasmConfig): ptr WasmEngine {.
    importc: "wasm_engine_new_with_config", header: WasmtimeHeader.}
proc wasmEngineDelete*(engine: ptr WasmEngine) {.importc: "wasm_engine_delete",
    header: WasmtimeHeader.}

proc wasmtimeConfigConsumeFuelSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_consume_fuel_set", header: WasmtimeHeader.}
proc wasmtimeConfigEpochInterruptionSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_epoch_interruption_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigMaxWasmStackSet*(config: ptr WasmConfig; size: csize_t) {.
    importc: "wasmtime_config_max_wasm_stack_set", header: WasmtimeHeader.}
proc wasmtimeConfigStrategySet*(config: ptr WasmConfig; strategy: uint8) {.
    importc: "wasmtime_config_strategy_set", header: WasmtimeHeader.}
proc wasmtimeConfigParallelCompilationSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_parallel_compilation_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigCraneliftNanCanonicalizationSet*(config: ptr WasmConfig;
    enabled: bool) {.
    importc: "wasmtime_config_cranelift_nan_canonicalization_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigMemoryMayMoveSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_memory_may_move_set", header: WasmtimeHeader.}
proc wasmtimeConfigMemoryReservationSet*(config: ptr WasmConfig;
    size: uint64) {.importc: "wasmtime_config_memory_reservation_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigMemoryGuardSizeSet*(config: ptr WasmConfig; size: uint64) {.
    importc: "wasmtime_config_memory_guard_size_set", header: WasmtimeHeader.}
proc wasmtimeConfigSignalsBasedTrapsSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_signals_based_traps_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigMacosUseMachPortsSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_macos_use_mach_ports_set",
    header: WasmtimeHeader.}

proc wasmtimeConfigWasmThreadsSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_threads_set", header: WasmtimeHeader.}
proc wasmtimeConfigSharedMemorySet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_shared_memory_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmTailCallSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_tail_call_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmReferenceTypesSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_reference_types_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmFunctionReferencesSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_function_references_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmGcSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_gc_set", header: WasmtimeHeader.}
proc wasmtimeConfigGcSupportSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_gc_support_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmSimdSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_simd_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmRelaxedSimdSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_relaxed_simd_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmBulkMemorySet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_bulk_memory_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmMultiValueSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_multi_value_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmMultiMemorySet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_multi_memory_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmMemory64Set*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_wasm_memory64_set", header: WasmtimeHeader.}
proc wasmtimeConfigWasmWideArithmeticSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_wide_arithmetic_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmBranchHintingSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_branch_hinting_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmExceptionsSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_exceptions_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmCustomPageSizesSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_custom_page_sizes_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigWasmStackSwitchingSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_wasm_stack_switching_set",
    header: WasmtimeHeader.}

proc wasmtimePoolingConfigNew*(): ptr WasmtimePoolingConfig {.
    importc: "wasmtime_pooling_allocation_config_new", header: WasmtimeHeader.}
proc wasmtimePoolingConfigDelete*(pool: ptr WasmtimePoolingConfig) {.
    importc: "wasmtime_pooling_allocation_config_delete",
    header: WasmtimeHeader.}
proc wasmtimePoolingTotalCoreInstancesSet*(pool: ptr WasmtimePoolingConfig;
    count: uint32) {.
    importc: "wasmtime_pooling_allocation_config_total_core_instances_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingTotalMemoriesSet*(pool: ptr WasmtimePoolingConfig;
    count: uint32) {.
    importc: "wasmtime_pooling_allocation_config_total_memories_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingMaxMemoriesPerModuleSet*(pool: ptr WasmtimePoolingConfig;
    count: uint32) {.
    importc: "wasmtime_pooling_allocation_config_max_memories_per_module_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingMaxMemorySizeSet*(pool: ptr WasmtimePoolingConfig;
    size: csize_t) {.
    importc: "wasmtime_pooling_allocation_config_max_memory_size_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingLinearMemoryKeepResidentSet*(
    pool: ptr WasmtimePoolingConfig; size: csize_t) {.
    importc: "wasmtime_pooling_allocation_config_linear_memory_keep_resident_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingAllocationStrategySet*(config: ptr WasmConfig;
    pool: ptr WasmtimePoolingConfig) {.
    importc: "wasmtime_pooling_allocation_strategy_set",
    header: WasmtimeHeader.}

proc wasmtimeStoreNew*(engine: ptr WasmEngine; data: pointer;
    finalizer: pointer): ptr WasmtimeStore {.importc: "wasmtime_store_new",
    header: WasmtimeHeader.}
proc wasmtimeStoreContext*(store: ptr WasmtimeStore): ptr WasmtimeContext {.
    importc: "wasmtime_store_context", header: WasmtimeHeader.}
proc wasmtimeStoreLimiter*(store: ptr WasmtimeStore; memorySize,
    tableElements, instances, tables, memories: int64) {.
    importc: "wasmtime_store_limiter", header: WasmtimeHeader.}
proc wasmtimeStoreDelete*(store: ptr WasmtimeStore) {.
    importc: "wasmtime_store_delete", header: WasmtimeHeader.}
proc wasmtimeContextSetFuel*(context: ptr WasmtimeContext;
    fuel: uint64): ptr WasmtimeError {.importc: "wasmtime_context_set_fuel",
    header: WasmtimeHeader.}
proc wasmtimeContextSetEpochDeadline*(context: ptr WasmtimeContext;
    ticks: uint64) {.importc: "wasmtime_context_set_epoch_deadline",
    header: WasmtimeHeader.}
proc wasmtimeEngineIncrementEpoch*(engine: ptr WasmEngine) {.
    importc: "wasmtime_engine_increment_epoch", header: WasmtimeHeader.}

proc wasmtimeModuleValidate*(engine: ptr WasmEngine; bytes: ptr uint8;
    size: csize_t): ptr WasmtimeError {.importc: "wasmtime_module_validate",
    header: WasmtimeHeader.}
proc wasmtimeModuleNew*(engine: ptr WasmEngine; bytes: ptr uint8;
    size: csize_t; module: ptr ptr WasmtimeModule): ptr WasmtimeError {.
    importc: "wasmtime_module_new", header: WasmtimeHeader.}
proc wasmtimeModuleSerialize*(module: ptr WasmtimeModule;
    output: ptr WasmByteVec): ptr WasmtimeError {.
    importc: "wasmtime_module_serialize", header: WasmtimeHeader.}
proc wasmtimeModuleDelete*(module: ptr WasmtimeModule) {.
    importc: "wasmtime_module_delete", header: WasmtimeHeader.}
proc wasmtimeInstanceNew*(context: ptr WasmtimeContext;
    module: ptr WasmtimeModule; imports: pointer; importCount: csize_t;
    instance: ptr WasmtimeInstance; trap: ptr ptr WasmTrap): ptr WasmtimeError {.
    importc: "wasmtime_instance_new", header: WasmtimeHeader.}
proc wasmtimeLinkerNew*(engine: ptr WasmEngine): ptr WasmtimeLinker {.
    importc: "wasmtime_linker_new", header: WasmtimeHeader.}
proc wasmtimeLinkerDelete*(linker: ptr WasmtimeLinker) {.
    importc: "wasmtime_linker_delete", header: WasmtimeHeader.}
proc shellWasmtimeLinkerDefineFunc*(linker: ptr WasmtimeLinker;
    module: cstring; moduleLen: csize_t; name: cstring; nameLen: csize_t;
    functionType: ptr WasmFuncType; callback: WasmtimeCallback;
    data: pointer): ptr WasmtimeError {.
    importc: "shell_wasmtime_linker_define_func", header: WasmtimeHeader.}
proc wasmtimeLinkerInstantiate*(linker: ptr WasmtimeLinker;
    context: ptr WasmtimeContext; module: ptr WasmtimeModule;
    instance: ptr WasmtimeInstance; trap: ptr ptr WasmTrap): ptr WasmtimeError {.
    importc: "wasmtime_linker_instantiate", header: WasmtimeHeader.}
proc wasmtimeInstanceExportGet*(context: ptr WasmtimeContext;
    instance: ptr WasmtimeInstance; name: cstring; nameLen: csize_t;
    item: ptr WasmtimeExtern): bool {.importc: "wasmtime_instance_export_get",
    header: WasmtimeHeader.}
proc wasmtimeExternDelete*(item: ptr WasmtimeExtern) {.
    importc: "wasmtime_extern_delete", header: WasmtimeHeader.}
proc wasmtimeFuncCall*(context: ptr WasmtimeContext; function: ptr WasmtimeFunc;
    args: ptr WasmtimeVal; nargs: csize_t; results: ptr WasmtimeVal;
    nresults: csize_t; trap: ptr ptr WasmTrap): ptr WasmtimeError {.
    importc: "wasmtime_func_call", header: WasmtimeHeader.}
proc wasmtimeCallerExportGet*(caller: ptr WasmtimeCaller; name: cstring;
    nameLen: csize_t; item: ptr WasmtimeExtern): bool {.
    importc: "wasmtime_caller_export_get", header: WasmtimeHeader.}
proc wasmtimeCallerContext*(caller: ptr WasmtimeCaller): ptr WasmtimeContext {.
    importc: "wasmtime_caller_context", header: WasmtimeHeader.}
proc wasmtimeMemoryData*(context: ptr WasmtimeContext;
    memory: ptr WasmtimeMemory): ptr uint8 {.importc: "wasmtime_memory_data",
    header: WasmtimeHeader.}
proc wasmtimeMemoryDataSize*(context: ptr WasmtimeContext;
    memory: ptr WasmtimeMemory): csize_t {.
    importc: "wasmtime_memory_data_size", header: WasmtimeHeader.}
proc wasmFuncTypeDelete*(functionType: ptr WasmFuncType) {.
    importc: "wasm_functype_delete", header: WasmtimeHeader.}

proc wasmtimeErrorMessage*(error: ptr WasmtimeError;
    output: ptr WasmByteVec) {.importc: "wasmtime_error_message",
    header: WasmtimeHeader.}
proc wasmtimeErrorDelete*(error: ptr WasmtimeError) {.
    importc: "wasmtime_error_delete", header: WasmtimeHeader.}
proc wasmtimeTrapCode*(trap: ptr WasmTrap; code: ptr uint8): bool {.
    importc: "wasmtime_trap_code", header: WasmtimeHeader.}
proc wasmTrapMessage*(trap: ptr WasmTrap; output: ptr WasmByteVec) {.
    importc: "wasm_trap_message", header: WasmtimeHeader.}
proc wasmTrapDelete*(trap: ptr WasmTrap) {.importc: "wasm_trap_delete",
    header: WasmtimeHeader.}
proc wasmByteVecDelete*(bytes: ptr WasmByteVec) {.
    importc: "wasm_byte_vec_delete", header: WasmtimeHeader.}
## Test-fixture conversion only. Never pass untrusted or production input to
## the WAT parser; production module admission accepts binary Wasm bytes only.
proc wasmtimeWat2Wasm*(wat: cstring; watLen: csize_t;
    output: ptr WasmByteVec): ptr WasmtimeError {.
    importc: "wasmtime_wat2wasm", header: WasmtimeHeader.}

proc shellWasmtimeAbiOk*(): cint {.importc: "shell_wasmtime_abi_ok",
    header: WasmtimeHeader.}
proc shellWasmtimeFuncSize*(): csize_t {.
    importc: "shell_wasmtime_func_size", header: WasmtimeHeader.}
proc shellWasmtimeInstanceSize*(): csize_t {.
    importc: "shell_wasmtime_instance_size", header: WasmtimeHeader.}
proc shellWasmtimeMemorySize*(): csize_t {.
    importc: "shell_wasmtime_memory_size", header: WasmtimeHeader.}
proc shellWasmtimeValRawSize*(): csize_t {.
    importc: "shell_wasmtime_val_raw_size", header: WasmtimeHeader.}
proc shellWasmtimeValRawAlignment*(): csize_t {.
    importc: "shell_wasmtime_val_raw_alignment", header: WasmtimeHeader.}
proc shellWasmtimeVersion*(): cstring {.importc: "shell_wasmtime_version",
    header: WasmtimeHeader.}
proc shellWasmtimeValI32Set*(value: ptr WasmtimeVal; number: int32) {.
    importc: "shell_wasmtime_val_i32_set", header: WasmtimeHeader.}
proc shellWasmtimeValI32Get*(value: ptr WasmtimeVal): int32 {.
    importc: "shell_wasmtime_val_i32_get", header: WasmtimeHeader.}
proc shellWasmtimeValI64Set*(value: ptr WasmtimeVal; number: int64) {.
    importc: "shell_wasmtime_val_i64_set", header: WasmtimeHeader.}
proc shellWasmtimeExternKind*(item: ptr WasmtimeExtern): uint8 {.
    importc: "shell_wasmtime_extern_kind", header: WasmtimeHeader.}
proc shellWasmtimeExternFunc*(item: ptr WasmtimeExtern): ptr WasmtimeFunc {.
    importc: "shell_wasmtime_extern_func", header: WasmtimeHeader.}
proc shellWasmtimeExternMemory*(item: ptr WasmtimeExtern): ptr WasmtimeMemory {.
    importc: "shell_wasmtime_extern_memory", header: WasmtimeHeader.}
proc shellWasmtimeEmitFuncType*(): ptr WasmFuncType {.
    importc: "shell_wasmtime_emit_functype", header: WasmtimeHeader.}
proc shellWasmtimeLogFuncType*(): ptr WasmFuncType {.
    importc: "shell_wasmtime_log_functype", header: WasmtimeHeader.}
proc shellWasmtimeReachableFuncType*(): ptr WasmFuncType {.
    importc: "shell_wasmtime_reachable_functype", header: WasmtimeHeader.}
proc shellWasmtimeCoverFuncType*(): ptr WasmFuncType {.
    importc: "shell_wasmtime_cover_functype", header: WasmtimeHeader.}
