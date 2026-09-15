#import <UIKit/UIKit.h>
#include <MediaRemote/MediaRemote.h>
#include <notify.h>
#include <dlfcn.h>

// Spotify channel names kept as the original, unsuffixed constants so SpotifyHalf
// needs no changes at all.
static NSString * const kLikeToggleDarwinNotification = @"com.brkr1.tweaks.spotilovereborn/toggle";
static const char * const kLikedStateNotifyName = "com.brkr1.tweaks.spotilovereborn/isLikedState";

static NSString * const kLikeToggleDarwinNotificationYouTubeMusic = @"com.brkr1.tweaks.spotilovereborn/toggle.ytmusic";
static const char * const kLikedStateNotifyNameYouTubeMusic = "com.brkr1.tweaks.spotilovereborn/isLikedState.ytmusic";

static NSString * const kLXSpotifyBundleID = @"com.spotify.client";
static NSString * const kLXYouTubeMusicBundleID = @"com.google.ios.youtubemusic";

typedef NS_ENUM(NSInteger, LXMusicSource) {
    LXMusicSourceUnknown = 0,
    LXMusicSourceSpotify,
    LXMusicSourceYouTubeMusic,
};

#ifdef __cplusplus
extern "C" {
#endif

// Called by the Spotify half whenever it knows the real liked state.
static inline void lx_setLikedState(BOOL isLiked) {
    static int token = -1;
    if (token == -1 && notify_register_check(kLikedStateNotifyName, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    notify_set_state(token, isLiked ? 1 : 0);
    notify_post(kLikedStateNotifyName);
}

// Called by the MediaRemoteUI half to read Spotify's real liked state. Always live.
static inline BOOL lx_getLikedState(void) {
    static int token = -1;
    if (token == -1 && notify_register_check(kLikedStateNotifyName, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return NO;
    }
    uint64_t value = 0;
    notify_get_state(token, &value);
    return value != 0;
}

// Same pair as above, for the YouTube Music half.
static inline void lx_setLikedStateYouTubeMusic(BOOL isLiked) {
    static int token = -1;
    if (token == -1 && notify_register_check(kLikedStateNotifyNameYouTubeMusic, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    notify_set_state(token, isLiked ? 1 : 0);
    notify_post(kLikedStateNotifyNameYouTubeMusic);
}

static inline BOOL lx_getLikedStateYouTubeMusic(void) {
    static int token = -1;
    if (token == -1 && notify_register_check(kLikedStateNotifyNameYouTubeMusic, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return NO;
    }
    uint64_t value = 0;
    notify_get_state(token, &value);
    return value != 0;
}

// MRMediaRemoteGetNowPlayingClient / MRNowPlayingClientGetBundleIdentifier /
// MRMediaRemoteRegisterForNowPlayingNotifications aren't in the MediaRemote.h Theos links
// against, so resolve them at runtime the same way NextUp3 does (its own comments call this
// "verified" against real devices).
static inline void *lx_mediaRemoteHandle(void) {
    static void *handle;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    });
    return handle;
}

static inline LXMusicSource lx_sourceForBundleID(NSString *bundleID) {
    if ([bundleID isEqualToString: kLXSpotifyBundleID]) {
        return LXMusicSourceSpotify;
    }
    if ([bundleID isEqualToString: kLXYouTubeMusicBundleID]) {
        return LXMusicSourceYouTubeMusic;
    }
    return LXMusicSourceUnknown;
}

// Asynchronously resolves which app currently owns the system Now Playing info and writes it
// into *outSource, calling onChange() if it moved to a different app. Never blocks the calling
// thread (MRMediaRemoteGetNowPlayingClient's callback lands on dispatch_get_main_queue(), so a
// synchronous wait here from the main thread would deadlock).
// TODO(debug): remove once multi-app source routing is confirmed working for YouTube Music.
static inline void lx_refreshNowPlayingSource(LXMusicSource *outSource, dispatch_block_t onChange) {
    void *handle = lx_mediaRemoteHandle();
    if (!handle) {
        NSLog(@"[SpotiLoveReborn][MRU-DEBUG] lx_refreshNowPlayingSource: MediaRemote dlopen failed");
        return;
    }
    void (*getClient)(dispatch_queue_t, void (^)(id)) =
        (void (*)(dispatch_queue_t, void (^)(id))) dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
    NSString *(*getBundleID)(id) = (NSString *(*)(id)) dlsym(handle, "MRNowPlayingClientGetBundleIdentifier");
    NSString *(*getParentBundleID)(id) = (NSString *(*)(id)) dlsym(handle, "MRNowPlayingClientGetParentAppBundleIdentifier");
    if (!getClient || (!getBundleID && !getParentBundleID)) {
        NSLog(@"[SpotiLoveReborn][MRU-DEBUG] lx_refreshNowPlayingSource: symbols missing getClient=%p getBundleID=%p getParentBundleID=%p",
              (void *) getClient, (void *) getBundleID, (void *) getParentBundleID);
        return;
    }

    getClient(dispatch_get_main_queue(), ^(id client) {
        NSString *bundleID = (client && getBundleID) ? getBundleID(client) : nil;
        if (bundleID.length == 0 && client && getParentBundleID) {
            bundleID = getParentBundleID(client);
        }
        LXMusicSource newSource = lx_sourceForBundleID(bundleID);
        NSLog(@"[SpotiLoveReborn][MRU-DEBUG] lx_refreshNowPlayingSource: client=%@ bundleID=%@ resolvedSource=%ld (was %ld)",
              client, bundleID, (long) newSource, (long) *outSource);
        if (newSource != *outSource) {
            *outSource = newSource;
            if (onChange) {
                onChange();
            }
        }
    });
}

// Registers `handler` to run whenever the system's Now Playing app changes. Call once from
// %ctor; combine with an initial lx_refreshNowPlayingSource() call since this notification only
// fires on change, not for the app already playing when the dylib loads.
static inline void lx_registerForNowPlayingAppChanges(dispatch_block_t handler) {
    void *handle = lx_mediaRemoteHandle();
    if (!handle) {
        return;
    }
    void (*reg)(dispatch_queue_t) = (void (*)(dispatch_queue_t)) dlsym(handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (reg) {
        reg(dispatch_get_main_queue());
    }
    NSString * __unsafe_unretained *namePtr =
        (NSString * __unsafe_unretained *) dlsym(handle, "kMRMediaRemoteNowPlayingApplicationDidChangeNotification");
    NSString *name = namePtr ? *namePtr : @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification";
    [[NSNotificationCenter defaultCenter] addObserverForName: name
                                                       object: nil
                                                        queue: [NSOperationQueue mainQueue]
                                                   usingBlock: ^(NSNotification *note) {
        handler();
    }];
}

#ifdef __cplusplus
}
#endif
