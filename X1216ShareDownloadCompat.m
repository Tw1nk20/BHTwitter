#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHDownloadInlineButton.h"

static const void *BHTShareDownloadGestureKey = &BHTShareDownloadGestureKey;
static const void *BHTShareDownloadProxyKey = &BHTShareDownloadProxyKey;
static const void *BHTShareDownloaderKey = &BHTShareDownloaderKey;
static const void *BHTSharePendingModelKey = &BHTSharePendingModelKey;
static const void *BHTSharePausedRecognizersKey = &BHTSharePausedRecognizersKey;

static IMP BHTOriginalViewDidMoveToWindowIMP = NULL;
static IMP BHTOriginalT1ShareLayoutIMP = NULL;
static IMP BHTOriginalTTAShareLayoutIMP = NULL;
typedef void (*BHTViewVoidIMP)(id, SEL);

typedef void (*BHTShareLayoutIMP)(id, SEL);

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
                SEL videoInfoSEL = NSSelectorFromString(@"videoInfo");
                if ([media respondsToSelector:videoInfoSEL] && ((id (*)(id, SEL))objc_msgSend)(media, videoInfoSEL)) return YES;
            }
        }
    }

    SEL entitiesSEL = NSSelectorFromString(@"entities");
    if ([item respondsToSelector:entitiesSEL]) {
        id entities = ((id (*)(id, SEL))objc_msgSend)(item, entitiesSEL);
        SEL mediaSEL = NSSelectorFromString(@"media");
        if ([entities respondsToSelector:mediaSEL]) {
            id media = ((id (*)(id, SEL))objc_msgSend)(entities, mediaSEL);
            if ([media isKindOfClass:[NSArray class]]) {
                for (id entity in (NSArray *)media) {
                    SEL typeSEL = NSSelectorFromString(@"mediaType");
                    if ([entity respondsToSelector:typeSEL]) {
                        NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(entity, typeSEL);
                        if (type == 2 || type == 3) return YES;
                    }
                    SEL videoInfoSEL = NSSelectorFromString(@"videoInfo");
                    if ([entity respondsToSelector:videoInfoSEL] && ((id (*)(id, SEL))objc_msgSend)(entity, videoInfoSEL)) return YES;
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
    if (BHTShareItemIsVideo(object)) return object;
    return nil;
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
    UIView *view = shareView;
    UIView *fallback = nil;
    for (NSUInteger depth = 0; view && depth < 20; depth++, view = view.superview) {
        NSString *name = NSStringFromClass(view.class).lowercaseString ?: @"";
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

    while (stack.count && visited < 600) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;

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

    // First try the current inline-actions delegate. This is the exact post in
    // most X 12.16 feed/detail layouts.
    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareView respondsToSelector:delegateSEL]) {
        id delegate = ((id (*)(id, SEL))objc_msgSend)(shareView, delegateSEL);
        id model = BHTShareVideoModelFromObject(delegate);
        if (model) return model;
    }

    // Recycled feed cells can have a wrapper whose delegate path is stale or
    // temporarily empty after scrolling. Re-scan only the nearest current post
    // boundary; never search sibling posts, which caused false video matches.
    UIView *postRoot = BHTNearestPostBoundary(shareView);
    id model = BHTFindVideoModelInsidePost(postRoot);
    if (model) return model;

    // Final narrow ancestor fallback, still stopping at the current post.
    UIView *view = shareView;
    for (NSUInteger depth = 0; view && depth < 20; depth++, view = view.superview) {
        model = BHTShareVideoModelFromObject(view);
        if (model) return model;
        if (view != shareView && BHTLooksLikePostBoundary(view)) break;
    }
    return nil;
}

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

    // Include recognizers inside the visible share control; UIContextMenuInteraction
    // can install its private recognizer on an internal subview rather than the wrapper.
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
    // Let the BHT recognizer reach Began even if X has already attached a native
    // context-menu recognizer. At Began, BHT disables the competing recognizers.
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
        id viewModel = BHTShareViewModelForShareView(shareView);
        objc_setAssociatedObject(shareView, BHTSharePendingModelKey, viewModel ?: [NSNull null], OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        NSArray *paused = BHTPauseCompetingRecognizers(shareView, gesture);
        objc_setAssociatedObject(shareView, BHTSharePausedRecognizersKey, paused, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }

    if (gesture.state == UIGestureRecognizerStateEnded) {
        NSArray *paused = objc_getAssociatedObject(shareView, BHTSharePausedRecognizersKey) ?: @[];
        id pending = objc_getAssociatedObject(shareView, BHTSharePendingModelKey);
        objc_setAssociatedObject(shareView, BHTSharePausedRecognizersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(shareView, BHTSharePendingModelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        // Re-check the current post at release. This matters after cell reuse and
        // scrolling, where a model captured earlier can no longer describe the
        // visible post.
        id currentModel = BHTShareViewModelForShareView(shareView);
        id model = BHTShareItemIsVideo(currentModel) ? currentModel : (BHTShareItemIsVideo(pending) ? pending : nil);

        // Keep native recognizers disabled until the popup has been requested;
        // otherwise X can present its standard menu in the same run-loop turn.
        if (model) {
            [self bht_presentDownloadForShareView:shareView viewModel:model];
        } else {
            BHTShowNoVideoError();
        }

        dispatch_async(dispatch_get_main_queue(), ^{ BHTResumeRecognizers(paused); });
        return;
    }

    if (gesture.state == UIGestureRecognizerStateCancelled || gesture.state == UIGestureRecognizerStateFailed) {
        NSArray *paused = objc_getAssociatedObject(shareView, BHTSharePausedRecognizersKey) ?: @[];
        BHTResumeRecognizers(paused);
        objc_setAssociatedObject(shareView, BHTSharePausedRecognizersKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(shareView, BHTSharePendingModelKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
@end

static void BHTInstallLongPressIfNeeded(UIView *shareView) {
    if (!shareView || !shareView.window) return;
    if (!BHTLooksLikeShareControl(shareView)) {
        NSString *className = NSStringFromClass(shareView.class).lowercaseString ?: @"";
        if (![className containsString:@"statusinlinesharebutton"]) return;
    }
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

static void BHTViewDidMoveToWindow(id self, SEL _cmd) {
    if (BHTOriginalViewDidMoveToWindowIMP) ((BHTViewVoidIMP)BHTOriginalViewDidMoveToWindowIMP)(self, _cmd);
    if ([self isKindOfClass:[UIView class]]) BHTInstallLongPressIfNeeded((UIView *)self);
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
    Method inherited = class_getInstanceMethod(cls, selector);
    if (!inherited) return;
    const char *types = method_getTypeEncoding(inherited);
    IMP original = method_getImplementation(inherited);
    if (class_addMethod(cls, selector, replacement, types)) { *originalOut = original; return; }
    Method own = class_getInstanceMethod(cls, selector);
    if (!own) return;
    *originalOut = method_getImplementation(own);
    method_setImplementation(own, replacement);
}

__attribute__((constructor)) static void BHTX1216ShareDownloadCompatInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class viewClass = [UIView class];
        SEL selector = @selector(didMoveToWindow);
        Method method = class_getInstanceMethod(viewClass, selector);
        if (method) {
            BHTOriginalViewDidMoveToWindowIMP = method_getImplementation(method);
            method_setImplementation(method, (IMP)BHTViewDidMoveToWindow);
        }

        BHTInstallShareLayoutHook(NSClassFromString(@"T1StatusInlineShareButton"),
                                  (IMP)BHTT1ShareLayoutSubviews,
                                  &BHTOriginalT1ShareLayoutIMP);
        BHTInstallShareLayoutHook(NSClassFromString(@"TTAStatusInlineShareButton"),
                                  (IMP)BHTTTAShareLayoutSubviews,
                                  &BHTOriginalTTAShareLayoutIMP);

        NSLog(@"[BHTwitter][X12.16] Installed high-priority post-scoped share download hook");
    });
}
