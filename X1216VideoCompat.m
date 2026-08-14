#import <UIKit/UIKit.h>

// X 12.16 compatibility note:
// Do not install a custom long-press recognizer on TTAStatusInlineShareButton.
// X owns the button's gesture/context-menu pipeline and an additional recognizer
// can suppress the native long-press behavior. Video download integration will be
// reintroduced through the native share/menu path instead of competing gestures.

__attribute__((constructor)) static void BHTX1216VideoCompatInit(void) {
    NSLog(@"[BHTwitter][X12.16] Native share long-press preserved");
}
