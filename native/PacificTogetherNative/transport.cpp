// X5: tunnel UE's IpNetDriver traffic. The game exe's IAT entries for ws2_32 sendto/recvfrom are swapped: a sendto to a
// fake peer 10.77.x.y goes over the link (loopback UDP socket or Steam messages) instead of the wire, and packets from
// the link come out of the game socket's recvfrom with the peer's fake address. Each frame carries the UE source and
// destination ports, so the far side hands it to the socket bound to that port. Everything runs inside the engine's own
// socket calls (game thread), no extra thread. Shipping UE has no NetEmulation, so lag/loss emulation lives here too.
#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <winsock2.h>
#include <ws2tcpip.h>
#include <Windows.h>

#include <algorithm>
#include <atomic>
#include <deque>
#include <mutex>
#include <map>
#include <string>
#include <random>
#include <unordered_map>
#include <vector>

#include "transport.hpp"

using RC::LuaMadeSimple::Lua;

using SendToFn = int(WSAAPI*)(SOCKET, const char*, int, int, const sockaddr*, int);
using RecvFromFn = int(WSAAPI*)(SOCKET, char*, int, int, sockaddr*, int*);
static SendToFn g_sendto{};
static RecvFromFn g_recvfrom{};

enum class Link { None, Udp, Steam };
struct Packet
{
    uint64_t key;
    uint16_t src, dst;
    std::vector<uint8_t> data;
    uint64_t at; // inbox: arrival, outbox: due time (ms)
};

static constexpr uint32_t FAKE_NET = 0x0A4D0000, FAKE_MASK = 0xFFFF0000; // 10.77.0.0/16
static constexpr size_t INBOX_MAX = 4096;
static constexpr uint64_t INBOX_TTL_MS = 2000;

static std::mutex g_mx;
static std::atomic<Link> g_link{Link::None};
static SOCKET g_udp = INVALID_SOCKET;
static int g_channel{};
static std::unordered_map<uint32_t, uint64_t> g_fake_to_key;
static std::unordered_map<uint64_t, uint32_t> g_key_to_fake;
static uint32_t g_next_fake = 0x0A4D0101; // 10.77.1.1+: peers that reach us first; Lua maps 10.77.0.x to known peers
static std::deque<Packet> g_inbox, g_outbox;
static uint32_t g_lag_ms{};
static double g_loss_pct{};
static std::mt19937 g_rng{std::random_device{}()};
static struct { uint64_t out, out_bytes, in, in_bytes, dropped, unmapped, expired, link_errors, probes, pongs, rtt, rtt_avg, rtt_max, rtt_min; } g_stats{};
struct Motion { uint64_t key, sequence; std::string data; };
static std::map<std::string, Motion> g_motion_out, g_motion_in;
static uint64_t g_motion_sequence{}, g_motion_sent{}, g_motion_received{}, g_motion_replaced{};
static uint64_t g_last_probe{};
// frames with source and destination port 0 are the tunnel's own probes: [type 1 ping | 2 pong][u64 send time ms]
static constexpr uint8_t PROBE_PING = 1, PROBE_PONG = 2;
static constexpr uint64_t PROBE_MS = 1000;

static auto ip_str(uint32_t ip) -> std::string
{
    char b[16];
    snprintf(b, sizeof(b), "%u.%u.%u.%u", ip >> 24, (ip >> 16) & 255, (ip >> 8) & 255, ip & 255);
    return b;
}
static auto udp_key(uint32_t ip, uint16_t port) -> uint64_t { return (uint64_t(ip) << 16) | port; }
static auto local_port(SOCKET s) -> uint16_t
{
    sockaddr_in a{};
    int n = sizeof(a);
    return getsockname(s, reinterpret_cast<sockaddr*>(&a), &n) == 0 && a.sin_family == AF_INET ? ntohs(a.sin_port) : 0;
}

static auto link_send(const Packet& p) -> void
{
    std::vector<uint8_t> f(4 + p.data.size());
    f[0] = uint8_t(p.src >> 8), f[1] = uint8_t(p.src), f[2] = uint8_t(p.dst >> 8), f[3] = uint8_t(p.dst);
    std::copy(p.data.begin(), p.data.end(), f.begin() + 4);
    bool ok;
    if (g_link == Link::Udp)
    {
        sockaddr_in to{};
        to.sin_family = AF_INET;
        to.sin_addr.s_addr = htonl(uint32_t(p.key >> 16));
        to.sin_port = htons(uint16_t(p.key));
        ok = sendto(g_udp, reinterpret_cast<const char*>(f.data()), int(f.size()), 0, reinterpret_cast<sockaddr*>(&to), sizeof(to)) >= 0;
    }
    else
    {
        // k_nSteamNetworkingSend_Unreliable | NoNagle | AutoRestartBrokenSession
        ok = steam_send(p.key, g_channel, f.data(), uint32_t(f.size()), 1 | 32) == 1;
    }
    if (!ok) ++g_stats.link_errors;
    else if (p.dst) ++g_stats.out, g_stats.out_bytes += p.data.size();
}

// everything leaves through here, so the lag and loss emulation also applies to the probes
static auto queue_send(uint64_t key, uint16_t src, uint16_t dst, const uint8_t* data, size_t size) -> void
{
    if (g_loss_pct > 0 && std::uniform_real_distribution<double>(0, 100)(g_rng) < g_loss_pct) return void(++g_stats.dropped);
    Packet p{key, src, dst, {data, data + size}, GetTickCount64() + g_lag_ms};
    if (g_lag_ms) g_outbox.push_back(std::move(p));
    else link_send(p);
}

static auto send_probe(uint64_t key, uint8_t type, uint64_t t) -> void
{
    uint8_t b[9] = {type};
    memcpy(b + 1, &t, sizeof(t));
    queue_send(key, 0, 0, b, sizeof(b));
}

// a frame from the link: give its sender a fake address, queue it for the game socket bound to its destination port
static auto deliver(uint64_t key, const uint8_t* data, uint32_t size) -> void
{
    if (size < 4) return;
    const bool motion = size >= 5 && data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 0 && data[4] == 3;
    if (motion && !g_key_to_fake.contains(key)) return;
    if (!g_key_to_fake.contains(key))
    {
        uint32_t fake = g_next_fake++;
        g_key_to_fake[key] = fake, g_fake_to_key[fake] = key;
        pt_log("PT|native tunnel new peer key=%llu fake=%s", key, ip_str(fake).c_str());
    }
    if (data[0] == 0 && data[1] == 0 && data[2] == 0 && data[3] == 0 && size >= 14 && data[4] == 3)
    {
        const size_t length = data[13];
        if (g_key_to_fake.size() != 1 || length == 0 || length > 32 || size < 14 + length || size > 1150) return;
        std::string kind(reinterpret_cast<const char*>(data + 14), length);
        if (!kind.starts_with("g.motion.") && !kind.starts_with("t.motion.")) return;
        if (!g_motion_in.contains(kind) && g_motion_in.size() >= 64) return;
        uint64_t sequence{}; memcpy(&sequence, data + 5, sizeof(sequence));
        std::string payload(reinterpret_cast<const char*>(data + 14 + length), size - 14 - length);
        auto previous = g_motion_in.find(kind);
        if (previous != g_motion_in.end())
        {
            auto& old = previous->second;
            if (old.data.substr(0, old.data.find('|')) == payload.substr(0, payload.find('|')) && old.sequence >= sequence) return;
            ++g_motion_replaced;
        }
        g_motion_in[kind] = {key, sequence, std::move(payload)};
        ++g_motion_received;
        return;
    }
    if (data[2] == 0 && data[3] == 0)
    {
        uint64_t t{};
        if (size < 13) return;
        memcpy(&t, data + 5, sizeof(t));
        if (data[4] == PROBE_PING) send_probe(key, PROBE_PONG, t);
        if (data[4] != PROBE_PONG) return;
        uint64_t rtt = GetTickCount64() - t;
        g_stats.rtt = rtt, g_stats.rtt_max = std::max(g_stats.rtt_max, rtt), g_stats.rtt_min = g_stats.pongs ? std::min(g_stats.rtt_min, rtt) : rtt;
        g_stats.rtt_avg = g_stats.pongs++ ? (g_stats.rtt_avg * 7 + rtt) / 8 : rtt;
        return;
    }
    if (g_inbox.size() >= INBOX_MAX) g_inbox.pop_front(), ++g_stats.expired;
    g_inbox.push_back({key, uint16_t(data[0] << 8 | data[1]), uint16_t(data[2] << 8 | data[3]), {data + 4, data + size}, GetTickCount64()});
}

// caller holds g_mx: send what the lag emulation released, pull everything waiting on the link
static auto pump() -> void
{
    uint64_t now = GetTickCount64();
    for (auto& [kind, motion] : g_motion_out)
    {
        std::vector<uint8_t> data(10 + kind.size() + motion.data.size());
        data[0] = 3; memcpy(data.data() + 1, &motion.sequence, sizeof(motion.sequence));
        data[9] = static_cast<uint8_t>(kind.size());
        memcpy(data.data() + 10, kind.data(), kind.size());
        memcpy(data.data() + 10 + kind.size(), motion.data.data(), motion.data.size());
        queue_send(motion.key, 0, 0, data.data(), data.size());
        ++g_motion_sent;
    }
    g_motion_out.clear();
    while (!g_outbox.empty() && g_outbox.front().at <= now) link_send(g_outbox.front()), g_outbox.pop_front();
    while (!g_inbox.empty() && now - g_inbox.front().at > INBOX_TTL_MS) g_inbox.pop_front(), ++g_stats.expired;
    // round trip and keep-alive per peer (Steam messages have no close notification)
    if (now - g_last_probe >= PROBE_MS)
    {
        g_last_probe = now;
        for (auto& [key, fake] : g_key_to_fake) send_probe(key, PROBE_PING, now), ++g_stats.probes;
    }
    if (g_link == Link::Udp)
    {
        static uint8_t buf[65536];
        sockaddr_in from{};
        int fl = sizeof(from), n;
        while ((n = recvfrom(g_udp, reinterpret_cast<char*>(buf), sizeof(buf), 0, reinterpret_cast<sockaddr*>(&from), &fl)) > 0)
        {
            deliver(udp_key(ntohl(from.sin_addr.s_addr), ntohs(from.sin_port)), buf, uint32_t(n));
            fl = sizeof(from);
        }
    }
    else
    {
        steam_receive(g_channel, deliver);
    }
}

static auto WSAAPI hook_sendto(SOCKET s, const char* buf, int len, int flags, const sockaddr* to, int tolen) -> int
{
    auto in = reinterpret_cast<const sockaddr_in*>(to);
    if (g_link == Link::None || !to || tolen < int(sizeof(sockaddr_in)) || to->sa_family != AF_INET ||
        (ntohl(in->sin_addr.s_addr) & FAKE_MASK) != FAKE_NET)
        return g_sendto(s, buf, len, flags, to, tolen);
    std::lock_guard lock(g_mx);
    auto it = g_fake_to_key.find(ntohl(in->sin_addr.s_addr));
    // like UDP: an unknown or dropped destination still "sends"
    if (it == g_fake_to_key.end()) return ++g_stats.unmapped, len;
    queue_send(it->second, local_port(s), ntohs(in->sin_port), reinterpret_cast<const uint8_t*>(buf), size_t(len));
    return len;
}

static auto WSAAPI hook_recvfrom(SOCKET s, char* buf, int len, int flags, sockaddr* from, int* fromlen) -> int
{
    if (g_link != Link::None)
    {
        std::lock_guard lock(g_mx);
        pump();
        if (!g_inbox.empty())
        {
            uint16_t port = local_port(s);
            auto it = std::find_if(g_inbox.begin(), g_inbox.end(), [port](const Packet& p) { return p.dst == port; });
            if (it != g_inbox.end())
            {
                int n = int(std::min<size_t>(it->data.size(), size_t(std::max(len, 0))));
                memcpy(buf, it->data.data(), n);
                if (from && fromlen && *fromlen >= int(sizeof(sockaddr_in)))
                {
                    sockaddr_in a{};
                    a.sin_family = AF_INET;
                    a.sin_port = htons(it->src);
                    a.sin_addr.s_addr = htonl(g_key_to_fake[it->key]);
                    memcpy(from, &a, sizeof(a));
                    *fromlen = sizeof(a);
                }
                ++g_stats.in, g_stats.in_bytes += n;
                g_inbox.erase(it);
                return n;
            }
        }
    }
    return g_recvfrom(s, buf, len, flags, from, fromlen);
}

// swaps every slot of the game exe's import table that holds `real`; our DLL's own socket calls keep the real functions
static auto patch_iat(void* real, void* hook) -> int
{
    auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
    auto dir = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT];
    int n = 0;
    for (auto d = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dir.VirtualAddress); d->Name; ++d)
    {
        for (auto t = reinterpret_cast<IMAGE_THUNK_DATA*>(base + d->FirstThunk); t->u1.Function; ++t)
        {
            if (reinterpret_cast<void*>(t->u1.Function) != real) continue;
            DWORD old{};
            if (!VirtualProtect(&t->u1.Function, sizeof(void*), PAGE_READWRITE, &old)) continue;
            t->u1.Function = reinterpret_cast<ULONG_PTR>(hook);
            VirtualProtect(&t->u1.Function, sizeof(void*), old, &old);
            ++n;
        }
    }
    return n;
}

static auto install_hooks() -> bool
{
    if (g_sendto) return true;
    auto ws = GetModuleHandleW(L"ws2_32.dll");
    auto real_send = reinterpret_cast<SendToFn>(GetProcAddress(ws, "sendto"));
    auto real_recv = reinterpret_cast<RecvFromFn>(GetProcAddress(ws, "recvfrom"));
    g_sendto = real_send, g_recvfrom = real_recv;
    int ns = patch_iat(reinterpret_cast<void*>(real_send), reinterpret_cast<void*>(&hook_sendto));
    int nr = patch_iat(reinterpret_cast<void*>(real_recv), reinterpret_cast<void*>(&hook_recvfrom));
    pt_log("PT|native tunnel hooks sendto=%d recvfrom=%d", ns, nr);
    if (ns && nr) return true;
    pt_log("PT|error native tunnel hooks not installed");
    return false;
}

// shortcut: loopback only (no firewall prompt), for tests; peers on other machines use the Steam link
static auto open_udp(int port) -> bool
{
    std::lock_guard lock(g_mx);
    if (g_udp != INVALID_SOCKET) closesocket(g_udp);
    g_udp = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    sockaddr_in a{};
    a.sin_family = AF_INET;
    a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    a.sin_port = htons(uint16_t(port));
    u_long nonblock = 1;
    int rcv = 1 << 20;
    setsockopt(g_udp, SOL_SOCKET, SO_RCVBUF, reinterpret_cast<const char*>(&rcv), sizeof(rcv));
    if (g_udp == INVALID_SOCKET || bind(g_udp, reinterpret_cast<sockaddr*>(&a), sizeof(a)) != 0 || ioctlsocket(g_udp, FIONBIO, &nonblock) != 0)
    {
        pt_log("PT|error native tunnel udp bind 127.0.0.1:%d failed wsa=%d", port, WSAGetLastError());
        return false;
    }
    pt_log("PT|native tunnel udp link on 127.0.0.1:%u", local_port(g_udp));
    g_link = Link::Udp;
    return true;
}

static auto stats() -> std::string
{
    std::lock_guard lock(g_mx);
    char b[600];
    snprintf(b, sizeof(b), "link=%s out=%llu outBytes=%llu in=%llu inBytes=%llu dropped=%llu unmapped=%llu expired=%llu linkErrors=%llu probes=%llu pongs=%llu rtt=%llu rttAvg=%llu rttMax=%llu rttMin=%llu peers=%zu inbox=%zu delayed=%zu lag=%u loss=%.1f",
             g_link == Link::Udp ? "udp" : g_link == Link::Steam ? "steam" : "none", g_stats.out, g_stats.out_bytes, g_stats.in, g_stats.in_bytes,
             g_stats.dropped, g_stats.unmapped, g_stats.expired, g_stats.link_errors, g_stats.probes,
             g_stats.pongs, g_stats.rtt, g_stats.rtt_avg, g_stats.rtt_max, g_stats.rtt_min, g_key_to_fake.size(), g_inbox.size(), g_outbox.size(), g_lag_ms, g_loss_pct);
    return b;
}

auto transport_register(const Lua& lua) -> void
{
    // Optional datagrams on the existing two-player link; no socket, port or PT1/PT1A change.
    lua.register_function("PTNative_TunnelMotionSend", [](const Lua& l) -> int {
        auto kind = lua_str_arg(l), data = lua_str_arg(l);
        std::lock_guard lock(g_mx);
        const bool ok = g_link != Link::None && g_key_to_fake.size() == 1 && data.size() <= 1050 && kind.size() <= 32 &&
            (kind.starts_with("g.motion.") || kind.starts_with("t.motion."));
        if (ok)
        {
            if (!g_motion_out.contains(kind) && g_motion_out.size() >= 64) { l.set_bool(false); return 1; }
            if (g_motion_out.contains(kind)) ++g_motion_replaced;
            g_motion_out[kind] = {g_key_to_fake.begin()->first, ++g_motion_sequence, std::move(data)};
        }
        l.set_bool(ok); return 1;
    });
    lua.register_function("PTNative_TunnelMotionPoll", [](const Lua& l) -> int {
        auto prefix = lua_str_arg(l);
        std::lock_guard lock(g_mx);
        if (g_link == Link::None || g_key_to_fake.size() != 1) return 0;
        pump();
        for (auto it = g_motion_in.begin(); it != g_motion_in.end(); ++it)
        {
            if (!it->first.starts_with(prefix)) continue;
            l.set_string(it->first); l.set_string(it->second.data); l.set_integer(static_cast<int64_t>(it->second.sequence));
            g_motion_in.erase(it); return 3;
        }
        return 0;
    });
    lua.register_function("PTNative_TunnelMotionReset", [](const Lua&) -> int {
        std::lock_guard lock(g_mx); g_motion_in.clear(); g_motion_out.clear(); return 0;
    });
    lua.register_function("PTNative_TunnelMotionStats", [](const Lua& l) -> int {
        std::lock_guard lock(g_mx);
        l.set_string("sent=" + std::to_string(g_motion_sent) + " received=" + std::to_string(g_motion_received) + " replaced=" + std::to_string(g_motion_replaced));
        return 1;
    });
    // PTNative_TunnelUdp(port): link = loopback UDP socket on 127.0.0.1:port (0 = any free port); turns the tunnel on
    lua.register_function("PTNative_TunnelUdp", [](const Lua& l) -> int {
        int port = l.get_stack_size() >= 1 && l.is_number() ? int(l.get_number()) : 0;
        l.set_bool(install_hooks() && open_udp(port));
        return 1;
    });
    // PTNative_TunnelSteam(channel): link = ISteamNetworkingMessages on that channel (needs PTNative_SteamEnable(true))
    lua.register_function("PTNative_TunnelSteam", [](const Lua& l) -> int {
        int channel = l.get_stack_size() >= 1 && l.is_number() ? int(l.get_number()) : 0;
        bool ok = install_hooks();
        if (ok)
        {
            std::lock_guard lock(g_mx);
            g_channel = channel, g_link = Link::Steam;
            pt_log("PT|native tunnel steam link channel=%d", channel);
        }
        l.set_bool(ok);
        return 1;
    });
    // PTNative_TunnelPeer("10.77.0.1", "127.0.0.1:8811" | "steam:<steamid64>"): UE traffic to the fake address goes to that peer
    lua.register_function("PTNative_TunnelPeer", [](const Lua& l) -> int {
        auto fake_s = lua_str_arg(l), peer = lua_str_arg(l);
        in_addr fa{}, pa{};
        uint64_t key = 0;
        auto colon = peer.rfind(':');
        if (peer.starts_with("steam:")) key = strtoull(peer.c_str() + 6, nullptr, 10);
        else if (colon != std::string::npos && inet_pton(AF_INET, peer.substr(0, colon).c_str(), &pa) == 1)
            key = udp_key(ntohl(pa.s_addr), uint16_t(atoi(peer.c_str() + colon + 1)));
        bool ok = key && inet_pton(AF_INET, fake_s.c_str(), &fa) == 1 && (ntohl(fa.s_addr) & FAKE_MASK) == FAKE_NET;
        if (ok)
        {
            std::lock_guard lock(g_mx);
            uint32_t fake = ntohl(fa.s_addr);
            if (auto old = g_fake_to_key.find(fake); old != g_fake_to_key.end()) g_key_to_fake.erase(old->second);
            g_fake_to_key[fake] = key, g_key_to_fake[key] = fake;
        }
        pt_log("PT|native tunnel peer %s -> %s ok=%d", fake_s.c_str(), peer.c_str(), ok);
        l.set_bool(ok);
        return 1;
    });
    // PTNative_TunnelEmulate(lagMs, lossPercent): delay and drop our outgoing tunnel packets (both sides set it, like PktLag/PktLoss)
    lua.register_function("PTNative_TunnelEmulate", [](const Lua& l) -> int {
        double lag = l.get_stack_size() >= 1 && l.is_number() ? l.get_number() : 0;
        double loss = l.get_stack_size() >= 1 && l.is_number() ? l.get_number() : 0;
        std::lock_guard lock(g_mx);
        g_lag_ms = uint32_t(std::max(lag, 0.0)), g_loss_pct = std::clamp(loss, 0.0, 100.0);
        pt_log("PT|native tunnel emulate lag=%u loss=%.1f", g_lag_ms, g_loss_pct);
        return 0;
    });
    lua.register_function("PTNative_TunnelStats", [](const Lua& l) -> int {
        l.set_string(stats());
        return 1;
    });
}
