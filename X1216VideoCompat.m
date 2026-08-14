#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static IMP BHTInheritedShareLongPressIMP = NULL;
typedef void (*BHTShareLongPressIMP)(id, SEL, UILongPressGestureRecognizer *);

static id BHTActionsViewForShareButton(id shareButton) {
    if ([shareButton isKindOfClass:[UIView class]]) {
        UIView *superview = [(UIView *)shareButton superview];
        if ([superview isKindOfClass:NSClassFromString(@"TTAStatusInlineActionsView")]) {
            return superview;
        }
    }

    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareButton respondsToSelector:delegateSEL]) {
        id delegate = ((id (*)(id, SEL))objc_msgSend)(shareButton, delegateSEL);
        if ([delegate isKindOfClass:NSClassFromString(@"TTAStatusInlineActionsView")]) {
            return delegate;
        }
    }

    return nil;
}

static void BHTX1216ShareLongPress(id self, SEL _cmd, UILongPressGestureRecognizer *gestureRecognizer) {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan && [BHTManager DownloadingVideos]) {
        id actionsView = BHTActionsViewForShareButton(self);
        SEL viewModelSEL = NSSelectorFromString(@"viewModel");
        id viewModel = nil;

        if (actionsView && [actionsView respondsToSelector:viewModelSEL]) {
            viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL);
        }

        if (viewModel && [BHTManager isVideoCell:viewModel]) {
            NSLog(@"[BHTwitter][X12.16] Native share long-press intercepted for video: %@", NSStringFromClass([viewModel class]));

            BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
            downloadButton.delegate = (id)actionsView;
            downloadButton.viewModel = viewModel;
            [downloadButton DownloadHandler:nil];
            return;
        }
    }

    // Non-video posts and disabled-download mode retain X/BHTwitter's original behavior.
    if (BHTInheritedShareLongPressIMP) {
        ((BHTShareLongPressIMP)BHTInheritedShareLongPressIMP)(self, _cmd, gestureRecognizer);
    }
}

static void BHTInstallX1216VideoCompat(void) {
    Class cls = NSClassFromString(@"TTAStatusInlineShareButton");
    SEL selector = NSSelectorFromString(@"didLongPressActionButton:");
    if (!cls) {
        NSLog(@"[BHTwitter][X12.16] TTAStatusInlineShareButton not found");
        return;
    }

    Method inheritedMethod = class_getInstanceMethod(cls, selector);
    if (!inheritedMethod) {
        NSLog(@"[BHTwitter][X12.16] didLongPressActionButton: not found in hierarchy");
        return;
    }

    BHTInheritedShareLongPressIMP = method_getImplementation(inheritedMethod);
    const char *types = method_getTypeEncoding(inheritedMethod);

    // Critical: add an override to TTAStatusInlineShareButton itself. Do not
    // method_setImplementation() on an inherited Method because that can modify
    // the superclass implementation and affect unrelated inline-action buttons.
    if (class_addMethod(cls, selector, (IMP)BHTX1216ShareLongPress, types)) {
        NSLog(@"[BHTwitter][X12.16] Installed class-local native long-press download override");
        return;
    }

    // If the class already owns the method (for example another tweak added it),
    // replace only that class-local implementation.
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method ownMethod = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            ownMethod = methods[i];
            break;
        }
    }
    free(methods);

    if (ownMethod) {
        BHTInheritedShareLongPressIMP = method_getImplementation(ownMethod);
        method_setImplementation(ownMethod, (IMP)BHTX1216ShareLongPress);
        NSLog(@"[BHTwitter][X12.16] Replaced class-local native long-press implementation");
    } else {
        NSLog(@"[BHTwitter][X12.16] Could not install class-local long-press override");
    }
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216VideoCompat();
    });
}
