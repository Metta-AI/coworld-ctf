(module
  (import "play" "emit" (func $emit (param i32 i32) (result i32)))
  (memory (export "memory") 1 16)
  (func (export "play_alloc") (param i32) (result i32) i32.const 1)
  (func (export "play_manifest")
    i32.const 65530 i32.const 87 call $emit drop)
  (func (export "play_init") (param i32 i32 i32 i32) (result i32) i32.const 0)
  (func (export "play_step") (param i32 i32) (result i32) i32.const 0))
