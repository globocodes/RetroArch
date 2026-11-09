/*  RetroArch - A frontend for libretro.
 *  Copyright (C) 2013-2014 - Jason Fetters
 *  Copyright (C) 2011-2017 - Daniel De Matteis
 *
 *  RetroArch is free software: you can redistribute it and/or modify it under the terms
 *  of the GNU General Public License as published by the Free Software Found-
 *  ation, either version 3 of the License, or (at your option) any later version.
 *
 *  RetroArch is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
 *  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR
 *  PURPOSE.  See the GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License along with RetroArch.
 *  If not, see <http://www.gnu.org/licenses/>.
 */

#ifdef HAVE_CONFIG_H
#include "../../config.h"
#endif

#if TARGET_OS_IPHONE
#include <CoreGraphics/CoreGraphics.h>
#else
#include <ApplicationServices/ApplicationServices.h>
#endif
#ifdef OSX
#include <AppKit/NSScreen.h>
#endif

#include <math.h>

#include <retro_timers.h>
#include <features/features_cpu.h>
#include <compat/apple_compat.h>
#include <string/stdstring.h>

#include "../../ui/drivers/ui_cocoa.h"
#include "../../ui/drivers/cocoa/cocoa_common.h"
#include "../../ui/drivers/cocoa/apple_platform.h"
#include "../../configuration.h"
#include "../../retroarch.h"
#include "../../verbosity.h"
#include "../common/vulkan_common.h"
#include "../../manic_frame_timing.h"
#ifdef HAVE_METAL
#include "../common/metal_common.h"
#endif

typedef struct cocoa_vk_ctx_data
{
   gfx_ctx_vulkan_data_t vk;
   int swap_interval;
   unsigned width;
   unsigned height;
   /* Manic MP: a new view size waits until it has held for two checks and
    * COCOA_VK_RESIZE_SETTLE_USEC before it becomes a resize, see
    * cocoa_vk_gfx_ctx_check_window. */
   unsigned pending_width;
   unsigned pending_height;
   retro_time_t pending_since;
} cocoa_vk_ctx_data_t;

/* Manic MP: how long a new view size has to hold before the swapchain is
 * recreated for it. The 2026-11-08 AirPlay session logged, at the connect,
 * 2185x1640 -> 3278x2460 -> 1920x1080 within 22 ms: the view had joined the
 * AirPlay window (so its container's 1.5x transform applied) but had not been
 * laid out at the core's size yet, and two consecutive checks both saw the
 * transient. 50 ms spans a layout pass at 60 Hz with room to spare and costs
 * nothing visible: the old swapchain keeps presenting meanwhile. */
#define COCOA_VK_RESIZE_SETTLE_USEC 50000

/* TODO/FIXME - static globals */
static unsigned g_vk_minor          = 0;
static unsigned g_vk_major          = 0;
/* Forward declaration */
CocoaView *cocoaview_get(void);

static uint32_t cocoa_vk_gfx_ctx_get_flags(void *data)
{
   uint32_t flags = 0;
#if defined(HAVE_SLANG) && defined(HAVE_SPIRV_CROSS)
   BIT32_SET(flags, GFX_CTX_FLAGS_SHADERS_SLANG);
#endif
   return flags;
}

static void cocoa_vk_gfx_ctx_set_flags(void *data, uint32_t flags) { }

static void cocoa_vk_gfx_ctx_destroy(void *data)
{
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;

   if (!cocoa_ctx)
      return;

   vulkan_context_destroy(&cocoa_ctx->vk, cocoa_ctx->vk.vk_surface != VK_NULL_HANDLE);
   if (cocoa_ctx->vk.context.queue_lock)
      slock_free(cocoa_ctx->vk.context.queue_lock);
   memset(&cocoa_ctx->vk, 0, sizeof(cocoa_ctx->vk));

   free(cocoa_ctx);
}

static enum gfx_ctx_api cocoa_vk_gfx_ctx_get_api(void *data) { return GFX_CTX_VULKAN_API; }

static bool cocoa_vk_gfx_ctx_suppress_screensaver(void *data, bool disable)
{
    return [apple_platform setDisableDisplaySleep:disable];
}

static void cocoa_vk_gfx_ctx_input_driver(void *data,
      const char *name,
      input_driver_t **input, void **input_data)
{
   *input      = NULL;
   *input_data = NULL;
}

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
/* NOTE: convertRectToBacking only available on MacOS X 10.7 and up.
 * Therefore, make specialized version of this function instead of
 * going through a selector for every call. */
static void cocoa_vk_gfx_ctx_get_video_size_osx10_7_and_up(void *data,
      unsigned* width, unsigned* height)
{
   CocoaView *g_view               = cocoaview_get();
   CGRect _cgrect                  = NSRectToCGRect(g_view.frame);
   CGRect bounds                   = CGRectMake(0, 0, CGRectGetWidth(_cgrect), CGRectGetHeight(_cgrect));
   CGRect cgrect                   = NSRectToCGRect([g_view convertRectToBacking:bounds]);
   GLsizei backingPixelWidth       = CGRectGetWidth(cgrect);
   GLsizei backingPixelHeight      = CGRectGetHeight(cgrect);
   CGRect size                     = CGRectMake(0, 0, backingPixelWidth, backingPixelHeight);
   *width                          = CGRectGetWidth(size);
   *height                         = CGRectGetHeight(size);
}
#elif defined(OSX)
static void cocoa_vk_gfx_ctx_get_video_size(void *data,
      unsigned* width, unsigned* height)
{
   CocoaView *g_view               = cocoaview_get();
   CGRect cgrect                   = NSRectToCGRect([g_view frame]);
   GLsizei backingPixelWidth       = CGRectGetWidth(cgrect);
   GLsizei backingPixelHeight      = CGRectGetHeight(cgrect);
   CGRect size                     = CGRectMake(0, 0, backingPixelWidth, backingPixelHeight);
   *width                          = CGRectGetWidth(size);
   *height                         = CGRectGetHeight(size);
}
#else
/* Manic MP: the screen the render view is on. The app moves the view into the
 * window of an external (AirPlay) screen and back, so this is not always the
 * main screen. NULL while the view is in no window. */
static UIScreen *cocoa_vk_view_screen(void)
{
    UIView   *view   = apple_platform.renderView;
    UIWindow *window = view.window;
    if (!window)
        return nil;
    if (@available(iOS 13.0, tvOS 13.0, *))
    {
        UIScreen *screen = window.windowScene.screen;
        if (screen)
            return screen;
    }
    return [UIScreen mainScreen];
}

/* Manic MP: pixels of that screen per point of the render view. On the
 * device this is the screen's native scale, as before. On the external
 * screen the app lays the view out at the core's size (640x480 pt) inside a
 * container it scales up to the window height, so the factor is the screen's
 * scale times that transform (1 x 2.25): the swapchain then holds exactly
 * the pixels the view covers there (1440x1080) and the compositor has
 * nothing to stretch. Before, the main screen's scale was used on every
 * screen, which gave a 1280x960 swapchain stretched by 1.125 on a 1080p
 * AirPlay screen. */
static CGFloat cocoa_vk_view_scale(void)
{
    UIView   *view   = apple_platform.renderView;
    UIScreen *screen = cocoa_vk_view_screen();
    CGRect    bounds = view.bounds;
    CGFloat   scale;

    if (!screen || bounds.size.width <= 0.0)
        return cocoa_screen_get_native_scale();

    /* The device screen keeps the scale it always had. */
    if (screen == [UIScreen mainScreen])
        return cocoa_screen_get_native_scale();

    scale = screen.nativeScale;
    if (scale <= 0.0)
        scale = 1.0;
    /* nil = the window: includes the transforms of the views above. */
    scale *= [view convertRect:bounds toView:nil].size.width / bounds.size.width;
    return scale;
}

/* Manic MP: the pixel size of the screen the view is on, for the sanity
 * check in cocoa_vk_gfx_ctx_check_window; false on the device screen, whose
 * bounds follow the orientation and are not a bound worth checking. */
static bool cocoa_vk_external_screen_pixels(unsigned *width, unsigned *height)
{
    UIScreen *screen = cocoa_vk_view_screen();
    CGFloat   scale;
    if (!screen || screen == [UIScreen mainScreen])
        return false;
    scale = screen.nativeScale;
    if (scale <= 0.0)
        scale = 1.0;
    *width  = (unsigned)round(CGRectGetWidth(screen.bounds)  * scale);
    *height = (unsigned)round(CGRectGetHeight(screen.bounds) * scale);
    return *width > 0 && *height > 0;
}

/* Same arithmetic as MoltenVK's surface extent (bounds x contentsScale,
 * truncated), so the size reported here is the size of the swapchain it
 * creates once the layer carries this scale. */
static void cocoa_vk_gfx_ctx_get_video_size(void *data,
      unsigned* width, unsigned* height)
{
    CGFloat scale                   = cocoa_vk_view_scale();
    CGRect size                     = [apple_platform.renderView bounds];
    *width                          = (unsigned)trunc(CGRectGetWidth(size)  * scale);
    *height                         = (unsigned)trunc(CGRectGetHeight(size) * scale);
}

/* Give the layer the scale the size above was computed with, before the
 * swapchain is created from it, and tell the frame logger the refresh rate
 * of the screen its drawables are shown on. */
static void cocoa_vk_sync_layer(void)
{
    CAMetalLayer *layer  = ((MetalLayerView*)apple_platform.renderView).metalLayer;
    UIScreen     *screen = cocoa_vk_view_screen();
    CGFloat       scale  = cocoa_vk_view_scale();

    if (layer && scale > 0.0 && fabs(layer.contentsScale - scale) > 0.001)
        layer.contentsScale = scale;
    if (screen)
        manic_frame_present_set_refresh((float)screen.maximumFramesPerSecond);
}
#endif

static float cocoa_vk_gfx_ctx_get_refresh_rate(void *data)
{
#ifdef OSX
    CGDirectDisplayID mainDisplayID = CGMainDisplayID();
    CGDisplayModeRef currentMode = CGDisplayCopyDisplayMode(mainDisplayID);
    float currentRate = CGDisplayModeGetRefreshRate(currentMode);
    CFRelease(currentMode);
    return currentRate;
#else
    /* Manic MP: the screen the game view is on, not always the main one. */
    UIScreen *screen = cocoa_vk_view_screen();
    return (screen ? screen : [UIScreen mainScreen]).maximumFramesPerSecond;
#endif
}

static gfx_ctx_proc_t cocoa_vk_gfx_ctx_get_proc_address(const char *symbol_name)
{
   return NULL;
}

static void cocoa_vk_gfx_ctx_bind_hw_render(void *data, bool enable) { }

static void cocoa_vk_gfx_ctx_check_window(void *data, bool *quit,
      bool *resize, unsigned *width, unsigned *height)
{
   unsigned new_width, new_height;
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;
   *quit                          = false;
   *resize                        = (cocoa_ctx->vk.flags &
         VK_DATA_FLAG_NEED_NEW_SWAPCHAIN) ? true : false;

#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_vk_gfx_ctx_get_video_size_osx10_7_and_up(data, &new_width, &new_height);
#else
   cocoa_vk_gfx_ctx_get_video_size(data, &new_width, &new_height);
#endif

   if (new_width != *width || new_height != *height)
   {
#if !defined(OSX)
      unsigned screen_width, screen_height;
      retro_time_t now = cpu_features_get_time_usec();

      /* Manic MP: on an external screen a swapchain larger than the screen
       * is never right (the view is scaled to fit the window), so such a
       * size is the mid-move transient and is not even queued. */
      if (     cocoa_vk_external_screen_pixels(&screen_width, &screen_height)
            && (new_width > screen_width || new_height > screen_height))
      {
         cocoa_ctx->pending_width  = 0;
         cocoa_ctx->pending_height = 0;
         return;
      }

      /* Manic MP: when the app moves the view to another window the first
       * checks can land before the layout pass, with the old bounds under
       * the new transform. A size has to hold for two checks and for
       * COCOA_VK_RESIZE_SETTLE_USEC before the swapchain is recreated for
       * it; a size that changes again restarts the wait. */
      if (     new_width  != cocoa_ctx->pending_width
            || new_height != cocoa_ctx->pending_height)
      {
         cocoa_ctx->pending_width  = new_width;
         cocoa_ctx->pending_height = new_height;
         cocoa_ctx->pending_since  = now;
         return;
      }
      if (now - cocoa_ctx->pending_since < COCOA_VK_RESIZE_SETTLE_USEC)
         return;
      cocoa_vk_sync_layer();
#endif
      *width  = new_width;
      *height = new_height;
      *resize = true;
   }
#if !defined(OSX)
   else
   {
      cocoa_ctx->pending_width  = 0;
      cocoa_ctx->pending_height = 0;
      /* Same size: keep the layer's scale and the logger's refresh rate
       * right all the same (a move between two screens of one size). */
      cocoa_vk_sync_layer();
   }
#endif
}

static void cocoa_vk_gfx_ctx_swap_interval(void *data, int i)
{
   unsigned interval              = (unsigned)i;
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;

   if (cocoa_ctx->swap_interval != interval)
   {
      cocoa_ctx->swap_interval    = interval;
      if (cocoa_ctx->vk.swapchain)
         cocoa_ctx->vk.flags     |= VK_DATA_FLAG_NEED_NEW_SWAPCHAIN;
   }
}

static void cocoa_vk_gfx_ctx_swap_buffers(void *data)
{
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;

   if (cocoa_ctx->vk.context.flags & VK_CTX_FLAG_HAS_ACQUIRED_SWAPCHAIN)
   {
      cocoa_ctx->vk.context.flags &= ~VK_CTX_FLAG_HAS_ACQUIRED_SWAPCHAIN;
      if (cocoa_ctx->vk.swapchain == VK_NULL_HANDLE)
      {
         retro_sleep(10);
      }
      else
         vulkan_present(&cocoa_ctx->vk, cocoa_ctx->vk.context.current_swapchain_index);
   }
   vulkan_acquire_next_image(&cocoa_ctx->vk);
}

static bool cocoa_vk_gfx_ctx_bind_api(void *data, enum gfx_ctx_api api,
      unsigned major, unsigned minor)
{
   g_vk_minor  = minor;
   g_vk_major  = major;

   return true;
}

static void *cocoa_vk_gfx_ctx_get_context_data(void *data)
{
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;
   return &cocoa_ctx->vk.context;
}

#ifdef OSX
static bool cocoa_vk_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
   gfx_ctx_mode_t mode;
#if defined(HAVE_COCOA_METAL)
   NSView *g_view                 = apple_platform.renderView;
#elif defined(HAVE_COCOA)
   CocoaView *g_view              = (CocoaView*)nsview_get_ptr();
#endif
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;
   static bool
      has_went_fullscreen         = false;
   cocoa_ctx->width               = width;
   cocoa_ctx->height              = height;

   RARCH_LOG("[macOS]: Native window size: %u x %u.\n",
         cocoa_ctx->width, cocoa_ctx->height);

   if (!vulkan_surface_create(
            &cocoa_ctx->vk,
            VULKAN_WSI_MVK_MACOS,
            NULL,
            (BRIDGE void *)g_view.layer,
            cocoa_ctx->width,
            cocoa_ctx->height,
            cocoa_ctx->swap_interval))
   {
      RARCH_ERR("[macOS]: Failed to create surface.\n");
      return false;
   }

   mode.width                     = width;
   mode.height                    = height;
   mode.fullscreen                = fullscreen;
   [apple_platform setVideoMode:mode];
   cocoa_show_mouse(data, !fullscreen);

   has_went_fullscreen            = fullscreen;

   return true;
}

static void *cocoa_vk_gfx_ctx_init(void *video_driver)
{
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)
   calloc(1, sizeof(cocoa_vk_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

   [apple_platform setViewType:APPLE_VIEW_TYPE_VULKAN];
   if (!vulkan_context_init(&cocoa_ctx->vk, VULKAN_WSI_MVK_MACOS))
   {
      free(cocoa_ctx);
      return NULL;
   }

   return cocoa_ctx;
}
#else
static bool cocoa_vk_gfx_ctx_set_video_mode(void *data,
      unsigned width, unsigned height, bool fullscreen)
{
   id g_view                      = apple_platform.renderView;
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;
   cocoa_ctx->width               = width;
   cocoa_ctx->height              = height;

   /* Manic MP: the layer gets the scale the size was computed with before
    * MoltenVK reads its extent. */
   cocoa_vk_sync_layer();

   if (!vulkan_surface_create(&cocoa_ctx->vk,
                              VULKAN_WSI_MVK_IOS,
                              NULL,
                              (BRIDGE void *)((MetalLayerView*)g_view).metalLayer,
                              cocoa_ctx->width,
                              cocoa_ctx->height,
                              cocoa_ctx->swap_interval))
   {
      RARCH_ERR("[iOS Vulkan]: Failed to create surface.\n");
      return false;
   }
   manic_frame_swapchain_changed(cocoa_ctx->vk.context.swapchain_width,
         cocoa_ctx->vk.context.swapchain_height);

   /* TODO: Maybe iOS users should be able to
    * show/hide the status bar here? */
   return true;
}

static void *cocoa_vk_gfx_ctx_init(void *video_driver)
{
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)
   calloc(1, sizeof(cocoa_vk_ctx_data_t));

   if (!cocoa_ctx)
      return NULL;

   [apple_platform setViewType:APPLE_VIEW_TYPE_VULKAN];
   if (!vulkan_context_init(&cocoa_ctx->vk, VULKAN_WSI_MVK_IOS))
   {
      free(cocoa_ctx);
      return NULL;
   }

   return cocoa_ctx;
}
#endif

#ifdef HAVE_COCOA_METAL
static bool cocoa_vk_gfx_ctx_set_resize(void *data, unsigned width, unsigned height)
{
   cocoa_vk_ctx_data_t *cocoa_ctx = (cocoa_vk_ctx_data_t*)data;

   cocoa_ctx->width               = width;
   cocoa_ctx->height              = height;

   if (!vulkan_create_swapchain(&cocoa_ctx->vk,
            width, height, cocoa_ctx->swap_interval))
   {
      RARCH_ERR("[macOS/Vulkan]: Failed to update swapchain.\n");
      return false;
   }

   cocoa_ctx->vk.context.flags   |= VK_CTX_FLAG_INVALID_SWAPCHAIN;
   if (cocoa_ctx->vk.flags & VK_DATA_FLAG_CREATED_NEW_SWAPCHAIN)
      vulkan_acquire_next_image(&cocoa_ctx->vk);
   cocoa_ctx->vk.flags           &= ~VK_DATA_FLAG_NEED_NEW_SWAPCHAIN;
#if !defined(OSX)
   manic_frame_swapchain_changed(cocoa_ctx->vk.context.swapchain_width,
         cocoa_ctx->vk.context.swapchain_height);
#endif
   return true;
}
#endif

const gfx_ctx_driver_t gfx_ctx_cocoavk = {
   cocoa_vk_gfx_ctx_init,
   cocoa_vk_gfx_ctx_destroy,
   cocoa_vk_gfx_ctx_get_api,
   cocoa_vk_gfx_ctx_bind_api,
   cocoa_vk_gfx_ctx_swap_interval,
   cocoa_vk_gfx_ctx_set_video_mode,
#if MAC_OS_X_VERSION_10_7 && defined(OSX)
   cocoa_vk_gfx_ctx_get_video_size_osx10_7_and_up,
#else
   cocoa_vk_gfx_ctx_get_video_size,
#endif
   cocoa_vk_gfx_ctx_get_refresh_rate,
   NULL, /* get_video_output_size */
   NULL, /* get_video_output_prev */
   NULL, /* get_video_output_next */
   cocoa_get_metrics,
   NULL, /* translate_aspect */
#ifdef OSX
   video_driver_update_title,
#else
   NULL, /* update_title */
#endif
   cocoa_vk_gfx_ctx_check_window,
#if defined(HAVE_COCOA_METAL)
   cocoa_vk_gfx_ctx_set_resize,
#else
   NULL, /* set_resize */
#endif
   cocoa_has_focus,
   cocoa_vk_gfx_ctx_suppress_screensaver,
#if defined(HAVE_COCOATOUCH)
   false,
#else
   true,
#endif
   cocoa_vk_gfx_ctx_swap_buffers,
   cocoa_vk_gfx_ctx_input_driver,
   cocoa_vk_gfx_ctx_get_proc_address,
   NULL, /* image_buffer_init */
   NULL, /* image_buffer_write */
   NULL, /* show_mouse */
   "cocoavk",
   cocoa_vk_gfx_ctx_get_flags,
   cocoa_vk_gfx_ctx_set_flags,
   cocoa_vk_gfx_ctx_bind_hw_render,
   cocoa_vk_gfx_ctx_get_context_data,
   NULL  /* make_current */
};
