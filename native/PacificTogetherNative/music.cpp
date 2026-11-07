// Custom radio files: only a selected local audio file can be read; writes stay in a hash-named cache.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>
#include <wincrypt.h>
#include <algorithm>
#include <cctype>
#include <cstdio>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#pragma comment(lib, "advapi32.lib")

namespace
{
constexpr long long LIMIT = 64 * 1024 * 1024;
constexpr size_t BLOCK = 8192;
struct Hash {
    HCRYPTPROV provider{}; HCRYPTHASH hash{};
    Hash() { if (CryptAcquireContextW(&provider, nullptr, nullptr, PROV_RSA_AES, CRYPT_VERIFYCONTEXT)) CryptCreateHash(provider, CALG_SHA_256, 0, 0, &hash); }
    ~Hash() { if (hash) CryptDestroyHash(hash); if (provider) CryptReleaseContext(provider, 0); }
    bool add(const void* p, size_t n) { return hash && CryptHashData(hash, static_cast<const BYTE*>(p), static_cast<DWORD>(n), 0); }
    std::string finish() {
        BYTE bytes[32]; DWORD n = sizeof(bytes); std::string out;
        if (!hash || !CryptGetHashParam(hash, HP_HASHVAL, bytes, &n, 0)) return out;
        for (auto b : bytes) { out += "0123456789abcdef"[b >> 4]; out += "0123456789abcdef"[b & 15]; }
        return out;
    }
};
using File = std::unique_ptr<FILE, decltype(&fclose)>;
auto wide(const std::string& s) -> std::wstring {
    if (s.find('\0') != std::string::npos) return {};
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), nullptr, 0);
    std::wstring out(n, L'\0');
    if (n) MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s.data(), static_cast<int>(s.size()), out.data(), n);
    return out;
}
auto url(const std::wstring& path) -> std::string {
    int n = WideCharToMultiByte(CP_UTF8, 0, path.data(), static_cast<int>(path.size()), nullptr, 0, nullptr, nullptr);
    std::string out(n, '\0');
    if (n) WideCharToMultiByte(CP_UTF8, 0, path.data(), static_cast<int>(path.size()), out.data(), n, nullptr, nullptr);
    std::replace(out.begin(), out.end(), '\\', '/');
    return "file://" + out;
}
auto absolute(const std::wstring& path) -> std::wstring {
    wchar_t out[32768]; DWORD n = GetFullPathNameW(path.c_str(), 32768, out, nullptr);
    return n && n < 32768 ? std::wstring(out, n) : std::wstring{};
}
struct DigestJob {
    File file{nullptr, fclose}; std::unique_ptr<Hash> hash; long long remaining{};
    void clear() { file.reset(); hash.reset(); }
    bool start(const std::wstring& path, long long size) {
        clear(); file.reset(_wfopen(path.c_str(), L"rb")); hash = std::make_unique<Hash>(); remaining = size;
        if (!file || !hash->hash) { clear(); return false; } return true;
    }
    std::string step() {
        if (!file) return {};
        char buf[65536]; size_t budget = 1024 * 1024;
        while (remaining && budget) {
            size_t want = static_cast<size_t>(std::min<long long>(sizeof(buf), remaining));
            if (fread(buf, 1, want, file.get()) != want || !hash->add(buf, want)) { clear(); return {}; }
            remaining -= want; budget -= want;
        }
        if (remaining) return "pending";
        auto result = hash->finish(); clear(); return result;
    }
};
DigestJob sourceJob, cacheJob;
auto valid(const std::string& id, const std::string& ext, long long size) -> bool {
    return id.size() == 64 && id.find_first_not_of("0123456789abcdef") == std::string::npos
        && (ext == "mp3" || ext == "wav" || ext == "ogg") && size > 0 && size <= LIMIT;
}
auto cache_root() -> std::wstring {
    wchar_t exe[32768]; DWORD n = GetModuleFileNameW(nullptr, exe, 32768);
    if (!n || n >= 32768) return {};
    std::wstring path(exe, n); auto slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? std::wstring{} : path.substr(0, slash) + L"\\ue4ss\\pt_music";
}
auto cache(const std::string& id, const std::string& ext) -> std::wstring {
    auto root = cache_root(); return root.empty() ? root : root + L"\\" + wide(id + "." + ext);
}
std::wstring source;
std::string sourceId, sourceExt;
long long sourceSize{};
FILETIME sourceTime{};
auto info(const std::string& uri) -> std::string {
    if (!uri.starts_with("file://")) return {};
    auto raw = uri.substr(7); while (!raw.empty() && raw.front() == '/') raw.erase(0, 1);
    if (raw.size() < 4 || raw[1] != ':' || (raw[2] != '/' && raw[2] != '\\')) return {};
    auto path = wide(raw); auto dot = raw.find_last_of('.');
    auto ext = dot == std::string::npos ? "" : raw.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return static_cast<char>(tolower(c)); });
    WIN32_FILE_ATTRIBUTE_DATA st{};
    if (path.empty() || !GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &st) || (st.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)) return {};
    long long size = (static_cast<long long>(st.nFileSizeHigh) << 32) | st.nFileSizeLow;
    if (!valid(std::string(64, '0'), ext, size)) return {};
    if (path != source || size != sourceSize || CompareFileTime(&st.ftLastWriteTime, &sourceTime) != 0) {
        sourceJob.clear(); sourceId.clear();
        source = path; sourceExt = ext; sourceSize = size; sourceTime = st.ftLastWriteTime;
    }
    if (sourceId.empty()) {
        if (!sourceJob.file && !sourceJob.start(path, size)) return {};
        auto id = sourceJob.step(); if (id == "pending" || id.empty()) return id; sourceId = id;
    }
    return sourceId + "|" + std::to_string(sourceSize) + "|" + sourceExt;
}
auto read(const std::string& id, long long offset) -> std::string {
    if (id != sourceId || offset < 0 || offset >= sourceSize) return {};
    File f(_wfopen(source.c_str(), L"rb"), fclose); if (!f || _fseeki64(f.get(), offset, SEEK_SET)) return {};
    unsigned char buf[BLOCK]; size_t n = fread(buf, 1, static_cast<size_t>(std::min<long long>(BLOCK, sourceSize - offset)), f.get());
    if (!n || ferror(f.get())) return {};
    std::string out; out.reserve(n * 2);
    for (size_t i = 0; i < n; ++i) { out += "0123456789abcdef"[buf[i] >> 4]; out += "0123456789abcdef"[buf[i] & 15]; }
    return out;
}
std::wstring verified;
std::wstring checking;
FILETIME verifiedTime{};
FILETIME checkingTime{};
long long verifiedSize{};
auto cached(const std::string& id, const std::string& ext, long long size) -> std::string {
    if (!valid(id, ext, size)) return {};
    DWORD attrs = GetFileAttributesW(cache_root().c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return {};
    auto path = cache(id, ext); WIN32_FILE_ATTRIBUTE_DATA st{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &st) || (st.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)
        || st.nFileSizeHigh || st.nFileSizeLow != size) return {};
    if (path != verified || size != verifiedSize || CompareFileTime(&st.ftLastWriteTime, &verifiedTime) != 0) {
        if (!cacheJob.file || checking != path || CompareFileTime(&checkingTime, &st.ftLastWriteTime) != 0) {
            if (!cacheJob.start(path, size)) return {};
            checking = path; checkingTime = st.ftLastWriteTime;
        }
        auto got = cacheJob.step(); if (got == "pending") return got; if (got != id) return {};
        verified = path; verifiedSize = size; verifiedTime = st.ftLastWriteTime;
    }
    return url(path);
}
File incoming(nullptr, fclose);
std::unique_ptr<Hash> incomingHash;
std::wstring part, destination;
std::string incomingId;
long long received{}, expected{};
void cancel() {
    incoming.reset(); incomingHash.reset();
    sourceJob.clear(); cacheJob.clear();
    if (!part.empty()) DeleteFileW(part.c_str());
    part.clear(); destination.clear(); incomingId.clear(); received = expected = 0;
}
auto room(long long needed) -> bool {
    struct Entry { std::wstring path; long long size; FILETIME time; };
    std::vector<Entry> files; long long total = 0;
    WIN32_FIND_DATAW st{}; HANDLE scan = FindFirstFileW((cache_root() + L"\\*").c_str(), &st);
    if (scan == INVALID_HANDLE_VALUE) return false;
    do {
        if (st.dwFileAttributes & (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) continue;
        std::wstring name(st.cFileName);
        if (name.size() < 68 || name.substr(0, 64).find_first_not_of(L"0123456789abcdef") != std::wstring::npos || name[64] != '.') continue;
        auto ext = name.substr(65);
        auto path = cache_root() + L"\\" + name;
        if (ext == L"mp3.part" || ext == L"wav.part" || ext == L"ogg.part") { DeleteFileW(path.c_str()); continue; }
        if (ext != L"mp3" && ext != L"wav" && ext != L"ogg") continue;
        long long size = (static_cast<long long>(st.nFileSizeHigh) << 32) | st.nFileSizeLow;
        total += size; files.push_back({ path, size, st.ftLastWriteTime });
    } while (FindNextFileW(scan, &st));
    FindClose(scan);
    auto count = files.size();
    std::sort(files.begin(), files.end(), [](const Entry& a, const Entry& b) { return CompareFileTime(&a.time, &b.time) < 0; });
    for (auto& f : files) {
        if (total + needed <= 256 * 1024 * 1024 && count < 64) return true;
        if (DeleteFileW(f.path.c_str())) { total -= f.size; --count; }
    }
    return total + needed <= 256 * 1024 * 1024 && count < 64;
}
auto begin(const std::string& id, const std::string& ext, long long size) -> bool {
    if (!valid(id, ext, size)) return false;
    cancel(); auto root = cache_root(); if (root.empty()) return false;
    CreateDirectoryW(root.substr(0, root.find_last_of(L'\\')).c_str(), nullptr); CreateDirectoryW(root.c_str(), nullptr);
    DWORD attrs = GetFileAttributesW(root.c_str());
    if (attrs == INVALID_FILE_ATTRIBUTES || !(attrs & FILE_ATTRIBUTE_DIRECTORY) || (attrs & FILE_ATTRIBUTE_REPARSE_POINT)) return false;
    if (!room(size)) return false;
    destination = cache(id, ext); part = destination + L".part";
    DeleteFileW(part.c_str()); // Unlink stale parts, rather than writing through a pre-existing link.
    incoming.reset(_wfopen(part.c_str(), L"wbx"));
    incomingHash = std::make_unique<Hash>();
    if (!incoming || !incomingHash->hash) { cancel(); return false; }
    incomingId = id; expected = size; return true;
}
auto append(const std::string& id, long long offset, const std::string& hex) -> bool {
    if (!incoming || id != incomingId || offset != received || hex.empty() || hex.size() > BLOCK * 2 || hex.size() % 2
        || hex.find_first_not_of("0123456789abcdef") != std::string::npos || received + static_cast<long long>(hex.size() / 2) > expected) return false;
    std::vector<unsigned char> bytes; bytes.reserve(hex.size() / 2);
    auto nibble = [](char c) { return c <= '9' ? c - '0' : c - 'a' + 10; };
    for (size_t i = 0; i < hex.size(); i += 2) bytes.push_back(static_cast<unsigned char>(nibble(hex[i]) * 16 + nibble(hex[i + 1])));
    if (fwrite(bytes.data(), 1, bytes.size(), incoming.get()) != bytes.size() || !incomingHash->add(bytes.data(), bytes.size())) { cancel(); return false; }
    received += bytes.size(); return true;
}
auto finish(const std::string& id) -> std::string {
    if (!incoming || id != incomingId || received != expected) return {};
    bool good = incomingHash->finish() == id && fflush(incoming.get()) == 0;
    if (fclose(incoming.release()) != 0) good = false;
    if (!good || !MoveFileExW(part.c_str(), destination.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) { cancel(); return {}; }
    auto result = url(destination); part.clear(); cancel(); return result;
}
}

#ifndef PT_MUSIC_SELF_TEST
#include <LuaMadeSimple/LuaMadeSimple.hpp>
auto pt_register_music(const RC::LuaMadeSimple::Lua& lua) -> void {
    static std::mutex mutex;
    lua.register_function("PTNative_MusicInfo", [](const RC::LuaMadeSimple::Lua& l) -> int { std::lock_guard lock(mutex); l.set_string(info(std::string(l.get_string()))); return 1; });
    lua.register_function("PTNative_MusicRead", [](const RC::LuaMadeSimple::Lua& l) -> int { auto id = std::string(l.get_string()); auto at = l.get_integer(); std::lock_guard lock(mutex); l.set_string(read(id, at)); return 1; });
    lua.register_function("PTNative_MusicCached", [](const RC::LuaMadeSimple::Lua& l) -> int { auto id = std::string(l.get_string()); auto ext = std::string(l.get_string()); auto size = l.get_integer(); std::lock_guard lock(mutex); l.set_string(cached(id, ext, size)); return 1; });
    lua.register_function("PTNative_MusicBegin", [](const RC::LuaMadeSimple::Lua& l) -> int { auto id = std::string(l.get_string()); auto ext = std::string(l.get_string()); auto size = l.get_integer(); std::lock_guard lock(mutex); l.set_bool(begin(id, ext, size)); return 1; });
    lua.register_function("PTNative_MusicAppend", [](const RC::LuaMadeSimple::Lua& l) -> int { auto id = std::string(l.get_string()); auto at = l.get_integer(); auto hex = std::string(l.get_string()); std::lock_guard lock(mutex); l.set_bool(append(id, at, hex)); return 1; });
    lua.register_function("PTNative_MusicFinish", [](const RC::LuaMadeSimple::Lua& l) -> int { auto id = std::string(l.get_string()); std::lock_guard lock(mutex); l.set_string(finish(id)); return 1; });
    lua.register_function("PTNative_MusicCancel", [](const RC::LuaMadeSimple::Lua&) -> int { std::lock_guard lock(mutex); cancel(); return 0; });
}
#else
#include <cassert>
int main() {
    auto path = absolute(L"test-\u00e7-\u044f.wav");
    std::string bytes(3 * 1024 * 1024 + 19, '\0');
    for (size_t i = 0; i < bytes.size(); ++i) bytes[i] = static_cast<char>(i * 31);
    { File f(_wfopen(path.c_str(), L"wb"), fclose); assert(f); assert(fwrite(bytes.data(), 1, bytes.size(), f.get()) == bytes.size()); }
    auto infoReady = [](const std::string& uri) { std::string result; do { result = info(uri); } while (result == "pending"); return result; };
    auto cacheReady = [](const std::string& id, long long size) { std::string result; do { result = cached(id, "wav", size); } while (result == "pending"); return result; };
    assert(info(url(path)) == "pending");
    auto metadata = infoReady(url(path)); assert(!metadata.empty()); auto id = metadata.substr(0, 64);
    auto previousDir = absolute(L"."); CreateDirectoryW(L"unrelated-cwd", nullptr); assert(SetCurrentDirectoryW(L"unrelated-cwd"));
    DeleteFileW(cache(id, "wav").c_str()); assert(cached(id, "wav", bytes.size()).empty());
    assert(info("file://server/private.wav").empty()); assert(read("wrong", 0).empty());
    assert(!begin("../bad", "wav", 10)); assert(!begin(id, "exe", 10)); assert(!begin(id, "wav", LIMIT + 1));
    assert(begin(id, "wav", bytes.size())); assert(!append(id, 1, "00")); assert(!append(id, 0, "zz"));
    for (long long at = 0; at < static_cast<long long>(bytes.size()); at += BLOCK) assert(append(id, at, read(id, at)));
    auto result = finish(id); assert(!result.empty() && cached(id, "wav", bytes.size()) == "pending" && cacheReady(id, bytes.size()) == result);
    { File f(_wfopen(cache(id, "wav").c_str(), L"rb"), fclose); std::string got(bytes.size(), '\0'); assert(fread(got.data(), 1, got.size(), f.get()) == got.size()); assert(got == bytes); }
    assert(begin(id, "wav", bytes.size()));
    for (long long at = 0; at < static_cast<long long>(bytes.size()); at += BLOCK) { auto hex = read(id, at); if (!at) hex[0] = hex[0] == '0' ? '1' : '0'; assert(append(id, at, hex)); }
    assert(finish(id).empty()); assert(GetFileAttributesW((cache(id, "wav") + L".part").c_str()) == INVALID_FILE_ATTRIBUTES);
    assert(begin(id, "wav", bytes.size())); cancel(); assert(finish(id).empty());
    auto keep = cache_root() + L"\\keep.txt";
    { File f(_wfopen(keep.c_str(), L"wb"), fclose); assert(f); fputs("unrelated", f.get()); }
    assert(room(256 * 1024 * 1024)); assert(GetFileAttributesW(cache(id, "wav").c_str()) == INVALID_FILE_ATTRIBUTES);
    assert(GetFileAttributesW(keep.c_str()) != INVALID_FILE_ATTRIBUTES);
    DeleteFileW(keep.c_str());
    std::vector<std::wstring> small;
    for (int i = 0; i < 64; ++i) {
        auto key = std::string(62, '0'); key += "0123456789abcdef"[i / 16]; key += "0123456789abcdef"[i % 16];
        small.push_back(cache(key, "ogg")); File f(_wfopen(small.back().c_str(), L"wb"), fclose); assert(f); fputc('x', f.get());
    }
    assert(room(1)); int remaining = 0;
    for (auto& f : small) { if (GetFileAttributesW(f.c_str()) != INVALID_FILE_ATTRIBUTES) ++remaining; DeleteFileW(f.c_str()); }
    assert(remaining == 63);
    DeleteFileW(path.c_str()); DeleteFileW(cache(id, "wav").c_str());
    assert(SetCurrentDirectoryW(previousDir.c_str())); RemoveDirectoryW((previousDir + L"\\unrelated-cwd").c_str());
    puts("PASS native music: Unicode, binary fidelity, SHA-256, invalid paths/offsets/sizes, corruption, cancellation and cache quota");
}
#endif
