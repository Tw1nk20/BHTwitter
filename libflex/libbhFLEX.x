// FLEX bridge restored for BHTwitter 4.4 debug builds
#import "libFLEX.h"
#import "FLEXWindow.h"
#import "FLEXManager.h"

id FLXGetManager() {
    return [FLEXManager sharedManager];
}

SEL FLXRevealSEL() {
    return @selector(showExplorer);
}

Class FLXWindowClass() {
    return [FLEXWindow class];
}
