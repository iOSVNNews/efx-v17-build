// Native name-atlas fallback, PESmobile 11.1.101 only. These data vtable slots
// are validated before writing; no executable page is modified at runtime.
#include "ZiruPlayerIdentity.hpp"
namespace zjersey {
using LoadFn = void (*)(void*);
using ReadyFn = bool (*)(void*);
using DrawFn = void (*)(void*, void*);
struct NativeString { char16_t* data; int32_t num; int32_t max; };
using AssetFn = void (*)(void*, NativeString*, bool);
using SetUniformNumberFn = void (*)(void* actor, int uniformNumber);
using SetupFromPlayerIdFn = void (*)(void* actor, int64_t playerId, void* path, int uniformNumber, uint64_t uniName);
using BackNumberStepFn = void (*)(void* actor);
using ReloadFaceFn = void (*)(void* actor);

static LoadFn originalLoad;
static ReadyFn originalReady;
static DrawFn originalDraw;
static AssetFn originalAsset;
static SetUniformNumberFn originalSetUniformNumber;
static SetupFromPlayerIdFn originalSetupFromPlayerId;
static BackNumberStepFn originalBackNumberStep;
static ReloadFaceFn originalReloadFace;

static std::mutex mutex;
static std::set<void*> retried, recorded;
static int logBudget = 96;
static intptr_t gSlide = 0;

static NSString* nameText(void* actor) {
  const uint8_t* s = (const uint8_t*)actor + 0x278;
  bool heap = (int8_t)s[23] < 0;
  uint64_t length = heap ? ((const uint64_t*)s)[1] : s[23];
  const char* text = heap ? *(const char**)s : (const char*)s;
  if (!text || length > 120) return @"<invalid>";
  return [[NSString alloc] initWithBytes:text length:(NSUInteger)length encoding:NSUTF8StringEncoding] ?: @"<invalid UTF-8>";
}
static NSString* assetText(void* actor) {
  auto s = (NativeString*)((uint8_t*)actor + 0x2c0);
  if (!s->data || s->num < 2 || s->num > 512) return @"<empty>";
  return [[NSString alloc] initWithCharacters:(const unichar*)s->data length:s->num - 1];
}
static void load(void* actor) {
  {
    std::lock_guard<std::mutex> guard(mutex);
    retried.erase(actor); recorded.erase(actor);
    if (logBudget > 0) {
      --logBudget;
      ZLog(@"[JERSEY] request name='%@' atlas=%@ scale=%.4f", nameText(actor), assetText(actor), *(float*)((uint8_t*)actor + 0x298));
    }
  }
  originalLoad(actor);
}
static bool ready(void* actor) {
  if (actor) *(uint8_t*)((uint8_t*)actor + 0x290) = 0;
  if (!originalReady(actor)) return false;
  auto p = (uint8_t*)actor;
  // A completed async load with a null primary atlas produces a blank canvas.
  // Retry once with the stock iOS atlas verified in pc0103's directory index.
  // Existing and custom successfully loaded atlases always remain in use.
  bool retry = false;
  if (!*(void**)(p + 0x2b0) && nameText(actor).length > 0) {
    std::lock_guard<std::mutex> guard(mutex);
    if (retried.insert(actor).second) retry = true;
  }
  if (retry) {
    ZLog(@"[JERSEY] missing atlas %@; retry stock iOS name atlas", assetText(actor));
    static char16_t fallback[] = u"T_EditUni_FontName_00_D";
    NativeString s{fallback, (int32_t)(sizeof(fallback) / sizeof(fallback[0])), (int32_t)(sizeof(fallback) / sizeof(fallback[0]))};
    originalAsset(actor, &s, true);
    originalLoad(actor);
    return false;
  }
  return true;
}
static void draw(void* actor, void* canvas) {
  {
    std::lock_guard<std::mutex> guard(mutex);
    if (recorded.insert(actor).second && logBudget > 0) {
      --logBudget;
      ZLog(@"[JERSEY] draw name='%@' atlas=%@ texture=%p scale=%.4f", nameText(actor), assetText(actor),
          *(void**)((uint8_t*)actor + 0x2b0), *(float*)((uint8_t*)actor + 0x298));
    }
  }
  if (actor) *(uint8_t*)((uint8_t*)actor + 0x290) = 0;
  originalDraw(actor, canvas);
}

extern "C" int32_t gZiruHomeTeamId;
extern "C" int32_t gZiruAwayTeamId;

static std::string sanitizeShirtName(const char* s) {
  if (!s || !s[0]) return "";
  std::string raw;
  raw.reserve(32);
  for (size_t i = 0; s[i] != '\0' && raw.size() < 30; ++i) {
    unsigned char c = (unsigned char)s[i];
    if (c >= 'a' && c <= 'z') {
      raw += (char)(c - 'a' + 'A');
    } else if ((c >= 'A' && c <= 'Z') || c == ' ' || c == '.' || c == '-' || c == 0x27) {
      raw += (char)c;
    } else if (c == 0xC3 && s[i + 1] != '\0') {
      unsigned char c2 = (unsigned char)s[++i];
      if ((c2 >= 0x80 && c2 <= 0x85) || (c2 >= 0xA0 && c2 <= 0xA5)) raw += 'A';
      else if (c2 == 0x86 || c2 == 0xA6) { raw += 'A'; raw += 'E'; }
      else if (c2 == 0x87 || c2 == 0xA7) raw += 'C';
      else if ((c2 >= 0x88 && c2 <= 0x8B) || (c2 >= 0xA8 && c2 <= 0xAB)) raw += 'E';
      else if ((c2 >= 0x8C && c2 <= 0x8F) || (c2 >= 0xAC && c2 <= 0xAF)) raw += 'I';
      else if (c2 == 0x90 || c2 == 0xB0) raw += 'D';
      else if (c2 == 0x91 || c2 == 0xB1) raw += 'N';
      else if ((c2 >= 0x92 && c2 <= 0x96) || c2 == 0x98 || (c2 >= 0xB2 && c2 <= 0xB6) || c2 == 0xB8) raw += 'O';
      else if ((c2 >= 0x99 && c2 <= 0x9C) || (c2 >= 0xB9 && c2 <= 0xBC)) raw += 'U';
      else if (c2 == 0x9D || c2 == 0xBD || c2 == 0xBF) raw += 'Y';
      else if (c2 == 0x9F) { raw += 'S'; raw += 'S'; }
    } else if (c == 0xC4 && s[i + 1] != '\0') {
      unsigned char c2 = (unsigned char)s[++i];
      if (c2 >= 0x80 && c2 <= 0x85) raw += 'A';
      else if (c2 >= 0x86 && c2 <= 0x8D) raw += 'C';
      else if (c2 >= 0x8E && c2 <= 0x91) raw += 'D';
      else if (c2 >= 0x92 && c2 <= 0x9B) raw += 'E';
      else if (c2 >= 0x9C && c2 <= 0x9F) raw += 'G';
      else if (c2 >= 0xA8 && c2 <= 0xB1) raw += 'I';
    } else if (c == 0xC5 && s[i + 1] != '\0') {
      unsigned char c2 = (unsigned char)s[++i];
      if (c2 >= 0x81 && c2 <= 0x84) raw += 'L';
      else if (c2 >= 0x83 && c2 <= 0x8B) raw += 'N';
      else if (c2 >= 0x8C && c2 <= 0x91) raw += 'O';
      else if (c2 >= 0x94 && c2 <= 0x99) raw += 'R';
      else if ((c2 >= 0x9A && c2 <= 0x9F) || (c2 >= 0xA0 && c2 <= 0xA3)) raw += 'S';
      else if (c2 >= 0xA4 && c2 <= 0xA7) raw += 'T';
      else if (c2 >= 0xAA && c2 <= 0xB3) raw += 'U';
      else if (c2 >= 0xBD && c2 <= 0xC2) raw += 'Z';
    }
  }
  while (!raw.empty() && raw.front() == ' ') raw.erase(raw.begin());
  while (!raw.empty() && raw.back() == ' ') raw.pop_back();
  if (raw.empty() || raw.size() > 30) return "";
  return raw;
}

static std::string fallbackPlayerName(uint32_t baseId) {
  static const std::unordered_map<uint32_t, const char*> sMap = {
    {133580, "HAALAND"}, {7511, "MESSI"}, {4522, "C. RONALDO"}, {40352, "NEYMAR JR"},
    {110718, "MBAPPE"}, {44379, "DE BRUYNE"}, {138036, "BELLINGHAM"}, {117047, "VINI JR."},
    {109005, "RODRI"}, {45260, "SALAH"}, {40571, "LEWANDOWSKI"}, {47287, "KANE"},
    {45023, "SON"}, {32664, "MODRIC"}, {36770, "KROOS"}, {33702, "BENZEMA"},
    {36769, "SUAREZ"}, {42641, "GRIEZMANN"}, {131976, "SAKA"}, {118007, "FODEN"},
    {141673, "MUSIALA"}, {138384, "PEDRI"}, {145952, "GAVI"}, {167375, "LAMINE YAMAL"},
    {42668, "COURTOIS"}, {60512, "ALISSON"}, {103380, "EDERSON"}, {33145, "NEUER"},
    {45843, "VAN DIJK"}, {113351, "RUBEN"}, {126955, "SALIBA"}, {118073, "DAVIES"},
    {111451, "A. ARNOLD"}, {41103, "WALKER"}, {109265, "KIMMICH"}, {118485, "RICE"},
    {133465, "CAMAVINGA"}, {113408, "VALVERDE"}, {101057, "BERNARDO"}, {60587, "BRUNO F."},
    {110638, "RASHFORD"}, {118334, "LAUTARO"}, {117765, "OSIMHEN"}, {126280, "LEAO"},
    {140321, "KVARATSKHELIA"}, {109867, "BARELLA"}, {118047, "BASTONI"}, {113405, "T. HERNANDEZ"},
    {103445, "DIMARCO"}, {47000, "DYBALA"}, {44378, "MORATA"}, {120281, "ENZO"},
    {134907, "MAC ALLISTER"}, {127179, "JULIAN ALVAREZ"}, {108919, "R. DIAS"}, {100780, "CASEMIRO"},
    {100688, "MARQUINHOS"}, {46845, "GABRIEL JESUS"}, {45129, "DE GEA"}, {41571, "TER STEGEN"},
    {100236, "ODEGAARD"}, {114878, "GABRIEL"}, {4073, "INIESTA"}, {1082, "XAVI"},
    {2439, "PUYOL"}, {133543, "ZION SUZUKI"}, {134639, "CANNAVARO"}, {35496, "MERTESACKER"},
    {134594, "BONUCCI"}, {134632, "SUPHANAN"}, {137955, "JUN"}, {129961, "TOMIYASU"},
    {44840, "JORGINHO"}, {30210, "PARTEY"}, {137957, "TROSSARD"}, {110815, "HAVERTZ"},
    {107686, "MARTINELLI"}, {124266, "ZINCHENKO"}, {132933, "RAYA"}, {983, "BECKHAM"},
    {33185, "PIRLO"}, {134670, "MALDINI"}, {134701, "NEDVED"}, {34691, "NEDVED"},
    {45735, "MANE"}, {126343, "RODRYGO"}, {3214, "RONALDINHO"}, {15676, "KAKA"},
    {3000, "ZIDANE"}, {41066, "R. CARLOS"}, {3279, "CASILLAS"}, {3843, "BUFFON"},
    {3234, "SHEVCHENKO"}, {3334, "FIGO"}, {15886, "GULLIT"}, {16369, "VAN BASTEN"},
    {16368, "RIJKAARD"}, {136270, "WIRTZ"}, {133668, "PALMER"}, {143093, "MAINOO"},
    {105809, "CALHANOGLU"}, {101097, "CALHANOGLU"}, {42647, "LUKAKU"},
    {42669, "CASEMIRO"}, {40871, "ERIKSEN"}, {42659, "ERIKSEN"},
    {39936, "MKHITARYAN"}, {43026, "MKHITARYAN"},
    {133215, "ANSU FATI"}, {135760, "ANSU FATI"}
  };
  auto it = sMap.find(baseId);
  return (it != sMap.end()) ? it->second : "";
}

static std::string toUpperAscii(const std::string& s) {
  std::string r;
  r.reserve(s.size());
  for (char c : s) {
    if (c >= 'a' && c <= 'z') r += (char)(c - 'a' + 'A');
    else r += c;
  }
  return r;
}

static std::string formatPlayerShirtName(const std::string& input) {
  if (input.empty()) return "";
  std::string out;
  out.reserve(input.size());
  bool capitalizeNext = true;
  for (size_t i = 0; i < input.size(); ++i) {
    unsigned char c = (unsigned char)input[i];
    if (c == ' ' || c == '.' || c == '-' || c == 0x27) {
      out += (char)c;
      capitalizeNext = true;
    } else if (capitalizeNext) {
      if (c >= 'a' && c <= 'z') out += (char)(c - 'a' + 'A');
      else out += (char)c;
      capitalizeNext = false;
    } else {
      if (c >= 'A' && c <= 'Z') out += (char)(c - 'A' + 'a');
      else out += (char)c;
    }
  }
  return out;
}

static void applyLegendRealFace(void* actor, int64_t pid, const std::string& shirtName) {
  if (!actor) return;
  const std::string upper = toUpperAscii(shirtName);
  const uint32_t faceId = zidentity::legendFace(pid, upper);
  const char16_t* face = nullptr;
  int32_t length = 0;
  if (faceId == 9901397) {
    face = u"9901397"; length = 8;
  } else if (faceId == 37576) {
    face = u"37576"; length = 6;
  }
  if (!face) return;
  auto current = (NativeString*)((uint8_t*)actor + 0x468);
  if (current->data && current->num == length &&
      memcmp(current->data, face, (size_t)length * sizeof(char16_t)) == 0) return;
  // FString::operator= copies using the engine allocator. Never store a static
  // buffer in an owning FString: ReloadFace/destruction can free that buffer.
  NativeString borrowed{const_cast<char16_t*>(face), length, length};
  auto assign = (void* (*)(void*, const NativeString*))(0x102e14b64 + gSlide);
  assign(current, &borrowed);
  ZLog(@"[JERSEY] Set legend face asset name for pid=%lld; asset load still needs verification", (long long)pid);
}

static std::mutex sActorLock;
static std::unordered_map<void*, int64_t> sActorPlayerId;

static int resolveActorSide(void* actor, uint8_t* match) {
  if (!actor || !match) return -1;
  int64_t pid = 0;
  {
    std::lock_guard<std::mutex> lk(sActorLock);
    auto it = sActorPlayerId.find(actor);
    if (it != sActorPlayerId.end()) pid = it->second;
  }
  if (pid <= 0) return -1;
  int found = -1;
  for (int side = 0; side < 2; ++side) {
    uint8_t* players = match + 0x14e0 + side * 0x5dc0;
    for (int i = 0; i < 40; ++i) {
      uint64_t candidate = *(uint64_t*)(players + i * 0x258 + 0x38);
      if (candidate == (uint64_t)pid || (candidate & 0xFFFFFF) == ((uint64_t)pid & 0xFFFFFF)) {
        if (found >= 0 && found != side) return -1;
        found = side;
      }
    }
  }
  return found;
}

static std::string lookupShirtName(void* actor, int uniformNumber) {
  if (uniformNumber <= 0 || uniformNumber > 99) return "";

  auto getMgr = (void* (*)())(0x104bba084 + gSlide);
  void* mgr = getMgr ? getMgr() : nullptr;
  if (!mgr) return "";

  uint8_t* base = *(uint8_t**)((uint8_t*)mgr + 0x48);
  if (!base) return "";

  uint8_t* match = base + 0x6c4c0;

  int preferredSide = resolveActorSide(actor, match);

  auto checkSide = [&](int side) -> std::string {
    if (side < 0 || side > 1) return "";
    uint8_t* teamPlayers = match + 0x14e0 + (side * 0x5dc0);
    uint8_t* teamObj = match + 0x620 + (side * 0x5d8);
    uint16_t* uniformNums = (uint16_t*)(teamObj + 0x110);

    // Pass 1: Starters (0..10)
    for (int i = 0; i < 11; ++i) {
      uint8_t* p = teamPlayers + (i * 0x258);
      uint16_t num1 = *(uint16_t*)(p + 0x1ec);
      uint16_t num2 = *(uint16_t*)(p + 0x1b4);
      uint16_t num3 = uniformNums[i];
      if (num1 == (uint16_t)uniformNumber || num2 == (uint16_t)uniformNumber || num3 == (uint16_t)uniformNumber) {
        uint32_t baseId = *(uint32_t*)(p + 0x38);
        const char* rawName = (const char*)(p + 0xc6);
        if (!rawName || !rawName[0]) rawName = (const char*)(p + 0x89);
        std::string name = sanitizeShirtName(rawName);
        if (name.empty()) name = sanitizeShirtName((const char*)(p + 0x103));
        if (name.empty() && baseId > 0) name = fallbackPlayerName(baseId & 0xFFFFFF);
        if (!name.empty()) return name;
      }
    }

    // Pass 2: Bench (11..39)
    for (int i = 11; i < 40; ++i) {
      uint8_t* p = teamPlayers + (i * 0x258);
      uint16_t num1 = *(uint16_t*)(p + 0x1ec);
      uint16_t num2 = *(uint16_t*)(p + 0x1b4);
      uint16_t num3 = uniformNums[i];
      if (num1 == (uint16_t)uniformNumber || num2 == (uint16_t)uniformNumber || num3 == (uint16_t)uniformNumber) {
        uint32_t baseId = *(uint32_t*)(p + 0x38);
        const char* rawName = (const char*)(p + 0xc6);
        if (!rawName || !rawName[0]) rawName = (const char*)(p + 0x89);
        std::string name = sanitizeShirtName(rawName);
        if (name.empty()) name = sanitizeShirtName((const char*)(p + 0x103));
        if (name.empty() && baseId > 0) name = fallbackPlayerName(baseId & 0xFFFFFF);
        if (!name.empty()) return name;
      }
    }
    return "";
  };

  if (preferredSide >= 0) {
    return checkSide(preferredSide);
  }
  std::string res0 = checkSide(0);
  std::string res1 = checkSide(1);
  if (!res0.empty() && res1.empty()) return res0;
  if (!res1.empty() && res0.empty()) return res1;
  if (res0 == res1) return res0;
  return ""; // Same shirt number on both teams is not a player identity.
}

static std::string lookupShirtNameByPlayerId(void* actor, int64_t playerId) {
  if (playerId <= 0) return "";
  uint32_t targetBaseId = (uint32_t)(playerId & 0xFFFFFF);

  auto getMgr = (void* (*)())(0x104bba084 + gSlide);
  void* mgr = getMgr ? getMgr() : nullptr;
  if (!mgr) return fallbackPlayerName(targetBaseId);

  uint8_t* base = *(uint8_t**)((uint8_t*)mgr + 0x48);
  if (!base) return fallbackPlayerName(targetBaseId);

  uint8_t* match = base + 0x6c4c0;

  int preferredSide = resolveActorSide(actor, match);

  auto checkSide = [&](int side) -> std::string {
    if (side < 0 || side > 1) return "";
    uint8_t* teamPlayers = match + 0x14e0 + (side * 0x5dc0);
    for (int i = 0; i < 40; ++i) {
      uint8_t* p = teamPlayers + (i * 0x258);
      uint32_t baseId = *(uint32_t*)(p + 0x38);
      uint64_t fullPid = *(uint64_t*)(p + 0x38);
      if ((baseId & 0xFFFFFF) == targetBaseId || (fullPid & 0xFFFFFF) == (uint64_t)targetBaseId || fullPid == (uint64_t)playerId) {
        const char* rawName = (const char*)(p + 0xc6);
        if (!rawName || !rawName[0]) rawName = (const char*)(p + 0x89);
        std::string name = sanitizeShirtName(rawName);
        if (name.empty()) name = sanitizeShirtName((const char*)(p + 0x103));
        if (name.empty()) name = fallbackPlayerName(targetBaseId);
        if (!name.empty()) return name;
      }
    }
    return "";
  };

  if (preferredSide >= 0) {
    std::string res = checkSide(preferredSide);
    if (!res.empty()) return res;
    return fallbackPlayerName(targetBaseId);
  }
  std::string res = checkSide(0);
  if (!res.empty()) return res;
  res = checkSide(1);
  if (!res.empty()) return res;
  return fallbackPlayerName(targetBaseId);
}

static std::string lookupPlayerNameUniversal(void* actor, int64_t playerId, int uniformNumber) {
  // Player identity takes priority over a number reused by both teams.
  if (playerId > 0) {
    std::string n = lookupShirtNameByPlayerId(actor, playerId);
    if (!n.empty()) return n;
  }
  (void)uniformNumber;  // a shirt number alone is not a player identity

  // 3. Try native TMPDB PlayerManager::FindPlayer with playerId
  if (playerId > 0 || (playerId & 0xFFFFFF) > 0) {
    auto getMgr = (void* (*)())(0x104bba084 + gSlide);
    void* mgr = getMgr ? getMgr() : nullptr;
    if (mgr) {
      void* pmgr = *(void**)((uint8_t*)mgr + 0x40);
      if (pmgr) {
        auto findPl = (void* (*)(void*, int64_t, int64_t))(0x104b9588c + gSlide);
        if (findPl) {
          void* pl = nullptr;
          if (playerId > 0) {
            pl = findPl(pmgr, 0, playerId);
            if (!pl && (playerId & 0xFFFFFF) > 0) {
              pl = findPl(pmgr, (int64_t)(playerId & 0xFFFFFF), 0);
            }
            if (!pl && (uint32_t)playerId > 0) {
              pl = findPl(pmgr, (int64_t)(uint32_t)playerId, 0);
            }
          }
          if (pl) {
            const char* raw = (const char*)((uint8_t*)pl + 0xc6);
            if (!raw || !raw[0]) raw = (const char*)((uint8_t*)pl + 0x89);
            std::string n = sanitizeShirtName(raw);
            if (!n.empty()) return n;
          }
        }
      }
    }
  }

  // 4. Try fallback player names
  if (playerId > 0) {
    std::string n = fallbackPlayerName((uint32_t)(playerId & 0xFFFFFF));
    if (!n.empty()) return n;
  }

  return "";
}

static std::string currentShirtName(void* actor) {
  if (!actor) return "";
  const uint8_t* s = (const uint8_t*)actor + 0x1710;
  bool heap = (int8_t)s[23] < 0;
  uint64_t len = heap ? ((const uint64_t*)s)[1] : (s[23] & 0x7f);
  const char* str = heap ? *(const char**)s : (const char*)s;
  if (!str || len == 0 || len > 120) return "";
  return std::string(str, (size_t)len);
}

// The name to print on the shirt: the engine's own name when it has one,
// otherwise the roster/database name of the identified player. Always the
// upper-case ASCII form the kit fonts contain.
static std::string desiredShirtName(void* actor, int64_t pid, int uniformNumber) {
  std::string native = currentShirtName(actor);
  std::string source = !native.empty() ? native : lookupPlayerNameUniversal(actor, pid, uniformNumber);
  std::string upper = sanitizeShirtName(source.c_str());
  return upper.empty() ? toUpperAscii(source) : upper;
}

static void applyActorShirtName(void* actor, const std::string& name) {
  if (!actor || name.empty()) return;
  std::string formatted = name;
  auto setShirt = (void (*)(void*, const char*))(0x10090ef34 + gSlide);
  if (setShirt) {
    setShirt(actor, formatted.c_str());
  }
  *(uint8_t*)((uint8_t*)actor + 0xf10) = 1;
  *(uint8_t*)((uint8_t*)actor + 0x1aaf) = 1;
  // NOTE: Never overwrite actor + 0xe38!
  // If set to 1, triggers referee branch at 0x1008ecb88 and aborts uniform creation (black screen).
  // If set to 0, triggers cbz w23 at 0x1008a0184, which skips font color setup.
  // Leave actor + 0xe38 at its native value.

  void* nameTexActor = *(void**)((uint8_t*)actor + 0x1918);
  if (nameTexActor) {
    auto setNameFn = (void (*)(void*, void*))(0x100851098 + gSlide);
    if (setNameFn) setNameFn(nameTexActor, (uint8_t*)actor + 0x1710);
    *(uint8_t*)((uint8_t*)nameTexActor + 0x290) = 0; // 0 = render player name; 1 = debug font test grid (orange box)
  }
}

static void hookedSetUniformNumber(void* actor, int uniformNumber) {
  if (originalSetUniformNumber) {
    originalSetUniformNumber(actor, uniformNumber);
  }
  if (!actor || uniformNumber <= 0) return;
  int64_t pid = 0;
  {
    std::lock_guard<std::mutex> lk(sActorLock);
    auto it = sActorPlayerId.find(actor);
    if (it != sActorPlayerId.end()) pid = it->second;
  }
  std::string name = desiredShirtName(actor, pid, uniformNumber);
  if (!name.empty()) {
    applyLegendRealFace(actor, pid, name);
    if (name != currentShirtName(actor)) applyActorShirtName(actor, name);
    ZLog(@"[JERSEY] SetUniformNumber #%d pid=%lld -> '%s'", uniformNumber, (long long)pid, name.c_str());
  }
}



static void hookedReloadFace(void* actor) {
  if (actor) {
    int64_t pid = 0;
    {
      std::lock_guard<std::mutex> lk(sActorLock);
      auto it = sActorPlayerId.find(actor);
      if (it != sActorPlayerId.end()) pid = it->second;
    }
    int32_t num = *(int32_t*)((uint8_t*)actor + 0x1708);
    std::string name = lookupPlayerNameUniversal(actor, pid, num);
    applyLegendRealFace(actor, pid, name);
  }
  if (originalReloadFace) {
    originalReloadFace(actor);
  }
}
static void hookedSetupFromPlayerId(void* actor, int64_t playerId, void* path, int uniformNumber, uint64_t uniName) {
  if (!actor) return;
  {
    std::lock_guard<std::mutex> lk(sActorLock);
    if (sActorPlayerId.size() > 512) { sActorPlayerId.clear(); }
    sActorPlayerId[actor] = playerId;
    // The fourth argument is UniNo (shirt number), not a home/away index.
  }
  if (originalSetupFromPlayerId) originalSetupFromPlayerId(actor, playerId, path, uniformNumber, uniName);
  int32_t num = *(int32_t*)((uint8_t*)actor + 0x1708);
  std::string name = desiredShirtName(actor, playerId, num);
  applyLegendRealFace(actor, playerId, name);
  if (!name.empty()) {
    if (name != currentShirtName(actor)) applyActorShirtName(actor, name);
    ZLog(@"[JERSEY] SetupFromPlayerId pid=%lld num=%d -> '%s'", (long long)playerId, num, name.c_str());
  }
}

static void hookedBackNumberStep(void* actor) {
  if (actor) {
    int32_t num = *(int32_t*)((uint8_t*)actor + 0x1708);
    if (num <= 0 || num > 99) {
      int32_t altNum = *(int32_t*)((uint8_t*)actor + 0x1924);
      if (altNum > 0 && altNum <= 99) num = altNum;
    }
    int64_t pid = 0;
    {
      std::lock_guard<std::mutex> lk(sActorLock);
      auto it = sActorPlayerId.find(actor);
      if (it != sActorPlayerId.end()) pid = it->second;
    }

    // Keep the engine's own name (upper-cased for the kit font); only an
    // empty name is filled, and only from an identified player.
    std::string neededName = desiredShirtName(actor, pid, num);
    if (!neededName.empty() && neededName != currentShirtName(actor)) {
      applyActorShirtName(actor, neededName);
    }

    *(uint8_t*)((uint8_t*)actor + 0xf10) = 1;
    *(uint8_t*)((uint8_t*)actor + 0x1aaf) = 1;
  }

  if (originalBackNumberStep) {
    originalBackNumberStep(actor);
  }

  if (actor) {
    *(uint8_t*)((uint8_t*)actor + 0xf10) = 1;
    *(uint8_t*)((uint8_t*)actor + 0x1aaf) = 1;

    void* nameTexActor = *(void**)((uint8_t*)actor + 0x1918);
    if (nameTexActor) {
      *(uint8_t*)((uint8_t*)nameTexActor + 0x290) = 0; // 0 = render player name; 1 = debug font test grid (orange box)

      const uint8_t* s = (const uint8_t*)actor + 0x1710;
      bool heap = (int8_t)s[23] < 0;
      uint64_t len = heap ? ((const uint64_t*)s)[1] : (s[23] & 0x7f);
      const char* curStr = heap ? *(const char**)s : (const char*)s;

      if (len > 0 && curStr && curStr[0]) {
        const uint8_t* ts = (const uint8_t*)nameTexActor + 0x278;
        bool theap = (int8_t)ts[23] < 0;
        uint64_t tlen = theap ? ((const uint64_t*)ts)[1] : (ts[23] & 0x7f);
        const char* tstr = theap ? *(const char**)ts : (const char*)ts;

        bool mismatch = (tlen == 0 || !tstr || tlen != len || strncmp(tstr, curStr, len) != 0);
        if (mismatch) {
          auto setNameFn = (void (*)(void*, void*))(0x100851098 + gSlide);
          if (setNameFn) setNameFn(nameTexActor, (uint8_t*)actor + 0x1710);
        }
      }
    }
  }
}

static void install() {
  intptr_t slide = 0; bool found = false;
  for (uint32_t i = 0; i < _dyld_image_count(); ++i) if (_dyld_get_image_header(i)->filetype == MH_EXECUTE) {
    slide = _dyld_get_image_vmaddr_slide(i); found = true; break;
  }
  if (!found) return;
  gSlide = slide;

  const uintptr_t slots[] = {0x105f177f8, 0x105f17800, 0x105f17808, 0x105f17818};
  const uintptr_t functions[] = {0x100851490, 0x100851894, 0x1008518c0, 0x1008511c8};
  for (int i = 0; i < 4; ++i) if (*(uintptr_t*)(slots[i] + slide) != functions[i] + slide) {
    ZLog(@"[JERSEY] unsupported native vtable; hooks disabled"); return;
  }
  vm_address_t page = (slots[0] + slide) & ~(vm_address_t)(vm_page_size - 1);
  vm_size_t length = slots[3] + slide + 8 - page;
  if (vm_protect(mach_task_self(), page, length, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
    ZLog(@"[JERSEY] vtable protection failed; hooks disabled"); return;
  }
  originalLoad = (LoadFn)*(uintptr_t*)(slots[0] + slide);
  originalReady = (ReadyFn)*(uintptr_t*)(slots[1] + slide);
  originalDraw = (DrawFn)*(uintptr_t*)(slots[2] + slide);
  originalAsset = (AssetFn)*(uintptr_t*)(slots[3] + slide);
  *(uintptr_t*)(slots[0] + slide) = (uintptr_t)load;
  *(uintptr_t*)(slots[1] + slide) = (uintptr_t)ready;
  *(uintptr_t*)(slots[2] + slide) = (uintptr_t)draw;
  vm_protect(mach_task_self(), page, length, false, VM_PROT_READ);
  ZLog(@"[JERSEY] native name atlas fallback and diagnostics installed");

  const uintptr_t actorSlots[] = {
    0x105f286c0, 0x105f287a0, 0x105f28800, 0x105f28830,
    0x105f29098, 0x105f29178, 0x105f291d8, 0x105f29208
  };
  const uintptr_t actorFuncs[] = {
    0x10089f2e8, 0x1008a02f0, 0x10089f3ec, 0x10089cfa4,
    0x10089f2e8, 0x1008a02f0, 0x10089f3ec, 0x10089cfa4
  };

  // Hook Mobile vtable (slots 0, 1, 2, 3)
  bool mobMatch = true;
  for (int i = 0; i < 4; ++i) {
    if (*(uintptr_t*)(actorSlots[i] + slide) != actorFuncs[i] + slide) {
      mobMatch = false; break;
    }
  }
  if (mobMatch) {
    vm_address_t actorPage = (actorSlots[0] + slide) & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t actorLength = ((actorSlots[3] + slide + 8 - actorPage + vm_page_size - 1) & ~(vm_page_size - 1));
    if (vm_protect(mach_task_self(), actorPage, actorLength, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
      originalSetUniformNumber = (SetUniformNumberFn)*(uintptr_t*)(actorSlots[0] + slide);
      originalSetupFromPlayerId = (SetupFromPlayerIdFn)*(uintptr_t*)(actorSlots[1] + slide);
      originalBackNumberStep = (BackNumberStepFn)*(uintptr_t*)(actorSlots[2] + slide);
      originalReloadFace = (ReloadFaceFn)*(uintptr_t*)(actorSlots[3] + slide);

      *(uintptr_t*)(actorSlots[0] + slide) = (uintptr_t)hookedSetUniformNumber;
      *(uintptr_t*)(actorSlots[1] + slide) = (uintptr_t)hookedSetupFromPlayerId;
      *(uintptr_t*)(actorSlots[2] + slide) = (uintptr_t)hookedBackNumberStep;
      *(uintptr_t*)(actorSlots[3] + slide) = (uintptr_t)hookedReloadFace;
      vm_protect(mach_task_self(), actorPage, actorLength, false, VM_PROT_READ);
      ZLog(@"[JERSEY] player actor shirt name and face hooks installed for Mobile");
    } else {
      ZLog(@"[JERSEY] vm_protect failed for Mobile vtable");
    }
  } else {
    ZLog(@"[JERSEY] Mobile vtable mismatch; skipped");
  }

  // Hook MobileHigh vtable (slots 4, 5, 6, 7)
  bool highMatch = true;
  for (int i = 4; i < 8; ++i) {
    if (*(uintptr_t*)(actorSlots[i] + slide) != actorFuncs[i] + slide) {
      highMatch = false; break;
    }
  }
  if (highMatch) {
    vm_address_t actorPage = (actorSlots[4] + slide) & ~(vm_address_t)(vm_page_size - 1);
    vm_size_t actorLength = ((actorSlots[7] + slide + 8 - actorPage + vm_page_size - 1) & ~(vm_page_size - 1));
    if (vm_protect(mach_task_self(), actorPage, actorLength, false, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
      *(uintptr_t*)(actorSlots[4] + slide) = (uintptr_t)hookedSetUniformNumber;
      *(uintptr_t*)(actorSlots[5] + slide) = (uintptr_t)hookedSetupFromPlayerId;
      *(uintptr_t*)(actorSlots[6] + slide) = (uintptr_t)hookedBackNumberStep;
      *(uintptr_t*)(actorSlots[7] + slide) = (uintptr_t)hookedReloadFace;
      vm_protect(mach_task_self(), actorPage, actorLength, false, VM_PROT_READ);
      ZLog(@"[JERSEY] player actor shirt name and face hooks installed for MobileHigh");
    } else {
      ZLog(@"[JERSEY] vm_protect failed for MobileHigh vtable");
    }
  } else {
    ZLog(@"[JERSEY] MobileHigh vtable mismatch; skipped");
  }
}
}
