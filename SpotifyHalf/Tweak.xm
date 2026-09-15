#import "../Shared.h"
#import <objc/runtime.h>

@interface SPTNowPlayingAuxiliaryActionsHandlerImplementation : NSObject
- (void) toggleCollectionState;
- (void) toggleCollectionStateFromViewController: (id) viewController
                                andActionControl: (id) actionControl
                                 withConfirmation: (BOOL) confirmation;
- (BOOL) isCurrentTrackInCollection;
- (id) currentTrackURI;
@end

SPTNowPlayingAuxiliaryActionsHandlerImplementation *lx_actionsHandler;

// TODO(debug): remove once 9.1.82 heart sync is confirmed working again.
static void lx_debugDumpActionsHandlerClass(void) {
    Class cls = objc_getClass("SPTNowPlayingAuxiliaryActionsHandlerImplementation");
    if (!cls) {
        NSLog(@"[SpotiLoveReborn][DEBUG] SPTNowPlayingAuxiliaryActionsHandlerImplementation not found");
        return;
    }
    NSLog(@"[SpotiLoveReborn][DEBUG] SPTNowPlayingAuxiliaryActionsHandlerImplementation found, dumping instance methods:");
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int i = 0; i < count; i++) {
        NSLog(@"[SpotiLoveReborn][DEBUG]   - %@", NSStringFromSelector(method_getName(methods[i])));
    }
    free(methods);
}

static void lx_reportCurrentLikedState(void) {
    if (lx_actionsHandler == nil) {
        NSLog(@"[SpotiLoveReborn][DEBUG] lx_reportCurrentLikedState: lx_actionsHandler is nil, skipping");
        return;
    }

    @try {
        BOOL isLiked = [lx_actionsHandler isCurrentTrackInCollection];
        NSLog(@"[SpotiLoveReborn][DEBUG] lx_reportCurrentLikedState: isCurrentTrackInCollection = %d", isLiked);
        lx_setLikedState(isLiked);
    } @catch (NSException *e) {
        NSLog(@"[SpotiLoveReborn][DEBUG] lx_reportCurrentLikedState: caught %@: %@", e.name, e.reason);
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
    NSLog(@"[SpotiLoveReborn][DEBUG] initWithModel:... hook fired, result = %@", result);
    if (result != nil) {
        lx_actionsHandler = result;
    }
    return result;
}

- (void) auxiliaryActionsModelDidChangeCollectionState: (id) model {
    %orig;
    NSLog(@"[SpotiLoveReborn][DEBUG] auxiliaryActionsModelDidChangeCollectionState: fired");
    lx_reportCurrentLikedState();
}

%end

void lx_handleLikeToggleNotification() {
    if (lx_actionsHandler == nil) {
        NSLog(@"[SpotiLoveReborn][DEBUG] lx_handleLikeToggleNotification: lx_actionsHandler is nil, skipping");
        return;
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            NSLog(@"[SpotiLoveReborn][DEBUG] lx_handleLikeToggleNotification: calling toggleCollectionStateFromViewController:...");
            [lx_actionsHandler toggleCollectionStateFromViewController: nil
                                                       andActionControl: nil
                                                        withConfirmation: NO];
        } @catch (NSException *e) {
            NSLog(@"[SpotiLoveReborn][DEBUG] lx_handleLikeToggleNotification: caught %@: %@", e.name, e.reason);
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
    lx_debugDumpActionsHandlerClass();

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback) lx_handleLikeToggleNotification,
        (__bridge CFStringRef) kLikeToggleDarwinNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
