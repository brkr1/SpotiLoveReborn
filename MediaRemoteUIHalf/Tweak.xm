#import "../Shared.h"
#import <objc/runtime.h>

@interface MRUNowPlayingView : UIView
@property (nonatomic, readonly) UIView *transportControlsView;
@property (nonatomic, readonly) UIView *volumeControlsView;
@end

@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic, retain) MRUNowPlayingView *view;
@property (nonatomic) long long context; // 2 == lock screen
- (void) lx_ensureHeartButton;
- (void) lx_heartButtonTapped;
@end

static const long long kLXLockScreenContext = 2;

static BOOL lx_isLockScreenContext(MRUNowPlayingViewController *vc) {
    if (!vc) {
        return NO;
    }
    if (vc.context == kLXLockScreenContext) {
        Class controlCenterClass = objc_getClass("MRUControlCenterViewController");
        if (controlCenterClass) {
            for (UIViewController *ancestor = vc; ancestor; ancestor = ancestor.parentViewController) {
                if ([ancestor isKindOfClass: controlCenterClass]) {
                    return NO;
                }
            }
        }
        return YES;
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

void lx_layoutMRUHeartButton(MRUNowPlayingView *playerView) {
    if (!lx_mruHeartButton) {
        return;
    }

    CGSize fitSize = [lx_mruHeartButton sizeThatFits: CGSizeMake(100, 100)];
    CGFloat width = fitSize.width > 0 ? fitSize.width : 32;
    CGFloat height = fitSize.height > 0 ? fitSize.height : 32;

    CGFloat leftOffset = 18;
    CGFloat y = playerView.bounds.size.height - height - 15;

    @try {
        UIView *transportControls = [playerView respondsToSelector: @selector(transportControlsView)] ? playerView.transportControlsView : nil;
        if (transportControls != nil && !CGRectIsEmpty(transportControls.frame)) {
            y = CGRectGetMidY(transportControls.frame) - (height / 2.0);
        }
    } @catch (NSException *e) {
        // Fall back to the bottom-anchored default above.
    }

    lx_mruHeartButton.frame = CGRectMake(leftOffset, y, width, height);
}

%hook MRUNowPlayingViewController

- (void) viewDidLoad {
    %orig;
    if (@available(iOS 17, *)) {
        [self lx_ensureHeartButton];
    }
}

- (void) viewWillAppear: (BOOL) animated {
    %orig;
    if (@available(iOS 17, *)) {
        [self lx_ensureHeartButton];
    }
}

%new
- (void) lx_ensureHeartButton {
    if (!lx_isLockScreenContext(self) || ![self isViewLoaded]) {
        if (lx_mruHeartButton && lx_mruHeartButton.superview == self.view) {
            [lx_mruHeartButton removeFromSuperview];
            lx_mruHeartButton = nil;
        }
        return;
    }

    if (lx_mruHeartButton && lx_mruHeartButton.superview == self.view) {
        lx_layoutMRUHeartButton(self.view);
        return;
    }

    @try {
        if (lx_mruHeartButton && lx_mruHeartButton.superview) {
            [lx_mruHeartButton removeFromSuperview];
        }
    } @catch (id ignored) { }

    lx_mruHeartButton = [[UIButton alloc] init];
    lx_mruHeartButton.translatesAutoresizingMaskIntoConstraints = YES;
    [lx_mruHeartButton.titleLabel setFont: [UIFont systemFontOfSize: 24.0]];
    lx_updateMRUHeartButtonAppearance();

    [lx_mruHeartButton addTarget: self action: @selector(lx_heartButtonTapped) forControlEvents: UIControlEventTouchUpInside];

    [self.view addSubview: lx_mruHeartButton];
    lx_layoutMRUHeartButton(self.view);

    __weak MRUNowPlayingViewController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (weakSelf.isViewLoaded) lx_layoutMRUHeartButton(weakSelf.view);
    });
}

%new
- (void) lx_heartButtonTapped {
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

%end

%hook MRUNowPlayingView

- (void) layoutSubviews {
    %orig;
    if (@available(iOS 17, *)) {
        if (lx_mruHeartButton && lx_mruHeartButton.superview == self) {
            lx_layoutMRUHeartButton((MRUNowPlayingView *) self);
        }
    }
}

%end

void lx_handleLikedStateChangedInMRU(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        lx_updateMRUHeartButtonAppearance();
    });
}

%ctor {
    if (@available(iOS 17, *)) {
        int token;
        notify_register_dispatch(kLikedStateNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
            lx_handleLikedStateChangedInMRU();
        });
    }
}
