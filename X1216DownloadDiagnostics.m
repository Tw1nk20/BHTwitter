#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

static IMP BHTOriginalDiagnosticTapIMP = NULL;
typedef void (*BHTTapIMP)(id, SEL, UIButton *);

static UIView *BHTDiagFindActionsView(UIView *root) {
    if (!root) return nil;
    Class tta = NSClassFromString(@"TTAStatusInlineActionsView");
    Class t1 = NSClassFromString(@"T1StatusInlineActionsView");
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:root];
    while (stack.count) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        if ((tta && [v isKindOfClass:tta]) || (t1 && [v isKindOfClass:t1])) return v;
        [stack addObjectsFromArray:v.subviews];
    }
    return nil;
}

static id BHTDiagViewModelForSender(UIButton *sender) {
    UIResponder *r = sender;
    UITableViewCell *cell = nil;
    while (r) {
        if ([r isKindOfClass:[UITableViewCell class]]) { cell = (UITableViewCell *)r; break; }
        r = r.nextResponder;
    }
    if (!cell) return nil;
    UIView *actionsView = BHTDiagFindActionsView(cell);
    SEL sel = NSSelectorFromString(@"viewModel");
    if (actionsView && [actionsView respondsToSelector:sel]) {
        return ((id (*)(id, SEL))objc_msgSend)(actionsView, sel);
    }
    return nil;
}

static NSString *BHTYesNo(BOOL value) { return value ? @"YES" : @"NO"; }

static void BHTAppendClassProbe(NSMutableString *report, NSString *className, NSArray<NSString *> *instanceSelectors, NSArray<NSString *> *classSelectors) {
    Class cls = NSClassFromString(className);
    [report appendFormat:@"\n[%@] class=%@", className, BHTYesNo(cls != Nil)];
    if (!cls) return;
    for (NSString *name in classSelectors) {
        SEL sel = NSSelectorFromString(name);
        [report appendFormat:@"\n  +%@=%@", name, BHTYesNo([cls respondsToSelector:sel])];
    }
    for (NSString *name in instanceSelectors) {
        SEL sel = NSSelectorFromString(name);
        [report appendFormat:@"\n  -%@=%@", name, BHTYesNo(class_getInstanceMethod(cls, sel) != NULL)];
    }
}

static void BHTDiagnosticTap(id self, SEL _cmd, UIButton *sender) {
    NSMutableString *report = [NSMutableString stringWithString:@"BHTwitter X 12.16 download diagnostics\n"];

    BHTAppendClassProbe(report, @"TAEStandardFontGroup", @[@"headline2BoldFont"], @[@"sharedFontGroup"]);
    BHTAppendClassProbe(report, @"TFNAttributedTextModel", @[@"initWithAttributedString:"], @[]);
    BHTAppendClassProbe(report, @"TFNActiveTextItem", @[@"initWithTextModel:activeRanges:"], @[]);
    BHTAppendClassProbe(report, @"TFNActionItem", @[], @[@"actionItemWithTitle:imageName:action:"]);
    BHTAppendClassProbe(report, @"TFNMenuSheetViewController", @[@"initWithActionItems:", @"tfnPresentedCustomPresentFromViewController:animated:completion:"], @[]);

    [report appendString:@"\n\n[Construction probe]"];
    @try {
        Class fontClass = NSClassFromString(@"TAEStandardFontGroup");
        id group = nil;
        if (fontClass && [fontClass respondsToSelector:NSSelectorFromString(@"sharedFontGroup")]) {
            group = ((id (*)(id, SEL))objc_msgSend)(fontClass, NSSelectorFromString(@"sharedFontGroup"));
        }
        [report appendFormat:@"\nfontGroup=%@", group ? @"OK" : @"nil"];

        id font = nil;
        if (group && [group respondsToSelector:NSSelectorFromString(@"headline2BoldFont")]) {
            font = ((id (*)(id, SEL))objc_msgSend)(group, NSSelectorFromString(@"headline2BoldFont"));
        }
        [report appendFormat:@"\nheadline2BoldFont=%@", font ? @"OK" : @"nil"];

        if (font) {
            NSDictionary *attrs = @{ NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.labelColor };
            NSAttributedString *attr = [[NSAttributedString alloc] initWithString:@"Download" attributes:attrs];
            [report appendFormat:@"\nattributedString=%@", attr ? @"OK" : @"nil"];

            Class modelClass = NSClassFromString(@"TFNAttributedTextModel");
            id model = nil;
            SEL modelInitSEL = NSSelectorFromString(@"initWithAttributedString:");
            if (modelClass && class_getInstanceMethod(modelClass, modelInitSEL)) {
                id allocated = ((id (*)(id, SEL))objc_msgSend)(modelClass, @selector(alloc));
                model = ((id (*)(id, SEL, id))objc_msgSend)(allocated, modelInitSEL, attr);
            }
            [report appendFormat:@"\ntextModel=%@", model ? @"OK" : @"nil"];

            Class activeClass = NSClassFromString(@"TFNActiveTextItem");
            id active = nil;
            SEL activeInitSEL = NSSelectorFromString(@"initWithTextModel:activeRanges:");
            if (activeClass && class_getInstanceMethod(activeClass, activeInitSEL)) {
                id allocated = ((id (*)(id, SEL))objc_msgSend)(activeClass, @selector(alloc));
                active = ((id (*)(id, SEL, id, id))objc_msgSend)(allocated, activeInitSEL, model, nil);
            }
            [report appendFormat:@"\nactiveTextItem=%@", active ? @"OK" : @"nil"];

            if (active) {
                Class sheetClass = NSClassFromString(@"TFNMenuSheetViewController");
                id sheet = nil;
                SEL sheetInitSEL = NSSelectorFromString(@"initWithActionItems:");
                if (sheetClass && class_getInstanceMethod(sheetClass, sheetInitSEL)) {
                    id allocated = ((id (*)(id, SEL))objc_msgSend)(sheetClass, @selector(alloc));
                    sheet = ((id (*)(id, SEL, id))objc_msgSend)(allocated, sheetInitSEL, @[active]);
                }
                [report appendFormat:@"\nmenuSheetInit=%@", sheet ? @"OK" : @"nil"];
            }
        }
    } @catch (NSException *ex) {
        [report appendFormat:@"\nCONSTRUCTION EXCEPTION\n%@\n%@", ex.name ?: @"(no name)", ex.reason ?: @"(no reason)"];
    }

    [report appendString:@"\n\n[Media probe]"];
    id viewModel = BHTDiagViewModelForSender(sender);
    [report appendFormat:@"\nviewModel=%@", viewModel ? NSStringFromClass([viewModel class]) : @"nil"];
    @try {
        SEL representedSEL = NSSelectorFromString(@"representedMediaEntities");
        id mediaEntities = nil;
        if (viewModel && [viewModel respondsToSelector:representedSEL]) {
            mediaEntities = ((id (*)(id, SEL))objc_msgSend)(viewModel, representedSEL);
        }
        NSUInteger mediaCount = [mediaEntities isKindOfClass:[NSArray class]] ? [(NSArray *)mediaEntities count] : 0;
        [report appendFormat:@"\nrepresentedMediaEntities=%lu", (unsigned long)mediaCount];

        NSUInteger totalVariants = 0;
        NSUInteger mp4 = 0;
        NSUInteger hls = 0;
        for (id media in ([mediaEntities isKindOfClass:[NSArray class]] ? (NSArray *)mediaEntities : @[])) {
            id videoInfo = nil;
            SEL viSEL = NSSelectorFromString(@"videoInfo");
            if ([media respondsToSelector:viSEL]) videoInfo = ((id (*)(id, SEL))objc_msgSend)(media, viSEL);
            id variants = nil;
            SEL variantsSEL = NSSelectorFromString(@"variants");
            if (videoInfo && [videoInfo respondsToSelector:variantsSEL]) variants = ((id (*)(id, SEL))objc_msgSend)(videoInfo, variantsSEL);
            if ([variants isKindOfClass:[NSArray class]]) {
                totalVariants += [(NSArray *)variants count];
                for (id variant in (NSArray *)variants) {
                    NSString *contentType = nil;
                    SEL ctSEL = NSSelectorFromString(@"contentType");
                    if ([variant respondsToSelector:ctSEL]) contentType = ((id (*)(id, SEL))objc_msgSend)(variant, ctSEL);
                    if ([contentType isEqualToString:@"video/mp4"]) mp4++;
                    if ([contentType isEqualToString:@"application/x-mpegURL"]) hls++;
                }
            }
        }
        [report appendFormat:@"\nvariants=%lu mp4=%lu hls=%lu", (unsigned long)totalVariants, (unsigned long)mp4, (unsigned long)hls];
    } @catch (NSException *ex) {
        [report appendFormat:@"\nMEDIA EXCEPTION\n%@\n%@", ex.name ?: @"(no name)", ex.reason ?: @"(no reason)"];
    }

    UIViewController *top = UIApplication.sharedApplication.keyWindow.rootViewController;
    while (top.presentedViewController) top = top.presentedViewController;
    if ([top isKindOfClass:[UINavigationController class]]) top = ((UINavigationController *)top).visibleViewController;

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Download diagnostics"
                                                                   message:report
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

__attribute__((constructor)) static void BHTInstallDownloadDiagnostics(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        Class cls = NSClassFromString(@"BHTVideoDownloadTarget");
        SEL sel = NSSelectorFromString(@"bht_downloadVideoTapped:");
        Method method = cls ? class_getInstanceMethod(cls, sel) : NULL;
        if (!method) return;
        BHTOriginalDiagnosticTapIMP = method_getImplementation(method);
        method_setImplementation(method, (IMP)BHTDiagnosticTap);
        NSLog(@"[BHTwitter][X12.16] Installed download diagnostics tap override");
    });
}
