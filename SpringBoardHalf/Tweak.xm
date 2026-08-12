#import "../Shared.h"

UIButton *heartButton;
NSLayoutConstraint *heartButtonBottomConstraint;
BOOL currentTrackIsLiked = NO;

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

    CFPropertyListRef value = CFPreferencesCopyValue(kLXPrefsIsLikedKey, kLXPrefsAppID, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (value != NULL) {
        currentTrackIsLiked = CFBooleanGetValue((CFBooleanRef) value);
        CFRelease(value);
    } else {
        currentTrackIsLiked = NO;
    }
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

NSLayoutConstraint *heartButtonLeftConstraint;

UIButton *lx_findLyricationButton(UIView *container) {
    for (UIView *subview in container.subviews) {
        if ([subview isKindOfClass: [UIButton class]]) {
            UIButton *button = (UIButton *) subview;
            if ([[button currentTitle] isEqualToString: @"LX"]) {
                return button;
            }
        }
    }
    return nil;
}

void lx_updateHeartButtonPosition() {
    if (!heartButton || !heartButton.superview) {
        return;
    }

    UIButton *lyricationButton = lx_findLyricationButton(heartButton.superview);

    if (heartButtonLeftConstraint != nil) {
        heartButtonLeftConstraint.active = false;
        heartButtonLeftConstraint = nil;
    }

    if (lyricationButton != nil) {
        // Lyrication is present - sit just to its right instead of overlapping.
        heartButtonLeftConstraint = [heartButton.leftAnchor constraintEqualToAnchor: lyricationButton.trailingAnchor constant: 16];
    } else {
        // Lyrication isn't installed (or not showing here) - take its usual spot.
        heartButtonLeftConstraint = [heartButton.leftAnchor constraintEqualToAnchor: heartButton.superview.leftAnchor constant: 24];
    }

    heartButtonLeftConstraint.active = true;
}

- (void) layoutSubviews {
    %orig;

    BOOL isNowPlayingView = lx_activityViewIsNowPlayingView(self);

    if ((!isNowPlayingView || !lx_isPlayingFromSpotify()) && heartButton && [self.subviews containsObject: heartButton]) {
        [heartButton removeFromSuperview];
        heartButton = nil;
        return;
    }

    // Lyrication's own button may appear/disappear or move independently of
    // us, so re-check our position on every layout pass, not just once.
    lx_updateHeartButtonPosition();
}

- (void) didMoveToWindow {
    %orig;

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
        heartButton.translatesAutoresizingMaskIntoConstraints = false;

        currentTrackIsLiked = NO;
        lx_updateHeartButtonAppearance();
        [heartButton.titleLabel setFont: [UIFont systemFontOfSize: 24.0]];

        [self addSubview: heartButton];

        if (self.bounds.size.height >= 170) {
            heartButtonBottomConstraint = [heartButton.bottomAnchor constraintEqualToAnchor: self.bottomAnchor constant: -47];
        } else {
            heartButtonBottomConstraint = [heartButton.bottomAnchor constraintEqualToAnchor: self.bottomAnchor constant: -15];
        }
        heartButtonBottomConstraint.active = true;
        lx_updateHeartButtonPosition();

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

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback) lx_handleLikedStateChangedFromSpotify,
        (__bridge CFStringRef) kLikedStateChangedDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
