#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const NSInteger BHTVideoDownloadButtonTag = 1216099;
static const void *BHTVideoItemKey = &BHTVideoItemKey;
static const void *BHTActiveDownloaderKey = &BHTActiveDownloaderKey;
static const void *BHTActiveDownloadProxyKey = &BHTActiveDownloadProxyKey;
static IMP BHTOriginalTableCellForItemIMP = NULL;
static IMP BHTOriginalTableLayoutIMP = NULL;

typedef UITableViewCell *(*BHTTableCellForItemIMP)(id, SEL, id, id);
typedef void (*BHTVoidIMP)(id, SEL);

static BOOL BHTRuntimeItemIsVideo(id item) {
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
                    NSInteger mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(media, mediaTypeSEL);
                    if (mediaType == 2 || mediaType == 3) return YES;
                }

                SEL videoInfoSEL = NSSelectorFromString(@"videoInfo");
                if ([media respondsToSelector:videoInfoSEL] && ((id (*)(id, SEL))objc_msgSend)(media, videoInfoSEL)) return YES;
            }
        }
    }

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if ([item respondsToSelector:viewModelSEL]) {
        id model = ((id (*)(id, SEL))objc_msgSend)(item, viewModelSEL);
        if (model && model != item && BHTRuntimeItemIsVideo(model)) return YES;
    }

    SEL tweetSEL = NSSelectorFromString(@"tweet");
    if ([item respondsToSelector:tweetSEL]) {
        id tweet = ((id (*)(id, SEL))objc_msgSend)(item, tweetSEL);
        if (tweet && tweet != item && BHTRuntimeItemIsVideo(tweet)) return YES;
    }

    return NO;
}

static UIView *BHTFindActionsView(UIView *root) {
    if (!root) return nil;

    Class ttaClass = NSClassFromString(@"TTAStatusInlineActionsView");
    Class t1Class = NSClassFromString(@"T1StatusInlineActionsView");
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if ((ttaClass && [view isKindOfClass:ttaClass]) ||
            (t1Class && [view isKindOfClass:t1Class])) return view;

        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }

    return nil;
}

static id BHTFindVideoModelInCell(UITableViewCell *cell) {
    if (!cell) return nil;

    UIView *root = cell.contentView ?: cell;
    UIView *actionsView = BHTFindActionsView(cell);
    SEL viewModelSEL = NSSelectorFromString(@"viewModel");

    if (actionsView && [actionsView respondsToSelector:viewModelSEL]) {
        id model = ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL);
        if (BHTRuntimeItemIsVideo(model)) return model;
    }

    id associated = objc_getAssociatedObject(cell, BHTVideoItemKey);
    if (BHTRuntimeItemIsVideo(associated)) return associated;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if ([view respondsToSelector:viewModelSEL]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(view, viewModelSEL);
            if (BHTRuntimeItemIsVideo(model)) return model;
        }

        UIResponder *responder = view.nextResponder;
        if (responder && [responder respondsToSelector:viewModelSEL]) {
            id model = ((id (*)(id, SEL))objc_msgSend)(responder, viewModelSEL);
            if (BHTRuntimeItemIsVideo(model)) return model;
        }

        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }

    return nil;
}

@interface BHTDownloadDelegateProxy : NSObject
@property (nonatomic, strong) id viewModel;
@property (nonatomic, weak) id delegate;
@end
@implementation BHTDownloadDelegateProxy
@end

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
    UITableViewCell *cell = nil;
    UIResponder *responder = sender;
    while (responder) {
        if ([responder isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)responder;
            break;
        }
        responder = responder.nextResponder;
    }
    if (!cell) return;

    id viewModel = BHTFindVideoModelInCell(cell);
    if (!viewModel) return;

    BHTDownloadDelegateProxy *proxy = [BHTDownloadDelegateProxy new];
    proxy.viewModel = viewModel;

    BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloadButton.delegate = (id)proxy;
    downloadButton.viewModel = viewModel;

    objc_setAssociatedObject(sender, BHTActiveDownloadProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(sender, BHTActiveDownloaderKey, downloadButton, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    dispatch_async(dispatch_get_main_queue(), ^{
        [downloadButton DownloadHandler:sender];
    });
}
@end

static BOOL BHTViewOrLayerLooksLikeVideo(UIView *view) {
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
        NSString *layerName = NSStringFromClass(layer.class).lowercaseString ?: @"";
        if ([layerName containsString:@"player"] || [layerName containsString:@"video"]) return YES;
        if (layer.sublayers.count) [layers addObjectsFromArray:layer.sublayers];
    }

    return NO;
}

static UIView *BHTFindMainMediaView(UITableViewCell *cell) {
    if (!cell) return nil;

    UIView *root = cell.contentView ?: cell;
    UIView *actionsView = BHTFindActionsView(cell);
    CGRect actionsFrame = CGRectNull;
    if (actionsView && actionsView.superview) {
        actionsFrame = [actionsView.superview convertRect:actionsView.frame toView:root];
    }

    CGFloat rootWidth = CGRectGetWidth(root.bounds);
    CGFloat rootHeight = CGRectGetHeight(root.bounds);
    if (rootWidth <= 0.0 || rootHeight <= 0.0) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    CGFloat bestScore = -CGFLOAT_MAX;

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != root && view != actionsView &&
            view.tag != BHTVideoDownloadButtonTag &&
            !view.hidden && view.alpha > 0.05 && view.superview) {

            CGRect frame = [view convertRect:view.bounds toView:root];
            CGFloat w = CGRectGetWidth(frame);
            CGFloat h = CGRectGetHeight(frame);
            CGFloat area = w * h;

            BOOL largeEnough = w >= rootWidth * 0.55 && h >= 120.0;
            BOOL insideCell = CGRectIntersectsRect(root.bounds, frame);
            BOOL aboveActions = CGRectIsNull(actionsFrame) || CGRectGetMidY(frame) < CGRectGetMidY(actionsFrame);
            BOOL reasonableHeight = h <= rootHeight * 0.92;

            if (largeEnough && insideCell && aboveActions && reasonableHeight) {
                CGFloat score = area;
                if (BHTViewOrLayerLooksLikeVideo(view)) score += rootWidth * rootHeight * 1.5;

                NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
                if ([className containsString:@"image"] && !BHTViewOrLayerLooksLikeVideo(view)) score -= area * 0.25;

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

static void BHTRemoveVideoButtonsFromCell(UITableViewCell *cell) {
    if (!cell) return;
    UIView *root = cell.contentView ?: cell;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view.tag == BHTVideoDownloadButtonTag) {
            [view removeFromSuperview];
            continue;
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }
}

static UIButton *BHTEnsureVideoButton(UITableViewCell *cell) {
    if (!cell) return nil;
    UIView *overlayHost = cell.contentView ?: cell;

    UIButton *button = (UIButton *)[overlayHost viewWithTag:BHTVideoDownloadButtonTag];
    if (button && button.superview == overlayHost) return button;

    BHTRemoveVideoButtonsFromCell(cell);

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTVideoDownloadButtonTag;
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

    [button addTarget:[BHTVideoDownloadTarget sharedTarget]
               action:@selector(bht_downloadVideoTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    [overlayHost addSubview:button];
    return button;
}

static void BHTApplyVideoButtonToCell(UITableViewCell *cell) {
    if (!cell || !cell.window) return;

    UIView *overlayHost = cell.contentView ?: cell;
    id viewModel = BHTFindVideoModelInCell(cell);
    UIView *mediaHost = viewModel ? BHTFindMainMediaView(cell) : nil;

    if (!viewModel || !mediaHost || !mediaHost.window) {
        BHTRemoveVideoButtonsFromCell(cell);
        return;
    }

    UIButton *button = BHTEnsureVideoButton(cell);
    if (!button) return;

    CGRect mediaFrame = [mediaHost convertRect:mediaHost.bounds toView:overlayHost];
    if (CGRectIsNull(mediaFrame) || CGRectIsEmpty(mediaFrame)) {
        [button removeFromSuperview];
        return;
    }

    const CGFloat size = 40.0;
    const CGFloat inset = 10.0;
    CGFloat x = CGRectGetMinX(mediaFrame) + inset;
    CGFloat y = CGRectGetMinY(mediaFrame) + inset;

    button.frame = CGRectIntegral(CGRectMake(x, y, size, size));
    button.autoresizingMask = UIViewAutoresizingNone;
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [overlayHost bringSubviewToFront:button];
}

static void BHTScheduleVideoButtonEvaluation(UITableViewCell *cell) {
    if (!cell) return;
    dispatch_async(dispatch_get_main_queue(), ^{ BHTApplyVideoButtonToCell(cell); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ BHTApplyVideoButtonToCell(cell); });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.60 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ BHTApplyVideoButtonToCell(cell); });
}

static UITableViewCell *BHTVideoTableCellForItem(id self, SEL _cmd, id item, id indexPath) {
    UITableViewCell *cell = nil;
    if (BHTOriginalTableCellForItemIMP) {
        cell = ((BHTTableCellForItemIMP)BHTOriginalTableCellForItemIMP)(self, _cmd, item, indexPath);
    }

    id timelineItem = item;
    SEL itemAtIndexPathSEL = NSSelectorFromString(@"itemAtIndexPath:");
    if ([self respondsToSelector:itemAtIndexPathSEL] && indexPath) {
        id resolved = ((id (*)(id, SEL, id))objc_msgSend)(self, itemAtIndexPathSEL, indexPath);
        if (resolved) timelineItem = resolved;
    }

    if (cell && timelineItem) {
        objc_setAssociatedObject(cell, BHTVideoItemKey, timelineItem, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    BHTScheduleVideoButtonEvaluation(cell);
    return cell;
}

static void BHTTableLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalTableLayoutIMP) ((BHTVoidIMP)BHTOriginalTableLayoutIMP)(self, _cmd);

    UITableView *tableView = (UITableView *)self;
    for (UITableViewCell *cell in tableView.visibleCells) {
        BHTApplyVideoButtonToCell(cell);
    }
}

static void BHTInstallSafeLayoutHook(Class cls, IMP replacement, IMP *originalOut) {
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

static void BHTInstallVideoTimelineHook(void) {
    Class cls = NSClassFromString(@"TFNItemsDataViewController");
    SEL selector = NSSelectorFromString(@"tableViewCellForItem:atIndexPath:");
    if (cls) {
        Method method = class_getInstanceMethod(cls, selector);
        if (method) {
            const char *types = method_getTypeEncoding(method);
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
                BHTOriginalTableCellForItemIMP = method_getImplementation(ownMethod);
                method_setImplementation(ownMethod, (IMP)BHTVideoTableCellForItem);
            } else {
                BHTOriginalTableCellForItemIMP = method_getImplementation(method);
                class_addMethod(cls, selector, (IMP)BHTVideoTableCellForItem, types);
            }
        }
    }

    BHTInstallSafeLayoutHook([UITableView class], (IMP)BHTTableLayoutSubviews, &BHTOriginalTableLayoutIMP);
    NSLog(@"[BHTwitter][X12.16] Installed cell-owned video overlay and detail refresh");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallVideoTimelineHook();
    });
}
