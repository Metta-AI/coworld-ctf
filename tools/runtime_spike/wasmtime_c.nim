## Minimal Wasmtime v48 C-API surface used by the runtime spike.
##
## Ownership follows the v48.0.1 headers: configs are consumed by engine
## creation; errors, traps, linkers, stores, modules, and engines are explicit.

const WasmtimeHeader* = "wasmtime_shim.h"

type
  WasmConfig* {.importc: "wasm_config_t", header: WasmtimeHeader.} = object
  WasmEngine* {.importc: "wasm_engine_t", header: WasmtimeHeader.} = object
  WasmFuncType* {.importc: "wasm_functype_t", header: WasmtimeHeader.} = object
  WasmImportType* {.importc: "wasm_importtype_t", header: WasmtimeHeader.} = object
  WasmTrap* {.importc: "wasm_trap_t", header: WasmtimeHeader.} = object
  WasmtimeContext* {.importc: "wasmtime_context_t", header: WasmtimeHeader.} = object
  WasmtimeError* {.importc: "wasmtime_error_t", header: WasmtimeHeader.} = object
  WasmtimeExtern* {.importc: "wasmtime_extern_t", header: WasmtimeHeader.} = object
  WasmtimeFunc* {.importc: "wasmtime_func_t", header: WasmtimeHeader.} = object
  WasmtimeInstance* {.importc: "wasmtime_instance_t", header: WasmtimeHeader.} = object
  WasmtimeLinker* {.importc: "wasmtime_linker_t", header: WasmtimeHeader.} = object
  WasmtimeMemory* {.importc: "wasmtime_memory_t", header: WasmtimeHeader.} = object
  WasmtimeModule* {.importc: "wasmtime_module_t", header: WasmtimeHeader.} = object
  WasmtimeCaller* {.importc: "wasmtime_caller_t", header: WasmtimeHeader.} = object
  WasmtimePoolingConfig* {.importc: "wasmtime_pooling_allocation_config_t",
      header: WasmtimeHeader.} = object
  WasmtimeStore* {.importc: "wasmtime_store_t", header: WasmtimeHeader.} = object
  WasmtimeVal* {.importc: "wasmtime_val_t", header: WasmtimeHeader.} = object
  WasmtimeConstVal* {.importc: "const wasmtime_val_t",
      header: WasmtimeHeader.} = object

  WasmByteVec* {.importc: "wasm_byte_vec_t", header: WasmtimeHeader, bycopy.} = object
    size*: csize_t
    data*: ptr uint8

  WasmImportTypeVec* {.importc: "wasm_importtype_vec_t", header: WasmtimeHeader,
      bycopy.} = object
    size*: csize_t
    data*: ptr ptr WasmImportType

  WasmtimeCallback* = proc(env: pointer; caller: ptr WasmtimeCaller;
      args: ptr WasmtimeConstVal; nargs: csize_t; results: ptr WasmtimeVal;
      nresults: csize_t): ptr WasmTrap {.cdecl.}

const
  WasmtimeI32* = 0'u8
  WasmtimeI64* = 1'u8
  WasmtimeExternFunc* = 0'u8
  WasmtimeExternMemory* = 3'u8
  WasmtimeStrategyCranelift* = 1'u8
  TrapStackOverflow* = 0'u8
  TrapMemoryOutOfBounds* = 1'u8
  TrapInterrupt* = 10'u8
  TrapOutOfFuel* = 11'u8

proc wasmConfigNew*(): ptr WasmConfig {.importc: "wasm_config_new",
    header: WasmtimeHeader.}
proc wasmEngineNewWithConfig*(config: ptr WasmConfig): ptr WasmEngine {.
    importc: "wasm_engine_new_with_config", header: WasmtimeHeader.}
proc wasmEngineDelete*(engine: ptr WasmEngine) {.importc: "wasm_engine_delete",
    header: WasmtimeHeader.}

proc wasmtimeConfigConsumeFuelSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_consume_fuel_set", header: WasmtimeHeader.}
proc wasmtimeConfigEpochInterruptionSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_epoch_interruption_set", header: WasmtimeHeader.}
proc wasmtimeConfigMaxWasmStackSet*(config: ptr WasmConfig; size: csize_t) {.
    importc: "wasmtime_config_max_wasm_stack_set", header: WasmtimeHeader.}
proc wasmtimeConfigStrategySet*(config: ptr WasmConfig; strategy: uint8) {.
    importc: "wasmtime_config_strategy_set", header: WasmtimeHeader.}
proc wasmtimeConfigParallelCompilationSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_parallel_compilation_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigCraneliftNanCanonicalizationSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_cranelift_nan_canonicalization_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigMemoryMayMoveSet*(config: ptr WasmConfig; enabled: bool) {.
    importc: "wasmtime_config_memory_may_move_set", header: WasmtimeHeader.}
proc wasmtimeConfigMemoryReservationSet*(config: ptr WasmConfig; size: uint64) {.
    importc: "wasmtime_config_memory_reservation_set", header: WasmtimeHeader.}
proc wasmtimeConfigMemoryGuardSizeSet*(config: ptr WasmConfig; size: uint64) {.
    importc: "wasmtime_config_memory_guard_size_set", header: WasmtimeHeader.}
proc wasmtimeConfigSignalsBasedTrapsSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_signals_based_traps_set",
    header: WasmtimeHeader.}
proc wasmtimeConfigMacosUseMachPortsSet*(config: ptr WasmConfig;
    enabled: bool) {.importc: "wasmtime_config_macos_use_mach_ports_set",
    header: WasmtimeHeader.}

proc wasmtimePoolingConfigNew*(): ptr WasmtimePoolingConfig {.
    importc: "wasmtime_pooling_allocation_config_new", header: WasmtimeHeader.}
proc wasmtimePoolingConfigDelete*(pool: ptr WasmtimePoolingConfig) {.
    importc: "wasmtime_pooling_allocation_config_delete", header: WasmtimeHeader.}
proc wasmtimePoolingTotalCoreInstancesSet*(pool: ptr WasmtimePoolingConfig;
    count: uint32) {.importc:
    "wasmtime_pooling_allocation_config_total_core_instances_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingTotalMemoriesSet*(pool: ptr WasmtimePoolingConfig;
    count: uint32) {.importc:
    "wasmtime_pooling_allocation_config_total_memories_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingMaxMemoriesPerModuleSet*(pool: ptr WasmtimePoolingConfig;
    count: uint32) {.importc:
    "wasmtime_pooling_allocation_config_max_memories_per_module_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingMaxMemorySizeSet*(pool: ptr WasmtimePoolingConfig;
    size: csize_t) {.importc:
    "wasmtime_pooling_allocation_config_max_memory_size_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingLinearMemoryKeepResidentSet*(pool: ptr WasmtimePoolingConfig;
    size: csize_t) {.importc:
    "wasmtime_pooling_allocation_config_linear_memory_keep_resident_set",
    header: WasmtimeHeader.}
proc wasmtimePoolingAllocationStrategySet*(config: ptr WasmConfig;
    pool: ptr WasmtimePoolingConfig) {.importc:
    "wasmtime_pooling_allocation_strategy_set", header: WasmtimeHeader.}

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
proc wasmtimeContextGetFuel*(context: ptr WasmtimeContext;
    fuel: ptr uint64): ptr WasmtimeError {.importc: "wasmtime_context_get_fuel",
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
proc wasmtimeModuleImports*(module: ptr WasmtimeModule;
    output: ptr WasmImportTypeVec) {.importc: "wasmtime_module_imports",
    header: WasmtimeHeader.}
proc wasmtimeModuleDelete*(module: ptr WasmtimeModule) {.
    importc: "wasmtime_module_delete", header: WasmtimeHeader.}

proc wasmtimeLinkerNew*(engine: ptr WasmEngine): ptr WasmtimeLinker {.
    importc: "wasmtime_linker_new", header: WasmtimeHeader.}
proc wasmtimeLinkerDelete*(linker: ptr WasmtimeLinker) {.
    importc: "wasmtime_linker_delete", header: WasmtimeHeader.}
proc runtimeSpikeLinkerDefineFunc*(linker: ptr WasmtimeLinker; module: cstring;
    moduleLen: csize_t; name: cstring; nameLen: csize_t;
    functionType: ptr WasmFuncType; callback: WasmtimeCallback;
    data: pointer): ptr WasmtimeError {.
    importc: "runtime_spike_linker_define_func", header: WasmtimeHeader.}
proc wasmtimeLinkerInstantiate*(linker: ptr WasmtimeLinker;
    context: ptr WasmtimeContext; module: ptr WasmtimeModule;
    instance: ptr WasmtimeInstance; trap: ptr ptr WasmTrap): ptr WasmtimeError {.
    importc: "wasmtime_linker_instantiate", header: WasmtimeHeader.}
proc wasmtimeInstanceNew*(context: ptr WasmtimeContext;
    module: ptr WasmtimeModule; imports: pointer; importCount: csize_t;
    instance: ptr WasmtimeInstance; trap: ptr ptr WasmTrap): ptr WasmtimeError {.
    importc: "wasmtime_instance_new", header: WasmtimeHeader.}
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
proc wasmtimeMemoryData*(context: ptr WasmtimeContext;
    memory: ptr WasmtimeMemory): ptr uint8 {.importc: "wasmtime_memory_data",
    header: WasmtimeHeader.}
proc wasmtimeMemoryDataSize*(context: ptr WasmtimeContext;
    memory: ptr WasmtimeMemory): csize_t {.importc: "wasmtime_memory_data_size",
    header: WasmtimeHeader.}
proc wasmtimeMemorySize*(context: ptr WasmtimeContext;
    memory: ptr WasmtimeMemory): uint64 {.importc: "wasmtime_memory_size",
    header: WasmtimeHeader.}
proc wasmtimeMemoryGrow*(context: ptr WasmtimeContext;
    memory: ptr WasmtimeMemory; delta: uint64; previousSize: ptr uint64):
    ptr WasmtimeError {.importc: "wasmtime_memory_grow",
    header: WasmtimeHeader.}
proc wasmtimeCallerExportGet*(caller: ptr WasmtimeCaller; name: cstring;
    nameLen: csize_t; item: ptr WasmtimeExtern): bool {.
    importc: "wasmtime_caller_export_get", header: WasmtimeHeader.}
proc wasmtimeCallerContext*(caller: ptr WasmtimeCaller): ptr WasmtimeContext {.
    importc: "wasmtime_caller_context", header: WasmtimeHeader.}

proc wasmtimeErrorMessage*(error: ptr WasmtimeError; output: ptr WasmByteVec) {.
    importc: "wasmtime_error_message", header: WasmtimeHeader.}
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
proc wasmImportTypeVecDelete*(imports: ptr WasmImportTypeVec) {.
    importc: "wasm_importtype_vec_delete", header: WasmtimeHeader.}
proc wasmImportTypeModule*(importType: ptr WasmImportType): ptr WasmByteVec {.
    importc: "wasm_importtype_module", header: WasmtimeHeader.}
proc wasmImportTypeName*(importType: ptr WasmImportType): ptr WasmByteVec {.
    importc: "wasm_importtype_name", header: WasmtimeHeader.}
proc wasmFuncTypeDelete*(functionType: ptr WasmFuncType) {.
    importc: "wasm_functype_delete", header: WasmtimeHeader.}

proc runtimeSpikeAbiOk*(): cint {.importc: "runtime_spike_abi_ok",
    header: WasmtimeHeader.}
proc runtimeSpikeValI32Set*(value: ptr WasmtimeVal; number: int32) {.
    importc: "runtime_spike_val_i32_set", header: WasmtimeHeader.}
proc runtimeSpikeValI32Get*(value: ptr WasmtimeVal): int32 {.
    importc: "runtime_spike_val_i32_get", header: WasmtimeHeader.}
proc runtimeSpikeValI64Set*(value: ptr WasmtimeVal; number: int64) {.
    importc: "runtime_spike_val_i64_set", header: WasmtimeHeader.}
proc runtimeSpikeValKind*(value: ptr WasmtimeVal): uint8 {.
    importc: "runtime_spike_val_kind", header: WasmtimeHeader.}
proc runtimeSpikeExternFunc*(item: ptr WasmtimeExtern): ptr WasmtimeFunc {.
    importc: "runtime_spike_extern_func", header: WasmtimeHeader.}
proc runtimeSpikeExternMemory*(item: ptr WasmtimeExtern): ptr WasmtimeMemory {.
    importc: "runtime_spike_extern_memory", header: WasmtimeHeader.}
proc runtimeSpikeExternKind*(item: ptr WasmtimeExtern): uint8 {.
    importc: "runtime_spike_extern_kind", header: WasmtimeHeader.}
proc runtimeSpikeExternMemoryCopy*(memory: ptr WasmtimeMemory;
    item: ptr WasmtimeExtern) {.importc: "runtime_spike_extern_memory_copy",
    header: WasmtimeHeader.}
proc runtimeSpikeProcessMemory*(resident, virtualSize: ptr uint64): cint {.
    importc: "runtime_spike_process_memory", header: WasmtimeHeader.}
proc runtimeSpikeEmitFuncType*(): ptr WasmFuncType {.
    importc: "runtime_spike_emit_functype", header: WasmtimeHeader.}
proc runtimeSpikeCoverFuncType*(): ptr WasmFuncType {.
    importc: "runtime_spike_cover_functype", header: WasmtimeHeader.}
proc runtimeSpikeLogFuncType*(): ptr WasmFuncType {.
    importc: "runtime_spike_log_functype", header: WasmtimeHeader.}
