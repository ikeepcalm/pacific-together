// Message channel between host and guest on the existing game connection, for intents and state (PLAN §3).
// Guest -> host rides APlayerController::ServerExecRPC(FString): reliable, ordered, and a no-op in shipping builds
// (PlayerController.cpp:1739). Host -> guest rides ClientMessage(FString): reliable, ordered; its implementation only
// prints to the console, so ours are dropped before it runs. Both follow the connection: direct IP or the Steam tunnel.
// A message is "kind" + bytes (no NUL), split into chunks "PT1|<kind>|<m or e>|<bytes>"; chunks of one connection arrive
// in order, so reassembly needs no ids. Each byte is one TCHAR, so bytes come back exactly.
// Received messages wait in an inbox; each Lua mod polls the kinds it owns (main mod "g.", test mod "t.").
// Flow control: each side confirms the chunks it got ("PT1A|<count>", once a frame) and a sender keeps at most WINDOW chunks
// unconfirmed per connection; the rest wait in order. A guest joining a big save got every module's full state in one frame,
// the PlayerController channel passed UE's 256 outstanding reliable bunches ("Reliable buffer overflow"; a 1000-char chunk is
// 2-3 partial bunches) and the host closed the connection every ~70 s (hand playtest 2026-10-24, the owner's save: a storage of
// 4165 items). A fixed send rate was not enough: a guest still loading the map confirms nothing for seconds (closed after 2 s).
//   PTNative_MsgToHost(localPcAddress, kind, data) -> bool      guest side, on its own PlayerController
//   PTNative_MsgToGuest(remotePcAddress, kind, data) -> bool    host side, on that guest's PlayerController
//   PTNative_MsgPoll(prefix) -> kind, data, fromAddress | nil   oldest message whose kind starts with prefix
//   PTNative_MsgStats() -> "sent=.. recv=.. chunks_out=.. chunks_in=.. dropped=.. inbox=.. queued=.. queued_max=.. waits=.."
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>
#include <Unreal/Hooks/Hooks.hpp>
#include <Unreal/UObject.hpp>
#include <Unreal/UObjectGlobals.hpp>
#include <Unreal/UFunction.hpp>
#include <Unreal/CoreUObject/UObject/Class.hpp>
#include <Unreal/FWeakObjectPtr.hpp>

#include <cstdlib>
#include <cstring>
#include <deque>
#include <map>
#include <string>
#include <utility>
#include <vector>

using namespace RC;
using namespace RC::Unreal;

namespace
{
constexpr size_t CHUNK = 1000;       // bytes per RPC
constexpr size_t MAX_MSG = 32 * 1024; // 33 chunks
constexpr size_t MAX_INBOX = 4096;
constexpr const wchar_t* MAGIC = L"PT1|";
constexpr const wchar_t* ACK = L"PT1A|";
// 48 chunks are at most ~150 partial bunches: under UE's 256, with room for the game's own RPCs on the same channel
constexpr long long WINDOW = 48;
// and at most this many go per frame and connection: a whole window in one frame (~48 KB) saturated the connection, and a
// saturated connection sends no actor updates and no move acks (the host stood still on the guest's screen, NOTES 2026-10-24 late)
constexpr long long PER_FRAME = 8;

struct Msg
{
    std::string kind, data;
    FWeakObjectPtr from;
};

UFunction* g_to_host{};
UFunction* g_to_guest{};
bool g_sending = false; // our own ProcessEvent calls pass through the pre-callback too
bool g_capture = true;
bool g_pace = true;
std::deque<Msg> g_inbox;
long long g_sent = 0, g_recv = 0, g_chunks_out = 0, g_chunks_in = 0, g_dropped = 0, g_queued_max = 0, g_waits = 0;

// One per PlayerController we talk through (the host's copy of a guest's controller, or the guest's own). Its RPC (out) is the
// one towards the other side: our chunks and our confirmations of theirs go on it.
struct Link
{
    FWeakObjectPtr pc; // a guest that left takes its queue with it
    UFunction* out{};
    std::deque<std::wstring> chunks;
    std::map<std::string, std::string> partial;
    long long sent = 0, acked = 0;    // our chunks on this link, and how many the other side confirmed
    long long got = 0, confirmed = 0; // their chunks we received, and how many we confirmed
    long long this_frame = 0;         // our chunks sent since the last tick
    bool waiting = false;
};
std::map<uintptr_t, Link> g_links;

auto resolve() -> bool
{
    if (!g_to_host) g_to_host = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/Engine.PlayerController:ServerExecRPC"));
    if (!g_to_guest) g_to_guest = UObjectGlobals::StaticFindObject<UFunction*>(nullptr, nullptr, STR("/Script/Engine.PlayerController:ClientMessage"));
    return g_to_host && g_to_guest;
}

auto valid_kind(std::string_view k) -> bool
{
    if (k.empty() || k.size() > 32) return false;
    for (char c : k)
        if (!(isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '_' || c == '-')) return false;
    return true;
}

// the link of a controller; a new controller at a freed address starts clean
auto link(UObject* pc) -> Link&
{
    auto& l = g_links[reinterpret_cast<uintptr_t>(pc)];
    if (l.pc.Get() != pc)
    {
        l = Link{};
        l.pc = pc;
    }
    return l;
}

// Both RPCs take the FString first, at offset 0; the rest of ClientMessage's parameters stay zero (Type None, lifetime 0).
auto rpc(UObject* pc, UFunction* fn, const std::wstring& s) -> void
{
    std::vector<unsigned char> parms(std::max<size_t>(fn->GetStructureSize(), sizeof(FString)), 0);
    auto* str = new (parms.data()) FString(s.c_str());
    g_sending = true;
    pc->ProcessEvent(fn, parms.data());
    g_sending = false;
    str->~FString();
}

auto pump(Link& l, UObject* pc) -> void
{
    while (!l.chunks.empty() && (!g_pace || (l.sent - l.acked < WINDOW && l.this_frame < PER_FRAME)))
    {
        rpc(pc, l.out, l.chunks.front());
        l.chunks.pop_front();
        ++l.sent;
        ++l.this_frame;
        ++g_chunks_out;
    }
    if (!l.chunks.empty() && !l.waiting) ++g_waits;
    l.waiting = !l.chunks.empty();
}

auto queued() -> long long
{
    long long n = 0;
    for (auto& [_, l] : g_links) n += static_cast<long long>(l.chunks.size());
    return n;
}

// every frame, on the game thread: confirm what came in, send what the window allows, forget links whose controller is gone
auto tick() -> void
{
    for (auto it = g_links.begin(); it != g_links.end();)
    {
        auto& l = it->second;
        auto* pc = l.pc.Get();
        if (!pc) { it = g_links.erase(it); continue; }
        l.this_frame = 0;
        if (l.out && l.got > l.confirmed)
        {
            rpc(pc, l.out, std::wstring(ACK) + std::to_wstring(l.got));
            l.confirmed = l.got;
        }
        if (l.out) pump(l, pc);
        ++it;
    }
}

auto send(UObject* pc, UFunction* fn, const std::string& kind, const std::string& data) -> bool
{
    if (!pc || !fn || !valid_kind(kind) || data.size() > MAX_MSG || data.find('\0') != std::string::npos) return false;
    auto& l = link(pc);
    l.out = fn;
    size_t pos = 0;
    do
    {
        auto part = data.substr(pos, CHUNK);
        pos += part.size();
        std::wstring s = MAGIC;
        s.append(kind.begin(), kind.end());
        s += pos < data.size() ? L"|m|" : L"|e|";
        for (unsigned char b : part) s += static_cast<wchar_t>(b);
        l.chunks.push_back(std::move(s));
    } while (pos < data.size());
    ++g_sent;
    g_queued_max = std::max(g_queued_max, queued());
    pump(l, pc); // what the window allows goes now: an intent still feels instant
    return true;
}

auto on_pre(Hook::TCallbackIterationData<void>& it, UObject* context, UFunction* function, void* parms) -> void
{
    if (g_sending || !g_capture || !parms || !function || (function != g_to_host && function != g_to_guest)) return;
    auto& chars = static_cast<FString*>(parms)->GetCharArray();
    const wchar_t* s = chars.GetData();
    size_t len = s ? wcslen(s) : 0;
    if (len >= 6 && wcsncmp(s, ACK, 5) == 0)
    {
        it.PreventOriginalFunctionCall();
        auto& l = link(context);
        l.acked = std::max(l.acked, static_cast<long long>(_wtoi64(s + 5)));
        return;
    }
    if (len < 8 || wcsncmp(s, MAGIC, 4) != 0) return;
    it.PreventOriginalFunctionCall();
    ++g_chunks_in;
    auto& l = link(context);
    if (!l.out) l.out = function == g_to_guest ? g_to_host : g_to_guest; // confirmed from tick, back towards the sender
    ++l.got;
    // PT1|<kind>|<m|e>|<bytes>
    std::wstring_view v(s + 4, len - 4);
    auto bar = v.find(L'|');
    if (bar == std::wstring_view::npos || bar + 3 > v.size() || v[bar + 2] != L'|') { ++g_dropped; return; }
    std::string kind(v.begin(), v.begin() + bar);
    bool last = v[bar + 1] == L'e';
    // Reassembly belongs to this controller's weak identity, just like its outbound queue.
    auto& buf = l.partial[kind];
    if (buf.size() > MAX_MSG) { buf.clear(); ++g_dropped; }
    for (auto c : v.substr(bar + 3)) buf += static_cast<char>(c & 0xFF);
    if (!last) return;
    if (g_inbox.size() >= MAX_INBOX) { g_inbox.pop_front(); ++g_dropped; }
    Msg message{kind, std::move(buf), {}};
    message.from = context;
    g_inbox.push_back(std::move(message));
    l.partial.erase(kind);
    ++g_recv;
}

auto ensure_hook() -> void
{
    static bool done = false;
    if (done || !resolve()) return;
    done = true;
    // test runs only: the scenario's mutation proves the checks need this layer
    if (auto m = std::getenv("PT_MUTATE"); m && std::string(m) == "nocapture") g_capture = false;
    if (auto m = std::getenv("PT_MUTATE"); m && std::string(m) == "nopace") g_pace = false; // every chunk at once, as before
    Hook::RegisterProcessEventPreCallback(on_pre, {false, false, STR("PacificTogether"), STR("Msg")});
    Hook::RegisterEngineTickPreCallback([](auto&, UEngine*, float, bool) { tick(); }, {false, true, STR("PacificTogether"), STR("MsgFlow")});
}

auto lua_send(const LuaMadeSimple::Lua& l, bool to_host) -> int
{
    ensure_hook();
    auto address = static_cast<uintptr_t>(l.get_integer());
    auto kind = std::string(l.get_string());
    auto data = std::string(l.get_string());
    l.set_bool(send(reinterpret_cast<UObject*>(address), to_host ? g_to_host : g_to_guest, kind, data));
    return 1;
}
} // namespace

auto pt_register_msg(const LuaMadeSimple::Lua& lua) -> void
{
    // registered at every Lua start; the hook goes in as soon as the UFunctions exist, so a guest's first message is caught
    ensure_hook();
    lua.register_function("PTNative_MsgToHost", [](const LuaMadeSimple::Lua& l) -> int { return lua_send(l, true); });
    lua.register_function("PTNative_MsgToGuest", [](const LuaMadeSimple::Lua& l) -> int { return lua_send(l, false); });
    lua.register_function("PTNative_MsgReset", [](const LuaMadeSimple::Lua&) -> int {
        g_inbox.clear();
        g_links.clear();
        return 0;
    });
    lua.register_function("PTNative_MsgPoll", [](const LuaMadeSimple::Lua& l) -> int {
        ensure_hook();
        auto prefix = std::string(l.get_string());
        for (auto it = g_inbox.begin(); it != g_inbox.end();)
        {
            auto* sender = it->from.Get();
            if (!sender)
            { it = g_inbox.erase(it); ++g_dropped; continue; }
            if (it->kind.compare(0, prefix.size(), prefix) != 0) { ++it; continue; }
            auto m = std::move(*it);
            g_inbox.erase(it);
            l.set_string(m.kind);
            l.set_string(m.data);
            l.set_integer(static_cast<int64_t>(reinterpret_cast<uintptr_t>(sender)));
            return 3;
        }
        return 0;
    });
    lua.register_function("PTNative_MsgStats", [](const LuaMadeSimple::Lua& l) -> int {
        auto s = "sent=" + std::to_string(g_sent) + " recv=" + std::to_string(g_recv) + " chunks_out=" + std::to_string(g_chunks_out) +
                 " chunks_in=" + std::to_string(g_chunks_in) + " dropped=" + std::to_string(g_dropped) + " inbox=" + std::to_string(g_inbox.size()) +
                 " queued=" + std::to_string(queued()) + " queued_max=" + std::to_string(g_queued_max) + " waits=" + std::to_string(g_waits);
        l.set_string(s);
        return 1;
    });
}
