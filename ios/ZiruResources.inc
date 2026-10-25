// File updates are hash-authorized, staged, and recoverable. Pack names and
// file sizes do not identify a platform or a broken mod.
static NSString* resourceSHA256(NSString* path) {
  NSInputStream* stream = [NSInputStream inputStreamWithFileAtPath:path];
  [stream open];
  CC_SHA256_CTX ctx; CC_SHA256_Init(&ctx);
  uint8_t buffer[65536]; NSInteger count;
  while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0)
    CC_SHA256_Update(&ctx, buffer, (CC_LONG)count);
  BOOL ok = count == 0 && stream.streamError == nil;
  [stream close];
  if (!ok) return nil;
  unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(digest, &ctx);
  NSMutableString* result = [NSMutableString string];
  for (unsigned char c : digest) [result appendFormat:@"%02x", c];
  return result;
}

static NSDictionary* resourceRepairManifest() {
  NSString* path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ziru/resource-repairs.json"];
  NSData* data = [NSData dataWithContentsOfFile:path];
  id manifest = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [manifest isKindOfClass:NSDictionary.class] ? manifest : @{};
}

static BOOL installResourceGroup(NSArray<NSString*>* names, NSString* sourceDir,
                                NSString* destDir, NSDictionary* authorizations) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* receiptPath = [gDocs stringByAppendingPathComponent:@"PES2027-managed-resources.plist"];
  NSMutableDictionary* receipts = [[NSDictionary dictionaryWithContentsOfFile:receiptPath] mutableCopy];
  if (!receipts) receipts = [NSMutableDictionary dictionary];
  NSMutableDictionary* hashes = [NSMutableDictionary dictionary];
  BOOL changed = NO;
  for (NSString* name in names) {
    NSString* src = [sourceDir stringByAppendingPathComponent:name];
    NSString* dst = [destDir stringByAppendingPathComponent:name];
    NSString* key = [NSString stringWithFormat:@"%@/%@", destDir.lastPathComponent, name];
    NSDictionary* authorization = authorizations[name];
    NSString* desired = resourceSHA256(src);
    // An incomplete bundle or stale manifest must never remove working data.
    if (!desired || ![desired isEqualToString:authorization[@"sha256"]]) {
      ZLog(@"[RESOURCE_REPAIR] Bundle integrity failed: %@", src); return NO;
    }
    hashes[name] = desired;
    NSString* current = resourceSHA256(dst);
    if ([current isEqualToString:desired]) continue;
    changed = YES;
    NSString* link = [fm destinationOfSymbolicLinkAtPath:dst error:nil];
    BOOL exists = [fm fileExistsAtPath:dst];
    if (exists) {
      NSArray* originals = authorization[@"original_sha256"];
      if ([originals isKindOfClass:NSString.class]) originals = @[(id)originals];
      BOOL known = current && ([originals containsObject:current] || [current isEqualToString:receipts[key]]);
      // Broken bundle links may be refreshed; links to user files and every
      // unrecognized real file are preserved, including small .pak files.
      if (!known) {
        ZLog(@"[RESOURCE_PRESERVE] Custom container/CPK kept: %@", dst); return NO;
      }
    } else if (link && ![link containsString:@"/PESmobile.app/ziru/"]) {
      ZLog(@"[RESOURCE_PRESERVE] Unrecognized broken link kept: %@", dst); return NO;
    }
  }
  if (!changed) return YES;
  NSString* stage = [[gDocs stringByAppendingPathComponent:@"PES2027-repair-backups"]
      stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  NSError* error = nil;
  if (![fm createDirectoryAtPath:stage withIntermediateDirectories:YES attributes:nil error:&error] ||
      ![fm createDirectoryAtPath:destDir withIntermediateDirectories:YES attributes:nil error:&error]) return NO;
  // Stage the complete triple before moving any destination.
  for (NSString* name in names) {
    NSString* staged = [stage stringByAppendingPathComponent:[@"new-" stringByAppendingString:name]];
    if (![fm copyItemAtPath:[sourceDir stringByAppendingPathComponent:name] toPath:staged error:&error] ||
        ![resourceSHA256(staged) isEqualToString:hashes[name]]) {
      ZLog(@"[RESOURCE_REPAIR] Staging failed, originals untouched: %@ (%@)", name, error); return NO;
    }
  }
  NSMutableArray* saved = [NSMutableArray array];
  NSMutableArray* installed = [NSMutableArray array];
  BOOL ok = YES;
  for (NSString* name in names) {
    NSString* dst = [destDir stringByAppendingPathComponent:name];
    if ([fm fileExistsAtPath:dst] || [fm destinationOfSymbolicLinkAtPath:dst error:nil]) {
      if (![fm moveItemAtPath:dst toPath:[stage stringByAppendingPathComponent:name] error:&error]) { ok = NO; break; }
      [saved addObject:name];
    }
    if (![fm moveItemAtPath:[stage stringByAppendingPathComponent:[@"new-" stringByAppendingString:name]] toPath:dst error:&error]) { ok = NO; break; }
    [installed addObject:name];
  }
  if (!ok) {
    for (NSString* name in installed) unlink([destDir stringByAppendingPathComponent:name].fileSystemRepresentation);
    for (NSString* name in saved) [fm moveItemAtPath:[stage stringByAppendingPathComponent:name]
        toPath:[destDir stringByAppendingPathComponent:name] error:nil];
    ZLog(@"[RESOURCE_REPAIR] Rolled back container update: %@", error); return NO;
  }
  for (NSString* name in names) receipts[[NSString stringWithFormat:@"%@/%@", destDir.lastPathComponent, name]] = hashes[name];
  [receipts writeToFile:receiptPath atomically:YES];
  ZLog(@"[RESOURCE_REPAIR] Installed %@; previous files preserved in %@", names, stage);
  return YES;
}

static void installExtraResourceGroups(NSString* sourceDir, NSString* destDir) {
  NSDictionary* manifest = resourceRepairManifest()[@"pak_extra"];
  NSFileManager* fm = NSFileManager.defaultManager;
  for (NSString* file in [fm contentsOfDirectoryAtPath:sourceDir error:nil]) {
    if (![file.pathExtension isEqualToString:@"utoc"]) continue;
    NSString* stem = file.stringByDeletingPathExtension;
    NSArray* group = @[[stem stringByAppendingString:@".pak"], [stem stringByAppendingString:@".utoc"], [stem stringByAppendingString:@".ucas"]];
    installResourceGroup(group, sourceDir, destDir, manifest);
  }
}
