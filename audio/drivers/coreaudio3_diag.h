/* Manic MP: counters the CoreAudio3 driver keeps for the session log.
 *
 * The frame logger in ui/drivers/ui_cocoatouch.m reads them once per
 * emulator iteration to say whether a long frame also starved the audio
 * output (an audible gap) and how much of each frame was spent waiting for
 * room in the output buffer rather than running the core. */

#ifndef __COREAUDIO3_DIAG_H
#define __COREAUDIO3_DIAG_H

#include <stdint.h>
#include <retro_common_api.h>

RETRO_BEGIN_DECLS

typedef struct coreaudio3_diag
{
   /* render callbacks that found fewer samples than the hardware asked for */
   uint64_t underruns;
   /* stereo frames of silence those callbacks had to produce */
   uint64_t silent_frames;
   /* microseconds the writer (the emulator thread) spent blocked for room */
   uint64_t blocked_usec;
} coreaudio3_diag_t;

/* Totals since the driver was first loaded; callers keep their own deltas. */
void coreaudio3_diag_read(coreaudio3_diag_t *out);

RETRO_END_DECLS

#endif
