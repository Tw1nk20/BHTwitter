#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const NSInteger BHTVideoDownloadButtonTag = 1216002;
static IMP BHTOriginalTTActionsLayoutIMP = NULL;
static IMP BHTOriginalT1ActionsLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

static BOOL BHTIsActionsView(id obj) {
    Class tta = NSClassFromString(@"TTAStatusInlineActionsView");
    Class t1 = NSClassFromString(@"T1StatusInlineActionsView");
    return (tta && [obj isKindOfClass:tta]) || (t1 && [obj isKindOfClass:t1]);
}

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
    if (!actionsView || !BHTIsActionsView(actionsView)) return;

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
    Class ttaShare = NSClassFromString(@"TTAStatusInlineShareButton");
    Class t1Share = NSClassFromString(@"T1StatusInlineShareButton");
    if (!root) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ((ttaShare && [view isKindOfClass:ttaShare]) ||
            (t1Share && [view isKindOfClass:t1Share])) {
            return view;
        }
        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

static BOOL BHTViewModelIsVideo(id viewModel) {
    if (!viewModel) return NO;

    // Primary path used by BHTwitter and confirmed on X 12.16 with FLEX.
    if ([BHTManager isVideoCell:viewModel]) return YES;

    // Runtime fallback in case protocol dispatch changes while selectors remain.
    SEL videoSEL = NSSelectorFromString(@"isMediaEntityVideo");
    SEL gifSEL = NSSelectorFromString(@"isGIF");
    if ([viewModel respondsToSelector:videoSEL] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, videoSEL)) {
        return YES;
    }
    if ([viewModel respondsToSelector:gifSEL] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(viewModel, gifSEL)) {
        return YES;
    }

    // Last fallback: representedMediaEntities was also confirmed on X 12.16.
    SEL representedSEL = NSSelectorFromString(@"representedMediaEntities");
    if ([viewModel respondsToSelector:representedSEL]) {
        id entities = ((id (*)(id, SEL))objc_msgSend)(viewModel, representedSEL);
        if ([entities isKindOfClass:[NSArray class]]) {
            for (id media in (NSArray *)entities) {
                SEL mediaTypeSEL = NSSelectorFromString(@"mediaType");
                if ([media respondsToSelector:mediaTypeSEL]) {
                    NSInteger mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(media, mediaTypeSEL);
                    // Existing BHTwitter header: 2 = GIF, 3 = video.
                    if (mediaType == 2 || mediaType == 3) return YES;
                }
                NSString *desc = [[media description] lowercaseString];
                if ([desc containsString:@"mediatype: video"] || [desc containsString:@"mediatype: gif"]) {
                    return YES;
                }
            }
        }
    }
    return NO;
}

static void BHTLayoutVideoDownloadButton(UIView *actionsView) {
    if (!BHTIsActionsView(actionsView)) return;

    UIButton *button = (UIButton *)[actionsView viewWithTag:BHTVideoDownloadButtonTag];

    if (![BHTManager DownloadingVideos]) {
        [button removeFromSuperview];
        return;
    }

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    id viewModel = [actionsView respondsToSelector:viewModelSEL]
        ? ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL)
        : nil;

    if (!BHTViewModelIsVideo(viewModel)) {
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
        button.backgroundColor = UIColor.clearColor;
        button.accessibilityLabel = @"動画をダウンロード";
        UIImage *image = [UIImage systemImageNamed:@"arrow.down.to.line"] ?: [UIImage systemImageNamed:@"arrow.down"];
        [button setImage:image forState:UIControlStateNormal];
        [button addTarget:[BHTVideoDownloadTarget sharedTarget]
                   action:@selector(bht_downloadVideoTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [actionsView addSubview:button];
    }

    CGRect shareRect = [shareButton convertRect:shareButton.bounds toView:actionsView];
    CGFloat size = MAX(24.0, MIN(30.0, CGRectGetHeight(shareRect) > 0 ? CGRectGetHeight(shareRect) : 28.0));
    CGFloat spacing = 10.0;
    CGFloat x = CGRectGetMinX(shareRect) - spacing - size;
    CGFloat y = CGRectGetMidY(shareRect) - size / 2.0;

    // If the share button is very close to the left edge, place the download
    // button immediately to its right instead of clipping it out of sight.
    if (x < 0.0) {
        x = CGRectGetMaxX(shareRect) + spacing;
    }

    x = MAX(0.0, MIN(x, MAX(0.0, CGRectGetWidth(actionsView.bounds) - size)));
    y = MAX(0.0, MIN(y, MAX(0.0, CGRectGetHeight(actionsView.bounds) - size)));

    button.frame = CGRectIntegral(CGRectMake(x, y, size, size));
    button.tintColor = shareButton.tintColor ?: UIColor.labelColor;
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [actionsView bringSubviewToFront:button];
}

static void BHTTTActionsLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalTTActionsLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalTTActionsLayoutIMP)(self, _cmd);
    }
    if ([self isKindOfClass:[UIView class]]) BHTLayoutVideoDownloadButton((UIView *)self);
}

static void BHTT1ActionsLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalT1ActionsLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalT1ActionsLayoutIMP)(self, _cmd);
    }
    if ([self isKindOfClass:[UIView class]]) BHTLayoutVideoDownloadButton((UIView *)self);
}

static void BHTInstallLayoutOverrideForClass(Class cls, IMP replacement, IMP *originalOut) {
    if (!cls) return;
    SEL selector = @selector(layoutSubviews);
    Method inheritedMethod = class_getInstanceMethod(cls, selector);
    if (!inheritedMethod) return;

    *originalOut = method_getImplementation(inheritedMethod);
    const char *types = method_getTypeEncoding(inheritedMethod);

    if (class_addMethod(cls, selector, replacement, types)) return;

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
        *originalOut = method_getImplementation(ownMethod);
        method_setImplementation(ownMethod, replacement);
    }
}

static void BHTScanVisibleActionsViews(void) {
    Class tta = NSClassFromString(@"TTAStatusInlineActionsView");
    Class t1 = NSClassFromString(@"T1StatusInlineActionsView");

    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:window];
        while (stack.count) {
            UIView *view = stack.lastObject;
            [stack removeLastObject];
            if ((tta && [view isKindOfClass:tta]) || (t1 && [view isKindOfClass:t1])) {
                BHTLayoutVideoDownloadButton(view);
            }
            [stack addObjectsFromArray:view.subviews];
        }
    }
}

static void BHTInstallX1216VideoCompat(void) {
    BHTInstallLayoutOverrideForClass(NSClassFromString(@"TTAStatusInlineActionsView"),
                                     (IMP)BHTTTActionsLayoutSubviews,
                                     &BHTOriginalTTActionsLayoutIMP);
    BHTInstallLayoutOverrideForClass(NSClassFromString(@"T1StatusInlineActionsView"),
                                     (IMP)BHTT1ActionsLayoutSubviews,
                                     &BHTOriginalT1ActionsLayoutIMP);

    BHTScanVisibleActionsViews();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTScanVisibleActionsViews();
    });
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216VideoCompat();
    });
}
