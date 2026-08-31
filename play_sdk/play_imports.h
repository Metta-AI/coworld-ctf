#ifndef CTF_PLAY_SDK_IMPORTS_H
#define CTF_PLAY_SDK_IMPORTS_H

#include <stdint.h>

__attribute__((__import_module__("play"), __import_name__("emit")))
int32_t play_emit(int32_t ptr, int32_t len);

__attribute__((__import_module__("play"), __import_name__("log")))
void play_log(int32_t level, int32_t ptr, int32_t len);

__attribute__((__import_module__("play"), __import_name__("nearest_reachable")))
int64_t play_nearest_reachable(int32_t x, int32_t y);

__attribute__((__import_module__("play"), __import_name__("nearest_cover")))
int64_t play_nearest_cover(int32_t x, int32_t y, int32_t radius,
                           int32_t bearing_brads, int32_t threats_ptr,
                           int32_t threats_len);

#endif
