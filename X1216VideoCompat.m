#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// Diagnostic build: prove that our X 12.16 compatibility code can add UI to
// ordinary timeline cells and place it in the post action area.
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
        button.backgroundColor = UIColor.systemRedColor;
        button.tintColor = UIColor.whiteColor;
        button.layer.cornerRadius = 18.0;
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

    // Put the diagnostic button in the lower-right part of the post, near the
    // native reply/repost/like/bookmark/share action row. Recompute every time
    // because timeline cells have different heights depending on their media.
    const CGFloat size = 36.0;
    const CGFloat rightInset = 18.0;
    const CGFloat bottomInset = 10.0;
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

static UITableViewCell *BHTDiagnosticTableCellForItem(id self, SEL _cmd, id item, id indexPath) {
    UITableViewCell *cell = nil;
    if (BHTOriginalTableCellForItemIMP) {
        cell = ((BHTTableCellForItemIMP)BHTOriginalTableCellForItemIMP)(self, _cmd, item, indexPath);
    }

    // Intentionally unconditional for this diagnostic build. If this arrow is
    // visible, the compatibility code and timeline-cell hook are both working.
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

    NSLog(@"[BHTwitter][X12.16][TEST] Installed bottom-action-area arrow diagnostic");
}

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        BHTInstallDiagnosticTimelineHook();
    });
}
