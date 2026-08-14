#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const NSInteger BHTVideoDownloadButtonTag = 1216002;
static IMP BHTOriginalActionsLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

@interface BHTVideoDownloadTarget : NSObject
@end

@implementation BHTVideoDownloadTarget
+ (instancetype)sharedTarget {
    static BHTVideoDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTVideoDownloadTarget new]; });
    return target;
}

- (void)bht_downloadVideoTapped:(UIButton *)sender {
    UIView *actionsView = sender.superview;
    Class actionsClass = NSClassFromString(@"TTAStatusInlineActionsView");
    if (!actionsView || ![actionsView isKindOfClass:actionsClass]) return;

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if (![actionsView respondsToSelector:viewModelSEL]) return;

    id viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL);
    if (!viewModel || ![BHTManager isVideoCell:viewModel]) return;

    BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloadButton.delegate = (id)actionsView;
    downloadButton.viewModel = viewModel;
    [downloadButton DownloadHandler:nil];
}
@end

static UIView *BHTFindShareButton(UIView *root) {
    Class shareClass = NSClassFromString(@"TTAStatusInlineShareButton");
    if (!root || !shareClass) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:shareClass]) return view;
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void BHTLayoutVideoDownloadButton(UIView *actionsView) {
    UIButton *button = (UIButton *)[actionsView viewWithTag:BHTVideoDownloadButtonTag];

    if (![BHTManager DownloadingVideos]) {
        [button removeFromSuperview];
        return;
    }

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    id viewModel = [actionsView respondsToSelector:viewModelSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL)
        : nil;

    if (!viewModel || ![BHTManager isVideoCell:viewModel]) {
        [button removeFromSuperview];
        return;
    }

    UIView *shareButton = BHTFindShareButton(actionsView);
    if (!shareButton) {
        [button removeFromSuperview];
        return;
    }

    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = BHTVideoDownloadButtonTag;
        button.tintColor = shareButton.tintColor ?: UIColor.labelColor;
        button.backgroundColor = UIColor.clearColor;
        button.accessibilityLabel = @"動画をダウンロード";
        [button setImage:[UIImage systemImageNamed:@"arrow.down"] forState:UIControlStateNormal];
        [button addTarget:[BHTVideoDownloadTarget sharedTarget]
                   action:@selector(bht_downloadVideoTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [actionsView addSubview:button];
        NSLog(@"[BHTwitter][X12.16] Added dedicated video download button");
    }

    // Position immediately to the left of X's existing share button. Convert
    // coordinates in case the share button is wrapped by Swift container views.
    CGRect shareRect = [shareButton convertRect:shareButton.bounds toView:actionsView];
    CGFloat size = MAX(24.0, MIN(32.0, CGRectGetHeight(shareRect) > 0 ? CGRectGetHeight(shareRect) : 28.0));
    CGFloat spacing = 8.0;
    CGFloat x = CGRectGetMinX(shareRect) - spacing - size;
    CGFloat y = CGRectGetMidY(shareRect) - size / 2.0;

    // Keep the button inside the visible actions area. If there is no room on
    // the left, place it just inside the right edge rather than clipping it.
    x = MAX(0.0, MIN(x, CGRectGetWidth(actionsView.bounds) - size));
    y = MAX(0.0, MIN(y, CGRectGetHeight(actionsView.bounds) - size));

    button.frame = CGRectIntegral(CGRectMake(x, y, size, size));
    button.tintColor = shareButton.tintColor ?: UIColor.labelColor;
    button.hidden = NO;
    button.userInteractionEnabled = YES;
    [actionsView bringSubviewToFront:button];
}

static void BHTActionsLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalActionsLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalActionsLayoutIMP)(self, _cmd);
    }

    if ([self isKindOfClass:[UIView class]]) {
        BHTLayoutVideoDownloadButton((UIView *)self);
    }
}

static void BHTInstallX1216VideoCompat(void) {
    Class cls = NSClassFromString(@"TTAStatusInlineActionsView");
    SEL selector = @selector(layoutSubviews);
    if (!cls) {
        NSLog(@"[BHTwitter][X12.16] TTAStatusInlineActionsView not found");
        return;
    }

    Method inheritedMethod = class_getInstanceMethod(cls, selector);
    if (!inheritedMethod) {
        NSLog(@"[BHTwitter][X12.16] layoutSubviews not found for actions view");
        return;
    }

    BHTOriginalActionsLayoutIMP = method_getImplementation(inheritedMethod);
    const char *types = method_getTypeEncoding(inheritedMethod);

    // Prefer a class-local override so UIView/superclass implementations are
    // never replaced globally.
    if (class_addMethod(cls, selector, (IMP)BHTActionsLayoutSubviews, types)) {
        NSLog(@"[BHTwitter][X12.16] Installed dedicated download-button layout override");
        return;
    }

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
        BHTOriginalActionsLayoutIMP = method_getImplementation(ownMethod);
        method_setImplementation(ownMethod, (IMP)BHTActionsLayoutSubviews);
        NSLog(@"[BHTwitter][X12.16] Replaced class-local actions layout implementation");
    } else {
        NSLog(@"[BHTwitter][X12.16] Could not install actions layout override");
    }
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216VideoCompat();
    });
}
