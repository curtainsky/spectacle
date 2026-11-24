#import <Carbon/Carbon.h>

@interface SpectacleAccessibilityElement : NSObject

+ (SpectacleAccessibilityElement *)frontmostApplicationElement;
+ (SpectacleAccessibilityElement *)frontmostWindowElement;

- (SpectacleAccessibilityElement *)elementWithAttribute:(CFStringRef)attribute;

- (NSString *)stringValueOfAttribute:(CFStringRef)attribute;

- (AXValueRef)valueOfAttribute:(CFStringRef)attribute type:(AXValueType)type;
- (void)setValue:(AXValueRef)value forAttribute:(CFStringRef)attribute;

- (CGRect)rectOfElement;
// The rectangle the window is at, or the one it is on its way to while an update is in flight. Every
// decision that depends on where the window "is" - which screen it belongs to, which step of a cycle
// it is on - has to use this instead of -rectOfElement, because an application that applies geometry
// in its own time reports the middle of a transition for a few hundred milliseconds.
- (CGRect)currentRectOfElement;
- (void)setRectOfElement:(CGRect)rect;

// YES while a geometry update requested through -setRectOfElement: is still being confirmed. The
// window element converges on the requested rectangle on its own until then, so callers holding a
// rectangle reading taken during that window are looking at an intermediate state.
- (BOOL)hasPendingRectUpdate;

+ (CGRect)normalizeCoordinatesOfRect:(CGRect)rect frameOfScreen:(CGRect)frameOfScreen;

- (BOOL)isSheet;
- (BOOL)isSystemDialog;

@end
