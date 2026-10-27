/* Manic MP: where the time inside one frontend iteration goes, for the
 * session log's frame logger (ui/drivers/ui_cocoatouch.m).
 *
 * An iteration (runloop_iterate) is mostly one core_run(): the core's
 * retro_run(), inside which the core calls back into the frontend to present
 * video (video_driver_frame -> the video driver's frame(), which on iOS waits
 * for the Vulkan swapchain, i.e. for vsync) and to write audio (which blocks
 * when the output buffer is full - counted in coreaudio_diag). So a 52 ms
 * iteration at 60 Hz is three display slots, and only these totals say
 * whether the core itself overran by 17 or by 35 ms before the present
 * absorbed the rest.
 *
 * Totals since the process started, written and read on the emulator thread;
 * atomics only so a reader on another thread never sees a torn value. */

#ifndef __MANIC_FRAME_TIMING_H
#define __MANIC_FRAME_TIMING_H

#include <stdint.h>
#include <retro_common_api.h>

RETRO_BEGIN_DECLS

typedef struct manic_frame_timing
{
   /* microseconds spent inside the core's retro_run() */
   uint64_t core_usec;
   /* microseconds spent inside the video driver's frame() (present/vsync) */
   uint64_t video_usec;
   /* how many times frame() was called */
   uint64_t video_frames;
} manic_frame_timing_t;

void manic_frame_timing_read(manic_frame_timing_t *out);

/* Called by core_run() around retro_run(). */
void manic_frame_timing_core(uint64_t usec);

/* Called by video_driver_frame() around the driver's frame(). */
void manic_frame_timing_video(uint64_t usec);

RETRO_END_DECLS

#endif
