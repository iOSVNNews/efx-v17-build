// ZiruOffline.dylib — loaded into eFootball iOS 11.1.1 (PESmobile).
//  * Runs the C++ port of the Ziru offline server in-process.
//  * Redirects the game's HttpImpl* requests to https://127.0.0.1:8085 (same as Ziru's Android HttpImpl patch)
//    and answers them through an NSURLProtocol — no sockets, no TLS.
//  * Gates the UE4 launch until the separate data pack (pak/cpk/livedata) has been imported.
//  * Diagnostics: fileio.log, crash.log, ziru.log, offline_server.log, network logging.
//  * Commentary protection: prevents deletion of dt510 Vietnamese commentary.
//  * PES21 stadium design with unremovable 'Made by iOSVN' watermark.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#include <atomic>
#include <memory>
#include <mutex>
#include <string>
#include <execinfo.h>
#include <ctime>

#import <dirent.h>

static int (*orig_unlink)(const char *path);
static int (*orig_unlinkat)(int fd, const char *path, int flag);
static int (*orig_remove)(const char *path);
static int (*orig_open)(const char *path, int oflag, ...);
static int (*orig_stat)(const char *path, struct stat *buf);
static int (*orig_access)(const char *path, int amode);
static FILE* (*orig_fopen)(const char *filename, const char *mode);
static DIR* (*orig_opendir)(const char *name);
static void (*orig_exit)(int);
static void (*orig__exit)(int);
static void (*orig_abort)(void);

#include "../core/datapack.hpp"
#include "../core/modpack.hpp"
#include "../core/server.hpp"
#include "ZiruFontPak.h"
#include "ZiruWebView.h"

#define ZIRU_MOD_VERSION "1.1.1"
#ifdef PES_NO_PUBLIC
#define ZIRU_WATERMARK @"⚡ Zero??"
#define ZIRU_WATERMARK_KEY @"Zero??"
#else
#define ZIRU_WATERMARK @"⚡ Made by iOSVN"
#define ZIRU_WATERMARK_KEY @"Made by iOSVN"
#endif

// ---------------------------------------------------------------- theme colors (PES21)
static inline UIColor* PESLime() { return [UIColor colorWithRed:0.77 green:0.98 blue:0.22 alpha:1.0]; }
static inline UIColor* PESNight() { return [UIColor colorWithRed:0.025 green:0.045 blue:0.065 alpha:1.0]; }
static inline UIColor* PESCyan() { return [UIColor colorWithRed:0.27 green:0.86 blue:0.92 alpha:1.0]; }
static inline UIColor* PESMuted() { return [UIColor colorWithRed:0.65 green:0.73 blue:0.75 alpha:1.0]; }

// ---------------------------------------------------------------- paths & logs
static NSString* gDocs;
static NSString* gOriginalDocuments;
static NSString* gEfootxiDataMode;
static bool gEfootxiPrepared = false;
static char gDocsUTF8[1024] = {0};
static char gTerminationPathUTF8[2048] = {0};
static NSString* gSupport;   // Library/Application Support/PES2027
static NSString* gLogPath;
static NSString* gFileIoLogPath;
static NSString* gCrashLogPath;
static NSString* gBundleAssets;
static std::mutex gLogMu;
static thread_local bool gDiagnosticIO = false;
static thread_local bool gBackendIO = false;
struct BackendIOScope {
  bool previous;
  BackendIOScope() : previous(gBackendIO) { gBackendIO = true; }
  ~BackendIOScope() { gBackendIO = previous; }
};

static void ZLog(NSString* fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void ZLog(NSString* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  NSString* s = [[NSString alloc] initWithFormat:fmt arguments:ap];
  va_end(ap);
  NSLog(@"[Ziru] %@", s);
  if (!gLogPath) return;
  std::lock_guard<std::mutex> g(gLogMu);
  static NSDateFormatter* df;
  if (!df) { df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss.SSS"; }
  NSString* line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], s];
  bool previous = gDiagnosticIO; gDiagnosticIO = true;
  FILE* f = fopen(gLogPath.fileSystemRepresentation, "a");
  if (f) { fputs(line.UTF8String, f); fclose(f); }
  gDiagnosticIO = previous;
}

static void logSink(int level, const char* tag, const char* msg) {
  ZLog(@"[level=%d] %s %s", level, tag, msg);
}

#include "SessionDiagnostics.inc"
#include "EfootxiPython.inc"

static zd::Layout layout() {
  zd::Layout L;
  L.gameDataRoot = std::string(gSupport.fileSystemRepresentation) + "/GameData";
  L.documents = gDocs.fileSystemRepresentation;
  return L;
}

static void initPaths() {
  gDocs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  gOriginalDocuments = gDocs;
#ifdef EFOOTXI_IOS
  gEfootxiDataMode = [NSBundle.mainBundle objectForInfoDictionaryKey:@"EfootxiDataMode"] ?: @"global";
  gDocs = [gOriginalDocuments stringByAppendingPathComponent:[gEfootxiDataMode isEqualToString:@"china-data"] ? @"Efootxi-China-Data" : @"Efootxi-Global-Data"];
  [NSFileManager.defaultManager createDirectoryAtPath:gDocs withIntermediateDirectories:YES attributes:nil error:nil];
#endif
  if (gDocs) {
    strncpy(gDocsUTF8, gDocs.fileSystemRepresentation, sizeof(gDocsUTF8) - 1);
  }
  NSString* lib = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
  gSupport = [lib stringByAppendingPathComponent:@"PES2027"];
#ifdef EFOOTXI_IOS
  gSupport = [lib stringByAppendingPathComponent:[gEfootxiDataMode isEqualToString:@"china-data"] ? @"Efootxi2027-China-Adapter" : @"Efootxi2027-Global-Adapter"];
#endif
  NSFileManager* fm = NSFileManager.defaultManager;
  [fm createDirectoryAtPath:[gSupport stringByAppendingPathComponent:@"GameData"] withIntermediateDirectories:YES attributes:nil error:nil];
  [fm createDirectoryAtPath:[gSupport stringByAppendingPathComponent:@"Save"] withIntermediateDirectories:YES attributes:nil error:nil];
  // Only heavy resources are disposable. Saves should remain eligible for backup.
  [[NSURL fileURLWithPath:gSupport] setResourceValue:@NO forKey:NSURLIsExcludedFromBackupKey error:nil];
  [[NSURL fileURLWithPath:[gSupport stringByAppendingPathComponent:@"GameData"]]
      setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
#ifdef EFOOTXI_IOS
  gSessionRoot = [gOriginalDocuments stringByAppendingPathComponent:[gEfootxiDataMode isEqualToString:@"china-data"] ? @"Efootxi-China-logs" : @"Efootxi-Global-logs"];
#else
  gSessionRoot = [gDocs stringByAppendingPathComponent:@"PES2027-logs"];
#endif
  // A relaunch after a crash must not erase the request/stack that explains it.
  gSessionDir = rotateDiagnostics(gSessionRoot);
  [fm createDirectoryAtPath:gSessionDir withIntermediateDirectories:YES attributes:nil error:nil];
  gLogPath = [gSessionDir stringByAppendingPathComponent:@"adapter.log"];
  gFileIoLogPath = [gSessionDir stringByAppendingPathComponent:@"fileio.log"];
  gCrashLogPath = [gSessionDir stringByAppendingPathComponent:@"crash.log"];
  strncpy(gTerminationPathUTF8, [gSessionDir stringByAppendingPathComponent:@"termination.log"].fileSystemRepresentation,
    sizeof(gTerminationPathUTF8)-1);

  gBundleAssets = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ziru"];
  zs::setLogSink(logSink);
}

// ---------------------------------------------------------------- crash handler (crash.log)
// Keep the fatal-signal path free of Objective-C, allocation and locks.
static void crashHex(int fd, const char* label, uint64_t value) {
  char text[96]; size_t n=0;
  while (*label && n<64) text[n++]=*label++;
  text[n++]='0'; text[n++]='x';
  for (int shift=60; shift>=0; shift-=4) text[n++]="0123456789abcdef"[(value>>shift)&15];
  text[n++]='\n'; (void)write(fd,text,n);
}

static void crashHandler(int sig, siginfo_t* info, void* ucontext) {
  static volatile sig_atomic_t crashed = 0;
  if (crashed++) _exit(128+sig);
  gDiagnosticIO=true;
  int fd = gCrashPathUTF8[0] ? open(gCrashPathUTF8,O_WRONLY|O_CREAT|O_APPEND,0644) : -1;
  if (fd<0) fd=STDERR_FILENO;
  static const char marker[]="\nFATAL SIGNAL (addresses match stacks.jsonl image UUID/ASLR map)\n";
  (void)write(fd,marker,sizeof(marker)-1);
  crashHex(fd,"signal=",sig);
  crashHex(fd,"fault=",(uintptr_t)(info ? info->si_addr : nullptr));
#if defined(__arm64__)
  ucontext_t* uc=(ucontext_t*)ucontext;
  if (uc && uc->uc_mcontext) {
    crashHex(fd,"pc=",uc->uc_mcontext->__ss.__pc);
    crashHex(fd,"lr=",uc->uc_mcontext->__ss.__lr);
    crashHex(fd,"fp=",uc->uc_mcontext->__ss.__fp);
    crashHex(fd,"sp=",uc->uc_mcontext->__ss.__sp);
  }
#endif
  if (fd>2) close(fd);
  // SA_RESETHAND has restored the default action. Preserve the OS crash report.
  kill(getpid(),sig);
}

static void initCrashHandler() {
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = crashHandler;
  sa.sa_flags = SA_SIGINFO | SA_NODEFER | SA_RESETHAND;
  sigemptyset(&sa.sa_mask);
  sigaction(SIGSEGV, &sa, NULL);
  sigaction(SIGBUS, &sa, NULL);
  sigaction(SIGABRT, &sa, NULL);
  sigaction(SIGILL, &sa, NULL);
  sigaction(SIGFPE, &sa, NULL);
  sigaction(SIGTRAP, &sa, NULL);
}

// UE can terminate explicitly without producing an iOS exception report. Record
// those calls separately from signals; neither establishes a user swipe gesture.
// Only the main executable's imported symbols are rebound below.
static void recordTermination(const char* operation, int status) {
  int fd = gTerminationPathUTF8[0] ? open(gTerminationPathUTF8, O_CREAT|O_WRONLY|O_APPEND, 0644) : -1;
  if (fd < 0) return;
  (void)write(fd, operation, strlen(operation)); (void)write(fd, "\n", 1);
  crashHex(fd, "unix_time=", (uint64_t)time(nullptr));
  crashHex(fd, "status=", (uint64_t)status);
  void* frames[64]; int count=backtrace(frames, 64);
  for (int i=0; i<count; ++i) crashHex(fd, "frame=", (uintptr_t)frames[i]);
  (void)fsync(fd); close(fd);
}
__attribute__((noreturn)) static void hook_exit(int status) {
  recordTermination("main executable called exit", status);
  if (orig_exit) orig_exit(status);
  _exit(status);
}
__attribute__((noreturn)) static void hook__exit(int status) {
  recordTermination("main executable called _exit", status);
  if (orig__exit) orig__exit(status);
  _exit(status);
}
__attribute__((noreturn)) static void hook_abort() {
  recordTermination("main executable called abort", SIGABRT);
  if (orig_abort) orig_abort();
  abort();
}

// ---------------------------------------------------------------- fishhook (Mach-O symbol rebinding)
struct z_rebinding {
  const char *name;
  void *replacement;
  void **replaced;
};

struct z_rebindings_entry {
  struct z_rebinding *rebindings;
  size_t rebindings_nel;
  struct z_rebindings_entry *next;
};

static struct z_rebindings_entry *_z_rebindings_head = NULL;

static int z_prepend_rebindings(struct z_rebindings_entry **rebindings_head,
                                struct z_rebinding rebindings[],
                                size_t nel) {
  struct z_rebindings_entry *new_entry = (struct z_rebindings_entry *)malloc(sizeof(struct z_rebindings_entry));
  if (!new_entry) return -1;
  new_entry->rebindings = (struct z_rebinding *)malloc(sizeof(struct z_rebinding) * nel);
  if (!new_entry->rebindings) {
    free(new_entry);
    return -1;
  }
  memcpy(new_entry->rebindings, rebindings, sizeof(struct z_rebinding) * nel);
  new_entry->rebindings_nel = nel;
  new_entry->next = *rebindings_head;
  *rebindings_head = new_entry;
  return 0;
}

static void z_perform_rebinding_with_section(struct z_rebindings_entry *rebindings,
                                             section_64 *sect,
                                             intptr_t slide,
                                             nlist_64 *symtab,
                                             char *strtab,
                                             uint32_t *indirect_symtab) {
  uint32_t *indirect_symbol_indices = indirect_symtab + sect->reserved1;
  void **indirect_symbol_bindings = (void **)((uintptr_t)slide + sect->addr);

  // vm_protect to allow writing to read-only sections like __DATA_CONST
  size_t psize = (size_t)getpagesize();
  vm_address_t page_start = ((vm_address_t)indirect_symbol_bindings) & ~(psize - 1);
  vm_address_t page_end = (((vm_address_t)indirect_symbol_bindings) + sect->size + psize - 1) & ~(psize - 1);
  vm_size_t page_size = (vm_size_t)(page_end - page_start);
  kern_return_t err = vm_protect(mach_task_self(), page_start, page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
  if (err != KERN_SUCCESS) {
    err = vm_protect(mach_task_self(), page_start, page_size, 0, VM_PROT_READ | VM_PROT_WRITE);
  }
  if (err != KERN_SUCCESS) {
    return; // Prevent SIGBUS (Bus error: 10) on iOS 16 JB/TrollStore when memory page is strictly protected
  }

  for (uint32_t i = 0; i < sect->size / sizeof(void *); i++) {
    uint32_t symtab_index = indirect_symbol_indices[i];
    if (symtab_index == INDIRECT_SYMBOL_ABS || symtab_index == INDIRECT_SYMBOL_LOCAL ||
        symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
      continue;
    }
    uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
    char *symbol_name = strtab + strtab_offset;
    bool has_leading_underscore = symbol_name[0] == '_';
    struct z_rebindings_entry *cur = rebindings;
    while (cur) {
      for (size_t j = 0; j < cur->rebindings_nel; j++) {
        const char *want = cur->rebindings[j].name;
        if (has_leading_underscore && strcmp(&symbol_name[1], want) == 0) {
          if (cur->rebindings[j].replaced != NULL &&
              *(cur->rebindings[j].replaced) == NULL &&
              indirect_symbol_bindings[i] != cur->rebindings[j].replacement) {
            *(cur->rebindings[j].replaced) = indirect_symbol_bindings[i];
          }
          indirect_symbol_bindings[i] = cur->rebindings[j].replacement;
          goto symbol_done;
        }
      }
      cur = cur->next;
    }
  symbol_done:;
  }
}

static void z_rebind_symbols_for_image(struct z_rebindings_entry *rebindings,
                                       const struct mach_header *header,
                                       intptr_t slide) {
  Dl_info info;
  if (dladdr(header, &info) == 0) return;

  segment_command_64 *cur_seg_cmd;
  segment_command_64 *linkedit_segment = NULL;
  struct symtab_command *symtab_cmd = NULL;
  struct dysymtab_command *dysymtab_cmd = NULL;

  uintptr_t cur = (uintptr_t)header + sizeof(mach_header_64);
  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_64 *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_64) {
      if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
        linkedit_segment = cur_seg_cmd;
      }
    } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
      symtab_cmd = (struct symtab_command *)cur_seg_cmd;
    } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
      dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
    }
  }

  if (!linkedit_segment || !symtab_cmd || !dysymtab_cmd) return;

  uintptr_t linkedit_base = (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
  nlist_64 *symtab = (nlist_64 *)(linkedit_base + symtab_cmd->symoff);
  char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
  uint32_t *indirect_symtab = (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

  cur = (uintptr_t)header + sizeof(mach_header_64);
  for (uint32_t i = 0; i < header->ncmds; i++, cur += cur_seg_cmd->cmdsize) {
    cur_seg_cmd = (segment_command_64 *)cur;
    if (cur_seg_cmd->cmd == LC_SEGMENT_64) {
      if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
          strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) {
        continue;
      }
      for (uint32_t j = 0; j < cur_seg_cmd->nsects; j++) {
        section_64 *sect = (section_64 *)(cur + sizeof(segment_command_64)) + j;
        uint32_t type = sect->flags & SECTION_TYPE;
        if (type == S_LAZY_SYMBOL_POINTERS || type == S_NON_LAZY_SYMBOL_POINTERS) {
          z_perform_rebinding_with_section(rebindings, sect, slide, symtab, strtab, indirect_symtab);
        }
      }
    }
  }
}

static int z_rebind_symbols(struct z_rebinding rebindings[], size_t nel) {
  int r = z_prepend_rebindings(&_z_rebindings_head, rebindings, nel);
  if (r < 0) return r;
  // Rebind ONLY for the main executable PESmobile (image 0)
  // NEVER hook dyld shared cache or system frameworks, which causes crash on iOS
  const struct mach_header *header = _dyld_get_image_header(0);
  intptr_t slide = _dyld_get_image_vmaddr_slide(0);
  if (header) {
    z_rebind_symbols_for_image(_z_rebindings_head, header, slide);
  }
  return 0;
}

#ifdef PES_NO_PUBLIC
#include "PnpStun.inc"
// Reads stun_host / stun_port from PESmobile.app/efootxi/online.json (written by build_online_ipa.py).
static void pnpInstallStun() {
  NSString* path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"efootxi/online.json"];
  NSData* data = [NSData dataWithContentsOfFile:path];
  NSDictionary* cfg = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSString* host = [cfg isKindOfClass:NSDictionary.class] ? cfg[@"stun_host"] : nil;
  int port = [cfg isKindOfClass:NSDictionary.class] ? [cfg[@"stun_port"] intValue] : 0;
  if (![host isKindOfClass:NSString.class] || !pnpstun::configure(host.UTF8String, port)) {
    ZLog(@"[PNP] STUN redirect OFF (online.json missing stun_host IPv4)");
    return;
  }
  pnpstun::real_gai = (int (*)(const char*, const char*, const struct addrinfo*, struct addrinfo**))dlsym(RTLD_DEFAULT, "getaddrinfo");
  pnpstun::real_ghn = (struct hostent * (*)(const char*))dlsym(RTLD_DEFAULT, "gethostbyname");
  pnpstun::real_sendto = (ssize_t (*)(int, const void*, size_t, int, const struct sockaddr*, socklen_t))dlsym(RTLD_DEFAULT, "sendto");
  pnpstun::real_recvfrom = (ssize_t (*)(int, void*, size_t, int, struct sockaddr*, socklen_t*))dlsym(RTLD_DEFAULT, "recvfrom");
  struct z_rebinding stun[] = {
    {"getaddrinfo", (void*)pnpstun::hook_gai, nullptr},
    {"gethostbyname", (void*)pnpstun::hook_ghn, nullptr},
    {"sendto", (void*)pnpstun::hook_sendto, nullptr},
    {"recvfrom", (void*)pnpstun::hook_recvfrom, nullptr},
  };
  z_rebind_symbols(stun, sizeof(stun) / sizeof(stun[0]));
  ZLog(@"[PNP] STUN *.stun.service.konami.net -> %@:%d", host, port ?: 3478);
}
#endif

// ---------------------------------------------------------------- file I/O interception & BLV protection
// ---------------------------------------------------------------- Commentary (BLV) protection
static BOOL isCommentaryPath(const char* path) {
  if (!path) return NO;
  const char* name = strrchr(path, '/');
  return strcmp(name ? name + 1 : path, "dt510_eng_mobile_all.cpk") == 0;
}

static int hook_unlink(const char *path) {
  if (isCommentaryPath(path)) {
    ZLog(@"[BLV_PROTECT] Prevented deletion (unlink) of commentary: %s", path);
    return 0; // Fake success
  }
  if (!orig_unlink) return -1;
  return orig_unlink(path);
}

static int hook_unlinkat(int fd, const char *path, int flag) {
  if (isCommentaryPath(path)) {
    ZLog(@"[BLV_PROTECT] Prevented deletion (unlinkat) of commentary: %s", path);
    return 0;
  }
  if (!orig_unlinkat) return -1;
  return orig_unlinkat(fd, path, flag);
}

static int hook_remove(const char *path) {
  if (isCommentaryPath(path)) {
    ZLog(@"[BLV_PROTECT] Prevented deletion (remove) of commentary: %s", path);
    return 0;
  }
  if (!orig_remove) return -1;
  return orig_remove(path);
}

// ---------------------------------------------------------------- pak / cpk / Download file redirection
static bool isZipHeader(const char* path) {
  if (!path || !path[0]) return false;
  int (*my_open)(const char*, int, ...) = orig_open ?: (int (*)(const char*, int, ...))dlsym(RTLD_DEFAULT, "open");
  if (!my_open) return false;
  int fd = my_open(path, O_RDONLY, 0);
  if (fd < 0) return false;
  char hdr[4] = {0};
  ssize_t r = read(fd, hdr, 4);
  close(fd);
  return r == 4 && hdr[0] == 'P' && hdr[1] == 'K' && hdr[2] == 3 && hdr[3] == 4;
}

static void resolveAltName(char* buffer, size_t bufSize) {
  if (!orig_access) orig_access = (int (*)(const char*, int))dlsym(RTLD_DEFAULT, "access");
  if (!orig_access) return;

  const char* extension = strrchr(buffer, '.');
  if (!extension) return;
  bool isPakExt = (strcmp(extension, ".pak") == 0);
  bool isIoStore = (strcmp(extension, ".utoc") == 0 || strcmp(extension, ".ucas") == 0);
  bool isCpk = (strcmp(extension, ".cpk") == 0);
  if (!isPakExt && !isIoStore && !isCpk) return;

  // Check if buffer exists as a regular valid file
  if (orig_access(buffer, F_OK) == 0) {
    // If it's a .pak file but actually a zip archive (e.g. pc0000_mobile_and.pak), it's NOT a valid pak!
    if (isPakExt && isZipHeader(buffer)) {
      std::string altChunk = buffer;
      size_t pos = altChunk.find("pc0000_mobile_ios.pak");
      if (pos == std::string::npos) pos = altChunk.find("pc0000_mobile_and.pak");
      if (pos != std::string::npos) {
        altChunk.replace(pos, altChunk.length() - pos, "pakchunk0-Android_ETC2.pak");
        if (orig_access(altChunk.c_str(), F_OK) == 0) {
          strncpy(buffer, altChunk.c_str(), bufSize - 1);
          buffer[bufSize - 1] = '\0';
          return;
        }
      }
    } else {
      return;
    }
  }

  char alt[1024];
  strncpy(alt, buffer, sizeof(alt) - 1);
  alt[sizeof(alt) - 1] = '\0';

  // 1. _mobile_ios <-> _mobile_and
  char* iosPtr = strstr(alt, "_mobile_ios");
  if (iosPtr) {
    memcpy(iosPtr, "_mobile_and", 11);
    if (orig_access(alt, F_OK) == 0 && (!isPakExt || !isZipHeader(alt))) {
      strncpy(buffer, alt, bufSize - 1);
      buffer[bufSize - 1] = '\0';
      return;
    }
  }
  char* andPtr = strstr(alt, "_mobile_and");
  if (andPtr) {
    memcpy(andPtr, "_mobile_ios", 11);
    if (orig_access(alt, F_OK) == 0 && (!isPakExt || !isZipHeader(alt))) {
      strncpy(buffer, alt, bufSize - 1);
      buffer[bufSize - 1] = '\0';
      return;
    }
  }

  // 2. global_mobile_ios.* <-> global.*
  if (strstr(alt, "global_mobile_ios")) {
    std::string altGlobal = alt;
    size_t pos = altGlobal.find("global_mobile_ios");
    if (pos != std::string::npos) {
      altGlobal.replace(pos, 17, "global");
      if (orig_access(altGlobal.c_str(), F_OK) == 0) {
        strncpy(buffer, altGlobal.c_str(), bufSize - 1);
        buffer[bufSize - 1] = '\0';
        return;
      }
    }
  }

  // 3. pc0000_mobile_ios.* <-> pakchunk0-Android_ETC2.*
  if (strstr(alt, "pc0000_mobile_ios") || strstr(alt, "pc0000_mobile_and")) {
    std::string altChunk = alt;
    size_t pos = altChunk.find("pc0000_mobile_ios");
    if (pos == std::string::npos) pos = altChunk.find("pc0000_mobile_and");
    if (pos != std::string::npos) {
      altChunk.replace(pos, 17, "pakchunk0-Android_ETC2");
      if (orig_access(altChunk.c_str(), F_OK) == 0) {
        strncpy(buffer, altChunk.c_str(), bufSize - 1);
        buffer[bufSize - 1] = '\0';
        return;
      }
    }
  }
}

#include "ZiruDisplayRepair.inc"
#include "ZiruNativeBase.inc"

static const char* redirectPath(const char* path, char* buffer, size_t bufSize) {
  // Backend/installers already use explicit paths, including staging and source data.
  if (gBackendIO) return path;
  if (!path || !path[0] || !gDocsUTF8[0]) return path;
  if (isTemporaryDownloadPath(path)) return path;
  // The verified bundled iOS resources must not be redirected into an older cache.
  if (strstr(path, ".app/efootxi/") || strstr(path, ".app/python/") ||
      strstr(path, "/Application Support/Efootxi2027/") || strstr(path, "/Application Support/Efootxi2027-")) return path;

  // 1. Check for pak: /pak/ or pak/ or path ending with /pak or path == "pak"
  const char* p = strstr(path, "/pak/");
  if (!p && strncmp(path, "pak/", 4) == 0) p = path - 1;
  if (p) {
    const char* rel = (p == path - 1) ? (path + 4) : (p + 5);
    int n = snprintf(buffer, bufSize, "%s/pak/%s", gDocsUTF8, rel);
    if (n > 0 && (size_t)n < bufSize) {
      resolveAltName(buffer, bufSize);
      if (orig_access && orig_access(buffer, F_OK) == 0) return buffer;
      if (gOriginalDocuments && orig_access) {
        char fallback[1024];
        int fn = snprintf(fallback, sizeof(fallback), "%s/pak/%s", gOriginalDocuments.fileSystemRepresentation, rel);
        if (fn > 0 && (size_t)fn < sizeof(fallback)) {
          resolveAltName(fallback, sizeof(fallback));
          if (orig_access(fallback, F_OK) == 0) {
            strncpy(buffer, fallback, bufSize - 1);
            buffer[bufSize - 1] = '\0';
            return buffer;
          }
        }
      }
      return buffer;
    }
  }
  size_t len = strlen(path);
  if ((len >= 4 && strcmp(path + len - 4, "/pak") == 0) || strcmp(path, "pak") == 0) {
    int n = snprintf(buffer, bufSize, "%s/pak", gDocsUTF8);
    if (n > 0 && (size_t)n < bufSize) return buffer;
  }

  // 2. Check for cpk: /cpk/ or cpk/ or path ending with /cpk or path == "cpk"
  p = strstr(path, "/cpk/");
  if (!p && strncmp(path, "cpk/", 4) == 0) p = path - 1;
  if (p) {
    const char* rel = (p == path - 1) ? (path + 4) : (p + 5);
    int n = snprintf(buffer, bufSize, "%s/cpk/%s", gDocsUTF8, rel);
    if (n > 0 && (size_t)n < bufSize) {
      resolveAltName(buffer, bufSize);
      if (orig_access && orig_access(buffer, F_OK) == 0) return buffer;
      if (gOriginalDocuments && orig_access) {
        char fallback[1024];
        int fn = snprintf(fallback, sizeof(fallback), "%s/cpk/%s", gOriginalDocuments.fileSystemRepresentation, rel);
        if (fn > 0 && (size_t)fn < sizeof(fallback)) {
          resolveAltName(fallback, sizeof(fallback));
          if (orig_access(fallback, F_OK) == 0) {
            strncpy(buffer, fallback, bufSize - 1);
            buffer[bufSize - 1] = '\0';
            return buffer;
          }
        }
      }
      return buffer;
    }
  }
  if ((len >= 4 && strcmp(path + len - 4, "/cpk") == 0) || strcmp(path, "cpk") == 0) {
    int n = snprintf(buffer, bufSize, "%s/cpk", gDocsUTF8);
    if (n > 0 && (size_t)n < bufSize) return buffer;
  }

  // 3. Check for Download: /Download/ or /download/
  p = strstr(path, "/Download/");
  if (!p) p = strstr(path, "/download/");
  if (!p && (strncmp(path, "Download/", 9) == 0 || strncmp(path, "download/", 9) == 0)) p = path - 1;
  if (p) {
    const char* rel = (p == path - 1) ? (path + 9) : (p + 10);
    int n = snprintf(buffer, bufSize, "%s/Download/%s", gDocsUTF8, rel);
    if (n > 0 && (size_t)n < bufSize) {
      resolveAltName(buffer, bufSize);
      return buffer;
    }
  }
  if ((len >= 9 && strcasecmp(path + len - 9, "/download") == 0) || strcasecmp(path, "download") == 0) {
    int n = snprintf(buffer, bufSize, "%s/Download", gDocsUTF8);
    if (n > 0 && (size_t)n < bufSize) return buffer;
  }

  // 4. Check for livedata: /livedata/ or livedata/ or path ending with /livedata or path == "livedata"
  p = strstr(path, "/livedata/");
  if (!p && strncmp(path, "livedata/", 9) == 0) p = path - 1;
  if (p) {
    const char* rel = (p == path - 1) ? (path + 9) : (p + 10);
    int n = snprintf(buffer, bufSize, "%s/livedata/%s", gDocsUTF8, rel);
    if (n > 0 && (size_t)n < bufSize) {
      resolveAltName(buffer, bufSize);
      return buffer;
    }
  }
  if ((len >= 9 && strcmp(path + len - 9, "/livedata") == 0) || strcmp(path, "livedata") == 0) {
    int n = snprintf(buffer, bufSize, "%s/livedata", gDocsUTF8);
    if (n > 0 && (size_t)n < bufSize) return buffer;
  }

  return path;
}

static int hook_open(const char *path, int oflag, ...) {
  if (!orig_open) orig_open = (int (*)(const char*, int, ...))dlsym(RTLD_DEFAULT, "open");
  char buf[1024];
  const char* actual = redirectPath(path, buf, sizeof(buf));
  if (oflag & O_CREAT) {
    va_list args;
    va_start(args, oflag);
    mode_t mode = (mode_t)va_arg(args, int);
    va_end(args);
    int result = orig_open ? orig_open(actual, oflag, mode) : -1;
    int code = errno; diagnosticIO("open", path, actual, result, result<0 ? code : 0); errno=code; return result;
  }
  int result = orig_open ? orig_open(actual, oflag) : -1;
  int code=errno; diagnosticIO("open", path, actual, result, result<0 ? code : 0); errno=code; return result;
}

static int hook_stat(const char *path, struct stat *buf) {
  if (!orig_stat) orig_stat = (int (*)(const char*, struct stat*))dlsym(RTLD_DEFAULT, "stat");
  char rpath[1024];
  const char* actual = redirectPath(path, rpath, sizeof(rpath));
  int result = orig_stat ? orig_stat(actual, buf) : -1;
  int code=errno; diagnosticIO("stat", path, actual, result, result<0 ? code : 0); errno=code; return result;
}

static int hook_access(const char *path, int amode) {
  if (!orig_access) orig_access = (int (*)(const char*, int))dlsym(RTLD_DEFAULT, "access");
  char rpath[1024];
  const char* actual = redirectPath(path, rpath, sizeof(rpath));
  int result = orig_access ? orig_access(actual, amode) : -1;
  int code=errno; diagnosticIO("access", path, actual, result, result<0 ? code : 0); errno=code; return result;
}

static FILE* hook_fopen(const char *filename, const char *mode) {
  if (!orig_fopen) orig_fopen = (FILE* (*)(const char*, const char*))dlsym(RTLD_DEFAULT, "fopen");
  char rpath[1024];
  const char* actual = redirectPath(filename, rpath, sizeof(rpath));
  FILE* result = orig_fopen ? orig_fopen(actual, mode) : NULL;
  int code=errno; diagnosticIO("fopen", filename, actual, result ? 0 : -1, result ? 0 : code); errno=code; return result;
}

static DIR* hook_opendir(const char *name) {
  if (!orig_opendir) orig_opendir = (DIR* (*)(const char*))dlsym(RTLD_DEFAULT, "opendir");
  char rpath[1024];
  const char* actual = redirectPath(name, rpath, sizeof(rpath));
  DIR* result = orig_opendir ? orig_opendir(actual) : NULL;
  int code=errno; diagnosticIO("opendir", name, actual, result ? 0 : -1, result ? 0 : code); errno=code; return result;
}

// ---------------------------------------------------------------- NSFileManager swizzling
static IMP gOrigFmRemovePath, gOrigFmRemoveURL;

static BOOL hookFmRemovePath(id self, SEL _cmd, NSString* path, NSError** error) {
  if (path && isCommentaryPath(path.fileSystemRepresentation)) {
    ZLog(@"[BLV_PROTECT] Prevented NSFileManager removeItemAtPath: %@", path);
    return YES;
  }
  return ((BOOL(*)(id, SEL, NSString*, NSError**))gOrigFmRemovePath)(self, _cmd, path, error);
}

static BOOL hookFmRemoveURL(id self, SEL _cmd, NSURL* url, NSError** error) {
  if (url.path && isCommentaryPath(url.path.fileSystemRepresentation)) {
    ZLog(@"[BLV_PROTECT] Prevented NSFileManager removeItemAtURL: %@", url.path);
    return YES;
  }
  return ((BOOL(*)(id, SEL, NSURL*, NSError**))gOrigFmRemoveURL)(self, _cmd, url, error);
}

// ---------------------------------------------------------------- server
static std::unique_ptr<zsv::OfflineServer> gServer;
static std::once_flag gServerOnce;

static zsv::OfflineServer& server() {
  std::call_once(gServerOnce, [] {
    zsv::Config cfg;
    cfg.assetsDir = gBundleAssets.fileSystemRepresentation;
    cfg.dropAndroidLivedata = false;   // Retain 54 modded Epic/BigTime player paks; remapped to _mobile_ios
    // Vietnamese commentary is a paid add-on: offered only when dt510_eng_mobile_all.cpk is installed, and then with
    // its real size/SHA-256 so the client keeps it instead of deleting it as a mismatching download.
    cfg.iosCommentary = true;
    cfg.downloadDir = std::string([gDocs stringByAppendingPathComponent:@"Download"].fileSystemRepresentation);
    std::string livedataDir;
    NSString* directLivedata = [gDocs stringByAppendingPathComponent:@"livedata"];
    NSString* subLivedata = [gDocs stringByAppendingPathComponent:@"PES2027-data/livedata"];
    NSFileManager* fm = NSFileManager.defaultManager;
    if ([fm fileExistsAtPath:directLivedata]) {
      livedataDir = directLivedata.fileSystemRepresentation;
    } else if ([fm fileExistsAtPath:subLivedata]) {
      livedataDir = subLivedata.fileSystemRepresentation;
    } else {
      std::string id = zd::activeId(layout());
      if (!id.empty()) livedataDir = zd::dataDir(layout(), id) + "/livedata";
    }
    cfg.livedataDir = livedataDir;
    cfg.dataDir = std::string(gSupport.fileSystemRepresentation) + "/Save";
    cfg.iosPlayerLayout = true;
    cfg.logFile = std::string([gSessionDir stringByAppendingPathComponent:@"offline_server.log"].fileSystemRepresentation);
    gServer.reset(new zsv::OfflineServer(cfg));
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ gServer->prewarmIosCommentary(); });
    gServer->startupAudit();
    ZLog(@"server ready assets=%s livedata=%s save=%s layout=iOS147", cfg.assetsDir.c_str(), cfg.livedataDir.c_str(), cfg.dataDir.c_str());
  });
  return *gServer;
}

// ---------------------------------------------------------------- NSURLProtocol
static BOOL shouldHandleURL(NSURL* url) {
  NSString* host = url.host.lowercaseString;
  if (!host) return NO;
  NSString* scheme = url.scheme.lowercaseString;
  if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return NO;
  if ([host isEqualToString:@"127.0.0.1"] && url.port.intValue == 8085) return YES;
  if ([host isEqualToString:@"ntl.service.konami.net"]) return YES;                 // GateInfo.php
  if ([host isEqualToString:@"d1ln4m3c7n87ju.cloudfront.net"]) return YES;          // livedata CDN in CmdLogin
  return NO;
}

// Konami CDN images (pack/agent banners: /prd/banner/agent/<id>/<sha256>, campaign art ...). Ziru's responses point at
// d1ln4m3c7n87ju.cloudfront.net/prd/...; the Android build fetches them from the real CDN, the local server has none
// (404 -> packs show without pictures). Serve them from PESmobile.app/ziru/cdn/<path> or the on-device cache
// Documents/PES2027-cache/cdn/<path>; otherwise fetch once from the CDN (when online) and keep a copy for offline use.
static BOOL isCdnAssetURL(NSURL* url) {
  if (![url.path hasPrefix:@"/prd/"] && ![url.path hasPrefix:@"/banner/"]) return NO;
  if ([url.path rangeOfString:@".."].location != NSNotFound) return NO;
  NSString* h = url.host.lowercaseString;
  return [h isEqualToString:@"d1ln4m3c7n87ju.cloudfront.net"] ||
         [h isEqualToString:@"127.0.0.1"] ||
         [h isEqualToString:@"localhost"];
}
static NSString* cdnCachePath(NSURL* url) {
  return [[gDocs stringByAppendingPathComponent:@"PES2027-cache/cdn"] stringByAppendingPathComponent:url.path];
}
static NSString* cdnMime(NSData* d) {
  const uint8_t* b = (const uint8_t*)d.bytes;
  if (d.length >= 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G') return @"image/png";
  if (d.length >= 3 && b[0] == 0xFF && b[1] == 0xD8 && b[2] == 0xFF) return @"image/jpeg";
  if (d.length >= 12 && memcmp(b, "RIFF", 4) == 0 && memcmp(b + 8, "WEBP", 4) == 0) return @"image/webp";
  return @"application/octet-stream";
}
static IMP gOrigEphemeralCfg;  // defined with the configuration hooks below
static NSURLSession* cdnSession() {
  static NSURLSession* s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // the unhooked ephemeral configuration: no ZiruURLProtocol, so the request really goes to the CDN
    NSURLSessionConfiguration* c = gOrigEphemeralCfg
        ? ((NSURLSessionConfiguration * (*)(id, SEL)) gOrigEphemeralCfg)(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration))
        : NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSMutableArray* p = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
    [p removeObject:NSClassFromString(@"ZiruURLProtocol")];
    c.protocolClasses = p;
    c.timeoutIntervalForRequest = 20;
    s = [NSURLSession sessionWithConfiguration:c];
  });
  return s;
}

// ---------------------------------------------------------------- online (mod 1.1): Friend Match via the AWS server
// myClub stays on the on-device server; room / game-session / TURN / match-progress commands go to the online server
// configured in PESmobile.app/ziru/online.json, overridable by Documents/PES2027-online.json:
//   {"server": "https://1.2.3.4:8443", "name": "Long", "enabled": true}
// Every device plays Ziru's account (user_id 359042717); the server tells devices apart by X-Ziru-Uid.
static NSString* gOnlineServer;   // nil = online disabled
static NSString* gOnlineName;
static NSString* gOnlineToken;
static NSString* gOnlineCertSha256;
static uint32_t gOnlineUid;
static std::atomic<bool> gOnlineInRoom{false};

static void loadOnlineConfig() {
  // Keep AWS online servers disabled per user request ("gỡ toàn bộ online qua sever aws đi", "chỉ giữ đá qua LAN thôi")
  gOnlineServer = nil;
  gOnlineToken = nil;
  gOnlineCertSha256 = nil;
  NSUserDefaults* ud = NSUserDefaults.standardUserDefaults;
  gOnlineUid = (uint32_t)[ud integerForKey:@"ZiruOnlineUid"];
  if (!gOnlineUid) {
    gOnlineUid = 1000000000u + arc4random_uniform(1000000000u);
    [ud setInteger:gOnlineUid forKey:@"ZiruOnlineUid"];
  }
  gOnlineName = [NSString stringWithFormat:@"Player%04u", gOnlineUid % 10000];
  ZLog(@"[ONLINE] disabled (AWS servers decommissioned; local LAN/Bluetooth match only)");
}

static NSString* gateCommand(NSURL* url) {
  NSString* last = url.path.lastPathComponent;
  if (![last hasPrefix:@"gate_"] || ![last hasSuffix:@".php"]) return nil;
  return [last substringWithRange:NSMakeRange(5, last.length - 9)];
}

static BOOL isOnlineCommand(NSString* cmd) {
  static NSSet* always, *inRoom;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    always = [NSSet setWithArray:@[
      @"CMD_CREATEJOIN_ROOM", @"CMD_JOIN_ROOM", @"CMD_GET_ROOM_INFO", @"CMD_GET_ROOM_LIST", @"CMD_LEAVE_ROOM",
      @"CMD_SET_ROOM_MATCH_READY", @"CMD_UNSET_ROOM_MATCH_READY", @"CMD_SET_ROOM_SETTINGS", @"CMD_SET_ROOM_USER_ENTRY_SIDE",
      @"CMD_SET_ROOM_USER_SQUAD_ENABLE", @"CMD_SET_ROOM_USER_COMMENT", @"CMD_RETURN_ROOM", @"CMD_KICK_ROOM_USER",
      @"CMD_SEND_JOIN_ROOM_REQUEST", @"CMD_GET_REQUESTED_JOIN_ROOM_INFO", @"CMD_ADD_ROOM_GUEST", @"CMD_DELETE_ROOM_GUEST",
      @"CMD_GET_COMMUNITY_ROOM_LIST", @"CMD_SEND_JOIN_COMMUNITY_ROOM_REQUEST", @"CMD_WATCH_ROOM_CONNECTION",
      @"CMD_GET_TURN_SERVER_LIST", @"CMD_SEND_TURN_ADDRESS_DATA", @"CMD_GET_TURN_ADDRESS_DATA", @"CMD_WATCH_TURN_ADDRESS_DATA",
      @"CMD_GET_GAME_SESSION", @"CMD_GET_SESSION_ID", @"CMD_SEND_SESSION_ID", @"CMD_SET_GAME_SESSION_CHECK_RES",
      @"CMD_GET_GAME_SESSION_CHECK_RES", @"CMD_SEND_SESSION_FAILED_NOTICE", @"CMD_MATCH_SETTINGS"]];
    // used by offline matches too: only online while this device is in an online room
    inRoom = [NSSet setWithArray:@[ @"CMD_CHANGE_GAMEPHASE", @"CMD_ADD_SCORE", @"CMD_ADD_FOUL", @"CMD_SET_GAME_RESULT",
                                    @"CMD_GET_GAME_RESULT", @"CMD_CHECK_GAME_RESULT", @"CMD_ALIGN_PROGRESS" ]];
  });
  if (!gOnlineServer || !cmd) return NO;
  return [always containsObject:cmd] || (gOnlineInRoom && [inRoom containsObject:cmd]);
}

@interface ZiruOnlineDelegate : NSObject <NSURLSessionDelegate>
@end
@implementation ZiruOnlineDelegate
// A self-signed endpoint must match the certificate fingerprint bundled with its configuration.
- (void)URLSession:(NSURLSession*)session didReceiveChallenge:(NSURLAuthenticationChallenge*)challenge
    completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential*))completionHandler {
  NSURLProtectionSpace* ps = challenge.protectionSpace;
  if ([ps.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust] &&
      [ps.host isEqualToString:[NSURL URLWithString:gOnlineServer].host] && gOnlineCertSha256.length) {
    SecCertificateRef cert = ps.serverTrust ? SecTrustGetCertificateAtIndex(ps.serverTrust, 0) : nullptr;
    NSData* der = cert ? CFBridgingRelease(SecCertificateCopyData(cert)) : nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {0};
    if (der) CC_SHA256(der.bytes, (CC_LONG)der.length, digest);
    NSMutableString* fingerprint = [NSMutableString stringWithCapacity:64];
    for (unsigned char b : digest) [fingerprint appendFormat:@"%02x", b];
    if (der && [fingerprint isEqualToString:gOnlineCertSha256])
      completionHandler(NSURLSessionAuthChallengeUseCredential, [NSURLCredential credentialForTrust:ps.serverTrust]);
    else
      completionHandler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
    return;
  }
  completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}
@end

static NSURLSession* onlineSession() {
  static NSURLSession* s;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration* c = gOrigEphemeralCfg
        ? ((NSURLSessionConfiguration * (*)(id, SEL)) gOrigEphemeralCfg)(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration))
        : NSURLSessionConfiguration.ephemeralSessionConfiguration;
    NSMutableArray* p = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
    [p removeObject:NSClassFromString(@"ZiruURLProtocol")];
    c.protocolClasses = p;
    c.timeoutIntervalForRequest = 15;
    s = [NSURLSession sessionWithConfiguration:c delegate:[ZiruOnlineDelegate new] delegateQueue:nil];
  });
  return s;
}

@interface ZiruURLProtocol : NSURLProtocol
@end

@implementation ZiruURLProtocol {
  NSURLSessionDataTask* _cdnTask;
}
+ (BOOL)canInitWithRequest:(NSURLRequest*)request {
  if (shouldHandleURL(request.URL)) return YES;
  if (request.URL) {
    NSString* scheme = request.URL.scheme.lowercaseString;
    if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
      ZLog(@"[REAL_NET] Unhandled network request: %@ %@", request.HTTPMethod ?: @"GET", request.URL.absoluteString);
    }
  }
  return NO;
}
+ (NSURLRequest*)canonicalRequestForRequest:(NSURLRequest*)request { return request; }
+ (BOOL)requestIsCacheEquivalent:(NSURLRequest*)a toRequest:(NSURLRequest*)b { return NO; }

static NSData* bodyOf(NSURLRequest* r) {
  if (r.HTTPBody) return r.HTTPBody;
  NSInputStream* s = r.HTTPBodyStream;
  if (!s) return nil;
  NSMutableData* d = [NSMutableData data];
  [s open];
  uint8_t buf[65536];
  while (true) {
    NSInteger n = [s read:buf maxLength:sizeof buf];
    if (n <= 0) break;
    [d appendBytes:buf length:(NSUInteger)n];
  }
  [s close];
  return d;
}

- (void)finishWithStatus:(NSInteger)status headers:(NSDictionary*)headers data:(NSData*)data {
  NSHTTPURLResponse* hr = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:headers];
  [self.client URLProtocol:self didReceiveResponse:hr cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  if (data.length) [self.client URLProtocol:self didLoadData:data];
  [self.client URLProtocolDidFinishLoading:self];
  gLastNetwork=CFAbsoluteTimeGetCurrent();
  diagnosticEvent(@"native-network.jsonl", @{@"event":@"callbacks_done", @"path":self.request.URL.path ?: @"", @"status":@(status), @"bytes":@(data.length)});
  ZLog(@"[NET_DONE] %@ status=%ld bytes=%lu", self.request.URL.path, (long)status, (unsigned long)data.length);
}

- (void)loadCdnAsset {
  NSURL* url = self.request.URL;
  NSString* bundled = [[gBundleAssets stringByAppendingPathComponent:@"cdn"] stringByAppendingPathComponent:url.path];
  NSString* bundledResp = [[gBundleAssets stringByAppendingPathComponent:@"responses"] stringByAppendingPathComponent:url.path];
  NSString* cached = cdnCachePath(url);
  for (NSString* f in @[ bundled, bundledResp, cached ]) {
    NSData* d = [NSData dataWithContentsOfFile:f];
    if (d.length) {
      ZLog(@"[CDN] %@ -> %@ (%lu bytes)", url.path, f == bundled ? @"bundle/cdn" : (f == bundledResp ? @"bundle/responses" : @"cache"), (unsigned long)d.length);
      [self finishWithStatus:200 headers:@{@"Content-Type" : cdnMime(d), @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)d.length]} data:d];
      return;
    }
  }
  CFRunLoopRef rl = CFRunLoopGetCurrent();
  NSURL* cdnRealUrl = [NSURL URLWithString:[@"https://d1ln4m3c7n87ju.cloudfront.net" stringByAppendingString:url.path]];
  NSURLRequest* rq = [NSURLRequest requestWithURL:cdnRealUrl cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:20];
  __weak ZiruURLProtocol* weakSelf = self;
  _cdnTask = [cdnSession() dataTaskWithRequest:rq completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
    if (!error && status == 200 && data.length) {
      [NSFileManager.defaultManager createDirectoryAtPath:cached.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
      [data writeToFile:cached atomically:YES];
    }
    ZLog(@"[CDN] %@ -> network %ld, %lu bytes%@", url.path, (long)status, (unsigned long)data.length,
         error ? [@" error: " stringByAppendingString:error.localizedDescription] : @"");
    CFRunLoopPerformBlock(rl, kCFRunLoopCommonModes, ^{
      ZiruURLProtocol* me = weakSelf;
      if (!me) return;
      if (error || !status) {
        [me.client URLProtocol:me didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
        return;
      }
      [me finishWithStatus:status headers:@{@"Content-Type" : cdnMime(data ?: [NSData data]), @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)data.length]} data:data];
    });
    CFRunLoopWakeUp(rl);
  }];
  [_cdnTask resume];
}

- (void)forwardOnline:(NSString*)cmd {
  NSURLRequest* rq = self.request;
  NSURL* target = [NSURL URLWithString:[gOnlineServer stringByAppendingString:rq.URL.path]];
  NSMutableURLRequest* f = [NSMutableURLRequest requestWithURL:target cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
  f.HTTPMethod = rq.HTTPMethod ?: @"POST";
  f.HTTPBody = bodyOf(rq);
  NSString* ct = rq.allHTTPHeaderFields[@"Content-Type"];
  if (ct) [f setValue:ct forHTTPHeaderField:@"Content-Type"];
  [f setValue:[NSString stringWithFormat:@"%u", gOnlineUid] forHTTPHeaderField:@"X-Ziru-Uid"];
  [f setValue:[gOnlineName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet] forHTTPHeaderField:@"X-Ziru-Name"];
  [f setValue:@"1.1" forHTTPHeaderField:@"X-Ziru-Ver"];
  [f setValue:@"IOS" forHTTPHeaderField:@"X-Ziru-Platform"];
  if (gOnlineToken.length) [f setValue:gOnlineToken forHTTPHeaderField:@"X-Ziru-Token"];
  CFRunLoopRef rl = CFRunLoopGetCurrent();
  CFRetain(rl);
  __weak ZiruURLProtocol* weakSelf = self;
  CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
  _cdnTask = [onlineSession() dataTaskWithRequest:f completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
    ZLog(@"[ONLINE] %@ -> %ld %lu bytes (%.0f ms)%@", cmd, (long)status, (unsigned long)data.length,
         (CFAbsoluteTimeGetCurrent() - t0) * 1000.0, error ? [@" error: " stringByAppendingString:error.localizedDescription] : @"");
    if (status == 200) {
      NSString* inRoom = [((NSHTTPURLResponse*)response) valueForHTTPHeaderField:@"X-Ziru-In-Room"];
      if ([inRoom isEqualToString:@"YES"]) gOnlineInRoom = true;
      else if ([inRoom isEqualToString:@"NO"]) gOnlineInRoom = false;
    }
    CFRunLoopPerformBlock(rl, kCFRunLoopCommonModes, ^{
      CFRelease(rl);
      ZiruURLProtocol* me = weakSelf;
      if (!me) return;
      if (error || !status) {
        [me.client URLProtocol:me didFailWithError:error ?: [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorBadServerResponse userInfo:nil]];
        return;
      }
      [me finishWithStatus:status headers:@{@"Content-Type" : @"application/x-msgpack", @"Content-Length" : [NSString stringWithFormat:@"%lu", (unsigned long)data.length]} data:data];
    });
    CFRunLoopWakeUp(rl);
  }];
  [_cdnTask resume];
}

- (void)startLoading {
  NSURLRequest* rq = self.request;
  NSURL* url = rq.URL;
  gLastNetwork = CFAbsoluteTimeGetCurrent();
  diagnosticEvent(@"native-network.jsonl", @{@"event":@"begin", @"url":url.absoluteString ?: @"", @"method":rq.HTTPMethod ?: @"GET"});
#ifdef EFOOTXI_IOS
  BOOL localBanner = [url.path hasPrefix:@"/prd/efootxi/"] || [url.path hasPrefix:@"/efootxi/"] ||
    ([@[@"efootxi-home-players.jpg", @"efootxi-home-coaches.jpg"] containsObject:url.lastPathComponent] &&
    ([url.path hasPrefix:@"/prd/efootxi/"] || [url.path hasPrefix:@"/efootxi/"] ||
     [url.path hasPrefix:@"/prdhttp://127.0.0.1:8085/livedata/"]));
  if (localBanner || !isCdnAssetURL(url)) {
    NSString* path = url.path.length ? url.path : @"/";
    if (!localBanner && [url.host.lowercaseString isEqualToString:@"d1ln4m3c7n87ju.cloudfront.net"])
      path = [@"/livedata/" stringByAppendingString:url.lastPathComponent ?: @""];
    NSData* body = bodyOf(rq) ?: [NSData data];
    gRequestsActive.fetch_add(1);
    NSInteger status=500; NSString* mime=@"application/octet-stream";
    NSData* data = efootxiServe(rq.HTTPMethod ?: @"GET", path, body, &status, &mime);
    gRequestsActive.fetch_sub(1); gLastNetwork=CFAbsoluteTimeGetCurrent();
    NSMutableDictionary* responseHeaders=[@{@"Content-Type":mime, @"Content-Length":@(data.length).stringValue,
      @"Connection":@"close"} mutableCopy];
    if (status==200 && [mime isEqualToString:@"application/x-msgpack"])
      responseHeaders[@"pes-custom-encrypt"]=@"AES256";
    [self finishWithStatus:status headers:responseHeaders data:data];
    return;
  }
#endif
  if (isCdnAssetURL(url)) {
    [self loadCdnAsset];
    return;
  }
  NSString* gcmd = gateCommand(url);
  if (isOnlineCommand(gcmd)) {
    [self forwardOnline:gcmd];
    return;
  }
  zsv::Request r;
  r.method = rq.HTTPMethod ? rq.HTTPMethod.uppercaseString.UTF8String : "GET";
  NSString* path = url.path.length ? url.path : @"/";                // decoded, no query (NanoHTTPD getUri)
  if ([url.host.lowercaseString isEqualToString:@"d1ln4m3c7n87ju.cloudfront.net"]) {
    // CDN livedata URL -> /livedata/<file name> served from the imported pack
    path = [@"/livedata/" stringByAppendingString:url.lastPathComponent ?: @""];
  }
  r.uri = path.UTF8String;
  for (NSString* k in rq.allHTTPHeaderFields) r.headers[k.lowercaseString.UTF8String] = [rq.allHTTPHeaderFields[k] UTF8String];
  NSData* body = bodyOf(rq);
  if (body.length) {
    r.body.assign((const uint8_t*)body.bytes, (const uint8_t*)body.bytes + body.length);
    r.headers["content-length"] = std::to_string(body.length);  // NanoHTTPD reads exactly content-length
  } else {
    r.headers.erase("content-length");
  }
  CFAbsoluteTime t0 = CFAbsoluteTimeGetCurrent();
  zsv::Response resp;
  try {
    resp = server().serve(r);
  } catch (const std::exception& e) {
    ZLog(@"[SAVE_ERROR] %s", e.what());
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:@"PES2027.Save" code:1
        userInfo:@{NSLocalizedDescriptionKey: @"Không thể mở dữ liệu lưu. Kiểm tra dung lượng trống và log."}]];
    return;
  }
  double ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000.0;
  ZLog(@"%s %s body=%lu -> %d %lu bytes (%.0f ms)", r.method.c_str(), r.uri.c_str(), (unsigned long)body.length, resp.status,
       (unsigned long)resp.body.size(), ms);
  NSMutableDictionary* h = [NSMutableDictionary dictionary];
  h[@"Content-Type"] = [NSString stringWithUTF8String:resp.mime.c_str()];
  h[@"Content-Length"] = [NSString stringWithFormat:@"%lu", (unsigned long)resp.body.size()];
  for (auto& kv : resp.headers) h[[NSString stringWithUTF8String:kv.first.c_str()]] = [NSString stringWithUTF8String:kv.second.c_str()];
  NSHTTPURLResponse* hr = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:resp.status HTTPVersion:@"HTTP/1.1" headerFields:h];
  [self.client URLProtocol:self didReceiveResponse:hr cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  if (!resp.body.empty()) [self.client URLProtocol:self didLoadData:[NSData dataWithBytes:resp.body.data() length:resp.body.size()]];
  [self.client URLProtocolDidFinishLoading:self];
  ZLog(@"[NET_DONE] %s status=%d bytes=%lu", r.uri.c_str(), resp.status, (unsigned long)resp.body.size());
}
- (void)stopLoading {
  [_cdnTask cancel];
  _cdnTask = nil;
}
@end

// ---------------------------------------------------------------- swizzling helpers
static IMP swizzleClassMethod(Class c, SEL s, IMP repl) {
  Method m = class_getClassMethod(c, s);
  if (!m) return nullptr;
  return method_setImplementation(m, repl);
}
static IMP swizzleInstance(Class c, SEL s, IMP repl) {
  Method m = class_getInstanceMethod(c, s);
  if (!m) return nullptr;
  if (!class_addMethod(c, s, repl, method_getTypeEncoding(m))) return method_setImplementation(m, repl);
  return method_getImplementation(m);
}

// NSURLSessionConfiguration: put our protocol first in every default/ephemeral configuration
static IMP gOrigDefaultCfg;  // gOrigEphemeralCfg is declared with the CDN helpers above
static NSURLSessionConfiguration* withProtocol(NSURLSessionConfiguration* c) {
  NSMutableArray* p = [NSMutableArray arrayWithArray:c.protocolClasses ?: @[]];
  if (![p containsObject:ZiruURLProtocol.class]) [p insertObject:ZiruURLProtocol.class atIndex:0];
  c.protocolClasses = p;
  return c;
}
// Live Update (livedata) is downloaded with UE4 BackgroundHttp, i.e. a background NSURLSession. NSURLProtocol is never
// consulted for background sessions (the transfer runs in nsurlsessiond), so those downloads went to the real
// 127.0.0.1:8085 where nothing listens -> "Không thể áp dụng Dữ liệu Live Update". Give such callers an ordinary
// session configuration that carries ZiruURLProtocol instead; the delegate callbacks are the same.
static IMP gOrigBackgroundCfg;
static NSURLSessionConfiguration* hookDefaultCfg(id self, SEL _cmd);
static NSURLSessionConfiguration* hookBackgroundCfg(id self, SEL _cmd, NSString* identifier) {
  ZLog(@"[NET] background session '%@' -> in-app session with ZiruURLProtocol", identifier);
  return hookDefaultCfg(self, @selector(defaultSessionConfiguration));
}
static NSURLSessionConfiguration* hookDefaultCfg(id self, SEL _cmd) {
  return withProtocol(((NSURLSessionConfiguration * (*)(id, SEL)) gOrigDefaultCfg)(self, _cmd));
}
static NSURLSessionConfiguration* hookEphemeralCfg(id self, SEL _cmd) {
  return withProtocol(((NSURLSessionConfiguration * (*)(id, SEL)) gOrigEphemeralCfg)(self, _cmd));
}

// -[HttpImpl*Request setRequest:(const char*)url cookie:(const char*) isPost:(BOOL) sendData:(const void*) sendDataSize:(int) useGzip:(BOOL)]
typedef void (*SetReqFn)(id, SEL, const char*, const char*, long, const void*, long, long);
static SetReqFn gOrigSetReq[3];
template <int I>
static void hookSetRequest(id self, SEL _cmd, const char* url, const char* cookie, long isPost, const void* data, long size, long gzip) {
  std::string orig = url ? url : "";
  std::string red = url ? zsv::OfflineServer::redirectUrl(orig) : orig;
  if (orig.find("/prd/") != std::string::npos || orig.find("/banner/") != std::string::npos) red = orig;  // CDN images: see loadCdnAsset
  if (red != orig) {
    ZLog(@"[REDIRECT] %s -> %s", orig.c_str(), red.c_str());
  } else {
    ZLog(@"[HTTP_DIRECT] %s", orig.c_str());
  }
  gOrigSetReq[I](self, _cmd, url ? red.c_str() : url, cookie, isPost, data, size, gzip);
}

// ---------------------------------------------------------------- real frame-rate cap (FramePace)
// FMetalViewport::Present presents with afterMinimumDuration = 1 / FIOSPlatformRHIFramePacer::GetFramePace().
// GetFramePace (0x101aee720) returns maximumFramesPerSecond / rhi.SyncInterval only when
// [/Script/IOSRuntimeSettings.IOSRuntimeSettings] bEnableDynamicMaxFPS is true; eFootball's DefaultEngine.ini does
// not set it, so it returns 60 / SyncInterval and every frame is held for >= 16.7 ms: the game can never exceed
// 60 fps, whatever t.MaxFPS or CADisplayLink say. GetFramePace caches that ini value in two bytes of __DATA
// (0x10716a062 = value, 0x10716a063 = "already read"); set both so the cap follows the screen (120 on ProMotion).
static void enableDynamicMaxFps() {
  intptr_t slide = _dyld_get_image_vmaddr_slide(0);
  const uint32_t* code = (const uint32_t*)(0x101aee764 + slide);
  if (code[0] != 0x39418d08 || ((const uint32_t*)(0x101aee7ac + slide))[0] != 0x39418908) {
    ZLog(@"[FPS] GetFramePace does not match this binary - dynamic max FPS not enabled");
    return;
  }
  volatile uint8_t* cached = (volatile uint8_t*)(0x10716a062 + slide);
  cached[0] = 1;  // bEnableDynamicMaxFPS = true
  cached[1] = 1;  // value already loaded from the ini
  ZLog(@"[FPS] bEnableDynamicMaxFPS forced on: present pacing follows UIScreen.maximumFramesPerSecond");
}

// ---------------------------------------------------------------- 120 FPS Unlock
// Frame cap chosen in the Efootxi panel (NSUserDefaults efootxi.fps: 60 or 120, read once per launch).
static NSInteger ziruMaxFps() {
  static NSInteger cap = -1;
  if (cap < 0) cap = [NSUserDefaults.standardUserDefaults integerForKey:@"efootxi.fps"];
  NSInteger screen = (NSInteger)UIScreen.mainScreen.maximumFramesPerSecond;
  if (screen < 60) screen = 60;
  return (cap == 60) ? 60 : screen;
}
static IMP gOrigSetPreferredFramesPerSecond = nullptr;
static void hookSetPreferredFramesPerSecond(CADisplayLink* self, SEL _cmd, NSInteger fps) {
  NSInteger maxFps = ziruMaxFps();
  if (maxFps < 60) maxFps = 60;
  NSInteger targetFps = (fps <= 60 && fps > 0) ? 60 : maxFps;
  if (gOrigSetPreferredFramesPerSecond) {
    ((void(*)(id, SEL, NSInteger))gOrigSetPreferredFramesPerSecond)(self, _cmd, targetFps);
  }
  if (@available(iOS 15.0, *)) {
    float f = (float)targetFps;
    self.preferredFrameRateRange = CAFrameRateRangeMake(f, f, f);
  }
}

static IMP gOrigDisplayLinkWithTarget = nullptr;
static CADisplayLink* hookDisplayLinkWithTarget(Class cls, SEL _cmd, id target, SEL sel) {
  CADisplayLink* link = ((CADisplayLink* (*)(id, SEL, id, SEL))gOrigDisplayLinkWithTarget)(cls, _cmd, target, sel);
  if (link) {
    NSInteger maxFps = ziruMaxFps();
    if (maxFps < 60) maxFps = 60;
    link.preferredFramesPerSecond = maxFps;
    if (@available(iOS 15.0, *)) {
      float f = (float)maxFps;
      link.preferredFrameRateRange = CAFrameRateRangeMake(f, f, f);
    }
  }
  return link;
}

static IMP gOrigSetPreferredFrameRateRange = nullptr;
static void hookSetPreferredFrameRateRange(CADisplayLink* self, SEL _cmd, CAFrameRateRange range) {
  float maxFps = (float)ziruMaxFps();
  if (maxFps < 60.0f) maxFps = 60.0f;
  float target = (range.preferred <= 60.0f && range.preferred > 0.0f) ? 60.0f : maxFps;
  range.minimum = target;
  range.maximum = target;
  range.preferred = target;
  if (gOrigSetPreferredFrameRateRange) {
    ((void(*)(id, SEL, CAFrameRateRange))gOrigSetPreferredFrameRateRange)(self, _cmd, range);
  }
}

// Measured frame rate: the renderer takes one drawable per presented frame.
static std::atomic<uint32_t> gDrawables{0};
static IMP gOrigNextDrawable;
static id hookNextDrawable(id self, SEL _cmd) {
  gDrawables.fetch_add(1, std::memory_order_relaxed);
  return ((id(*)(id, SEL))gOrigNextDrawable)(self, _cmd);
}
static void startFpsMeter() {
  Class c = NSClassFromString(@"CAMetalLayer");
  if (!c) return;
  gOrigNextDrawable = swizzleInstance(c, @selector(nextDrawable), (IMP)hookNextDrawable);
  dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  static dispatch_source_t keep;
  keep = t;
  dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), 10 * NSEC_PER_SEC, NSEC_PER_SEC);
  __block CFTimeInterval previousSample = CACurrentMediaTime();
  dispatch_source_set_event_handler(t, ^{
    CFTimeInterval now = CACurrentMediaTime();
    double elapsed = now - previousSample;
    previousSample = now;
    uint32_t n = gDrawables.exchange(0);
    if (!n) return;
    dispatch_async(dispatch_get_main_queue(), ^{
      ZLog(@"[FPS] %.1f drawables/s (screen max %ld Hz)", n / elapsed, (long)UIScreen.mainScreen.maximumFramesPerSecond);
    });
  });
  dispatch_resume(t);
}

// Keep the frame limit; let the game's cooked shaders select their color path.
// Primary strategy: write Documents/ue4commandline.txt early (before engine reads it).
// Fallback: FCommandLine::Set / Append via symbol or known offset.
typedef void (*FCommandLineSetFn)(const char16_t*);
typedef void (*FCommandLineAppendFn)(const char16_t*);

static NSString* const kDefaultCommandLine = @"-t.MaxFPS=120";

static void setupGraphicsEnhancements() {
  repairSavedGraphics(gOriginalDocuments ?: gDocs, gSessionDir);
  if (gOriginalDocuments && ![gOriginalDocuments isEqualToString:gDocs])
    repairSavedGraphics(gDocs, gSessionDir);
  NSString* userCmdPath = [gDocs stringByAppendingPathComponent:@"ue4commandline.txt"];
  NSFileManager* fm = NSFileManager.defaultManager;
  
  NSString* existing = [NSString stringWithContentsOfFile:userCmdPath encoding:NSUTF8StringEncoding error:nil] ?: @"";
  // Migrate the previous adapter's forced Film/HDR/gamma settings. Preserve
  // unrelated switches rather than replacing the whole user's command line.
  NSString* cleaned = cleanLegacyGraphics(existing, YES);
  NSString* targetCmd = [cleaned stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!targetCmd.length) targetCmd = kDefaultCommandLine;
  if (![existing isEqualToString:cleaned]) {
    [existing writeToFile:[gSessionDir stringByAppendingPathComponent:@"previous-ue4commandline.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
    ZLog(@"[GRAPHICS] Removed adapter color overrides; using the game's native color/shader defaults");
  }
  // Write file — engine reads this on next applicationDidFinishLaunching
  NSError* writeErr = nil;
  [targetCmd writeToFile:userCmdPath atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
  if (!writeErr) {
    ZLog(@"[GRAPHICS] Wrote ue4commandline.txt: '%@'", targetCmd);
  } else {
    ZLog(@"[GRAPHICS] Failed to write ue4commandline.txt: %@", writeErr.localizedDescription);
  }

  // Backup: also try FCommandLine::Set in case engine already read its commandline
  intptr_t slide = _dyld_get_image_vmaddr_slide(0);
  FCommandLineSetFn setFn = nullptr;
  FCommandLineAppendFn appendFn = nullptr;
  if (slide != 0) {
    setFn = (FCommandLineSetFn)(0x101825828 + slide);
    appendFn = (FCommandLineAppendFn)(0x101825d60 + slide);
  }
  if (!setFn) setFn = (FCommandLineSetFn)dlsym(RTLD_DEFAULT, "_ZN12FCommandLine3SetEPKDs");
  if (!appendFn) appendFn = (FCommandLineAppendFn)dlsym(RTLD_DEFAULT, "_ZN12FCommandLine6AppendEPKDs");

  NSString* injectCmd = targetCmd;
  if (![injectCmd hasPrefix:@" "]) injectCmd = [@" " stringByAppendingString:injectCmd];
  std::u16string u16(injectCmd.length + 1, u'\0');
  for (NSUInteger i = 0; i < injectCmd.length; i++) {
    u16[i] = (char16_t)[injectCmd characterAtIndex:i];
  }
  if (setFn) {
    setFn(u16.data());
    ZLog(@"[GRAPHICS] FCommandLine::Set injected: '%@'", injectCmd);
  } else if (appendFn) {
    appendFn(u16.data());
    ZLog(@"[GRAPHICS] FCommandLine::Append injected: '%@'", injectCmd);
  } else {
    ZLog(@"[GRAPHICS] FCommandLine::Set not resolved; using ue4commandline.txt");
  }
}

// ---------------------------------------------------------------- launch gating
static std::atomic<bool> gGameStarted{false};
static IMP gOrigDidFinish, gOrigBecomeActive, gOrigResignActive, gOrigEnterBg, gOrigEnterFg;
static __strong id gLaunchApp;
static __strong NSDictionary* gLaunchOptions;
static __strong id gDelegate;
static __strong UIWindow* gImportWindow;
static void startGame();

static void ensureSymlink(NSString* linkPath, NSString* targetPath) {
  NSFileManager* fm = NSFileManager.defaultManager;
  if ([linkPath containsString:@"_mobile_ios"] && [targetPath containsString:@"_mobile_and"] &&
      [fm fileExistsAtPath:linkPath] && [linkPath.stringByResolvingSymlinksInPath containsString:@"_mobile_ios"]) return;
  if ([linkPath.stringByStandardizingPath isEqualToString:targetPath.stringByStandardizingPath]) return;
  if (![fm fileExistsAtPath:targetPath]) return;
  NSString* extension = targetPath.pathExtension.lowercaseString;
  if ([targetPath containsString:@"_mobile_and"] &&
      [@[@"pak", @"utoc", @"ucas"] containsObject:extension]) {
    ZLog(@"[DATA_PLATFORM] Android container needs asset conversion, not an iOS alias: %@", targetPath.lastPathComponent);
    return;
  }
  // Download/download can be the same directory on iOS. Never delete a file
  // in order to create a link back to itself, or replace genuine iOS data
  // with an Android alias of the same name.
  struct stat linkStat, targetStat;
  if (orig_stat && orig_stat(linkPath.fileSystemRepresentation, &linkStat) == 0 &&
      orig_stat(targetPath.fileSystemRepresentation, &targetStat) == 0 &&
      linkStat.st_dev == targetStat.st_dev && linkStat.st_ino == targetStat.st_ino) return;
  NSString* curDest = [fm destinationOfSymbolicLinkAtPath:linkPath error:nil];
  if (curDest && [curDest isEqualToString:targetPath]) return;

  BOOL isDir = NO;
  if ([fm fileExistsAtPath:linkPath isDirectory:&isDir]) {
    if (!isDir && curDest == nil) {
      NSDictionary* attrs = [fm attributesOfItemAtPath:linkPath error:nil];
      unsigned long long sz = [attrs fileSize];
      ZLog(@"[DATA_PRESERVE] keeping existing file %@ (%llu bytes)", linkPath.lastPathComponent, sz);
      return;
    }
    if (isDir && curDest == nil) {
      NSArray* contents = [fm contentsOfDirectoryAtPath:linkPath error:nil];
      if (contents.count > 0) {
        ZLog(@"%@ is a non-empty directory, will not overwrite with symlink", linkPath.lastPathComponent);
        return;
      }
    }
    // Our NSFileManager deletion guard protects commentary. Link maintenance
    // must bypass it, but only after confirming this is a symlink/empty folder.
    if (curDest) {
      if (unlink(linkPath.fileSystemRepresentation) != 0) return;
    } else {
      [fm removeItemAtPath:linkPath error:nil];
    }
  } else if (curDest != nil) {
    if (unlink(linkPath.fileSystemRepresentation) != 0) return;
  }

  NSError* err = nil;
  if ([fm createSymbolicLinkAtPath:linkPath withDestinationPath:targetPath error:&err]) {
    ZLog(@"Linked %@ -> %@", linkPath.lastPathComponent, targetPath);
  } else {
    ZLog(@"Failed to link %@: %@", linkPath.lastPathComponent, err);
  }
}

static NSString* findFolderNamed(NSString* root, NSString* targetName, int maxDepth) {
  if (maxDepth < 0) return nil;
  NSFileManager* fm = NSFileManager.defaultManager;
  for (NSString* item in [fm contentsOfDirectoryAtPath:root error:nil]) {
    NSString* full = [root stringByAppendingPathComponent:item];
    BOOL isDir = NO;
    if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
      if ([item.lowercaseString isEqualToString:targetName.lowercaseString]) {
        return full;
      }
      NSString* found = findFolderNamed(full, targetName, maxDepth - 1);
      if (found) return found;
    }
  }
  return nil;
}

#include "ZiruResources.inc"

static void installBundledTableFixes(NSArray<NSString*>* directories) {
  NSString* bundle = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ziru"];
  NSString* sourceDir = [bundle stringByAppendingPathComponent:@"livedata"];
  NSData* data = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"table-fixes.json"]];
  id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  NSMutableDictionary* manifest = [parsed isKindOfClass:NSDictionary.class] ? [parsed mutableCopy] : [NSMutableDictionary dictionary];
  data = [NSData dataWithContentsOfFile:[bundle stringByAppendingPathComponent:@"native-livedata.json"]];
  id native = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  if ([native isKindOfClass:NSArray.class]) for (NSDictionary* entry in native) {
    NSString* name = entry[@"name"];
    if ([name hasPrefix:@"pc92"] && [name isEqualToString:name.lastPathComponent] && entry[@"sha256"]) {
      manifest[name] = @{@"sha256": entry[@"sha256"], @"original_sha256": entry[@"android_sha256"] ?: @""};
    }
  }
  for (NSString* name in manifest) {
    BOOL cpk = [name isEqualToString:@"dt870_mobile_and.cpk"] || [name isEqualToString:@"dt870_mobile_ios.cpk"];
    if (!cpk && ![name hasSuffix:@".utoc"]) continue;
    NSArray* group = cpk ? @[name] : @[[name.stringByDeletingPathExtension stringByAppendingString:@".pak"],
        name, [name.stringByDeletingPathExtension stringByAppendingString:@".ucas"]];
    for (NSString* directory in directories) {
      if (!cpk && [directory.lastPathComponent isEqualToString:@"cpk"]) continue;
      installResourceGroup(group, sourceDir, directory, manifest);
      // The compatibility alias never replaces a real custom CPK.
      if (cpk) ensureSymlink([directory stringByAppendingPathComponent:@"dt870_mobile_ios.cpk"],
                            [directory stringByAppendingPathComponent:name]);
    }
  }
}

static BOOL checkDirectFolderData(NSString** why) {
  NSFileManager* fm = NSFileManager.defaultManager;

  // Search for pak, cpk, Download, livedata anywhere inside Documents (up to 3 levels deep)
  NSString* foundPak = findFolderNamed(gDocs, @"pak", 3);
  NSString* foundCpk = findFolderNamed(gDocs, @"cpk", 3);
  NSString* foundDl = findFolderNamed(gDocs, @"Download", 3);
  if (!foundDl) foundDl = findFolderNamed(gDocs, @"download", 3);
  NSString* foundLivedata = findFolderNamed(gDocs, @"livedata", 3);

  // If user dropped .pak/.ucas/.utoc files directly into Documents without folder:
  if (!foundPak) {
    for (NSString* item in [fm contentsOfDirectoryAtPath:gDocs error:nil]) {
      if ([item.pathExtension.lowercaseString isEqualToString:@"pak"]) {
        NSString* pakDir = [gDocs stringByAppendingPathComponent:@"pak"];
        [fm createDirectoryAtPath:pakDir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString* f in [fm contentsOfDirectoryAtPath:gDocs error:nil]) {
          NSString* ext = f.pathExtension.lowercaseString;
          if ([ext isEqualToString:@"pak"] || [ext isEqualToString:@"ucas"] || [ext isEqualToString:@"utoc"]) {
            ensureSymlink([pakDir stringByAppendingPathComponent:f], [gDocs stringByAppendingPathComponent:f]);
          }
        }
        foundPak = pakDir;
        break;
      }
    }
  }

  // If user dropped .cpk files directly into Documents without folder:
  if (!foundCpk) {
    for (NSString* item in [fm contentsOfDirectoryAtPath:gDocs error:nil]) {
      if ([item.pathExtension.lowercaseString isEqualToString:@"cpk"] && ![item.lowercaseString containsString:@"dt510"]) {
        NSString* cpkDir = [gDocs stringByAppendingPathComponent:@"cpk"];
        [fm createDirectoryAtPath:cpkDir withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString* f in [fm contentsOfDirectoryAtPath:gDocs error:nil]) {
          if ([f.pathExtension.lowercaseString isEqualToString:@"cpk"] && ![f.lowercaseString containsString:@"dt510"]) {
            ensureSymlink([cpkDir stringByAppendingPathComponent:f], [gDocs stringByAppendingPathComponent:f]);
          }
        }
        foundCpk = cpkDir;
        break;
      }
    }
  }

  // Symlink found directories to gDocs/pak, gDocs/cpk, etc.
  if (foundPak && ![foundPak isEqualToString:[gDocs stringByAppendingPathComponent:@"pak"]]) {
    ensureSymlink([gDocs stringByAppendingPathComponent:@"pak"], foundPak);
  }
  if (foundCpk && ![foundCpk isEqualToString:[gDocs stringByAppendingPathComponent:@"cpk"]]) {
    ensureSymlink([gDocs stringByAppendingPathComponent:@"cpk"], foundCpk);
  }
  if (foundLivedata && ![foundLivedata isEqualToString:[gDocs stringByAppendingPathComponent:@"livedata"]]) {
    ensureSymlink([gDocs stringByAppendingPathComponent:@"livedata"], foundLivedata);
  }

  NSString* pakDir = [gDocs stringByAppendingPathComponent:@"pak"];
  NSString* cpkDir = [gDocs stringByAppendingPathComponent:@"cpk"];
  NSString* dlDir = [gDocs stringByAppendingPathComponent:@"Download"];
  [fm createDirectoryAtPath:dlDir withIntermediateDirectories:YES attributes:nil error:nil];

  // Stadium auto-import disabled to prevent Android Vulkan shaders from breaking iOS Metal render

  installBundledTableFixes(@[[gDocs stringByAppendingPathComponent:@"livedata"], cpkDir, dlDir]);

  // Old IPA versions created absolute Android aliases. Remove those links only;
  // If livedata is bundled in IPA (PESmobile.app/ziru/livedata), extract/link into Documents/livedata
  NSString* bundleLivedata = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ziru/livedata"];
  if ([fm fileExistsAtPath:bundleLivedata]) {
    NSString* liveDocs = [gDocs stringByAppendingPathComponent:@"livedata"];
    [fm createDirectoryAtPath:liveDocs withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString* f in [fm contentsOfDirectoryAtPath:bundleLivedata error:nil]) {
      NSString* src = [bundleLivedata stringByAppendingPathComponent:f];
      NSString* dst = [liveDocs stringByAppendingPathComponent:f];
      ensureSymlink(dst, src);
    }
    if (!foundLivedata) foundLivedata = liveDocs;
  }

  // Extra UI container bundled in the IPA (tools/make_extra_pak.py): standard card photos, emblems, kit thumbnails that
  // exist only in Ziru's Android data. Linked into Documents/pak so the engine mounts it with the other containers.
  NSString* bundleExtra = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"ziru/pak_extra"];
  if ([fm fileExistsAtPath:bundleExtra]) installExtraResourceGroups(bundleExtra, pakDir);

  // Create _mobile_ios symlinks for livedata files, and mount all epic paks/ucas/utoc into pak/ and cpk into cpk/
  // CRITICAL: Also link into Documents/Download/ because onlinemode::UtilityLiveData::GetLiveDataSaveDirPath()
  // returns Documents/Download/ where LiveDataVersionLoader, LiveDataHashChecker, and LiveDataBinder look for dt870 and pc9242..pc9259!
  // Stadium files belong exclusively in Documents/Download/ where AddStadiumDlTask expects them.
  // Never mount stadium paks in Documents/pak/ (Unreal Engine boot mount causes stream deadlock / black screen).
  NSArray* staleEnginePaks = [fm contentsOfDirectoryAtPath:pakDir error:nil];
  for (NSString* stale in staleEnginePaks) {
    if (!zm::stadiumName(stale.UTF8String)) continue;
    NSString* sp = [pakDir stringByAppendingPathComponent:stale];
    if ([fm destinationOfSymbolicLinkAtPath:sp error:nil]) {
      unlink(sp.fileSystemRepresentation);
    } else if ([fm fileExistsAtPath:sp]) {
      NSString* dst = [dlDir stringByAppendingPathComponent:stale];
      if (![fm fileExistsAtPath:dst]) [fm moveItemAtPath:sp toPath:dst error:nil];
    }
  }

  // Purge corrupt Android Vulkan stadium containers mistakenly copied or symlinked as iOS
  for (NSString* stem in @[@"pc3001_mobile_ios", @"pc3011_mobile_ios"]) {
    NSString* ucas = [pakDir stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"ucas"]];
    NSDictionary* attrs = [fm attributesOfItemAtPath:ucas error:nil];
    if (attrs) {
      unsigned long long sz = [attrs fileSize];
      if (sz == 257503552ULL || sz == 117250880ULL) {
        ZLog(@"[STADIUM] Purging Android Vulkan stadium container %@ (size %llu) to prevent black screen", stem, sz);
        unlink(ucas.fileSystemRepresentation);
        unlink([pakDir stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"utoc"]].fileSystemRepresentation);
        unlink([pakDir stringByAppendingPathComponent:[stem stringByAppendingPathExtension:@"pak"]].fileSystemRepresentation);
      }
    }
  }

  // Do not purge packs or version metadata by filename. In particular pc3611
  // contains native face textures, and removing it breaks thousands of faces.
  // Do not overwrite the user's command line on each launch.

  // Resource repair is hash-authorized above. Pack IDs alone do not authorize
  // deleting user data, including additional player packs.

  // setupGraphicsEnhancements migrates old forced color settings before startup.

  // Native character containers belong in pak/, including the face textures.
  for (NSString* core in @[@"pc3600", @"pc3611"]) {
    for (NSString* ext in @[@".pak", @".ucas", @".utoc"]) {
      NSString* name = [NSString stringWithFormat:@"%@_mobile_ios%@", core, ext];
      NSString* wrong = [dlDir stringByAppendingPathComponent:name];
      NSString* right = [pakDir stringByAppendingPathComponent:name];
      if ([fm fileExistsAtPath:wrong] && ![fm fileExistsAtPath:right]) {
        [fm moveItemAtPath:wrong toPath:right error:nil];
        ZLog(@"[CORE_PAK] Restored %@ from Download/ to pak/", name);
      }
    }
  }

  NSString* liveDir = [gDocs stringByAppendingPathComponent:@"livedata"];
  if ([fm fileExistsAtPath:liveDir]) {
    for (NSString* f in [fm contentsOfDirectoryAtPath:liveDir error:nil]) {
      NSString* target = [liveDir stringByAppendingPathComponent:f];
      NSString* ext = f.pathExtension.lowercaseString;
      if ([f containsString:@"_mobile_and"] && ![ext isEqualToString:@"cpk"]) {
        NSString* nativeName = [f stringByReplacingOccurrencesOfString:@"_mobile_and" withString:@"_mobile_ios"];
        NSString* nativePath = [liveDir stringByAppendingPathComponent:nativeName];
        if ([fm fileExistsAtPath:nativePath] && [nativePath.stringByResolvingSymlinksInPath containsString:@"_mobile_ios"]) {
          for (NSString* dir in @[pakDir, dlDir]) {
            NSString* old = [dir stringByAppendingPathComponent:f];
            if ([fm destinationOfSymbolicLinkAtPath:old error:nil]) unlink(old.fileSystemRepresentation);
          }
          continue; // retain the Android original in livedata; mount the native iOS package below
        }
      }
      if (zm::stadiumName(f.UTF8String) || [f containsString:@"stadium"]) {
        // Skip linking Vulkan stadiums to prevent black screen
        continue;
      }
      if ([f containsString:@"_mobile_and"]) {
        NSString* iosName = [f stringByReplacingOccurrencesOfString:@"_mobile_and" withString:@"_mobile_ios"];
        NSString* link = [liveDir stringByAppendingPathComponent:iosName];
        ensureSymlink(link, target);
      }
      if ([ext isEqualToString:@"pak"] || [ext isEqualToString:@"ucas"] || [ext isEqualToString:@"utoc"]) {
        ensureSymlink([pakDir stringByAppendingPathComponent:f], target);
        ensureSymlink([dlDir stringByAppendingPathComponent:f], target);
        if ([f containsString:@"_mobile_and"]) {
          NSString* iosName = [f stringByReplacingOccurrencesOfString:@"_mobile_and" withString:@"_mobile_ios"];
          ensureSymlink([pakDir stringByAppendingPathComponent:iosName], target);
          ensureSymlink([dlDir stringByAppendingPathComponent:iosName], target);
        }
      } else if ([ext isEqualToString:@"cpk"]) {
        ensureSymlink([cpkDir stringByAppendingPathComponent:f], target);
        ensureSymlink([dlDir stringByAppendingPathComponent:f], target);
        if ([f containsString:@"_mobile_and"]) {
          NSString* iosName = [f stringByReplacingOccurrencesOfString:@"_mobile_and" withString:@"_mobile_ios"];
          ensureSymlink([cpkDir stringByAppendingPathComponent:iosName], target);
          ensureSymlink([dlDir stringByAppendingPathComponent:iosName], target);
        }
      }
    }
  }

  // For Download/download: link files individually into Documents/Download
  if (foundDl && ![foundDl isEqualToString:dlDir]) {
    for (NSString* f in [fm contentsOfDirectoryAtPath:foundDl error:nil]) {
      NSString* src = [foundDl stringByAppendingPathComponent:f];
      NSString* dst = [dlDir stringByAppendingPathComponent:f];
      ensureSymlink(dst, src);
      if ([f containsString:@"_mobile_and"]) {
        NSString* iosName = [f stringByReplacingOccurrencesOfString:@"_mobile_and" withString:@"_mobile_ios"];
        ensureSymlink([dlDir stringByAppendingPathComponent:iosName], src);
      }
    }
  }

  // Ensure every _mobile_and file in pak, cpk, Download, and livedata has a corresponding _mobile_ios symlink
  NSArray<NSString*>* allModDirs = @[pakDir, cpkDir, dlDir, [gDocs stringByAppendingPathComponent:@"livedata"], gDocs];
  for (NSString* dir in allModDirs) {
    for (NSString* f in [fm contentsOfDirectoryAtPath:dir error:nil]) {
      if ([f containsString:@"_mobile_and"]) {
        // NEVER symlink Android Vulkan stadiums to iOS Metal!
        if ([f hasPrefix:@"pc3001"] || [f hasPrefix:@"pc3011"]) continue;
        NSString* iosName = [f stringByReplacingOccurrencesOfString:@"_mobile_and" withString:@"_mobile_ios"];
        NSString* dst = [dir stringByAppendingPathComponent:iosName];
        NSString* src = [dir stringByAppendingPathComponent:f];
        ensureSymlink(dst, src);
      }
    }
  }

  // Auto-create stub .pak if .utoc exists in pakDir or dlDir but .pak is missing
  for (NSString* dir in @[pakDir, dlDir]) {
    for (NSString* item in [fm contentsOfDirectoryAtPath:dir error:nil]) {
      if ([item.pathExtension.lowercaseString isEqualToString:@"utoc"]) {
        NSString* stem = [item stringByDeletingPathExtension];
        NSString* pakName = [stem stringByAppendingPathExtension:@"pak"];
        NSString* pakPath = [dir stringByAppendingPathComponent:pakName];
        if (![fm fileExistsAtPath:pakPath]) {
          NSString* templatePak = nil;
          for (NSString* check in [fm contentsOfDirectoryAtPath:pakDir error:nil]) {
            if ([check.pathExtension.lowercaseString isEqualToString:@"pak"]) {
              NSString* cp = [pakDir stringByAppendingPathComponent:check];
              NSDictionary* attrs = [fm attributesOfItemAtPath:cp error:nil];
              if ([attrs[NSFileSize] unsignedLongLongValue] == 365) {
                templatePak = cp;
                break;
              }
            }
          }
          if (templatePak) {
            [fm copyItemAtPath:templatePak toPath:pakPath error:nil];
            ZLog(@"[AUTO_PAK] Auto-generated pak stub for %@", item);
          }
        }
      }
    }
  }

  // Accept commentary next to the data, inside cpk/, or inside a nested data
  // folder. Keep the real 1.26 GB file in place and repair the Download alias.
  NSString* blvName = @"dt510_eng_mobile_all.cpk";
  NSArray* blvRoots = @[gDocs, cpkDir, [gDocs stringByAppendingPathComponent:@"data"],
    [gDocs stringByAppendingPathComponent:@"PES2027-data"],
    [gDocs stringByAppendingPathComponent:@"PES2027-data/cpk"],
    [gDocs stringByAppendingPathComponent:@"data/cpk"],
    [gDocs stringByAppendingPathComponent:@"data/Download"]];
  for (NSString* root in blvRoots) {
    NSString* source = [root stringByAppendingPathComponent:blvName];
    NSDictionary* attrs = [fm attributesOfItemAtPath:source.stringByResolvingSymlinksInPath error:nil];
    if ([attrs[NSFileType] isEqualToString:NSFileTypeRegular] && [attrs[NSFileSize] unsignedLongLongValue] > 0) {
      ensureSymlink([dlDir stringByAppendingPathComponent:blvName], source);
      break;
    }
  }

  BOOL isDir = NO;
  if (![fm fileExistsAtPath:pakDir isDirectory:&isDir]) {
    if (why) *why = @"Chưa tìm thấy thư mục 'pak' trong Documents hoặc PES2027-data";
    return NO;
  }
  if (![fm fileExistsAtPath:cpkDir isDirectory:&isDir]) {
    if (why) *why = @"Chưa tìm thấy thư mục 'cpk' trong Documents hoặc PES2027-data";
    return NO;
  }

  NSArray* pakItems = [fm contentsOfDirectoryAtPath:pakDir error:nil];
  NSArray* cpkItems = [fm contentsOfDirectoryAtPath:cpkDir error:nil];
  if (pakItems.count == 0 || cpkItems.count == 0) {
    if (why) *why = @"Thư mục pak hoặc cpk bị trống không có tệp dữ liệu";
    return NO;
  }

  ZLog(@"Direct folder data ready: pak=%lu files, cpk=%lu files", (unsigned long)pakItems.count, (unsigned long)cpkItems.count);
  return YES;
}

static BOOL dataReady(NSString** why) {
#ifdef EFOOTXI_IOS
  BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:[gDocs stringByAppendingPathComponent:@"pak"]];
  if (why) *why = exists ? @"Efootxi data prepared" : @"Chua co du lieu Efootxi trong thu muc pak";
  return exists;
#endif
  if (checkDirectFolderData(why)) return YES;
  std::string err;
  zd::Layout L = layout();
  std::string id = zd::activeId(L);
  NSString* appVer = [NSBundle.mainBundle.infoDictionary objectForKey:@"CFBundleShortVersionString"] ?: @"";
  NSString* appBuild = [NSBundle.mainBundle.infoDictionary objectForKey:@"CFBundleVersion"] ?: @"";
  bool ok = zd::quickVerify(L, id, appVer.UTF8String ?: "", appBuild.UTF8String ?: "", ZIRU_MOD_VERSION, err);
  if (!ok && why) *why = [NSString stringWithUTF8String:err.c_str()];
  return ok;
}

// ---------------------------------------------------------------- PES21 UI components
@interface PESPressButton : UIButton
@end

@implementation PESPressButton
- (void)setHighlighted:(BOOL)highlighted {
  [super setHighlighted:highlighted];
  [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.75 initialSpringVelocity:0.5
                      options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                   animations:^{
                     self.transform = highlighted ? CGAffineTransformMakeScale(0.97, 0.97) : CGAffineTransformIdentity;
                   } completion:nil];
}
@end

@interface PESPitchBackdrop : UIView
@property (nonatomic, strong) CAGradientLayer* gradient;
@property (nonatomic, strong) CAShapeLayer* pitch;
@property (nonatomic, strong) CAShapeLayer* slash;
@end

@implementation PESPitchBackdrop
- (instancetype)initWithFrame:(CGRect)frame {
  if ((self = [super initWithFrame:frame])) {
    self.userInteractionEnabled = NO;
    _gradient = [CAGradientLayer layer];
    _gradient.colors = @[
      (id)PESNight().CGColor,
      (id)[UIColor colorWithRed:0.035 green:0.08 blue:0.11 alpha:1.0].CGColor,
      (id)PESNight().CGColor
    ];
    _gradient.startPoint = CGPointMake(0.0, 0.0);
    _gradient.endPoint = CGPointMake(1.0, 1.0);
    [self.layer addSublayer:_gradient];

    _slash = [CAShapeLayer layer];
    _slash.fillColor = [PESLime() colorWithAlphaComponent:0.035].CGColor;
    [self.layer addSublayer:_slash];

    _pitch = [CAShapeLayer layer];
    _pitch.strokeColor = [PESCyan() colorWithAlphaComponent:0.12].CGColor;
    _pitch.fillColor = UIColor.clearColor.CGColor;
    _pitch.lineWidth = 1.2;
    [self.layer addSublayer:_pitch];
  }
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  _gradient.frame = self.bounds;
  CGFloat w = self.bounds.size.width;
  CGFloat h = self.bounds.size.height;
  if (w <= 0 || h <= 0) return;

  UIBezierPath* sp = [UIBezierPath bezierPath];
  [sp moveToPoint:CGPointMake(w * 0.18, 0)];
  [sp addLineToPoint:CGPointMake(w * 0.48, 0)];
  [sp addLineToPoint:CGPointMake(w * 0.32, h)];
  [sp addLineToPoint:CGPointMake(0, h)];
  [sp closePath];
  _slash.path = sp.CGPath;

  UIBezierPath* p = [UIBezierPath bezierPath];
  CGFloat pad = 24.0;
  CGRect pitchRect = CGRectInset(self.bounds, pad, pad);
  [p appendPath:[UIBezierPath bezierPathWithRoundedRect:pitchRect cornerRadius:14.0]];
  CGFloat midX = CGRectGetMidX(pitchRect);
  [p moveToPoint:CGPointMake(midX, CGRectGetMinY(pitchRect))];
  [p addLineToPoint:CGPointMake(midX, CGRectGetMaxY(pitchRect))];
  CGPoint center = CGPointMake(midX, CGRectGetMidY(pitchRect));
  [p moveToPoint:CGPointMake(center.x + 65.0, center.y)];
  [p addArcWithCenter:center radius:65.0 startAngle:0 endAngle:M_PI * 2 clockwise:YES];
  _pitch.path = p.CGPath;
}
@end

// ---------------------------------------------------------------- diagnostics modal (log viewer)
@interface PESDiagnosticsVC : UIViewController
@property (nonatomic, strong) UISegmentedControl* seg;
@property (nonatomic, strong) UITextView* tv;
@property (nonatomic, strong) NSArray<NSString*>* logNames;
@end

@implementation PESDiagnosticsVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = PESNight();
  self.logNames = @[@"adapter.log", @"stdout-stderr.log", @"crash.log", @"network.jsonl"];

  UIView* topBar = [UIView new];
  topBar.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:topBar];

  UIButton* closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [closeBtn setTitle:@"Đóng" forState:UIControlStateNormal];
  closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  closeBtn.tintColor = PESLime();
  [closeBtn addTarget:self action:@selector(onClose) forControlEvents:UIControlEventTouchUpInside];
  closeBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [topBar addSubview:closeBtn];

  UIButton* shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
  [shareBtn setTitle:@"Chia sẻ nhật ký" forState:UIControlStateNormal];
  shareBtn.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  shareBtn.tintColor = PESCyan();
  [shareBtn addTarget:self action:@selector(onShare) forControlEvents:UIControlEventTouchUpInside];
  shareBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [topBar addSubview:shareBtn];

  self.seg = [[UISegmentedControl alloc] initWithItems:@[@"Ziru", @"File I/O", @"Crash", @"Server"]];
  self.seg.selectedSegmentIndex = 0;
  self.seg.selectedSegmentTintColor = [PESLime() colorWithAlphaComponent:0.25];
  [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: PESLime()} forState:UIControlStateSelected];
  [self.seg setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor} forState:UIControlStateNormal];
  [self.seg addTarget:self action:@selector(onTabChanged) forControlEvents:UIControlEventValueChanged];
  self.seg.translatesAutoresizingMaskIntoConstraints = NO;
  [topBar addSubview:self.seg];

  self.tv = [UITextView new];
  self.tv.editable = NO;
  self.tv.backgroundColor = [UIColor colorWithWhite:0 alpha:0.4];
  self.tv.layer.cornerRadius = 10;
  self.tv.font = [UIFont fontWithName:@"Courier" size:11] ?: [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
  self.tv.textColor = [UIColor colorWithRed:0.8 green:0.9 blue:0.95 alpha:1.0];
  self.tv.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:self.tv];

  UILayoutGuide* g = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [topBar.topAnchor constraintEqualToAnchor:g.topAnchor constant:8],
    [topBar.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
    [topBar.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
    [topBar.heightAnchor constraintEqualToConstant:40],

    [closeBtn.leadingAnchor constraintEqualToAnchor:topBar.leadingAnchor],
    [closeBtn.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],

    [self.seg.centerXAnchor constraintEqualToAnchor:topBar.centerXAnchor],
    [self.seg.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],

    [shareBtn.trailingAnchor constraintEqualToAnchor:topBar.trailingAnchor],
    [shareBtn.centerYAnchor constraintEqualToAnchor:topBar.centerYAnchor],

    [self.tv.topAnchor constraintEqualToAnchor:topBar.bottomAnchor constant:12],
    [self.tv.leadingAnchor constraintEqualToAnchor:g.leadingAnchor constant:16],
    [self.tv.trailingAnchor constraintEqualToAnchor:g.trailingAnchor constant:-16],
    [self.tv.bottomAnchor constraintEqualToAnchor:g.bottomAnchor constant:-12],
  ]];

  [self onTabChanged];
}

- (void)onClose {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)onTabChanged {
  NSInteger idx = self.seg.selectedSegmentIndex;
  if (idx < 0 || idx >= (NSInteger)self.logNames.count) return;
  NSString* name = self.logNames[idx];
  NSString* path = [gSessionDir stringByAppendingPathComponent:name];
  NSError* err = nil;
  NSString* content = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&err];
  if (!content || !content.length) {
    self.tv.text = [NSString stringWithFormat:@"[Chưa có dữ liệu trong %@]", name];
  } else {
    self.tv.text = content;
    if (content.length > 0) {
      [self.tv scrollRangeToVisible:NSMakeRange(content.length - 1, 1)];
    }
  }
}

- (void)onShare {
  NSMutableArray* urls = [NSMutableArray array];
  NSString* dir = gSessionDir;
  for (NSString* n in self.logNames) {
    NSString* p = [dir stringByAppendingPathComponent:n];
    if ([NSFileManager.defaultManager fileExistsAtPath:p]) {
      [urls addObject:[NSURL fileURLWithPath:p]];
    }
  }
  if (!urls.count) {
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Chưa có nhật ký" message:@"Chưa có file log nào để chia sẻ." preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
    return;
  }
  UIActivityViewController* act = [[UIActivityViewController alloc] initWithActivityItems:urls applicationActivities:nil];
  act.popoverPresentationController.sourceView = self.view;
  [self presentViewController:act animated:YES completion:nil];
}
@end

// ---------------------------------------------------------------- ZiruImportVC
@interface ZiruImportVC : UIViewController <UIDocumentPickerDelegate>
@property(nonatomic, strong) UILabel* status;
@property(nonatomic, strong) UILabel* detail;
@property(nonatomic, strong) UIProgressView* bar;
@property(nonatomic, strong) PESPressButton* pick;
@property(nonatomic, strong) PESPressButton* local;
@property(nonatomic, strong) PESPressButton* rescan;
@property(nonatomic, strong) PESPressButton* logs;
@property(nonatomic, strong) UILabel* watermarkLabel;
@property(nonatomic, copy) NSString* localZip;
@property(atomic) BOOL busy;
@end

@implementation ZiruImportVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)prefersStatusBarHidden { return YES; }

static PESPressButton* makeButton(NSString* title, BOOL primary) {
  PESPressButton* b = [PESPressButton buttonWithType:UIButtonTypeCustom];
  [b setTitle:title forState:UIControlStateNormal];
  b.titleLabel.font = [UIFont boldSystemFontOfSize:16];
  if (primary) {
    b.backgroundColor = PESLime();
    [b setTitleColor:PESNight() forState:UIControlStateNormal];
  } else {
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.07];
    b.layer.borderWidth = 1.2;
    b.layer.borderColor = [PESLime() colorWithAlphaComponent:0.4].CGColor;
    [b setTitleColor:PESLime() forState:UIControlStateNormal];
  }
  b.layer.cornerRadius = 12;
  b.contentEdgeInsets = UIEdgeInsetsMake(12, 24, 12, 24);
  b.translatesAutoresizingMaskIntoConstraints = NO;
  return b;
}

- (void)checkTamper {
  // Enforce unremovable watermark "Made by iOSVN"
  if (self.watermarkLabel) {
    if (self.watermarkLabel.hidden || self.watermarkLabel.alpha < 0.1 ||
        ![self.watermarkLabel.text containsString:ZIRU_WATERMARK_KEY]) {
      NSLog(@"[CRITICAL ERROR] Integrity failure: Watermark %@ was modified or removed.", ZIRU_WATERMARK_KEY);
      abort();
    }
  }
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.08 blue:0.13 alpha:1.0];

  // Pitch backdrop (PES21 stadium style)
  PESPitchBackdrop* backdrop = [[PESPitchBackdrop alloc] initWithFrame:self.view.bounds];
  backdrop.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [self.view addSubview:backdrop];

  UIScrollView* scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
  scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  scroll.alwaysBounceVertical = YES;
  [self.view addSubview:scroll];

  // Glass Card container
  UIView* card = [UIView new];
  card.backgroundColor = [UIColor colorWithRed:0.06 green:0.11 blue:0.17 alpha:0.96];
  card.layer.cornerRadius = 18;
  card.layer.borderWidth = 1.5;
  card.layer.borderColor = [PESLime() colorWithAlphaComponent:0.6].CGColor;
  card.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:card];

  // Title Header: "PES 2027" + "OFFLINE"
  NSMutableAttributedString* mat = [[NSMutableAttributedString alloc]
    initWithString:@"PES 2027 "
    attributes:@{
      NSFontAttributeName: [UIFont italicSystemFontOfSize:26],
      NSForegroundColorAttributeName: UIColor.whiteColor
    }];
  [mat appendAttributedString:[[NSAttributedString alloc]
    initWithString:@"OFFLINE"
    attributes:@{
      NSFontAttributeName: [UIFont boldSystemFontOfSize:26],
      NSForegroundColorAttributeName: PESLime()
    }]];
  UILabel* title = [UILabel new];
  title.attributedText = mat;
  title.textAlignment = NSTextAlignmentCenter;

  // Subtitle Badge Pill
  UIView* pill = [UIView new];
  pill.backgroundColor = [PESLime() colorWithAlphaComponent:0.12];
  pill.layer.cornerRadius = 11;
  pill.layer.borderWidth = 1;
  pill.layer.borderColor = [PESLime() colorWithAlphaComponent:0.35].CGColor;
  UILabel* pillText = [UILabel new];
  pillText.text = @"eFootball Ziru • iOS Mod v" ZIRU_MOD_VERSION;
  pillText.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
  pillText.textColor = PESLime();
  pillText.translatesAutoresizingMaskIntoConstraints = NO;
  [pill addSubview:pillText];
  [NSLayoutConstraint activateConstraints:@[
    [pillText.topAnchor constraintEqualToAnchor:pill.topAnchor constant:4],
    [pillText.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-4],
    [pillText.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:12],
    [pillText.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-12],
  ]];

  self.status = [UILabel new];
  self.status.textColor = [UIColor colorWithWhite:0.95 alpha:1];
  self.status.font = [UIFont systemFontOfSize:14 weight:UIFontWeightRegular];
  self.status.numberOfLines = 0;
  self.status.textAlignment = NSTextAlignmentCenter;

  self.detail = [UILabel new];
  self.detail.textColor = PESMuted();
  self.detail.font = [UIFont systemFontOfSize:12];
  self.detail.numberOfLines = 0;
  self.detail.textAlignment = NSTextAlignmentCenter;

  self.bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault];
  self.bar.progressTintColor = PESLime();
  self.bar.trackTintColor = [UIColor colorWithWhite:1 alpha:0.12];
  self.bar.layer.cornerRadius = 3;
  self.bar.clipsToBounds = YES;
  self.bar.hidden = YES;

  self.rescan = makeButton(@"Quét thư mục data (3uTools / Tệp)", YES);
  [self.rescan addTarget:self action:@selector(onRescan) forControlEvents:UIControlEventTouchUpInside];

  self.pick = makeButton(@"Chọn file (.zip) từ Tệp", NO);
  [self.pick addTarget:self action:@selector(onPick) forControlEvents:UIControlEventTouchUpInside];

  self.local = makeButton(@"Nhập file .zip trong Documents", NO);
  [self.local addTarget:self action:@selector(onLocal) forControlEvents:UIControlEventTouchUpInside];

  self.logs = makeButton(@"Xem nhật ký (Logs)", NO);
  self.logs.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
  self.logs.contentEdgeInsets = UIEdgeInsetsMake(6, 16, 6, 16);
  [self.logs setTitleColor:PESCyan() forState:UIControlStateNormal];
  self.logs.layer.borderColor = [PESCyan() colorWithAlphaComponent:0.35].CGColor;
  [self.logs addTarget:self action:@selector(onShowLogs) forControlEvents:UIControlEventTouchUpInside];

  // Watermark "Made by iOSVN"
  UIView* wmContainer = [UIView new];
  wmContainer.backgroundColor = [PESLime() colorWithAlphaComponent:0.08];
  wmContainer.layer.cornerRadius = 10;
  wmContainer.layer.borderWidth = 1;
  wmContainer.layer.borderColor = [PESLime() colorWithAlphaComponent:0.35].CGColor;
  wmContainer.translatesAutoresizingMaskIntoConstraints = NO;

  self.watermarkLabel = [UILabel new];
  self.watermarkLabel.text = ZIRU_WATERMARK;
  self.watermarkLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
  self.watermarkLabel.textColor = PESLime();
  self.watermarkLabel.textAlignment = NSTextAlignmentCenter;
  self.watermarkLabel.translatesAutoresizingMaskIntoConstraints = NO;
  [wmContainer addSubview:self.watermarkLabel];

  [NSLayoutConstraint activateConstraints:@[
    [self.watermarkLabel.topAnchor constraintEqualToAnchor:wmContainer.topAnchor constant:4],
    [self.watermarkLabel.bottomAnchor constraintEqualToAnchor:wmContainer.bottomAnchor constant:-4],
    [self.watermarkLabel.leadingAnchor constraintEqualToAnchor:wmContainer.leadingAnchor constant:14],
    [self.watermarkLabel.trailingAnchor constraintEqualToAnchor:wmContainer.trailingAnchor constant:-14],
  ]];

  UIStackView* btnStack = [[UIStackView alloc] initWithArrangedSubviews:@[self.rescan, self.pick, self.local]];
  btnStack.axis = UILayoutConstraintAxisVertical;
  btnStack.alignment = UIStackViewAlignmentFill;
  btnStack.spacing = 8;
  btnStack.translatesAutoresizingMaskIntoConstraints = NO;

  UIStackView* cardStack = [[UIStackView alloc] initWithArrangedSubviews:@[
    title, pill, self.status, self.bar, btnStack, self.detail, self.logs, wmContainer
  ]];
  cardStack.axis = UILayoutConstraintAxisVertical;
  cardStack.alignment = UIStackViewAlignmentCenter;
  cardStack.spacing = 11;
  cardStack.translatesAutoresizingMaskIntoConstraints = NO;
  [card addSubview:cardStack];

  NSLayoutConstraint* cardWidth = [card.widthAnchor constraintEqualToConstant:440];
  cardWidth.priority = UILayoutPriorityDefaultHigh;

  [NSLayoutConstraint activateConstraints:@[
    [card.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:20],
    [card.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-20],
    [card.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    cardWidth,
    [card.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:16],
    [card.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-16],
    [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:16],
    [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
    [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:20],
    [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-20],
    [btnStack.widthAnchor constraintEqualToAnchor:cardStack.widthAnchor],
    [self.bar.widthAnchor constraintEqualToAnchor:cardStack.widthAnchor],
  ]];

  [self refresh];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self checkTamper];
}

- (void)onShowLogs {
  [self checkTamper];
  PESDiagnosticsVC* vc = [PESDiagnosticsVC new];
  vc.modalPresentationStyle = UIModalPresentationFullScreen;
  [self presentViewController:vc animated:YES completion:nil];
}

- (NSString*)findLocalZip {
  NSArray* items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:gDocs error:nil];
  for (NSString* n in [items sortedArrayUsingSelector:@selector(compare:)]) {
    if ([n.lowercaseString hasPrefix:@"pes2027-data"] && [n.lowercaseString hasSuffix:@".zip"]) return [gDocs stringByAppendingPathComponent:n];
  }
  return nil;
}

- (void)refresh {
  NSString* why = nil;
  if (dataReady(&why)) {
    self.status.text = @"Đã phát hiện dữ liệu game! Đang vào game…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      startGame();
    });
    return;
  }
  self.localZip = [self findLocalZip];
  self.local.hidden = self.localZip == nil;
  if (self.localZip) [self.local setTitle:[NSString stringWithFormat:@"Nhập %@", self.localZip.lastPathComponent] forState:UIControlStateNormal];
  self.status.text = @"Chưa có dữ liệu game. Bạn có thể:\n"
                     @"1. Dùng 3uTools chép thẳng thư mục data (pak, cpk, Download, livedata) vào app.\n"
                     @"2. Hoặc chọn file .zip từ app Tệp để giải nén.";
  self.detail.text = [NSString stringWithFormat:@"Bản mod %s • %@", ZIRU_MOD_VERSION, why ?: @""];
}

- (void)onRescan {
  [self checkTamper];
  NSString* why = nil;
  if (dataReady(&why)) {
    self.status.text = @"Đã phát hiện dữ liệu game! Đang khởi động…";
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
      startGame();
    });
  } else {
    [self refresh];
    UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Chưa thấy đủ thư mục dữ liệu"
                                                               message:why ?: @"Hãy đảm bảo đã chép các thư mục pak, cpk, Download, livedata vào Documents."
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
  }
}

- (void)onPick {
  [self checkTamper];
  if (self.busy) return;
  UIDocumentPickerViewController* p;
  if (@available(iOS 14.0, *)) {
    p = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeZIP, UTTypeData ] asCopy:NO];
  } else {
    p = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.zip-archive", @"public.data" ] inMode:UIDocumentPickerModeOpen];
  }
  p.delegate = self;
  p.allowsMultipleSelection = NO;
  [self presentViewController:p animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* u = urls.firstObject;
  if (!u) return;
  BOOL scoped = [u startAccessingSecurityScopedResource];
  [self importPath:u.path done:^{
    if (scoped) [u stopAccessingSecurityScopedResource];
  }];
}

- (void)onLocal {
  [self checkTamper];
  if (self.busy || !self.localZip) return;
  [self importPath:self.localZip done:nil];
}

static uint64_t freeBytes() {
  NSURL* u = [NSURL fileURLWithPath:gSupport];
  NSNumber* n = nil;
  if (@available(iOS 11.0, *)) [u getResourceValue:&n forKey:NSURLVolumeAvailableCapacityForImportantUsageKey error:nil];
  if (!n) {
    NSDictionary* a = [NSFileManager.defaultManager attributesOfFileSystemForPath:gSupport error:nil];
    n = a[NSFileSystemFreeSize];
  }
  return n.unsignedLongLongValue;
}

- (void)importPath:(NSString*)path done:(void (^)(void))done {
  [self checkTamper];
  self.busy = YES;
  self.pick.enabled = NO;
  self.local.enabled = NO;
  self.bar.hidden = NO;
  self.bar.progress = 0;
  self.status.text = @"Đang kiểm tra gói data…";
  UIApplication.sharedApplication.idleTimerDisabled = YES;
  std::string zip = path.fileSystemRepresentation;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    __block UIBackgroundTaskIdentifier bg = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
      [UIApplication.sharedApplication endBackgroundTask:bg];
    }];
    std::string err;
    zd::Manifest m;
    NSString* ver = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"];
    NSString* build = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"];
    bool ok = zd::inspectPack(zip, m, err) && zd::checkCompatible(m, ver.UTF8String ?: "", build.UTF8String ?: "", ZIRU_MOD_VERSION, err);
    if (ok) {
      CFAbsoluteTime last = 0;
      ok = zd::installPack(zip, layout(), freeBytes(), [&](const zd::Progress& p) {
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (now - last < 0.2 && p.phase == "extract") return true;
        last = now;
        float f = p.total ? (float)((double)p.done / (double)p.total) : 0;
        NSString* phase = p.phase == "extract" ? @"Đang giải nén và kiểm tra SHA-256" : p.phase == "activate" ? @"Đang kích hoạt" : @"Đang kiểm tra";
        NSString* txt = [NSString stringWithFormat:@"%@\n%s\n%.0f / %.0f MB", phase, p.file.c_str(), p.done / 1048576.0, p.total / 1048576.0];
        dispatch_async(dispatch_get_main_queue(), ^{
          self.bar.progress = f;
          self.status.text = txt;
        });
        return true;
      }, m, err);
    }
    NSString* msg = [NSString stringWithUTF8String:err.c_str()];
    ZLog(@"import %s: %@ (data_id=%s)", ok ? "OK" : "FAILED", msg, m.dataId.c_str());
    dispatch_async(dispatch_get_main_queue(), ^{
      if (done) done();
      UIApplication.sharedApplication.idleTimerDisabled = NO;
      [UIApplication.sharedApplication endBackgroundTask:bg];
      self.busy = NO;
      self.pick.enabled = YES;
      self.local.enabled = YES;
      if (ok) {
        self.status.text = @"Đã nhập xong dữ liệu. Đang vào game…";
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Hoàn tất"
                                                                   message:@"Dữ liệu đã nhập thành công. Có thể xóa file .zip gốc để giải phóng dung lượng."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"Vào game" style:UIAlertActionStyleDefault handler:^(UIAlertAction*) { startGame(); }]];
        [self presentViewController:a animated:YES completion:nil];
      } else {
        self.bar.hidden = YES;
        UIAlertController* a = [UIAlertController alertControllerWithTitle:@"Nhập dữ liệu thất bại" message:msg preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        [self refresh];
      }
    });
  });
}
@end

static UIWindow* getAppWindow(id appDelegate) {
  UIWindow* win = nil;
  if ([appDelegate respondsToSelector:@selector(window)]) {
    win = [(id)appDelegate window];
    if (win) return win;
  }
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class] && scene.activationState == UISceneActivationStateForegroundActive) {
      UIWindowScene* ws = (UIWindowScene*)scene;
      for (UIWindow* w in ws.windows) {
        if (w.isKeyWindow) return w;
      }
      if (ws.windows.count > 0) return ws.windows.firstObject;
    }
  }
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes) {
    if ([scene isKindOfClass:UIWindowScene.class]) {
      UIWindowScene* ws = (UIWindowScene*)scene;
      if (ws.windows.count > 0) return ws.windows.firstObject;
    }
  }
  if (UIApplication.sharedApplication.keyWindow) return UIApplication.sharedApplication.keyWindow;
  if (UIApplication.sharedApplication.windows.count > 0) return UIApplication.sharedApplication.windows.firstObject;
  return nil;
}

static __strong ZiruImportVC* gActiveImportVC = nil;

static void showImporter(UIWindow* win, NSString* reason) {
  if (gActiveImportVC || gGameStarted) return;
  ZLog(@"Showing importer UI on window, reason: %@", reason);
  ZiruImportVC* vc = [ZiruImportVC new];
  UIViewController* root = win.rootViewController;
  if (root) {
    [root addChildViewController:vc];
    vc.view.frame = root.view.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [root.view addSubview:vc.view];
    [root.view bringSubviewToFront:vc.view];
    [vc didMoveToParentViewController:root];
  } else {
    vc.view.frame = win.bounds;
    vc.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [win addSubview:vc.view];
    [win bringSubviewToFront:vc.view];
  }
  gActiveImportVC = vc;
}

static void startGame() {
  if (gGameStarted.exchange(true)) return;
  ZLog(@"Game starting, dismissing importer");
  dispatch_async(dispatch_get_main_queue(), ^{
    if (gActiveImportVC) {
      [UIView animateWithDuration:0.3 animations:^{
        gActiveImportVC.view.alpha = 0;
      } completion:^(BOOL finished) {
        [gActiveImportVC willMoveToParentViewController:nil];
        [gActiveImportVC.view removeFromSuperview];
        [gActiveImportVC removeFromParentViewController];
        gActiveImportVC = nil;
      }];
    }
  });
}

#include "ZiruMods.inc"
#include "ZiruJersey.inc"
#include "EfootxiBootstrap.inc"
#include "EfootxiPanel.inc"

static BOOL hookDidFinish(id self, SEL _cmd, UIApplication* app, NSDictionary* opts) {
  gDelegate = self;
  gLaunchApp = app;
  gLaunchOptions = opts;
#ifdef EFOOTXI_IOS
  {
    BackendIOScope backendIO;
    activatePendingNativeBase(gDocs, gSessionDir);
  }
  // Khoi dong server Python ngam ngay lap tuc, khong chan chu ky khoi tao giao dien cua UE4
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    efootxiPrepareResources();
    gEfootxiPrepared = true;
  });
#endif

  // Complete mod batches are activated before Unreal opens any containers.
  std::string modSummary, modError;
  bool modsOK = false;
  try {
    modsOK = zm::activatePending([gSupport stringByAppendingPathComponent:@"PendingMods"].fileSystemRepresentation,
        gDocs.fileSystemRepresentation, modSummary, modError);
  } catch (const std::exception& e) { modError = e.what(); }
  ZLog(@"[MOD] %s %s", modSummary.c_str(), modError.c_str());

  // Let UE4 initialize its window and Metal graphics first!
  BOOL res = ((BOOL(*)(id, SEL, id, id))gOrigDidFinish)(self, _cmd, app, opts);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    // installModButton(getAppWindow(self));
    if (!modsOK) showModError(getAppWindow(self), [NSString stringWithUTF8String:modError.c_str()]);
#ifdef EFOOTXI_IOS
    efootxiInstallPanelButton();
#endif
  });

  // Check if direct data exists
  NSString* why = nil;
  if (dataReady(&why)) {
    ZLog(@"Data ready, launching game directly");
    gGameStarted = true;
    return res;
  }

  // If data is NOT ready, present importer UI!
  ZLog(@"Data not ready: %@ — scheduling importer UI", why);
  void (^tryShow)(void) = ^{
    if (gGameStarted || gActiveImportVC) return;
    UIWindow* win = getAppWindow(self);
    if (win) {
      showImporter(win, why);
    }
  };
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), tryShow);

  return res;
}

static void hookBecomeActive(id self, SEL _cmd, UIApplication* app) {
  diagnosticEvent(@"lifecycle.jsonl", @{@"event":@"hookBecomeActive"});

  if (gOrigBecomeActive) ((void (*)(id, SEL, id))gOrigBecomeActive)(self, _cmd, app);
  if (!gGameStarted && !gActiveImportVC) {
    NSString* why = nil;
    if (!dataReady(&why)) {
      UIWindow* win = getAppWindow(self);
      if (win) showImporter(win, why);
    }
  }
}
static void hookResignActive(id self, SEL _cmd, UIApplication* app) {
  diagnosticEvent(@"lifecycle.jsonl", @{@"event":@"hookResignActive"});

  if (gOrigResignActive) ((void (*)(id, SEL, id))gOrigResignActive)(self, _cmd, app);
}
static void hookEnterBg(id self, SEL _cmd, UIApplication* app) {
  diagnosticEvent(@"lifecycle.jsonl", @{@"event":@"hookEnterBg"});

  if (gOrigEnterBg) ((void (*)(id, SEL, id))gOrigEnterBg)(self, _cmd, app);
}
static void hookEnterFg(id self, SEL _cmd, UIApplication* app) {
  diagnosticEvent(@"lifecycle.jsonl", @{@"event":@"hookEnterFg"});

  if (gOrigEnterFg) ((void (*)(id, SEL, id))gOrigEnterFg)(self, _cmd, app);
}

// ---------------------------------------------------------------- entry
__attribute__((constructor)) static void ziruInit() {
  @autoreleasepool {
    initPaths();
    initSessionDiagnostics();
    initCrashHandler();
    zjersey::install();
    zfont::install([gBundleAssets stringByAppendingPathComponent:@"fonts"].fileSystemRepresentation,
                   gDocs.fileSystemRepresentation, [](const char* line) { ZLog(@"%s", line); });
    zweb::install([](const char* line) { ZLog(@"%s", line); });
    loadOnlineConfig();
    // checkDirectFolderData is called safely from dataReady() inside hookDidFinish to avoid dyld constructor crashes.
    ZLog(@"ZiruOffline %s loaded, bundle=%@", ZIRU_MOD_VERSION, NSBundle.mainBundle.bundlePath);

    // Initialize original function pointers via dlsym
    orig_unlink = (int (*)(const char*))dlsym(RTLD_DEFAULT, "unlink");
    orig_unlinkat = (int (*)(int, const char*, int))dlsym(RTLD_DEFAULT, "unlinkat");
    orig_remove = (int (*)(const char*))dlsym(RTLD_DEFAULT, "remove");
    orig_open = (int (*)(const char*, int, ...))dlsym(RTLD_DEFAULT, "open");
    orig_stat = (int (*)(const char*, struct stat*))dlsym(RTLD_DEFAULT, "stat");
    orig_access = (int (*)(const char*, int))dlsym(RTLD_DEFAULT, "access");
    orig_fopen = (FILE* (*)(const char*, const char*))dlsym(RTLD_DEFAULT, "fopen");
    orig_opendir = (DIR* (*)(const char*))dlsym(RTLD_DEFAULT, "opendir");
    orig_exit = (void (*)(int))dlsym(RTLD_DEFAULT, "exit");
    orig__exit = (void (*)(int))dlsym(RTLD_DEFAULT, "_exit");
    orig_abort = (void (*)(void))dlsym(RTLD_DEFAULT, "abort");

    // Register commentary protection & pak/cpk file redirection hooks via fishhook
    struct z_rebinding rebindings[] = {
      {"unlink", (void*)hook_unlink, (void**)&orig_unlink},
      {"unlinkat", (void*)hook_unlinkat, (void**)&orig_unlinkat},
      {"remove", (void*)hook_remove, (void**)&orig_remove},
      {"open", (void*)hook_open, (void**)&orig_open},
      {"stat", (void*)hook_stat, (void**)&orig_stat},
      {"access", (void*)hook_access, (void**)&orig_access},
      {"fopen", (void*)hook_fopen, (void**)&orig_fopen},
      {"opendir", (void*)hook_opendir, (void**)&orig_opendir},
      {"exit", (void*)hook_exit, (void**)&orig_exit},
      {"_exit", (void*)hook__exit, (void**)&orig__exit},
      {"abort", (void*)hook_abort, (void**)&orig_abort},
    };
    z_rebind_symbols(rebindings, sizeof(rebindings) / sizeof(rebindings[0]));
#ifdef PES_NO_PUBLIC
    pnpInstallStun();
#endif

    // Swizzle NSFileManager for commentary protection
    Class fmCls = NSFileManager.class;
    gOrigFmRemovePath = swizzleInstance(fmCls, @selector(removeItemAtPath:error:), (IMP)hookFmRemovePath);
    gOrigFmRemoveURL = swizzleInstance(fmCls, @selector(removeItemAtURL:error:), (IMP)hookFmRemoveURL);

    // Network protocol
    [NSURLProtocol registerClass:ZiruURLProtocol.class];
    Class cfg = NSURLSessionConfiguration.class;
    gOrigDefaultCfg = swizzleClassMethod(cfg, @selector(defaultSessionConfiguration), (IMP)hookDefaultCfg);
    gOrigBackgroundCfg = swizzleClassMethod(cfg, @selector(backgroundSessionConfigurationWithIdentifier:), (IMP)hookBackgroundCfg);
    gOrigEphemeralCfg = swizzleClassMethod(cfg, @selector(ephemeralSessionConfiguration), (IMP)hookEphemeralCfg);
    SEL sr = NSSelectorFromString(@"setRequest:cookie:isPost:sendData:sendDataSize:useGzip:");
    const char* names[3] = {"HttpImplAsyncRequest", "HttpImplRequest", "HttpImpl2Request"};
    IMP hooks[3] = {(IMP)hookSetRequest<0>, (IMP)hookSetRequest<1>, (IMP)hookSetRequest<2>};
    for (int i = 0; i < 3; i++) {
      Class c = objc_getClass(names[i]);
      if (c) gOrigSetReq[i] = (SetReqFn)swizzleInstance(c, sr, hooks[i]);
      ZLog(@"hook %s: %s", names[i], gOrigSetReq[i] ? "ok" : "MISSING");
    }
    Class d = objc_getClass("IOSAppDelegate");
    if (d) {
      gOrigDidFinish = swizzleInstance(d, @selector(application:didFinishLaunchingWithOptions:), (IMP)hookDidFinish);
      gOrigBecomeActive = swizzleInstance(d, @selector(applicationDidBecomeActive:), (IMP)hookBecomeActive);
      gOrigResignActive = swizzleInstance(d, @selector(applicationWillResignActive:), (IMP)hookResignActive);
      gOrigEnterBg = swizzleInstance(d, @selector(applicationDidEnterBackground:), (IMP)hookEnterBg);
      gOrigEnterFg = swizzleInstance(d, @selector(applicationWillEnterForeground:), (IMP)hookEnterFg);
    } else {
      ZLog(@"IOSAppDelegate not found — launch gating disabled");
      gGameStarted = true;
    }

    // 120 FPS Unlock via CADisplayLink & Dynamic Max FPS
    Class dlCls = CADisplayLink.class;
    if (dlCls) {
      gOrigDisplayLinkWithTarget = swizzleClassMethod(dlCls, @selector(displayLinkWithTarget:selector:), (IMP)hookDisplayLinkWithTarget);
      gOrigSetPreferredFramesPerSecond = swizzleInstance(dlCls, @selector(setPreferredFramesPerSecond:), (IMP)hookSetPreferredFramesPerSecond);
      if (@available(iOS 15.0, *)) {
        gOrigSetPreferredFrameRateRange = swizzleInstance(dlCls, @selector(setPreferredFrameRateRange:), (IMP)hookSetPreferredFrameRateRange);
      }
      ZLog(@"[120FPS] CADisplayLink 120 FPS hooks installed");
    }
    enableDynamicMaxFps();
    setupGraphicsEnhancements();
    startFpsMeter();
  }
}
