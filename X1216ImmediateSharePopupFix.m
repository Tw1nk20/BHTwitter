#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static IMP BHTOriginalImmediateShareLongPressIMP = NULL;
typedef void (*BHTShareLongPressIMP)(id, SEL, UILongPressGestureRecognizer *);

static void BHTImmediateShareLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gesture) {
    UIGestureRecognizerState state = gesture.state;

    if (BHTOriginalImmediateShareLongPressIMP) {
        ((BHTShareLongPressIMP)BHTOriginalImmediateShareLongPressIMP)(self, _cmd, gesture);
    }

    if (state != UIGestureRecognizerStateBegan) return;

    // X 12.16 can defer TFNMenuSheet presentation while the originating
    // long-press recognizer is still holding the touch. The original BHT
    // handler has already fired the haptic and requested the download/error
    // popup at Began. Cancel only this BHT recognizer immediately afterwards
    // so UIKit considers the originating touch sequence finished without
    // waiting for the user's finger to lift.
    gesture.enabled = NO;
    gesture.enabled = YES;
}

__attribute__((constructor)) static void BHTX1216ImmediateSharePopupFixInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"BHTShareDownloadTarget");
        SEL selector = NSSelectorFromString(@"bht_shareLongPressed:");
        Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
        if (!method) return;

        BHTOriginalImmediateShareLongPressIMP = method_getImplementation(method);
        method_setImplementation(method, (IMP)BHTImmediateShareLongPress);
        NSLog(@"[BHTwitter][X12.16] Installed immediate share popup gesture release fix");
    });
}
