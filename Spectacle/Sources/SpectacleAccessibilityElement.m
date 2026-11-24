#import "SpectacleAccessibilityElement.h"

#import <AppKit/AppKit.h>

@implementation SpectacleAccessibilityElement
{
  AXUIElementRef _underlyingElement;
  BOOL _rectUpdatePending;
  CGRect _updateTargetRect;
  CGRect _lastObservedRect;
  CFAbsoluteTime _updateStartTime;
  CFAbsoluteTime _lastObservedChangeTime;
  NSUInteger _pendingAttribute;
  NSUInteger _stalledWrites;
  CGRect _rectAtLastWrite;
  BOOL _resizeFirst;
  BOOL _waitForCommit;
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

// The rectangle a window has been asked for and has not reached yet, keyed by process. A second press
// that arrives while the window is still on its way has to continue from the rectangle it is heading
// for: an application that applies geometry in its own time reports the middle of the previous
// transition for a few hundred milliseconds, and a cycle step computed from that lands somewhere else
// entirely - on another display, even.
static NSMutableDictionary<NSNumber *, NSDictionary *> *SpectaclePendingRectUpdates(void)
{
  static NSMutableDictionary *updates;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    updates = [NSMutableDictionary new];
  });
  return updates;
}

static void SpectacleRememberPendingRectUpdate(pid_t processIdentifier, CGRect rect)
{
  if (processIdentifier <= 0) {
    return;
  }
  SpectaclePendingRectUpdates()[@(processIdentifier)] = @{@"rect": [NSValue valueWithRect:NSRectFromCGRect(rect)],
                                                        @"time": @(CFAbsoluteTimeGetCurrent())};
}

static void SpectacleForgetPendingRectUpdate(pid_t processIdentifier)
{
  if (processIdentifier > 0) {
    [SpectaclePendingRectUpdates() removeObjectForKey:@(processIdentifier)];
  }
}

static CGRect SpectaclePendingRectUpdate(pid_t processIdentifier)
{
  NSDictionary *update = SpectaclePendingRectUpdates()[@(processIdentifier)];
  if (!update) {
    return CGRectNull;
  }
  // A pending update that never finished must not shadow the window forever.
  if (CFAbsoluteTimeGetCurrent() - [update[@"time"] doubleValue] > SpectacleUpdateTimeout + 0.5) {
    SpectacleForgetPendingRectUpdate(processIdentifier);
    return CGRectNull;
  }
  return NSRectToCGRect([update[@"rect"] rectValue]);
}

- (pid_t)processIdentifier
{
  pid_t processIdentifier = 0;
  if (AXUIElementGetPid(_underlyingElement, &processIdentifier) != kAXErrorSuccess) {
    return 0;
  }
  return processIdentifier;
}

- (CGRect)currentRectOfElement
{
  CGRect pendingRect = SpectaclePendingRectUpdate([self processIdentifier]);
  if (!CGRectIsNull(pendingRect)) {
    return pendingRect;
  }
  return [self rectOfElement];
}

// A geometry update is written to the window one attribute at a time, and each write is left alone
// until the application has committed it. Two things make that necessary.
//
// Applications built on Qt (WPS is one) coalesce frame updates internally for about a quarter of a
// second. A resize that arrives before the move has been folded in is applied against the frame they
// last committed, so the window settles at a size that was never asked for - and once its right edge
// sits on the edge of the screen it will not grow again until it has been moved back. Writing on a
// short timer is what made the transition oscillate: every attempt was computed from a frame that was
// still changing.
//
// They also throw away one of two attributes that arrive in the same batch, and which one survives is
// not predictable, so a single combined write cannot be relied on.
//
// The order is therefore chosen from the shape of the transition: growing windows are moved first so
// that the resize happens where it belongs and never runs off the screen, shrinking ones are resized
// first so that the move does not drag a window larger than its destination across the display.
static const NSTimeInterval SpectaclePollInterval = 0.025;
// A cooperative application finishes a frame change within a frame or two.
static const NSTimeInterval SpectacleQuietInterval = 0.12;
// Applications that coalesce frame updates need appreciably longer before their next committed frame
// can be relied on.
static const NSTimeInterval SpectacleAsyncQuietInterval = 0.30;
// Give up on the update entirely after this long; the window is left wherever it got to.
static const NSTimeInterval SpectacleUpdateTimeout = 2.5;
// How many writes of an attribute that the window ignored are tolerated before giving up.
static const NSUInteger SpectacleMaxStalledWrites = 2;

typedef NS_ENUM(NSUInteger, SpectacleRectUpdatePendingAttribute) {
  SpectacleRectUpdatePendingAttributeNone = 0,
  SpectacleRectUpdatePendingAttributePosition,
  SpectacleRectUpdatePendingAttributeSize,
};

- (void)setRectOfElement:(CGRect)rect
{
  if (CGRectIsNull(rect) || CGRectIsEmpty(rect)) {
    return;
  }
  NSUInteger generation = ++SpectacleRectUpdateGeneration;
  _rectUpdatePending = YES;
  _updateTargetRect = rect;
  _updateStartTime = CFAbsoluteTimeGetCurrent();
  _lastObservedRect = [self rectOfElement];
  _lastObservedChangeTime = _updateStartTime;
  _pendingAttribute = SpectacleRectUpdatePendingAttributeNone;
  _stalledWrites = 0;
  SpectacleTrace(@"set %@ (is %@)", SpectacleDescribeRect(rect), SpectacleDescribeRect(_lastObservedRect));
  SpectacleRememberPendingRectUpdate([self processIdentifier], rect);

  NSString *applicationBundleIdentifier = [self applicationBundleIdentifier];
  BOOL moveBeforeResize = applicationBundleIdentifier
    && [SpectacleTwoPhaseApplicationIdentifiers() containsObject:applicationBundleIdentifier];
  // Shrinking windows are resized first; anything else is moved first. A window that does not need to
  // grow can be resized where it stands without any risk of ending up outside the screen.
  BOOL shrinking = rect.size.width <= _lastObservedRect.size.width + 1.0
                && rect.size.height <= _lastObservedRect.size.height + 1.0;
  _resizeFirst = shrinking;
  _waitForCommit = moveBeforeResize;
  if (moveBeforeResize) {
    [self writeNextAttributeForGeneration:generation];
  } else {
    // Everything else takes the whole rectangle in one run loop turn, which it shows as a single
    // step. If it turns out to drop one of the two, the poll below notices and the paced path is used
    // from then on.
    [self applyPositionOfRect:rect];
    [self applySizeOfRect:rect];
  }
  [self scheduleRectUpdatePollForGeneration:generation];
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

- (void)finishRectUpdate
{
  _rectUpdatePending = NO;
  _pendingAttribute = SpectacleRectUpdatePendingAttributeNone;
  SpectacleForgetPendingRectUpdate([self processIdentifier]);
}

// Writes one attribute - whichever the window is furthest away from - and marks it as pending so that
// nothing else is written until the application has committed it.
- (void)writeNextAttributeForGeneration:(NSUInteger)generation
{
  CGRect observedRect = _lastObservedRect;
  BOOL positionIsOff = SpectaclePositionIsOff(observedRect, _updateTargetRect);
  BOOL sizeIsOff = SpectacleSizeIsOff(observedRect, _updateTargetRect);
  if (!positionIsOff && !sizeIsOff) {
    [self finishRectUpdate];
    return;
  }
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (positionIsOff && sizeIsOff) {
    if (_resizeFirst) {
      [self applySizeOfRect:_updateTargetRect];
      _pendingAttribute = SpectacleRectUpdatePendingAttributeSize;
    } else {
      [self applyPositionOfRect:_updateTargetRect];
      _pendingAttribute = SpectacleRectUpdatePendingAttributePosition;
    }
  } else if (positionIsOff) {
    [self applyPositionOfRect:_updateTargetRect];
    _pendingAttribute = SpectacleRectUpdatePendingAttributePosition;
  } else {
    [self applySizeOfRect:_updateTargetRect];
    _pendingAttribute = SpectacleRectUpdatePendingAttributeSize;
  }
  _lastObservedChangeTime = now;
  _rectAtLastWrite = observedRect;
}

- (void)scheduleRectUpdatePollForGeneration:(NSUInteger)generation
{
  // The element is held for the duration of the update: it is created per action and is not
  // otherwise kept alive while the update is in flight.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(SpectaclePollInterval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
    typeof(self) strongSelf = self;
    if (SpectacleRectUpdateGeneration != generation) {
      return;
    }
    [strongSelf pollRectUpdateForGeneration:generation];
  });
}

- (void)pollRectUpdateForGeneration:(NSUInteger)generation
{
  CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  CGRect observedRect = [self rectOfElement];
  if (CGRectIsNull(observedRect)) {
    [self finishRectUpdate];
    return;
  }
  if (!CGRectEqualToRect(observedRect, _lastObservedRect)) {
    _lastObservedRect = observedRect;
    _lastObservedChangeTime = now;
  }
  NSTimeInterval quiet = now - _lastObservedChangeTime;
  NSTimeInterval elapsed = now - _updateStartTime;
  if (SpectacleRectsAreClose(observedRect, _updateTargetRect)) {
    SpectacleTrace(@"landed at %@ after %.0fms", SpectacleDescribeRect(observedRect), elapsed * 1000.0);
    [self finishRectUpdate];
    return;
  }
  if (elapsed > SpectacleUpdateTimeout) {
    SpectacleTrace(@"giving up at %@ after %.0fms", SpectacleDescribeRect(observedRect), elapsed * 1000.0);
    [self finishRectUpdate];
    return;
  }
  NSTimeInterval requiredQuiet = _waitForCommit ? SpectacleAsyncQuietInterval : SpectacleQuietInterval;
  SpectacleTrace(@"at %@ (size %@, position %@, pending %lu, quiet %.0fms)", SpectacleDescribeRect(observedRect),
                 SpectacleSizeIsOff(observedRect, _updateTargetRect) ? @"off" : @"ok",
                 SpectaclePositionIsOff(observedRect, _updateTargetRect) ? @"off" : @"ok",
                 (unsigned long)_pendingAttribute, quiet * 1000.0);
  // Nothing is written while the window is still changing, and nothing is written twice into the same
  // frame: the application has to have committed the previous write first.
  if (quiet < requiredQuiet) {
    [self scheduleRectUpdatePollForGeneration:generation];
    return;
  }
  if (_pendingAttribute != SpectacleRectUpdatePendingAttributeNone) {
    _pendingAttribute = SpectacleRectUpdatePendingAttributeNone;
    // A write that moved the window was accepted even if the rectangle is not the requested one yet,
    // so the next attribute can follow. A write that changed nothing was ignored, and asking again
    // only makes sense a couple of times.
    if (CGRectEqualToRect(observedRect, _rectAtLastWrite)) {
      if (++_stalledWrites > SpectacleMaxStalledWrites) {
        SpectacleTrace(@"the window stopped responding to the requests");
        [self finishRectUpdate];
        return;
      }
      SpectacleRememberTwoPhaseApplication([self applicationBundleIdentifier]);
      _waitForCommit = YES;
    } else {
      _stalledWrites = 0;
    }
  }
  [self writeNextAttributeForGeneration:generation];
  [self scheduleRectUpdatePollForGeneration:generation];
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
