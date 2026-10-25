#pragma once
#include <cstdint>
#include <string>

namespace zidentity {
inline uint32_t legendFace(int64_t pid, const std::string&) {
  uint32_t base = (uint32_t)(pid & 0xFFFFFF);
  if (pid > 0) {
    if (base == 9901397) return 9901397;
    if (base == 37576) return 37576;
    return 0;
  }
  // Both 4522 (Cristiano) and 37576 (R9) have the exact shirt name RONALDO
  // in the supplied database. A shirt name cannot establish face identity.
  return 0;
}
}
