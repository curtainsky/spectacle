#import "SpectacleShortcutUserDefaultsStorage.h"

#import "SpectacleShortcut.h"

static void SpectacleApplyLegacyShortcutClassMappings(NSKeyedUnarchiver *unarchiver)
{
  [unarchiver setClass:[SpectacleShortcut class] forClassName:@"SpectacleHotKey"];
  [unarchiver setClass:[SpectacleShortcut class] forClassName:@"ZeroKitHotKey"];
  [unarchiver setClass:[SpectacleShortcut class] forClassName:@"ZKHotKey"];
}

@implementation SpectacleShortcutUserDefaultsStorage

- (NSArray<SpectacleShortcut *> *)loadShortcutsWithAction:(SpectacleShortcutAction)action
{
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  NSMutableDictionary<NSString *, NSData *> *shortcutsFromUserDefaults = [NSMutableDictionary new];
  for (NSString *shortcutName in [self shortcutNames]) {
    shortcutsFromUserDefaults[shortcutName] = [userDefaults dataForKey:shortcutName];
  }
  return [self shortcutsFromDictionary:shortcutsFromUserDefaults action:action];
}

- (void)storeShortcuts:(NSArray<SpectacleShortcut *> *)shortcuts
{
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  for (SpectacleShortcut *shortcut in shortcuts) {
    NSError *error = nil;
    NSData *shortcutData = [NSKeyedArchiver archivedDataWithRootObject:shortcut requiringSecureCoding:YES error:&error];
    if (!shortcutData) {
      NSLog(@"Unable to archive shortcut %@; reason %@", shortcut.shortcutName, error.localizedDescription);
      continue;
    }
    NSString *shortcutName = shortcut.shortcutName;
    if (![shortcutData isEqualToData:[userDefaults dataForKey:shortcutName]]) {
      [userDefaults setObject:shortcutData forKey:shortcutName];
    }
  }
}

- (BOOL)isMigrationNeeded
{
  return NO;
}

- (NSArray<NSString *> *)shortcutNames
{
  return @[
           @"MoveToCenter",
           @"MoveToFullscreen",
           @"MoveToLeftHalf",
           @"MoveToRightHalf",
           @"MoveToTopHalf",
           @"MoveToBottomHalf",
           @"MoveToUpperLeft",
           @"MoveToLowerLeft",
           @"MoveToUpperRight",
           @"MoveToLowerRight",
           @"MoveToNextDisplay",
           @"MoveToPreviousDisplay",
           @"MoveToNextThird",
           @"MoveToPreviousThird",
           @"MakeLarger",
           @"MakeSmaller",
           @"UndoLastMove",
           @"RedoLastMove",
           ];
}

- (NSArray<SpectacleShortcut *> *)shortcutsFromDictionary:(NSDictionary<NSString *, NSData *> *)dictionary
                                                   action:(SpectacleShortcutAction)action
{
  NSMutableArray<SpectacleShortcut *> *shortcuts = [NSMutableArray new];
  for (NSData *shortcutData in dictionary.allValues) {
    SpectacleShortcut *shortcut = [self shortcutFromData:shortcutData];
    if (shortcut) {
      [shortcuts addObject:[shortcut copyWithShortcutAction:action]];
    }
  }
  return shortcuts;
}

- (SpectacleShortcut *)shortcutFromData:(NSData *)shortcutData
{
  if (shortcutData.length == 0) {
    return nil;
  }
  NSError *error = nil;
  NSKeyedUnarchiver *unarchiver = [[NSKeyedUnarchiver alloc] initForReadingFromData:shortcutData error:&error];
  if (!unarchiver) {
    NSLog(@"Unable to read the archived shortcut; reason %@", error.localizedDescription);
    return nil;
  }
  SpectacleApplyLegacyShortcutClassMappings(unarchiver);
  // Shortcuts written by older versions of Spectacle were archived without secure coding.
  unarchiver.requiresSecureCoding = NO;
  id shortcut = [unarchiver decodeObjectOfClass:[SpectacleShortcut class] forKey:NSKeyedArchiveRootObjectKey];
  [unarchiver finishDecoding];
  return [shortcut isKindOfClass:[SpectacleShortcut class]] ? shortcut : nil;
}

@end
