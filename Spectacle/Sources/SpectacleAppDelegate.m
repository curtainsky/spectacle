#import "SpectacleAppDelegate.h"

#import "SpectacleAccessibilityElement.h"
#import "SpectacleDefaultShortcutHelpers.h"
#import "SpectacleMigratingShortcutStorage.h"
#import "SpectaclePreferencesController.h"
#import "SpectacleScreenDetector.h"
#import "SpectacleShortcutJSONStorage.h"
#import "SpectacleShortcutManager.h"
#import "SpectacleShortcutTranslations.h"
#import "SpectacleShortcutUserDefaultsStorage.h"
#import "SpectacleUtilities.h"
#import "SpectacleWindowPositionCalculator.h"
#import "SpectacleWindowPositionManager.h"

@implementation SpectacleAppDelegate
{
  NSDictionary<NSString *, NSMenuItem *> *_shortcutMenuItems;
  NSStatusItem *_statusItem;
  id<SpectacleShortcutStorage> _shortcutStorage;
  SpectacleShortcutManager *_shortcutManager;
  SpectacleWindowPositionManager *_windowPositionManager;
  SpectaclePreferencesController *_preferencesController;
  NSTimer *_disableShortcutsForAnHourTimer;
  NSSet<NSString *> *_blacklistedApplications;
  NSMutableSet<NSString *> *_disabledApplications;
  BOOL _shortcutsAreDisabledForAnHour;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
  NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
  NSNotificationCenter *workspaceNotificationCenter = [NSWorkspace sharedWorkspace].notificationCenter;
  [notificationCenter addObserver:self
                         selector:@selector(enableStatusItem)
                             name:@"SpectacleStatusItemEnabledNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(disableStatusItem)
                             name:@"SpectacleStatusItemDisabledNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(updateShortcutMenuItems)
                             name:@"SpectacleShortcutChangedNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(updateShortcutMenuItems)
                             name:@"SpectacleRestoreDefaultShortcutsNotification"
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(menuDidSendAction:)
                             name:NSMenuDidSendActionNotification
                           object:nil];
  [notificationCenter addObserver:self
                         selector:@selector(inputSourceSelectionDidChange)
                             name:NSTextInputContextKeyboardSelectionDidChangeNotification
                           object:nil];
  [workspaceNotificationCenter addObserver:self
                                  selector:@selector(applicationDidActivate:)
                                      name:NSWorkspaceDidActivateApplicationNotification
                                    object:nil];
  [workspaceNotificationCenter addObserver:self
                                  selector:@selector(applicationDidDeactivate:)
                                      name:NSWorkspaceDidDeactivateApplicationNotification
                                    object:nil];
  [SpectacleUtilities registerDefaultsForBundle:[NSBundle mainBundle]];
  _shortcutMenuItems = @{
                         @"MoveToCenter": _moveToCenterShortcutMenuItem,
                         @"MoveToFullscreen": _moveToFullscreenShortcutMenuItem,
                         @"MoveToLeftHalf": _moveToLeftShortcutMenuItem,
                         @"MoveToRightHalf": _moveToRightShortcutMenuItem,
                         @"MoveToTopHalf": _moveToTopShortcutMenuItem,
                         @"MoveToBottomHalf": _moveToBottomShortcutMenuItem,
                         @"MoveToUpperLeft": _moveToUpperLeftShortcutMenuItem,
                         @"MoveToLowerLeft": _moveToLowerLeftShortcutMenuItem,
                         @"MoveToUpperRight": _moveToUpperRightShortcutMenuItem,
                         @"MoveToLowerRight": _moveToLowerRightShortcutMenuItem,
                         @"MoveToNextDisplay": _moveToNextDisplayShortcutMenuItem,
                         @"MoveToPreviousDisplay": _moveToPreviousDisplayShortcutMenuItem,
                         @"MoveToNextThird": _moveToNextThirdShortcutMenuItem,
                         @"MoveToPreviousThird": _moveToPreviousThirdShortcutMenuItem,
                         @"MakeLarger": _makeLargerShortcutMenuItem,
                         @"MakeSmaller": _makeSmallerShortcutMenuItem,
                         @"UndoLastMove": _undoLastMoveShortcutMenuItem,
                         @"RedoLastMove": _redoLastMoveShortcutMenuItem,
                         };
  NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
  _blacklistedApplications = [NSSet setWithArray:[userDefaults objectForKey:@"BlacklistedApplications"]];
  _disabledApplications = [NSMutableSet setWithArray:[userDefaults objectForKey:@"DisabledApplications"]];
  _shortcutStorage = [[SpectacleMigratingShortcutStorage alloc] initWithShortcutStorage:[SpectacleShortcutUserDefaultsStorage new]
                                                                   migrationDestination:[SpectacleShortcutJSONStorage new]];
  _shortcutManager = [[SpectacleShortcutManager alloc] initWithShortcutStorage:_shortcutStorage];
  SpectacleWindowPositionCalculator *windowPositionCalculator = [[SpectacleWindowPositionCalculator alloc] initWithErrorHandler:^(NSString *errorMessage) {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Encountered an unexpected error";
    alert.informativeText = errorMessage;
    [alert runModal];
  }];
  _windowPositionManager = [[SpectacleWindowPositionManager alloc] initWithScreenDetector:[SpectacleScreenDetector new]
                                                                 windowPositionCalculator:windowPositionCalculator
                                                                          sharedWorkspace:[NSWorkspace sharedWorkspace]];
  _preferencesController = [[SpectaclePreferencesController alloc] initWithShortcutManager:_shortcutManager
                                                                     windowPositionManager:_windowPositionManager
                                                                           shortcutStorage:_shortcutStorage];
  _shortcutsAreDisabledForAnHour = NO;
  [self manageShortcuts];
  [self disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled];
  BOOL automaticallyChecksForUpdates = [userDefaults boolForKey:@"AutomaticUpdateCheckEnabled"];
  BOOL statusItemEnabled = [userDefaults boolForKey:@"StatusItemEnabled"];
  if (statusItemEnabled) {
    [self enableStatusItem];
  }
  if (automaticallyChecksForUpdates) {
    [self checkForUpdatesWithUserInteraction:NO];
  }
  [self updateShortcutMenuItems];
  if (!AXIsProcessTrustedWithOptions(NULL)) {
    [[NSApplication sharedApplication] runModalForWindow:self.accessiblityAccessDialogWindow];
  }
}

- (BOOL)applicationShouldHandleReopen:(NSApplication *)application hasVisibleWindows:(BOOL)visibleWindows
{
  [self showPreferencesWindow:self];

  return YES;
}

- (IBAction)showPreferencesWindow:(id)sender
{
  [_preferencesController showWindow:sender];
}

- (IBAction)moveFrontmostWindowToFullscreen:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionFullscreen];
}

- (IBAction)moveFrontmostWindowToCenter:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionCenter];
}

- (IBAction)moveFrontmostWindowToLeftHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLeftHalf];
}

- (IBAction)moveFrontmostWindowToRightHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionRightHalf];
}

- (IBAction)moveFrontmostWindowToTopHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionTopHalf];
}

- (IBAction)moveFrontmostWindowToBottomHalf:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionBottomHalf];
}

- (IBAction)moveFrontmostWindowToUpperLeft:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionUpperLeft];
}

- (IBAction)moveFrontmostWindowToLowerLeft:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLowerLeft];
}

- (IBAction)moveFrontmostWindowToUpperRight:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionUpperRight];
}

- (IBAction)moveFrontmostWindowToLowerRight:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLowerRight];
}

- (IBAction)moveFrontmostWindowToNextDisplay:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionNextDisplay];
}

- (IBAction)moveFrontmostWindowToPreviousDisplay:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionPreviousDisplay];
}

- (IBAction)moveFrontmostWindowToNextThird:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionNextThird];
}

- (IBAction)moveFrontmostWindowToPreviousThird:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionPreviousThird];
}

- (IBAction)makeFrontmostWindowLarger:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionLarger];
}

- (IBAction)makeFrontmostWindowSmaller:(id)sender
{
  [_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                              action:kSpectacleWindowActionSmaller];
}

- (IBAction)undoLastWindowAction:(id)sender
{
  [_windowPositionManager undoLastWindowAction];
}

- (IBAction)redoLastWindowAction:(id)sender
{
  [_windowPositionManager redoLastWindowAction];
}

- (IBAction)disableOrEnableShortcutsForAnHour:(id)sender
{
  NSInteger newMenuItemState = NSControlStateValueMixed;
  if (_shortcutsAreDisabledForAnHour) {
    _shortcutsAreDisabledForAnHour = NO;
    [_disableShortcutsForAnHourTimer invalidate];
    [self enableShortcutsIfPermitted];
    newMenuItemState = NSControlStateValueOff;
  } else {
    _shortcutsAreDisabledForAnHour = YES;
    _disableShortcutsForAnHourTimer = [NSTimer scheduledTimerWithTimeInterval:3600
                                                                       target:self
                                                                     selector:@selector(disableOrEnableShortcutsForAnHour:)
                                                                     userInfo:nil
                                                                      repeats:NO];
    [_shortcutManager unregisterShortcuts];
    newMenuItemState = NSControlStateValueOn;
  }
  self.disableShortcutsForAnHourMenuItem.state = newMenuItemState;
}

- (IBAction)disableOrEnableShortcutsForApplication:(id)sender
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  if ([_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    [_disabledApplications removeObject:frontmostApplication.bundleIdentifier];
    [self enableShortcutsIfPermitted];
    self.disableShortcutsForApplicationMenuItem.state = NSControlStateValueOff;
  } else {
    [_disabledApplications addObject:frontmostApplication.bundleIdentifier];
    [_shortcutManager unregisterShortcuts];
    self.disableShortcutsForApplicationMenuItem.state = NSControlStateValueOn;
  }
  [NSUserDefaults.standardUserDefaults setObject:_disabledApplications.allObjects forKey:@"DisabledApplications"];
}

- (IBAction)openSystemPreferences:(id)sender
{
  [[NSApplication sharedApplication] stopModal];
  [self.accessiblityAccessDialogWindow orderOut:self];
  NSWorkspace *sharedWorkspace = [NSWorkspace sharedWorkspace];
  // macOS 13 and later no longer ships the Security preference pane, so the deep link is the
  // only reliable way of taking the user straight to the Accessibility privacy settings.
  NSURL *accessibilitySettingsURL = [NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility"];
  if ([sharedWorkspace openURL:accessibilitySettingsURL]) {
    return;
  }
  NSBundle *applicationBundle = NSBundle.mainBundle;
  NSURL *scriptURL = [applicationBundle URLForResource:@"Security & Privacy System Preferences" withExtension:@"scpt"];
  if ([[[NSAppleScript alloc] initWithContentsOfURL:scriptURL error:nil] executeAndReturnError:nil]) {
    return;
  }
  NSString *preferencePanePath = [SpectacleUtilities pathForPreferencePaneNamed:@"Security"];
  if (preferencePanePath) {
    [sharedWorkspace openURL:[NSURL fileURLWithPath:preferencePanePath]];
  }
}

- (void)dealloc
{
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)manageShortcuts
{
  SpectacleShortcutAction action = ^(SpectacleShortcut *shortcut) {
    [self->_windowPositionManager moveFrontmostWindowElement:[SpectacleAccessibilityElement frontmostWindowElement]
                                                      action:shortcut.windowAction];
  };
  NSArray<SpectacleShortcut *> *shortcuts = [_shortcutStorage loadShortcutsWithAction:action];
  if (shortcuts.count != 0) {
    [_shortcutManager manageShortcuts:shortcuts];
  } else {
    [_shortcutManager manageShortcuts:SpectacleDefaultShortcutsWithAction(action)];
  }
}

- (void)enableStatusItem
{
  _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
  NSImage *statusImage = [NSBundle.mainBundle imageForResource:@"Spectacle Status Item"];
  [statusImage setTemplate:YES];
  _statusItem.button.image = statusImage;
  _statusItem.menu = _statusItemMenu;
  _statusItem.button.toolTip = [@"Spectacle " stringByAppendingString:SpectacleUtilities.applicationVersion];
}

- (void)disableStatusItem
{
  [NSStatusBar.systemStatusBar removeStatusItem:_statusItem];
}

- (void)updateShortcutMenuItems
{
  for (NSString *shortcutName in _shortcutMenuItems.allKeys) {
    NSMenuItem *shortcutMenuItem = _shortcutMenuItems[shortcutName];
    SpectacleShortcut *shortcut = [_shortcutManager shortcutForShortcutName:shortcutName];
    if (shortcut) {
      shortcutMenuItem.keyEquivalent = [SpectacleTranslateKeyCode(shortcut.shortcutKeyCode) lowercaseString];
      shortcutMenuItem.keyEquivalentModifierMask = SpectacleConvertModifiersToCocoaIfNecessary(shortcut.shortcutModifiers);
    } else {
      shortcutMenuItem.keyEquivalent = @"";
      shortcutMenuItem.keyEquivalentModifierMask = 0;
    }
  }
}

- (void)enableShortcutsIfPermitted
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  // Do not enable shortcuts if they should remain disabled for an hour.
  if (_shortcutsAreDisabledForAnHour) {
    return;
  }
  // Do not enable shortcuts if the application is blacklisted or disabled.
  if ([_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      || [_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }
  [_shortcutManager registerShortcuts];
  [[NSNotificationCenter defaultCenter] postNotificationName:@"SpectacleShortcutChangedNotification" object:self];
}

- (void)disableShortcutsIfFrontmostApplicationIsBlacklistedOrDisabled
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  // Do not disable shortcuts if the application is not blacklisted or disabled.
  if (![_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]
      && ![_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    return;
  }
  [_shortcutManager unregisterShortcuts];
}

- (void)applicationDidActivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [_shortcutManager unregisterShortcuts];
  }
}

- (void)applicationDidDeactivate:(NSNotification *)notification
{
  NSRunningApplication *application = notification.userInfo[NSWorkspaceApplicationKey];
  if ([_blacklistedApplications containsObject:application.bundleIdentifier]
      || [_disabledApplications containsObject:application.bundleIdentifier]) {
    [self enableShortcutsIfPermitted];
  }
}

- (void)menuWillOpen:(NSMenu *)menu
{
  NSRunningApplication *frontmostApplication = [NSWorkspace sharedWorkspace].frontmostApplication;
  self.disableShortcutsForApplicationMenuItem.hidden = NO;
  if ([_blacklistedApplications containsObject:frontmostApplication.bundleIdentifier]) {
    self.disableShortcutsForApplicationMenuItem.hidden = YES;
  } else {
    self.disableShortcutsForApplicationMenuItem.title =
      [NSString stringWithFormat:NSLocalizedString(@"MenuItemTitleDisableShortcutsForApplication", @"The menu item title that displays the application to disable shortcuts for"), frontmostApplication.localizedName];
  }
  if ([_disabledApplications containsObject:frontmostApplication.bundleIdentifier]) {
    self.disableShortcutsForApplicationMenuItem.state = NSControlStateValueOn;
  } else {
    self.disableShortcutsForApplicationMenuItem.state = NSControlStateValueOff;
  }
}

- (void)menuDidSendAction:(NSNotification *)notification
{
  NSMenuItem *menuItem = notification.userInfo[@"MenuItem"];
  if (menuItem.tag == -1) {
    [[NSApplication sharedApplication] activateIgnoringOtherApps:YES];
  }
}

- (void)inputSourceSelectionDidChange
{
  [_preferencesController loadRegisteredShortcuts];
  [self updateShortcutMenuItems];
}

#pragma mark - Update Checking

static NSString *const SpectacleReleasesAPIURL = @"https://api.github.com/repos/curtainsky/spectacle/releases/latest";
static NSString *const SpectacleReleasesPageURL = @"https://github.com/curtainsky/spectacle/releases";

static NSComparisonResult SpectacleCompareVersions(NSString *version, NSString *otherVersion)
{
  NSString *normalizedVersion = [version hasPrefix:@"v"] || [version hasPrefix:@"V"] ? [version substringFromIndex:1] : version;
  NSString *normalizedOtherVersion = [otherVersion hasPrefix:@"v"] || [otherVersion hasPrefix:@"V"] ? [otherVersion substringFromIndex:1] : otherVersion;
  NSArray<NSString *> *components = [normalizedVersion componentsSeparatedByString:@"."];
  NSArray<NSString *> *otherComponents = [normalizedOtherVersion componentsSeparatedByString:@"."];
  NSUInteger componentCount = MAX(components.count, otherComponents.count);
  for (NSUInteger index = 0; index < componentCount; index++) {
    NSInteger component = index < components.count ? components[index].integerValue : 0;
    NSInteger otherComponent = index < otherComponents.count ? otherComponents[index].integerValue : 0;
    if (component < otherComponent) {
      return NSOrderedAscending;
    }
    if (component > otherComponent) {
      return NSOrderedDescending;
    }
  }
  return NSOrderedSame;
}

static void SpectacleOpenURLString(NSString *URLString)
{
  NSURL *URL = [NSURL URLWithString:URLString];
  if (URL) {
    [[NSWorkspace sharedWorkspace] openURL:URL];
  }
}

- (IBAction)checkForUpdates:(id)sender
{
  [self checkForUpdatesWithUserInteraction:YES];
}

- (void)checkForUpdatesWithUserInteraction:(BOOL)userInteraction
{
  NSString *currentVersion = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:SpectacleReleasesAPIURL]];
  request.timeoutInterval = 15.0;
  [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
  [request setValue:@"Spectacle" forHTTPHeaderField:@"User-Agent"];
  NSURLSessionDataTask *dataTask = [[NSURLSession sharedSession] dataTaskWithRequest:request
                                                                  completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
    NSString *latestVersion = nil;
    NSString *downloadURLString = SpectacleReleasesPageURL;
    if (data) {
      id release = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
      if ([release isKindOfClass:[NSDictionary class]]) {
        id tagName = release[@"tag_name"];
        id htmlURL = release[@"html_url"];
        latestVersion = [tagName isKindOfClass:[NSString class]] ? tagName : nil;
        downloadURLString = [htmlURL isKindOfClass:[NSString class]] ? htmlURL : SpectacleReleasesPageURL;
      }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      [self handleUpdateCheckWithLatestVersion:latestVersion
                             downloadURLString:downloadURLString
                                currentVersion:currentVersion
                       userInteractionRequired:userInteraction
                                         error:error];
    });
  }];
  [dataTask resume];
}

- (void)handleUpdateCheckWithLatestVersion:(NSString *)latestVersion
                         downloadURLString:(NSString *)downloadURLString
                            currentVersion:(NSString *)currentVersion
                   userInteractionRequired:(BOOL)userInteraction
                                     error:(NSError *)error
{
  if (!latestVersion) {
    NSLog(@"Unable to check for updates; reason %@", error.localizedDescription ?: @"no release information was found");
    if (!userInteraction) {
      return;
    }
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = @"Unable to check for updates";
    alert.informativeText = @"Spectacle could not reach github.com. Please check your internet connection and try again.";
    [alert addButtonWithTitle:@"Open Releases Page"];
    [alert addButtonWithTitle:@"Cancel"];
    if ([alert runModal] == NSAlertFirstButtonReturn) {
      SpectacleOpenURLString(SpectacleReleasesPageURL);
    }
    return;
  }
  if (SpectacleCompareVersions(latestVersion, currentVersion) != NSOrderedDescending) {
    if (!userInteraction) {
      return;
    }
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"You're up to date";
    alert.informativeText = [NSString stringWithFormat:@"Spectacle %@ is the latest version available.", currentVersion];
    [alert runModal];
    return;
  }
  NSAlert *alert = [NSAlert new];
  alert.messageText = [NSString stringWithFormat:@"A new version of Spectacle is available: %@", latestVersion];
  alert.informativeText = [NSString stringWithFormat:@"You're currently running %@. Would you like to download the new version?", currentVersion];
  [alert addButtonWithTitle:@"Download"];
  [alert addButtonWithTitle:@"Later"];
  if ([alert runModal] == NSAlertFirstButtonReturn) {
    SpectacleOpenURLString(downloadURLString);
  }
}

@end
