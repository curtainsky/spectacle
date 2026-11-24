#import "SpectacleQuantizedWindowMover.h"

#import "SpectacleAccessibilityElement.h"

@implementation SpectacleQuantizedWindowMover
{
  id<SpectacleWindowMover> _innerWindowMover;
}

- (instancetype)initWithInnerWindowMover:(id<SpectacleWindowMover>)innerWindowMover
{
  if (self = [super init]) {
    _innerWindowMover = innerWindowMover;
  }
  return self;
}

- (instancetype)init
{
  return [self initWithInnerWindowMover:nil];
}

+ (instancetype)newWithInnerWindowMover:(id<SpectacleWindowMover>)innerWindowMover
{
  return [[self alloc] initWithInnerWindowMover:innerWindowMover];
}

- (void)moveWindowRect:(CGRect)windowRect
         frameOfScreen:(CGRect)frameOfScreen
  visibleFrameOfScreen:(CGRect)visibleFrameOfScreen
frontmostWindowElement:(SpectacleAccessibilityElement *)frontmostWindowElement
                action:(SpectacleWindowAction *)action
{
  // A geometry update is still being confirmed, so anything read from the window right now is an
  // intermediate state rather than the rectangle it will settle on. Correcting against it would
  // only add visible steps to the transition; the element converges on its own.
  if ([frontmostWindowElement hasPendingRectUpdate]) {
    [_innerWindowMover moveWindowRect:windowRect
                        frameOfScreen:frameOfScreen
                 visibleFrameOfScreen:visibleFrameOfScreen
               frontmostWindowElement:frontmostWindowElement
                               action:action];
    return;
  }
  CGRect movedWindowRect = [frontmostWindowElement rectOfElement];
  if (!CGRectEqualToRect(movedWindowRect, windowRect)) {
    CGRect adjustedWindowRect = windowRect;
    // A window that refuses to shrink below its minimum size keeps reporting the larger size, so
    // stop after a couple of attempts instead of walking the requested size down step by step.
    for (NSUInteger attempt = 0; attempt < 2; attempt++) {
      if (movedWindowRect.size.width <= windowRect.size.width
          && movedWindowRect.size.height <= windowRect.size.height) {
        break;
      }
      if (movedWindowRect.size.width > windowRect.size.width) {
        adjustedWindowRect.size.width -= 2;
      }
      if (movedWindowRect.size.height > windowRect.size.height) {
        adjustedWindowRect.size.height -= 2;
      }
      if (adjustedWindowRect.size.width < windowRect.size.width * 0.85f
          || adjustedWindowRect.size.height < windowRect.size.height * 0.85f) {
        break;
      }
      [frontmostWindowElement setRectOfElement:adjustedWindowRect];
      movedWindowRect = [frontmostWindowElement rectOfElement];
    }
    // Centre the window inside the requested rectangle rather than nudging its current origin,
    // which may already have been moved by the window server while it was resizing.
    adjustedWindowRect.origin.x = windowRect.origin.x + floor((windowRect.size.width - movedWindowRect.size.width) / 2.0f);
    adjustedWindowRect.origin.y = windowRect.origin.y + floor((windowRect.size.height - movedWindowRect.size.height) / 2.0f);
    [frontmostWindowElement setRectOfElement:adjustedWindowRect];
  }
  [_innerWindowMover moveWindowRect:windowRect
                      frameOfScreen:frameOfScreen
               visibleFrameOfScreen:visibleFrameOfScreen
             frontmostWindowElement:frontmostWindowElement
                             action:action];
}

@end
