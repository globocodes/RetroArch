//
//  LibretroCore.h
//  LibretroCore
//
//  Created by Daiuno on 2025/4/22.
//  Copyright © 2025 Manic EMU. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "CheevosBridge.h"
#import "AzaharKeyboardConfig.h"
#import "LibretroShaders.h"
#import "LibretroKeyboardCode.h"
#import "LibretroCoreOptions.h"
#import "LibretroDisk.h"
#import "LibretroPSPGame.h"
#import "LibretroHost.h"
#import "LibretroSymbian.h"

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSUInteger, LibretroButton) {
   LibretroButtonUp = 4,
   LibretroButtonDown = 5,
   LibretroButtonLeft = 6,
   LibretroButtonRight = 7,
   LibretroButtonA = 8,
   LibretroButtonB = 0,
   LibretroButtonX = 9,
   LibretroButtonY = 1,
   LibretroButtonSelect = 2,
   LibretroButtonStart = 3,
   LibretroButtonL1 = 10,
   LibretroButtonR1 = 11,
   LibretroButtonL2 = 12,
   LibretroButtonR2 = 13,
   LibretroButtonL3 = 14,
   LibretroButtonR3 = 15,
};

/// Wii controller type. Raw values match ExtraKey.wiiController / R.Strings.WiiControllers.
/// Device IDs come from Dolphin `DolphinLibretro/Input.cpp` and are applied to ports 0–3.
typedef NS_ENUM(NSInteger, LibretroWiiController) {
    /// WiiMote + Classic Controller Pro. `RETRO_DEVICE_WIIMOTE_CC_PRO` = (5 << 8) | JOYPAD
    LibretroWiiControllerClassicPro = 0,
    /// WiiMote. `RETRO_DEVICE_WIIMOTE` = JOYPAD
    LibretroWiiControllerWiimote = 1,
    /// WiiMote (sideways). `RETRO_DEVICE_WIIMOTE_SW` = (2 << 8) | JOYPAD
    LibretroWiiControllerWiimoteSideways = 2,
    /// WiiMote + Nunchuk. `RETRO_DEVICE_WIIMOTE_NC` = (3 << 8) | JOYPAD
    LibretroWiiControllerWiimoteNunchuk = 3,
};

extern NSString * const RetroAchievementsNotification;
/// Netplay event notification. userInfo: @{@"event": @(LibretroNetplayEvent), @"info": NSString (related nickname, may be empty)}
extern NSString * const LibretroNetplayEventNotification;

/// Netplay events (1:1 with enum netplay_frontend_event in netplay.h)
typedef NS_ENUM(NSInteger, LibretroNetplayEvent) {
    /// Local host started successfully
    LibretroNetplayEventHostStarted = 0,
    /// Local host stopped
    LibretroNetplayEventHostStopped,
    /// Connected to a host as a client (info = host nickname)
    LibretroNetplayEventConnected,
    /// Disconnected from the host as a client
    LibretroNetplayEventDisconnected,
    /// Host side: a client connected (info = peer nickname)
    LibretroNetplayEventPeerConnected,
    /// Host side: a client disconnected (info = peer nickname)
    LibretroNetplayEventPeerDisconnected,
    /// A player joined gameplay (info = nickname; empty string means local)
    LibretroNetplayEventPeerJoined,
    /// A player left gameplay and became a spectator (info = nickname; empty string means local)
    LibretroNetplayEventPeerLeft,
};

@interface LibretroCore : NSObject

@property(nonatomic, strong) id retroArch_iOS;
@property (nonatomic, copy, nullable) NSString *workspace;
@property (assign) BOOL forbitJIT;

+ (instancetype)sharedInstance;

- (UIViewController *)startWithCustomSaveDir:(NSString *_Nullable)customSaveDir;
- (void)pause;
- (BOOL)isPaused;
- (void)resume;
- (void)stop;
- (void)mute:(BOOL)mute;
- (void)snapshot:(void(^ _Nullable)(UIImage *_Nullable image))completion;
- (BOOL)saveState:(void(^ _Nullable)(NSString *_Nullable path))completion;
- (BOOL)loadState:(NSString *_Nonnull)path;
- (void)fastForward:(float)rate;
/// Enable or disable rewind (when on, snapshots are recorded in the background; costs memory and CPU)
/// @param granularity Rewind frame interval (snapshot every N frames; each rewind step spans this many frames). Default 10
/// @param bufferSizeMB Rewind buffer size in MB. Default 20
/// @param bufferSizeStepMB Rewind buffer size adjustment step in MB. Default 10
/// @param mute Whether to mute while rewinding. Default NO
- (void)setRewindEnable:(BOOL)enable
            granularity:(unsigned)granularity
           bufferSizeMB:(unsigned)bufferSizeMB
       bufferSizeStepMB:(unsigned)bufferSizeStepMB
                   mute:(BOOL)mute;
/// Convenience method with defaults: granularity=10, bufferSizeMB=20, bufferSizeStepMB=10, mute=NO
- (void)setRewindEnable:(BOOL)enable;
/// Start (YES, hold-to-rewind) or stop (NO) rewinding. Rewind must be enabled first
- (void)setRewind:(BOOL)rewinding;
- (void)reload;
- (void)reloadByKeepState:(BOOL)keepState;
- (BOOL)loadGame:(NSString *_Nonnull)gamePath corePath:(NSString *_Nonnull)corePath completion:(void(^ _Nullable)(NSDictionary *_Nullable))completion;
- (void)loadCoreWithoutContent:(NSString *_Nonnull)corePath;
- (void)loadCoreWithoutRunning:(NSString *_Nonnull)corePath;
- (NSArray<CoreOptionCategory *> *_Nullable)getCoreOptions:(NSString *_Nonnull)corePath;
- (NSArray<CoreOptionCategory *> *_Nullable)getCoreOptions:(NSString *_Nonnull)corePath resetOptFile:(BOOL)resetOptFile;
- (void)sendEvent:(UIEvent * _Nonnull)event;
- (void)pressButton:(LibretroButton)button playerIndex:(unsigned)playerIndex;
- (void)releaseButton:(LibretroButton)button playerIndex:(unsigned)playerIndex;
- (void)pressKeyboard:(LibretroKeyboardCode *_Nonnull)keyboardCode;
- (void)releaseKeyboard:(LibretroKeyboardCode *_Nonnull)keyboardCode;
- (void)handleUIPress:(UIPress *)press withEvent:(UIPressesEvent *)event down:(BOOL)down;
- (void)keyboardEvent:(UIEvent *_Nonnull)event;
/// x, y range: -1 to 1
- (void)moveStick:(BOOL)isLeft x:(CGFloat)x y:(CGFloat)y playerIndex:(unsigned)playerIndex;
- (void)updatePSPCheat:(NSString *_Nonnull)cheatCode cheatFilePath:(NSString *_Nonnull)cheatFilePath reloadGame:(BOOL)reloadGame;
- (void)updateCoreConfig:(NSString *_Nonnull)coreName key:(NSString *_Nonnull)key value:(NSString *_Nonnull)value reload:(BOOL)reload;
- (void)updateCoreConfig:(NSString *_Nonnull)coreName configs:(NSDictionary<NSString*, NSString*> *_Nullable)configs reload:(BOOL)reload;
- (void)updateCoreConfig:(NSString *_Nonnull)coreName content:(NSString *_Nullable)content reload:(BOOL)reload;
- (void)updateRunningCoreConfigs:(NSDictionary<NSString*, NSString*> *_Nullable)configs flush:(BOOL)flush;
- (void)updateLibretroConfig:(NSString *_Nonnull)key value:(NSString *_Nonnull)value;
- (void)updateLibretroConfigs:(NSDictionary<NSString*, NSString*> *_Nullable)configs;
/// Write RetroArch runtime settings in the current process. Takes effect immediately; does not write retroarch.cfg
- (void)updateRuningLibretroConfigs:(NSDictionary<NSString*, NSString*> *_Nullable)configs;
- (BOOL)setShader:(NSString *_Nullable)path;
- (NSArray<ShaderParameter *> *_Nullable)loadParameters;
- (void)updateParameterWith:(NSString *_Nonnull)identifier
                      value:(float)value
               changingPath:(NSString *_Nonnull)changingPath;
- (void)appendShader:(NSString *_Nonnull)path prepend:(BOOL)prepend;
- (void)addCheatCode:(NSString *_Nonnull)code index:(unsigned)index enable:(BOOL)enable;
- (void)resetCheatCode;
+ (BOOL)JITAvailable;
- (NSString * _Nullable)coreConfigValue:(NSString * _Nonnull)coreName key:(NSString * _Nonnull)key;
- (NSString * _Nullable)libretroConfigValue:(NSString * _Nonnull)key;
- (void)setRespectSilentMode:(BOOL)respect;
- (void)setDiskIndex:(unsigned)index delay:(BOOL)delay;
- (void)setDiskIndex2:(unsigned)index;
- (LibretroDisk *_Nullable)getDiskInfo;
- (BOOL)insertDisk:(NSString *_Nonnull)path;
- (void)setPSXAnalog:(BOOL)isAnalog;
- (void)setWiiController:(LibretroWiiController)type;
- (void)setReloadDelay:(double)delay;
- (void)turnOffHardcode;
- (void)resetRetroAchievements;
- (void)setCustomSaveExtension:(NSString *_Nullable)customSaveExtension;
- (void)setEnableRumble:(BOOL)enable;
- (BOOL)getSensorEnable:(int)playerIndex;
- (void)startWFCStatusMonitor;
- (void)setNDSCustomLayout:(NSString *_Nullable)layout;
- (void)setNDSWFCDNS:(NSString *_Nullable)nds;
- (void)setPSPCustomServerAddress:(NSString *_Nullable)address;
- (void)setPSPCustomServerPort:(NSString *_Nullable)port;
- (void)setCoreOptionNeedsUpdate;
- (void)sendTouchEventX:(CGFloat)x y:(CGFloat)y;
- (void)releaseTouchEvent;
- (void)sendMultiTouchEvent:(NSArray<NSDictionary *> *)points;
- (NSString *_Nullable)getCoreConfigs:(NSString *_Nonnull)coreName;
- (void)updateFBNeoCheatCode:(NSArray<NSString *> *_Nonnull)keys enable:(BOOL)enable;
- (void)setFastforwardFrameSkip:(BOOL)frameSkip;
- (void)set3DSCustomLayout:(NSString *_Nullable)layout;
- (void)setLibretroLogMonitor:(BOOL)enable;
/// Manic MP: write one line to RetroArch's log (the Dolphin session log in
/// Documents/Netplay Logs) as "[Input] <line>". Safe from any thread.
- (void)logDiagnosticsLine:(NSString *_Nonnull)line;
- (void)loadAmiibo:(NSString *_Nonnull)path;
- (BOOL)isSearchingAmiibo;
- (void)registerAzaharKeyboard:(void(^ _Nullable)(AzaharKeyboardConfig *_Nonnull config))callback;
- (void)inputAzaharKeyboard:(NSString *_Nullable)text buttonType:(AzaharButtonType)buttonType;
- (void)installAzaharCIA:(NSString *_Nonnull)path;
+ (NSString *_Nullable)getPSPGameIDWithRomPath:(NSString *_Nonnull)romPath;
+ (LibretroPSPGame *_Nullable)installPSPGameWithZipPath:(NSString *_Nonnull)zipPath destDir:(NSString *_Nonnull)destDir;
- (void)setFullScreen:(BOOL)isFullScreen;
+ (UIImage *_Nullable)previewImageWithImage:(UIImage *_Nonnull)image shaderPath:(NSString *_Nonnull)shaderPath;
+ (void)clearPreviewCache;

#pragma mark - Netplay
/**
 [{
 "hasPassword": false,
 "coreVersion": "(SVN) 5cd4a43",
 "retroarchVersion": "1.22.2",
 "port": 55435,
 "mitmAddress": null,
 "hostMethod": "unknown",
 "frontend": "darwin ARMv8",
 "subsystemName": "N/A",
 "contentCRC": 1223877203,
 "address": "122.118.108.39",
 "connectable": false,
 "mitmPort": 0,
 "hasSpectatePassword": false,
 "mitmSession": null,
 "coreName": "FCEUmm",
 "nickname": "Anonymous",
 "country": "tw",
 "isLan": false,
 "content": "Battle City (Bootleg) (VS)"
}]
 */
/// Start netplay as a game host (game must already be loaded and not paused).
/// Savestate-sync cores reload content; netpacket cores (gpSP, DOSBox-pure) keep the current session.
/// @param nickname Netplay nickname shown in LAN/lobby discovery. Empty keeps the current config (Anonymous if unset)
/// Result is delivered via LibretroNetplayEventNotification HostStarted
- (BOOL)startNetplayHost:(NSString * _Nullable)nickname;
/// Stop the netplay host
- (void)stopNetplayHost;
/// Refresh the internet netplay host list (async, callback on main thread; hosts is nil on failure)
- (void)refreshNetplayHostList:(void(^ _Nullable)(NSArray<LibretroHost *> * _Nullable hosts))completion;
/// Refresh the LAN netplay host list (async, callback on main thread, ~2.5s scan timeout; hosts is nil on failure)
- (void)refreshNetplayLANHostList:(void(^ _Nullable)(NSArray<LibretroHost *> * _Nullable hosts))completion;
/// Connect to a host as a client (same game/core as the host must already be loaded and not paused)
/// @param nickname Local netplay nickname, visible to the host. Empty keeps the current config (Anonymous if unset)
/// Result is delivered via LibretroNetplayEventNotification Connected/Disconnected
- (BOOL)connectToNetplayHost:(LibretroHost *_Nonnull)host nickname:(NSString * _Nullable)nickname;
/// Disconnect the current netplay session (client disconnect / host stop; equivalent to stopNetplayHost)
- (void)disconnectNetplay;
/// Whether the currently loaded core supports netplay (call after loading a game)
- (BOOL)currentCoreSupportsNetplay;

#pragma mark - Symbian
+ (void)installSymbianROM:(NSString *_Nonnull)romPath
                 rpkgPath:(NSString *_Nullable)rpkgPath
               completion:(void(^_Nullable)(LibretroSymbianRomInstallResult result, LibretroSymbianDevice *_Nullable device))completion;
+ (void)installSymbianGame:(NSString *_Nonnull)gamePath
                completion:(void(^_Nullable)(LibretroSymbianGameInstallResult result, LibretroSymbianGame *_Nullable game))completion;
+ (void)uninstallSymbianGameWithUid:(NSInteger)uid index:(NSInteger)index;
+ (NSArray<LibretroSymbianDevice*> *_Nullable)getSymbianDevices;
+ (BOOL)isSymbianRomNeedsRpkg:(NSString *_Nonnull)romPath;
+ (NSArray<LibretroSymbianGame*> *_Nullable)getSymbianGamesForDeviceIndex:(NSInteger)deviceIndex
                                                                appKinds:(LibretroSymbianAppKind)appKinds;
+ (void)uninstallSymbianDeviceWithFirmwareCode:(NSString *_Nonnull)FirmwareCode;
/// Drop a cached EKA2L1 management session (firmware/game list/install). Called
/// automatically when loading a non-EKA2L1 core. Guest play uses unload/deinit.
+ (void)shutdownSymbianManagementSession;
- (void)registerEKA2L1InputDialog:(void(^ _Nullable)(NSString *_Nullable initialText, NSInteger maxLength))inputCallback
                   questionDialog:(void(^ _Nullable)(NSString *_Nonnull text, NSString *_Nullable buttonYes, NSString *_Nullable buttonNo))questionCallback;
/// Pass user-entered text. `nil` or `@""` cancels the text-input dialog.
- (void)submitEKA2L1Input:(NSString *_Nullable)text;
/// `value`: 1 = user tapped `buttonYes`, 0 = user tapped `buttonNo`. Unrelated to text-input dialogs.
- (void)submitEKA2L1QuestionResponse:(NSInteger)value;

@end

NS_ASSUME_NONNULL_END
