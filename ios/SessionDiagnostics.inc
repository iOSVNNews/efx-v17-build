// Local diagnostics. Keep the current run and one preceding run in the log folder.
#include <mach/thread_act.h>
#include <mach/arm/thread_status.h>
#include <pthread.h>
#include <errno.h>

static NSString* gSessionDir;
static NSString* gSessionRoot;
static char gCrashPathUTF8[2048];
static std::atomic<double> gMainPulse{0}, gLastNetwork{0};
static std::atomic<int> gRequestsActive{0};

static NSString* rotateDiagnostics(NSString* root) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* previous = [root stringByAppendingPathComponent:@"previous-run"];
  NSString* staging = [gSupport stringByAppendingPathComponent:@"PreviousDiagnostics"];
  // Recover a rotation interrupted between the two renames.
  if ([fm fileExistsAtPath:staging]) {
    if (![fm fileExistsAtPath:root]) {
      [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
      [fm moveItemAtPath:staging toPath:previous error:nil];
    }
    if ([fm fileExistsAtPath:staging]) {
      // Preserve both sets if recovery cannot be completed; never truncate them.
      return [root stringByAppendingPathComponent:[NSString stringWithFormat:@"recovery-%d-%.0f", getpid(), NSDate.date.timeIntervalSince1970]];
    }
  }
  if ([fm contentsOfDirectoryAtPath:root error:nil].count) {
    [fm removeItemAtPath:previous error:nil];
    if (![fm moveItemAtPath:root toPath:staging error:nil])
      return [root stringByAppendingPathComponent:[NSString stringWithFormat:@"launch-%d-%.0f", getpid(), NSDate.date.timeIntervalSince1970]];
    [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
    [fm moveItemAtPath:staging toPath:previous error:nil];
  }
  return root;
}

static void diagnosticEvent(NSString* name, NSDictionary* value) {
  if (!gSessionDir || gDiagnosticIO) return;
  gDiagnosticIO = true;
  @try {
    NSMutableDictionary* v = [value mutableCopy];
    v[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    NSData* d = [NSJSONSerialization dataWithJSONObject:v options:NSJSONWritingFragmentsAllowed error:nil];
    if (d) {
      std::lock_guard<std::mutex> lock(gLogMu);
      NSString* path = [gSessionDir stringByAppendingPathComponent:name];
      FILE* f = fopen(path.fileSystemRepresentation, "ab");
      if (f) { fwrite(d.bytes, 1, d.length, f); fputc('\n', f); fclose(f); }
    }
  } @catch (...) {}
  gDiagnosticIO = false;
}

static void diagnosticIO(const char* op, const char* requested, const char* actual, long result, int code) {
  if (gDiagnosticIO || !requested || !actual) return;
  // All failed operations, plus successful game-resource opens (not every stat).
  bool resource = strstr(actual, "/pak/") || strstr(actual, "/cpk/") || strstr(actual, "/livedata/") || strstr(actual, "/Download/");
  if (result >= 0 && (!resource || (!strstr(op, "open")))) return;
  diagnosticEvent(@"fileio.jsonl", @{@"operation":@(op), @"requested":@(requested), @"actual":@(actual),
    @"result":@(result), @"errno":@(code), @"error":@(code ? strerror(code) : "")});
}

static void diagnosticSnapshot(NSString* reason) {
  @autoreleasepool {
    NSMutableArray* images = [NSMutableArray array];
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
      const mach_header* header = _dyld_get_image_header(i);
      if (!header || header->magic != MH_MAGIC_64) continue;
      const mach_header_64* h = (const mach_header_64*)header;
      const uint8_t* p = (const uint8_t*)(h + 1);
      NSString* uuid = @"";
      for (uint32_t j = 0; j < h->ncmds; ++j) {
        const load_command* lc = (const load_command*)p;
        if (lc->cmdsize < sizeof(load_command)) break;
        if (lc->cmd == LC_UUID) {
          const uuid_command* u = (const uuid_command*)lc;
          uuid = [[NSUUID alloc] initWithUUIDBytes:u->uuid].UUIDString;
        }
        p += lc->cmdsize;
      }
      [images addObject:@{@"path":@(_dyld_get_image_name(i) ?: ""), @"uuid":uuid,
        @"base":@((uint64_t)header), @"slide":@(_dyld_get_image_vmaddr_slide(i))}];
    }
    NSMutableArray* samples = [NSMutableArray array];
    thread_act_array_t threads = nullptr;
    mach_msg_type_number_t count = 0;
    kern_return_t kr = task_threads(mach_task_self(), &threads, &count);
    if (kr == KERN_SUCCESS) {
      for (mach_msg_type_number_t i = 0; i < count; ++i) {
        NSMutableDictionary* sample = [NSMutableDictionary dictionaryWithDictionary:@{@"port":@(threads[i])}];
#if defined(__arm64__)
        arm_thread_state64_t state = {};
        mach_msg_type_number_t n = ARM_THREAD_STATE64_COUNT;
        kern_return_t status = thread_get_state(threads[i], ARM_THREAD_STATE64, (thread_state_t)&state, &n);
        sample[@"status"] = @(status);
        if (status == KERN_SUCCESS) {
          uint64_t pc = arm_thread_state64_get_pc(state), lr = arm_thread_state64_get_lr(state);
          uint64_t fp = arm_thread_state64_get_fp(state), sp = arm_thread_state64_get_sp(state);
          sample[@"pc"] = @(pc); sample[@"lr"] = @(lr); sample[@"sp"] = @(sp);
          NSMutableArray* frames = [NSMutableArray arrayWithObjects:@(pc), @(lr), nil];
          // Live, unsuspended samples: frame-pointer walk is best effort, never a complete unwind.
          for (int j = 0; j < 48 && fp >= sp && fp - sp < (16ull << 20) && !(fp & 15); ++j) {
            uint64_t frame[2] = {}; vm_size_t read = 0;
            if (vm_read_overwrite(mach_task_self(), (vm_address_t)fp, sizeof(frame), (vm_address_t)frame, &read) != KERN_SUCCESS || read != sizeof(frame)) break;
            if (!frame[1] || frame[0] <= fp || frame[0] - fp > (1ull << 20)) break;
            [frames addObject:@(frame[1])]; fp = frame[0];
          }
          sample[@"frames"] = frames;
        }
#endif
        [samples addObject:sample];
        mach_port_deallocate(mach_task_self(), threads[i]);
      }
      vm_deallocate(mach_task_self(), (vm_address_t)threads, count * sizeof(thread_t));
    }
    diagnosticEvent(@"stacks.jsonl", @{@"reason":reason, @"task_threads_status":@(kr), @"threads":samples,
      @"images":images, @"unwind":@"live frame-pointer samples; may be incomplete",
      @"pending_requests":@(gRequestsActive.load()), @"main_heartbeat_age":@(CFAbsoluteTimeGetCurrent()-gMainPulse.load()),
      @"last_network_age":@(CFAbsoluteTimeGetCurrent()-gLastNetwork.load())});
  }
}

static void diagnosticInventory() {
  NSFileManager* fm = NSFileManager.defaultManager;
  for (NSString* root in @[@"pak", @"cpk", @"livedata", @"Download"]) {
    NSString* base = [gDocs stringByAppendingPathComponent:root];
    NSError* error = nil;
    NSArray* names = [fm subpathsOfDirectoryAtPath:base error:&error];
    if (error) diagnosticEvent(@"resources.jsonl", @{@"root":root, @"error":error.description});
    for (NSString* name in names) {
      NSDictionary* a = [fm attributesOfItemAtPath:[base stringByAppendingPathComponent:name] error:&error];
      diagnosticEvent(@"resources.jsonl", @{@"path":[root stringByAppendingPathComponent:name], @"size":@(a.fileSize),
        @"type":a.fileType ?: @"?", @"modified":@([a.fileModificationDate timeIntervalSince1970])});
    }
  }
}

static void diagnosticException(NSException* exception) {
  diagnosticEvent(@"exceptions.jsonl", @{@"name":exception.name ?: @"", @"reason":exception.reason ?: @"",
    @"stack":exception.callStackSymbols ?: @[]});
}

static void collectEngineLogs() {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSArray* roots = @[[gOriginalDocuments stringByAppendingPathComponent:@"UE4Game"],
    [gOriginalDocuments stringByAppendingPathComponent:@"PESmobile/Saved/Logs"],
    [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs"]];
  for (NSUInteger i=0; i<roots.count; ++i) {
    NSString* root=roots[i];
    NSDirectoryEnumerator* names=[fm enumeratorAtPath:root];
    for (NSString* name in names) {
      if (![name.pathExtension.lowercaseString isEqualToString:@"log"]) continue;
      NSString* source=[root stringByAppendingPathComponent:name];
      NSDictionary* attributes=[fm attributesOfItemAtPath:source error:nil];
      NSString* relative=[NSString stringWithFormat:@"engine/%lu/%@", (unsigned long)i, name];
      NSString* target=[gSessionDir stringByAppendingPathComponent:relative];
      NSDictionary* prior=[fm attributesOfItemAtPath:target error:nil];
      if (prior && prior.fileSize==attributes.fileSize &&
          [prior.fileModificationDate isEqualToDate:attributes.fileModificationDate]) continue;
      NSData* data=[NSData dataWithContentsOfFile:source options:NSDataReadingMappedIfSafe error:nil];
      [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
      NSError* error=nil;
      BOOL ok=data && [data writeToFile:target options:NSDataWritingAtomic error:&error];
      if (ok) [fm setAttributes:@{NSFileModificationDate:attributes.fileModificationDate ?: NSDate.date} ofItemAtPath:target error:nil];
      diagnosticEvent(@"engine-log-sources.jsonl", @{@"source":source, @"copy":relative, @"bytes":@(data.length), @"success":@(ok), @"error":error.description ?: @""});
    }
  }
}

static void initSessionDiagnostics() {
  gMainPulse = CFAbsoluteTimeGetCurrent(); gLastNetwork = CFAbsoluteTimeGetCurrent();
  strncpy(gCrashPathUTF8, gCrashLogPath.fileSystemRepresentation, sizeof(gCrashPathUTF8)-1);
  NSString* stream = [gSessionDir stringByAppendingPathComponent:@"stdout-stderr.log"];
  int fd = open(stream.fileSystemRepresentation, O_CREAT|O_WRONLY|O_TRUNC, 0644);
  if (fd >= 0) { fflush(stdout); fflush(stderr); dup2(fd, STDOUT_FILENO); dup2(fd, STDERR_FILENO); if (fd > 2) close(fd); }
  setvbuf(stdout, nullptr, _IONBF, 0); setvbuf(stderr, nullptr, _IONBF, 0);
  NSSetUncaughtExceptionHandler(diagnosticException);
  diagnosticEvent(@"session.jsonl", @{@"event":@"start", @"app":NSBundle.mainBundle.bundleIdentifier ?: @"",
    @"build":[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
    @"os":NSProcessInfo.processInfo.operatingSystemVersionString, @"session":gSessionDir,
    @"pid":@(getpid()), @"retention":@"current run plus previous-run; background events do not establish termination cause",
    @"coverage":@"adapter, in-process requests, Python, rebound file operations, stdout/stderr, self-process stack samples; OS unified logs and jetsam reports are external"});
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ diagnosticInventory(); collectEngineLogs(); diagnosticSnapshot(@"startup"); });
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer* t) { gMainPulse = CFAbsoluteTimeGetCurrent(); }];
  });
  static dispatch_source_t timer;
  timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, 30*NSEC_PER_SEC), 30*NSEC_PER_SEC, NSEC_PER_SEC);
  dispatch_source_set_event_handler(timer, ^{
    @autoreleasepool {
      double now = CFAbsoluteTimeGetCurrent();
      collectEngineLogs();
      diagnosticEvent(@"heartbeat.jsonl", @{@"main_age":@(now-gMainPulse.load()), @"network_age":@(now-gLastNetwork.load()),
        @"pending_requests":@(gRequestsActive.load()), @"application_state":@(UIApplication.sharedApplication.applicationState)});
      static double lastSample = 0;
      if (now-lastSample >= 120 && (now-gMainPulse.load()>15 || gRequestsActive.load()>0 || now-gLastNetwork.load()>45)) {
        lastSample = now; diagnosticSnapshot(@"periodic inactivity observation (not proof of a hang)");
      }
    }
  });
  dispatch_resume(timer);
}
