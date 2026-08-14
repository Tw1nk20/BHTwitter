#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const NSInteger BHTVideoDownloadButtonTag = 1216099;
static const void *BHTVideoItemKey = &BHTVideoItemKey;
static const void *BHTActiveDownloaderKey = &BHTActiveDownloaderKey;
static const void *BHTActiveDownloadProxyKey = &BHTActiveDownloadProxyKey;
static IMP BHTOriginalTableCellForItemIMP = NULL;

typedef UITableViewCell *(*BHTTableCellForItemIMP)(id, SEL, id, id);

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
            (t1Class && [view isKindOfClass:t1Class])) {
            return view;
        }

        [stack addObjectsFromArray:view.subviews];
    }

    return nil;
}

static id BHTVideoViewModelForCell(UITableViewCell *cell) {
    if (!cell) return nil;

    UIView *actionsView = BHTFindActionsView(cell);
    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if (actionsView && [actionsView respondsToSelector:viewModelSEL]) {
        id viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL);
        if (viewModel && BHTRuntimeItemIsVideo(viewModel)) return viewModel;
    }

    id fallback = objc_getAssociatedObject(cell, BHTVideoItemKey);
    if (fallback && BHTRuntimeItemIsVideo(fallback)) return fallback;

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

    UIView *actionsView = BHTFindActionsView(cell);
    id viewModel = nil;

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if (actionsView && [actionsView respondsToSelector:viewModelSEL]) {
        id liveModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL);
        if (liveModel && BHTRuntimeItemIsVideo(liveModel)) viewModel = liveModel;
    }

    if (!viewModel) viewModel = BHTVideoViewModelForCell(cell);
    if (!viewModel) return;

    BHTDownloadDelegateProxy *proxy = [BHTDownloadDelegateProxy new];
    proxy.viewModel = viewModel;
    proxy.delegate = nil;

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

static NSArray<NSDictionary *> *BHTNativeActionCandidates(UIView *host) {
    if (!host) return @[];

    NSMutableArray<NSDictionary *> *items = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:host];
    CGFloat hostHeight = CGRectGetHeight(host.bounds);

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != host && view.tag != BHTVideoDownloadButtonTag && !view.hidden && view.alpha > 0.05 && view.superview) {
            BOOL controlLike = [view isKindOfClass:[UIControl class]];
            NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
            controlLike = controlLike || [className containsString:@"button"] || [className containsString:@"control"];

            if (controlLike) {
                CGRect frame = [view.superview convertRect:view.frame toView:host];
                CGFloat w = CGRectGetWidth(frame);
                CGFloat h = CGRectGetHeight(frame);
                CGFloat midY = CGRectGetMidY(frame);
                BOOL sizeOK = w >= 24.0 && w <= 72.0 && h >= 24.0 && h <= 72.0;
                BOOL lowerHalf = midY >= MAX(32.0, hostHeight * 0.45) && midY <= hostHeight - 2.0;
                if (sizeOK && lowerHalf) {
                    [items addObject:@{ @"view": view, @"frame": [NSValue valueWithCGRect:frame] }];
                }
            }
        }
        [stack addObjectsFromArray:view.subviews];
    }

    return items;
}

static BOOL BHTFindRightActionPair(UIView *host, CGRect *leftFrameOut, CGRect *rightFrameOut) {
    NSArray<NSDictionary *> *items = BHTNativeActionCandidates(host);
    if (items.count < 2) return NO;

    CGFloat lowestMidY = -CGFLOAT_MAX;
    for (NSDictionary *item in items) {
        CGRect f = [item[@"frame"] CGRectValue];
        lowestMidY = MAX(lowestMidY, CGRectGetMidY(f));
    }

    NSMutableArray<NSValue *> *row = [NSMutableArray array];
    for (NSDictionary *item in items) {
        CGRect f = [item[@"frame"] CGRectValue];
        if (fabs(CGRectGetMidY(f) - lowestMidY) <= 24.0) [row addObject:item[@"frame"]];
    }
    if (row.count < 2) return NO;

    [row sortUsingComparator:^NSComparisonResult(NSValue *a, NSValue *b) {
        CGFloat ax = CGRectGetMidX(a.CGRectValue);
        CGFloat bx = CGRectGetMidX(b.CGRectValue);
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    CGRect right = row.lastObject.CGRectValue;
    CGRect left = row[row.count - 2].CGRectValue;
    if (leftFrameOut) *leftFrameOut = left;
    if (rightFrameOut) *rightFrameOut = right;
    return YES;
}

static void BHTApplyVideoButtonToCell(UITableViewCell *cell) {
    if (!cell) return;

    UIView *host = cell.contentView ?: cell;
    UIButton *button = (UIButton *)[host viewWithTag:BHTVideoDownloadButtonTag];
    id viewModel = BHTVideoViewModelForCell(cell);

    if (!viewModel) {
        [button removeFromSuperview];
        return;
    }

    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = BHTVideoDownloadButtonTag;
        button.backgroundColor = UIColor.clearColor;
        button.tintColor = UIColor.secondaryLabelColor;
        button.accessibilityLabel = @"動画をダウンロード";

        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0
                                                            weight:UIImageSymbolWeightRegular
                                                             scale:UIImageSymbolScaleMedium];
        UIImage *image = [UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:config];
        if (!image) image = [UIImage systemImageNamed:@"arrow.down" withConfiguration:config];
        [button setImage:image forState:UIControlStateNormal];

        [button addTarget:[BHTVideoDownloadTarget sharedTarget]
                   action:@selector(bht_downloadVideoTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [host addSubview:button];
    }

    const CGFloat hitSize = 32.0;
    CGFloat width = CGRectGetWidth(host.bounds);
    CGFloat height = CGRectGetHeight(host.bounds);
    CGRect leftAction = CGRectZero;
    CGRect rightAction = CGRectZero;
    CGRect frame = CGRectZero;

    if (BHTFindRightActionPair(host, &leftAction, &rightAction)) {
        CGFloat centerX = (CGRectGetMidX(leftAction) + CGRectGetMidX(rightAction)) * 0.5;
        CGFloat centerY = (CGRectGetMidY(leftAction) + CGRectGetMidY(rightAction)) * 0.5;
        frame = CGRectMake(centerX - hitSize * 0.5,
                           centerY - hitSize * 0.5,
                           hitSize,
                           hitSize);
    } else {
        // Fallback is deliberately lower than the previous implementation so
        // timeline cells align with X's native action baseline. On tweet detail
        // cells, keeping the button in the action band avoids the metadata row.
        CGFloat x = MAX(8.0, width - 72.0);
        CGFloat y = MAX(8.0, height - 40.0);
        frame = CGRectMake(x, y, hitSize, hitSize);
    }

    frame.origin.x = MAX(8.0, MIN(frame.origin.x, MAX(8.0, width - hitSize - 8.0)));
    frame.origin.y = MAX(8.0, MIN(frame.origin.y, MAX(8.0, height - hitSize - 6.0)));

    button.frame = CGRectIntegral(frame);
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [host bringSubviewToFront:button];
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

static void BHTInstallVideoTimelineHook(void) {
    Class cls = NSClassFromString(@"TFNItemsDataViewController");
    SEL selector = NSSelectorFromString(@"tableViewCellForItem:atIndexPath:");
    if (!cls) return;

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) return;

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

    NSLog(@"[BHTwitter][X12.16] Installed video download button with native-row alignment");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallVideoTimelineHook();
    });
}
