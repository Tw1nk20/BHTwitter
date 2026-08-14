#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHDownloadInlineButton.h"

static const void *BHTShareDownloadGestureKey = &BHTShareDownloadGestureKey;
static const void *BHTShareDownloadProxyKey = &BHTShareDownloadProxyKey;
static const void *BHTShareDownloaderKey = &BHTShareDownloaderKey;

static IMP BHTOriginalT1ShareLayoutIMP = NULL;
static IMP BHTOriginalTTAShareLayoutIMP = NULL;
typedef void (*BHTShareLayoutIMP)(id, SEL);

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

static id BHTShareViewModelFromObject(id object) {
    if (!object) return nil;

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if ([object respondsToSelector:viewModelSEL]) {
        id model = ((id (*)(id, SEL))objc_msgSend)(object, viewModelSEL);
        if (BHTShareItemIsVideo(model)) return model;
    }

    if (BHTShareItemIsVideo(object)) return object;
    return nil;
}

static id BHTShareViewModelForShareView(UIView *shareView) {
    if (!shareView) return nil;

    // First use the share button's delegate. On X 12.16 this is commonly the
    // inline-actions view/adapter and therefore the shortest stable route to
    // the status view model.
    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareView respondsToSelector:delegateSEL]) {
        id delegate = ((id (*)(id, SEL))objc_msgSend)(shareView, delegateSEL);
        id model = BHTShareViewModelFromObject(delegate);
        if (model) return model;
    }

    // Fall back to the responder and superview chains. This covers tweet-detail
    // layouts where the share button is wrapped by Swift/UI adapters.
    UIResponder *responder = shareView;
    while (responder) {
        id model = BHTShareViewModelFromObject(responder);
        if (model) return model;
        responder = responder.nextResponder;
    }

    UIView *view = shareView.superview;
    while (view) {
        id model = BHTShareViewModelFromObject(view);
        if (model) return model;
        view = view.superview;
    }

    return nil;
}

@interface BHTShareDownloadProxy : NSObject
@property (nonatomic, strong) id viewModel;
@property (nonatomic, weak) id delegate;
@end
@implementation BHTShareDownloadProxy
@end

@interface BHTShareDownloadTarget : NSObject
@end

@implementation BHTShareDownloadTarget

+ (instancetype)sharedTarget {
    static BHTShareDownloadTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTShareDownloadTarget new]; });
    return target;
}

- (void)bht_shareLongPressed:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateBegan) return;
    UIView *shareView = gesture.view;
    if (!shareView || !shareView.window) return;

    id viewModel = BHTShareViewModelForShareView(shareView);
    if (!viewModel) return; // Keep non-video share buttons completely unchanged.

    BHTShareDownloadProxy *proxy = [BHTShareDownloadProxy new];
    proxy.viewModel = viewModel;

    // Preserve the real inline-actions delegate where available. The existing
    // downloader uses it for slideshow/special-media handling.
    SEL delegateSEL = NSSelectorFromString(@"delegate");
    if ([shareView respondsToSelector:delegateSEL]) {
        proxy.delegate = ((id (*)(id, SEL))objc_msgSend)(shareView, delegateSEL);
    }

    BHDownloadInlineButton *downloader = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloader.delegate = (id)proxy;
    downloader.viewModel = viewModel;

    objc_setAssociatedObject(shareView,
                             BHTShareDownloadProxyKey,
                             proxy,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(shareView,
                             BHTShareDownloaderKey,
                             downloader,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // DownloadHandler does not require the sender to be the original inline
    // button. Supplying a UIButton keeps the declared method contract intact.
    UIButton *sender = [shareView isKindOfClass:[UIButton class]]
        ? (UIButton *)shareView
        : [UIButton buttonWithType:UIButtonTypeSystem];

    [downloader DownloadHandler:sender];
}

@end

static void BHTInstallLongPressIfNeeded(UIView *shareView) {
    if (!shareView || objc_getAssociatedObject(shareView, BHTShareDownloadGestureKey)) return;

    UILongPressGestureRecognizer *gesture =
        [[UILongPressGestureRecognizer alloc] initWithTarget:[BHTShareDownloadTarget sharedTarget]
                                                     action:@selector(bht_shareLongPressed:)];
    gesture.minimumPressDuration = 0.45;
    gesture.cancelsTouchesInView = YES;
    [shareView addGestureRecognizer:gesture];
    shareView.userInteractionEnabled = YES;

    objc_setAssociatedObject(shareView,
                             BHTShareDownloadGestureKey,
                             gesture,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void BHTT1ShareLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalT1ShareLayoutIMP) {
        ((BHTShareLayoutIMP)BHTOriginalT1ShareLayoutIMP)(self, _cmd);
    }
    if ([self isKindOfClass:[UIView class]]) BHTInstallLongPressIfNeeded((UIView *)self);
}

static void BHTTTAShareLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalTTAShareLayoutIMP) {
        ((BHTShareLayoutIMP)BHTOriginalTTAShareLayoutIMP)(self, _cmd);
    }
    if ([self isKindOfClass:[UIView class]]) BHTInstallLongPressIfNeeded((UIView *)self);
}

static void BHTInstallShareLayoutHook(Class cls, IMP replacement, IMP *originalOut) {
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

__attribute__((constructor)) static void BHTX1216ShareDownloadCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        BHTInstallShareLayoutHook(NSClassFromString(@"T1StatusInlineShareButton"),
                                  (IMP)BHTT1ShareLayoutSubviews,
                                  &BHTOriginalT1ShareLayoutIMP);
        BHTInstallShareLayoutHook(NSClassFromString(@"TTAStatusInlineShareButton"),
                                  (IMP)BHTTTAShareLayoutSubviews,
                                  &BHTOriginalTTAShareLayoutIMP);
        NSLog(@"[BHTwitter][X12.16] Installed video download on share-button long press");
    });
}
