// S7: while the guest guard is on, the game exe cannot create, change, delete or move files under Saved/SaveGames
// (saves, USERSETTINGS.sav) or Content/Bookmarks (MakeBookmark writes the whole world there, next to the game files).
// Q9 (D16): the game never starts CrashReportClient and never initialises Sentry (the game's own settings may turn it on
// before any Lua runs). Every crash folder the engine writes gets our marker file, whether or not CrashReportClient exists.
// All of it patches the exe's imports: UE's file, process and Sentry calls all go through them (monolithic shipping exe).
#include <DynamicOutput/DynamicOutput.hpp>
#include <LuaMadeSimple/LuaMadeSimple.hpp>

#define NOMINMAX
#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

#include <atomic>
#include <cstdlib>
#include <string>

using namespace RC;

auto pt_blackbox_dump() -> std::string; // blackbox.cpp

namespace pt_guard
{
    static std::atomic<bool> g_on{};
    static std::atomic<int> g_blocked{}, g_sentry_blocked{};
    static bool g_installed{};
    // test runs only: show that the marker and Sentry checks can fail
    static bool g_test_no_marker{}, g_test_allow_sentry{};
    static std::string g_crash_info; // set from Lua on the game thread, read only while crashing
    static std::wstring g_marked;    // crash folder that already has our marker

    static decltype(&CreateFileW) real_create_file{};
    static decltype(&DeleteFileW) real_delete_file{};
    static decltype(&MoveFileW) real_move_file{};
    static decltype(&CreateProcessW) real_create_process{};
    using SentryInit = int (*)(void* options);
    static SentryInit real_sentry_init{};

    static auto lower(LPCWSTR s) -> std::wstring
    {
        std::wstring r = s ? s : L"";
        for (auto& c : r) c = c == L'/' ? L'\\' : towlower(c);
        return r;
    }

    static auto guarded(LPCWSTR path) -> bool
    {
        if (!g_on || !path) return false;
        auto p = lower(path);
        return p.find(L"\\saved\\savegames\\") != std::wstring::npos || p.find(L"\\content\\bookmarks\\") != std::wstring::npos;
    }

    static auto refuse(const wchar_t* what, LPCWSTR path) -> void
    {
        ++g_blocked;
        SetLastError(ERROR_ACCESS_DENIED);
        Output::send<LogLevel::Verbose>(STR("[PacificTogether] PT|safety guard refused {} {}\n"), what, path);
    }

    // the engine writes the minidump and CrashContext.runtime-xml into Saved/Crashes/<crash>/ before it would start CrashReportClient
    static auto write_marker(LPCWSTR name) -> void
    {
        auto p = lower(name);
        auto at = p.find(L"\\saved\\crashes\\");
        if (at == std::wstring::npos || g_test_no_marker) return;
        auto end = p.find(L'\\', at + 15);
        if (end == std::wstring::npos) return;
        auto dir = std::wstring(name, end);
        if (dir == g_marked) return;
        g_marked = dir;
        HANDLE f = real_create_file((dir + L"\\PacificTogether-crash.txt").c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) return;
        std::string text = "Pacific Together crash marker\r\nCrash upload: off (the mod never starts CrashReportClient or Sentry)\r\n" + g_crash_info + "\r\n" +
                           pt_blackbox_dump();
        DWORD n{};
        WriteFile(f, text.data(), static_cast<DWORD>(text.size()), &n, nullptr);
        CloseHandle(f);
    }

    static auto WINAPI create_file(LPCWSTR name, DWORD access, DWORD share, LPSECURITY_ATTRIBUTES sa, DWORD disposition, DWORD flags, HANDLE tmpl) -> HANDLE
    {
        bool writes = (access & (GENERIC_WRITE | GENERIC_ALL | FILE_WRITE_DATA | FILE_APPEND_DATA | DELETE)) || disposition != OPEN_EXISTING;
        if (writes && name) write_marker(name);
        if (writes && guarded(name))
        {
            refuse(STR("CreateFileW"), name);
            return INVALID_HANDLE_VALUE;
        }
        return real_create_file(name, access, share, sa, disposition, flags, tmpl);
    }

    static auto WINAPI delete_file(LPCWSTR name) -> BOOL
    {
        if (guarded(name))
        {
            refuse(STR("DeleteFileW"), name);
            return FALSE;
        }
        return real_delete_file(name);
    }

    static auto WINAPI move_file(LPCWSTR from, LPCWSTR to) -> BOOL
    {
        if (guarded(from) || guarded(to))
        {
            refuse(STR("MoveFileW"), guarded(to) ? to : from);
            return FALSE;
        }
        return real_move_file(from, to);
    }

    static auto WINAPI create_process(LPCWSTR app, LPWSTR cmd, LPSECURITY_ATTRIBUTES pa, LPSECURITY_ATTRIBUTES ta, BOOL inherit, DWORD flags, LPVOID env,
                                      LPCWSTR dir, LPSTARTUPINFOW si, LPPROCESS_INFORMATION pi) -> BOOL
    {
        if ((lower(app) + L" " + lower(cmd)).find(L"crashreportclient") != std::wstring::npos)
        {
            SetLastError(ERROR_FILE_NOT_FOUND);
            return FALSE;
        }
        return real_create_process(app, cmd, pa, ta, inherit, flags, env, dir, si, pi);
    }

    // sentry_init takes ownership of the options and returns 0 on success; refusing leaks one small options object
    static auto sentry_init(void* options) -> int
    {
        if (g_test_allow_sentry) return real_sentry_init(options);
        ++g_sentry_blocked;
        Output::send<LogLevel::Verbose>(STR("[PacificTogether] PT|safety guard refused sentry_init\n"));
        return 1;
    }

    template <typename Fn>
    static auto patch(IMAGE_THUNK_DATA* slot, Fn* real, Fn mine) -> void
    {
        DWORD old{};
        VirtualProtect(&slot->u1.Function, sizeof(void*), PAGE_READWRITE, &old);
        *real = reinterpret_cast<Fn>(slot->u1.Function);
        slot->u1.Function = reinterpret_cast<ULONG_PTR>(mine);
        VirtualProtect(&slot->u1.Function, sizeof(void*), old, &old);
    }

    auto install() -> void
    {
        auto base = reinterpret_cast<uint8_t*>(GetModuleHandleW(nullptr));
        auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + reinterpret_cast<IMAGE_DOS_HEADER*>(base)->e_lfanew);
        auto& dirs = nt->OptionalHeader.DataDirectory;
        int found = 0;
        auto scan = [&](const char* dll, DWORD names_rva, DWORD slots_rva) {
            bool sentry = !_stricmp(dll, "sentry.dll");
            if (!sentry && _stricmp(dll, "KERNEL32.dll")) return;
            auto names = reinterpret_cast<IMAGE_THUNK_DATA*>(base + names_rva);
            auto slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base + slots_rva);
            for (; names->u1.AddressOfData; ++names, ++slots)
            {
                if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
                auto fn = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData)->Name;
                if (sentry) { if (!strcmp(fn, "sentry_init")) patch(slots, &real_sentry_init, &sentry_init), ++found; }
                else if (!strcmp(fn, "CreateFileW")) patch(slots, &real_create_file, &create_file), ++found;
                else if (!strcmp(fn, "DeleteFileW")) patch(slots, &real_delete_file, &delete_file), ++found;
                else if (!strcmp(fn, "MoveFileW")) patch(slots, &real_move_file, &move_file), ++found;
                else if (!strcmp(fn, "CreateProcessW")) patch(slots, &real_create_process, &create_process), ++found;
            }
        };
        for (auto imp = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + dirs[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress); imp->Name; ++imp)
            scan(reinterpret_cast<char*>(base + imp->Name), imp->OriginalFirstThunk, imp->FirstThunk);
        // sentry.dll is delay-loaded: its slots hold the loader's thunk until the first call, so ours is called instead
        if (dirs[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].VirtualAddress)
            for (auto d = reinterpret_cast<IMAGE_DELAYLOAD_DESCRIPTOR*>(base + dirs[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].VirtualAddress); d->DllNameRVA; ++d)
                scan(reinterpret_cast<char*>(base + d->DllNameRVA), d->ImportNameTableRVA, d->ImportAddressTableRVA);
        g_installed = found == 5;
        Output::send<LogLevel::Verbose>(STR("[PacificTogether] PT|native guard imports patched={}/5\n"), found);
    }

    auto register_lua(const LuaMadeSimple::Lua& l) -> void
    {
        // PTNative_SetSaveGuard(bool): refuse writes under Saved/SaveGames and Content/Bookmarks while on. Returns whether the imports are patched.
        l.register_function("PTNative_SetSaveGuard", [](const LuaMadeSimple::Lua& l) -> int {
            g_on = l.get_bool();
            l.set_bool(g_installed);
            return 1;
        });
        // PTNative_SaveGuardBlocked() -> number of refused file calls since start
        l.register_function("PTNative_SaveGuardBlocked", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_integer(g_blocked);
            return 1;
        });
        // PTNative_SentryInitBlocked() -> number of refused sentry_init calls since start
        l.register_function("PTNative_SentryInitBlocked", [](const LuaMadeSimple::Lua& l) -> int {
            l.set_integer(g_sentry_blocked);
            return 1;
        });
        // PTNative_SetCrashInfo(string): one line for the crash marker (mod version, session state)
        l.register_function("PTNative_SetCrashInfo", [](const LuaMadeSimple::Lua& l) -> int {
            g_crash_info = std::string(l.get_string());
            return 0;
        });
#ifndef PT_PUBLIC // T08
        if (!std::getenv("PT_SCENARIO")) return;
        // test runs only: PTNative_TestCrash(noMarker) crashes the game on purpose to check what the crash leaves behind
        l.register_function("PTNative_TestCrash", [](const LuaMadeSimple::Lua& l) -> int {
            g_test_no_marker = l.is_bool() && l.get_bool();
            *static_cast<volatile int*>(nullptr) = 0;
            return 0;
        });
        // test runs only: PTNative_TestAllowSentry(bool) lets sentry_init through (tests point the DSN at a dead local address first)
        l.register_function("PTNative_TestAllowSentry", [](const LuaMadeSimple::Lua& l) -> int {
            g_test_allow_sentry = l.get_bool();
            return 0;
        });
#endif
    }
} // namespace pt_guard
