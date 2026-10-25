// Native rendering updates are staged by Python while Unreal is running.
// Activate the completed directory only at the next launch, before UE mounts it.
static BOOL nativeUpdateName(NSString* value, NSString* prefix) {
  return [value isKindOfClass:NSString.class] && [value hasPrefix:prefix] &&
    [value.lastPathComponent isEqualToString:value] && ![value containsString:@".."];
}

static BOOL activatePendingNativeBase(NSString* root, NSString* diagnostics) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* pendingPath = [root stringByAppendingPathComponent:@"native-render-pending.json"];
  NSData* data = [NSData dataWithContentsOfFile:pendingPath];
  if (!data) return NO;
  NSDictionary* pending = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (![pending isKindOfClass:NSDictionary.class] ||
      !nativeUpdateName(pending[@"pak_staging"], @"pak.native-staging-") ||
      !nativeUpdateName(pending[@"pak_backup"], @"pak.before-native-") ||
      !nativeUpdateName(pending[@"marker_staging"], @"china-data-installed.native-staging-") ||
      !nativeUpdateName(pending[@"marker_backup"], @"china-data-installed.before-native-")) {
    ZLog(@"[NATIVE_BASE] Invalid pending descriptor; data preserved"); return NO;
  }
  NSString* current = [root stringByAppendingPathComponent:@"pak"];
  NSString* staging = [root stringByAppendingPathComponent:pending[@"pak_staging"]];
  NSString* backup = [root stringByAppendingPathComponent:pending[@"pak_backup"]];
  NSString* marker = [root stringByAppendingPathComponent:@"china-data-installed.json"];
  NSString* markerStaging = [root stringByAppendingPathComponent:pending[@"marker_staging"]];
  NSString* markerHolding = [[root stringByAppendingPathComponent:pending[@"marker_backup"]] stringByAppendingString:@".active"];
  NSData* newData = [NSData dataWithContentsOfFile:markerStaging];
  NSDictionary* next = newData ? [NSJSONSerialization JSONObjectWithData:newData options:0 error:nil] : nil;
  if (!next) {
    // A launch may have ended after publishing the new marker.
    NSData* activeData = [NSData dataWithContentsOfFile:marker];
    next = activeData ? [NSJSONSerialization JSONObjectWithData:activeData options:0 error:nil] : nil;
  }
  NSString* fingerprint = pending[@"manifest_sha256"];
  if (![next isKindOfClass:NSDictionary.class] || ![fingerprint isKindOfClass:NSString.class] ||
      fingerprint.length != 64 || ![next[@"native_render_overlay"][@"manifest_sha256"] isEqual:fingerprint]) {
    ZLog(@"[NATIVE_BASE] Pending marker mismatch; data preserved"); return NO;
  }
  NSError* error = nil;
  if ([fm fileExistsAtPath:staging]) {
    if ([fm fileExistsAtPath:current] && ![fm moveItemAtPath:current toPath:backup error:&error]) goto failed;
    if (![fm moveItemAtPath:staging toPath:current error:&error]) goto failed;
  } else if (![fm fileExistsAtPath:backup] || ![fm fileExistsAtPath:current]) {
    ZLog(@"[NATIVE_BASE] Pending files missing; data preserved"); return NO;
  }
  if ([fm fileExistsAtPath:markerStaging]) {
    if ([fm fileExistsAtPath:marker] && ![fm moveItemAtPath:marker toPath:markerHolding error:&error]) goto failed;
    if (![fm moveItemAtPath:markerStaging toPath:marker error:&error]) goto failed;
  }
  [fm createDirectoryAtPath:diagnostics withIntermediateDirectories:YES attributes:nil error:nil];
  [fm moveItemAtPath:pendingPath toPath:[diagnostics stringByAppendingPathComponent:
      [NSString stringWithFormat:@"native-render-activated-%@.json",NSUUID.UUID.UUIDString]] error:nil];
  ZLog(@"[NATIVE_BASE] Activated verified iOS rendering before Unreal startup (backup %@)",backup);
  return YES;
failed:
  if ([fm fileExistsAtPath:backup]) {
    if ([fm fileExistsAtPath:current] && ![fm fileExistsAtPath:staging])
      [fm moveItemAtPath:current toPath:staging error:nil];
    if (![fm fileExistsAtPath:current]) [fm moveItemAtPath:backup toPath:current error:nil];
  }
  if (![fm fileExistsAtPath:marker] && [fm fileExistsAtPath:markerHolding])
    [fm moveItemAtPath:markerHolding toPath:marker error:nil];
  ZLog(@"[NATIVE_BASE] Activation deferred; previous graphics restored: %@",error);
  return NO;
}
