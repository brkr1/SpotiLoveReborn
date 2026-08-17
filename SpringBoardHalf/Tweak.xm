#import "../Shared.h"

UIButton *heartButton;
BOOL currentTrackIsLiked = NO;

// Marker-file-gated, same pattern already proven on IslandAura/SporeReborn/
// IslandVolume this cycle: touch /var/mobile/Documents/SpotiLoveRebornDebug.enable
// (Filza/SSH) to turn on, delete it to turn off, no respring needed.
BOOL lx_debugLoggingEnabled(void) {
    return [[NSFileManager defaultManager] fileExistsAtPath: @"/var/mobile/Documents/SpotiLoveRebornDebug.enable"];
}

void lx_log(NSString *format, ...) {
    if (!lx_debugLoggingEnabled()) {
        return;
    }

    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat: format arguments: args];
    va_end(args);

    NSString *line = [NSString stringWithFormat: @"[%@] %@\n", [NSDate date], message];
    NSLog(@"[SpotiLoveRebornDebug] %@", message);

    NSString *path = @"/var/mobile/Documents/SpotiLoveRebornDebug.log";
    if (![[NSFileManager defaultManager] fileExistsAtPath: path]) {
        [[NSFileManager defaultManager] createFileAtPath: path contents: nil attributes: nil];
    }
    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath: path];
    [handle seekToEndOfFile];
    [handle writeData: [line dataUsingEncoding: NSUTF8StringEncoding]];
    [handle closeFile];
}

void lx_updateHeartButtonAppearance() {
    if (!heartButton) {
        return;
    }
    [heartButton setTitle: (currentTrackIsLiked ? @"♥" : @"♡") forState: UIControlStateNormal];
    [heartButton setTitleColor: (currentTrackIsLiked ? [UIColor systemRedColor] : [[UIColor labelColor] colorWithAlphaComponent: 0.85])
                       forState: UIControlStateNormal];
}

void lx_refreshLikedState() {
    if (!lx_isPlayingFromSpotify()) {
        return;
    }

    currentTrackIsLiked = lx_getLikedState();
    lx_updateHeartButtonAppearance();
}

@interface CSListItemActivityProvider: NSObject
    - (NSDictionary*) activityItemsByBundleId;
@end

@interface ACUISActivityHostViewController: UIViewController
    - (CSListItemActivityProvider*) delegate;
@end

@interface CSActivityItemViewController: UIViewController
    - (ACUISActivityHostViewController*) activityHostViewController;
@end

@interface CSActivityItemContentView: UIView
@end

bool lx_activityViewIsNowPlayingView(CSActivityItemContentView* questionedView) {
    BOOL isNowPlayingView = false;

    CSActivityItemViewController* itemViewController = (CSActivityItemViewController*) questionedView.nextResponder;
    if (itemViewController && [itemViewController isKindOfClass: %c(CSActivityItemViewController)]) {
        ACUISActivityHostViewController* activityHostViewController = itemViewController.activityHostViewController;
        if (activityHostViewController && [activityHostViewController isKindOfClass: %c(ACUISActivityHostViewController)]) {
            CSListItemActivityProvider* ahvcDelegate = activityHostViewController.delegate;
            if (ahvcDelegate && [ahvcDelegate isKindOfClass: %c(CSListItemActivityProvider)]) {
                NSDictionary* activityItemsByBundleId = ahvcDelegate.activityItemsByBundleId;
                if (activityItemsByBundleId && [activityItemsByBundleId isKindOfClass: [NSDictionary class]]) {
                    NSArray* activityItems = activityItemsByBundleId[@"com.apple.MediaRemoteUI"];
                    if (activityItems && [activityItems isKindOfClass: [NSArray class]] && activityItems.count > 0) {
                        isNowPlayingView = true;
                    }
                }
            }
        }
    }

    return isNowPlayingView;
}

%hook CSActivityItemContentView

%new
- (void) lx_heartButtonTapped {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];

    [UIView animateWithDuration: 0.15 animations: ^{
        heartButton.alpha = 0.4;
    } completion: ^(BOOL finished) {
        [UIView animateWithDuration: 0.15 animations: ^{
            heartButton.alpha = 1.0;
        }];
    }];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef) kLikeToggleDarwinNotification,
        NULL, NULL, true
    );

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        lx_refreshLikedState();
    });
}

UIButton *lx_findLyricationButton(UIView *container) {
    NSArray<UIView *> *subviewsSnapshot = [container.subviews copy];
    for (UIView *subview in subviewsSnapshot) {
        if ([subview isKindOfClass: [UIButton class]]) {
            UIButton *button = (UIButton *) subview;
            if ([[button currentTitle] isEqualToString: @"LX"]) {
                return button;
            }
        }
    }
    return nil;
}

// A recursive subtree dump (same technique that found
// SBSystemApertureContainerView for IslandAura's live-tracking fix) proved
// the real transport buttons can't be found by view introspection at all:
// MediaRemoteUI renders every player's controls into a remote scene
// (_UIScenePresentationView -> _UISceneLayerHostContainerView) that
// SpringBoard only composites, not local views - the walk reached the leaf
// (_UITouchPassthroughView) with zero real buttons anywhere underneath.
//
// A fixed distance from the container's TOP is the only thing that survives
// content appended below it (NextUp 3's Up Next row, or anything else
// appended there in the future) - anchoring from the bottom broke the moment
// anything grew the container from below, no matter what threshold/offset
// pair was chosen. This constant was cross-checked two ways: measuring a
// real screenshot comparison (with/without NextUp 3, transport row sits at
// the same absolute screen position in both) and reproducing the old,
// previously-correct height-based formula's own output for the pre-NextUp3
// settled height (198pt: 198 - 47 - 41 = 110). Not pixel-perfect science -
// may need a small manual nudge after a real device test.
static const CGFloat kLXHeartTopOffset = 110.0;

void lx_layoutHeartButton(UIView *container) {
    if (!heartButton) {
        return;
    }

    CGFloat leftOffset = 18;
    UIButton *lyricationButton = lx_findLyricationButton(container);
    if (lyricationButton != nil && !CGRectIsEmpty(lyricationButton.frame)) {
        leftOffset = CGRectGetMaxX(lyricationButton.frame) + 8;
    }

    CGSize fitSize = [heartButton sizeThatFits: CGSizeMake(100, 100)];
    CGFloat width = fitSize.width > 0 ? fitSize.width : 32;
    CGFloat height = fitSize.height > 0 ? fitSize.height : 32;

    CGFloat y = kLXHeartTopOffset;

    if (lx_debugLoggingEnabled()) {
        NSMutableString *dump = [NSMutableString stringWithFormat: @"layoutHeartButton: container=%@ bounds=%@\n", NSStringFromClass([container class]), NSStringFromCGRect(container.bounds)];
        [dump appendFormat: @"lyricationButton=%@ frame=%@\n", lyricationButton, NSStringFromCGRect(lyricationButton.frame)];
        [dump appendFormat: @"chosen leftOffset=%.1f y=%.1f width=%.1f height=%.1f\n", leftOffset, y, width, height];
        lx_log(@"%@", dump);
    }

    heartButton.frame = CGRectMake(leftOffset, y, width, height);
}

- (void) layoutSubviews {
    %orig;

    BOOL isNowPlayingView = lx_activityViewIsNowPlayingView(self);

    if ((!isNowPlayingView || !lx_isPlayingFromSpotify()) && heartButton && [self.subviews containsObject: heartButton]) {
        [heartButton removeFromSuperview];
        heartButton = nil;
        return;
    }

    lx_layoutHeartButton(self);
}

- (void) didMoveToWindow {
    %orig;

    // iOS 17+ is handled by MediaRemoteUIHalf instead, which hooks the
    // actual content process directly rather than this SpringBoard-side
    // composited frame - see that file for why.
    if (@available(iOS 17, *)) {
        if (heartButton && [self.subviews containsObject: heartButton]) {
            [heartButton removeFromSuperview];
            heartButton = nil;
        }
        return;
    }

    if (@available(iOS 16, *)) {
        BOOL isNowPlayingView = lx_activityViewIsNowPlayingView(self);

        if (!isNowPlayingView || !lx_isPlayingFromSpotify()) {
            if (heartButton && [self.subviews containsObject: heartButton]) {
                [heartButton removeFromSuperview];
                heartButton = nil;
            }
            return;
        }

        if (heartButton) {
            if ([self.subviews containsObject: heartButton]) {
                return;
            }

            @try {
                if (heartButton.superview) {
                    [heartButton removeFromSuperview];
                }
            } @catch (id ignored) { }

            heartButton = nil;
        }

        heartButton = [[UIButton alloc] init];
        heartButton.translatesAutoresizingMaskIntoConstraints = true;

        currentTrackIsLiked = NO;
        lx_updateHeartButtonAppearance();
        [heartButton.titleLabel setFont: [UIFont systemFontOfSize: 24.0]];

        [self addSubview: heartButton];
        lx_layoutHeartButton(self);

        __weak CSActivityItemContentView *weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf) lx_layoutHeartButton(weakSelf);
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (weakSelf) lx_layoutHeartButton(weakSelf);
        });

        [heartButton
            addTarget: self
            action: @selector(lx_heartButtonTapped)
            forControlEvents: UIControlEventTouchUpInside
        ];

        lx_refreshLikedState();
    }
}

- (void) dealloc {
    if (heartButton && self && self.subviews && [self.subviews containsObject: heartButton]) {
        [heartButton removeFromSuperview];
        heartButton = nil;
    }

    %orig;
}

%end

void lx_handleLikedStateChangedFromSpotify() {
    dispatch_async(dispatch_get_main_queue(), ^{
        lx_refreshLikedState();
    });
}

%ctor {
    [[NSNotificationCenter defaultCenter]
        addObserverForName: (__bridge NSString*) kMRMediaRemoteNowPlayingInfoDidChangeNotification
        object: nil
        queue: [NSOperationQueue mainQueue]
        usingBlock: ^(NSNotification *note) {
            lx_refreshLikedState();
        }];

    int token;
    notify_register_dispatch(kLikedStateNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
        lx_handleLikedStateChangedFromSpotify();
    });
}
