#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const void *BHTVideoLongPressKey = &BHTVideoLongPressKey;
static IMP BHTOriginalShareLayoutIMP = NULL;

typedef void (*BHTVoidIMP)(id, SEL);

@interface BHTVideoLongPressTarget : NSObject <UIGestureRecognizerDelegate>
@end

@implementation BHTVideoLongPressTarget

+ (instancetype)sharedTarget {
    static BHTVideoLongPressTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTVideoLongPressTarget new]; });
    return target;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return NO;
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

    if (!actionsView || ![actionsView respondsToSelector:NSSelectorFromString(@"viewModel")]) {
        NSLog(@"[BHTwitter][X12.16] Video long press: actionsView/viewModel unavailable");
        return;
    }

    id viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, NSSelectorFromString(@"viewModel"));
    BOOL isVideo = viewModel && [BHTManager isVideoCell:viewModel];
    NSLog(@"[BHTwitter][X12.16] Video long press fired. viewModel=%@ isVideo=%d",
          viewModel ? NSStringFromClass([viewModel class]) : @"nil", isVideo);

    if (!isVideo) return;

    BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloadButton.delegate = (id)actionsView;
    downloadButton.viewModel = viewModel;
    [downloadButton DownloadHandler:nil];
}

@end

static void BHTAttachVideoLongPressIfNeeded(UIView *view) {
    if (!view || objc_getAssociatedObject(view, BHTVideoLongPressKey)) return;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc]
        initWithTarget:[BHTVideoLongPressTarget sharedTarget]
                action:@selector(bht_handleVideoLongPress:)];

    // Start before X's own long-press/context-menu recognizer so this recognizer
    // wins the gesture arbitration for video posts.
    gesture.minimumPressDuration = 0.25;
    gesture.cancelsTouchesInView = YES;
    gesture.delaysTouchesBegan = YES;
    gesture.delegate = [BHTVideoLongPressTarget sharedTarget];

    [view addGestureRecognizer:gesture];
    objc_setAssociatedObject(view, BHTVideoLongPressKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    NSLog(@"[BHTwitter][X12.16] Attached video long-press recognizer to %@", NSStringFromClass([view class]));
}

static void BHTShareLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalShareLayoutIMP) {
        ((BHTVoidIMP)BHTOriginalShareLayoutIMP)(self, _cmd);
    }

    if ([self isKindOfClass:[UIView class]]) {
        BHTAttachVideoLongPressIfNeeded((UIView *)self);
    }
}

static void BHTInstallX1216VideoCompat(void) {
    Class cls = NSClassFromString(@"TTAStatusInlineShareButton");
    SEL selector = @selector(layoutSubviews);
    Method inheritedMethod = cls ? class_getInstanceMethod(cls, selector) : NULL;

    if (!cls || !inheritedMethod) {
        NSLog(@"[BHTwitter][X12.16] Could not install share-button layout hook");
        return;
    }

    IMP replacement = (IMP)BHTShareLayoutSubviews;
    const char *types = method_getTypeEncoding(inheritedMethod);
    BHTOriginalShareLayoutIMP = method_getImplementation(inheritedMethod);

    // Add a class-local override when layoutSubviews is inherited. This avoids
    // accidentally replacing UIView's implementation globally.
    if (!class_addMethod(cls, selector, replacement, types)) {
        Method ownMethod = class_getInstanceMethod(cls, selector);
        if (!ownMethod) return;
        BHTOriginalShareLayoutIMP = method_getImplementation(ownMethod);
        method_setImplementation(ownMethod, replacement);
    }

    NSLog(@"[BHTwitter][X12.16] Installed share-button layout hook");

    // Also attach immediately to any share buttons already visible before the hook.
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ([view isKindOfClass:cls]) {
                BHTAttachVideoLongPressIfNeeded(view);
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216VideoCompat();
    });
}
