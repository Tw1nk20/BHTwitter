#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHDownloadInlineButton.h"

static const void *BHTShareDownloadGestureKey = &BHTShareDownloadGestureKey;
static const void *BHTShareDownloadProxyKey = &BHTShareDownloadProxyKey;
static const void *BHTShareDownloaderKey = &BHTShareDownloaderKey;

static IMP BHTOriginalViewDidMoveToWindowIMP = NULL;
typedef void (*BHTViewVoidIMP)(id, SEL);

static BOOL BHTShareItemIsVideo(id item) {
    if (!item) return NO;

    SEL videoSEL = NSSelectorFromString(@"isMediaEntityVideo");
    if ([item respondsToSelector:videoSEL] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(item, videoSEL)) return YES;

    SEL gifSEL = NSSelectorFromString(@"isGIF");
    if ([item respondsToSelector:gifSEL] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(item, gifSEL)) return YES;

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
                if ([media respondsToSelector:videoInfoSEL] &&
                    ((id (*)(id, SEL))objc_msgSend)(media, videoInfoSEL)) return YES;
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
                }
            }
        }
    }

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if ([item respondsToSelector:viewModelSEL]) {
        id model = ((id (*)(id, SEL))objc_msgSend)(item, viewModelSEL);
        if (model && model != item && BHTShareItemIsVideo(model)) return YES;
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
        if (BHTShareItemIsVideo(model)) return model;
    }

    if (BHTShareItemIsVideo(object)) return object;
    return nil;
}

static BOOL BHTLooksLikeShareControl(UIView *view) {
    if (!view || !view.window || view.hidden || view.alpha < 0.05) return NO;

    NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
    NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
    NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";

    if ([className containsString:@"sharebutton"] ||
        [className containsString:@"share_button"] ||
        [identifier containsString:@"share"] ||
        [identifier containsString:@"共有"]) return YES;

    if ([label isEqualToString:@"share"] ||
        [label containsString:@"share post"] ||
        [label containsString:@"share tweet"] ||
        [label containsString:@"共有"] ||
        [label containsString:@"シェア"]) return YES;

    return NO;
}

static id BHTFindVideoModelInViewTree(UIView *root) {
    if (!root) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    NSUInteger visited = 0;
    while (stack.count && visited < 500) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        visited++;

        id model = BHTShareVideoModelFromObject(view);
        if (model) return model;

        UIResponder *responder = view.nextResponder;
        if (responder) {
            model = BHTShareVideoModelFromObject(responder);
            if (model) return model;
        }

        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
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

    UIResponder *responder = shareView;
    while (responder) {
        id model = BHTShareVideoModelFromObject(responder);
        if (model) return model;
        responder = responder.nextResponder;
    }

    UIView *ancestor = shareView;
    for (NSUInteger depth = 0; ancestor && depth < 12; depth++, ancestor = ancestor.superview) {
        id model = BHTShareVideoModelFromObject(ancestor);
        if (model) return model;

        if (CGRectGetWidth(ancestor.bounds) >= 250.0 && CGRectGetHeight(ancestor.bounds) >= 100.0) {
            model = BHTFindVideoModelInViewTree(ancestor);
            if (model) return model;
        }
    }

    return nil;
}

static UIViewController *BHTTopViewController(void) {
    UIWindow *window = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (scene.activationState != UISceneActivationStateForegroundActive ||
            ![scene isKindOfClass:[UIWindowScene class]]) continue;

        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.isKeyWindow) {
                window = candidate;
                break;
            }
        }
        if (window) break;
    }

    if (!window) window = UIApplication.sharedApplication.keyWindow;
    UIViewController *controller = window.rootViewController;
    while (controller) {
        if (controller.presentedViewController) {
            controller = controller.presentedViewController;
            continue;
        }
        if ([controller isKindOfClass:[UINavigationController class]]) {
            controller = ((UINavigationController *)controller).visibleViewController;
            continue;
        }
        if ([controller isKindOfClass:[UITabBarController class]]) {
            controller = ((UITabBarController *)controller).selectedViewController;
            continue;
        }
        break;
    }
    return controller;
}

static void BHTShowNoVideoError(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *controller = BHTTopViewController();
        if (!controller) return;

        UIAlertController *alert =
            [UIAlertController alertControllerWithTitle:nil
                                                message:@"This post does not contain a video"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK"
                                                  style:UIAlertActionStyleDefault
                                                handler:nil]];
        [controller presentViewController:alert animated:YES completion:nil];
    });
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
    return YES;
}

- (void)bht_shareLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;

    UIView *shareView = gesture.view;
    if (!shareView || !shareView.window) return;

    id viewModel = BHTShareViewModelForShareView(shareView);
    if (!viewModel) {
        NSLog(@"[BHTwitter][X12.16] Share long press: video model not found (%@ / %@)",
              NSStringFromClass(shareView.class), shareView.accessibilityLabel);

        for (UIGestureRecognizer *other in shareView.gestureRecognizers.copy) {
            if (other != gesture) other.enabled = NO;
        }

        BHTShowNoVideoError();

        dispatch_async(dispatch_get_main_queue(), ^{
            for (UIGestureRecognizer *other in shareView.gestureRecognizers.copy) {
                if (other != gesture) other.enabled = YES;
            }
        });
        return;
    }

    for (UIGestureRecognizer *other in shareView.gestureRecognizers.copy) {
        if (other != gesture) other.enabled = NO;
    }

    BHTShareDownloadProxy *proxy = [BHTShareDownloadProxy new];
    proxy.viewModel = viewModel;

    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareView respondsToSelector:delegateSEL]) {
        proxy.delegate = ((id (*)(id, SEL))objc_msgSend)(shareView, delegateSEL);
    }

    BHDownloadInlineButton *downloader = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloader.delegate = (id)proxy;
    downloader.viewModel = viewModel;

    objc_setAssociatedObject(shareView, BHTShareDownloadProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(shareView, BHTShareDownloaderKey, downloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    UIButton *sender = [shareView isKindOfClass:[UIButton class]]
        ? (UIButton *)shareView
        : [UIButton buttonWithType:UIButtonTypeSystem];

    [downloader DownloadHandler:sender];

    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIGestureRecognizer *other in shareView.gestureRecognizers.copy) {
            if (other != gesture) other.enabled = YES;
        }
    });
}

@end

static void BHTInstallLongPressIfNeeded(UIView *shareView) {
    if (!BHTLooksLikeShareControl(shareView)) return;
    if (objc_getAssociatedObject(shareView, BHTShareDownloadGestureKey)) return;

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[BHTShareDownloadTarget sharedTarget]
                                                     action:@selector(bht_shareLongPressed:)];
    gesture.minimumPressDuration = 0.30;
    gesture.cancelsTouchesInView = YES;
    gesture.delaysTouchesBegan = YES;
    gesture.delegate = [BHTShareDownloadTarget sharedTarget];
    [shareView addGestureRecognizer:gesture];
    shareView.userInteractionEnabled = YES;

    objc_setAssociatedObject(shareView, BHTShareDownloadGestureKey, gesture, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSLog(@"[BHTwitter][X12.16] Attached share download gesture to %@ (%@)",
          NSStringFromClass(shareView.class), shareView.accessibilityLabel);
}

static void BHTViewDidMoveToWindow(id self, SEL _cmd) {
    if (BHTOriginalViewDidMoveToWindowIMP) {
        ((BHTViewVoidIMP)BHTOriginalViewDidMoveToWindowIMP)(self, _cmd);
    }

    if ([self isKindOfClass:[UIView class]]) {
        BHTInstallLongPressIfNeeded((UIView *)self);
    }
}

__attribute__((constructor)) static void BHTX1216ShareDownloadCompatInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        Class viewClass = [UIView class];
        SEL selector = @selector(didMoveToWindow);
        Method method = class_getInstanceMethod(viewClass, selector);
        if (!method) return;

        BHTOriginalViewDidMoveToWindowIMP = method_getImplementation(method);
        method_setImplementation(method, (IMP)BHTViewDidMoveToWindow);
        NSLog(@"[BHTwitter][X12.16] Installed accessibility-based share long-press download hook");
    });
}
