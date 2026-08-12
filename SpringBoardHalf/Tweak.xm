#import "../Shared.h"

// draws the heart button on the lock screen

UIButton *heartButton;
NSLayoutConstraint *heartButtonBottomConstraint;
BOOL currentTrackIsLiked = NO;

void lx_updateHeartButtonAppearance() {
    if (!heartButton) {
        return;
    }
    [heartButton setTitle: (currentTrackIsLiked ? @"♥" : @"♡") forState: UIControlStateNormal];
}

void lx_refreshLikedState() {
    if (!lx_isPlayingFromSpotify()) {
        return;
    }

    MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
        NSDictionary *info = (__bridge NSDictionary*) information;
        NSNumber *isLiked = info[(__bridge NSString*) kMRMediaRemoteNowPlayingInfoIsLiked];
        currentTrackIsLiked = [isLiked boolValue];
        lx_updateHeartButtonAppearance();
    });
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

- (void) layoutSubviews {
    %orig;

    BOOL isNowPlayingView = lx_activityViewIsNowPlayingView(self);

    if ((!isNowPlayingView || !lx_isPlayingFromSpotify()) && heartButton && [self.subviews containsObject: heartButton]) {
        [heartButton removeFromSuperview];
        heartButton = nil;
    }
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
        [heartButton setTitleColor: [[UIColor labelColor] colorWithAlphaComponent: 0.85] forState: UIControlStateNormal];

        [self addSubview: heartButton];

        if (self.bounds.size.height >= 170) {
            heartButtonBottomConstraint = [heartButton.bottomAnchor constraintEqualToAnchor: self.bottomAnchor constant: -47];
        } else {
            heartButtonBottomConstraint = [heartButton.bottomAnchor constraintEqualToAnchor: self.bottomAnchor constant: -15];
        }
        heartButtonBottomConstraint.active = true;
        [heartButton.leftAnchor constraintEqualToAnchor: self.leftAnchor constant: 70].active = true;

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

%ctor {
    [[NSNotificationCenter defaultCenter]
        addObserverForName: (__bridge NSString*) kMRMediaRemoteNowPlayingInfoDidChangeNotification
        object: nil
        queue: [NSOperationQueue mainQueue]
        usingBlock: ^(NSNotification *note) {
            lx_refreshLikedState();
        }];
}
