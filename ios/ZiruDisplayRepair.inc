// Download caches are moved/read by Foundation as well as libc. Redirecting
// only fopen/stat splits one cache file across two locations.
static bool isTemporaryDownloadPath(const char* path) {
  return path && (strstr(path, "/tmp/") || strstr(path, "/TempData/") ||
                  strstr(path, "/Library/Caches/"));
}

static NSString* cleanLegacyGraphics(NSString* text, BOOL commandLine) {
  NSString* keys = @"(?:TonemapperFilm|MobileHDR|Color\\.(?:Saturation|Contrast|Mid)|TonemapperGamma)";
  NSString* pattern = commandLine
    ? [NSString stringWithFormat:@"(?i)(?<!\\S)-r\\.%@=[^\\s]+", keys]
    : [NSString stringWithFormat:@"(?im)^[ \\t]*r\\.%@[ \\t]*=[^\\r\\n]*(?:\\r?\\n|$)", keys];
  NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
  return [re stringByReplacingMatchesInString:text options:0 range:NSMakeRange(0,text.length) withTemplate:@""];
}

static void repairSavedGraphics(NSString* documents, NSString* diagnostics) {
  // Old adapters changed command lines; Unreal can persist the same variables
  // in saved INIs. Removing only the command line leaves that second copy live.
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* library = [documents.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"Library"];
  NSArray* configs = @[
    [library stringByAppendingPathComponent:@"Preferences/Unreal Engine/PesMobile/IOS"],
    [library stringByAppendingPathComponent:@"PesMobile/Saved/Config/IOS"],
    [documents stringByAppendingPathComponent:@"UnrealGame/PesMobile/PesMobile/Saved/Config/IOS"],
    [documents stringByAppendingPathComponent:@"Saved/Config/IOS"]];
  NSMutableArray* paths = [NSMutableArray array];
  for (NSString* dir in configs)
    for (NSString* name in @[@"Engine.ini", @"GameUserSettings.ini", @"Scalability.ini"])
      [paths addObject:[dir stringByAppendingPathComponent:name]];
  for (NSString* name in @[@"uecommandline.txt", @"ue4commandline.txt"])
    [paths addObject:[documents stringByAppendingPathComponent:name]];
  NSUInteger index = 0;
  for (NSString* path in paths) {
    ++index;
    NSString* before = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!before) continue;
    NSString* after = cleanLegacyGraphics(before, [path hasSuffix:@"commandline.txt"]);
    if ([after isEqualToString:before]) continue;
    NSString* backup = [diagnostics stringByAppendingPathComponent:
      [NSString stringWithFormat:@"graphics-before-%@-%lu-%@",documents.lastPathComponent,(unsigned long)index,path.lastPathComponent]];
    if (![fm fileExistsAtPath:backup] && ![before writeToFile:backup atomically:YES encoding:NSUTF8StringEncoding error:nil]) continue;
    NSError* error = nil;
    if ([after writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error])
      ZLog(@"[GRAPHICS] Restored native color defaults in %@ (backup %@)",path,backup);
    else ZLog(@"[GRAPHICS] Could not repair %@: %@",path,error);
  }
}
