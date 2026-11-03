// Object lookup by full path through the engine's hash tables only.
// UE4SS's StaticFindObject falls back to a scan of every object by full name when the hash misses: 25-45 ms per miss in a
// zone (measured 2026-10-22), and the mod looks up not-yet-loaded classes in loops (hook retries, LoadAsset checks).
//   PTNative_Find(path) -> UObject | nil     never scans while the hash tables are up (UE4SS self test passed)
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <Unreal/UObjectHashTables.hpp>
#include <Unreal/UnrealInitializer.hpp>
#include <charconv>

using namespace RC;
using namespace RC::Unreal;

auto pt_register_find(const LuaMadeSimple::Lua& lua) -> void
{
    // Resolve the captured weak key without reading memory through a stale UObject address.
    lua.register_function("PTNative_ObjectMatches", [](const LuaMadeSimple::Lua& l) -> int {
        auto key = std::string(l.get_string());
        auto colon = key.find(':');
        FWeakObjectPtr weak;
        if (colon == std::string::npos) { l.set_bool(false); return 1; }
        auto index = std::from_chars(key.data(), key.data() + colon, weak.ObjectIndex);
        auto serial = std::from_chars(key.data() + colon + 1, key.data() + key.size(), weak.ObjectSerialNumber);
        l.set_bool(index.ec == std::errc{} && index.ptr == key.data() + colon && serial.ec == std::errc{} &&
            serial.ptr == key.data() + key.size() && weak.ObjectIndex >= 0 && weak.ObjectSerialNumber > 0 && weak.Get() != nullptr);
        return 1;
    });
    lua.register_function("PTNative_ObjectIdentity", [](const LuaMadeSimple::Lua& l) -> int {
        auto* object = reinterpret_cast<UObject*>(static_cast<uintptr_t>(l.get_integer()));
        if (!object) { l.set_nil(); return 1; }
        FWeakObjectPtr weak(object);
        if (weak.Get() != object) { l.set_nil(); return 1; }
        l.set_string(std::to_string(weak.ObjectIndex) + ":" + std::to_string(weak.ObjectSerialNumber));
        return 1;
    });
    lua.register_function("PTNative_Find", [](const LuaMadeSimple::Lua& l) -> int {
        auto path = ensure_str(l.get_string());
        UObject* found = UnrealInitializer::ShouldUseHashTables()
                ? FUObjectHashTables::StaticFindObjectByPath(nullptr, path.c_str())
                : UObjectGlobals::StaticFindObject(nullptr, nullptr, path);
        if (!found) { l.set_nil(); return 1; }
        LuaType::auto_construct_object(l, found);
        return 1;
    });
}
