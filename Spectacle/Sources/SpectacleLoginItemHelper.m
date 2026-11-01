#import "SpectacleLoginItemHelper.h"

#import <ServiceManagement/ServiceManagement.h>

@implementation SpectacleLoginItemHelper

+ (BOOL)isLoginItemEnabledForBundle:(NSBundle *)bundle
{
  // SMAppService is the supported replacement for the deprecated LSSharedFileList APIs
  // (deprecated since macOS 10.11 and no longer maintained by Apple).
  return [SMAppService mainAppService].status == SMAppServiceStatusEnabled;
}

+ (void)enableLoginItemForBundle:(NSBundle *)bundle
{
  NSError *error = nil;
  // The status can also be SMAppServiceStatusRequiresApproval, in which case the user has to
  // approve the login item under System Settings › General › Login Items.
  if ([SMAppService mainAppService].status == SMAppServiceStatusEnabled) {
    return;
  }
  if (![[SMAppService mainAppService] registerAndReturnError:&error]) {
    NSLog(@"Unable to register the login item; reason %@", error.localizedDescription);
  }
}

+ (void)disableLoginItemForBundle:(NSBundle *)bundle
{
  if ([SMAppService mainAppService].status != SMAppServiceStatusEnabled) {
    return;
  }
  NSError *error = nil;
  if (![[SMAppService mainAppService] unregisterAndReturnError:&error]) {
    NSLog(@"Unable to unregister the login item; reason %@", error.localizedDescription);
  }
}

@end
