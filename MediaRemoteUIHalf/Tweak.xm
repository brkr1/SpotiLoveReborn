// Covers iOS 16+. Injected into both MediaRemoteUI (lock screen) and
// springboard (Control Center), whose Bundles filter picks up both.
#import "../Shared.h"
#import <objc/runtime.h>

@interface MRUNowPlayingView : UIView
@property (nonatomic, readonly) UIView *transportControlsView;
@property (nonatomic, readonly) UIView *volumeControlsView;
- (void) lx_heartButtonTappedFromView;
@end

@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic, retain) MRUNowPlayingView *view;
@property (nonatomic) long long context; // 2 == lock screen
@end

static const long long kLXLockScreenContext = 2;

static MRUNowPlayingViewController *lx_owningNowPlayingVC(UIView *view) {
    Class vcClass = objc_getClass("MRUNowPlayingViewController");
    if (!vcClass) {
        return nil;
    }
    UIResponder *responder = view.nextResponder;
    while (responder && ![responder isKindOfClass: vcClass]) {
        responder = responder.nextResponder;
    }
    return (MRUNowPlayingViewController *) responder;
}

// Control Center's card doesn't report context==2 like the lock screen does,
// so fall back to an ancestor-chain walk to detect it (confirmed via NextUp3).
static BOOL lx_isSupportedNowPlayingContext(MRUNowPlayingViewController *vc) {
    if (!vc) {
        return NO;
    }
    if (vc.context == kLXLockScreenContext) {
        return YES;
    }
    Class controlCenterClass = objc_getClass("MRUControlCenterViewController");
    if (controlCenterClass) {
        for (UIViewController *ancestor = vc; ancestor; ancestor = ancestor.parentViewController) {
            if ([ancestor isKindOfClass: controlCenterClass]) {
                return YES;
            }
        }
    }
    return NO;
}

UIButton *lx_mruHeartButton;

void lx_updateMRUHeartButtonAppearance(void) {
    if (!lx_mruHeartButton) {
        return;
    }
    BOOL isLiked = lx_getLikedState();
    [lx_mruHeartButton setTitle: (isLiked ? @"♥" : @"♡") forState: UIControlStateNormal];
    [lx_mruHeartButton setTitleColor: (isLiked ? [UIColor systemRedColor] : [[UIColor labelColor] colorWithAlphaComponent: 0.85])
                             forState: UIControlStateNormal];
}

void lx_heartButtonTapped(void) {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];

    [UIView animateWithDuration: 0.15 animations: ^{
        lx_mruHeartButton.alpha = 0.4;
    } completion: ^(BOOL finished) {
        [UIView animateWithDuration: 0.15 animations: ^{
            lx_mruHeartButton.alpha = 1.0;
        }];
    }];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef) kLikeToggleDarwinNotification,
        NULL, NULL, true
    );
}

UIButton *lx_findMRULyricationButton(UIView *playerView) {
    NSArray<UIView *> *subviewsSnapshot = [playerView.subviews copy];
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

void lx_layoutMRUHeartButton(MRUNowPlayingView *playerView) {
    if (!lx_mruHeartButton) {
        return;
    }

    CGSize fitSize = [lx_mruHeartButton sizeThatFits: CGSizeMake(100, 100)];
    CGFloat width = fitSize.width > 0 ? fitSize.width : 32;
    CGFloat height = fitSize.height > 0 ? fitSize.height : 32;

    // Anchors to LyricationReborn's LX button frame when present, so both
    // stay on the same row even if either one's alignment logic changes.
    CGFloat leftOffset = 18;
    UIButton *lyricationButton = lx_findMRULyricationButton(playerView);
    if (lyricationButton != nil && !CGRectIsEmpty(lyricationButton.frame)) {
        leftOffset = CGRectGetMaxX(lyricationButton.frame) + 8;
    }

    CGFloat y = playerView.bounds.size.height - height - 15;

    @try {
        if ([playerView respondsToSelector: @selector(transportControlsView)]) {
            UIView *transportControls = playerView.transportControlsView;
            if (transportControls != nil && !CGRectIsEmpty(transportControls.frame)) {
                CGRect transportFrame = transportControls.frame;
                y = CGRectGetMidY(transportFrame) - (height / 2.0);

                // Control Center's compact card has no left margin before the transport row
                // (origin.x == 0), so centering there sits on top of the backward button instead.
                if (transportFrame.origin.x <= 0.5) {
                    y = CGRectGetMinY(transportFrame) - (height * 0.7) - 4;
                }
            }
        }
    } @catch (NSException *e) {
        // Fall back to the bottom-anchored default above.
    }

    lx_mruHeartButton.frame = CGRectMake(leftOffset, y, width, height);
    [playerView bringSubviewToFront: lx_mruHeartButton];
}

void lx_ensureMRUHeartButton(MRUNowPlayingView *playerView) {
    MRUNowPlayingViewController *owningVC = lx_owningNowPlayingVC(playerView);
    BOOL supported = lx_isSupportedNowPlayingContext(owningVC);

    if (!supported) {
        if (lx_mruHeartButton && lx_mruHeartButton.superview == playerView) {
            [lx_mruHeartButton removeFromSuperview];
            lx_mruHeartButton = nil;
        }
        return;
    }

    if (lx_mruHeartButton && lx_mruHeartButton.superview == playerView) {
        lx_layoutMRUHeartButton(playerView);
        return;
    }

    @try {
        if (lx_mruHeartButton && lx_mruHeartButton.superview) {
            [lx_mruHeartButton removeFromSuperview];
        }
    } @catch (id ignored) { }

    lx_mruHeartButton = [[UIButton alloc] init];
    lx_mruHeartButton.translatesAutoresizingMaskIntoConstraints = YES;
    [lx_mruHeartButton.titleLabel setFont: [UIFont systemFontOfSize: 30.0]];
    lx_updateMRUHeartButtonAppearance();

    [lx_mruHeartButton addTarget: playerView action: @selector(lx_heartButtonTappedFromView) forControlEvents: UIControlEventTouchUpInside];

    [playerView addSubview: lx_mruHeartButton];
    lx_layoutMRUHeartButton(playerView);
}

%hook MRUNowPlayingView

- (void) layoutSubviews {
    %orig;
    if (@available(iOS 16, *)) {
        lx_ensureMRUHeartButton((MRUNowPlayingView *) self);
    }
}

%new
- (void) lx_heartButtonTappedFromView {
    lx_heartButtonTapped();
}

%end

void lx_handleLikedStateChangedInMRU(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        lx_updateMRUHeartButtonAppearance();
    });
}

%ctor {
    if (@available(iOS 16, *)) {
        int token;
        notify_register_dispatch(kLikedStateNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            lx_handleLikedStateChangedInMRU();
        });
    }
}
