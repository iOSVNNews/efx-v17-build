// iOS login needs one consistent download list and integrity manifest. Build
// both from the same paths that serveLivedataAsset actually serves. In
// particular, never hash Download/ while serving a different livedata/ file.
void patchIosLivedataManifest(const ObjP& li) {
  ObjP version = Object::parse(li->optString("version_file", "{}"));
  version->remove("targetAppVersion");
  std::set<std::string> names;
  auto addName = [&](std::string name) {
    if (name.find('/') != std::string::npos || name.find('\\') != std::string::npos) return;
    size_t platform = name.find("_mobile_and.");
    if (platform != std::string::npos) name.replace(platform, 11, "_mobile_ios");
    if (name.rfind("pc", 0) == 0 && name.find("_mobile_ios.") != std::string::npos)
      names.insert(name);
  };
  ArrP previous = li->optJSONArray("livedata_list");
  for (int i = 0; previous && i < previous->length(); ++i) {
    ObjP item = previous->optJSONObject(i);
    if (item) addName(item->optString("name", ""));
  }
  // The bundled native inventory also recovers a list erased by older builds.
  // Its filenames identify intended groups; custom installed bytes are kept
  // and measured rather than overwritten or claimed to be platform-converted.
  std::string nativeText;
  if (assets.read("native-livedata.json", nativeText)) {
    ArrP native = Array::parse(nativeText);
    for (int i = 0; i < native->length(); ++i) {
      ObjP item = native->optJSONObject(i);
      if (item) addName(item->optString("name", ""));
    }
  }
  auto metadata = [&](const std::string& name, bool nativeContainer) -> ObjP {
    std::string path = assets.path("livedata/" + name);
    // Assets::path has an Android fallback. Do not advertise a renamed Android
    // container as a recovered native pack; CPK tables may use the shared alias.
    if (nativeContainer && !endsWith(path, name)) return nullptr;
    struct stat st{};
    if (stat(path.c_str(), &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 0) return nullptr;
    std::string hash = commentaryHash(path, st);
    if (hash.size() != 64) return nullptr;
    return newObj()->put("name", name)->put("size", (long long)st.st_size)
        ->put("hash", hash)->put("url", livedataBaseUrl + name);
  };
  ArrP downloads = newArr(), packs = newArr();
  ObjP database = metadata("dt870_mobile_ios.cpk", false);
  if (!database) throw IOEx("Live Update dt870 is missing or unreadable");
  downloads->put(database);
  version->put("dt870Hash", database->getString("hash"))
      ->put("dt870FileSize", database->getLong("size"));
  std::set<std::string> stems;
  for (const auto& name : names) {
    size_t platform = name.find("_mobile_ios.");
    std::string id = name.substr(2, platform - 2);
    if (id.empty() || id.find_first_not_of("0123456789") != std::string::npos) continue;
    if (endsWith(name, ".pak") || endsWith(name, ".utoc") || endsWith(name, ".ucas"))
      stems.insert(name.substr(0, platform));
  }
  for (const auto& stem : stems) {
    ObjP pak = metadata(stem + "_mobile_ios.pak", true);
    ObjP ucas = metadata(stem + "_mobile_ios.ucas", true);
    ObjP utoc = metadata(stem + "_mobile_ios.utoc", true);
    if (!pak || !ucas || !utoc) {
      logRequest("IOS_LIVEDATA_MANIFEST", "incomplete group retained on disk, not advertised: " + stem);
      continue;
    }
    downloads->put(pak)->put(ucas)->put(utoc);
    packs->put(newObj()->put("name", stem)->put("hash", pak->getString("hash"))
        ->put("hashFileSize", pak->getLong("size"))->put("ucas", ucas->getString("hash"))
        ->put("ucasFileSize", ucas->getLong("size"))->put("utoc", utoc->getString("hash"))
        ->put("utocFileSize", utoc->getLong("size")));
  }
  version->put("dt880", packs);
  // The previous empty and complete manifests reused 2026091003. A newer
  // revision makes the client reconsider that stale cached version once.
  version->put("version", (long long)std::max<int64_t>(version->optLong("version", 0), 2026102101LL));
  li->put("version_file", version->toString())->put("livedata_list", downloads);
  logRequest("IOS_LIVEDATA_MANIFEST", "version=" + std::to_string(version->getLong("version")) +
      " files=" + std::to_string(downloads->length()) + " groups=" + std::to_string(packs->length()) +
      " dt870=" + database->getString("hash"));
}
