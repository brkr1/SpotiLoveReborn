#import <UIKit/UIKit.h>
#include <MediaRemote/MediaRemote.h>

static NSString * const kLikeToggleDarwinNotification = @"com.brkr1.tweaks.spotilovereborn/toggle";

static CFStringRef const kLXPrefsAppID = CFSTR("com.brkr1.tweaks.spotilovereborn");
static CFStringRef const kLXPrefsIsLikedKey = CFSTR("isCurrentTrackLiked");
static CFStringRef const kLXPrefsTrackURIKey = CFSTR("currentTrackURIForLikedState");

static NSString * const kLikedStateChangedDarwinNotification = @"com.brkr1.tweaks.spotilovereborn/likedStateChanged";

@interface SBApplication: NSObject
    @property (nonatomic, readonly) NSString* bundleIdentifier;
@end

@interface SBMediaController: NSObject
    @property (nonatomic, readonly) SBApplication* nowPlayingApplication;
    + (instancetype) sharedInstance;
@end

#ifdef __cplusplus
extern "C" {
#endif

BOOL lx_isPlayingFromSpotify(void);

#ifdef __cplusplus
}
#endif