#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"

static const NSInteger BHTProfileCopyButtonTag = 1216001;
static IMP BHTOriginalProfileHeaderLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

static UIViewController *BHTProfileHeaderControllerFromView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:NSClassFromString(@"T1ProfileHeaderViewController")]) {
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

            if (looksLikeShare) {
                return view;
            }

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

    [controller presentViewController:alert animated:YES completion:nil];
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

    id viewModel = nil;
    if ([controller respondsToSelector:NSSelectorFromString(@"viewModel")]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"viewModel"));
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
    button.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.92];
    button.layer.cornerRadius = 20.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
    [button setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
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
    UIView *headerView = (UIView *)self;

    id actionButtonsView = nil;
    SEL actionButtonsSelector = NSSelectorFromString(@"actionButtonsView");
    if ([self respondsToSelector:actionButtonsSelector]) {
        actionButtonsView = ((id (*)(id, SEL))objc_msgSend)(self, actionButtonsSelector);
    }

    if (![actionButtonsView isKindOfClass:[UIView class]]) return;
    UIView *container = (UIView *)actionButtonsView;

    UIButton *existing = (UIButton *)[container viewWithTag:BHTProfileCopyButtonTag];
    if (![BHTManager CopyProfileInfo]) {
        [existing removeFromSuperview];
        return;
    }

    UIButton *button = BHTEnsureCopyButton(container);
    if (!button) return;

    CGFloat size = 40.0;
    CGFloat gap = 8.0;
    UIView *shareControl = BHTFindShareControlInView(container);

    CGRect targetFrame;
    if (shareControl && shareControl != button) {
        CGRect shareFrame = [shareControl.superview convertRect:shareControl.frame toView:container];
        targetFrame = CGRectMake(CGRectGetMinX(shareFrame) - gap - size,
                                 CGRectGetMidY(shareFrame) - size / 2.0,
                                 size,
                                 size);
    } else {
        targetFrame = CGRectMake(MAX(8.0, CGRectGetWidth(container.bounds) - (size * 2.0) - gap - 8.0),
                                 0.0,
                                 size,
                                 size);
    }

    // Keep the button entirely inside the actionButtonsView's interactive bounds.
    targetFrame.origin.x = MAX(0.0, MIN(targetFrame.origin.x, CGRectGetWidth(container.bounds) - size));
    targetFrame.origin.y = MAX(0.0, MIN(targetFrame.origin.y, CGRectGetHeight(container.bounds) - size));
    button.frame = CGRectIntegral(targetFrame);
    button.hidden = NO;
    button.userInteractionEnabled = YES;
    [container bringSubviewToFront:button];
}

static void BHTInstallX1216ProfileCompat(void) {
    Class cls = NSClassFromString(@"T1ProfileHeaderView");
    SEL selector = @selector(layoutSubviews);
    Method inheritedMethod = cls ? class_getInstanceMethod(cls, selector) : NULL;

    if (!cls || !inheritedMethod) {
        NSLog(@"[BHTwitter][X12.16] Could not install safe T1ProfileHeaderView layout hook");
        return;
    }

    const char *types = method_getTypeEncoding(inheritedMethod);
    IMP replacement = (IMP)BHTProfileHeaderLayoutSubviews;
    BHTOriginalProfileHeaderLayoutIMP = method_getImplementation(inheritedMethod);

    // First try to add a class-local override. If layoutSubviews is inherited,
    // this is the safe path and leaves UIView's implementation untouched.
    if (class_addMethod(cls, selector, replacement, types)) {
        NSLog(@"[BHTwitter][X12.16] Added class-local profile layout override");
        return;
    }

    // The class already owns layoutSubviews, so replacing that method is safe.
    Method ownMethod = class_getInstanceMethod(cls, selector);
    if (!ownMethod) return;

    BHTOriginalProfileHeaderLayoutIMP = method_getImplementation(ownMethod);
    method_setImplementation(ownMethod, replacement);
    NSLog(@"[BHTwitter][X12.16] Replaced owned profile layout implementation");
}

__attribute__((constructor)) static void BHTX1216ProfileCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216ProfileCompat();
    });
}
