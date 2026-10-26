/* Manic MP: see coreaudio_diag.h. Written from the audio render thread
 * (underruns) and the emulator thread (blocked time), read from the emulator
 * thread, so each total is a relaxed atomic. */

#include <stdatomic.h>

#include "coreaudio_diag.h"

static _Atomic uint64_t g_diag_underruns;
static _Atomic uint64_t g_diag_silent_frames;
static _Atomic uint64_t g_diag_blocked_usec;

void coreaudio_diag_read(coreaudio_diag_t *out)
{
   out->underruns     = atomic_load_explicit(&g_diag_underruns,     memory_order_relaxed);
   out->silent_frames = atomic_load_explicit(&g_diag_silent_frames, memory_order_relaxed);
   out->blocked_usec  = atomic_load_explicit(&g_diag_blocked_usec,  memory_order_relaxed);
}

void coreaudio_diag_underrun(uint64_t silent_frames)
{
   atomic_fetch_add_explicit(&g_diag_underruns, 1, memory_order_relaxed);
   atomic_fetch_add_explicit(&g_diag_silent_frames, silent_frames, memory_order_relaxed);
}

void coreaudio_diag_blocked(uint64_t usec)
{
   atomic_fetch_add_explicit(&g_diag_blocked_usec, usec, memory_order_relaxed);
}
