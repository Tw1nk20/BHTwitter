#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"

static const NSInteger BHTProfileCopyButtonTag = 1216001;
static IMP BHTOriginalProfileHeaderLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

static BOOL BHTLegacyCopyProfileInfoDisabled(id self, SEL _cmd) { return NO; }
static BOOL BHTX1216CopyProfileInfoEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"CopyProfileInfo"];
}

static void BHTDisableLegacyProfileCopyHook(void) {
    Class managerClass = NSClassFromString(@"BHTManager");
    SEL selector = NSSelectorFromString(@"CopyProfileInfo");
    Method method = managerClass ? class_getClassMethod(managerClass, selector) : NULL;
    if (!method) return;
    Class metaClass = object_getClass(managerClass);
    class_replaceMethod(metaClass, selector, (IMP)BHTLegacyCopyProfileInfoDisabled, method_getTypeEncoding(method));
}

static UIViewController *BHTProfileHeaderControllerFromView(UIView *view) {
    UIResponder *responder = view;
    Class cls = NSClassFromString(@"T1ProfileHeaderViewController");
    while (responder) {
        if (cls && [responder isKindOfClass:cls]) return (UIViewController *)responder;
        responder = responder.nextResponder;
    }
    return nil;
}

static void BHTShowProfileCopyMenu(UIViewController *controller, id viewModel, UIView *sourceView) {
    if (!controller || !viewModel || !controller.view.window) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"プロフィール情報をコピー"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    NSArray<NSDictionary *> *items = @[
        @{ @"selector": @"bio", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_1"] ?: @"自己紹介" },
        @{ @"selector": @"username", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_2"] ?: @"ユーザー名" },
        @{ @"selector": @"fullName", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_3"] ?: @"表示名" },
        @{ @"selector": @"url", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_4"] ?: @"URL" },
        @{ @"selector": @"location", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_5"] ?: @"場所" },
    ];

    for (NSDictionary *item in items) {
        SEL selector = NSSelectorFromString(item[@"selector"]);
        if (![viewModel respondsToSelector:selector]) continue;
        id value = ((id (*)(id, SEL))objc_msgSend)(viewModel, selector);
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) continue;
        [alert addAction:[UIAlertAction actionWithTitle:item[@"title"] style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = value;
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];
    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: controller.view;
        popover.sourceRect = sourceView ? sourceView.bounds : controller.view.bounds;
    }
    if (!controller.presentedViewController) [controller presentViewController:alert animated:YES completion:nil];
}

@interface BHTProfileCopyTarget : NSObject
@end
@implementation BHTProfileCopyTarget
+ (instancetype)sharedTarget {
    static BHTProfileCopyTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTProfileCopyTarget new]; });
    return target;
}
- (void)bht_profileCopyTapped:(UIButton *)sender {
    UIViewController *controller = BHTProfileHeaderControllerFromView(sender);
    if (!controller || !controller.view.window) return;
    SEL selector = NSSelectorFromString(@"viewModel");
    id viewModel = [controller respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(controller, selector) : nil;
    if (viewModel) BHTShowProfileCopyMenu(controller, viewModel, sender);
}
@end

static UIButton *BHTEnsureCopyButton(UIView *headerView) {
    UIButton *button = (UIButton *)[headerView viewWithTag:BHTProfileCopyButtonTag];
    if (button) return button;

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTProfileCopyButtonTag;
    button.backgroundColor = UIColor.clearColor;
    button.tintColor = UIColor.whiteColor;
    button.adjustsImageWhenHighlighted = YES;
    button.accessibilityLabel = @"プロフィール情報をコピー";
    button.imageView.contentMode = UIViewContentModeScaleAspectFit;
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;

    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:21.0
                                                                                          weight:UIImageSymbolWeightRegular
                                                                                           scale:UIImageSymbolScaleMedium];
    [button setImage:[UIImage systemImageNamed:@"doc.on.doc" withConfiguration:config] forState:UIControlStateNormal];

    [button addTarget:[BHTProfileCopyTarget sharedTarget]
               action:@selector(bht_profileCopyTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:button];
    return button;
}

static NSArray<NSDictionary *> *BHTProfileActionCandidates(UIView *root) {
    if (!root || CGRectGetWidth(root.bounds) <= 0.0 || CGRectGetHeight(root.bounds) <= 0.0) return @[];
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    CGFloat rootHeight = CGRectGetHeight(root.bounds);

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && view.tag != BHTProfileCopyButtonTag && !view.hidden && view.alpha > 0.05 && view.superview) {
            BOOL isControl = [view isKindOfClass:[UIControl class]];
            NSString *className = NSStringFromClass(view.class).lowercaseString ?: @"";
            BOOL looksLikeButton = isControl || [className containsString:@"button"] || [className containsString:@"control"];
            if (looksLikeButton) {
                CGRect frame = [view.superview convertRect:view.frame toView:root];
                CGFloat width = CGRectGetWidth(frame), height = CGRectGetHeight(frame), midY = CGRectGetMidY(frame);
                BOOL actionSize = width >= 28.0 && width <= 72.0 && height >= 28.0 && height <= 72.0;
                BOOL lowerHeader = midY >= MAX(105.0, rootHeight * 0.40) && midY <= rootHeight - 4.0;
                if (actionSize && lowerHeader) [candidates addObject:@{ @"view": view, @"frame": [NSValue valueWithCGRect:frame] }];
            }
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }
    return candidates;
}

static UIView *BHTFindRightmostProfileActionControl(UIView *root) {
    NSArray<NSDictionary *> *candidates = BHTProfileActionCandidates(root);
    if (candidates.count == 0) return nil;
    CGFloat lowestMidY = -CGFLOAT_MAX;
    for (NSDictionary *candidate in candidates) lowestMidY = MAX(lowestMidY, CGRectGetMidY([candidate[@"frame"] CGRectValue]));

    UIView *best = nil;
    CGFloat bestX = -CGFLOAT_MAX;
    for (NSDictionary *candidate in candidates) {
        CGRect frame = [candidate[@"frame"] CGRectValue];
        if (fabs(CGRectGetMidY(frame) - lowestMidY) > 26.0) continue;
        if (CGRectGetMaxX(frame) > bestX) { bestX = CGRectGetMaxX(frame); best = candidate[@"view"]; }
    }
    return best;
}

static CGFloat BHTNativeIconExtent(UIView *anchor) {
    if (!anchor) return 21.0;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:anchor];
    CGFloat best = 0.0;
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if ([view isKindOfClass:[UIImageView class]] && !view.hidden && view.alpha > 0.05) {
            CGFloat extent = MAX(CGRectGetWidth(view.bounds), CGRectGetHeight(view.bounds));
            if (extent >= 12.0 && extent <= 32.0) best = MAX(best, extent);
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }
    return best > 0.0 ? best : 21.0;
}

static void BHTStyleCopyButtonLikeAnchor(UIButton *button, UIView *anchor) {
    if (!button) return;
    CGFloat diameter = 48.0;
    if (anchor) {
        CGFloat anchorSize = MIN(CGRectGetWidth(anchor.bounds), CGRectGetHeight(anchor.bounds));
        if (anchorSize >= 40.0 && anchorSize <= 68.0) diameter = anchorSize;
    }

    button.bounds = CGRectMake(0.0, 0.0, diameter, diameter);
    button.layer.cornerRadius = diameter * 0.5;
    button.layer.masksToBounds = YES;

    // Always draw the circle explicitly. X 12.16 often exposes the native
    // share control's visible ring through a subview rather than layer.borderWidth,
    // so copying the anchor layer can result in an invisible border.
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.20].CGColor;
    button.backgroundColor = UIColor.clearColor;
    button.tintColor = UIColor.whiteColor;

    CGFloat pointSize = BHTNativeIconExtent(anchor);
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                          weight:UIImageSymbolWeightRegular
                                                                                           scale:UIImageSymbolScaleMedium];
    [button setImage:[UIImage systemImageNamed:@"doc.on.doc" withConfiguration:config] forState:UIControlStateNormal];
}

static void BHTProfileHeaderLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalProfileHeaderLayoutIMP) ((BHTLayoutIMP)BHTOriginalProfileHeaderLayoutIMP)(self, _cmd);
    if (![self isKindOfClass:[UIView class]]) return;

    UIView *headerView = (UIView *)self;
    UIButton *button = (UIButton *)[headerView viewWithTag:BHTProfileCopyButtonTag];
    if (!BHTX1216CopyProfileInfoEnabled()) { [button removeFromSuperview]; return; }

    CGFloat headerWidth = CGRectGetWidth(headerView.bounds), headerHeight = CGRectGetHeight(headerView.bounds);
    if (headerWidth < 100.0 || headerHeight < 125.0) { [button removeFromSuperview]; return; }

    UIView *anchor = BHTFindRightmostProfileActionControl(headerView);
    if (!button) button = BHTEnsureCopyButton(headerView);
    if (!button) return;
    BHTStyleCopyButtonLikeAnchor(button, anchor);

    CGFloat diameter = CGRectGetWidth(button.bounds);
    const CGFloat gap = 10.0;
    CGRect targetFrame;
    if (anchor && anchor.superview) {
        CGRect anchorFrame = [anchor.superview convertRect:anchor.frame toView:headerView];
        targetFrame = CGRectMake(CGRectGetMinX(anchorFrame) - gap - diameter,
                                 CGRectGetMidY(anchorFrame) - diameter * 0.5,
                                 diameter, diameter);
    } else {
        targetFrame = CGRectMake(MAX(8.0, headerWidth - 126.0), MAX(8.0, headerHeight - diameter - 14.0), diameter, diameter);
    }

    targetFrame.origin.x = MAX(8.0, MIN(targetFrame.origin.x, MAX(8.0, headerWidth - diameter - 8.0)));
    targetFrame.origin.y = MAX(8.0, MIN(targetFrame.origin.y, MAX(8.0, headerHeight - diameter - 8.0)));
    button.frame = CGRectIntegral(targetFrame);
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [headerView bringSubviewToFront:button];
}

static void BHTInstallX1216ProfileCompat(void) {
    Class cls = NSClassFromString(@"T1ProfileHeaderView");
    SEL selector = @selector(layoutSubviews);
    Method inheritedMethod = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!cls || !inheritedMethod) return;
    const char *types = method_getTypeEncoding(inheritedMethod);
    IMP replacement = (IMP)BHTProfileHeaderLayoutSubviews;
    IMP original = method_getImplementation(inheritedMethod);
    if (class_addMethod(cls, selector, replacement, types)) { BHTOriginalProfileHeaderLayoutIMP = original; return; }
    Method ownMethod = class_getInstanceMethod(cls, selector);
    if (!ownMethod) return;
    BHTOriginalProfileHeaderLayoutIMP = method_getImplementation(ownMethod);
    method_setImplementation(ownMethod, replacement);
}

__attribute__((constructor)) static void BHTX1216ProfileCompatInit(void) {
    BHTDisableLegacyProfileCopyHook();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216ProfileCompat();
    });
}
