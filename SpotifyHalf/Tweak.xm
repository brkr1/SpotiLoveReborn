#import "../Shared.h"

@interface SPTNowPlayingAuxiliaryActionsHandlerImplementation : NSObject
- (void) toggleCollectionState;
- (void) toggleCollectionStateFromViewController: (id) viewController
                                andActionControl: (id) actionControl
                                 withConfirmation: (BOOL) confirmation;
- (BOOL) isCurrentTrackInCollection;
- (id) currentTrackURI;
@end

SPTNowPlayingAuxiliaryActionsHandlerImplementation *lx_actionsHandler;

static void lx_reportCurrentLikedState(void) {
    if (lx_actionsHandler == nil) {
        return;
    }

    @try {
        BOOL isLiked = [lx_actionsHandler isCurrentTrackInCollection];
        lx_setLikedState(isLiked);
    } @catch (NSException *e) {
        // Best effort.
    }
}

%hook SPTNowPlayingAuxiliaryActionsHandlerImplementation

- (id) initWithModel: (id) model
    playbackSpeedUIPresenter: (id) playbackSpeedUIPresenter
             contextMenuService: (id) contextMenuService
       podcastContextMenuProvider: (id) podcastContextMenuProvider
                nowPlayingManager: (id) nowPlayingManager
                   linkDispatcher: (id) linkDispatcher
                     modeResolver: (id) modeResolver
                           logger: (id) logger
                      testManager: (id) testManager
                 sleepTimerService: (id) sleepTimerService
              smartShuffleHandler: (id) smartShuffleHandler
    nowPlayingContextMenuSettingsActionsProvider: (id) nowPlayingContextMenuSettingsActionsProvider
                    djPlaylistUri: (id) djPlaylistUri
    djSettingsLanguageActionTaskFactory: (id) djSettingsLanguageActionTaskFactory {
    id result = %orig;
    if (result != nil) {
        lx_actionsHandler = result;
    }
    return result;
}

- (void) auxiliaryActionsModelDidChangeCollectionState: (id) model {
    %orig;
    lx_reportCurrentLikedState();
}

%end

void lx_handleLikeToggleNotification() {
    if (lx_actionsHandler == nil) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [lx_actionsHandler toggleCollectionStateFromViewController: nil
                                                       andActionControl: nil
                                                        withConfirmation: NO];
        } @catch (NSException *e) {
            // Best effort.
        }

        NSArray<NSNumber *> *delays = @[@0.4, @1.0, @2.0];
        for (NSNumber *delay in delays) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)([delay doubleValue] * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                lx_reportCurrentLikedState();
            });
        }
    });
}

%ctor {
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback) lx_handleLikeToggleNotification,
        (__bridge CFStringRef) kLikeToggleDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
