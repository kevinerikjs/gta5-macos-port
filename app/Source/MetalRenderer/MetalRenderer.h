#pragma once
#include <stdint.h>
#include <stdbool.h>
#ifdef __cplusplus
extern "C" {
#endif
// Native Metal renderer (Source/MetalRenderer): executes the game's graphics command ring directly on Metal.
bool PGMetalRendererAvailable(void);
void PGMetalRendererAttachLayer(void *layer);
void PGStartMetalRenderer(void *memory, uint64_t memorySize, uint64_t ring, uint64_t ringSize);
double PGMetalRendererFPS(void);
void PGMetalRendererCapture(const char *name);
void PGMetalRendererSetUpscaling(int on);
// Each picture stays on screen at least this long (0: as the frame limiter allows). 1/40 s gives an even 40 FPS on a 120 Hz screen.
void PGMetalRendererSetPresentInterval(double seconds);
#ifdef __cplusplus
}
#endif
