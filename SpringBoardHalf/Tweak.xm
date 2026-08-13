#import "../Shared.h"

UIButton *heartButton;
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

CGFloat lx_nativeControlsMinX(UIView *container) {
    CGFloat minX = CGFLOAT_MAX;
    NSArray<UIView *> *subviewsSnapshot = [container.subviews copy];
    for (UIView *subview in subviewsSnapshot) {
        if (subview == heartButton) continue;
        if (![subview isKindOfClass: [UIButton class]]) continue;
        UIButton *button = (UIButton *) subview;
        NSString *title = [button currentTitle];
        if ([title isEqualToString: @"LX"] || [title isEqualToString: @"♥"] || [title isEqualToString: @"♡"]) continue;
        if (CGRectIsEmpty(button.frame)) continue;
        minX = MIN(minX, CGRectGetMinX(button.frame));
    }
    return minX;
}

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

    CGFloat nativeMinX = lx_nativeControlsMinX(container);
    if (nativeMinX < CGFLOAT_MAX) {
        CGFloat maxAllowedOffset = nativeMinX - width - 8;
        if (leftOffset > maxAllowedOffset) {
            leftOffset = MAX(4, maxAllowedOffset);
        }
    }

    CGFloat bottomInset = (container.bounds.size.height >= 170) ? 47 : 15;
    CGFloat y = container.bounds.size.height - bottomInset - height;

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
