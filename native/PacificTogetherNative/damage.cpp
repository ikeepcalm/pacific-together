// Remote characters must not run this process's singleton health/feedback receiver.
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <LuaType/LuaUObject.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FWeakObjectPtr.hpp>
#include <array>
#include <algorithm>
#include <deque>
#include <unordered_map>

using namespace RC;
using namespace RC::Unreal;
namespace {
std::unordered_map<UObject*, FWeakObjectPtr> receivers;
struct Hit { FWeakObjectPtr receiver, payload; bool rooted; };
std::deque<Hit> hits;
Hook::GlobalCallbackId hookId = 0;
constexpr std::array binds = {
    L"MessageBind_MSG_Damage_Physical_C", L"MessageBind_MSG_Base_Heal_C", L"MessageBind_MSG_Damage_Acid_C",
    L"MessageBind_MSG_Damage_Radiation_C", L"MessageBind_MSG_Damage_Electrical_C", L"MessageBind_MSG_Damage_FallDamage_C",
    L"MessageBind_MSG_Heal_Generic_C", L"MessageBind_MSG_Base_Damage_C"};
void clear() {
    for (auto& hit : hits) if (auto* p = hit.payload.Get(); p && hit.rooted) p->ClearRootSet();
    hits.clear(); receivers.clear();
}
void intercept(Hook::TCallbackIterationData<void>& call, UObject* context, UFunction* function, void* params) {
    if (!context || !function || !params || receivers.empty()) return;
    auto it = receivers.find(context);
    if (it == receivers.end() || it->second.Get() != context) return;
    auto name = function->GetName();
    if (std::find(binds.begin(), binds.end(), name) == binds.end()) return;
    auto* payload = *static_cast<UObject**>(params); // all admitted bind signatures start with Payload:Object
    if (!payload) return;
    call.PreventOriginalFunctionCall();
    // Each dispatch reaches one base bind plus its subtype feedback bind. Reused DOT payloads are separate hits.
    if (name != STR("MessageBind_MSG_Base_Damage_C") && name != STR("MessageBind_MSG_Base_Heal_C")) return;
    bool rooted = !payload->IsRootSet();
    if (rooted) payload->SetRootSet();
    hits.push_back({FWeakObjectPtr(context), FWeakObjectPtr(payload), rooted});
}
}
auto pt_register_damage(const LuaMadeSimple::Lua& lua) -> void {
    lua.register_function("PTNative_DamageReceiver", [](const LuaMadeSimple::Lua& l) -> int {
        if (l.get_stack_size() != 1 || !l.is_integer()) { l.set_bool(false); return 1; }
        auto* receiver = reinterpret_cast<UObject*>(static_cast<uintptr_t>(l.get_integer()));
        if (!receiver || receiver->GetClassPrivate()->GetName() != STR("AC_PlayerHealthReceiverHelper_C")) { l.set_bool(false); return 1; }
        receivers[receiver] = FWeakObjectPtr(receiver);
        if (!hookId) hookId = Hook::RegisterProcessEventPreCallback(intercept, {false, false, STR("PacificTogether"), STR("Damage")});
        l.set_bool(true); return 1;
    });
    lua.register_function("PTNative_DamageClear", [](const LuaMadeSimple::Lua&) -> int { clear(); return 0; });
    lua.register_function("PTNative_DamagePoll", [](const LuaMadeSimple::Lua& l) -> int {
        while (!hits.empty()) {
            auto hit = hits.front(); hits.pop_front();
            auto* receiver = hit.receiver.Get(); auto* payload = hit.payload.Get();
            if (payload && hit.rooted) payload->ClearRootSet();
            if (!receiver || !payload) continue;
            LuaType::auto_construct_object(l, receiver);
            LuaType::auto_construct_object(l, payload);
            return 2;
        }
        return 0;
    });
}
