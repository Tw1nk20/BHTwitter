#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static IMP BHTOriginalShareLongPressIMP = NULL;

typedef void (*BHTShareLongPressIMP)(id, SEL, UILongPressGestureRecognizer *);

static void BHTX1216ShareLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gestureRecognizer) {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan && [BHTManager DownloadingVideos]) {
        id actionsView = nil;

        // X 12.16 immersive timeline still embeds TTAStatusInlineShareButton
        // directly inside TTAStatusInlineActionsView. Prefer the real superview
        // observed with FLEX, then fall back to the button delegate.
        if ([self respondsToSelector:@selector(superview)]) {
            UIView *superview = ((UIView *(*)(id, SEL))objc_msgSend)(self, @selector(superview));
            if ([superview isKindOfClass:NSClassFromString(@"TTAStatusInlineActionsView")]) {
                actionsView = superview;
            }
        }

        if (!actionsView && [self respondsToSelector:NSSelectorFromString(@"delegate")]) {
            actionsView = ((id (*)(id, SEL))objc_msgSend)(self, NSSelectorFromString(@"delegate"));
        }

        id viewModel = nil;
        if (actionsView && [actionsView respondsToSelector:NSSelectorFromString(@"viewModel")]) {
            viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, NSSelectorFromString(@"viewModel"));
        }

        if (viewModel && [BHTManager isVideoCell:viewModel]) {
            NSLog(@"[BHTwitter][X12.16] Video long press detected. viewModel=%@", NSStringFromClass([viewModel class]));

            BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
            downloadButton.delegate = (id)actionsView;
            downloadButton.viewModel = viewModel;
            [downloadButton DownloadHandler:nil];
            return;
        }
    }

    if (BHTOriginalShareLongPressIMP) {
        ((BHTShareLongPressIMP)BHTOriginalShareLongPressIMP)(self, _cmd, gestureRecognizer);
    }
}

static void BHTInstallX1216VideoCompat(void) {
    Class cls = NSClassFromString(@"TTAStatusInlineShareButton");
    SEL selector = NSSelectorFromString(@"didLongPressActionButton:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;

    if (!method) {
        NSLog(@"[BHTwitter][X12.16] Could not find TTAStatusInlineShareButton didLongPressActionButton:");
        return;
    }

    IMP current = method_getImplementation(method);
    IMP replacement = (IMP)BHTX1216ShareLongPress;

    if (current == replacement) {
        return;
    }

    BHTOriginalShareLongPressIMP = current;
    method_setImplementation(method, replacement);
    NSLog(@"[BHTwitter][X12.16] Installed video download long-press fallback");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    // Install after Logos hooks have initialized, so the saved implementation
    // remains the complete original BHTwitter/X behavior for non-video cases.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216VideoCompat();
    });
}
