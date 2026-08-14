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
        [alert addAction:[UIAlertAction actionWithTitle:item[@"title"]
                                                  style:UIAlertActionStyleDefault
                                                handler:^(__unused UIAlertAction *action) {
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

static BOOL BHTStringLooksLikeCopy(NSString *value) {
    NSString *s = value.lowercaseString ?: @"";
    return [s containsString:@"copy"] || [s containsString:@"コピー"] || [s containsString:@"profilecopy"];
}

static BOOL BHTStringLooksLikeShare(NSString *value) {
    NSString *s = value.lowercaseString ?: @"";
    return [s containsString:@"share"] || [s containsString:@"共有"] || [s containsString:@"シェア"];
}

static void BHTHideLegacyProfileCopyControls(UIView *root) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && view.tag != BHTProfileCopyButtonTag) {
            NSString *className = NSStringFromClass(view.class);
            if (BHTStringLooksLikeCopy(view.accessibilityLabel) ||
                BHTStringLooksLikeCopy(view.accessibilityIdentifier) ||
                BHTStringLooksLikeCopy(className)) {
                view.hidden = YES;
                view.userInteractionEnabled = NO;
                continue;
            }
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
    }
}

static UIView *BHTFindNativeShareControl(UIView *root) {
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    UIView *best = nil;
    CGFloat bestX = -CGFLOAT_MAX;
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];
        if (view != root && view.tag != BHTProfileCopyButtonTag && !view.hidden && view.alpha > 0.05 && view.superview) {
            NSString *className = NSStringFromClass(view.class);
            BOOL looksShare = BHTStringLooksLikeShare(view.accessibilityLabel) ||
                              BHTStringLooksLikeShare(view.accessibilityIdentifier) ||
                              BHTStringLooksLikeShare(className);
            if (looksShare) {
                CGRect frame = [view convertRect:view.bounds toView:root];
                CGFloat w = CGRectGetWidth(frame), h = CGRectGetHeight(frame);
                if (w >= 30.0 && w <= 72.0 && h >= 30.0 && h <= 72.0 && CGRectGetMaxX(frame) > bestX) {
                    best = view;
                    bestX = CGRectGetMaxX(frame);
                }
            }
        }
        if (view.subviews.count) [stack addObjectsFromArray:view.subviews];
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
    [button addTarget:[BHTProfileCopyTarget sharedTarget]
               action:@selector(bht_profileCopyTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:button];
    return button;
}

static void BHTStyleCopyButtonLikeShare(UIButton *button, UIView *share) {
    CGFloat diameter = 48.0;
    CGFloat borderWidth = 1.0 / UIScreen.mainScreen.scale;
    UIColor *borderColor = [UIColor colorWithWhite:1.0 alpha:0.18];
    if (share) {
        CGFloat s = MIN(CGRectGetWidth(share.bounds), CGRectGetHeight(share.bounds));
        if (s >= 40.0 && s <= 68.0) diameter = s;
        if (share.layer.borderWidth > 0.0) borderWidth = share.layer.borderWidth;
        if (share.layer.borderColor) borderColor = [UIColor colorWithCGColor:share.layer.borderColor];
    }

    button.bounds = CGRectMake(0, 0, diameter, diameter);
    button.layer.cornerRadius = diameter * 0.5;
    button.layer.masksToBounds = YES;
    button.layer.borderWidth = borderWidth;
    button.layer.borderColor = borderColor.CGColor;
    button.tintColor = UIColor.whiteColor;

    CGFloat pointSize = BHTNativeIconExtent(share);
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize
                                                                                          weight:UIImageSymbolWeightRegular
                                                                                           scale:UIImageSymbolScaleMedium];
    UIImage *image = [UIImage systemImageNamed:@"doc.on.doc" withConfiguration:config];
    [button setImage:image forState:UIControlStateNormal];
}

static void BHTProfileHeaderLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalProfileHeaderLayoutIMP) ((BHTLayoutIMP)BHTOriginalProfileHeaderLayoutIMP)(self, _cmd);
    if (![self isKindOfClass:[UIView class]]) return;

    UIView *headerView = (UIView *)self;
    UIButton *button = (UIButton *)[headerView viewWithTag:BHTProfileCopyButtonTag];
    if (!BHTX1216CopyProfileInfoEnabled()) {
        [button removeFromSuperview];
        return;
    }

    CGFloat headerWidth = CGRectGetWidth(headerView.bounds);
    CGFloat headerHeight = CGRectGetHeight(headerView.bounds);
    if (headerWidth < 100.0 || headerHeight < 125.0) return;

    BHTHideLegacyProfileCopyControls(headerView);
    UIView *share = BHTFindNativeShareControl(headerView);
    if (!button) button = BHTEnsureCopyButton(headerView);
    if (!button) return;
    BHTStyleCopyButtonLikeShare(button, share);

    CGFloat diameter = CGRectGetWidth(button.bounds);
    const CGFloat gap = 10.0;
    CGRect targetFrame;
    if (share && share.superview) {
        CGRect shareFrame = [share convertRect:share.bounds toView:headerView];
        targetFrame = CGRectMake(CGRectGetMinX(shareFrame) - gap - diameter,
                                 CGRectGetMidY(shareFrame) - diameter * 0.5,
                                 diameter,
                                 diameter);
    } else {
        targetFrame = CGRectMake(MAX(8.0, headerWidth - 126.0),
                                 MAX(8.0, headerHeight - diameter - 14.0),
                                 diameter,
                                 diameter);
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
    if (class_addMethod(cls, selector, replacement, types)) {
        BHTOriginalProfileHeaderLayoutIMP = original;
        return;
    }
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
