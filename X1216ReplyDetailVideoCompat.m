#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHDownloadInlineButton.h"

static const NSInteger BHTDetailVideoDownloadButtonTag = 1216199;
static const void *BHTDetailVideoModelKey = &BHTDetailVideoModelKey;
static const void *BHTDetailDownloaderKey = &BHTDetailDownloaderKey;
static const void *BHTDetailProxyKey = &BHTDetailProxyKey;

static IMP BHTOriginalTweetDetailLayoutIMP = NULL;
static IMP BHTOriginalConversationDetailLayoutIMP = NULL;
typedef void (*BHTDetailLayoutIMP)(id, SEL);

static BOOL BHTDetailItemIsVideo(id item) {
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
                SEL mediaTypeSEL = NSSelectorFromString(@"mediaType");
                if ([media respondsToSelector:mediaTypeSEL]) {
                    NSInteger type = ((NSInteger (*)(id, SEL))objc_msgSend)(media, mediaTypeSEL);
                    if (type == 2 || type == 3) return YES;
                }

                SEL videoInfoSEL = NSSelectorFromString(@"videoInfo");
                if ([media respondsToSelector:videoInfoSEL] && ((id (*)(id, SEL))objc_msgSend)(media, videoInfoSEL)) return YES;
            }
        }
    }

    SEL tweetSEL = NSSelectorFromString(@"tweet");
    if ([item respondsToSelector:tweetSEL]) {
        id tweet = ((id (*)(id, SEL))objc_msgSend)(item, tweetSEL);
        if (tweet && tweet != item && BHTDetailItemIsVideo(tweet)) return YES;
    }

    return NO;
}

static id BHTDetailFindVideoModel(UIView *root) {
    if (!root) return nil;

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    UIResponder *responder = root;
    while (responder) {
        if ([responder respondsToSelector:viewModelSEL]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(responder, viewModelSEL);
            if (BHTDetailItemIsVideo(model)) return model;
        }
        responder = responder.nextResponder;
    }

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if ([view respondsToSelector:viewModelSEL]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(view, viewModelSEL);
            if (BHTDetailItemIsVideo(model)) return model;
        }

        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }

    return nil;
}

static BOOL BHTDetailViewLooksLikeMedia(UIView *view) {
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

static UIView *BHTDetailFindMainMediaView(UIView *root) {
    if (!root) return nil;

    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth <= 0.0 || rootHeight <= 0.0) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != root &&
            view.tag != BHTDetailVideoDownloadButtonTag &&
            !view.hidden && view.alpha > 0.05 && view.superview) {

            CGRect frame = [view convertRect:view.bounds toView:root];
            CGFloat w = CGRectGetWidth(frame);
            CGFloat h = CGRectGetHeight(frame);
            CGFloat area = w * h;

            BOOL largeEnough = w >= rootWidth * 0.55 && h >= 120.0;
            BOOL visible = CGRectIntersectsRect(root.bounds, frame);
            BOOL sensible = h <= rootHeight * 0.92;

            if (largeEnough && visible && sensible) {
                CGFloat score = area;
                if (BHTDetailViewLooksLikeMedia(view)) score += rootWidth * rootHeight * 1.5;

                NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
                if ([className containsString:@"image"] && !BHTDetailViewLooksLikeMedia(view)) score -= area * 0.35;

                if (score > bestScore) {
                    bestScore = score;
                    best = view;
                }
            }
        }

        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }

    return best;
}

@interface BHTDetailDownloadProxy : NSObject
@property (nonatomic, strong) id viewModel;
@property (nonatomic, weak) id delegate;
@end
@implementation BHTDetailDownloadProxy
@end

@interface BHTDetailDownloadTarget : NSObject
@end

@implementation BHTDetailDownloadTarget
+ (instancetype)sharedTarget {
    static BHTDetailDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTDetailDownloadTarget new]; });
    return target;
}

- (void)bht_detailDownloadTapped:(UIButton *)sender {
    id model = objc_getAssociatedObject(sender, BHTDetailVideoModelKey);
    if (!model) return;

    BHTDetailDownloadProxy *proxy = [BHTDetailDownloadProxy new];
    proxy.viewModel = model;

    BHDownloadInlineButton *downloader = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloader.delegate = (id)proxy;
    downloader.viewModel = model;

    objc_setAssociatedObject(sender, BHTDetailProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sender, BHTDetailDownloaderKey, downloader, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    [downloader DownloadHandler:sender];
}
@end

static UIButton *BHTDetailEnsureButton(UIView *root) {
    UIButton *button = (UIButton *)[root viewWithTag:BHTDetailVideoDownloadButtonTag];
    if (button) return button;

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTDetailVideoDownloadButtonTag;
    button.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.58];
    button.tintColor = UIColor.whiteColor;
    button.layer.cornerRadius = 20.0;
    button.layer.masksToBounds = YES;
    button.accessibilityLabel = @"動画をダウンロード";

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:18.0
                                                        weight:UIImageSymbolWeightSemibold
                                                         scale:UIImageSymbolScaleMedium];
    UIImage *image = [UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:config];
    if (!image) image = [UIImage systemImageNamed:@"arrow.down" withConfiguration:config];
    [button setImage:image forState:UIControlStateNormal];
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;

    [button addTarget:[BHTDetailDownloadTarget sharedTarget]
               action:@selector(bht_detailDownloadTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    [root addSubview:button];
    return button;
}

static void BHTDetailApplyButton(UIView *root) {
    if (!root || !root.window) return;

    id model = BHTDetailFindVideoModel(root);
    UIView *mediaView = model ? BHTDetailFindMainMediaView(root) : nil;
    UIButton *button = (UIButton *)[root viewWithTag:BHTDetailVideoDownloadButtonTag];

    if (!model || !mediaView) {
        [button removeFromSuperview];
        return;
    }

    if (!button) button = BHTDetailEnsureButton(root);
    if (!button) return;

    objc_setAssociatedObject(button, BHTDetailVideoModelKey, model, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    CGRect mediaFrame = [mediaView convertRect:mediaView.bounds toView:root];
    if (CGRectIsNull(mediaFrame) || CGRectIsEmpty(mediaFrame)) {
        [button removeFromSuperview];
        return;
    }

    const CGFloat size = 40.0;
    const CGFloat inset = 10.0;
    button.frame = CGRectIntegral(CGRectMake(CGRectGetMinX(mediaFrame) + inset,
                                             CGRectGetMinY(mediaFrame) + inset,
                                             size,
                                             size));
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [root bringSubviewToFront:button];
}

static void BHTTweetDetailLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalTweetDetailLayoutIMP) {
        ((BHTDetailLayoutIMP)BHTOriginalTweetDetailLayoutIMP)(self, _cmd);
    }
    BHTDetailApplyButton((UIView *)self);
}

static void BHTConversationDetailLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalConversationDetailLayoutIMP) {
        ((BHTDetailLayoutIMP)BHTOriginalConversationDetailLayoutIMP)(self, _cmd);
    }
    BHTDetailApplyButton((UIView *)self);
}

static void BHTDetailInstallLayoutHook(Class cls, IMP replacement, IMP *originalOut) {
    if (!cls || !originalOut) return;

    SEL selector = @selector(layoutSubviews);
    Method inherited = class_getInstanceMethod(cls, selector);
    if (!inherited) return;

    const char *types = method_getTypeEncoding(inherited);
    IMP inheritedIMP = method_getImplementation(inherited);

    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    Method own = NULL;
    for (unsigned int i = 0; i < count; i++) {
        if (method_getName(methods[i]) == selector) {
            own = methods[i];
            break;
        }
    }
    free(methods);

    if (own) {
        *originalOut = method_getImplementation(own);
        method_setImplementation(own, replacement);
    } else {
        *originalOut = inheritedIMP;
        class_addMethod(cls, selector, replacement, types);
    }
}

__attribute__((constructor)) static void BHTX1216ReplyDetailVideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTDetailInstallLayoutHook(NSClassFromString(@"T1TweetDetailsFocalStatusView"),
                                   (IMP)BHTTweetDetailLayoutSubviews,
                                   &BHTOriginalTweetDetailLayoutIMP);
        BHTDetailInstallLayoutHook(NSClassFromString(@"T1ConversationFocalStatusView"),
                                   (IMP)BHTConversationDetailLayoutSubviews,
                                   &BHTOriginalConversationDetailLayoutIMP);
        NSLog(@"[BHTwitter][X12.16] Installed reply/detail focal video download overlay");
    });
}
