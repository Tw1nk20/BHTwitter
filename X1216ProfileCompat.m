#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"

static const NSInteger BHTProfileCopyButtonTag = 1216001;
static IMP BHTOriginalProfileHeaderLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

// Prevent the legacy Logos profile-copy hook from executing on X 12.16.
// The compatibility implementation below reads the preference directly.
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
}

static UIViewController *BHTProfileHeaderControllerFromView(UIView *view) {
    UIResponder *responder = view;
    Class cls = NSClassFromString(@"T1ProfileHeaderViewController");
    while (responder) {
        if (cls && [responder isKindOfClass:cls]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIView *BHTFindShareControlInView(UIView *root) {
    if (!root) return nil;

    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *view = stack.lastObject;
        [stack removeLastObject];

        if (view != root && view.tag != BHTProfileCopyButtonTag && !view.hidden && view.alpha > 0.01) {
            NSString *label = view.accessibilityLabel.lowercaseString ?: @"";
            NSString *identifier = view.accessibilityIdentifier.lowercaseString ?: @"";
            if ([label containsString:@"共有"] ||
                [label containsString:@"share"] ||
                [identifier containsString:@"share"]) {
                return view;
            }
        }

        [stack addObjectsFromArray:view.subviews];
    }
    return nil;
}

static void BHTShowProfileCopyMenu(UIViewController *controller, id viewModel, UIView *sourceView) {
    if (!controller || !viewModel || !controller.view.window) return;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"プロフィール情報をコピー"
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    NSArray<NSDictionary *> *items = @[
        @{ @"selector": @"bio",      @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_1"] ?: @"自己紹介" },
        @{ @"selector": @"username", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_2"] ?: @"ユーザー名" },
        @{ @"selector": @"fullName", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_3"] ?: @"表示名" },
        @{ @"selector": @"url",      @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_4"] ?: @"URL" },
        @{ @"selector": @"location", @"title": [[BHTBundle sharedBundle] localizedStringForKey:@"COPY_PROFILE_INFO_MENU_OPTION_5"] ?: @"場所" },
    ];

    for (NSDictionary *item in items) {
        SEL selector = NSSelectorFromString(item[@"selector"]);
        if (![viewModel respondsToSelector:selector]) continue;

        id value = ((id (*)(id, SEL))objc_msgSend)(viewModel, selector);
        if (![value isKindOfClass:[NSString class]] || [(NSString *)value length] == 0) continue;

        NSString *title = item[@"title"];
        [alert addAction:[UIAlertAction actionWithTitle:title
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

    SEL selector = NSSelectorFromString(@"viewModel");
    id viewModel = nil;
    if ([controller respondsToSelector:selector]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(controller, selector);
    }
    if (!viewModel) return;

    BHTShowProfileCopyMenu(controller, viewModel, sender);
}

@end

static UIButton *BHTEnsureCopyButton(UIView *headerView) {
    UIButton *button = (UIButton *)[headerView viewWithTag:BHTProfileCopyButtonTag];
    if (button) return button;

    button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTProfileCopyButtonTag;
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.92];
    button.layer.cornerRadius = 18.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
    [button setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
    button.accessibilityLabel = @"プロフィール情報をコピー";
    [button addTarget:[BHTProfileCopyTarget sharedTarget]
               action:@selector(bht_profileCopyTapped:)
     forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:button];
    return button;
}

static void BHTProfileHeaderLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalProfileHeaderLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalProfileHeaderLayoutIMP)(self, _cmd);
    }

    if (![self isKindOfClass:[UIView class]]) return;
    UIView *headerView = (UIView *)self;

    UIButton *existing = (UIButton *)[headerView viewWithTag:BHTProfileCopyButtonTag];
    if (!BHTX1216CopyProfileInfoEnabled()) {
        [existing removeFromSuperview];
        return;
    }

    UIButton *button = BHTEnsureCopyButton(headerView);
    if (!button) return;

    const CGFloat size = 36.0;
    const CGFloat gap = 8.0;
    UIView *shareControl = BHTFindShareControlInView(headerView);
    CGRect targetFrame = CGRectZero;

    if (shareControl && shareControl != button && shareControl.superview) {
        CGRect shareFrame = [shareControl.superview convertRect:shareControl.frame toView:headerView];
        targetFrame = CGRectMake(CGRectGetMinX(shareFrame) - gap - size,
                                 CGRectGetMidY(shareFrame) - size * 0.5,
                                 size,
                                 size);
    } else {
        // Safe fallback matching the previously visible X 12.16 header position.
        targetFrame = CGRectMake(MAX(8.0, CGRectGetWidth(headerView.bounds) - 74.0 - size),
                                 58.0,
                                 size,
                                 size);
    }

    targetFrame.origin.x = MAX(4.0, MIN(targetFrame.origin.x,
                                        MAX(4.0, CGRectGetWidth(headerView.bounds) - size - 4.0)));
    targetFrame.origin.y = MAX(4.0, MIN(targetFrame.origin.y,
                                        MAX(4.0, CGRectGetHeight(headerView.bounds) - size - 4.0)));

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
    BHTOriginalProfileHeaderLayoutIMP = method_getImplementation(inheritedMethod);

    if (class_addMethod(cls, selector, replacement, types)) return;

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
