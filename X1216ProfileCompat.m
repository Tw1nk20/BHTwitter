#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"

static const NSInteger BHTProfileCopyButtonTag = 1216001;

static UIViewController *BHTNearestViewController(UIResponder *start) {
    UIResponder *responder = start;
    while (responder) {
        if ([responder isKindOfClass:[UIViewController class]]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return nil;
}

static UIViewController *BHTProfileHeaderControllerFromView(UIView *view) {
    UIResponder *responder = view;
    while (responder) {
        if ([responder isKindOfClass:NSClassFromString(@"T1ProfileHeaderViewController")]) {
            return (UIViewController *)responder;
        }
        responder = responder.nextResponder;
    }
    return BHTNearestViewController(view);
}

static void BHTShowProfileCopyMenu(UIViewController *controller, id viewModel, UIView *sourceView) {
    if (!controller || !viewModel) return;

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
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            UIPasteboard.generalPasteboard.string = value;
        }]];
    }

    [alert addAction:[UIAlertAction actionWithTitle:@"キャンセル" style:UIAlertActionStyleCancel handler:nil]];

    UIPopoverPresentationController *popover = alert.popoverPresentationController;
    if (popover) {
        popover.sourceView = sourceView ?: controller.view;
        popover.sourceRect = sourceView ? sourceView.bounds : CGRectMake(CGRectGetMidX(controller.view.bounds), CGRectGetMidY(controller.view.bounds), 1, 1);
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
    id viewModel = nil;

    if (controller && [controller respondsToSelector:NSSelectorFromString(@"viewModel")]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"viewModel"));
    }

    if (!viewModel) {
        UIResponder *responder = sender.nextResponder;
        while (responder) {
            if ([responder respondsToSelector:NSSelectorFromString(@"viewModel")]) {
                viewModel = ((id (*)(id, SEL))objc_msgSend)(responder, NSSelectorFromString(@"viewModel"));
                if (viewModel) break;
            }
            responder = responder.nextResponder;
        }
    }

    BHTShowProfileCopyMenu(controller, viewModel, sender);
}
@end

static IMP BHTOriginalProfileHeaderLayoutIMP = NULL;
typedef void (*BHTLayoutIMP)(id, SEL);

static void BHTProfileHeaderLayoutSubviews(id self, SEL _cmd) {
    if (BHTOriginalProfileHeaderLayoutIMP) {
        ((BHTLayoutIMP)BHTOriginalProfileHeaderLayoutIMP)(self, _cmd);
    }

    if (![BHTManager CopyProfileInfo]) return;
    if (![self isKindOfClass:[UIView class]]) return;

    UIView *headerView = (UIView *)self;
    UIButton *button = (UIButton *)[headerView viewWithTag:BHTProfileCopyButtonTag];

    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = BHTProfileCopyButtonTag;
        button.tintColor = UIColor.labelColor;
        button.backgroundColor = [UIColor.systemBackgroundColor colorWithAlphaComponent:0.92];
        button.layer.cornerRadius = 17.0;
        button.layer.borderWidth = 1.0;
        button.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
        [button setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
        [button addTarget:[BHTProfileCopyTarget sharedTarget]
                   action:@selector(bht_profileCopyTapped:)
         forControlEvents:UIControlEventTouchUpInside];
        [headerView addSubview:button];
        NSLog(@"[BHTwitter][X12.16] Added direct profile-header copy button");
    }

    // Place it directly on the profile header, to the left of the existing
    // top-right profile action cluster. This avoids actionButtonsView internals.
    CGFloat size = 34.0;
    CGFloat rightInset = 58.0;
    CGFloat topInset = 12.0;
    button.frame = CGRectMake(MAX(8.0, CGRectGetWidth(headerView.bounds) - rightInset - size),
                              topInset,
                              size,
                              size);
    [headerView bringSubviewToFront:button];
}

static void BHTInstallX1216ProfileCompat(void) {
    Class cls = NSClassFromString(@"T1ProfileHeaderView");
    SEL selector = @selector(layoutSubviews);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;

    if (!method) {
        NSLog(@"[BHTwitter][X12.16] Could not hook T1ProfileHeaderView layoutSubviews");
        return;
    }

    IMP current = method_getImplementation(method);
    IMP replacement = (IMP)BHTProfileHeaderLayoutSubviews;
    if (current == replacement) return;

    BHTOriginalProfileHeaderLayoutIMP = current;
    method_setImplementation(method, replacement);
    NSLog(@"[BHTwitter][X12.16] Installed direct profile-header copy fallback");
}

__attribute__((constructor)) static void BHTX1216ProfileCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216ProfileCompat();
    });
}
