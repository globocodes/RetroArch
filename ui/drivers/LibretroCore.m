//
//  LibretroCore.m
//  LibretroCore
//
//  Created by Daiuno on 2025/4/22.
//  Copyright © 2025 Manic EMU. All rights reserved.
//

#import "LibretroCore.h"
#import "LibretroShaderPreview.h"
#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include <boolean.h>

#include <file/file_path.h>
#include <queues/task_queue.h>
#include <string/stdstring.h>
#include <retro_timers.h>

#include "cocoa/cocoa_common.h"
#include "cocoa/apple_platform.h"
#include "../ui_companion_driver.h"
#include "../../audio/audio_driver.h"
#include "../../configuration.h"
#include "../../frontend/frontend.h"
#include "../../input/drivers/cocoa_input.h"
#include "../../input/drivers_keyboard/keyboard_event_apple.h"
#include "../../retroarch.h"
#include "../../tasks/task_content.h"
#include "../../verbosity.h"

#ifdef HAVE_MENU
#include "../../menu/menu_setting.h"
#endif

#import <AVFoundation/AVFoundation.h>
#import <CoreFoundation/CoreFoundation.h>

#import <MetricKit/MetricKit.h>
#import <MetricKit/MXMetricManager.h>

#ifdef HAVE_MFI
#import <GameController/GCMouse.h>
#endif

#ifdef HAVE_SDL2
#define SDL_MAIN_HANDLED
#include "SDL.h"
#endif

#import "JITSupport.h"
#include "../../cheevos/cheevos.h"
#include "../../deps/rcheevos/include/rc_client.h"
#include "../../command.h"
#include "../../core.h"
#include "../../file_path_special.h"
#include "../../libretro-common/include/libretro.h"
#include "../../network/netplay/netplay.h"
#include "../../tasks/tasks_internal.h"

NSString * const RetroAchievementsNotification = @"RetroAchievementsNotification";
NSString * const LibretroDidShutdownNotification = @"LibretroDidShutdownNotification";
NSString * const DidConnectToWFCNotification = @"DidConnectToWFCNotification";
NSString * const DidDisconnectFromWFCNotification = @"DidDisconnectFromWFCNotification";
NSString * const MAMEGameFileMissingNotification = @"MAMEGameFileMissingNotification";
NSString * const LibretroNetplayEventNotification = @"LibretroNetplayEventNotification";
NSString * const FirmwareNoSupportNotification = @"FirmwareNoSupportNotification";
NSString * const AmigaBiosMissingNotification = @"AmigaBiosMissingNotification";

static BOOL LibretroPathLooksLikeEKA2L1(NSString *corePath);
static void LibretroEKA2L1ShutdownManagement(void);

@interface LibretroHost (Private)
+ (instancetype)hostWithRoom:(const struct netplay_room *)room;
+ (instancetype)hostWithLANHost:(const struct netplay_host *)lanHost;
@end

@interface LibretroCore()

@property (assign) BOOL isRunning;
@property (assign) unsigned keyboardMods;

@end

static void netplayDidTrigger(int event, const char *info);
static void (^_Nullable s_netplay_host_list_completion)(NSArray<LibretroHost *> * _Nullable hosts) = nil;
static void (^_Nullable s_netplay_lan_host_list_completion)(NSArray<LibretroHost *> * _Nullable hosts) = nil;
static NSTimer *s_netplay_task_pump = nil;
static NSInteger s_netplay_task_pump_ticks = 0;
static BOOL s_netplay_advertise_pump = NO;
static const NSInteger kNetplayTaskPumpMaxTicks = 15 * 30;

///暂停时 draw observer 被停掉: 任务队列不再推进, 主机也不再应答 UDP 55435 发现查询
///这里只泵任务队列和局域网应答, 不调用 runloop_iterate, 游戏保持暂停
static BOOL netplay_is_hosting(void)
{
    return netplay_driver_ctl(RARCH_NETPLAY_CTL_IS_ENABLED, NULL)
        && netplay_driver_ctl(RARCH_NETPLAY_CTL_IS_SERVER, NULL);
}

static void netplay_stop_task_pump(void)
{
    [s_netplay_task_pump invalidate];
    s_netplay_task_pump = nil;
    s_netplay_task_pump_ticks = 0;
    s_netplay_advertise_pump = NO;
}

static void netplay_pump_tick(void)
{
    task_queue_check();
#ifdef HAVE_NETPLAYDISCOVERY
    if (s_netplay_advertise_pump)
        netplay_lan_advertise();
#endif

    s_netplay_task_pump_ticks++;

    BOOL needScan = (s_netplay_host_list_completion != nil
                     || s_netplay_lan_host_list_completion != nil);
    if ((!needScan && !s_netplay_advertise_pump)
        || (!s_netplay_advertise_pump && s_netplay_task_pump_ticks >= kNetplayTaskPumpMaxTicks))
        netplay_stop_task_pump();
}

static void netplay_start_task_pump_if_paused(BOOL advertise)
{
    if (![[LibretroCore sharedInstance] isPaused])
        return;

    if (advertise)
        s_netplay_advertise_pump = YES;

    if (s_netplay_task_pump)
        return;

    s_netplay_task_pump_ticks = 0;
    s_netplay_task_pump = [NSTimer timerWithTimeInterval:1.0 / 30.0
                                                 repeats:YES
                                                   block:^(NSTimer * _Nonnull timer) {
        netplay_pump_tick();
    }];
    [[NSRunLoop mainRunLoop] addTimer:s_netplay_task_pump forMode:NSRunLoopCommonModes];
}

@implementation LibretroCore

+ (instancetype)sharedInstance {
    static LibretroCore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[self alloc] init];
        instance.retroArch_iOS = [RetroArch_iOS new];
    });
    return instance;
}

// 可选：重写 allocWithZone，防止外部 alloc init 创建新实例
+ (id)allocWithZone:(struct _NSZone *)zone {
    static LibretroCore *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [super allocWithZone:zone];
    });
    return instance;
}

- (id)copyWithZone:(NSZone *)zone {
    return self;
}

- (id)mutableCopyWithZone:(NSZone *)zone {
    return self;
}

- (UIViewController *)startWithCustomSaveDir:(NSString *_Nullable)customSaveDir {
    self.isRunning = YES;
    [[self getRetroArch] startWithCustomSaveDir:customSaveDir];
    cheevos_event_register_callback(cheevosDidTrigger);
    netplay_event_register_callback(netplayDidTrigger);
    shutdown_register_callback(shutdownCallback);
    log_register_callback(libretroLogCallback);
    return [CocoaView get];
}

- (void)pause {
    [[self getRetroArch] pause];
    if (netplay_is_hosting())
        netplay_start_task_pump_if_paused(YES);
}

- (BOOL)isPaused {
    return [[self getRetroArch] isPaused];
}

- (void)resume {
    s_netplay_advertise_pump = NO;
    if (!s_netplay_host_list_completion && !s_netplay_lan_host_list_completion)
        netplay_stop_task_pump();
    [[self getRetroArch] resume];
}

- (void)stop {
    self.isRunning = NO;
    cheevos_event_register_callback(NULL);
    netplay_event_register_callback(NULL);
    shutdown_register_callback(NULL);
    wfc_status_register_callback(NULL);
    log_register_callback(NULL);
    g_enableMonitorLibretroLog = NO;
    s_netplay_host_list_completion = nil;
    s_netplay_lan_host_list_completion = nil;
    netplay_stop_task_pump();
    [self registerAzaharKeyboard:nil];
    [self registerEKA2L1InputDialog:nil questionDialog:nil];
    [[self getRetroArch] stop];
}

- (void)mute:(BOOL)mute {
    [[self getRetroArch] mute:mute];
}

- (void)snapshot:(void(^ _Nullable)(UIImage *_Nullable image))completion {
#if !TARGET_IPHONE_SIMULATOR
    [[self getRetroArch] snapshot:completion];
#else
    if (completion) {
        completion(nil);
    }
#endif
    
}

- (BOOL)saveState:(void(^ _Nullable)(NSString *_Nullable path))completion {
    return [[self getRetroArch] saveState:completion];
}

- (BOOL)loadState:(NSString *_Nonnull)path {
    return [[self getRetroArch] loadState:path];
}

- (void)fastForward:(float)rate {
    [[self getRetroArch] fastForward:rate];
}

- (void)setRewindEnable:(BOOL)enable
            granularity:(unsigned)granularity
           bufferSizeMB:(unsigned)bufferSizeMB
       bufferSizeStepMB:(unsigned)bufferSizeStepMB
                   mute:(BOOL)mute {
    [[self getRetroArch] setRewindEnable:enable
                             granularity:granularity
                            bufferSizeMB:bufferSizeMB
                        bufferSizeStepMB:bufferSizeStepMB
                                    mute:mute];
}

- (void)setRewindEnable:(BOOL)enable {
    [self setRewindEnable:enable granularity:2 bufferSizeMB:20 bufferSizeStepMB:10 mute:NO];
}

- (void)setRewind:(BOOL)rewinding {
    [[self getRetroArch] setRewind:rewinding];
}

- (void)reload {
    [[self getRetroArch] reload];
}

- (void)reloadByKeepState:(BOOL)keepState {
    [[self getRetroArch] reloadByKeepState:keepState];
}

- (BOOL)loadGame:(NSString *_Nonnull)gamePath corePath:(NSString *_Nonnull)corePath completion:(void(^ _Nullable)(NSDictionary *_Nullable))completion {
    if (!LibretroPathLooksLikeEKA2L1(corePath)) {
        LibretroEKA2L1ShutdownManagement();
    }
    return [[self getRetroArch] loadGame:gamePath corePath:corePath completion:completion];
}

- (void)loadCoreWithoutContent:(NSString *_Nonnull)corePath {
    if (!LibretroPathLooksLikeEKA2L1(corePath)) {
        LibretroEKA2L1ShutdownManagement();
    }
    [[self getRetroArch] loadCoreWithoutContent:corePath];
}

- (void)loadCoreWithoutRunning:(NSString *_Nonnull)corePath {
    if (!LibretroPathLooksLikeEKA2L1(corePath)) {
        LibretroEKA2L1ShutdownManagement();
    }
    [[self getRetroArch] loadCoreWithoutRunning:corePath];
}

- (NSArray<CoreOptionCategory *> *_Nullable)getCoreOptions:(NSString *_Nonnull)corePath {
    return [self getCoreOptions:corePath resetOptFile:NO];
}

- (NSArray<CoreOptionCategory *> *_Nullable)getCoreOptions:(NSString *_Nonnull)corePath resetOptFile:(BOOL)resetOptFile {
    return [[self getRetroArch] getCoreOptions:corePath resetOptFile:resetOptFile];
}

- (void)pressButton:(LibretroButton)button playerIndex:(unsigned)playerIndex {
    [[self getRetroArch] pressButton:(unsigned)button playerIndex:playerIndex];
}

- (void)releaseButton:(LibretroButton)button playerIndex:(unsigned)playerIndex {
    [[self getRetroArch] releaseButton:(unsigned)button playerIndex:playerIndex];
}

- (void)pressKeyboard:(LibretroKeyboardCode *_Nonnull)keyboardCode {
    // 先更新修饰键状态
    if (keyboardCode.code == RETROK_LSHIFT || keyboardCode.code == RETROK_RSHIFT) {
        _keyboardMods |= RETROKMOD_SHIFT;
    } else if (keyboardCode.code == RETROK_LCTRL || keyboardCode.code == RETROK_RCTRL) {
        _keyboardMods |= RETROKMOD_CTRL;
    } else if (keyboardCode.code == RETROK_LALT || keyboardCode.code == RETROK_RALT) {
        _keyboardMods |= RETROKMOD_ALT;
    }
    
    // 再发送键盘事件（包含更新后的修饰键状态）
    apple_direct_input_keyboard_event(true, keyboardCode.code, 0, _keyboardMods, RETRO_DEVICE_KEYBOARD);
}

- (void)releaseKeyboard:(LibretroKeyboardCode *_Nonnull)keyboardCode {
    // 先清除修饰键状态（使用按位取反）
    if (keyboardCode.code == RETROK_LSHIFT || keyboardCode.code == RETROK_RSHIFT) {
        _keyboardMods &= ~RETROKMOD_SHIFT;
    } else if (keyboardCode.code == RETROK_LCTRL || keyboardCode.code == RETROK_RCTRL) {
        _keyboardMods &= ~RETROKMOD_CTRL;
    } else if (keyboardCode.code == RETROK_LALT || keyboardCode.code == RETROK_RALT) {
        _keyboardMods &= ~RETROKMOD_ALT;
    }
    
    // 再发送键盘事件（包含更新后的修饰键状态）
    apple_direct_input_keyboard_event(false, keyboardCode.code, 0, _keyboardMods, RETRO_DEVICE_KEYBOARD);
}

- (void)handleUIPress:(UIPress *)press withEvent:(UIPressesEvent *)event down:(BOOL)down {
   NSString       *ch;
   uint32_t character = 0;
   uint32_t mod       = 0;
   NSUInteger mods    = 0;
   if (@available(iOS 13.4, tvOS 13.4, *))
   {
      ch = (NSString*)press.key.characters;
      mods = event.modifierFlags;
   }

   if (mods & UIKeyModifierAlphaShift)
      mod |= RETROKMOD_CAPSLOCK;
   if (mods & UIKeyModifierShift)
      mod |= RETROKMOD_SHIFT;
   if (mods & UIKeyModifierControl)
      mod |= RETROKMOD_CTRL;
   if (mods & UIKeyModifierAlternate)
      mod |= RETROKMOD_ALT;
   if (mods & UIKeyModifierCommand)
      mod |= RETROKMOD_META;
   if (mods & UIKeyModifierNumericPad)
      mod |= RETROKMOD_NUMLOCK;

   if (ch && ch.length != 0)
   {
      unsigned i;
      character = [ch characterAtIndex:0];

      apple_input_keyboard_event(down,
                                 (uint32_t)press.key.keyCode, 0, mod,
                                 RETRO_DEVICE_KEYBOARD);

      for (i = 1; i < ch.length; i++)
         apple_input_keyboard_event(down,
                                    0, [ch characterAtIndex:i], mod,
                                    RETRO_DEVICE_KEYBOARD);
   }

   if (@available(iOS 13.4, tvOS 13.4, *))
      apple_input_keyboard_event(down,
                                 (uint32_t)press.key.keyCode, character, mod,
                                 RETRO_DEVICE_KEYBOARD);
}

- (void)keyboardEvent:(UIEvent *_Nonnull)event {
    // 严格参考 DeltaCore KeyboardResponder.swift 实现
    // 通过 KVC 从私有字段直接读取
    NSNumber *keyCodeNum       = [event valueForKey:@"_keyCode"];
    NSNumber *isKeyDownNum     = [event valueForKey:@"_isKeyDown"];
    NSNumber *modifierFlagsNum = [event valueForKey:@"_modifierFlags"];
    NSString *unmodifiedInput  = [event valueForKey:@"_unmodifiedInput"];

    if (!keyCodeNum || !isKeyDownNum || !modifierFlagsNum) {
        return;
    }

    NSInteger hidKeyCode   = keyCodeNum.integerValue;
    BOOL isKeyDown         = isKeyDownNum.boolValue;
    NSInteger rawModifiers = modifierFlagsNum.integerValue;

    // ── 1. 计算 RETROKMOD 位掩码 ─────────────────────────────────────────
    static const NSInteger kShift   = 1 << 17; // UIKeyModifierShift
    static const NSInteger kCtrl    = 1 << 18; // UIKeyModifierControl
    static const NSInteger kAlt     = 1 << 19; // UIKeyModifierAlternate
    static const NSInteger kMeta    = 1 << 20; // UIKeyModifierCommand
    static const NSInteger kCapsLk  = 1 << 16; // UIKeyModifierAlphaShift

    uint32_t newMods = RETROKMOD_NONE;
    if (rawModifiers & kShift)  newMods |= RETROKMOD_SHIFT;
    if (rawModifiers & kCtrl)   newMods |= RETROKMOD_CTRL;
    if (rawModifiers & kAlt)    newMods |= RETROKMOD_ALT;
    if (rawModifiers & kMeta)   newMods |= RETROKMOD_META;
    if (rawModifiers & kCapsLk) newMods |= RETROKMOD_CAPSLOCK;

    // ── 2. HID Usage → RETROK 映射表（初始化一次）────────────────────────
    static unsigned hidToRetrok[0x200];
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        memset(hidToRetrok, 0, sizeof(hidToRetrok));
        // 字母 a-z (HID 0x04–0x1D)
        hidToRetrok[0x04] = RETROK_a; hidToRetrok[0x05] = RETROK_b;
        hidToRetrok[0x06] = RETROK_c; hidToRetrok[0x07] = RETROK_d;
        hidToRetrok[0x08] = RETROK_e; hidToRetrok[0x09] = RETROK_f;
        hidToRetrok[0x0A] = RETROK_g; hidToRetrok[0x0B] = RETROK_h;
        hidToRetrok[0x0C] = RETROK_i; hidToRetrok[0x0D] = RETROK_j;
        hidToRetrok[0x0E] = RETROK_k; hidToRetrok[0x0F] = RETROK_l;
        hidToRetrok[0x10] = RETROK_m; hidToRetrok[0x11] = RETROK_n;
        hidToRetrok[0x12] = RETROK_o; hidToRetrok[0x13] = RETROK_p;
        hidToRetrok[0x14] = RETROK_q; hidToRetrok[0x15] = RETROK_r;
        hidToRetrok[0x16] = RETROK_s; hidToRetrok[0x17] = RETROK_t;
        hidToRetrok[0x18] = RETROK_u; hidToRetrok[0x19] = RETROK_v;
        hidToRetrok[0x1A] = RETROK_w; hidToRetrok[0x1B] = RETROK_x;
        hidToRetrok[0x1C] = RETROK_y; hidToRetrok[0x1D] = RETROK_z;
        // 数字 1-9, 0 (HID 0x1E–0x27)
        hidToRetrok[0x1E] = RETROK_1; hidToRetrok[0x1F] = RETROK_2;
        hidToRetrok[0x20] = RETROK_3; hidToRetrok[0x21] = RETROK_4;
        hidToRetrok[0x22] = RETROK_5; hidToRetrok[0x23] = RETROK_6;
        hidToRetrok[0x24] = RETROK_7; hidToRetrok[0x25] = RETROK_8;
        hidToRetrok[0x26] = RETROK_9; hidToRetrok[0x27] = RETROK_0;
        // 控制键
        hidToRetrok[0x28] = RETROK_RETURN;    // Return
        hidToRetrok[0x29] = RETROK_ESCAPE;    // Escape
        hidToRetrok[0x2A] = RETROK_BACKSPACE; // Backspace
        hidToRetrok[0x2B] = RETROK_TAB;       // Tab
        hidToRetrok[0x2C] = RETROK_SPACE;     // Space
        // 符号
        hidToRetrok[0x2D] = RETROK_MINUS;        // -
        hidToRetrok[0x2E] = RETROK_EQUALS;       // =
        hidToRetrok[0x2F] = RETROK_LEFTBRACKET;  // [
        hidToRetrok[0x30] = RETROK_RIGHTBRACKET; // ]
        hidToRetrok[0x31] = RETROK_BACKSLASH;    // backslash
        hidToRetrok[0x33] = RETROK_SEMICOLON;    // ;
        hidToRetrok[0x34] = RETROK_QUOTE;        // '
        hidToRetrok[0x35] = RETROK_BACKQUOTE;    // `
        hidToRetrok[0x36] = RETROK_COMMA;        // ,
        hidToRetrok[0x37] = RETROK_PERIOD;       // .
        hidToRetrok[0x38] = RETROK_SLASH;        // /
        // CapsLock
        hidToRetrok[0x39] = RETROK_CAPSLOCK;
        // F1–F12 (HID 0x3A–0x45)
        hidToRetrok[0x3A] = RETROK_F1;  hidToRetrok[0x3B] = RETROK_F2;
        hidToRetrok[0x3C] = RETROK_F3;  hidToRetrok[0x3D] = RETROK_F4;
        hidToRetrok[0x3E] = RETROK_F5;  hidToRetrok[0x3F] = RETROK_F6;
        hidToRetrok[0x40] = RETROK_F7;  hidToRetrok[0x41] = RETROK_F8;
        hidToRetrok[0x42] = RETROK_F9;  hidToRetrok[0x43] = RETROK_F10;
        hidToRetrok[0x44] = RETROK_F11; hidToRetrok[0x45] = RETROK_F12;
        // 导航区
        hidToRetrok[0x49] = RETROK_INSERT;   hidToRetrok[0x4A] = RETROK_HOME;
        hidToRetrok[0x4B] = RETROK_PAGEUP;   hidToRetrok[0x4C] = RETROK_DELETE;
        hidToRetrok[0x4D] = RETROK_END;      hidToRetrok[0x4E] = RETROK_PAGEDOWN;
        hidToRetrok[0x4F] = RETROK_RIGHT;    hidToRetrok[0x50] = RETROK_LEFT;
        hidToRetrok[0x51] = RETROK_DOWN;     hidToRetrok[0x52] = RETROK_UP;
        // 小键盘
        hidToRetrok[0x53] = RETROK_NUMLOCK;
        hidToRetrok[0x54] = RETROK_KP_DIVIDE;   hidToRetrok[0x55] = RETROK_KP_MULTIPLY;
        hidToRetrok[0x56] = RETROK_KP_MINUS;    hidToRetrok[0x57] = RETROK_KP_PLUS;
        hidToRetrok[0x58] = RETROK_KP_ENTER;
        hidToRetrok[0x59] = RETROK_KP1; hidToRetrok[0x5A] = RETROK_KP2;
        hidToRetrok[0x5B] = RETROK_KP3; hidToRetrok[0x5C] = RETROK_KP4;
        hidToRetrok[0x5D] = RETROK_KP5; hidToRetrok[0x5E] = RETROK_KP6;
        hidToRetrok[0x5F] = RETROK_KP7; hidToRetrok[0x60] = RETROK_KP8;
        hidToRetrok[0x61] = RETROK_KP9; hidToRetrok[0x62] = RETROK_KP0;
        hidToRetrok[0x63] = RETROK_KP_PERIOD;
        // PrintScreen/SysReq, ScrollLock, Pause (HID 0x46–0x48)
        hidToRetrok[0x46] = RETROK_PRINT;
        hidToRetrok[0x47] = RETROK_SCROLLOCK;
        hidToRetrok[0x48] = RETROK_PAUSE;
        // F13–F15 (HID 0x68–0x6A)
        hidToRetrok[0x68] = RETROK_F13;
        hidToRetrok[0x69] = RETROK_F14;
        hidToRetrok[0x6A] = RETROK_F15;
        // 小键盘等号 (HID 0x67)
        hidToRetrok[0x67] = RETROK_KP_EQUALS;
        // 非 US 键盘第102键反斜杠 (HID 0x64)
        hidToRetrok[0x64] = RETROK_OEM_102;
        // Application/Menu 键 → Compose (HID 0x65)
        hidToRetrok[0x65] = RETROK_COMPOSE;
        // Power 键 (HID 0x66)
        hidToRetrok[0x66] = RETROK_POWER;
        // Help 键 (HID 0x75)
        hidToRetrok[0x75] = RETROK_HELP;
        // 键盘音量键（HID 键盘页 0x07：0x7F–0x81）
        hidToRetrok[0x7F] = RETROK_VOLUME_MUTE;
        hidToRetrok[0x80] = RETROK_VOLUME_UP;
        hidToRetrok[0x81] = RETROK_VOLUME_DOWN;
        // 修饰键（左/右）(HID 0xE0–0xE7)
        hidToRetrok[0xE0] = RETROK_LCTRL;  hidToRetrok[0xE1] = RETROK_LSHIFT;
        hidToRetrok[0xE2] = RETROK_LALT;   hidToRetrok[0xE3] = RETROK_LMETA;
        hidToRetrok[0xE4] = RETROK_RCTRL;  hidToRetrok[0xE5] = RETROK_RSHIFT;
        hidToRetrok[0xE6] = RETROK_RALT;   hidToRetrok[0xE7] = RETROK_RMETA;
    });

    // ── 3. 统一的 activeKeys 跟踪（参考 KeyboardResponder.activeKeyPresses）──
    // 字典存储每个 HID keyCode 的 {retrok, isActive}，用于：
    //   a) 去重（过滤 key-repeat）
    //   b) keyUp 时使用按下时记录的 retrok（因为 keyUp 时 _unmodifiedInput 可能无效）
    //   c) 修饰键也统一走此路径，不再单独 early return

    // activeKeys: key=HID keyCode, value=@[@(retrok), @(isActive)]
    static NSMutableDictionary<NSNumber *, NSArray<NSNumber *> *> *activeKeys = nil;
    static dispatch_once_t keysOnce;
    dispatch_once(&keysOnce, ^{ activeKeys = [NSMutableDictionary dictionary]; });

    NSNumber *keyNum = @(hidKeyCode);
    NSArray<NSNumber *> *previousEntry = activeKeys[keyNum];
    BOOL previousIsActive = previousEntry ? previousEntry[1].boolValue : NO;

    // 参考 KeyboardResponder: guard previousKeyPress?.isActive != isActive
    // 过滤重复的 down/up 事件（包括 key-repeat 和重复 up）
    if (previousEntry && previousIsActive == isKeyDown) {
        return;
    }

    // ── 4. 确定 RETROK 值 ────────────────────────────────────────────────
    unsigned retrok = RETROK_UNKNOWN;

    if (!isKeyDown && previousEntry) {
        // keyUp 时优先使用按下时记录的 retrok（参考 KeyboardResponder: previousKeyPress?.key）
        // 因为 _unmodifiedInput 在 keyUp 时可能无效或不同
        retrok = previousEntry[0].unsignedIntValue;
    } else {
        // keyDown：根据 unmodifiedInput 和 HID keyCode 确定 retrok
        if (unmodifiedInput.length == 0) {
            // 纯修饰键事件（参考 KeyboardResponder 对空 key 的处理）
            // 通过比较前后 modifier flags 确定是哪个修饰键
            if (isKeyDown) {
                // 新按下的修饰键 = 当前 flags 中新增的部分
                uint32_t activated = newMods & ~((uint32_t)_keyboardMods);
                retrok = [self retrokForModifierFlags:activated];
            } else {
                // 新释放的修饰键 = 之前 flags 中消失的部分
                uint32_t deactivated = ((uint32_t)_keyboardMods) & ~newMods;
                retrok = [self retrokForModifierFlags:deactivated];
            }
        } else {
            // 有 unmodifiedInput：使用 HID keyCode 映射
            if (hidKeyCode > 0 && hidKeyCode < 0x200) {
                retrok = hidToRetrok[hidKeyCode];
            }
        }
    }

    // 更新修饰键状态（参考 KeyboardResponder 的 defer 语义：无论是否发送事件都要更新）
    _keyboardMods = newMods;

    if (retrok == RETROK_UNKNOWN) {
        return;
    }

    // ── 5. 更新 activeKeys 并发送事件 ────────────────────────────────────
    if (isKeyDown) {
        activeKeys[keyNum] = @[@(retrok), @YES];
        apple_direct_input_keyboard_event(true, retrok, 0, newMods, RETRO_DEVICE_KEYBOARD);
    } else {
        apple_direct_input_keyboard_event(false, retrok, 0, newMods, RETRO_DEVICE_KEYBOARD);
        [activeKeys removeObjectForKey:keyNum];
    }
}

// 辅助方法：根据 modifier flags 差异确定对应的 RETROK（参考 KeyboardResponder.key(for:)）
- (unsigned)retrokForModifierFlags:(uint32_t)flags {
    if (flags & RETROKMOD_SHIFT)    return RETROK_LSHIFT;
    if (flags & RETROKMOD_CTRL)     return RETROK_LCTRL;
    if (flags & RETROKMOD_ALT)      return RETROK_LALT;
    if (flags & RETROKMOD_META)     return RETROK_LMETA;
    if (flags & RETROKMOD_CAPSLOCK) return RETROK_CAPSLOCK;
    return RETROK_UNKNOWN;
}

- (void)moveStick:(BOOL)isLeft x:(CGFloat)x y:(CGFloat)y playerIndex:(unsigned)playerIndex {
    [[self getRetroArch] moveStick:isLeft x:x y:y playerIndex:playerIndex];
}

- (void)updatePSPCheat:(NSString *_Nonnull)cheatCode cheatFilePath:(NSString *_Nonnull)cheatFilePath reloadGame:(BOOL)reloadGame {
    [[self getRetroArch] updatePSPCheat:cheatCode cheatFilePath:cheatFilePath reloadGame:reloadGame];
}

- (void)updateCoreConfig:(NSString *_Nonnull)coreName key:(NSString *_Nonnull)key value:(NSString *_Nonnull)value reload:(BOOL)reload {
    [[self getRetroArch] updateCoreConfig:coreName key:key value:value reload:reload];
}

- (void)updateCoreConfig:(NSString *_Nonnull)coreName configs:(NSDictionary<NSString*, NSString*> *_Nullable)configs reload:(BOOL)reload {
    [[self getRetroArch] updateCoreConfig:coreName configs:configs reload:reload];
}

- (void)updateCoreConfig:(NSString *_Nonnull)coreName content:(NSString *_Nullable)content reload:(BOOL)reload {
    [[self getRetroArch] updateCoreConfig:coreName content:content reload:reload];
}

- (void)updateRunningCoreConfigs:(NSDictionary<NSString*, NSString*> *_Nullable)configs flush:(BOOL)flush {
    [[self getRetroArch] updateRunningCoreConfigs:configs flush:flush];
}

- (void)updateLibretroConfig:(NSString *_Nonnull)key value:(NSString *_Nonnull)value {
    [[self getRetroArch] updateLibretroConfig:key value:value];
}

- (void)updateLibretroConfigs:(NSDictionary<NSString*, NSString*> *_Nullable)configs {
    [[self getRetroArch] updateLibretroConfigs:configs];
}

- (void)updateRuningLibretroConfigs:(NSDictionary<NSString*, NSString*> *_Nullable)configs {
    if (!self.isRunning)
        return;
    [[self getRetroArch] updateRuningLibretroConfigs:configs];
}

- (BOOL)setShader:(NSString *_Nullable)path {
    return [[self getRetroArch] setShaderWith:path];
}

- (NSArray<ShaderParameter *> *_Nullable)loadParameters {
    return [[self getRetroArch] loadParameters];
}

- (void)updateParameterWith:(NSString *_Nonnull)identifier
                      value:(float)value
               changingPath:(NSString *_Nonnull)changingPath {
    [[self getRetroArch] updateParameterWith:identifier value:value changingPath:changingPath];
}

- (void)appendShader:(NSString *_Nonnull)path prepend:(BOOL)prepend {
    [[self getRetroArch] appendShader:path prepend:prepend];
}

- (void)addCheatCode:(NSString *_Nonnull)code index:(unsigned)index enable:(BOOL)enable {
    [[self getRetroArch] addCheatCode:code index:index enable:enable];
}

- (void)resetCheatCode {
    [[self getRetroArch] resetCheatCode];
}

- (RetroArch_iOS *)getRetroArch {
#if !TARGET_IPHONE_SIMULATOR
    return (RetroArch_iOS *)self.retroArch_iOS;
#else
    return nil;
#endif
}

- (void)sendEvent:(UIEvent * _Nonnull)event {
    if (self.isRunning) {
        [[self getRetroArch] sendEvent:event];
    }
}

- (void)setWorkspace:(NSString *)workspace {
    [self getRetroArch].workspace = workspace;
}

- (NSString *)workspace {
    return [self getRetroArch].workspace;
}

+ (BOOL)JITAvailable {
    if (LibretroCore.sharedInstance.forbitJIT) {
        return false;
    }
    return jit_available();
}

- (NSString * _Nullable)libretroConfigValue:(NSString * _Nonnull)key {
    return [[self getRetroArch] libretroConfigValue:key];
}

- (NSString * _Nullable)coreConfigValue:(NSString * _Nonnull)coreName key:(NSString * _Nonnull)key {
    return [[self getRetroArch] coreConfigValue:coreName key:key];
}

- (void)setRespectSilentMode:(BOOL)respect {
    [[self getRetroArch] setRespectSilentMode:respect];
}

- (void)setDiskIndex:(unsigned)index delay:(BOOL)delay {
    [[self getRetroArch] setDiskIndex:index delay:delay];
}

- (void)setDiskIndex2:(unsigned)index {
    [[self getRetroArch] setDiskIndex2:index];
}

- (LibretroDisk *_Nullable)getDiskInfo {
    return [[self getRetroArch] getDiskInfo];
}

- (BOOL)insertDisk:(NSString *_Nonnull)path {
    return [[self getRetroArch] insertDisk:path];
}

- (void)setPSXAnalog:(BOOL)isAnalog {
    [[self getRetroArch] setPSXAnalog:isAnalog];
}

- (void)setWiiController:(LibretroWiiController)type {
    [[self getRetroArch] setWiiController:type];
}

- (void)setReloadDelay:(double)delay {
    [[self getRetroArch] setReloadDelay:delay];
}

#pragma mark - RetroAchievements

+ (CheevosAchievement *)convertAchievement:(rc_client_achievement_t *)a {
    if ([[NSString stringWithUTF8String:a->badge_name] isEqualToString:@"00000"]) {
        return nil;
    }
    CheevosAchievement* obj = [CheevosAchievement new];
    obj.title = a->title ? [NSString stringWithUTF8String:a->title] : nil;
    obj._description = a->description ? [NSString stringWithUTF8String:a->description] : nil;
    obj.badgeName = [NSString stringWithUTF8String:a->badge_name];
    obj.measuredProgress = [NSString stringWithUTF8String:a->measured_progress];
    obj.measuredPercent = (CGFloat)a->measured_percent;
    obj._id = (NSInteger)a->id;
    obj.points = (NSInteger)a->points;
    obj.unlockTime = (a->unlock_time ? [NSDate dateWithTimeIntervalSince1970:a->unlock_time] : nil);
    obj.state = (NSInteger)a->state;
    obj.category = (NSInteger)a->state;
    obj.bucket = (NSInteger)a->bucket;
    obj.unlocked = (a->unlocked != 0);
    obj.rarity = (CGFloat)a->rarity;
    obj.rarityHardcore = (CGFloat)a->rarity_hardcore;
    obj.type = (NSInteger)a->type;
    char url1[256];
    if (rc_client_achievement_get_image_url(a, RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED, url1, sizeof(url1)) == RC_OK) {
        obj.unlockedBadgeUrl = [NSString stringWithCString:url1 encoding:NSUTF8StringEncoding];
    }
    char url2[256];
    if (rc_client_achievement_get_image_url(a, RC_CLIENT_ACHIEVEMENT_STATE_UNLOCKED, url2, sizeof(url2)) == RC_OK) {
        obj.activeBadgeUrl = [NSString stringWithCString:url2 encoding:NSUTF8StringEncoding];
    }
    return obj;
}

static void cheevosDidTrigger(uint32_t type, void* object1, void* object2) {
    if (type == RC_CLIENT_EVENT_ACHIEVEMENT_TRIGGERED) {
        //获得成就
        if (object1) {
            rc_client_achievement_t *a = (rc_client_achievement_t *)object1;
            CheevosAchievement *achievement = [LibretroCore convertAchievement:a];
            if (!achievement) {
                return;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:achievement];
            });
        }
        
    } else if (type == 8888) {
        //启动游戏
        if (object1 && object2) {
            rc_client_game_t *g = (rc_client_game_t *)object1;
            rc_client_user_game_summary_t *s = (rc_client_user_game_summary_t *)object2;
            
            CheevosSummary* summary = [CheevosSummary new];
            summary.title = g->title ? [NSString stringWithUTF8String:g->title] : nil;
            summary.coreAchievementsNum = (NSInteger)s->num_core_achievements;
            summary.unofficialAchievementsNum = (NSInteger)s->num_unofficial_achievements;
            summary.unlockedAchievementsNum = (NSInteger)s->num_unlocked_achievements;
            summary.unsupportedAchievementsNum = (NSInteger)s->num_unsupported_achievements;
            summary.corePoints = (NSInteger)s->points_core;
            summary.unlockedPoints = (NSInteger)s->points_unlocked;
            char url[256];
            if (rc_client_game_get_image_url(g, url, sizeof(url)) == RC_OK) {
                summary.badgeUrl = [NSString stringWithCString:url encoding:NSUTF8StringEncoding];
            }
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:summary];
            });
            
        }
    } else if (type == RC_CLIENT_EVENT_GAME_COMPLETED) {
        //所有成就收集完成
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:[CheevosCompletion new]];
        });
        
    } else if (type == RC_CLIENT_EVENT_SERVER_ERROR) {
        //发生错误
        if (object1) {
            rc_client_server_error_t *error = (rc_client_server_error_t *)object1;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:error->error_message ? [NSString stringWithUTF8String:error->error_message] : @"RetroAchievements Server Error"];
            });
        }
    } else if (type == RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_SHOW) {
        //挑战提示
        if (object1) {
            rc_client_achievement_t *a = (rc_client_achievement_t *)object1;
            CheevosAchievement *achievement = [LibretroCore convertAchievement:a];
            if (!achievement) {
                return;
            }
            achievement.isChallengeAchievement = YES;
            achievement.show = YES;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:achievement];
            });
        }
    } else if (type == RC_CLIENT_EVENT_ACHIEVEMENT_CHALLENGE_INDICATOR_HIDE) {
        //挑战隐藏
        if (object1) {
            rc_client_achievement_t *a = (rc_client_achievement_t *)object1;
            CheevosAchievement *achievement = [LibretroCore convertAchievement:a];
            if (!achievement) {
                return;
            }
            achievement.isChallengeAchievement = YES;
            achievement.show = NO;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:achievement];
            });
        }
    } else if (type == RC_CLIENT_EVENT_LEADERBOARD_TRACKER_SHOW) {
        //排行榜追踪展示
        if (object1) {
            rc_client_leaderboard_tracker_t *a = (rc_client_leaderboard_tracker_t *)object1;
            CheevosLeaderboardTracker* obj = [CheevosLeaderboardTracker new];
            obj.show = YES;
            obj._id = a->id;
            obj.display = [NSString stringWithUTF8String:a->display];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:obj];
            });
        }
        
    } else if (type == RC_CLIENT_EVENT_LEADERBOARD_TRACKER_HIDE) {
        //排行榜追踪隐藏
        if (object1) {
            rc_client_leaderboard_tracker_t *a = (rc_client_leaderboard_tracker_t *)object1;
            CheevosLeaderboardTracker* obj = [CheevosLeaderboardTracker new];
            obj.show = NO;
            obj._id = a->id;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:obj];
            });
        }
    } else if (type == RC_CLIENT_EVENT_LEADERBOARD_TRACKER_UPDATE) {
        //排行榜追踪更新
        if (object1) {
            rc_client_leaderboard_tracker_t *a = (rc_client_leaderboard_tracker_t *)object1;
            CheevosLeaderboardTracker* obj = [CheevosLeaderboardTracker new];
            obj.show = YES;
            obj._id = a->id;
            obj.display = [NSString stringWithUTF8String:a->display];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:obj];
            });
        }
    } else if (type == RC_CLIENT_EVENT_LEADERBOARD_STARTED) {
        //排行榜开始
        if (object1) {
            rc_client_leaderboard_t *a = (rc_client_leaderboard_t *)object1;
            CheevosLeaderboard* obj = [CheevosLeaderboard new];
            obj.title = a->title ? [NSString stringWithUTF8String:a->title] : nil;
            obj._description = a->description ? [NSString stringWithUTF8String:a->description] : nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:obj];
            });
        }
    } else if (type == RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_SHOW) {
        //进度展示
        if (object1) {
            rc_client_achievement_t *a = (rc_client_achievement_t *)object1;
            
            CheevosAchievement *achievement = [LibretroCore convertAchievement:a];
            if (!achievement) {
                return;
            }
            
            achievement.isProgressAchievement = YES;
            achievement.show = YES;

            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:achievement];
            });
        }
        
    } else if (type == RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_HIDE) {
        //进度隐藏
        CheevosAchievement *achievement = [CheevosAchievement new];
        achievement.isProgressAchievement = YES;
        achievement.show = NO;
        
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:achievement];
        });
        
    } else if (type == RC_CLIENT_EVENT_ACHIEVEMENT_PROGRESS_INDICATOR_UPDATE) {
        //进度更新
        if (object1) {
            rc_client_achievement_t *a = (rc_client_achievement_t *)object1;
            
            CheevosAchievement *achievement = [LibretroCore convertAchievement:a];
            if (!achievement) {
                return;
            }
            
            achievement.isProgressAchievement = YES;
            achievement.show = YES;
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [[NSNotificationCenter defaultCenter] postNotificationName:RetroAchievementsNotification object:achievement];
            });
        }
    }
}

- (void)turnOffHardcode {
    [[self getRetroArch] turnOffHardcode];
}

- (void)resetRetroAchievements {
    [[self getRetroArch] resetRetroAchievements];
}

- (void)setCustomSaveExtension:(NSString *_Nullable)customSaveExtension {
    [[self getRetroArch] setCustomSaveExtension:customSaveExtension];
}

- (void)setEnableRumble:(BOOL)enable {
    [[self getRetroArch] setEnableRumble:enable];
}

- (BOOL)getSensorEnable:(int)playerIndex {
    return [[self getRetroArch] getSensorEnable:playerIndex];
}

static void shutdownCallback(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:LibretroDidShutdownNotification object:nil];
    });
}

- (void)startWFCStatusMonitor {
    wfc_status_register_callback(wfcStatusCallback);
}

static void wfcStatusCallback(bool isConnect) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (isConnect) {
            [[NSNotificationCenter defaultCenter] postNotificationName:DidConnectToWFCNotification object:nil];
        } else {
            [[NSNotificationCenter defaultCenter] postNotificationName:DidDisconnectFromWFCNotification object:nil];
        }
    });
}

static BOOL g_enableMonitorLibretroLog = NO;
- (void)setLibretroLogMonitor:(BOOL)enable {
    g_enableMonitorLibretroLog = enable;
}

- (void)logDiagnosticsLine:(NSString *)line {
    RARCH_LOG("[Input] %s\n", line.UTF8String ?: "");
}

static NSString *g_mameMissingFileLog = nil;
static void libretroLogCallback(enum retro_log_level level, const char *fmt, va_list args) {
    char buffer[4096];
    vsnprintf(buffer, sizeof(buffer), fmt, args);
    NSString *logMessage = [NSString stringWithUTF8String:buffer] ?: @"";

    if (!g_enableMonitorLibretroLog) {
        return;
    }
    
    if ([logMessage containsString:@" NOT FOUND (tried in "]) {
        if (g_mameMissingFileLog && g_mameMissingFileLog.length > 0) {
            g_mameMissingFileLog = [g_mameMissingFileLog stringByAppendingFormat:@"\n%@", logMessage];
        } else {
            g_mameMissingFileLog = logMessage;
        }
    }
    
    switch (level) {
        case RETRO_LOG_ERROR:
            if ([logMessage containsString:@"Required files are missing,"]) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:MAMEGameFileMissingNotification object:g_mameMissingFileLog];
                    g_mameMissingFileLog = nil;
                });
            } else if ([logMessage containsString:@"[EKA2L1] Symbian App Killed"]) {
                // EKA2L1 guest app crash — detect via core log (independent of log monitor toggle).
                dispatch_async(dispatch_get_main_queue(), ^{
                    [[NSNotificationCenter defaultCenter] postNotificationName:LibretroDidShutdownNotification object:nil];
                });
            } else if ([logMessage containsString:@"[EKA2L1] Firmware doesn't support Symbian App"]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:FirmwareNoSupportNotification object:nil];
            } else if ([logMessage containsString:@"Kickstart ROM"]) {
                [[NSNotificationCenter defaultCenter] postNotificationName:AmigaBiosMissingNotification object:logMessage];
            }
            break;
        default:
            break;
    }
}

- (void)setNDSCustomLayout:(NSString *_Nullable)layout {
    if (layout) {
        if ([layout componentsSeparatedByString:@","].count == 10) {
            set_melonds_custom_layout([layout cStringUsingEncoding:NSUTF8StringEncoding]);
            set_desmume_custom_layout([layout cStringUsingEncoding:NSUTF8StringEncoding]);
            [self setCoreOptionNeedsUpdate];
        }
    } else {
        set_melonds_custom_layout(NULL);
        set_desmume_custom_layout(NULL);
        [self setCoreOptionNeedsUpdate];
    }
}

- (void)set3DSCustomLayout:(NSString *_Nullable)layout {
    if (layout) {
        if ([layout componentsSeparatedByString:@","].count == 10) {
            set_azahar_custom_layout([layout cStringUsingEncoding:NSUTF8StringEncoding]);
            [self setCoreOptionNeedsUpdate];
        }
    } else {
        set_azahar_custom_layout(NULL);
        [self setCoreOptionNeedsUpdate];
    }
}

- (void)setNDSWFCDNS:(NSString *_Nullable)nds {
    if (nds) {
        set_melonds_wfc_dns([nds cStringUsingEncoding:NSUTF8StringEncoding]);
        [self setCoreOptionNeedsUpdate];
    } else {
        set_melonds_wfc_dns(NULL);
        [self setCoreOptionNeedsUpdate];
    }
}

- (void)setPSPCustomServerAddress:(NSString *_Nullable)address {
    if (address) {
        set_psp_custom_server_address([address cStringUsingEncoding:NSUTF8StringEncoding]);
    } else {
        set_psp_custom_server_address(NULL);
    }
}

- (void)setPSPCustomServerPort:(NSString *_Nullable)port {
    if (port) {
        set_psp_custom_server_port([port cStringUsingEncoding:NSUTF8StringEncoding]);
    } else {
        set_psp_custom_server_port(NULL);
    }
}

- (void)setCoreOptionNeedsUpdate {
    // 通知核心配置已更新
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (runloop_st->core_options) {
        runloop_st->core_options->updated = true;
    }
}

- (void)sendTouchEventX:(CGFloat)x y:(CGFloat)y {
    [[self getRetroArch] sendTouchEventX:x y:y];
}

- (void)releaseTouchEvent {
    [[self getRetroArch] releaseTouchEvent];
}

- (void)sendMultiTouchEvent:(NSArray<NSDictionary *> *)points {
    [[self getRetroArch] sendMultiTouchEvent:points];
}

- (NSString *_Nullable)getCoreConfigs:(NSString *_Nonnull)coreName {
    return [[self getRetroArch] getCoreConfigs:coreName];
}

- (void)updateFBNeoCheatCode:(NSArray<NSString *> *_Nonnull)keys enable:(BOOL)enable {
    [[self getRetroArch] updateFBNeoCheatCode:keys enable:enable];
}

- (void)setFastforwardFrameSkip:(BOOL)frameSkip {
    [[self getRetroArch] setFastforwardFrameSkip:frameSkip];
}

- (void)loadAmiibo:(NSString *_Nonnull)path {
    [[self getRetroArch] loadAmiibo:path];
}

- (BOOL)isSearchingAmiibo {
    return [[self getRetroArch] isSearchingAmiibo];
}

- (void)setFullScreen:(BOOL)isFullScreen {
    [[self getRetroArch] setFullScreen:isFullScreen];
}

#pragma mark - Azahar

/* ABI layout must match azahar core (libretro_azahar.h); loaded via dylib_proc only. */
struct retro_azahar_keyboard_config_local {
    int button_config;
    int accept_mode;
    bool multiline_mode;
    int max_text_length;
    int max_digits;
    const char* _Nullable hint_text;
    const char* _Nonnull* _Nullable button_text;
    int button_text_count;
    bool prevent_digit;
    bool prevent_at;
    bool prevent_percent;
    bool prevent_backslash;
    bool prevent_profanity;
    bool enable_callback;
};

// Static storage for the keyboard callback
static void (^_Nullable s_azahar_keyboard_callback)(AzaharKeyboardConfig * _Nullable config) = nil;
static AzaharButtonConfig s_azahar_last_button_config = AzaharButtonConfigSingle;

// C callback that will be called by the Azahar core (often off the main thread).
static void azahar_keyboard_request_callback(
    const struct retro_azahar_keyboard_config_local* _Nullable config) {
    if (!s_azahar_keyboard_callback || !config) {
        return;
    }

    s_azahar_last_button_config = (AzaharButtonConfig)config->button_config;
    
    AzaharKeyboardConfig *objcConfig = [[AzaharKeyboardConfig alloc] init];
    objcConfig.buttonConfig = (AzaharButtonConfig)config->button_config;
    objcConfig.acceptedInput = (AzaharAcceptedInput)config->accept_mode;
    objcConfig.multilineMode = config->multiline_mode;
    objcConfig.maxTextLength = config->max_text_length;
    objcConfig.maxDigits = config->max_digits;
    objcConfig.hintText = config->hint_text ? [NSString stringWithUTF8String:config->hint_text] : nil;
    
    // Convert button text array
    if (config->button_text && config->button_text_count > 0) {
        NSMutableArray<NSString *> *buttonTexts = [NSMutableArray arrayWithCapacity:config->button_text_count];
        for (int i = 0; i < config->button_text_count; i++) {
            if (config->button_text[i]) {
                [buttonTexts addObject:[NSString stringWithUTF8String:config->button_text[i]]];
            } else {
                [buttonTexts addObject:@""];
            }
        }
        objcConfig.buttonText = buttonTexts;
    }
    
    // Set filters
    objcConfig.preventDigit = config->prevent_digit;
    objcConfig.preventAt = config->prevent_at;
    objcConfig.preventPercent = config->prevent_percent;
    objcConfig.preventBackslash = config->prevent_backslash;
    objcConfig.preventProfanity = config->prevent_profanity;
    objcConfig.enableCallback = config->enable_callback;

    void (^callback)(AzaharKeyboardConfig *) = s_azahar_keyboard_callback;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (callback) {
            callback(objcConfig);
        }
    });
}

- (void)registerAzaharKeyboard:(void(^ _Nullable)(AzaharKeyboardConfig *_Nonnull config))callback {
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (!runloop_st || !runloop_st->lib_handle) {
        return;
    }
    
    s_azahar_keyboard_callback = [callback copy];
    if (!callback) {
        s_azahar_last_button_config = AzaharButtonConfigSingle;
    }
    
    typedef void (*retro_azahar_set_keyboard_callback_t)(
        void (*)(const struct retro_azahar_keyboard_config_local*));
    retro_azahar_set_keyboard_callback_t set_callback =
        (retro_azahar_set_keyboard_callback_t)dylib_proc(runloop_st->lib_handle,
                                                         "retro_azahar_set_keyboard_callback");
    
    if (set_callback) {
        if (callback) {
            set_callback(azahar_keyboard_request_callback);
        } else {
            set_callback(NULL);
        }
    }
#endif
}

- (void)inputAzaharKeyboard:(NSString *_Nullable)text buttonType:(AzaharButtonType)buttonType {
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (!runloop_st || !runloop_st->lib_handle) {
        return;
    }
    
    typedef void (*retro_azahar_keyboard_input_t)(const char*, int);
    retro_azahar_keyboard_input_t keyboard_input =
        (retro_azahar_keyboard_input_t)dylib_proc(runloop_st->lib_handle, "retro_azahar_keyboard_input");
    
    if (keyboard_input) {
        const char* text_cstr = text ? [text UTF8String] : NULL;
        int button = 0;
        // SWKBD: Single/None Ok=0; Dual Cancel=0 Ok=1; Triple Cancel=0 Forgot=1 Ok=2.
        switch (buttonType) {
            case AzaharButtonTypeOk:
                switch (s_azahar_last_button_config) {
                    case AzaharButtonConfigDual:
                        button = 1;
                        break;
                    case AzaharButtonConfigTriple:
                        button = 2;
                        break;
                    case AzaharButtonConfigSingle:
                    case AzaharButtonConfigNone:
                    default:
                        button = 0;
                        break;
                }
                break;
            case AzaharButtonTypeCancel:
                button = 0;
                break;
            case AzaharButtonTypeForgot:
                button = 1;
                break;
            case AzaharButtonTypeNoButton:
            default:
                button = 0;
                break;
        }

        keyboard_input(text_cstr, button);
    }
#endif
}

- (void)installAzaharCIA:(NSString *_Nonnull)path {
    NSString *corePath = [[NSBundle mainBundle] pathForResource:@"azahar.libretro" ofType:@"framework" inDirectory:@"Frameworks"];
    if (!corePath) {
        return;
    }
    
    NSString *dylibPath = [corePath stringByAppendingPathComponent:@"azahar.libretro"];
    dylib_t lib = dylib_load([dylibPath UTF8String]);
    if (!lib) {
        return;
    }
    
    typedef void (*retro_azahar_install_cia_t)(const char*);
    retro_azahar_install_cia_t install_cia =
        (retro_azahar_install_cia_t)dylib_proc(lib, "retro_azahar_install_cia");
    
    if (install_cia) {
        const char* path_cstr = [path UTF8String];
        install_cia(path_cstr);
    }
    dylib_close(lib);
}

+ (NSString *_Nullable)getPSPGameIDWithRomPath:(NSString *_Nonnull)romPath {
    NSString *corePath = [[NSBundle mainBundle] pathForResource:@"ppsspp.libretro" ofType:@"framework" inDirectory:@"Frameworks"];
    if (!corePath) {
        return nil;
    }
    
    NSString *dylibPath = [corePath stringByAppendingPathComponent:@"ppsspp.libretro"];
    dylib_t lib = dylib_load([dylibPath UTF8String]);
    if (!lib) {
        return nil;
    }
    
    typedef const char* (*retro_ppsspp_get_gameid_t)(const char*);
    retro_ppsspp_get_gameid_t get_psp_gameid = (retro_ppsspp_get_gameid_t)dylib_proc(lib, "retro_ppsspp_get_gameid");
    if (!get_psp_gameid) {
        dylib_close(lib);
        return nil;
    }
    
    const char *romPath_cstr = [romPath UTF8String];
    const char* gameid = get_psp_gameid(romPath_cstr);
    NSString *result = nil;
    if (gameid) {
        result = [NSString stringWithUTF8String:gameid];
    }
    dylib_close(lib);
    
    return result;
}

+ (LibretroPSPGame *_Nullable)installPSPGameWithZipPath:(NSString *_Nonnull)zipPath destDir:(NSString *_Nonnull)destDir {
    NSString *corePath = [[NSBundle mainBundle] pathForResource:@"ppsspp.libretro" ofType:@"framework" inDirectory:@"Frameworks"];
    if (!corePath) {
        return nil;
    }

    NSString *dylibPath = [corePath stringByAppendingPathComponent:@"ppsspp.libretro"];
    dylib_t lib = dylib_load([dylibPath UTF8String]);
    if (!lib) {
        return nil;
    }

    typedef struct {
        int success;
        const char *title;
        const char *gameID;
        const char *gamePath;
        const void *iconData;
        int iconSize;
    } retro_ppsspp_zip_install_result;

    typedef const retro_ppsspp_zip_install_result* (*retro_ppsspp_install_zip_t)(const char*, const char*);
    retro_ppsspp_install_zip_t install_psp_zip = (retro_ppsspp_install_zip_t)dylib_proc(lib, "retro_ppsspp_install_zip");
    if (!install_psp_zip) {
        dylib_close(lib);
        return nil;
    }

    const retro_ppsspp_zip_install_result *result = install_psp_zip([zipPath UTF8String], [destDir UTF8String]);
    LibretroPSPGame *game = nil;

    if (result && result->success) {
        game = [[LibretroPSPGame alloc] init];

        if (result->title) {
            game.title = [NSString stringWithUTF8String:result->title];
        }
        if (result->gameID) {
            game.gameID = [NSString stringWithUTF8String:result->gameID];
        }
        if (result->gamePath) {
            game.gamePath = [NSString stringWithUTF8String:result->gamePath];
        }
        if (result->iconData && result->iconSize > 0) {
            NSData *iconData = [NSData dataWithBytes:result->iconData length:result->iconSize];
            game.icon = [UIImage imageWithData:iconData];
        }
    }

    dylib_close(lib);
    return game;
}

+ (UIImage *_Nullable)previewImageWithImage:(UIImage *_Nonnull)image shaderPath:(NSString *_Nonnull)shaderPath {
    return [LibretroShaderPreview renderImage:image shaderPath:shaderPath];
}

+ (void)clearPreviewCache {
    [LibretroShaderPreview clearCache];
}

#pragma mark - Netplay

static void netplayDidTrigger(int event, const char *info)
{
    NSString *infoStr = (info && info[0]) ? [NSString stringWithUTF8String:info] : @"";
    NSDictionary *userInfo = @{
        @"event": @(event),
        @"info": infoStr
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        if (event == NETPLAY_EVT_HOST_STARTED)
            netplay_start_task_pump_if_paused(YES);
        else if (event == NETPLAY_EVT_HOST_STOPPED)
        {
            s_netplay_advertise_pump = NO;
            if (!s_netplay_host_list_completion && !s_netplay_lan_host_list_completion)
                netplay_stop_task_pump();
        }
        [[NSNotificationCenter defaultCenter]
         postNotificationName:LibretroNetplayEventNotification
         object:nil
         userInfo:userInfo];
    });
}

static void netplay_refresh_rooms_http_cb(retro_task_t *task, void *task_data,
      void *user_data, const char *error)
{
    void (^completion)(NSArray<LibretroHost *> * _Nullable) = s_netplay_host_list_completion;
    s_netplay_host_list_completion = nil;

    if (!completion)
        return;

    http_transfer_data_t *data = (http_transfer_data_t *)task_data;
    if (error || !data || !data->data || !data->len || data->status != 200)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
        return;
    }

    char *room_data = (char *)malloc(data->len + 1);
    if (!room_data)
    {
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
        });
        return;
    }
    memcpy(room_data, data->data, data->len);
    room_data[data->len] = '\0';

    NSMutableArray<LibretroHost *> *hosts = [NSMutableArray array];
    if (!string_is_empty(room_data))
    {
        netplay_rooms_parse(room_data, strlen(room_data));
        int room_count = netplay_rooms_get_count();
        for (int i = 0; i < room_count; i++)
        {
            struct netplay_room *room = netplay_room_get(i);
            if (!room || !room->is_retroarch)
                continue;
            LibretroHost *host = [LibretroHost hostWithRoom:room];
            if (host)
                [hosts addObject:host];
        }
        netplay_rooms_free();
    }
    free(room_data);

    NSArray<LibretroHost *> *result = [hosts copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(result);
    });
}

static void netplay_refresh_lan_hosts_cb(const void *data)
{
    void (^completion)(NSArray<LibretroHost *> * _Nullable) = s_netplay_lan_host_list_completion;
    s_netplay_lan_host_list_completion = nil;

    if (!completion)
        return;

    const struct netplay_host_list *hosts =
        (const struct netplay_host_list *)data;
    NSMutableArray<LibretroHost *> *result = [NSMutableArray array];

    if (hosts && hosts->size > 0)
    {
        for (size_t i = 0; i < hosts->size; i++)
        {
            LibretroHost *host = [LibretroHost hostWithLANHost:&hosts->hosts[i]];
            if (host)
                [result addObject:host];
        }
    }

    NSArray<LibretroHost *> *hostsCopy = [result copy];
    dispatch_async(dispatch_get_main_queue(), ^{
        completion(hostsCopy);
    });
}

static void netplay_apply_nickname(NSString * _Nullable nickname)
{
    if (nickname.length == 0)
        return;

    settings_t *settings = config_get_ptr();
    if (!settings)
        return;

    NSString *trimmed = [nickname stringByTrimmingCharactersInSet:
        NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0)
        return;

    strlcpy(settings->paths.username, trimmed.UTF8String,
        sizeof(settings->paths.username));
}

- (BOOL)startNetplayHost:(NSString *)nickname
{
    if (!self.isRunning)
        return NO;
    netplay_apply_nickname(nickname);
    BOOL ok = command_event(CMD_EVENT_NETPLAY_ENABLE_HOST, NULL);
    if (ok)
        netplay_start_task_pump_if_paused(YES);
    return ok;
}

- (void)stopNetplayHost
{
    command_event(CMD_EVENT_NETPLAY_DISCONNECT, NULL);
}

- (void)refreshNetplayHostList:(void(^ _Nullable)(NSArray<LibretroHost *> * _Nullable hosts))completion
{
    if (!self.isRunning)
    {
        if (completion)
            completion(nil);
        return;
    }

    s_netplay_host_list_completion = [completion copy];
    if (!task_push_http_transfer(FILE_PATH_LOBBY_LIBRETRO_URL "list", true, NULL,
            netplay_refresh_rooms_http_cb, NULL))
    {
        s_netplay_host_list_completion = nil;
        if (completion)
            completion(nil);
        return;
    }
    netplay_start_task_pump_if_paused(NO);
}

- (void)refreshNetplayLANHostList:(void(^ _Nullable)(NSArray<LibretroHost *> * _Nullable hosts))completion
{
    if (!self.isRunning)
    {
        if (completion)
            completion(nil);
        return;
    }

    s_netplay_lan_host_list_completion = [completion copy];
    if (!task_push_netplay_lan_scan(netplay_refresh_lan_hosts_cb, 2500))
    {
        s_netplay_lan_host_list_completion = nil;
        if (completion)
            completion(nil);
        return;
    }
    netplay_start_task_pump_if_paused(NO);
}

- (BOOL)connectToNetplayHost:(LibretroHost *)host nickname:(NSString *)nickname
{
    if (!self.isRunning || !host)
        return NO;

    netplay_apply_nickname(nickname);

    char hostname[512];
    hostname[0] = '\0';

    if (host.hostMethod == LibretroHostMethodMITM
        && host.mitmAddress.length > 0
        && host.mitmSession.length > 0)
    {
        snprintf(hostname, sizeof(hostname), "%s|%d|%s",
            host.mitmAddress.UTF8String,
            (int)host.mitmPort,
            host.mitmSession.UTF8String);
    }
    else if (host.address.length > 0)
    {
        snprintf(hostname, sizeof(hostname), "%s|%d",
            host.address.UTF8String,
            (int)host.port);
    }
    else
        return NO;

    netplay_driver_ctl(RARCH_NETPLAY_CTL_ENABLE_CLIENT, NULL);
    return command_event(CMD_EVENT_NETPLAY_INIT_DIRECT, (void *)hostname);
}

- (void)disconnectNetplay
{
    [self stopNetplayHost];
}

- (BOOL)currentCoreSupportsNetplay
{
    if (!self.isRunning)
        return NO;

    if (netplay_driver_ctl(RARCH_NETPLAY_CTL_USE_CORE_PACKET_INTERFACE, NULL))
        return YES;

    uint64_t quirks = core_serialization_quirks();
    if (quirks & (RETRO_SERIALIZATION_QUIRK_INCOMPLETE
                | RETRO_SERIALIZATION_QUIRK_SINGLE_SESSION))
        return NO;

    return core_serialize_size() > 0;
}

#pragma mark - EKA2L1 Symbian

typedef struct {
    const char *initial_text;
    int max_length;
} retro_eka2l1_input_dialog_request_local;

typedef struct {
    const char *text;
    const char *button_yes;
    const char *button_no;
} retro_eka2l1_question_dialog_request_local;

static void (^_Nullable s_eka2l1_input_dialog_callback)(NSString *_Nullable initialText, NSInteger maxLength) = nil;
static void (^_Nullable s_eka2l1_question_dialog_callback)(NSString *_Nonnull text, NSString *_Nullable buttonYes, NSString *_Nullable buttonNo) = nil;

static void eka2l1_input_dialog_request_callback(const retro_eka2l1_input_dialog_request_local *_Nullable request) {
    if (!s_eka2l1_input_dialog_callback || !request) {
        return;
    }

    void (^callback)(NSString *_Nullable, NSInteger) = s_eka2l1_input_dialog_callback;
    if (request->max_length < 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(nil, -1);
        });
        return;
    }

    NSString *initialText = request->initial_text ? [NSString stringWithUTF8String:request->initial_text] : @"";
    NSInteger maxLength = request->max_length;
    dispatch_async(dispatch_get_main_queue(), ^{
        callback(initialText, maxLength);
    });
}

static void eka2l1_question_dialog_request_callback(const retro_eka2l1_question_dialog_request_local *_Nullable request) {
    if (!s_eka2l1_question_dialog_callback || !request || !request->text) {
        return;
    }

    NSString *text = [NSString stringWithUTF8String:request->text];
    NSString *buttonYes = request->button_yes ? [NSString stringWithUTF8String:request->button_yes] : nil;
    NSString *buttonNo = request->button_no ? [NSString stringWithUTF8String:request->button_no] : nil;
    void (^callback)(NSString *, NSString *, NSString *) = s_eka2l1_question_dialog_callback;

    dispatch_async(dispatch_get_main_queue(), ^{
        callback(text, buttonYes, buttonNo);
    });
}

- (void)registerEKA2L1InputDialog:(void(^ _Nullable)(NSString *_Nullable initialText, NSInteger maxLength))inputCallback
                   questionDialog:(void(^ _Nullable)(NSString *_Nonnull text, NSString *_Nullable buttonYes, NSString *_Nullable buttonNo))questionCallback {
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (!runloop_st || !runloop_st->lib_handle) {
        return;
    }

    s_eka2l1_input_dialog_callback = [inputCallback copy];
    s_eka2l1_question_dialog_callback = [questionCallback copy];

    typedef void (*set_input_dialog_callback_t)(void (*)(const retro_eka2l1_input_dialog_request_local *));
    typedef void (*set_question_dialog_callback_t)(void (*)(const retro_eka2l1_question_dialog_request_local *));

    set_input_dialog_callback_t set_input_callback =
        (set_input_dialog_callback_t)dylib_proc(runloop_st->lib_handle, "retro_eka2l1_set_input_dialog_callback");
    set_question_dialog_callback_t set_question_callback =
        (set_question_dialog_callback_t)dylib_proc(runloop_st->lib_handle, "retro_eka2l1_set_question_dialog_callback");

    if (set_input_callback) {
        set_input_callback(inputCallback ? eka2l1_input_dialog_request_callback : NULL);
        RARCH_LOG("[EKA2L1] input-dialog callback %s to core\n",
                  inputCallback ? "registered" : "cleared");
    } else {
        RARCH_LOG("[EKA2L1] retro_eka2l1_set_input_dialog_callback not found in core — rebuild eka2l1.libretro\n");
    }
    if (set_question_callback) {
        set_question_callback(questionCallback ? eka2l1_question_dialog_request_callback : NULL);
        RARCH_LOG("[EKA2L1] question-dialog callback %s to core\n",
                  questionCallback ? "registered" : "cleared");
    } else {
        RARCH_LOG("[EKA2L1] retro_eka2l1_set_question_dialog_callback not found in core — rebuild eka2l1.libretro\n");
    }
#endif
}

- (void)submitEKA2L1Input:(NSString *_Nullable)text {
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (!runloop_st || !runloop_st->lib_handle) {
        return;
    }

    typedef void (*submit_input_t)(const char *);
    submit_input_t submit_input = (submit_input_t)dylib_proc(runloop_st->lib_handle, "retro_eka2l1_submit_input");
    if (submit_input) {
        submit_input(text ? [text UTF8String] : "");
    }
#endif
}

- (void)submitEKA2L1QuestionResponse:(NSInteger)value {
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (!runloop_st || !runloop_st->lib_handle) {
        return;
    }

    typedef void (*submit_question_response_t)(int);
    submit_question_response_t submit_question_response =
        (submit_question_response_t)dylib_proc(runloop_st->lib_handle, "retro_eka2l1_submit_question_response");
    if (submit_question_response) {
        submit_question_response((int)value);
    }
#endif
}

static NSString *LibretroSymbianSaveRoot(void) {
    NSString *documentsDir = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [documentsDir stringByAppendingPathComponent:@"EKA2L1"];
}

typedef struct {
    uint32_t    index;
    uint32_t    epoc_version;
    uint32_t    machine_uid;
    const char *firmware_code;
    const char *manufacturer;
    const char *model;
    uint8_t     symbian_os_major;
    uint8_t     symbian_os_minor;
    const char *symbian_platform;
    uint32_t    screen_width;
    uint32_t    screen_height;
} retro_eka2l1_device_entry;

typedef struct {
    uint32_t    uid;
    const char *short_caption;
    const char *long_caption;
    const char *app_path;
    void       *icon_file;
    size_t      icon_file_size;
    char        drive_letter;
    bool        is_system_app;
    bool        is_hidden;
    bool        is_user_installed;
    retro_eka2l1_device_entry compatible_device;
} retro_eka2l1_app_entry;

typedef struct {
    int error;
    retro_eka2l1_device_entry device;
} retro_eka2l1_install_device_result;

typedef struct {
    uint32_t    uid;
    int32_t     index;
    const char *package_name;
    const char *vendor_name;
} retro_eka2l1_install_game_package;

typedef struct {
    int error;
    retro_eka2l1_app_entry app;
    const retro_eka2l1_install_game_package *packages;
    uint32_t package_count;
} retro_eka2l1_install_game_result;

typedef struct {
    retro_eka2l1_app_entry app;
    const retro_eka2l1_install_game_package *packages;
    uint32_t package_count;
} retro_eka2l1_game_entry;

typedef struct {
    uint32_t    uid;
    int32_t     index;
    const char *package_name;
    const char *vendor_name;
} retro_eka2l1_package_entry;

static dylib_t g_eka2l1_mgmt_lib = NULL;
static BOOL g_eka2l1_mgmt_lib_owned = NO;
static int g_eka2l1_mgmt_in_flight = 0;

static NSLock *LibretroEKA2L1MgmtLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSLock new];
    });
    return lock;
}

static BOOL LibretroPathLooksLikeEKA2L1(NSString *corePath) {
    if (!corePath.length) {
        return NO;
    }
    NSString *name = corePath.lastPathComponent.lowercaseString;
    return [name containsString:@"eka2l1"];
}

static dylib_t LibretroEKA2L1RunloopHandle(void) {
#ifdef HAVE_DYNAMIC
    runloop_state_t *runloop_st = runloop_state_get_ptr();
    if (runloop_st && runloop_st->lib_handle) {
        void *sym = (void *)dylib_proc(runloop_st->lib_handle, "retro_eka2l1_extension_version");
        if (sym) {
            return runloop_st->lib_handle;
        }
    }
#endif
    return NULL;
}

static dylib_t LibretroEKA2L1Open(BOOL *libOwned) {
    if (libOwned) {
        *libOwned = NO;
    }
    [LibretroEKA2L1MgmtLock() lock];
#ifdef HAVE_DYNAMIC
    dylib_t runloop_lib = LibretroEKA2L1RunloopHandle();
    if (runloop_lib) {
        g_eka2l1_mgmt_in_flight++;
        [LibretroEKA2L1MgmtLock() unlock];
        return runloop_lib;
    }
#endif
    if (g_eka2l1_mgmt_lib) {
        g_eka2l1_mgmt_in_flight++;
        dylib_t cached = g_eka2l1_mgmt_lib;
        [LibretroEKA2L1MgmtLock() unlock];
        return cached;
    }
    [LibretroEKA2L1MgmtLock() unlock];

    NSString *corePath = [[NSBundle mainBundle] pathForResource:@"eka2l1.libretro" ofType:@"framework" inDirectory:@"Frameworks"];
    if (!corePath) {
        return NULL;
    }
    NSString *dylibPath = [corePath stringByAppendingPathComponent:@"eka2l1.libretro"];
    dylib_t lib = dylib_load([dylibPath UTF8String]);
    if (!lib) {
        return NULL;
    }

    [LibretroEKA2L1MgmtLock() lock];
    if (g_eka2l1_mgmt_lib) {
        dylib_close(lib);
        lib = g_eka2l1_mgmt_lib;
    } else {
        g_eka2l1_mgmt_lib = lib;
        g_eka2l1_mgmt_lib_owned = YES;
    }
    g_eka2l1_mgmt_in_flight++;
    [LibretroEKA2L1MgmtLock() unlock];
    if (libOwned) {
        *libOwned = NO;
    }
    return lib;
}

static void LibretroEKA2L1Close(dylib_t lib, BOOL libOwned) {
    (void)lib;
    (void)libOwned;
    [LibretroEKA2L1MgmtLock() lock];
    if (g_eka2l1_mgmt_in_flight > 0) {
        g_eka2l1_mgmt_in_flight--;
    }
    [LibretroEKA2L1MgmtLock() unlock];
}

static void LibretroEKA2L1ShutdownManagement(void) {
    [LibretroEKA2L1MgmtLock() lock];
    dylib_t lib = g_eka2l1_mgmt_lib;
    if (!lib) {
        lib = LibretroEKA2L1RunloopHandle();
    }
    dylib_t to_close = NULL;
    if (g_eka2l1_mgmt_lib_owned && g_eka2l1_mgmt_lib && g_eka2l1_mgmt_in_flight == 0) {
        to_close = g_eka2l1_mgmt_lib;
        g_eka2l1_mgmt_lib = NULL;
        g_eka2l1_mgmt_lib_owned = NO;
    }
    [LibretroEKA2L1MgmtLock() unlock];

    if (lib) {
        typedef void (*shutdown_engine_t)(void);
        shutdown_engine_t shutdown_engine =
            (shutdown_engine_t)dylib_proc(lib, "retro_eka2l1_shutdown_engine");
        if (shutdown_engine) {
            shutdown_engine();
        }
    }
    if (to_close) {
        dylib_close(to_close);
    }
}

static BOOL LibretroEKA2L1ConfigureStorage(dylib_t lib) {
    typedef void (*set_paths_t)(const char *, const char *);
    set_paths_t set_paths = (set_paths_t)dylib_proc(lib, "retro_eka2l1_set_storage_paths");
    if (!set_paths) {
        return NO;
    }
    set_paths(NULL, [LibretroSymbianSaveRoot() UTF8String]);
    return YES;
}

static LibretroSymbianRomInstallResult LibretroSymbianRomResultFromError(int err) {
    if (err >= 0 && err <= 11) {
        return (LibretroSymbianRomInstallResult)err;
    }
    return LibretroSymbianRomInstallResultUnknown;
}

static LibretroSymbianGameInstallResult LibretroSymbianGameResultFromError(int err) {
    switch (err) {
        case 0:  return LibretroSymbianGameInstallResultOK;
        case 1:  return LibretroSymbianGameInstallResultNot_exist;
        case 5:  return LibretroSymbianGameInstallResultAlreadyExist;
        case 6:  return LibretroSymbianGameInstallResultGeneralFailure;
        case 50: return LibretroSymbianGameInstallResultAborted;
        case 51: return LibretroSymbianGameInstallResultInvalidPackage;
        case 52: return LibretroSymbianGameInstallResultUnsupportedFirmware;
        default: return LibretroSymbianGameInstallResultUnknown;
    }
}

static NSString *LibretroSymbianNonEmptyUTF8String(const char *value) {
    if (!value) {
        return nil;
    }
    // 64-bit iOS user mappings sit above 4GB. A truncated pointer or a uint32
    // leaked into a char* (the 0x5b4320 crash) is never a live C string.
    if ((uintptr_t)value < 0x100000000ull) {
        return nil;
    }
    if (!value[0]) {
        return nil;
    }
    NSString *string = [NSString stringWithUTF8String:value];
    if (!string.length) {
        return nil;
    }
    NSCharacterSet *nonNull = [[NSCharacterSet characterSetWithCharactersInString:@"\0"] invertedSet];
    NSString *trimmed = [[string componentsSeparatedByCharactersInSet:nonNull.invertedSet] componentsJoinedByString:@""];
    trimmed = [trimmed stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    return trimmed.length ? trimmed : nil;
}

static LibretroSymbianDevice *LibretroSymbianDeviceFromEntry(const retro_eka2l1_device_entry *entry) {
    if (!entry) {
        return nil;
    }
    LibretroSymbianDevice *device = [LibretroSymbianDevice new];
    device.index = (NSInteger)entry->index;
    device.epocVersion = (NSInteger)entry->epoc_version;
    device.machineUid = (NSInteger)entry->machine_uid;
    device.screenWidth = (NSInteger)entry->screen_width;
    device.screenHeight = (NSInteger)entry->screen_height;
    device.firmwareCode = LibretroSymbianNonEmptyUTF8String(entry->firmware_code);
    device.manufacturer = LibretroSymbianNonEmptyUTF8String(entry->manufacturer);
    device.model = LibretroSymbianNonEmptyUTF8String(entry->model);
    device.symbianOsMajor = entry->symbian_os_major;
    device.symbianOsMinor = entry->symbian_os_minor;
    device.symbianPlatform = LibretroSymbianNonEmptyUTF8String(entry->symbian_platform);
    return device;
}

static LibretroSymbianGame *LibretroSymbianGameFromAppAndPackages(const retro_eka2l1_app_entry *app,
                                                                  const retro_eka2l1_install_game_package *packages,
                                                                  uint32_t package_count) {
    if (!app) {
        return nil;
    }
    LibretroSymbianGame *game = [LibretroSymbianGame new];
    game.uid = (NSInteger)app->uid;
    game.shortCaption = LibretroSymbianNonEmptyUTF8String(app->short_caption);
    game.longCaption = LibretroSymbianNonEmptyUTF8String(app->long_caption);
    game.appPath = LibretroSymbianNonEmptyUTF8String(app->app_path);
    game.driveLetter = app->drive_letter ? [NSString stringWithFormat:@"%c", app->drive_letter] : @"";
    game.isSystemApp = app->is_system_app;
    game.isHidden = app->is_hidden;
    game.isUserInstalled = app->is_user_installed;
    game.compatibleDevice = LibretroSymbianDeviceFromEntry(&app->compatible_device);
    if (app->icon_file && app->icon_file_size > 0) {
        NSData *iconData = [NSData dataWithBytes:app->icon_file length:app->icon_file_size];
        game.icon = [UIImage imageWithData:iconData];
    }
    NSMutableArray<LibretroSymbianGamePackage *> *packageItems = [NSMutableArray arrayWithCapacity:package_count];
    if (packages && package_count > 0) {
        for (uint32_t i = 0; i < package_count; ++i) {
            const retro_eka2l1_install_game_package *pkg = &packages[i];
            LibretroSymbianGamePackage *item = [LibretroSymbianGamePackage new];
            item.uid = (NSInteger)pkg->uid;
            item.index = (NSInteger)pkg->index;
            item.packageName = LibretroSymbianNonEmptyUTF8String(pkg->package_name);
            item.vendorName = LibretroSymbianNonEmptyUTF8String(pkg->vendor_name);
            [packageItems addObject:item];
        }
    }
    game.packages = packageItems;
    return game;
}

static LibretroSymbianGame *LibretroSymbianGameFromInstallResult(const retro_eka2l1_install_game_result *result) {
    if (!result) {
        return nil;
    }
    return LibretroSymbianGameFromAppAndPackages(&result->app, result->packages, result->package_count);
}

static LibretroSymbianGame *LibretroSymbianGameFromGameEntry(const retro_eka2l1_game_entry *entry) {
    if (!entry) {
        return nil;
    }
    LibretroSymbianGame *game = LibretroSymbianGameFromAppAndPackages(&entry->app, entry->packages, entry->package_count);
    return game;
}

+ (void)installSymbianROM:(NSString *_Nonnull)romPath
                 rpkgPath:(NSString *_Nullable)rpkgPath
               completion:(void(^_Nullable)(LibretroSymbianRomInstallResult result, LibretroSymbianDevice *_Nullable device))completion {
    NSString *rom = romPath;
    NSString *rpkg = rpkgPath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LibretroSymbianRomInstallResult mappedResult = LibretroSymbianRomInstallResultUnknown;
        LibretroSymbianDevice *device = nil;

        BOOL libOwned = YES;
        dylib_t lib = LibretroEKA2L1Open(&libOwned);
        if (lib && LibretroEKA2L1ConfigureStorage(lib)) {
            typedef int (*install_rom_ex_t)(const char *, const char *, retro_eka2l1_install_device_result *);
            install_rom_ex_t install_rom_ex = (install_rom_ex_t)dylib_proc(lib, "retro_eka2l1_install_rom_ex");
            if (install_rom_ex) {
                retro_eka2l1_install_device_result out = {0};
                const char *rom_c = rom.UTF8String;
                const char *rpkg_c = rpkg.length ? rpkg.UTF8String : NULL;
                const int err = install_rom_ex(rom_c, rpkg_c, &out);
                mappedResult = LibretroSymbianRomResultFromError(err);
                if (mappedResult == LibretroSymbianRomInstallResultOK) {
                    device = LibretroSymbianDeviceFromEntry(&out.device);
                    // Core fills out.device from an in-memory cache; if rescan wiped
                    // the list (older cores) fall back to get_devices.
                    if (device && !device.firmwareCode.length) {
                        typedef const retro_eka2l1_device_entry *(*get_devices_t)(uint32_t *);
                        get_devices_t get_devices =
                            (get_devices_t)dylib_proc(lib, "retro_eka2l1_get_devices");
                        if (get_devices) {
                            uint32_t count = 0;
                            const retro_eka2l1_device_entry *devs = get_devices(&count);
                            if (count > 0 && devs) {
                                device = LibretroSymbianDeviceFromEntry(&devs[count - 1]);
                            }
                        }
                    }
                }
            }
        }
        LibretroEKA2L1Close(lib, libOwned);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(mappedResult, device);
            }
        });
    });
}

+ (void)installSymbianGame:(NSString *_Nonnull)gamePath
                completion:(void(^_Nullable)(LibretroSymbianGameInstallResult result, LibretroSymbianGame *_Nullable game))completion {
    NSString *path = gamePath;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        LibretroSymbianGameInstallResult mappedResult = LibretroSymbianGameInstallResultUnknown;
        LibretroSymbianGame *game = nil;

        BOOL libOwned = YES;
        dylib_t lib = LibretroEKA2L1Open(&libOwned);
        if (lib && LibretroEKA2L1ConfigureStorage(lib)) {
            typedef int (*install_game_t)(const char *, retro_eka2l1_install_game_result *);
            install_game_t install_game = (install_game_t)dylib_proc(lib, "retro_eka2l1_install_game");
            if (install_game) {
                retro_eka2l1_install_game_result out = {0};
                const int err = install_game(path.UTF8String, &out);
                mappedResult = LibretroSymbianGameResultFromError(err);
                if (mappedResult == LibretroSymbianGameInstallResultOK) {
                    game = LibretroSymbianGameFromInstallResult(&out);
                }
            }
        }
        LibretroEKA2L1Close(lib, libOwned);

        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(mappedResult, game);
            }
        });
    });
}

+ (void)uninstallSymbianGameWithUid:(NSInteger)uid index:(NSInteger)index {
    BOOL libOwned = YES;
    dylib_t lib = LibretroEKA2L1Open(&libOwned);
    if (!lib) {
        return;
    }
    if (!LibretroEKA2L1ConfigureStorage(lib)) {
        LibretroEKA2L1Close(lib, libOwned);
        return;
    }

    typedef bool (*uninstall_package_t)(uint32_t, int32_t);
    uninstall_package_t uninstall_package = (uninstall_package_t)dylib_proc(lib, "retro_eka2l1_uninstall_package");
    if (uninstall_package) {
        uninstall_package((uint32_t)uid, (int32_t)index);
    }
    LibretroEKA2L1Close(lib, libOwned);
}

+ (NSArray<LibretroSymbianDevice*> *_Nullable)getSymbianDevices {
    BOOL libOwned = YES;
    dylib_t lib = LibretroEKA2L1Open(&libOwned);
    if (!lib) {
        return nil;
    }
    if (!LibretroEKA2L1ConfigureStorage(lib)) {
        LibretroEKA2L1Close(lib, libOwned);
        return nil;
    }
    
    typedef const retro_eka2l1_device_entry *  (*retro_eka2l1_get_devices_t)(uint32_t *out_count);
    retro_eka2l1_get_devices_t get_devices = (retro_eka2l1_get_devices_t)dylib_proc(lib, "retro_eka2l1_get_devices");
    
    NSArray<LibretroSymbianDevice *> *result = nil;
    if (get_devices) {
        uint32_t count = 0;
        const retro_eka2l1_device_entry *devs = get_devices(&count);
        NSMutableArray<LibretroSymbianDevice *> *items = NSMutableArray.new;
        for (uint32_t i = 0; i < count && devs; ++i) {
            const retro_eka2l1_device_entry *d = &devs[i];
            LibretroSymbianDevice *device = LibretroSymbianDeviceFromEntry(d);
            if (device) {
                [items addObject:device];
            }
        }
        if (items.count > 0) {
            result = items;
        }
    }
    LibretroEKA2L1Close(lib, libOwned);
    return result;
}

+ (BOOL)isSymbianRomNeedsRpkg:(NSString *_Nonnull)romPath {
    BOOL libOwned = YES;
    dylib_t lib = LibretroEKA2L1Open(&libOwned);
    if (!lib) {
        return NO;
    }
    if (!LibretroEKA2L1ConfigureStorage(lib)) {
        LibretroEKA2L1Close(lib, libOwned);
        return NO;
    }
    
    typedef bool (*rom_needs_rpkg_t)(const char *);
    rom_needs_rpkg_t rom_needs_rpkg = (rom_needs_rpkg_t)dylib_proc(lib, "retro_eka2l1_rom_needs_rpkg");
    if (!rom_needs_rpkg) {
        LibretroEKA2L1Close(lib, libOwned);
        return NO;
    }
    BOOL result = rom_needs_rpkg([romPath UTF8String]);
    LibretroEKA2L1Close(lib, libOwned);
    return result;
}

+ (NSArray<LibretroSymbianGame*> *_Nullable)getSymbianGamesForDeviceIndex:(NSInteger)deviceIndex
                                                                appKinds:(LibretroSymbianAppKind)appKinds {
    BOOL libOwned = YES;
    dylib_t lib = LibretroEKA2L1Open(&libOwned);
    if (!lib) {
        return nil;
    }
    if (!LibretroEKA2L1ConfigureStorage(lib)) {
        LibretroEKA2L1Close(lib, libOwned);
        return nil;
    }

    typedef const retro_eka2l1_game_entry *(*get_games_t)(uint32_t, uint32_t, uint32_t *);
    get_games_t get_games = (get_games_t)dylib_proc(lib, "retro_eka2l1_get_games");

    NSArray<LibretroSymbianGame *> *result = nil;
    if (get_games) {
        uint32_t count = 0;
        const retro_eka2l1_game_entry *games = get_games((uint32_t)deviceIndex, (uint32_t)appKinds, &count);
        NSMutableArray<LibretroSymbianGame *> *items = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count && games; ++i) {
            LibretroSymbianGame *game = LibretroSymbianGameFromGameEntry(&games[i]);
            if (game) {
                [items addObject:game];
            }
        }
        if (items.count > 0) {
            result = items;
        }
    }

    LibretroEKA2L1Close(lib, libOwned);
    return result;
}

+ (void)shutdownSymbianManagementSession {
    LibretroEKA2L1ShutdownManagement();
}

+ (void)uninstallSymbianDeviceWithFirmwareCode:(NSString *_Nonnull)FirmwareCode {
    BOOL libOwned = YES;
    dylib_t lib = LibretroEKA2L1Open(&libOwned);
    if (!lib) {
        return;
    }
    if (!LibretroEKA2L1ConfigureStorage(lib)) {
        LibretroEKA2L1Close(lib, libOwned);
        return;
    }

    typedef bool (*uninstall_rom_t)(const char *);
    uninstall_rom_t uninstall_rom = (uninstall_rom_t)dylib_proc(lib, "retro_eka2l1_uninstall_rom");
    if (uninstall_rom) {
        uninstall_rom([FirmwareCode UTF8String]);
    }
    LibretroEKA2L1Close(lib, libOwned);
}


@end
