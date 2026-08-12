#import <UIKit/UIKit.h>
#include <MediaRemote/MediaRemote.h>
#include <notify.h>

static NSString * const kLikeToggleDarwinNotification = @"com.brkr1.tweaks.spotilovereborn/toggle";

static const char * const kLikedStateNotifyName = "com.brkr1.tweaks.spotilovereborn/isLikedState";

#ifdef __cplusplus
extern "C" {
#endif

BOOL lx_isPlayingFromSpotify(void);

static inline void lx_setLikedState(BOOL isLiked) {
    static int token = -1;
    if (token == -1 && notify_register_check(kLikedStateNotifyName, &token) != NOTIFY_STATUS_OK) {
        token = -1;
        return;
    }
    notify_set_state(token, isLiked ? 1 : 0);
    notify_post(kLikedStateNotifyName);
}

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

#ifdef __cplusplus
}
#endif

@interface SBApplication: NSObject
    @property (nonatomic, readonly) NSString* bundleIdentifier;
@end

@interface SBMediaController: NSObject
    @property (nonatomic, readonly) SBApplication* nowPlayingApplication;
    + (instancetype) sharedInstance;
@end
