#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Diagnostic build: prove that our X 12.16 compatibility code can add UI to
// ordinary timeline cells before spending more time on video/share detection.
static const NSInteger BHTDiagnosticArrowTag = 1216099;
static IMP BHTOriginalTableCellForItemIMP = NULL;

typedef UITableViewCell *(*BHTTableCellForItemIMP)(id, SEL, id, id);

@interface BHTDiagnosticArrowTarget : NSObject
@end

@implementation BHTDiagnosticArrowTarget
+ (instancetype)sharedTarget {
    static BHTDiagnosticArrowTarget *target;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ target = [BHTDiagnosticArrowTarget new]; });
    return target;
}

- (void)bht_diagnosticArrowTapped:(UIButton *)sender {
    UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) {
        top = ((UINavigationController *)top).visibleViewController;
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"BHTwitter Test"
                                                                   message:@"テスト矢印の表示・タップに成功しました。"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}
@end

static void BHTAddDiagnosticArrowToCell(UITableViewCell *cell) {
    if (!cell) return;

    UIView *host = cell.contentView ?: cell;
    UIButton *button = (UIButton *)[host viewWithTag:BHTDiagnosticArrowTag];
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.tag = BHTDiagnosticArrowTag;
        button.frame = CGRectMake(8.0, 8.0, 42.0, 42.0);
        button.autoresizingMask = UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleBottomMargin;
        button.backgroundColor = UIColor.systemRedColor;
        button.tintColor = UIColor.whiteColor;
        button.layer.cornerRadius = 21.0;
        button.layer.borderWidth = 2.0;
        button.layer.borderColor = UIColor.whiteColor.CGColor;
        button.accessibilityLabel = @"BHTwitter テスト矢印";

        UIImage *image = [UIImage systemImageNamed:@"arrow.down"];
        [button setImage:image forState:UIControlStateNormal];
        [button addTarget:[BHTDiagnosticArrowTarget sharedTarget]
                   action:@selector(bht_diagnosticArrowTapped:)
         forControlEvents:UIControlEventTouchUpInside];

        [host addSubview:button];
        NSLog(@"[BHTwitter][X12.16][TEST] Added diagnostic arrow to %@", NSStringFromClass([cell class]));
    }

    button.hidden = NO;
    button.alpha = 1.0;
    button.userInteractionEnabled = YES;
    [host bringSubviewToFront:button];
}

static UITableViewCell *BHTDiagnosticTableCellForItem(id self, SEL _cmd, id item, id indexPath) {
    UITableViewCell *cell = nil;
    if (BHTOriginalTableCellForItemIMP) {
        cell = ((BHTTableCellForItemIMP)BHTOriginalTableCellForItemIMP)(self, _cmd, item, indexPath);
    }

    // Intentionally unconditional for this diagnostic build. If this arrow is
    // visible, the compatibility dylib and timeline-cell hook are both working.
    BHTAddDiagnosticArrowToCell(cell);
    return cell;
}

static void BHTInstallDiagnosticTimelineHook(void) {
    Class cls = NSClassFromString(@"TFNItemsDataViewController");
    SEL selector = NSSelectorFromString(@"tableViewCellForItem:atIndexPath:");
    if (!cls) {
        NSLog(@"[BHTwitter][X12.16][TEST] TFNItemsDataViewController not found");
        return;
    }

    Method method = class_getInstanceMethod(cls, selector);
    if (!method) {
        NSLog(@"[BHTwitter][X12.16][TEST] tableViewCellForItem:atIndexPath: not found");
        return;
    }

    IMP current = method_getImplementation(method);
    const char *types = method_getTypeEncoding(method);
    BHTOriginalTableCellForItemIMP = current;

    // Add a class-local override if the method is inherited; otherwise replace
    // only TFNItemsDataViewController's own implementation. The captured IMP
    // already includes BHTwitter's existing Logos hook, so normal behavior is kept.
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
        method_setImplementation(ownMethod, (IMP)BHTDiagnosticTableCellForItem);
    } else {
        class_addMethod(cls, selector, (IMP)BHTDiagnosticTableCellForItem, types);
    }

    NSLog(@"[BHTwitter][X12.16][TEST] Installed unconditional timeline arrow diagnostic");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallDiagnosticTimelineHook();
    });
}
