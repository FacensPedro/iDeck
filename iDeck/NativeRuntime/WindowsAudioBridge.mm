#import "RuntimeSupport.h"
#import <AVFoundation/AVFoundation.h>
extern "C" bool ideck_audio_session_activate(void) {
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSError *error = nil;
    if (![session setCategory:AVAudioSessionCategoryPlayback mode:AVAudioSessionModeDefault options:AVAudioSessionCategoryOptionMixWithOthers error:&error]) return false;
    return [session setActive:YES error:&error];
}
