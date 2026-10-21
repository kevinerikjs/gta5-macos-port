#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
void PGCaptureNativeFrame(const char *name);
double PGRenderedFramesPerSecond(void);
void PGAttachMetalLayer(void *layer);
void PGStartGraphics(void *memory,uint64_t memorySize,uint64_t ring,uint64_t ringSize,uint64_t debug);
// The GPU samples BC textures as they are (otherwise they are decoded, about 4 times larger).
int PGGPUReadsBC(void);
// GPU bytes per budgeted byte of BC textures, in percent, from earlier sessions on this device (GTA-123), and the
// renderer's live numbers that keep it current.
int PGTextureRatioPercent(void);
void PGNoteTextureRatio(int64_t gpuBytes, int64_t gameBytes);
// Settings › Sharper upscaling: MetalFX scales the picture to the screen's resolution (changes live).
void PGSetSharperUpscaling(int on);
// Frame rate 40 (ProMotion screens): each picture stays up at least this long; 0 for the other frame rates.
void PGSetPresentInterval(double seconds);
#ifdef __cplusplus
}
#endif
