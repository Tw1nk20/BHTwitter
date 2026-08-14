#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHDownloadInlineButton.h"

static const void *BHTShareDownloadGestureKey = &BHTShareDownloadGestureKey;
static const void *BHTShareDownloadProxyKey = &BHTShareDownloadProxyKey;
static const void *BHTShareDownloaderKey = &BHTShareDownloaderKey;
static const void *BHTSharePausedRecognizersKey = &BHTSharePausedRecognizersKey;

static IMP BHTOriginalViewDidMoveToWindowIMP = NULL;
static IMP BHTOriginalT1ShareLayoutIMP = NULL;
static IMP BHTOriginalTTAShareLayoutIMP = NULL;
typedef void (*BHTViewVoidIMP)(id, SEL);
typedef void (*BHTShareLayoutIMP)(id, SEL);

#pragma mark - Media detection

static BOOL BHTShareItemIsVideo(id item) {
    if (!item || item == [NSNull null]) return NO;

    SEL videoSEL = NSSelectorFromString(@"isMediaEntityVideo");
    if ([item respondsToSelector:videoSEL] && ((BOOL (*)(id, SEL))objc_msgSend)(item, videoSEL)) return YES;

    SEL gifSEL = NSSelectorFromString(@"isGIF");
    if ([item respondsToSelector:gifSEL] && ((BOOL (*)(id, SEL))objc_msgSend)(item, gifSEL)) return YES;

    SEL representedSEL = NSSelectorFromString(@"representedMediaEntities");
    if ([item respondsToSelector:representedSEL]) {
        id entities = ((id (*)(id, SEL))objc_msgSend)(item, representedSEL);
        if ([entities isKindOfClass:[NSArray class]]) {
            for (id media in (NSArray *)entities) {
                SEL typeSEL = NSSelectorFromString(@"mediaType");
                if ([media respondsToSelector:typeSEL]) {
                    NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(media, typeSEL);
                    if (type == 2 || type == 3) return YES;
                }
                SEL infoSEL = NSSelectorFromString(@"videoInfo");
                if ([media respondsToSelector:infoSEL] && ((id (*)(id, SEL))objc_msgSend)(media, infoSEL)) return YES;
            }
        }
    }

    SEL entitiesSEL = NSSelectorFromString(@"entities");
    if ([item respondsToSelector:entitiesSEL]) {
        id entities = ((id (*)(id, SEL))objc_msgSend)(item, entitiesSEL);
        SEL mediaSEL = NSSelectorFromString(@"media");
        if ([entities respondsToSelector:mediaSEL]) {
            id mediaArray = ((id (*)(id, SEL))objc_msgSend)(entities, mediaSEL);
            if ([mediaArray isKindOfClass:[NSArray class]]) {
                for (id media in (NSArray *)mediaArray) {
                    SEL typeSEL = NSSelectorFromString(@"mediaType");
                    if ([media respondsToSelector:typeSEL]) {
                        NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(media, typeSEL);
                        if (type == 2 || type == 3) return YES;
                    }
                    SEL infoSEL = NSSelectorFromString(@"videoInfo");
                    if ([media respondsToSelector:infoSEL] && ((id (*)(id, SEL))objc_msgSend)(media, infoSEL)) return YES;
                }
            }
        }
    }

    SEL tweetSEL = NSSelectorFromString(@"tweet");
    if ([item respondsToSelector:tweetSEL]) {
        id tweet = ((id (*)(id, SEL))objc_msgSend)(item, tweetSEL);
        if (tweet && tweet != item && BHTShareItemIsVideo(tweet)) return YES;
    }

    return NO;
}

static id BHTShareVideoModelFromObject(id object) {
    if (!object) return nil;
    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if ([object respondsToSelector:viewModelSEL]) {
        id model = ((id (*)(id, SEL))objc_msgSend)(object, viewModelSEL);
        if (model && BHTShareItemIsVideo(model)) return model;
    }
    return BHTShareItemIsVideo(object) ? object : nil;
}

static BOOL BHTLooksLikeShareControl(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha < 0.05) return NO;
    NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
    NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
    return [className containsString:@"sharebutton"] ||
           [className containsString:@"share_button"] ||
           [identifier containsString:@"share"] ||
           [identifier containsString:@"共有"] ||
           [label isEqualToString:@"share"] ||
           [label containsString:@"share post"] ||
           [label containsString:@"share tweet"] ||
           [label containsString:@"共有"] ||
           [label containsString:@"シェア"];
}

static BOOL BHTLooksLikePostBoundary(UIView *view) {
    NSString *name = NSStringFromClass(view.class).lowercaseString ?: @"";
    return [name containsString:@"statuscell"] ||
           [name containsString:@"tweetcell"] ||
           [name containsString:@"focalstatusview"] ||
           [name containsString:@"standardstatusview"] ||
           [name containsString:@"tweetdetailsfocalstatusview"] ||
           [name containsString:@"conversationfocalstatusview"];
}

static UIView *BHTNearestPostBoundary(UIView *shareView) {
    UIView *fallback = nil;
    for (UIView *view = shareView; view; view = view.superview) {
        if ([view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) return view;
        if (BHTLooksLikePostBoundary(view)) return view;
        if (!fallback && CGRectGetWidth(view.bounds) >= 280.0 && CGRectGetHeight(view.bounds) >= 100.0) fallback = view;
    }
    return fallback;
}

static id BHTFindVideoModelInsidePost(UIView *postRoot) {
    if (!postRoot) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:postRoot];
    NSUInteger visited = 0;
    while (stack.count && visited++ < 600) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        id model = BHTShareVideoModelFromObject(view);
        if (model) return model;

        SEL delegateSEL = NSSelectorFromString(@"delegate");
        if ([view respondsToSelector:delegateSEL]) {
            id delegate = ((id (*)(id, SEL))objc_msgSend)(view, delegateSEL);
            model = BHTShareVideoModelFromObject(delegate);
            if (model) return model;
        }

        for (UIView *subview in view.subviews) {
            if (subview != postRoot && BHTLooksLikePostBoundary(subview)) continue;
            [stack addObject:subview];
        }
    }
    return nil;
}

static id BHTShareViewModelForShareView(UIView *shareView) {
    if (!shareView) return nil;

    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareView respondsToSelector:delegateSEL]) {
        id delegate = ((id (*)(id, SEL))objc_msgSend)(shareView, delegateSEL);
        id model = BHTShareVideoModelFromObject(delegate);
        if (model) return model;
    }

    UIView *postRoot = BHTNearestPostBoundary(shareView);
    id model = BHTFindVideoModelInsidePost(postRoot);
    if (model) return model;

    for (UIView *view = shareView; view; view = view.superview) {
        model = BHTShareVideoModelFromObject(view);
        if (model) return model;
        if (view != shareView && (BHTLooksLikePostBoundary(view) ||
                                  [view isKindOfClass:[UITableViewCell class]] ||
                                  [view isKindOfClass:[UICollectionViewCell class]])) break;
    }
    return nil;
}

#pragma mark - UI helpers

static UIViewController *BHTTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) { window = candidate; break; }
        }
        if (window) break;
    }
    if (!window) window = UIApplication.sharedApplication.keyWindow;

    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController) { controller = controller.presentedViewController; continue; }
        if ([controller isKindOfClass:[UINavigationController class]]) { controller = ((UINavigationController *)controller).visibleViewController; continue; }
        if ([controller isKindOfClass:[UITabBarController class]]) { controller = ((UITabBarController *)controller).selectedViewController; continue; }
        break;
    }
    return controller;
}

static void BHTImpactTap(void) {
    UIImpactFeedbackGenerator *generator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [generator prepare];
    [generator impactOccurred];
}

static void BHTShowNoVideoError(void) {
    UIViewController *controller = BHTTopViewController();
    if (!controller || controller.presentedViewController) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:nil
                                                                   message:@"This post does not contain a video"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

static void BHTCollectRecognizersInViewTree(UIView *root,
                                            UIGestureRecognizer *except,
                                            NSMutableArray<UIGestureRecognizer *> *out) {
    if (!root) return;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers.copy) {
            if (recognizer != except && recognizer.enabled && ![out containsObject:recognizer]) [out addObject:recognizer];
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }
}

static NSArray<UIGestureRecognizer *> *BHTPauseCompetingRecognizers(UIView *shareView,
                                                                    UIGestureRecognizer *bhtGesture) {
    if (!shareView) return @[];
    NSMutableArray<UIGestureRecognizer *> *paused = [NSMutableArray array];
    BHTCollectRecognizersInViewTree(shareView, bhtGesture, paused);

    UIView *view = shareView.superview;
    for (NSUInteger depth = 0; view && depth < 20; depth++, view = view.superview) {
        for (UIGestureRecognizer *recognizer in view.gestureRecognizers.copy) {
            if (recognizer != bhtGesture && recognizer.enabled && ![paused containsObject:recognizer]) [paused addObject:recognizer];
        }
        if (BHTLooksLikePostBoundary(view) || [view isKindOfClass:[UITableViewCell class]] || [view isKindOfClass:[UICollectionViewCell class]]) break;
    }

    for (UIGestureRecognizer *recognizer in paused) recognizer.enabled = NO;
    return paused;
}

static void BHTResumeRecognizers(NSArray<UIGestureRecognizer *> *recognizers) {
    for (UIGestureRecognizer *recognizer in recognizers) recognizer.enabled = YES;
}

#pragma mark - Long press target

@interface BHTShareDownloadProxy : NSObject
@property (nonatomic, strong) id viewModel;
@property (nonatomic, weak) id delegate;
@end
@implementation BHTShareDownloadProxy
@end

@interface BHTShareDownloadTarget : NSObject <UIGestureRecognizerDelegate>
@end
@implementation BHTShareDownloadTarget

+ (instancetype)sharedTarget {
    static BHTShareDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTShareDownloadTarget new]; });
    return target;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer
        shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // Let BHTwitter reach Began even when X has already installed its own context-menu recognizer.
    // The native recognizer is disabled immediately afterwards.
    return YES;
}

- (void)bht_presentDownloadForShareView:(UIView *)shareView viewModel:(id)viewModel {
    if (!shareView || !viewModel || !BHTShareItemIsVideo(viewModel)) return;

    BHTShareDownloadProxy *proxy = [BHTShareDownloadProxy new];
    proxy.viewModel = viewModel;
    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareView respondsToSelector:delegateSEL]) proxy.delegate = ((id (*)(id, SEL))objc_msgSend)(shareView, delegateSEL);

    BHDownloadInlineButton *downloader = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloader.delegate = (id)proxy;
    downloader.viewModel = viewModel;
    objc_setAssociatedObject(shareView, BHTShareDownloadProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(shareView, BHTShareDownloaderKey, downloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *sender = [shareView isKindOfClass:[UIButton class]] ? (UIButton *)shareView : [UIButton buttonWithType:UIButtonTypeSystem];
    [downloader DownloadHandler:sender];
}

- (void)bht_shareLongPressed:(UILongPressGestureRecognizer *)gesture {
    UIView *shareView = gesture.view;
    if (!shareView || !shareView.window) return;

    if (gesture.state == UIGestureRecognizerStateBegan) {
        // Long press has just become valid: provide the requested short tactile "tap" now.
        BHTImpactTap();

        // Freeze X's native share/context-menu recognizers before they can present their sheet.
        NSArray *paused = BHTPauseCompetingRecognizers(shareView, gesture);
        objc_setAssociatedObject(shareView, BHTSharePausedRecognizersKey, paused, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Re-resolve the current model at the exact moment the gesture fires. This is important
        // for recycled feed cells after scrolling.
        id viewModel = BHTShareViewModelForShareView(shareView);
        if (viewModel && BHTShareItemIsVideo(viewModel)) {
            [self bht_presentDownloadForShareView:shareView viewModel:viewModel];
        } else {
            BHTShowNoVideoError();
        }
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        NSArray *paused = objc_getAssociatedObject(shareView, BHTSharePausedRecognizersKey) ?: @[];
        objc_setAssociatedObject(shareView, BHTSharePausedRecognizersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        dispatch_async(dispatch_get_main_queue(), ^{ BHTResumeRecognizers(paused); });
    }
}
@end

#pragma mark - Installation

static void BHTInstallLongPressIfNeeded(UIView *shareView) {
    if (!shareView || !shareView.window) return;

    NSString *className = NSStringFromClass(shareView.class).lowercaseString ?: @"";
    BOOL knownShareClass = [className containsString:@"t1statusinlinesharebutton"] ||
                           [className containsString:@"ttastatusinlinesharebutton"];
    if (!knownShareClass && !BHTLooksLikeShareControl(shareView)) return;
    if (objc_getAssociatedObject(shareView, BHTShareDownloadGestureKey)) return;

    UILongPressGestureRecognizer *gesture = [[UILongPressGestureRecognizer alloc] initWithTarget:[BHTShareDownloadTarget sharedTarget]
                                                                                         action:@selector(bht_shareLongPressed:)];
    gesture.minimumPressDuration = 0.25;
    gesture.cancelsTouchesInView = YES;
    gesture.delaysTouchesBegan = YES;
    gesture.delegate = [BHTShareDownloadTarget sharedTarget];
    [shareView addGestureRecognizer:gesture];
    shareView.userInteractionEnabled = YES;
    objc_setAssociatedObject(shareView, BHTShareDownloadGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void BHTT1ShareLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalT1ShareLayoutIMP) ((BHTShareLayoutIMP)BHTOriginalT1ShareLayoutIMP)(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) BHTInstallLongPressIfNeeded((UIView *)self);
}

static void BHTTTAShareLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalTTAShareLayoutIMP) ((BHTShareLayoutIMP)BHTOriginalTTAShareLayoutIMP)(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) BHTInstallLongPressIfNeeded((UIView *)self);
}

static void BHTInstallShareLayoutHook(Class cls, IMP replacement, IMP *originalOut) {
    if (!cls || !originalOut) return;
    SEL selector = @selector(layoutSubviews);
    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;
    const char *types = method_getTypeEncoding(method);
    IMP original = method_getImplementation(method);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) { own = methods[i]; break; }
    }
    free(methods);

    if (own) {
        *originalOut = method_getImplementation(own);
        method_setImplementation(own, replacement);
    } else {
        *originalOut = original;
        class_addMethod(cls, selector, replacement, types);
    }
}

static void BHTViewDidMoveToWindow(id self, SEL _cmd) {
    if (BHTOriginalViewDidMoveToWindowIMP) ((BHTViewVoidIMP)BHTOriginalViewDidMoveToWindowIMP)(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) BHTInstallLongPressIfNeeded((UIView *)self);
}

__attribute__((constructor)) static void BHTX1216ShareDownloadCompatInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BHTInstallShareLayoutHook(NSClassFromString(@"T1StatusInlineShareButton"),
                                  (IMP)BHTT1ShareLayoutSubviews,
                                  &BHTOriginalT1ShareLayoutIMP);
        BHTInstallShareLayoutHook(NSClassFromString(@"TTAStatusInlineShareButton"),
                                  (IMP)BHTTTAShareLayoutSubviews,
                                  &BHTOriginalTTAShareLayoutIMP);

        Class viewClass = [UIView class];
        SEL selector = @selector(didMoveToWindow);
        Method method = class_getInstanceMethod(viewClass, selector);
        if (method) {
            BHTOriginalViewDidMoveToWindowIMP = method_getImplementation(method);
            method_setImplementation(method, (IMP)BHTViewDidMoveToWindow);
        }
        NSLog(@"[BHTwitter][X12.16] Installed immediate share long-press download with haptics");
    });
}
