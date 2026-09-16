#import "../Shared.h"
#import <objc/runtime.h>
#include <string.h>

// Read-only introspection of a block's compiler-embedded Objective-C type-encoding signature
// (the same mechanism NSInvocation/KVO use), so we can learn responseBlock/errorBlock's real
// argument types without guessing and risking a call-signature mismatch. Never invokes the
// block - only reads its layout, so this is safe even if the flag/signature turn out absent.
struct lx_BlockDescriptor {
    unsigned long reserved;
    unsigned long size;
    void *rest[1];
};

struct lx_BlockLiteral {
    void *isa;
    int flags;
    int reserved;
    void *invoke;
    struct lx_BlockDescriptor *descriptor;
};

static const int kLXBlockHasCopyDispose = (1 << 25);
static const int kLXBlockHasSignature = (1 << 30);

static NSString *lx_ytmBlockSignature(id blockObj) {
    if (!blockObj) {
        return @"(nil)";
    }
    struct lx_BlockLiteral *block = (__bridge struct lx_BlockLiteral *) blockObj;
    if (!(block->flags & kLXBlockHasSignature) || !block->descriptor) {
        return @"(no embedded signature)";
    }
    void **descriptorSlots = (void **) block->descriptor;
    int signatureIndex = 2; // slot 0 = reserved, slot 1 = size (both unsigned long, pointer-sized on arm64)
    if (block->flags & kLXBlockHasCopyDispose) {
        signatureIndex += 2; // copy + dispose helper pointers
    }
    const char *signature = (const char *) descriptorSlots[signatureIndex];
    return signature ? [NSString stringWithUTF8String: signature] : @"(null signature)";
}

static BOOL lx_ytmNameLooksPromising(const char *name) {
    NSString *lowered = [[NSString stringWithUTF8String: name] lowercaseString];
    NSArray<NSString *> *needles = @[@"like", @"dislike", @"rating", @"thumbsup", @"thumbdown", @"thumb", @"togglebutton", @"favorite", @"favourite"];
    for (NSString *needle in needles) {
        if ([lowered containsString: needle]) {
            return YES;
        }
    }
    return NO;
}

// TODO(debug): remove once the real like/dislike hook for YouTube Music is confirmed working.
// No private-header dump exists for YTM's like API (unlike Spotify's), so this scans every
// loaded class for a plausible name and dumps its instance methods - the same discovery
// approach that found the broken Spotify init signature. Round 1 result: found real classes
// (YTMLikeEndpointCommandImpl, YTMLikeStatusDidChangeResponderEvent, YTMCarPlayLikeStatusHolder,
// etc), so round 2 (below) hooks the most promising ones read-only to see live call arguments.
static void lx_ytmDebugScanForLikeClasses(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG] scanning %u loaded classes for like/rating candidates", classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        const char *name = class_getName(classes[i]);
        if (!name || !lx_ytmNameLooksPromising(name)) {
            continue;
        }
        NSLog(@"[SpotiLoveReborn][YTM-DEBUG] candidate class: %s", name);
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG]     - %@", NSStringFromSelector(method_getName(methods[j])));
        }
        free(methods);
    }
    free(classes);
}

static BOOL lx_ytmSelectorLooksPromising(SEL sel) {
    const char *name = sel_getName(sel);
    static const char *needles[] = {"like", "dislike", "rating", "thumbup", "thumbdown", "thumbsup", "thumbsdown", "favorite", "favourite"};
    for (size_t i = 0; i < sizeof(needles) / sizeof(needles[0]); i++) {
        if (strcasestr(name, needles[i])) {
            return YES;
        }
    }
    return NO;
}

// Round 1 only matched classes whose OWN name contains a needle. The actual view/controller
// that owns the visible like/dislike button may reuse a generic class name (YTM's player bar
// reuses button/controller classes across actions) with only its *method* naming the action, so
// this instead scans every method of every loaded class by selector name.
static void lx_ytmDebugScanAllMethodsForLikeSelectors(void) {
    unsigned int classCount = 0;
    Class *classes = objc_copyClassList(&classCount);
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][SEL] scanning methods of %u classes for like/rating selectors", classCount);
    for (unsigned int i = 0; i < classCount; i++) {
        unsigned int methodCount = 0;
        Method *methods = class_copyMethodList(classes[i], &methodCount);
        for (unsigned int j = 0; j < methodCount; j++) {
            SEL sel = method_getName(methods[j]);
            if (lx_ytmSelectorLooksPromising(sel)) {
                NSLog(@"[SpotiLoveReborn][YTM-DEBUG][SEL] %s -%s", class_getName(classes[i]), sel_getName(sel));
            }
        }
        free(methods);
    }
    free(classes);
}

// Round 1 only dumped INSTANCE methods, missing any class-side factory methods (e.g. a
// +notificationWith... constructor for YTMLikeModificationNotificationData, mirroring
// YTQueueModificationNotificationData's +addToQueueNotificationWithQueueItems:... in NextUp3).
static void lx_ytmDebugDumpClassAndInstanceMethods(const char *className) {
    Class cls = objc_getClass(className);
    if (!cls) {
        NSLog(@"[SpotiLoveReborn][YTM-DEBUG][FULL] %s not found", className);
        return;
    }
    unsigned int count = 0;
    Method *instanceMethods = class_copyMethodList(cls, &count);
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][FULL] %s instance methods:", className);
    for (unsigned int i = 0; i < count; i++) {
        NSLog(@"[SpotiLoveReborn][YTM-DEBUG][FULL]   - %@", NSStringFromSelector(method_getName(instanceMethods[i])));
    }
    free(instanceMethods);

    Method *classMethods = class_copyMethodList(object_getClass(cls), &count);
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][FULL] %s class methods:", className);
    for (unsigned int i = 0; i < count; i++) {
        NSLog(@"[SpotiLoveReborn][YTM-DEBUG][FULL]   + %@", NSStringFromSelector(method_getName(classMethods[i])));
    }
    free(classMethods);
}

static void lx_ytmDebugDumpFinalistClasses(void) {
    static const char *finalists[] = {
        "YTMLikeModificationNotificationData",
        "YTILikeButtonRenderer",
        "YTLikeServiceImpl",
        "YTMLikeEndpointCommandImpl",
        "YTMCarPlayLikeStatusHolder",
        "YTMLikeStatusDidChangeResponderEvent",
        "YTMLikeActionOptimisticHandlerImpl",
        "YTMLikeResponseHandlerImpl",
        // Round 6: requestForLikeWithTarget:... (round 4) returns one of these, but nothing
        // hooked so far shows what actually sends it over the network. Dump it in case it has
        // an obvious -send/-execute/-start method we can hook next round.
        "YTInnerTubeRequest",
        "YTILikeTarget",
        // Round 9: -endpointWithStatus: fires just from the like button rendering (no in-app tap
        // needed, unlike requestForLikeWithTarget:/requestForRemoveLikeWithTarget:, which only
        // fire after an actual tap inside YTM). Its returned YTILikeEndpoint already carries the
        // target + like_params/remove_like_params we need - dump its real accessors here instead
        // of guessing the property names from the protobuf field names.
        "YTILikeEndpoint",
    };
    for (size_t i = 0; i < sizeof(finalists) / sizeof(finalists[0]); i++) {
        lx_ytmDebugDumpClassAndInstanceMethods(finalists[i]);
    }
}

static void lx_ytmRunAllDebugScans(void) {
    lx_ytmDebugScanForLikeClasses();
    lx_ytmDebugScanAllMethodsForLikeSelectors();
    lx_ytmDebugDumpFinalistClasses();
}

// --- Rounds 2-3: read-only hooks on the most promising real classes found in round 1. These only
// log (via %orig passthrough, never altering behaviour) so tapping like/dislike inside YTM's own
// UI is completely safe and shows us the real live arguments. Round 2 confirmed
// handleLikeActionWithCommand:entry:fromView:sender: fires with a heavy, UI-bound "entry" (an
// ELMNodeController) - round 3 adds YTILikeButtonRenderer's class-side factory
// (+likeButtonRendererWithVideoID:likeStatus:), which may let a future write path build a command
// from just a video id instead. `likeStatus`-named parameters are logged as a raw pointer/integer,
// never with %@, since we don't know yet whether the real type is an object or a plain enum -
// dereferencing a non-object value via %@ could crash.

// The crash from the previous round confirms it: likeStatus/status parameters are a plain
// NSInteger-sized enum, not an object (objc_retain crashed trying to retain the raw value 2).
// Declaring them as `id` made ARC implicitly retain that garbage pointer on method entry, before
// any of our code even ran. Every likeStatus/status here is NSInteger now - never id.

@interface YTMLikeEndpointCommandImpl : NSObject
- (void) toggleLikeStatusForTrackWithLikeEndpoint: (id) likeEndpoint track: (id) track;
- (void) executeWithCommand: (id) command entry: (id) entry fromView: (id) fromView sender: (id) sender;
- (void) updateEntityWithLikeStatus: (NSInteger) likeStatus videoID: (id) videoID;
- (void) updateEntityWithLikeEndpoint: (id) likeEndpoint revertOptimisticUpdate: (BOOL) revertOptimisticUpdate;
@end

// Round 1 found these on YTILikeButtonRenderer, the data model backing the visible like/dislike
// button for whatever track/video is currently on screen. +likeButtonRendererWithVideoID:likeStatus:
// looks like it can build one from just a video id, without needing any live UI object - if true,
// that sidesteps the ELM-bound entry/fromView/sender objects entirely for the write path.
@interface YTILikeButtonRenderer : NSObject
- (NSInteger) likeStatus;
- (id) endpointWithStatus: (NSInteger) status;
+ (id) likeButtonRendererWithVideoID: (id) videoID likeStatus: (NSInteger) likeStatus;
+ (NSInteger) ytm_newLikeStatusFromLikeButtonTap: (NSInteger) currentStatus;
+ (NSInteger) ytm_newLikeStatusFromDislikeButtonTap: (NSInteger) currentStatus;
@end

@interface YTMLikeStatusDidChangeResponderEvent : NSObject
- (id) initWithLikeStatus: (NSInteger) likeStatus firstResponder: (id) firstResponder;
@end

@interface YTMCarPlayLikeStatusHolder : NSObject
- (id) initWithIdentifier: (id) identifier likeStatus: (NSInteger) likeStatus;
@end

@interface YTMLikeActionOptimisticHandlerImpl : NSObject
- (void) handleLikeActionWithCommand: (id) command entry: (id) entry fromView: (id) fromView sender: (id) sender;
@end

@interface YTMLikeResponseHandlerImpl : NSObject
- (void) setLikeStatusForTrackWithLikeEndpoint: (id) likeEndpoint track: (id) track;
@end

// Round 4: none of round 3's YTMLikeEndpointCommandImpl/YTILikeButtonRenderer factory methods
// ever fired for a real in-app tap - only handleLikeActionWithCommand:entry:fromView:sender:
// does, and its entry/fromView/sender stay UI-cell-bound (ELMNodeController), which a lock
// screen tap has no way to construct. YTLikeServiceImpl looks like the lower layer that
// actually issues the network request from just a target (a simple video-id wrapper) and status
// - no UI object in its signature at all - so this checks whether it's reachable independently.
@interface YTLikeServiceImpl : NSObject
- (id) initWithAccountID: (id) accountID;
- (void) makeRequestWithStatus: (NSInteger) status target: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams responseBlock: (id) responseBlock errorBlock: (id) errorBlock;
- (void) makeRequestWithStatus: (NSInteger) status target: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType responseBlock: (id) responseBlock errorBlock: (id) errorBlock;
- (id) requestForLikeWithTarget: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType;
- (id) requestForDislikeWithTarget: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType;
- (id) requestForRemoveLikeWithTarget: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType;
@end

// Round 7: captured from inside makeRequestWithStatus:... (more reliable than
// initWithAccountID:, which never fired live - the singleton is likely built before our hooks
// install) so we can reuse the same live service instance for our own write attempt.
id lx_ytmLikeServiceInstance;

// Round 8 (first real write attempt): cached from the read hooks below, which already fire
// during ordinary playback as YTM renders its own like/dislike button. Single-slot, last-seen
// only - not yet keyed by video id, so if the user browses a list with other tracks' like
// buttons while a different track plays, this could go stale and target the wrong track. A
// later hardening pass should key this by the actual now-playing video id, the same way
// NextUp3's YTQueueController.playbackQueueItems[nowPlayingIndex] already does in this exact
// process (see Fontes/NextUp3-main/NUYouTubeShared.h) - not done yet to keep this round's scope
// to validating the write call itself.
id lx_ytmCachedLikeTarget;
id lx_ytmCachedClickTrackingParams;
id lx_ytmCachedLikeRequestParams;       // requestParams that sets status to LIKE (0)
id lx_ytmCachedRemoveLikeRequestParams; // requestParams that sets status to INDIFFERENT (2)
NSInteger lx_ytmCachedCurrentLikeStatus = -1; // -1 = unknown/nothing observed yet

// Round 9: cached YTILikeEndpoint objects from -endpointWithStatus:, which fires just from the
// like button rendering (unlike requestForLikeWithTarget:/requestForRemoveLikeWithTarget:, which
// only fire after an actual in-app tap - round 9's log showed the toggle handler skipping every
// time because those never fired without one). Not used yet until the finalist dump above
// confirms YTILikeEndpoint's real accessor names.
id lx_ytmCachedLikeEndpointForLike;
id lx_ytmCachedLikeEndpointForRemoveLike;

%hook YTMLikeEndpointCommandImpl

- (void) toggleLikeStatusForTrackWithLikeEndpoint: (id) likeEndpoint track: (id) track {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] toggleLikeStatusForTrackWithLikeEndpoint:%@ track:%@", likeEndpoint, track);
    %orig;
}

- (void) executeWithCommand: (id) command entry: (id) entry fromView: (id) fromView sender: (id) sender {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] executeWithCommand:%@ entry:%@ fromView:%@ sender:%@", command, entry, fromView, sender);
    %orig;
}

- (void) updateEntityWithLikeStatus: (NSInteger) likeStatus videoID: (id) videoID {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] updateEntityWithLikeStatus(raw):%ld videoID:%@", (long) likeStatus, videoID);
    %orig;
}

- (void) updateEntityWithLikeEndpoint: (id) likeEndpoint revertOptimisticUpdate: (BOOL) revertOptimisticUpdate {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] updateEntityWithLikeEndpoint:%@ revertOptimisticUpdate:%d", likeEndpoint, revertOptimisticUpdate);
    %orig;
}

%end

%hook YTILikeButtonRenderer

- (NSInteger) likeStatus {
    NSInteger result = %orig;
    lx_ytmCachedCurrentLikeStatus = result;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] YTILikeButtonRenderer likeStatus(raw)=%ld self=%@", (long) result, self);
    return result;
}

- (id) endpointWithStatus: (NSInteger) status {
    id result = %orig;
    // Cached separately by target status so round 10 can extract target/requestParams straight
    // from these, once the dump above confirms YTILikeEndpoint's real accessor names - this
    // fires just from the like button rendering, no in-app tap required.
    if (status == 0) {
        lx_ytmCachedLikeEndpointForLike = result;
    } else if (status == 2) {
        lx_ytmCachedLikeEndpointForRemoveLike = result;
    }
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] YTILikeButtonRenderer endpointWithStatus(raw)=%ld self=%@ result=%@",
          (long) status, self, result);
    return result;
}

+ (id) likeButtonRendererWithVideoID: (id) videoID likeStatus: (NSInteger) likeStatus {
    id result = %orig;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] +likeButtonRendererWithVideoID:%@ likeStatus(raw)=%ld result=%@",
          videoID, (long) likeStatus, result);
    return result;
}

+ (NSInteger) ytm_newLikeStatusFromLikeButtonTap: (NSInteger) currentStatus {
    NSInteger result = %orig;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] +ytm_newLikeStatusFromLikeButtonTap currentStatus(raw)=%ld newStatus(raw)=%ld",
          (long) currentStatus, (long) result);
    return result;
}

+ (NSInteger) ytm_newLikeStatusFromDislikeButtonTap: (NSInteger) currentStatus {
    NSInteger result = %orig;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] +ytm_newLikeStatusFromDislikeButtonTap currentStatus(raw)=%ld newStatus(raw)=%ld",
          (long) currentStatus, (long) result);
    return result;
}

%end

%hook YTMLikeStatusDidChangeResponderEvent

- (id) initWithLikeStatus: (NSInteger) likeStatus firstResponder: (id) firstResponder {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] YTMLikeStatusDidChangeResponderEvent likeStatus(raw)=%ld firstResponderClass=%@",
          (long) likeStatus, firstResponder ? NSStringFromClass([firstResponder class]) : @"(nil)");
    return %orig;
}

%end

%hook YTMCarPlayLikeStatusHolder

- (id) initWithIdentifier: (id) identifier likeStatus: (NSInteger) likeStatus {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] YTMCarPlayLikeStatusHolder identifier=%@ likeStatus(raw)=%ld", identifier, (long) likeStatus);
    return %orig;
}

%end

%hook YTMLikeActionOptimisticHandlerImpl

- (void) handleLikeActionWithCommand: (id) command entry: (id) entry fromView: (id) fromView sender: (id) sender {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] handleLikeActionWithCommand:%@ entry:%@ fromView:%@ sender:%@", command, entry, fromView, sender);
    %orig;
}

%end

%hook YTMLikeResponseHandlerImpl

- (void) setLikeStatusForTrackWithLikeEndpoint: (id) likeEndpoint track: (id) track {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] setLikeStatusForTrackWithLikeEndpoint:%@ track:%@", likeEndpoint, track);
    %orig;
}

%end

%hook YTLikeServiceImpl

- (id) initWithAccountID: (id) accountID {
    id result = %orig;
    lx_ytmLikeServiceInstance = result;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] YTLikeServiceImpl initWithAccountID:%@ result=%@", accountID, result);
    return result;
}

- (void) makeRequestWithStatus: (NSInteger) status target: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams responseBlock: (id) responseBlock errorBlock: (id) errorBlock {
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] makeRequestWithStatus(raw):%ld target:%@ clickTrackingParams:%@ queueContextParams:%@ requestParams:%@ responseBlockSig:%@ errorBlockSig:%@",
          (long) status, target, clickTrackingParams, queueContextParams, requestParams,
          lx_ytmBlockSignature(responseBlock), lx_ytmBlockSignature(errorBlock));
    %orig;
}

// Round 6: round 4 only hooked the 7-param overload (no requestDispatchType), which never fired.
// requestForLikeWithTarget:... returns a requestDispatchType, so the real caller almost
// certainly uses this 8-param overload instead - missed it in round 4's declaration.
- (void) makeRequestWithStatus: (NSInteger) status target: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType responseBlock: (id) responseBlock errorBlock: (id) errorBlock {
    lx_ytmLikeServiceInstance = self;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] makeRequestWithStatus(raw):%ld target:%@ clickTrackingParams:%@ queueContextParams:%@ requestParams:%@ requestDispatchType(raw):%ld responseBlockSig:%@ errorBlockSig:%@",
          (long) status, target, clickTrackingParams, queueContextParams, requestParams, (long) requestDispatchType,
          lx_ytmBlockSignature(responseBlock), lx_ytmBlockSignature(errorBlock));
    %orig;
}

- (id) requestForLikeWithTarget: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType {
    id result = %orig;
    lx_ytmCachedLikeTarget = target;
    lx_ytmCachedClickTrackingParams = clickTrackingParams;
    lx_ytmCachedLikeRequestParams = requestParams;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] requestForLikeWithTarget:%@ clickTrackingParams:%@ queueContextParams:%@ requestParams:%@ requestDispatchType(raw):%ld result:%@",
          target, clickTrackingParams, queueContextParams, requestParams, (long) requestDispatchType, result);
    return result;
}

- (id) requestForDislikeWithTarget: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType {
    id result = %orig;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] requestForDislikeWithTarget:%@ clickTrackingParams:%@ queueContextParams:%@ requestParams:%@ requestDispatchType(raw):%ld result:%@",
          target, clickTrackingParams, queueContextParams, requestParams, (long) requestDispatchType, result);
    return result;
}

- (id) requestForRemoveLikeWithTarget: (id) target clickTrackingParams: (id) clickTrackingParams queueContextParams: (id) queueContextParams requestParams: (id) requestParams requestDispatchType: (NSInteger) requestDispatchType {
    id result = %orig;
    lx_ytmCachedLikeTarget = target;
    lx_ytmCachedClickTrackingParams = clickTrackingParams;
    lx_ytmCachedRemoveLikeRequestParams = requestParams;
    NSLog(@"[SpotiLoveReborn][YTM-DEBUG][HOOK] requestForRemoveLikeWithTarget:%@ clickTrackingParams:%@ queueContextParams:%@ requestParams:%@ requestDispatchType(raw):%ld result:%@",
          target, clickTrackingParams, queueContextParams, requestParams, (long) requestDispatchType, result);
    return result;
}

%end

void lx_handleLikeToggleNotificationYouTubeMusic() {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!lx_ytmLikeServiceInstance || !lx_ytmCachedLikeTarget) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle: nothing cached yet (play a track and let its like button render at least once first), skipping");
            return;
        }

        BOOL isCurrentlyLiked = (lx_ytmCachedCurrentLikeStatus == 0); // 0 = LIKE, confirmed via round 6/7 correlation
        NSInteger targetStatus = isCurrentlyLiked ? 2 /* INDIFFERENT */ : 0 /* LIKE */;
        id requestParams = isCurrentlyLiked ? lx_ytmCachedRemoveLikeRequestParams : lx_ytmCachedLikeRequestParams;
        if (!requestParams) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle: no cached requestParams for target status %ld yet, skipping", (long) targetStatus);
            return;
        }

        // Signatures confirmed by reading the blocks' own compiler-embedded type encoding
        // (round 7): responseBlock is void(^)(YTILikeResponse *, BOOL), errorBlock is
        // void(^)(NSError *). Declaring `id` for the object params is safe here since both are
        // confirmed real objects, unlike the likeStatus/status enums elsewhere in this file.
        void (^responseBlock)(id, BOOL) = ^(id response, BOOL flag) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle: response=%@ flag=%d", response, flag);
        };
        void (^errorBlock)(id) = ^(id error) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle: error=%@", error);
        };

        @try {
            [lx_ytmLikeServiceInstance makeRequestWithStatus: targetStatus
                                                       target: lx_ytmCachedLikeTarget
                                         clickTrackingParams: lx_ytmCachedClickTrackingParams
                                          queueContextParams: nil
                                               requestParams: requestParams
                                         requestDispatchType: 1
                                               responseBlock: responseBlock
                                                  errorBlock: errorBlock];
            // Optimistic, matching YTM's own YTMLikeActionOptimisticHandlerImpl naming/behavior -
            // flip the cached status and report it immediately rather than waiting on the
            // network response, so the heart updates right away.
            lx_ytmCachedCurrentLikeStatus = targetStatus;
            lx_setLikedStateYouTubeMusic(targetStatus == 0);
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle: sent makeRequestWithStatus:%ld", (long) targetStatus);
        } @catch (NSException *e) {
            NSLog(@"[SpotiLoveReborn][YTM-DEBUG] toggle: caught %@: %@", e.name, e.reason);
        }
    });
}

%ctor {
    // The class/selector scans walk ~90k loaded classes - expensive, and round 2's log showed
    // it running 7 times concurrently (7 near-simultaneous "scanning..." lines within 130us of
    // each other), almost certainly from this ctor firing more than once. Running that on the
    // main thread, possibly several times at once, right at cold launch risks a launch watchdog
    // kill on its own. dispatch_once guards against repeat runs, and everything now runs off the
    // main queue so it can never block YTM's own launch/UI work. One pass only now - rounds 1-2
    // already captured the class/method data we needed; this round only adds the read-only hooks
    // below, which cost nothing until YTM itself calls the hooked methods.
    static dispatch_once_t debugScanOnceToken;
    dispatch_once(&debugScanOnceToken, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                        dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            lx_ytmRunAllDebugScans();
        });
    });

    CFNotificationCenterAddObserver(
        CFNotificationCenterGetDarwinNotifyCenter(),
        NULL,
        (CFNotificationCallback) lx_handleLikeToggleNotificationYouTubeMusic,
        (__bridge CFStringRef) kLikeToggleDarwinNotificationYouTubeMusic,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
}
