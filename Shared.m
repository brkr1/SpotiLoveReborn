#import "Shared.h"

BOOL lx_isPlayingFromSpotify(void) {
    SBMediaController *shared = [(id) NSClassFromString(@"SBMediaController") sharedInstance];
    NSString *nowPlayingBundleId = shared.nowPlayingApplication.bundleIdentifier;
    return [nowPlayingBundleId isEqualToString: @"com.spotify.client"];
}
