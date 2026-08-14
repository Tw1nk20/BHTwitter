#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const void *BHTVideoLongPressKey = &BHTVideoLongPressKey;

@interface BHTVideoLongPressTarget : NSObject
@end

@implementation BHTVideoLongPressTarget
+ (instancetype)sharedTarget {
    static BHTVideoLongPressTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTVideoLongPressTarget new]; });
    return target;
}

- (void)bht_handleVideoLongPress:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    if (![BHTManager DownloadingVideos]) return;

    UIView *shareButton = gesture.view;
    if (!shareButton) return;

    id actionsView = shareButton.superview;
    if (![actionsView isKindOfClass:NSClassFromString(@"TTAStatusInlineActionsView")]) {
        if ([shareButton respondsToSelector:NSSelectorFromString(@"delegate")]) {
            actionsView = ((id (*)(id, SEL))objc_msgSend)(shareButton, NSSelectorFromString(@"delegate"));
        }
    }

    if (!actionsView || ![actionsView respondsToSelector:NSSelectorFromString(@"viewModel")]) return;

    id viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, NSSelectorFromString(@"viewModel"));
    if (!viewModel || ![BHTManager isVideoCell:viewModel]) return;

    NSLog(@"[BHTwitter][X12.16] Direct video long press fired: %@", NSStringFromClass([viewModel class]));

    BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloadButton.delegate = (id)actionsView;
    downloadButton.viewModel = viewModel;
    [downloadButton DownloadHandler:nil];
}
@end

static IMP BHTOriginalShareDidMoveToWindowIMP = NULL;
typedef void (*BHTVoidIMP)(id, SEL);

static void BHTShareDidMoveToWindow(id self, SEL _cmd) {
    if (BHTOriginalShareDidMoveToWindowIMP) {
        ((BHTVoidIMP)BHTOriginalShareDidMoveToWindowIMP)(self, _cmd);
    }

    if (![self isKindOfClass:[UIView class]]) return;
    UIView *view = (UIView *)self;
    if (!view.window) return;
    if (objc_getAssociatedObject(self, BHTVideoLongPressKey)) return;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[BHTVideoLongPressTarget sharedTarget]
                action:@selector(bht_handleVideoLongPress:)];
    gesture.minimumPressDuration = 0.45;
    gesture.cancelsTouchesInView = YES;
    gesture.delaysTouchesBegan = YES;
    [view addGestureRecognizer:gesture];
    objc_setAssociatedObject(self, BHTVideoLongPressKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[BHTwitter][X12.16] Attached direct long-press recognizer to share button");
}

static void BHTInstallX1216VideoCompat(void) {
    Class cls = NSClassFromString(@"TTAStatusInlineShareButton");
    SEL selector = @selector(didMoveToWindow);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;

    if (!method) {
        NSLog(@"[BHTwitter][X12.16] Could not hook TTAStatusInlineShareButton didMoveToWindow");
        return;
    }

    IMP current = method_getImplementation(method);
    IMP replacement = (IMP)BHTShareDidMoveToWindow;
    if (current == replacement) return;

    BHTOriginalShareDidMoveToWindowIMP = current;
    method_setImplementation(method, replacement);
    NSLog(@"[BHTwitter][X12.16] Installed direct share-button gesture fallback");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216VideoCompat();
    });
}
