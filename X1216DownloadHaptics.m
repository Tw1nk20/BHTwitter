#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP BHTOriginalDownloadDidFinishIMP = NULL;
typedef void (*BHTDownloadDidFinishIMP)(id, SEL, NSURL *, NSString *);

static void BHTDownloadCompletionDoubleImpact(void) {
    UIImpactFeedbackGenerator *first = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [first prepare];
    [first impactOccurred];

    // A short second impact creates the requested "トトンッ" completion cue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIImpactFeedbackGenerator *second = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        [second prepare];
        [second impactOccurred];
    });
}

static void BHTDownloadDidFinishWithHaptic(id self, SEL _cmd, NSURL *tmpURL, NSString *name) {
    if (BHTOriginalDownloadDidFinishIMP) {
        ((BHTDownloadDidFinishIMP)BHTOriginalDownloadDidFinishIMP)(self, _cmd, tmpURL, name);
    }

    // Fire only after BHTwitter's original completion/save path has run.
    dispatch_async(dispatch_get_main_queue(), ^{
        BHTDownloadCompletionDoubleImpact();
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
        NSLog(@"[BHTwitter][X12.16] Installed double download-completion haptic");
    });
}
