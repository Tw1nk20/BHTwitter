#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP BHTOriginalDownloadDidFinishIMP = NULL;
typedef void (*BHTDownloadDidFinishIMP)(id, SEL, NSURL *, NSString *);

static void BHTDownloadCompletionImpact(void) {
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator prepare];
    [generator impactOccurred];
}

static void BHTDownloadDidFinishWithHaptic(id self, SEL _cmd, NSURL *tmpURL, NSString *name) {
    if (BHTOriginalDownloadDidFinishIMP) {
        ((BHTDownloadDidFinishIMP)BHTOriginalDownloadDidFinishIMP)(self, _cmd, tmpURL, name);
    }

    // Fire only after BHTwitter's original completion path has run.
    dispatch_async(dispatch_get_main_queue(), ^{
        BHTDownloadCompletionImpact();
    });
}

__attribute__((constructor)) static void BHTX1216DownloadHapticsInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"BHDownloadInlineButton");
        SEL selector = NSSelectorFromString(@"downloadDidFinish:Filename:");
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method) return;

        BHTOriginalDownloadDidFinishIMP = method_getImplementation(method);
        method_setImplementation(method, (IMP)BHTDownloadDidFinishWithHaptic);
        NSLog(@"[BHTwitter][X12.16] Installed download-completion haptic");
    });
}
