(module
  (import "play" "nearest_reachable" (func $nearest (param i32 i32) (result i64)))
  (memory (export "memory") 1 16)
  (func (export "play_alloc") (param i32) (result i32) i32.const 1)
  (func (export "play_manifest") i32.const 0 i32.const 0 call $nearest drop)
  (func (export "play_init") (param i32 i32 i32 i32) (result i32) i32.const 0)
  (func (export "play_step") (param i32 i32) (result i32) i32.const 0))
