#import "SpectacleAccessibilityElement.h"

#import <AppKit/AppKit.h>

@implementation SpectacleAccessibilityElement
{
  AXUIElementRef _underlyingElement;
  NSUInteger _rectCorrectionGeneration;
}

static BOOL SpectacleRectsAreClose(CGRect rect1, CGRect rect2)
{
  return fabs(rect1.origin.x - rect2.origin.x) <= 1.0
      && fabs(rect1.origin.y - rect2.origin.y) <= 1.0
      && fabs(rect1.size.width - rect2.size.width) <= 1.0
      && fabs(rect1.size.height - rect2.size.height) <= 1.0;
}

// Windows that resize asynchronously (Qt-based applications such as WPS, and anything else that
// reflows off the main thread) swallow part of a geometry update, so tell those apart from a
// window that simply has a minimum size and never reached the requested rectangle.
static BOOL SpectacleRectMismatchIsSignificant(CGRect currentRect, CGRect targetRect)
{
  return fabs(currentRect.origin.x - targetRect.origin.x) > 20.0
      || fabs(currentRect.origin.y - targetRect.origin.y) > 20.0
      || fabs(currentRect.size.width - targetRect.size.width) > 20.0
      || fabs(currentRect.size.height - targetRect.size.height) > 20.0;
}

- (instancetype)init
{
  if (self = [super init]) {
    _underlyingElement = NULL;
  }

  return self;
}

+ (SpectacleAccessibilityElement *)frontmostApplicationElement
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  SpectacleAccessibilityElement *frontmostApplicationElement = [SpectacleAccessibilityElement new];
  AXUIElementRef underlyingElement = AXUIElementCreateApplication(frontmostApplication.processIdentifier);
  frontmostApplicationElement.underlyingElement = underlyingElement;
  CFRelease(underlyingElement);
  return frontmostApplicationElement;
}

+ (SpectacleAccessibilityElement *)frontmostWindowElement
{
  SpectacleAccessibilityElement *frontmostApplicationElement = [SpectacleAccessibilityElement frontmostApplicationElement];
  SpectacleAccessibilityElement *frontmostWindowElement = nil;
  if (frontmostApplicationElement) {
    frontmostWindowElement = [frontmostApplicationElement elementWithAttribute:kAXFocusedWindowAttribute];
    if (!frontmostWindowElement) {
      NSLog(@"Invalid accessibility element provided, unable to determine the size and position of the window.");
    }
  } else {
    NSLog(@"Failed to find the application that currently has focus.");
  }
  return frontmostWindowElement;
}

- (SpectacleAccessibilityElement *)elementWithAttribute:(CFStringRef)attribute
{
  SpectacleAccessibilityElement *newElement = nil;
  AXUIElementRef underlyingElement;
  AXError result = AXUIElementCopyAttributeValue(_underlyingElement, attribute, (CFTypeRef *)&underlyingElement);
  if (result == kAXErrorSuccess) {
    newElement = [SpectacleAccessibilityElement new];
    newElement.underlyingElement = underlyingElement;
    CFRelease(underlyingElement);
  } else {
    NSLog(@"Unable to obtain the accessibility element with the specified attribute: %@ (error code %d)", attribute, result);
  }
  return newElement;
}

- (NSString *)stringValueOfAttribute:(CFStringRef)attribute
{
  if (CFGetTypeID(_underlyingElement) == AXUIElementGetTypeID()) {
    CFTypeRef value;
    AXError result;
    result = AXUIElementCopyAttributeValue(_underlyingElement, attribute, &value);
    if (result == kAXErrorSuccess) {
      return CFBridgingRelease(value);
    } else {
      NSLog(@"There was a problem getting the string value of the specified attribute: %@ (error code %d)", attribute, result);
    }
  }
  return nil;
}

- (AXValueRef)valueOfAttribute:(CFStringRef)attribute type:(AXValueType)type
{
  if (CFGetTypeID(_underlyingElement) == AXUIElementGetTypeID()) {
    CFTypeRef value;
    AXError result;
    result = AXUIElementCopyAttributeValue(_underlyingElement, attribute, (CFTypeRef *)&value);
    if ((result == kAXErrorSuccess) && (AXValueGetType(value) == type)) {
      return value;
    } else {
      NSLog(@"There was a problem getting the value of the specified attribute: %@ (error code %d)", attribute, result);
    }
  }
  return NULL;
}

- (void)setValue:(AXValueRef)value forAttribute:(CFStringRef)attribute
{
  AXError result = AXUIElementSetAttributeValue(_underlyingElement, attribute, (CFTypeRef *)value);
  if (result != kAXErrorSuccess) {
    NSLog(@"There was a problem setting the value of the specified attribute: %@ (error code %d)", attribute, result);
  }
}

- (CGRect)rectOfElement
{
  CGRect result = CGRectNull;
  CFTypeRef positionValue = [self valueOfAttribute:kAXPositionAttribute type:kAXValueCGPointType];
  CFTypeRef sizeValue = [self valueOfAttribute:kAXSizeAttribute type:kAXValueCGSizeType];
  CGPoint position;
  CGSize size;
  AXValueGetValue(positionValue, kAXValueCGPointType, (void *)&position);
  AXValueGetValue(sizeValue, kAXValueCGSizeType, (void *)&size);
  if ((positionValue != NULL) && (sizeValue != NULL)) {
    CFRelease(positionValue);
    CFRelease(sizeValue);
    result = CGRectMake(position.x, position.y, size.width, size.height);
  }
  return result;
}

- (void)setRectOfElement:(CGRect)rect
{
  NSUInteger generation = ++_rectCorrectionGeneration;
  // Fast path: move, resize, move again. Standard AppKit windows land exactly where asked and
  // never reach the stepwise correction below.
  CGPoint origin = rect.origin;
  CGSize size = rect.size;
  AXValueRef positionRef = AXValueCreate(kAXValueCGPointType, &origin);
  AXValueRef sizeRef = AXValueCreate(kAXValueCGSizeType, &size);
  [self setValue:positionRef forAttribute:kAXPositionAttribute];
  [self setValue:sizeRef forAttribute:kAXSizeAttribute];
  [self setValue:positionRef forAttribute:kAXPositionAttribute];
  CFRelease(positionRef);
  CFRelease(sizeRef);
  // Some windows resize asynchronously (Qt-based applications such as WPS, and anything that
  // reflows off the main thread). They drop the size update while the position is still
  // changing, and re-anchor themselves mid-resize, so the fast path leaves them the wrong size
  // and in the wrong place. Those updates have to be spaced out to take effect.
  [self scheduleStepwiseCorrectionToRect:rect generation:generation round:0];
}

- (void)applyPositionOfRect:(CGRect)rect
{
  CGPoint origin = rect.origin;
  AXValueRef positionRef = AXValueCreate(kAXValueCGPointType, &origin);
  [self setValue:positionRef forAttribute:kAXPositionAttribute];
  CFRelease(positionRef);
}

- (void)applySizeOfRect:(CGRect)rect
{
  CGSize size = rect.size;
  AXValueRef sizeRef = AXValueCreate(kAXValueCGSizeType, &size);
  [self setValue:sizeRef forAttribute:kAXSizeAttribute];
  CFRelease(sizeRef);
}

- (void)scheduleStepwiseCorrectionToRect:(CGRect)rect generation:(NSUInteger)generation round:(NSUInteger)round
{
  if (round >= 2) {
    return;
  }
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_rectCorrectionGeneration != generation) {
      return;
    }
    CGRect currentRect = [strongSelf rectOfElement];
    if (CGRectIsNull(currentRect)
        || SpectacleRectsAreClose(currentRect, rect)
        || !SpectacleRectMismatchIsSignificant(currentRect, rect)) {
      return;
    }
    [strongSelf applyPositionOfRect:rect];
    [strongSelf scheduleSizeStepForRect:rect generation:generation round:round];
  });
}

- (void)scheduleSizeStepForRect:(CGRect)rect generation:(NSUInteger)generation round:(NSUInteger)round
{
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_rectCorrectionGeneration != generation) {
      return;
    }
    [strongSelf applySizeOfRect:rect];
    [strongSelf scheduleFinalPositionStepForRect:rect generation:generation round:round];
  });
}

- (void)scheduleFinalPositionStepForRect:(CGRect)rect generation:(NSUInteger)generation round:(NSUInteger)round
{
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_rectCorrectionGeneration != generation) {
      return;
    }
    [strongSelf applyPositionOfRect:rect];
    [strongSelf scheduleVerificationForRect:rect generation:generation round:round];
  });
}

- (void)scheduleVerificationForRect:(CGRect)rect generation:(NSUInteger)generation round:(NSUInteger)round
{
  __weak typeof(self) weakSelf = self;
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = weakSelf;
    if (!strongSelf || strongSelf->_rectCorrectionGeneration != generation) {
      return;
    }
    CGRect currentRect = [strongSelf rectOfElement];
    if (CGRectIsNull(currentRect)
        || SpectacleRectsAreClose(currentRect, rect)
        || !SpectacleRectMismatchIsSignificant(currentRect, rect)) {
      return;
    }
    [strongSelf scheduleStepwiseCorrectionToRect:rect generation:generation round:round + 1];
  });
}

+ (CGRect)normalizeCoordinatesOfRect:(CGRect)rect frameOfScreen:(CGRect)frameOfScreen
{
  CGRect frameOfScreenWithMenuBar = [[[NSScreen screens] objectAtIndex:0] frame];
  rect.origin.y = frameOfScreen.size.height - NSMaxY(rect) + (frameOfScreenWithMenuBar.size.height - frameOfScreen.size.height);
  return rect;
}

- (BOOL)isSheet
{
  return [[self stringValueOfAttribute:kAXRoleAttribute] isEqualToString:(__bridge NSString *)kAXSheetRole];
}

- (BOOL)isSystemDialog
{
  return [[self stringValueOfAttribute:kAXSubroleAttribute] isEqualToString:(__bridge NSString *)kAXSystemDialogSubrole];
}

- (void)dealloc
{
  if (_underlyingElement != NULL) {
    CFRelease(_underlyingElement);
  }
}

- (void)setUnderlyingElement:(AXUIElementRef)underlyingElement
{
  if (_underlyingElement != NULL) {
    CFRelease(_underlyingElement);
  }
  _underlyingElement = CFRetain(underlyingElement);
}

@end
