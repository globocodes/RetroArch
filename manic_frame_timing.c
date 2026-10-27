/* Manic MP: see manic_frame_timing.h. Compiled on every Apple build from
 * griffin.c (and Makefile.common with HAVE_COREAUDIO). */

#include <stdatomic.h>

#include "manic_frame_timing.h"

static _Atomic uint64_t g_core_usec;
static _Atomic uint64_t g_video_usec;
static _Atomic uint64_t g_video_frames;

void manic_frame_timing_read(manic_frame_timing_t *out)
{
   out->core_usec    = atomic_load_explicit(&g_core_usec,    memory_order_relaxed);
   out->video_usec   = atomic_load_explicit(&g_video_usec,   memory_order_relaxed);
   out->video_frames = atomic_load_explicit(&g_video_frames, memory_order_relaxed);
}

void manic_frame_timing_core(uint64_t usec)
{
   atomic_fetch_add_explicit(&g_core_usec, usec, memory_order_relaxed);
}

void manic_frame_timing_video(uint64_t usec)
{
   atomic_fetch_add_explicit(&g_video_usec, usec, memory_order_relaxed);
   atomic_fetch_add_explicit(&g_video_frames, 1, memory_order_relaxed);
}
