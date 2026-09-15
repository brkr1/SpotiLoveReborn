#import "../Shared.h"
#import <objc/runtime.h>

static BOOL lx_ytmNameLooksPromising(const char *name) {
    NSString *lowered = [[NSString stringWithUTF8String: name] lowercaseString];
    NSArray<NSString *> *needles = @[@"like", @"dislike", @"rating", @"thumbsup", @"thumbdown", @"thumb", @"togglebutton", @"favorite", @"favourite"];
    for (NSString *needle in needles) {
        if ([lowered containsString: needle]) {
            return YES;
        }
    }
    return NO;
}

// TODO(debug): remove once the real like/dislike hook for YouTube Music is confirmed working.
// No private-header dump exists for YTM's like API (unlike Spotify's), so this scans every
// loaded class for a plausible name and dumps its instance methods - the same discovery
// approach that found the broken Spotify init signature.
static void lx_ytmDebugScanForLikeClasses(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG] scanning %u loaded classes for like/rating candidates", classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (!name || !lx_ytmNameLooksPromising(name)) {
            continue;
        }
        NSLog(@"[SpotiLoveReborn][YTM-DEBUG] candidate class: %s", name);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG]     - %@", NSStringFromSelector(method_getName(methods[j])));
        }
        free(methods);
    }
    free(classes);
}

void lx_handleLikeToggleNotificationYouTubeMusic() {
    // Not yet implemented: the real like/dislike API for YouTube Music isn't known yet.
    // Once the class scan above identifies it, this becomes a real toggle call, mirroring
    // SpotifyHalf/Tweak.xm's lx_handleLikeToggleNotification.
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle notification received, but no hook wired up yet");
}

%ctor {
    lx_ytmDebugScanForLikeClasses();

    // Some of YTM's classes may only get registered once its player UI is actually built,
    // so rescan a few times after launch instead of relying on the ctor-time snapshot alone.
    NSArray<NSNumber *> *delays = @[@5.0, @15.0, @30.0];
    for (NSNumber *delay in delays) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([delay doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            lx_ytmDebugScanForLikeClasses();
        });
    }

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback) lx_handleLikeToggleNotificationYouTubeMusic,
        (__bridge CFStringRef) kLikeToggleDarwinNotificationYouTubeMusic,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
