#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "BHTManager.h"
#import "BHTBundle/BHTBundle.h"

static IMP BHTOriginalProfileViewDidAppearIMP = NULL;
static const NSInteger BHTProfileCopyButtonTag = 1216001;

typedef void (*BHTProfileViewDidAppearIMP)(id, SEL, BOOL);

static void BHTShowProfileCopyMenu(id controller, id viewModel) {
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

    if ([controller isKindOfClass:[UIViewController class]]) {
        UIViewController *vc = (UIViewController *)controller;
        UIPopoverPresentationController *popover = alert.popoverPresentationController;
        if (popover) {
            popover.sourceView = vc.view;
            popover.sourceRect = CGRectMake(CGRectGetMidX(vc.view.bounds), CGRectGetMidY(vc.view.bounds), 1, 1);
        }
        [vc presentViewController:alert animated:YES completion:nil];
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
    UIViewController *controller = nil;
    UIResponder *responder = sender;
    while (responder) {
        responder = responder.nextResponder;
        if ([responder isKindOfClass:NSClassFromString(@"T1ProfileHeaderViewController")]) {
            controller = (UIViewController *)responder;
            break;
        }
    }

    if (!controller) {
        UIResponder *next = sender.nextResponder;
        while (next) {
            if ([next isKindOfClass:[UIViewController class]]) {
                controller = (UIViewController *)next;
                break;
            }
            next = next.nextResponder;
        }
    }

    id viewModel = nil;
    if (controller && [controller respondsToSelector:NSSelectorFromString(@"viewModel")]) {
        viewModel = ((id (*)(id, SEL))objc_msgSend)(controller, NSSelectorFromString(@"viewModel"));
    }

    BHTShowProfileCopyMenu(controller, viewModel);
}
@end

static void BHTX1216ProfileViewDidAppear(id self, SEL _cmd, BOOL animated) {
    if (BHTOriginalProfileViewDidAppearIMP) {
        ((BHTProfileViewDidAppearIMP)BHTOriginalProfileViewDidAppearIMP)(self, _cmd, animated);
    }

    if (![BHTManager CopyProfileInfo]) return;
    if (![self isKindOfClass:[UIViewController class]]) return;

    UIViewController *controller = (UIViewController *)self;
    UIView *rootView = controller.view;
    if (!rootView || [rootView viewWithTag:BHTProfileCopyButtonTag]) return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tag = BHTProfileCopyButtonTag;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.tintColor = UIColor.labelColor;
    button.backgroundColor = UIColor.systemBackgroundColor;
    button.layer.cornerRadius = 17.0;
    button.layer.borderWidth = 1.0;
    button.layer.borderColor = [UIColor.separatorColor colorWithAlphaComponent:0.7].CGColor;
    [button setImage:[UIImage systemImageNamed:@"doc.on.clipboard"] forState:UIControlStateNormal];
    [button addTarget:[BHTProfileCopyTarget sharedTarget]
               action:@selector(bht_profileCopyTapped:)
     forControlEvents:UIControlEventTouchUpInside];

    // Attach directly to the current profile controller's root view instead of
    // depending on the old actionButtonsView/_innerContentView hierarchy.
    [rootView addSubview:button];
    [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor constraintEqualToAnchor:rootView.safeAreaLayoutGuide.trailingAnchor constant:-12.0],
        [button.topAnchor constraintEqualToAnchor:rootView.safeAreaLayoutGuide.topAnchor constant:8.0],
        [button.widthAnchor constraintEqualToConstant:34.0],
        [button.heightAnchor constraintEqualToConstant:34.0],
    ]];

    NSLog(@"[BHTwitter][X12.16] Added profile copy fallback button");
}

static void BHTInstallX1216ProfileCompat(void) {
    Class cls = NSClassFromString(@"T1ProfileHeaderViewController");
    SEL selector = @selector(viewDidAppear:);
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method) {
        NSLog(@"[BHTwitter][X12.16] Could not find T1ProfileHeaderViewController viewDidAppear:");
        return;
    }

    IMP current = method_getImplementation(method);
    IMP replacement = (IMP)BHTX1216ProfileViewDidAppear;
    if (current == replacement) return;

    BHTOriginalProfileViewDidAppearIMP = current;
    method_setImplementation(method, replacement);
    NSLog(@"[BHTwitter][X12.16] Installed profile copy UI fallback");
}

__attribute__((constructor)) static void BHTX1216ProfileCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallX1216ProfileCompat();
    });
}
