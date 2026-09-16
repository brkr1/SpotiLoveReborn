// Now covers iOS 16+ (previously 17+ only). The heart button lives here
// rather than in SpringBoard because MRUNowPlayingView's transportControlsView
// is a real, local view only from inside this process - SpringBoard only
// composites a remote scene for the lock screen widget's controls, so a
// SpringBoard-side hook can only guess the transport row's Y with a fixed
// offset. That's what SpringBoardHalf used to do (removed): one offset
// tuned for the widget's compact-pill layout, which drifted out of line
// with the real controls the moment the lock screen's tap-to-expand
// full-screen state laid the same content out differently.
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

// TODO(debug): remove once we've identified the real Control Center card view/window.
// A screenshot showed no heart at all in the (much taller) real Control Center card, while
// our own logs showed a valid-looking 401x160 view passing this check - strong evidence that
// what we've been hooking is some OTHER 401x160 surface (likely the lock screen's own compact
// platter, which also reports context==2) rather than Control Center's real card. This walks
// the full ancestor chain so we can see it directly instead of inferring from a boolean.
static void lx_debugLogAncestorChain(UIViewController *vc) {
    NSMutableString *chain = [NSMutableString string];
    for (UIViewController *ancestor = vc; ancestor; ancestor = ancestor.parentViewController) {
        [chain appendFormat: @"%@ <- ", NSStringFromClass([ancestor class])];
    }
    NSLog(@"[SpotiLoveReborn][MRU-DEBUG] ancestor chain: %@", chain);
}

// TODO(debug): remove once we've identified the real Control Center card view/window.
static void lx_debugLogAllWindows(void) {
    // UIApplication.windows is deprecated (iOS 15+, -Werror fails the build on it) - go through
    // each connected UIWindowScene's own windows instead.
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass: [UIWindowScene class]]) {
            continue;
        }
        UIWindowScene *windowScene = (UIWindowScene *) scene;
        for (UIWindow *window in windowScene.windows) {
            NSLog(@"[SpotiLoveReborn][MRU-DEBUG] window: %@ class=%@ frame=%@ hidden=%d rootVC=%@",
                  window, NSStringFromClass([window class]), NSStringFromCGRect(window.frame), window.hidden,
                  NSStringFromClass([window.rootViewController class]));
        }
    }
}

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

// NextUp3's own Control Center hooks (NUHooksControlCenterLegacy.x) confirm
// MRUControlCenterViewController hosts this same MRUNowPlayingViewController/MRUNowPlayingView
// for its now-playing card - but its .context value there is unconfirmed (an earlier version of
// this function assumed it was still 2, same as the lock screen, and the heart never appeared in
// Control Center - that assumption was never actually verified). Detecting Control Center by
// walking the ancestor chain instead is the same technique this function used to use to
// EXCLUDE Control Center, so it's already proven to correctly identify it either way.
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

    // LyricationReborn's LX button (LockscreenButtonMRU/Tweak.xm) lives in
    // this same MRUNowPlayingView and aligns itself to the real
    // transportControlsView frame the same way this heart button does -
    // anchoring the heart to LX's own frame keeps them on the same row as
    // each other even if either one's alignment logic changes later,
    // instead of both independently re-deriving the transport row's Y.
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

                // Control Center's compact card (~170x170) lays the transport row out flush with
                // the card's edges (transportFrame.origin.x == 0) - unlike the lock screen and
                // Control Center's own expanded card, both of which leave a left margin before it
                // (origin.x == 14 or 24). Centering the heart on the row's Y there puts it right on
                // top of the backward button, since there's no free margin to its left. Move it
                // above the row there instead.
                if (transportFrame.origin.x <= 0.5) {
                    y = CGRectGetMinY(transportFrame) - height - 6;
                }
            }
        }
    } @catch (NSException *e) {
        // Fall back to the bottom-anchored default above.
    }

    lx_mruHeartButton.frame = CGRectMake(leftOffset, y, width, height);
    [playerView bringSubviewToFront: lx_mruHeartButton];
    NSLog(@"[SpotiLoveReborn][MRU-DEBUG] lx_layoutMRUHeartButton: playerView.bounds=%@ transportControlsView=%@ resultFrame=%@ hidden=%d alpha=%f window=%@",
          NSStringFromCGRect(playerView.bounds),
          [playerView respondsToSelector: @selector(transportControlsView)] ? playerView.transportControlsView : nil,
          NSStringFromCGRect(lx_mruHeartButton.frame), lx_mruHeartButton.hidden, lx_mruHeartButton.alpha, playerView.window);
}

// TODO(debug): remove once the heart shows up correctly in Control Center.
void lx_ensureMRUHeartButton(MRUNowPlayingView *playerView) {
    MRUNowPlayingViewController *owningVC = lx_owningNowPlayingVC(playerView);
    BOOL supported = lx_isSupportedNowPlayingContext(owningVC);
    NSLog(@"[SpotiLoveReborn][MRU-DEBUG] lx_ensureMRUHeartButton: playerView=%@ owningVC=%@ context=%lld supported=%d",
          playerView, owningVC, owningVC.context, supported);
    lx_debugLogAncestorChain(owningVC);

    // Throttled - layoutSubviews fires many times per second during animations, and dumping
    // every window on every call would flood the log without adding anything new each time.
    static CFAbsoluteTime lastWindowDumpTime = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - lastWindowDumpTime > 2.0) {
        lastWindowDumpTime = now;
        lx_debugLogAllWindows();
    }

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
    NSLog(@"[SpotiLoveReborn][MRU-DEBUG] MRUNowPlayingView layoutSubviews: self=%@", self);
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
