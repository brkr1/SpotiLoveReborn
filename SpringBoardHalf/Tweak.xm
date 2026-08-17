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

// The leftmost native transport button in the row (rewind, on every Now
// Playing layout seen so far) - used both to keep the heart from overlapping
// the native controls horizontally, and as the vertical anchor below, since
// its own frame reflects Spotify's actual current layout instead of a
// height-based guess about it.
UIButton *lx_leftmostNativeControlButton(UIView *container) {
    UIButton *leftmost = nil;
    CGFloat minX = CGFLOAT_MAX;
    NSArray<UIView *> *subviewsSnapshot = [container.subviews copy];
    for (UIView *subview in subviewsSnapshot) {
        if (subview == heartButton) continue;
        if (![subview isKindOfClass: [UIButton class]]) continue;
        UIButton *button = (UIButton *) subview;
        NSString *title = [button currentTitle];
        if ([title isEqualToString: @"LX"] || [title isEqualToString: @"♥"] || [title isEqualToString: @"♡"]) continue;
        if (CGRectIsEmpty(button.frame)) continue;
        if (CGRectGetMinX(button.frame) < minX) {
            minX = CGRectGetMinX(button.frame);
            leftmost = button;
        }
    }
    return leftmost;
}

CGFloat lx_nativeControlsMinX(UIView *container) {
    UIButton *leftmost = lx_leftmostNativeControlButton(container);
    return leftmost ? CGRectGetMinX(leftmost.frame) : CGFLOAT_MAX;
}

// iOS 16: dynamic clamp against native controls (confirmed working well).
// iOS 17: that same clamp made the heart disappear entirely (no crash - an
// Auto Layout-era theory that didn't hold up even after switching to plain
// frame math, so the real cause is still unclear). Until that's understood
// properly, iOS 17 skips the clamp and just uses the simple LX-relative /
// default offset - the exact behavior that was confirmed to at least show
// the heart there (just imperfectly positioned), which beats it not
// appearing at all.
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

    UIButton *rewindButton = lx_leftmostNativeControlButton(container);

    if (rewindButton != nil) {
        CGFloat maxAllowedOffset = CGRectGetMinX(rewindButton.frame) - width - 8;
        if (leftOffset > maxAllowedOffset) {
            leftOffset = MAX(4, maxAllowedOffset);
        }
    }

    // Anchor to the rewind button's own frame rather than a height-based
    // guess about where it should be - Spotify 9.1.72 added an "Up Next"
    // row that grew the container's height, which broke the old guess (it
    // assumed a fixed offset from the bottom, tuned for 9.1.0's shorter
    // layout) without moving the actual button. Falls back to the old
    // guess only if no native button can be found yet.
    CGFloat y;
    if (rewindButton != nil && !CGRectIsEmpty(rewindButton.frame)) {
        y = CGRectGetMidY(rewindButton.frame) - (height / 2.0);
    } else {
        CGFloat bottomInset = (container.bounds.size.height >= 170) ? 47 : 15;
        y = container.bounds.size.height - bottomInset - height;
    }

    if (lx_debugLoggingEnabled()) {
        NSMutableString *dump = [NSMutableString stringWithFormat: @"layoutHeartButton: container=%@ bounds=%@\n", NSStringFromClass([container class]), NSStringFromCGRect(container.bounds)];
        for (UIView *subview in [container.subviews copy]) {
            [dump appendFormat: @"  subview class=%@ frame=%@", NSStringFromClass([subview class]), NSStringFromCGRect(subview.frame)];
            if ([subview isKindOfClass: [UIButton class]]) {
                [dump appendFormat: @" title=%@", [(UIButton *) subview currentTitle]];
            }
            [dump appendString: @"\n"];
        }
        [dump appendFormat: @"lyricationButton=%@ frame=%@\n", lyricationButton, NSStringFromCGRect(lyricationButton.frame)];
        [dump appendFormat: @"rewindButton=%@ frame=%@\n", rewindButton, NSStringFromCGRect(rewindButton.frame)];
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
