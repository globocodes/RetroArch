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
   /* of those, calls with no new picture (the core duped the last frame) */
   uint64_t video_dupes;
} manic_frame_timing_t;

void manic_frame_timing_read(manic_frame_timing_t *out);

/* Called by core_run() around retro_run(). */
void manic_frame_timing_core(uint64_t usec);

/* Called by video_driver_frame() around the driver's frame(). */
void manic_frame_timing_video(uint64_t usec);

/* Called by video_driver_frame() when the core passed no picture (NULL data). */
void manic_frame_timing_video_dupe(void);

/* Which screen the game's CAMetalLayer presents on, as the app names it
 * ("device", or "AirPlay 1920x1080 @ 60 Hz"): the present time above is the
 * swapchain wait on whichever screen the layer sits on, so the frame logger
 * (ui/drivers/ui_cocoatouch.m) tags every "[Frame] Stats" window with this.
 * Set from the main thread by -[LibretroCore setDiagnosticsScreen:] when the
 * app moves the view; read on the main thread by the logger. Defaults to
 * "device". */
void manic_frame_set_present_screen(const char *name);

/* What the screen did with the frames after the present call, which the
 * totals above cannot see: every drawable the game's CAMetalLayer hands out
 * reports back the host time at which the screen showed it (MTLDrawable
 * presentedTime, ui/drivers/ui_cocoatouch.m). Counts for one "[Frame] Stats"
 * window. */
typedef struct manic_frame_present
{
   /* drawables the screen reported a presented time for */
   uint32_t shown;
   /* drawables that came back without one: never put on the screen */
   uint32_t never_shown;
   /* intervals between consecutive shown frames (breaks over 1 s left out) */
   uint32_t intervals;
   uint64_t interval_sum_usec;
   uint32_t interval_max_usec;
   /* intervals of 1.5 refreshes or more: the frame before stayed up for two
    * or more refreshes of that screen */
   uint32_t held;
   /* spacing between consecutive held frames */
   uint32_t held_gaps;
   uint64_t held_gap_sum_usec;
   /* intervals under half a refresh: the frame before was replaced early */
   uint32_t quick;
} manic_frame_present_t;

/* Called from the drawable's presented handler (any thread).
 * presented_time is in seconds of host time, 0 when it was never shown. */
void manic_frame_presented(double presented_time);

/* The refresh rate of the screen the layer is on, for the 1.5 and 0.5 refresh
 * limits above. Set by the Vulkan context (main thread). */
void manic_frame_present_set_refresh(float hz);

/* Copies the counts of the window that just ended and starts a new one. */
void manic_frame_present_take(manic_frame_present_t *out);

/* The Vulkan context reports the swapchain it just (re)created, in pixels.
 * The frame logger prints the size in every "[Frame] Stats" line and logs a
 * line when it changes (ui/drivers/ui_cocoatouch.m). Main thread. */
void manic_frame_swapchain_changed(unsigned width, unsigned height);

RETRO_END_DECLS

#endif
