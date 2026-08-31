#ifndef CTF_RUNTIME_SPIKE_HELLO_IMPORTS_H
#define CTF_RUNTIME_SPIKE_HELLO_IMPORTS_H

#include <stdint.h>

__attribute__((__import_module__("play"), __import_name__("emit")))
int32_t play_emit(int32_t ptr, int32_t len);

#endif
