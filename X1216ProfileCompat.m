#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"

static const NSInteger BHTProfileCopyButtonTag = 1216001;
static IMP BHTOriginalProfileHeaderLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

// X 12.16 must not execute the legacy Tweak.x profile-copy hook because it
// relies on the removed/private _innerContentView hierarchy. Keep the user's
// preference intact in NSUserDefaults, but make the legacy BHTManager gate
// return NO. This compatibility file reads the preference directly.
static BOOL BHTLegacyCopyProfileInfoDisabled(id self, SEL _cmd) {
    return NO;
}

static BOOL BHTX1216CopyProfileInfoEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:@"CopyProfileInfo"];
}

static void BHTDisableLegacyProfileCopyHook(void) {
    Class managerClass = NSClassFromString(@"BHTManager");
    SEL selector = NSSelectorFromString(@"CopyProfileInfo");
    Method method = managerClass ? class_getClassMethod(managerClass, selector) : NULL;
    if (!method) return;

    Class metaClass = object_getClass(managerClass);
    class_replaceMethod(metaClass,
                        selector,
                        (IMP)BHTLegacyCopyProfileInfoDisabled,
                        method_getTypeEncoding(method));
    NSLog(@"[BHTwitter][X12.16] Disabled legacy profile-copy implementation");
}

static UIViewController *BHTProfileHeaderControllerFromView(UIView *view) {
    UIResponder *responder = view;
    Class controllerClass = NSClassFromString(@"T1ProfileHeaderViewController");
    while (responder) {
        if (controllerClass && [responder isKindOfClass:controllerClass]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIView *BHTFindShareControlInView(UIView *root) {
    if (!root) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    UIView *fallback = nil;

    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != root && !view.hidden && view.alpha > 0.01) {
            NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
            NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";

            BOOL looksLikeShare = [label containsString:@"共有"] ||
                                  [label containsString:@"share"] ||
                                  [identifier containsString:@"share"];
            if (looksLikeShare) return view;

            CGFloat w = CGRectGetWidth(view.bounds);
            CGFloat h = CGRectGetHeight(view.bounds);
            if (!fallback && [view isKindOfClass:[UIControl class]] &&
                w >= 28.0 && w <= 56.0 && h >= 28.0 && h <= 56.0) {
                fallback = view;
            }
        }

        [stack addObjectsFromArray:view.subviews];
    }

    return fallback;
}

static NSString *BHTProfileValue(id viewModel, NSString *selectorName) {
    if (!viewModel || selectorName.length == 0) return nil;
    SEL selector = NSSelectorFromString(selectorName);
    if (![viewModel respondsToSelector:selector]) return nil;

    id value = ((id (*)(id, SEL))objc_msgSend)(viewModel, selector);
    if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) return nil;
    return (NSString *)value;
}

static void BHTShowProfileCopyMenu(UIViewController *controller, id viewModel, UIView *sourceView) {
    if (!controller || !viewModel || !controller.view.window) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"プロフィール情報をコピー"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSDictionary *> *items = @[
        @{ @"selector": @"bio",      @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_1"] ?: @"プロフィールをコピー" },
        @{ @"selector": @"username", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_2"] ?: @"ユーザー名をコピー" },
        @{ @"selector": @"fullName", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_3"] ?: @"名前をコピー" },
        @{ @"selector": @"url",      @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_4"] ?: @"URLをコピー" },
        @{ @"selector": @"location", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_5"] ?: @"場所をコピー" },
    ];

    for (NSDictionary *item in items) {
        NSString *value = BHTProfileValue(viewModel, item[@"selector"]);
        if (!value) continue;

        [alert addAction:[UIAlertAction actionWithTitle:item[@"title"]
                                                     style:UIAlertActionStyleDefault
                                                   handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = value;
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル"
                                             style:UIAlertActionStyleCancel
                                           handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: controller.view;
        popover.sourceRect = sourceView ? sourceView.bounds : controller.view.bounds;
    }

    if (!controller.presentedViewController) {
        [controller presentViewController:alert animated:YES completion:nil];
    }
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

    SEL viewModelSelector = NSSelectorFromString(@"viewModel");
    id viewModel = nil;
    if ([controller respondsToSelector:viewModelSelector]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(controller, viewModelSelector);
    }
    if (!viewModel) return;

    BHTShowProfileCopyMenu(controller, viewModel, sender);
}

@end

static UIButton *BHTEnsureCopyButton(UIView *container) {
    UIButton *button = (UIButton *)[container viewWithTag:BHTProfileCopyButtonTag];
    if (button) return button;

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTProfileCopyButtonTag;
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = UIColor.clearColor;
    button.layer.cornerRadius = 16.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.8].CGColor;

    UIImageSymbolConfiguration *config =
        [UIImageSymbolConfiguration configurationWithPointSize:15.0 weight:UIImageSymbolWeightRegular];
    UIImage *image = [UIImage systemImageNamed:@"doc.on.clipboard" withConfiguration:config];
    [button setImage:image forState:UIControlStateNormal];
    button.accessibilityLabel = @"プロフィール情報をコピー";

    [button addTarget:[BHTProfileCopyTarget sharedTarget]
               action:@selector(bht_profileCopyTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    [container addSubview:button];
    return button;
}

static void BHTProfileHeaderLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalProfileHeaderLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalProfileHeaderLayoutIMP)(self, _cmd);
    }

    if (![self isKindOfClass:[UIView class]]) return;

    SEL actionButtonsSelector = NSSelectorFromString(@"actionButtonsView");
    id actionButtonsView = nil;
    if ([self respondsToSelector:actionButtonsSelector]) {
        actionButtonsView = ((id (*)(id, SEL))objc_msgSend)(self, actionButtonsSelector);
    }
    if (![actionButtonsView isKindOfClass:[UIView class]]) return;

    UIView *container = (UIView *)actionButtonsView;
    UIButton *existing = (UIButton *)[container viewWithTag:BHTProfileCopyButtonTag];

    if (!BHTX1216CopyProfileInfoEnabled()) {
        [existing removeFromSuperview];
        return;
    }

    UIButton *button = BHTEnsureCopyButton(container);
    UIView *shareControl = BHTFindShareControlInView(container);

    // Match the compact X profile action buttons and place immediately left of Share.
    const CGFloat size = 32.0;
    const CGFloat gap = 7.0;
    CGRect targetFrame = CGRectZero;

    if (shareControl && shareControl != button) {
        CGRect shareFrame = [shareControl.superview convertRect:shareControl.frame toView:container];
        targetFrame = CGRectMake(CGRectGetMinX(shareFrame) - gap - size,
                                 CGRectGetMidY(shareFrame) - size * 0.5,
                                 size,
                                 size);
    } else {
        targetFrame = CGRectMake(MAX(0.0, CGRectGetWidth(container.bounds) - size * 2.0 - gap),
                                 MAX(0.0, (CGRectGetHeight(container.bounds) - size) * 0.5),
                                 size,
                                 size);
    }

    // Never place the button outside the action row's hit-testable area.
    targetFrame.origin.x = MAX(0.0, MIN(targetFrame.origin.x, MAX(0.0, CGRectGetWidth(container.bounds) - size)));
    targetFrame.origin.y = MAX(0.0, MIN(targetFrame.origin.y, MAX(0.0, CGRectGetHeight(container.bounds) - size)));

    button.frame = CGRectIntegral(targetFrame);
    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [container bringSubviewToFront:button];
}

static void BHTInstallX1216ProfileCompat(void) {
    Class cls = NSClassFromString(@"T1ProfileHeaderView");
    SEL selector = @selector(layoutSubviews);
    Method inheritedMethod = cls ? class_getInstanceMethod(cls, selector) : NULL;

    if (!cls || !inheritedMethod) {
        NSLog(@"[BHTwitter][X12.16] Could not install profile layout hook");
        return;
    }

    const char *types = method_getTypeEncoding(inheritedMethod);
    IMP replacement = (IMP)BHTProfileHeaderLayoutSubviews;
    BHTOriginalProfileHeaderLayoutIMP = method_getImplementation(inheritedMethod);

    // If layoutSubviews is inherited, add an override only to T1ProfileHeaderView.
    if (class_addMethod(cls, selector, replacement, types)) {
        NSLog(@"[BHTwitter][X12.16] Added safe profile layout override");
        return;
    }

    // Otherwise T1ProfileHeaderView owns it, so replacing that method is local/safe.
    Method ownMethod = class_getInstanceMethod(cls, selector);
    if (!ownMethod) return;
    BHTOriginalProfileHeaderLayoutIMP = method_getImplementation(ownMethod);
    method_setImplementation(ownMethod, replacement);
    NSLog(@"[BHTwitter][X12.16] Replaced owned profile layout implementation");
}

__attribute__((constructor)) static void BHTX1216ProfileCompatInit(void) {
    // Disable the legacy hook immediately so a fast profile navigation cannot hit it.
    BHTDisableLegacyProfileCopyHook();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216ProfileCompat();
    });
}
