// Drops chosen UFunction calls on chosen objects before they run. The game's single-player managers broadcast to every
// character in the process (e.g. BP_MainCharacterManager.CommandEnterCar), so without this the other player's character
// on each side runs the local player's enter-car, storm and feedback code. Lua passes object addresses (UObject:GetAddress()).
//   PTNative_Mute(address, "Fn A|Fn B")   short UFunction names, exact match
//   PTNative_Unmute(address)
//   PTNative_MuteClear()                  e.g. before a map change, so a reused address is never muted by accident
//   PTNative_MuteCount() -> calls dropped so far (for tests)
//   PTNative_MediaTime(player) -> ms   UMediaPlayer::GetTime / Seek(FTimespan): Lua cannot read or build an FTimespan (no reflected
//   PTNative_MediaSeek(player, ms)     properties), the shared radio needs the song position (radio.lua)
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/UObjectGlobals.hpp>

#include <algorithm>
#include <cstring>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

using namespace RC;
using namespace RC::Unreal;

namespace
{
std::mutex g_mutex;
std::unordered_map<UObject*, std::vector<std::wstring>> g_muted;
bool g_any = false; // read without the lock on the hot path; ProcessEvent runs on the game thread, as does every Lua call here
long long g_dropped = 0;
Hook::GlobalCallbackId g_id = 0;

auto on_pre(Hook::TCallbackIterationData<void>& data, UObject* context, UFunction* function, void*) -> void
{
    if (!g_any || !context || !function) return;
    std::lock_guard lock(g_mutex);
    auto it = g_muted.find(context);
    if (it == g_muted.end()) return;
    auto name = function->GetName();
    for (auto& n : it->second)
    {
        if (n == name) { data.PreventOriginalFunctionCall(); ++g_dropped; return; }
    }
}

auto ensure_hook() -> void
{
    if (!g_id) g_id = Hook::RegisterProcessEventPreCallback(on_pre, {false, false, STR("PacificTogether"), STR("Mute")});
}
// UMediaPlayer: GetTime() has no parameters (the FTimespan return value, in ticks of 100 ns, is at offset 0); Seek(FTimespan) is
// the first parameter at offset 0 followed by a bool return value
auto media_call(uintptr_t address, const wchar_t* name, int64_t* ticks) -> bool
{
    auto* mp = reinterpret_cast<UObject*>(address);
    auto* fn = address ? UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, name) : nullptr;
    if (!mp || !fn) return false;
    std::vector<unsigned char> parms(std::max<size_t>(fn->GetStructureSize(), 16), 0);
    if (*ticks >= 0) std::memcpy(parms.data(), ticks, sizeof(int64_t));
    mp->ProcessEvent(fn, parms.data());
    if (*ticks < 0) std::memcpy(ticks, parms.data(), sizeof(int64_t));
    return true;
}
} // namespace

auto pt_register_mute(const LuaMadeSimple::Lua& lua) -> void
{
    lua.register_function("PTNative_Mute", [](const LuaMadeSimple::Lua& l) -> int {
        auto address = static_cast<uintptr_t>(l.get_integer());
        auto names = std::string(l.get_string());
        std::vector<std::wstring> list;
        size_t pos = 0;
        while (pos <= names.size())
        {
            auto bar = names.find('|', pos);
            auto part = names.substr(pos, bar == std::string::npos ? std::string::npos : bar - pos);
            if (!part.empty()) list.emplace_back(part.begin(), part.end());
            if (bar == std::string::npos) break;
            pos = bar + 1;
        }
        bool ok = address != 0 && !list.empty();
        if (ok)
        {
            std::lock_guard lock(g_mutex);
            g_muted[reinterpret_cast<UObject*>(address)] = std::move(list);
            g_any = true;
            ensure_hook();
        }
        l.set_bool(ok);
        return 1;
    });
    lua.register_function("PTNative_Unmute", [](const LuaMadeSimple::Lua& l) -> int {
        auto address = static_cast<uintptr_t>(l.get_integer());
        std::lock_guard lock(g_mutex);
        bool had = g_muted.erase(reinterpret_cast<UObject*>(address)) > 0;
        g_any = !g_muted.empty();
        l.set_bool(had);
        return 1;
    });
    lua.register_function("PTNative_MuteClear", [](const LuaMadeSimple::Lua& l) -> int {
        std::lock_guard lock(g_mutex);
        g_muted.clear();
        g_any = false;
        l.set_bool(true);
        return 1;
    });
    lua.register_function("PTNative_MediaTime", [](const LuaMadeSimple::Lua& l) -> int {
        int64_t t = -1;
        if (media_call(static_cast<uintptr_t>(l.get_integer()), STR("/Script/MediaAssets.MediaPlayer:GetTime"), &t)) l.set_integer(t / 10000);
        else l.set_integer(-1);
        return 1;
    });
    lua.register_function("PTNative_MediaSeek", [](const LuaMadeSimple::Lua& l) -> int {
        auto address = static_cast<uintptr_t>(l.get_integer());
        int64_t t = l.get_integer() * 10000;
        l.set_bool(t >= 0 && media_call(address, STR("/Script/MediaAssets.MediaPlayer:Seek"), &t));
        return 1;
    });
    lua.register_function("PTNative_MuteCount", [](const LuaMadeSimple::Lua& l) -> int {
        std::lock_guard lock(g_mutex);
        l.set_integer(g_dropped);
        return 1;
    });
}
