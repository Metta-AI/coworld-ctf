(module
  (memory (export "memory") 1)
  (func (export "play_alloc") (param i32) (result i32) i32.const 1)
  (func (export "play_manifest"))
  (func (export "play_init") (param i32 i32 i32 i32) (result i32) i32.const 0)
  (func (export "play_step") (param i32 i32) (result i32) i32.const 0))
