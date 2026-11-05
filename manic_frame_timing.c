/* Manic MP: see manic_frame_timing.h. Compiled on every Apple build from
 * griffin.c (and Makefile.common with HAVE_COREAUDIO). */

#include <stdatomic.h>
#include <string.h>
#include <pthread.h>

#include "manic_frame_timing.h"

static _Atomic uint64_t g_core_usec;
static _Atomic uint64_t g_video_usec;
static _Atomic uint64_t g_video_frames;
static _Atomic uint64_t g_video_dupes;

void manic_frame_timing_read(manic_frame_timing_t *out)
{
   out->core_usec    = atomic_load_explicit(&g_core_usec,    memory_order_relaxed);
   out->video_usec   = atomic_load_explicit(&g_video_usec,   memory_order_relaxed);
   out->video_frames = atomic_load_explicit(&g_video_frames, memory_order_relaxed);
   out->video_dupes  = atomic_load_explicit(&g_video_dupes,  memory_order_relaxed);
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

void manic_frame_timing_video_dupe(void)
{
   atomic_fetch_add_explicit(&g_video_dupes, 1, memory_order_relaxed);
}

/* The presented times arrive on a thread of the system's choosing, the
 * logger takes the window on the main thread: one short lock, 60 times a
 * second. */
static pthread_mutex_t       g_present_lock = PTHREAD_MUTEX_INITIALIZER;
static manic_frame_present_t g_present;
static uint64_t              g_present_last_usec;      /* last shown frame, kept across windows */
static uint64_t              g_present_held_last_usec; /* last held frame of this window */
static _Atomic uint32_t      g_present_slot_usec = 16667;

void manic_frame_present_set_refresh(float hz)
{
   if (hz >= 1.0f)
      atomic_store_explicit(&g_present_slot_usec,
            (uint32_t)(1000000.0f / hz), memory_order_relaxed);
}

void manic_frame_presented(double presented_time)
{
   uint64_t slot = atomic_load_explicit(&g_present_slot_usec, memory_order_relaxed);

   pthread_mutex_lock(&g_present_lock);
   if (!(presented_time > 0.0))
      g_present.never_shown++;
   else
   {
      uint64_t now = (uint64_t)(presented_time * 1000000.0);
      g_present.shown++;
      if (g_present_last_usec && now > g_present_last_usec)
      {
         uint64_t d = now - g_present_last_usec;
         if (d < 1000000)   /* a pause or a moved view is not a held frame */
         {
            g_present.intervals++;
            g_present.interval_sum_usec += d;
            if (d > g_present.interval_max_usec)
               g_present.interval_max_usec = (uint32_t)d;
            if (d * 2 >= slot * 3)
            {
               g_present.held++;
               if (g_present_held_last_usec)
               {
                  g_present.held_gap_sum_usec += now - g_present_held_last_usec;
                  g_present.held_gaps++;
               }
               g_present_held_last_usec = now;
            }
            else if (d * 2 < slot)
               g_present.quick++;
         }
      }
      if (now > g_present_last_usec)
         g_present_last_usec = now;
   }
   pthread_mutex_unlock(&g_present_lock);
}

void manic_frame_present_take(manic_frame_present_t *out)
{
   pthread_mutex_lock(&g_present_lock);
   if (out)
      *out = g_present;
   memset(&g_present, 0, sizeof(g_present));
   g_present_held_last_usec = 0;
   pthread_mutex_unlock(&g_present_lock);
}
