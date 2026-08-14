#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static void BHTTryShowFLEX(NSUInteger attempt) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class flexManagerClass = NSClassFromString(@"FLEXManager");
        SEL sharedManagerSelector = NSSelectorFromString(@"sharedManager");
        SEL showExplorerSelector = NSSelectorFromString(@"showExplorer");
        BOOL didShow = NO;

        if (flexManagerClass && [flexManagerClass respondsToSelector:sharedManagerSelector]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id manager = [flexManagerClass performSelector:sharedManagerSelector];
            if (manager && [manager respondsToSelector:showExplorerSelector]) {
                NSLog(@"[BHTwitter][FLEX] FLEXManager found; showing explorer");
                [manager performSelector:showExplorerSelector];
                didShow = YES;
            }
#pragma clang diagnostic pop
        }

        if (didShow) return;

        if (attempt < 10) {
            NSLog(@"[BHTwitter][FLEX] FLEXManager not ready (attempt %lu)", (unsigned long)attempt);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BHTTryShowFLEX(attempt + 1);
            });
        } else {
            NSLog(@"[BHTwitter][FLEX] FLEXManager was not loaded after 10 attempts");
        }
    });
}

__attribute__((constructor)) static void BHTInstallFLEXLauncher(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTTryShowFLEX(1);
    });
}
