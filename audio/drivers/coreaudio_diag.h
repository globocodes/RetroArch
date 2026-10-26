/* Manic MP: counters the CoreAudio output drivers keep for the session log.
 *
 * Both Apple drivers feed them: coreaudio.c (the AudioUnit driver the iOS
 * build compiles, HAVE_COREAUDIO) and coreaudio3.m (the AVAudioEngine driver
 * the macOS build adds, HAVE_COREAUDIO3). The totals live in coreaudio_diag.c,
 * which griffin.c compiles on every Apple build, so the frame logger in
 * ui/drivers/ui_cocoatouch.m links whichever driver is in.
 *
 * The frame logger reads them once per emulator iteration to say whether a
 * long frame also starved the audio output (an audible gap) and how much of
 * each frame was spent waiting for room in the output buffer rather than
 * running the core. */

#ifndef __COREAUDIO_DIAG_H
#define __COREAUDIO_DIAG_H

#include <stdint.h>
#include <retro_common_api.h>

RETRO_BEGIN_DECLS

typedef struct coreaudio_diag
{
   /* render callbacks that found fewer samples than the hardware asked for */
   uint64_t underruns;
   /* stereo frames of silence those callbacks had to produce */
   uint64_t silent_frames;
   /* microseconds the writer (the emulator thread) spent blocked for room */
   uint64_t blocked_usec;
} coreaudio_diag_t;

/* Totals since the process started; callers keep their own deltas. */
void coreaudio_diag_read(coreaudio_diag_t *out);

/* Called by a driver's render callback when it had to fill silence. */
void coreaudio_diag_underrun(uint64_t silent_frames);

/* Called by a driver's write path after it blocked waiting for room. */
void coreaudio_diag_blocked(uint64_t usec);

RETRO_END_DECLS

#endif
