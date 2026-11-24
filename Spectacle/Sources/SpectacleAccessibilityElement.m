#import "SpectacleAccessibilityElement.h"

#import <AppKit/AppKit.h>

@implementation SpectacleAccessibilityElement
{
  AXUIElementRef _underlyingElement;
  BOOL _rectUpdatePending;
}

// One counter for every window update, not one per element: a fresh element is created for every
// shortcut press, and an in-flight update started by a previous element has to be able to tell that
// it has been superseded. Without that, the two updates alternate and the window visibly bounces
// between the old and the new rectangle.
static NSUInteger SpectacleRectUpdateGeneration = 0;

static BOOL SpectacleRectsAreClose(CGRect rect1, CGRect rect2)
{
  return fabs(rect1.origin.x - rect2.origin.x) <= 1.0
      && fabs(rect1.origin.y - rect2.origin.y) <= 1.0
      && fabs(rect1.size.width - rect2.size.width) <= 1.0
      && fabs(rect1.size.height - rect2.size.height) <= 1.0;
}

static BOOL SpectacleSizeIsClose(CGRect rect1, CGRect rect2)
{
  return fabs(rect1.size.width - rect2.size.width) <= 1.0 && fabs(rect1.size.height - rect2.size.height) <= 1.0;
}

static BOOL SpectaclePositionIsClose(CGRect rect1, CGRect rect2)
{
  return fabs(rect1.origin.x - rect2.origin.x) <= 1.0 && fabs(rect1.origin.y - rect2.origin.y) <= 1.0;
}

static BOOL SpectaclePositionIsOff(CGRect rect1, CGRect rect2)
{
  return !SpectaclePositionIsClose(rect1, rect2);
}

static BOOL SpectacleSizeIsOff(CGRect rect1, CGRect rect2)
{
  return !SpectacleSizeIsClose(rect1, rect2);
}

// Diagnostics for tuning the transition: SPECTACLE_TRACE=1 prints every step with a timestamp.
static BOOL SpectacleTraceEnabled(void)
{
  static BOOL enabled;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    enabled = getenv("SPECTACLE_TRACE") != NULL;
  });
  return enabled;
}

static NSString *SpectacleDescribeRect(CGRect rect)
{
  if (CGRectIsNull(rect)) {
    return @"<null>";
  }
  return [NSString stringWithFormat:@"(%.0f,%.0f %.0fx%.0f)", rect.origin.x, rect.origin.y, rect.size.width, rect.size.height];
}

static void SpectacleTrace(NSString *format, ...)
{
  if (!SpectacleTraceEnabled()) {
    return;
  }
  static CFAbsoluteTime referenceTime;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    referenceTime = CFAbsoluteTimeGetCurrent();
  });
  va_list arguments;
  va_start(arguments, format);
  NSString *message = [[NSString alloc] initWithFormat:format arguments:arguments];
  va_end(arguments);
  NSLog(@"[trace %7.1fms] %@", (CFAbsoluteTimeGetCurrent() - referenceTime) * 1000.0, message);
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

// Applications that reflow asynchronously (Qt-based ones such as WPS) apply a resize in their own
// time and throw away a position update that arrives in the same batch. They are remembered, so the
// extra step is only paid once per application instead of on every shortcut.
static NSMutableSet<NSString *> *SpectacleTwoPhaseApplicationIdentifiers(void)
{
  static NSMutableSet *identifiers;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    NSArray *stored = [[NSUserDefaults standardUserDefaults] arrayForKey:@"SpectacleTwoPhaseApplicationIdentifiers"];
    identifiers = [NSMutableSet setWithArray:stored ?: @[]];
  });
  return identifiers;
}

static void SpectacleRememberTwoPhaseApplication(NSString *identifier)
{
  if (identifier.length == 0 || [SpectacleTwoPhaseApplicationIdentifiers() containsObject:identifier]) {
    return;
  }
  NSMutableSet *identifiers = SpectacleTwoPhaseApplicationIdentifiers();
  [identifiers addObject:identifier];
  [[NSUserDefaults standardUserDefaults] setObject:identifiers.allObjects
                                            forKey:@"SpectacleTwoPhaseApplicationIdentifiers"];
  SpectacleTrace(@"remembering %@ as needing a move before a resize", identifier);
}

- (NSString *)applicationBundleIdentifier
{
  pid_t processIdentifier = 0;
  if (AXUIElementGetPid(_underlyingElement, &processIdentifier) != kAXErrorSuccess || processIdentifier <= 0) {
    return nil;
  }
  return [NSRunningApplication runningApplicationWithProcessIdentifier:processIdentifier].bundleIdentifier;
}

- (void)setRectOfElement:(CGRect)rect
{
  if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) {
    return;
  }
  NSUInteger generation = ++SpectacleRectUpdateGeneration;
  _rectUpdatePending = YES;
  SpectacleTrace(@"set %@ (was %@)", SpectacleDescribeRect(rect), SpectacleDescribeRect([self rectOfElement]));
  NSString *applicationBundleIdentifier = [self applicationBundleIdentifier];
  [self applyPositionOfRect:rect];
  if (applicationBundleIdentifier
      && [SpectacleTwoPhaseApplicationIdentifiers() containsObject:applicationBundleIdentifier]) {
    // Known to drop a resize that arrives while it is being moved: wait for the move to land first.
    [self confirmPositionOfRect:rect generation:generation attempt:0];
    return;
  }
  // Everything else gets the whole rectangle in one run loop turn, which the window shows as a
  // single step. If the application turns out to drop the move, the answer is caught below and the
  // two-phase path is used from then on.
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [self applySizeOfRect:rect];
  [self confirmResizeOfRect:rect
                 generation:generation
                      attempt:0
               applyDuration:CFAbsoluteTimeGetCurrent() - start];
}

- (BOOL)hasPendingRectUpdate
{
  return _rectUpdatePending;
}

- (void)applyPositionOfRect:(CGRect)rect
{
  SpectacleTrace(@"  apply position %@", SpectacleDescribeRect(rect));
  CGPoint origin = rect.origin;
  AXValueRef positionRef = AXValueCreate(kAXValueCGPointType, &origin);
  [self setValue:positionRef forAttribute:kAXPositionAttribute];
  CFRelease(positionRef);
}

- (void)applySizeOfRect:(CGRect)rect
{
  SpectacleTrace(@"  apply size %@", SpectacleDescribeRect(rect));
  CGSize size = rect.size;
  AXValueRef sizeRef = AXValueCreate(kAXValueCGSizeType, &size);
  [self setValue:sizeRef forAttribute:kAXSizeAttribute];
  CFRelease(sizeRef);
}

// Polling interval while waiting for one phase to land: short enough to stay inside a single
// perceived motion.
static const NSTimeInterval SpectacleConfirmDelay = 0.02;
static const NSUInteger SpectacleMaxMoveAttempts = 3;
static const NSUInteger SpectacleMaxResizeAttempts = 2;
// An application that spends longer than this applying a resize (Qt-based ones such as WPS block
// for a few hundred milliseconds while they reflow) is doing the work in its own time. Asking again
// only means another long block and another visible step, so a single request is enough.
static const NSTimeInterval SpectacleSlowResizeThreshold = 0.2;

- (void)confirmPositionOfRect:(CGRect)rect generation:(NSUInteger)generation attempt:(NSUInteger)attempt
{
  // The element is held for the duration of the update: it is created per action and is not
  // otherwise kept alive while the update is in flight.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SpectacleConfirmDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = self;
    if (SpectacleRectUpdateGeneration != generation) {
      return;
    }
    CGRect currentRect = [strongSelf rectOfElement];
    BOOL moved = !CGRectIsNull(currentRect) && !SpectaclePositionIsOff(currentRect, rect);
    SpectacleTrace(@"move check %lu: %@ (was asked %@)", (unsigned long)attempt,
                   SpectacleDescribeRect(currentRect), SpectacleDescribeRect(rect));
    if (moved) {
      if (SpectacleSizeIsOff(currentRect, rect)) {
        [strongSelf beginResizeOfRect:rect generation:generation attempt:0];
      } else {
        strongSelf->_rectUpdatePending = NO;
      }
      return;
    }
    if (attempt + 1 >= SpectacleMaxMoveAttempts) {
      // Move on regardless: the resize is what the user notices, and the position is verified again
      // after it.
      SpectacleTrace(@"move did not take after %lu tries, resizing anyway", (unsigned long)(attempt + 1));
      [strongSelf beginResizeOfRect:rect generation:generation attempt:0];
      return;
    }
    [strongSelf applyPositionOfRect:rect];
    [strongSelf confirmPositionOfRect:rect generation:generation attempt:attempt + 1];
  });
}

- (void)beginResizeOfRect:(CGRect)rect generation:(NSUInteger)generation attempt:(NSUInteger)attempt
{
  CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
  [self applySizeOfRect:rect];
  NSTimeInterval applyDuration = CFAbsoluteTimeGetCurrent() - start;
  [self confirmResizeOfRect:rect generation:generation attempt:attempt applyDuration:applyDuration];
}

- (void)confirmResizeOfRect:(CGRect)rect
                 generation:(NSUInteger)generation
                      attempt:(NSUInteger)attempt
               applyDuration:(NSTimeInterval)applyDuration
{
  // The element is held for the duration of the update: it is created per action and is not
  // otherwise kept alive while the update is in flight.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SpectacleConfirmDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = self;
    if (SpectacleRectUpdateGeneration != generation) {
      return;
    }
    CGRect currentRect = [strongSelf rectOfElement];
    if (CGRectIsNull(currentRect) || SpectacleRectsAreClose(currentRect, rect)) {
      SpectacleTrace(@"resize check %lu: landed %@", (unsigned long)attempt, SpectacleDescribeRect(currentRect));
      strongSelf->_rectUpdatePending = NO;
      return;
    }
    BOOL positionIsOff = SpectaclePositionIsOff(currentRect, rect);
    BOOL sizeIsOff = SpectacleSizeIsOff(currentRect, rect);
    SpectacleTrace(@"resize check %lu: at %@ (size %@, position %@, took %.0fms)", (unsigned long)attempt,
                   SpectacleDescribeRect(currentRect), sizeIsOff ? @"off" : @"ok", positionIsOff ? @"off" : @"ok",
                   applyDuration * 1000.0);
    if (positionIsOff) {
      // The move was swallowed while the window was resizing. Move first this time, and resize again
      // once the window is where it belongs.
      SpectacleRememberTwoPhaseApplication([strongSelf applicationBundleIdentifier]);
      [strongSelf applyPositionOfRect:rect];
      [strongSelf confirmPositionOfRect:rect generation:generation attempt:0];
      return;
    }
    // Resizing again is only worthwhile when the application applied the previous request promptly
    // and still ended up short, which means a clamp rather than work still in progress.
    BOOL resizeAgain = sizeIsOff
                    && attempt + 1 < SpectacleMaxResizeAttempts
                    && applyDuration < SpectacleSlowResizeThreshold;
    if (resizeAgain) {
      [strongSelf beginResizeOfRect:rect generation:generation attempt:attempt + 1];
      return;
    }
    strongSelf->_rectUpdatePending = NO;
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
