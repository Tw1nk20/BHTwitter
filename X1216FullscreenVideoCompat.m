#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHDownloadInlineButton.h"

// Full-screen media uses a different hierarchy from timeline/detail cells.
// Keep the existing cell implementation untouched and only handle video views
// that are NOT descendants of UITableViewCell.
static const NSInteger BHTFullscreenDownloadButtonTag = 1216099;
static const void *BHTFullscreenVideoModelKey = &BHTFullscreenVideoModelKey;
static const void *BHTFullscreenDownloaderKey = &BHTFullscreenDownloaderKey;
static const void *BHTFullscreenProxyKey = &BHTFullscreenProxyKey;

static IMP BHTOriginalWindowLayoutIMP = NULL;
static IMP BHTOriginalScrollLayoutIMP = NULL;
typedef void (*BHTVoidIMP)(id, SEL);

static CFTimeInterval BHTLastFullscreenScan = 0.0;

static BOOL BHTFullscreenRuntimeItemIsVideo(id item) {
    if (!item) return NO;

    SEL videoSEL = NSSelectorFromString(@"isMediaEntityVideo");
    if ([item respondsToSelector:videoSEL] && ((BOOL (*)(id, SEL))objc_msgSend)(item, videoSEL)) return YES;

    SEL gifSEL = NSSelectorFromString(@"isGIF");
    if ([item respondsToSelector:gifSEL] && ((BOOL (*)(id, SEL))objc_msgSend)(item, gifSEL)) return YES;

    SEL representedSEL = NSSelectorFromString(@"representedMediaEntities");
    if ([item respondsToSelector:representedSEL]) {
        id entities = ((id (*)(id, SEL))objc_msgSend)(item, representedSEL);
        if ([entities isKindOfClass:[NSArray class]]) {
            for (id media in (NSArray *)entities) {
                SEL videoInfoSEL = NSSelectorFromString(@"videoInfo");
                if ([media respondsToSelector:videoInfoSEL] && ((id (*)(id, SEL))objc_msgSend)(media, videoInfoSEL)) return YES;

                SEL mediaTypeSEL = NSSelectorFromString(@"mediaType");
                if ([media respondsToSelector:mediaTypeSEL]) {
                    NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(media, mediaTypeSEL);
                    if (type == 2 || type == 3) return YES;
                }
            }
        }
    }

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if ([item respondsToSelector:viewModelSEL]) {
        id model = ((id (*)(id, SEL))objc_msgSend)(item, viewModelSEL);
        if (model && model != item && BHTFullscreenRuntimeItemIsVideo(model)) return YES;
    }

    SEL tweetSEL = NSSelectorFromString(@"tweet");
    if ([item respondsToSelector:tweetSEL]) {
        id tweet = ((id (*)(id, SEL))objc_msgSend)(item, tweetSEL);
        if (tweet && tweet != item && BHTFullscreenRuntimeItemIsVideo(tweet)) return YES;
    }

    return NO;
}

static BOOL BHTViewIsInsideTableCell(UIView *view) {
    UIResponder *node = view;
    while (node) {
        if ([node isKindOfClass:[UITableViewCell class]]) return YES;
        node = node.nextResponder;
    }
    return NO;
}

static BOOL BHTViewLooksLikeVideo(UIView *view) {
    if (!view) return NO;

    NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
    if ([className containsString:@"video"] ||
        [className containsString:@"player"] ||
        [className containsString:@"media"] ||
        [className containsString:@"slideshow"]) return YES;

    NSMutableArray<CALayer *> *layers = [NSMutableArray arrayWithObject:view.layer];
    while (layers.count) {
        CALayer *layer = layers.lastObject;
        [layers removeLastObject];
        NSString *name = NSStringFromClass(layer.class).lowercaseString ?: @"";
        if ([name containsString:@"player"] || [name containsString:@"video"]) return YES;
        if (layer.sublayers.count) [layers addObjectsFromArray:layer.sublayers];
    }
    return NO;
}

static id BHTVideoModelFromResponderChain(UIView *view) {
    UIResponder *node = view;
    while (node) {
        SEL viewModelSEL = NSSelectorFromString(@"viewModel");
        if ([node respondsToSelector:viewModelSEL]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(node, viewModelSEL);
            if (BHTFullscreenRuntimeItemIsVideo(model)) return model;
        }

        SEL representedSEL = NSSelectorFromString(@"representedMediaEntities");
        if ([node respondsToSelector:representedSEL] && BHTFullscreenRuntimeItemIsVideo(node)) return node;

        node = node.nextResponder;
    }
    return nil;
}

static UIView *BHTFindFullscreenVideoHost(UIView *root, id *modelOut) {
    if (!root || !root.window) return nil;

    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth < 200.0 || rootHeight < 300.0) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    id bestModel = nil;
    CGFloat bestScore = -CGFLOAT_MAX;

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != root &&
            view.tag != BHTFullscreenDownloadButtonTag &&
            !view.hidden && view.alpha > 0.05 && view.window &&
            !BHTViewIsInsideTableCell(view)) {

            CGRect frame = [view convertRect:view.bounds toView:root];
            CGFloat width = CGRectGetWidth(frame);
            CGFloat height = CGRectGetHeight(frame);
            CGFloat area = width * height;

            BOOL large = width >= rootWidth * 0.72 && height >= 180.0;
            BOOL visible = CGRectIntersectsRect(root.bounds, frame);
            BOOL sensible = height <= rootHeight * 0.92 && width <= rootWidth * 1.05;

            if (large && visible && sensible && BHTViewLooksLikeVideo(view)) {
                id model = BHTVideoModelFromResponderChain(view);
                CGFloat score = area;
                if (model) score += rootWidth * rootHeight;

                if (score > bestScore) {
                    bestScore = score;
                    best = view;
                    bestModel = model;
                }
            }
        }

        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }

    if (modelOut) *modelOut = bestModel;
    return best;
}

@interface BHTFullscreenDownloadProxy : NSObject
@property (nonatomic, strong) id viewModel;
@property (nonatomic, weak) id delegate;
@end
@implementation BHTFullscreenDownloadProxy
@end

@interface BHTFullscreenDownloadTarget : NSObject
@end

@implementation BHTFullscreenDownloadTarget
+ (instancetype)sharedTarget {
    static BHTFullscreenDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTFullscreenDownloadTarget new]; });
    return target;
}

- (void)bht_fullscreenDownloadTapped:(UIButton *)sender {
    id model = objc_getAssociatedObject(sender, BHTFullscreenVideoModelKey);
    if (!model) model = BHTVideoModelFromResponderChain(sender.superview);
    if (!model) return;

    BHTFullscreenDownloadProxy *proxy = [BHTFullscreenDownloadProxy new];
    proxy.viewModel = model;

    BHDownloadInlineButton *downloader = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloader.delegate = (id)proxy;
    downloader.viewModel = model;

    objc_setAssociatedObject(sender, BHTFullscreenProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sender, BHTFullscreenDownloaderKey, downloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [downloader DownloadHandler:sender];
}
@end

static UIButton *BHTEnsureFullscreenDownloadButton(UIView *host) {
    UIButton *button = (UIButton *)[host viewWithTag:BHTFullscreenDownloadButtonTag];
    if (button) return button;

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTFullscreenDownloadButtonTag;
    button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    button.tintColor = UIColor.whiteColor;
    button.layer.cornerRadius = 20.0;
    button.layer.masksToBounds = YES;
    button.accessibilityLabel = @"動画をダウンロード";

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                                                         weight:UIImageSymbolWeightSemibold
                                                                                          scale:UIImageSymbolScaleMedium];
    UIImage *image = [UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:config];
    if (!image) image = [UIImage systemImageNamed:@"arrow.down" withConfiguration:config];
    [button setImage:image forState:UIControlStateNormal];
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;

    [button addTarget:[BHTFullscreenDownloadTarget sharedTarget]
               action:@selector(bht_fullscreenDownloadTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    [host addSubview:button];
    return button;
}

static void BHTRemoveStaleFullscreenButtons(UIView *root, UIView *currentHost) {
    if (!root) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view.tag == BHTFullscreenDownloadButtonTag &&
            view.superview != currentHost &&
            !BHTViewIsInsideTableCell(view)) {
            [view removeFromSuperview];
            continue;
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }
}

static UIViewController *BHTTopController(UIViewController *controller) {
    if (!controller) return nil;
    if (controller.presentedViewController) return BHTTopController(controller.presentedViewController);
    if ([controller isKindOfClass:[UINavigationController class]]) return BHTTopController(((UINavigationController *)controller).visibleViewController);
    if ([controller isKindOfClass:[UITabBarController class]]) return BHTTopController(((UITabBarController *)controller).selectedViewController);
    return controller;
}

static void BHTRefreshFullscreenDownloadButton(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    if (!window) return;

    UIViewController *top = BHTTopController(window.rootViewController);
    UIView *root = top.view ?: window;
    if (!root.window) return;

    id model = nil;
    UIView *host = BHTFindFullscreenVideoHost(root, &model);
    BHTRemoveStaleFullscreenButtons(root, host);
    if (!host) return;

    UIButton *button = BHTEnsureFullscreenDownloadButton(host);
    if (!button) return;
    if (model) objc_setAssociatedObject(button, BHTFullscreenVideoModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    const CGFloat size = 40.0;
    const CGFloat inset = 10.0;
    button.frame = CGRectIntegral(CGRectMake(inset, inset, size, size));
    button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [host bringSubviewToFront:button];
}

static void BHTScheduleFullscreenRefresh(void) {
    CFTimeInterval now = CACurrentMediaTime();
    if (now - BHTLastFullscreenScan < 0.08) return;
    BHTLastFullscreenScan = now;
    dispatch_async(dispatch_get_main_queue(), ^{ BHTRefreshFullscreenDownloadButton(); });
}

static void BHTWindowLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalWindowLayoutIMP) ((BHTVoidIMP)BHTOriginalWindowLayoutIMP)(self, _cmd);
    BHTScheduleFullscreenRefresh();
}

static void BHTScrollLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalScrollLayoutIMP) ((BHTVoidIMP)BHTOriginalScrollLayoutIMP)(self, _cmd);
    BHTScheduleFullscreenRefresh();
}

static void BHTInstallLayoutHook(Class cls, IMP replacement, IMP *originalOut) {
    if (!cls || !originalOut) return;
    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    *originalOut = method_getImplementation(method);
    method_setImplementation(method, replacement);
}

__attribute__((constructor)) static void BHTX1216FullscreenVideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallLayoutHook([UIWindow class], (IMP)BHTWindowLayoutSubviews, &BHTOriginalWindowLayoutIMP);
        BHTInstallLayoutHook([UIScrollView class], (IMP)BHTScrollLayoutSubviews, &BHTOriginalScrollLayoutIMP);
        BHTRefreshFullscreenDownloadButton();
        NSLog(@"[BHTwitter][X12.16] Installed fullscreen video download persistence fix");
    });
}
