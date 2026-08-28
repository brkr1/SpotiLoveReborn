// Dynamic Island expanded now-playing player. Two class generations, same
// mechanism Crescendo/NextUp3 use here: iOS 16 MRUSessionNowPlaying*,
// iOS 17-26 MRUActivityNowPlaying*, both installed on demand via
// _dyld_register_func_for_add_image since MediaControls.framework loads
// lazily in this process.
//
// Unlike Crescendo's volume slider or NextUp3's Up Next row, the heart
// doesn't need a reserved strip of its own - it's a small icon that sits in
// the existing transport-controls row, the same way it already does on the
// lock screen (Tweak.xm). So there's no preferredHeightForBottomSafeArea
// growth or -bounds clamp here: just find the real
// MRUNowPlayingTransportControlsView (a real, local view in this process,
// exactly like the lock screen) among the player's subviews and anchor to
// its frame.
#import "../Shared.h"
#import <objc/runtime.h>
#import <mach-o/dyld.h>

// Private API, verified by Crescendo/NextUp3 (see their CRPrivate.h /
// NUPrivate.h) - declared narrowly here to just the members this file reads.
@interface MRUActivityNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long activeLayoutMode;
@end

@interface MRUSessionNowPlayingViewController : UIViewController
@property (nonatomic, readonly) long long activeLayoutMode;
- (BOOL) isExpanded;
@end

static const long long kLXDIExpandedMode = 4; // activeLayoutMode when fully expanded
static const CGFloat kLXDIExpandedMinHeight = 120.0; // view is reused for the compact pill

UIButton *lx_mruDIHeartButton;

// Which of the two class generations applies, decided by which %init ran -
// same trick as Crescendo's gCRDIExpanded.
static BOOL (*gLXDIExpanded)(UIViewController *) = NULL;

static BOOL lx_diActivityExpanded(UIViewController *vc) {
    return ((MRUActivityNowPlayingViewController *) vc).activeLayoutMode >= kLXDIExpandedMode;
}

static BOOL lx_diSessionExpanded(UIViewController *vc) {
    MRUSessionNowPlayingViewController *sessionVC = (MRUSessionNowPlayingViewController *) vc;
    @try {
        if ([sessionVC respondsToSelector: @selector(isExpanded)]) {
            return [sessionVC isExpanded];
        }
    } @catch (__unused NSException *e) { }
    return sessionVC.activeLayoutMode >= kLXDIExpandedMode;
}

static UIView *lx_diFindTransportControls(UIView *host) {
    static Class transportClass;
    if (!transportClass) {
        transportClass = objc_getClass("MRUNowPlayingTransportControlsView");
    }
    if (!transportClass) {
        return nil;
    }
    for (UIView *sub in host.subviews) {
        if ([sub isKindOfClass: transportClass] && !sub.isHidden) {
            return sub;
        }
    }
    return nil;
}

void lx_updateMRUDIHeartButtonAppearance(void) {
    if (!lx_mruDIHeartButton) {
        return;
    }
    BOOL isLiked = lx_getLikedState();
    [lx_mruDIHeartButton setTitle: (isLiked ? @"♥" : @"♡") forState: UIControlStateNormal];
    [lx_mruDIHeartButton setTitleColor: (isLiked ? [UIColor systemRedColor] : [[UIColor labelColor] colorWithAlphaComponent: 0.85])
                               forState: UIControlStateNormal];
}

void lx_mruDIHeartButtonTapped(void) {
    UISelectionFeedbackGenerator *feedback = [[UISelectionFeedbackGenerator alloc] init];
    [feedback selectionChanged];

    [UIView animateWithDuration: 0.15 animations: ^{
        lx_mruDIHeartButton.alpha = 0.4;
    } completion: ^(BOOL finished) {
        [UIView animateWithDuration: 0.15 animations: ^{
            lx_mruDIHeartButton.alpha = 1.0;
        }];
    }];

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef) kLikeToggleDarwinNotification,
        NULL, NULL, true
    );
}

void lx_layoutMRUDIHeartButton(UIView *host) {
    if (!lx_mruDIHeartButton) {
        return;
    }

    CGSize fitSize = [lx_mruDIHeartButton sizeThatFits: CGSizeMake(100, 100)];
    CGFloat width = fitSize.width > 0 ? fitSize.width : 32;
    CGFloat height = fitSize.height > 0 ? fitSize.height : 32;

    CGFloat leftOffset = 18;
    CGFloat y = host.bounds.size.height - height - 15;

    UIView *transportControls = lx_diFindTransportControls(host);
    if (transportControls != nil && !CGRectIsEmpty(transportControls.frame)) {
        y = CGRectGetMidY(transportControls.frame) - (height / 2.0);
    }

    lx_mruDIHeartButton.frame = CGRectMake(leftOffset, y, width, height);
    [host bringSubviewToFront: lx_mruDIHeartButton];
}

static BOOL lx_diShouldShow(UIView *host, UIViewController *vc) {
    return vc != nil
        && host.bounds.size.height >= kLXDIExpandedMinHeight
        && gLXDIExpanded != NULL
        && gLXDIExpanded(vc);
}

void lx_ensureMRUDIHeartButton(UIView *host, UIViewController *vc) {
    if (!lx_diShouldShow(host, vc)) {
        if (lx_mruDIHeartButton && lx_mruDIHeartButton.superview == host) {
            [lx_mruDIHeartButton removeFromSuperview];
            lx_mruDIHeartButton = nil;
        }
        return;
    }

    if (lx_mruDIHeartButton && lx_mruDIHeartButton.superview == host) {
        lx_layoutMRUDIHeartButton(host);
        return;
    }

    @try {
        if (lx_mruDIHeartButton && lx_mruDIHeartButton.superview) {
            [lx_mruDIHeartButton removeFromSuperview];
        }
    } @catch (id ignored) { }

    lx_mruDIHeartButton = [[UIButton alloc] init];
    lx_mruDIHeartButton.translatesAutoresizingMaskIntoConstraints = YES;
    [lx_mruDIHeartButton.titleLabel setFont: [UIFont systemFontOfSize: 24.0]];
    lx_updateMRUDIHeartButtonAppearance();

    [lx_mruDIHeartButton addTarget: host action: @selector(lx_diHeartButtonTappedFromView) forControlEvents: UIControlEventTouchUpInside];

    [host addSubview: lx_mruDIHeartButton];
    lx_layoutMRUDIHeartButton(host);
}

#pragma mark - iOS 17-26: MRUActivityNowPlaying*

@interface MRUActivityNowPlayingView : UIView
@end

%group LXDI

%hook MRUActivityNowPlayingView

- (void) layoutSubviews {
    %orig;
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass: objc_getClass("MRUActivityNowPlayingViewController")]) {
        r = r.nextResponder;
    }
    lx_ensureMRUDIHeartButton(self, (UIViewController *) r);
}

%new
- (void) lx_diHeartButtonTappedFromView {
    lx_mruDIHeartButtonTapped();
}

%end

%end // LXDI

#pragma mark - iOS 16: MRUSessionNowPlaying* (pre-Activity family)

@interface MRUSessionNowPlayingView : UIView
@end

%group LXDI16

%hook MRUSessionNowPlayingView

- (void) layoutSubviews {
    %orig;
    UIResponder *r = self.nextResponder;
    while (r && ![r isKindOfClass: objc_getClass("MRUSessionNowPlayingViewController")]) {
        r = r.nextResponder;
    }
    lx_ensureMRUDIHeartButton(self, (UIViewController *) r);
}

%new
- (void) lx_diHeartButtonTappedFromView {
    lx_mruDIHeartButtonTapped();
}

%end

%end // LXDI16

// MediaControls.framework is loaded on demand in this process, so at
// constructor time these classes may not exist yet and %init would silently
// hook nothing. Install once the image shows up instead;
// _dyld_register_func_for_add_image replays already-loaded images, so a
// process that already has it linked still initialises at the same moment
// it used to.
static void LXDIInitIfLoaded(void) {
    static BOOL done = NO;
    if (done) {
        return;
    }
    if (objc_getClass("MRUActivityNowPlayingViewController")) {
        done = YES;
        gLXDIExpanded = lx_diActivityExpanded;
        %init(LXDI);
    } else if (objc_getClass("MRUSessionNowPlayingViewController")) {
        done = YES;
        gLXDIExpanded = lx_diSessionExpanded;
        %init(LXDI16);
    }
}

static void LXDIImageAdded(const struct mach_header *mh, intptr_t slide) {
    LXDIInitIfLoaded();
}

void lx_handleLikedStateChangedInMRUDI(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        lx_updateMRUDIHeartButtonAppearance();
    });
}

%ctor {
    _dyld_register_func_for_add_image(LXDIImageAdded);

    int token;
    notify_register_dispatch(kLikedStateNotifyName, &token, dispatch_get_main_queue(), ^(int t) {
        lx_handleLikedStateChangedInMRUDI();
    });
}
