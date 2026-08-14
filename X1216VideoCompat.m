#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHDownloadInlineButton.h"

static const NSInteger BHTVideoDownloadButtonTag = 1216099;
static const void *BHTVideoItemKey = &BHTVideoItemKey;
static IMP BHTOriginalTableCellForItemIMP = NULL;

typedef UITableViewCell *(*BHTTableCellForItemIMP)(id, SEL, id, id);

static BOOL BHTRuntimeItemIsVideo(id item) {
    if (!item) return NO;

    SEL videoSEL = NSSelectorFromString(@"isMediaEntityVideo");
    if ([item respondsToSelector:videoSEL] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(item, videoSEL)) {
        return YES;
    }

    SEL gifSEL = NSSelectorFromString(@"isGIF");
    if ([item respondsToSelector:gifSEL] &&
        ((BOOL (*)(id, SEL))objc_msgSend)(item, gifSEL)) {
        return YES;
    }

    SEL representedSEL = NSSelectorFromString(@"representedMediaEntities");
    if ([item respondsToSelector:representedSEL]) {
        id entities = ((id (*)(id, SEL))objc_msgSend)(item, representedSEL);
        if ([entities isKindOfClass:[NSArray class]]) {
            for (id media in (NSArray *)entities) {
                SEL mediaTypeSEL = NSSelectorFromString(@"mediaType");
                if ([media respondsToSelector:mediaTypeSEL]) {
                    NSInteger mediaType = ((NSInteger (*)(id, SEL))objc_msgSend)(media, mediaTypeSEL);
                    // BHTwitter's current model mapping: 2 = GIF, 3 = video.
                    if (mediaType == 2 || mediaType == 3) return YES;
                }

                NSString *desc = [[media description] lowercaseString];
                if ([desc containsString:@"mediatype: video"] ||
                    [desc containsString:@"mediatype: gif"]) {
                    return YES;
                }
            }
        }
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
    UIView *host = sender.superview;
    UITableViewCell *cell = nil;
    UIResponder *responder = sender;

    while (responder) {
        if ([responder isKindOfClass:[UITableViewCell class]]) {
            cell = (UITableViewCell *)responder;
            break;
        }
        responder = responder.nextResponder;
    }

    UIView *searchRoot = cell ?: host;
    UIView *actionsView = BHTFindActionsView(searchRoot);
    id viewModel = nil;

    SEL viewModelSEL = NSSelectorFromString(@"viewModel");
    if (actionsView && [actionsView respondsToSelector:viewModelSEL]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(actionsView, viewModelSEL);
    }

    if (!viewModel) {
        viewModel = objc_getAssociatedObject(sender, BHTVideoItemKey);
    }

    if (!viewModel || !BHTRuntimeItemIsVideo(viewModel)) return;

    // BHDownloadInlineButton already contains BHTwitter's quality-selection,
    // MP4/M3U8 handling and direct-save logic. Reuse it instead of duplicating
    // the downloader here.
    BHDownloadInlineButton *downloadButton = [[BHDownloadInlineButton alloc] initWithFrame:CGRectZero];
    downloadButton.delegate = (id)actionsView;
    downloadButton.viewModel = viewModel;
    [downloadButton DownloadHandler:nil];
}

@end

static void BHTConfigureDownloadButton(UITableViewCell *cell, id item) {
    if (!cell) return;

    UIView *host = cell.contentView ?: cell;
    UIButton *button = (UIButton *)[host viewWithTag:BHTVideoDownloadButtonTag];

    BOOL shouldShow = [BHTManager DownloadingVideos] && BHTRuntimeItemIsVideo(item);
    if (!shouldShow) {
        if (button) {
            [button removeFromSuperview];
        }
        return;
    }

    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = BHTVideoDownloadButtonTag;
        button.backgroundColor = UIColor.clearColor;
        button.tintColor = UIColor.secondaryLabelColor;
        button.accessibilityLabel = @"動画をダウンロード";

        UIImageSymbolConfiguration *config =
            [UIImageSymbolConfiguration configurationWithPointSize:17.0 weight:UIImageSymbolWeightRegular];
        UIImage *image = [UIImage systemImageNamed:@"arrow.down.to.line" withConfiguration:config];
        if (!image) image = [UIImage systemImageNamed:@"arrow.down" withConfiguration:config];
        [button setImage:image forState:UIControlStateNormal];

        [button addTarget:[BHTVideoDownloadTarget sharedTarget]
                   action:@selector(bht_downloadVideoTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        [host addSubview:button];
    }

    objc_setAssociatedObject(button, BHTVideoItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

    // Previous diagnostic placement: size 36, right inset 18.
    // Final placement: one size smaller and roughly 10pt farther left.
    const CGFloat size = 30.0;
    const CGFloat rightInset = 34.0;
    const CGFloat bottomInset = 12.0;
    CGFloat width = CGRectGetWidth(host.bounds);
    CGFloat height = CGRectGetHeight(host.bounds);

    CGFloat x = MAX(8.0, width - rightInset - size);
    CGFloat y = MAX(8.0, height - bottomInset - size);
    button.frame = CGRectIntegral(CGRectMake(x, y, size, size));
    button.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;

    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [host bringSubviewToFront:button];
}

static UITableViewCell *BHTVideoTableCellForItem(id self, SEL _cmd, id item, id indexPath) {
    UITableViewCell *cell = nil;
    if (BHTOriginalTableCellForItemIMP) {
        cell = ((BHTTableCellForItemIMP)BHTOriginalTableCellForItemIMP)(self, _cmd, item, indexPath);
    }

    BHTConfigureDownloadButton(cell, item);
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

    NSLog(@"[BHTwitter][X12.16] Installed video-only timeline download button");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallVideoTimelineHook();
    });
}
