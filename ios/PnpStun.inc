// PES - No Public (PRIVATE build only, compiled with -DPES_NO_PUBLIC): send the game's STUN checks to Long's own
// STUN/TURN server instead of Konami. Same idea as liboffline_lan.so in the "Friendly Match - Same WiFi" APK:
//   *.stun.service.konami.net  -> resolves to the marker 127.0.0.2 (IPv6 lookups fail, so the game uses IPv4)
//   UDP sent to 127.0.0.2:any  -> goes to stun_host:stun_port from efootxi/online.json
//   STUN replies from there    -> handed back to the game as if from 127.0.0.2:<the port it used>
// Replies are matched by STUN transaction id, so TURN traffic the game sends to the same server is untouched.
// Included from ZiruOffline.mm after the fishhook section; plain POSIX so it is unit-tested on Linux.
#include <arpa/inet.h>
#include <netdb.h>
#include <netinet/in.h>
#include <pthread.h>
#include <string.h>
#include <strings.h>
#include <sys/socket.h>

namespace pnpstun {
static int (*real_gai)(const char*, const char*, const struct addrinfo*, struct addrinfo**) = getaddrinfo;
static struct hostent* (*real_ghn)(const char*) = gethostbyname;
static ssize_t (*real_sendto)(int, const void*, size_t, int, const struct sockaddr*, socklen_t) = sendto;
static ssize_t (*real_recvfrom)(int, void*, size_t, int, struct sockaddr*, socklen_t*) = recvfrom;

static struct sockaddr_in gStun;
static volatile bool gOn = false;
static const char kSuffix[] = ".stun.service.konami.net";
static const char kMarker[] = "127.0.0.2";
static const uint32_t kMarkerHost = 0x7f000002u;

struct Slot { int fd; uint16_t port; uint8_t txid[12]; bool used; };
static Slot gSlots[64];
static unsigned gCursor = 0;
static pthread_mutex_t gLock = PTHREAD_MUTEX_INITIALIZER;
static unsigned gRedirected = 0, gAnswered = 0;

static bool stunHost(const char* name) {
  if (!name) return false;
  size_t n = strlen(name), s = sizeof(kSuffix) - 1;
  return n > s && strcasecmp(name + n - s, kSuffix) == 0;
}

static int hook_gai(const char* node, const char* service, const struct addrinfo* hints, struct addrinfo** res) {
  if (gOn && stunHost(node)) {
    if (hints && hints->ai_family == AF_INET6) return EAI_NONAME;
    return real_gai(kMarker, service, hints, res);
  }
  return real_gai(node, service, hints, res);
}

static struct hostent* hook_ghn(const char* name) {
  return real_ghn(gOn && stunHost(name) ? kMarker : name);
}

static bool toMarker(const struct sockaddr* to, socklen_t len) {
  return to && len >= (socklen_t)sizeof(sockaddr_in) && to->sa_family == AF_INET &&
         ((const sockaddr_in*)to)->sin_addr.s_addr == htonl(kMarkerHost);
}

static ssize_t hook_sendto(int fd, const void* buf, size_t len, int flags, const struct sockaddr* to, socklen_t tolen) {
  if (!gOn || !toMarker(to, tolen)) return real_sendto(fd, buf, len, flags, to, tolen);
  const uint8_t* b = (const uint8_t*)buf;
  if (len >= 20 && (b[0] & 0xc0) == 0) {          // STUN message: remember who asked, by transaction id
    pthread_mutex_lock(&gLock);
    Slot& s = gSlots[gCursor++ % 64];
    s.fd = fd; s.port = ((const sockaddr_in*)to)->sin_port; memcpy(s.txid, b + 8, 12); s.used = true;
    gRedirected++;
    pthread_mutex_unlock(&gLock);
  }
  return real_sendto(fd, buf, len, flags, (const struct sockaddr*)&gStun, sizeof gStun);
}

static ssize_t hook_recvfrom(int fd, void* buf, size_t cap, int flags, struct sockaddr* from, socklen_t* fromlen) {
  ssize_t n = real_recvfrom(fd, buf, cap, flags, from, fromlen);
  if (!gOn || n < 20 || !from || !fromlen || *fromlen < (socklen_t)sizeof(sockaddr_in) || from->sa_family != AF_INET) return n;
  sockaddr_in* a = (sockaddr_in*)from;
  if (a->sin_addr.s_addr != gStun.sin_addr.s_addr || a->sin_port != gStun.sin_port) return n;
  const uint8_t* b = (const uint8_t*)buf;
  pthread_mutex_lock(&gLock);
  for (Slot& s : gSlots) {
    if (s.used && s.fd == fd && memcmp(s.txid, b + 8, 12) == 0) {
      a->sin_addr.s_addr = htonl(kMarkerHost); a->sin_port = s.port; s.used = false; gAnswered++;
      break;
    }
  }
  pthread_mutex_unlock(&gLock);
  return n;
}

// host must be an IPv4 literal (the AWS public IP). Returns false (and changes nothing) otherwise.
static bool configure(const char* host, int port) {
  memset(&gStun, 0, sizeof gStun);
  gStun.sin_family = AF_INET;
  gStun.sin_port = htons((uint16_t)(port > 0 && port < 65536 ? port : 3478));
  if (!host || inet_pton(AF_INET, host, &gStun.sin_addr) != 1) return false;
  gOn = true;
  return true;
}
}  // namespace pnpstun
