#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static const NSInteger BHTVideoDownloadButtonTag_Placement = 1216099;
static IMP BHTOriginalTTAActionsLayoutIMP = NULL;
static IMP BHTOriginalT1ActionsLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

static BOOL BHTStringContainsAny(NSString *value, NSArray<NSString *> *needles) {
    if (![value isKindOfClass:[NSString class]] || value.length == 0) return NO;
    NSString *lower = value.lowercaseString;
    for (NSString *needle in needles) {
        if ([lower containsString:needle.lowercaseString]) return YES;
    }
    return NO;
}

static CGRect BHTFrameOfViewInsideActionsView(UIView *view, UIView *actionsView) {
    if (!view || !actionsView || !view.window || !actionsView.window) return CGRectNull;
    return [view convertRect:view.bounds toView:actionsView];
}

static NSArray<UIView *> *BHTActionControls(UIView *actionsView) {
    if (!actionsView) return @[];

    NSMutableArray<UIView *> *controls = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:actionsView];

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != actionsView &&
            view.tag != BHTVideoDownloadButtonTag_Placement &&
            !view.hidden &&
            view.alpha > 0.05 &&
            view.window) {

            BOOL controlLike = [view isKindOfClass:[UIControl class]];
            NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
            controlLike = controlLike || [className containsString:@"button"] || [className containsString:@"control"];

            if (controlLike) {
                CGRect frame = BHTFrameOfViewInsideActionsView(view, actionsView);
                if (!CGRectIsNull(frame)) {
                    CGFloat w = CGRectGetWidth(frame);
                    CGFloat h = CGRectGetHeight(frame);
                    CGFloat midY = CGRectGetMidY(frame);
                    BOOL sizeOK = w >= 18.0 && w <= 120.0 && h >= 18.0 && h <= 80.0;
                    BOOL rowOK = midY >= -8.0 && midY <= CGRectGetHeight(actionsView.bounds) + 8.0;
                    if (sizeOK && rowOK) [controls addObject:view];
                }
            }
        }

        [stack addObjectsFromArray:view.subviews];
    }

    return controls;
}

static UIView *BHTFindActionByMeaning(NSArray<UIView *> *controls, BOOL bookmark) {
    NSArray<NSString *> *needles = bookmark
        ? @[@"bookmark", @"ブックマーク", @"save", @"保存"]
        : @[@"share", @"共有", @"send", @"シェア"];

    UIView *best = nil;
    for (UIView *view in controls) {
        NSString *label = view.accessibilityLabel ?: @"";
        NSString *identifier = view.accessibilityIdentifier ?: @"";
        NSString *hint = view.accessibilityHint ?: @"";
        NSString *className = NSStringFromClass(view.class) ?: @"";

        if (BHTStringContainsAny(label, needles) ||
            BHTStringContainsAny(identifier, needles) ||
            BHTStringContainsAny(hint, needles) ||
            BHTStringContainsAny(className, needles)) {
            best = view;
            break;
        }
    }
    return best;
}

static BOOL BHTFallbackRightmostPair(NSArray<UIView *> *controls,
                                     UIView *actionsView,
                                     UIView **bookmarkOut,
                                     UIView **shareOut) {
    if (controls.count < 2) return NO;

    NSArray<UIView *> *sorted = [controls sortedArrayUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGRect af = BHTFrameOfViewInsideActionsView(a, actionsView);
        CGRect bf = BHTFrameOfViewInsideActionsView(b, actionsView);
        CGFloat ax = CGRectGetMidX(af);
        CGFloat bx = CGRectGetMidX(bf);
        if (ax < bx) return NSOrderedAscending;
        if (ax > bx) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    for (NSInteger i = (NSInteger)sorted.count - 1; i > 0; i--) {
        UIView *right = sorted[i];
        UIView *left = sorted[i - 1];
        CGRect rf = BHTFrameOfViewInsideActionsView(right, actionsView);
        CGRect lf = BHTFrameOfViewInsideActionsView(left, actionsView);

        if (CGRectIsNull(rf) || CGRectIsNull(lf)) continue;
        if (fabs(CGRectGetMidY(rf) - CGRectGetMidY(lf)) > 10.0) continue;

        CGFloat xGap = CGRectGetMidX(rf) - CGRectGetMidX(lf);
        if (xGap < 34.0 || xGap > 170.0) continue;

        if (bookmarkOut) *bookmarkOut = left;
        if (shareOut) *shareOut = right;
        return YES;
    }

    return NO;
}

static void BHTCorrectDownloadButtonPlacement(UIView *actionsView) {
    if (!actionsView || !actionsView.window) return;

    UIButton *download = (UIButton *)[actionsView viewWithTag:BHTVideoDownloadButtonTag_Placement];
    if (![download isKindOfClass:[UIButton class]] || download.hidden) return;

    NSArray<UIView *> *controls = BHTActionControls(actionsView);
    UIView *bookmark = BHTFindActionByMeaning(controls, YES);
    UIView *share = BHTFindActionByMeaning(controls, NO);

    if (!bookmark || !share) {
        UIView *fallbackBookmark = nil;
        UIView *fallbackShare = nil;
        if (BHTFallbackRightmostPair(controls, actionsView, &fallbackBookmark, &fallbackShare)) {
            if (!bookmark) bookmark = fallbackBookmark;
            if (!share) share = fallbackShare;
        }
    }

    if (!bookmark || !share || bookmark == share) return;

    CGRect bookmarkFrame = BHTFrameOfViewInsideActionsView(bookmark, actionsView);
    CGRect shareFrame = BHTFrameOfViewInsideActionsView(share, actionsView);
    if (CGRectIsNull(bookmarkFrame) || CGRectIsNull(shareFrame)) return;

    CGFloat bookmarkX = CGRectGetMidX(bookmarkFrame);
    CGFloat shareX = CGRectGetMidX(shareFrame);
    if (shareX < bookmarkX) {
        CGRect tmp = bookmarkFrame;
        bookmarkFrame = shareFrame;
        shareFrame = tmp;
    }

    CGFloat targetX = (CGRectGetMidX(bookmarkFrame) + CGRectGetMidX(shareFrame)) * 0.5;

    // Do not average arbitrary descendant Y positions. X's visible action baseline
    // is represented most reliably by the two native controls themselves; when
    // they differ slightly, prefer the share control and clamp to the action bar.
    CGFloat targetY = CGRectGetMidY(shareFrame);
    CGFloat bookmarkY = CGRectGetMidY(bookmarkFrame);
    if (fabs(bookmarkY - targetY) <= 8.0) {
        targetY = (bookmarkY + targetY) * 0.5;
    }

    CGFloat barHeight = CGRectGetHeight(actionsView.bounds);
    if (barHeight > 0.0) {
        targetY = MAX(16.0, MIN(targetY, barHeight - 16.0));
    }

    const CGFloat hitSize = 32.0;
    CGRect target = CGRectMake(targetX - hitSize * 0.5,
                               targetY - hitSize * 0.5,
                               hitSize,
                               hitSize);

    download.frame = CGRectIntegral(target);
    download.center = CGPointMake(round(targetX * UIScreen.mainScreen.scale) / UIScreen.mainScreen.scale,
                                  round(targetY * UIScreen.mainScreen.scale) / UIScreen.mainScreen.scale);
    download.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                UIViewAutoresizingFlexibleRightMargin |
                                UIViewAutoresizingFlexibleTopMargin |
                                UIViewAutoresizingFlexibleBottomMargin;
    [actionsView bringSubviewToFront:download];
}

static void BHTTTAActionsLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalTTAActionsLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalTTAActionsLayoutIMP)(self, _cmd);
    }
    BHTCorrectDownloadButtonPlacement((UIView *)self);
}

static void BHTT1ActionsLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalT1ActionsLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalT1ActionsLayoutIMP)(self, _cmd);
    }
    BHTCorrectDownloadButtonPlacement((UIView *)self);
}

static void BHTInstallLayoutFixForClass(Class cls, IMP replacement, IMP *originalOut) {
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

__attribute__((constructor)) static void BHTX1216VideoPlacementFixInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallLayoutFixForClass(NSClassFromString(@"TTAStatusInlineActionsView"),
                                    (IMP)BHTTTAActionsLayoutSubviews,
                                    &BHTOriginalTTAActionsLayoutIMP);
        BHTInstallLayoutFixForClass(NSClassFromString(@"T1StatusInlineActionsView"),
                                    (IMP)BHTT1ActionsLayoutSubviews,
                                    &BHTOriginalT1ActionsLayoutIMP);
        NSLog(@"[BHTwitter][X12.16] Installed precise bookmark-download-share placement fix");
    });
}
