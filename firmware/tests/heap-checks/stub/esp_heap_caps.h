#pragma once
#include <cstdint>
#define MALLOC_CAP_INTERNAL 0x0001
extern bool stubIntegrityOk;
extern bool stubSawInternal;
bool heap_caps_check_integrity(uint32_t caps, bool print_errors);
