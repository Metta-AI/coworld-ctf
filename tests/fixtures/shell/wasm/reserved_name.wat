(module
  (import "play" "emit" (func $emit (param i32 i32) (result i32)))
  (memory (export "memory") 1 16)
  (data (i32.const 0) "{\22abi\22:1,\22class\22:\22controller\22,\22modes\22:[\22br\22],\22name\22:\22default\22,\22params\22:{},\22retune\22:false}")
  (func (export "play_alloc") (param i32) (result i32) i32.const 1)
  (func (export "play_manifest") i32.const 0 i32.const 89 call $emit drop)
  (func (export "play_init") (param i32 i32 i32 i32) (result i32) i32.const 0)
  (func (export "play_step") (param i32 i32) (result i32) i32.const 0))
