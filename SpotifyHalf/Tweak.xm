#import "../Shared.h"

@interface SPTNowPlayingAuxiliaryActionsHandlerImplementation : NSObject
- (void) toggleCollectionState;
- (BOOL) isCurrentTrackInCollection;
- (id) currentTrackURI;
@end

SPTNowPlayingAuxiliaryActionsHandlerImplementation *lx_actionsHandler;

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

%end

void lx_handleLikeToggleNotification() {
    if (lx_actionsHandler == nil) {
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            [lx_actionsHandler toggleCollectionState];
        } @catch (NSException *e) {
            // Best effort.
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
