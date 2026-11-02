# Game MCP (`pacific-game`)

Explore running test games through Lua, reflection, actions, state comparisons, traces, screenshots and logs.
The server uses the [live console](TESTING.md#live-console). Test copies only. Convert findings into scenario assertions
and mutations before treating them as gameplay proof.

## Setup after a clone

- Python 3.9+ on PATH as `python`. Standard library only, nothing to install.
- A test pair (`tools\setup-test.ps1`, `docs/DEVELOPING.md`, "Test copies and tests"). Every tool refuses a root that is
  not `<root>\client1\PenDriverPro` and anything under the Steam install or `%LOCALAPPDATA%\PenDriverPro`.
- `watch` needs the native mod with `native/PacificTogetherNative/trace.cpp`: build it once (or after changing it) with
  `tools\build-native.cmd` (Epic/GitHub steps in `docs/DEVELOPING.md`, "Clone and build") or `tools\build-mod-fast.ps1` in a
  worktree. Stop games using the checkout's DLL before rebuilding. Other tools can use a matching prebuilt DLL;
  normal mod setup still requires the native layer.
- `xref` needs `local/atlas` (git-ignored, game-derived; `docs/research/game-atlas.md`). Without it the tool says so;
  ask the owner for the folder or rebuild it as described there.
- Claude Code reads `.mcp.json` at the repo root (server `pacific-game`, `python tools/gamemcp/server.py`; the server finds
  the repo from its own file path, the working directory does not matter). Approve the project server once, and
  **start a new Claude Code session** after cloning or pulling: servers are loaded at session start.
- Check without an agent: `python tools/gamemcp/selftest.py --root C:/PTLanes/probe --port 7801` (starts real games).

The project's `.mcp.json` also includes the read-only Co-op Anything playbook server:
`python coop-anything/tools/mcp/coop_mcp.py` (requires PyYAML). The game server uses only Python's standard library.
Pass the actual isolated pair path as `root` when it differs from `C:/PacificTogetherTest`; registering a server
does not create a test pair or rebuild the native DLL.

## Tools

Inspection/action tools use `root` (default `C:/PacificTogetherTest`) and `side` (`host` = client1, `client` = client2,
default host). Session and comparison tools operate on the pair. Large replies are capped or saved to disk.
Server errors return as tool errors; unsafe live game-object access can still crash the game.

| Tool | What it does | Example |
|---|---|---|
| `session_start` | runs `run-test.ps1 -Scenario repl` detached, waits until host (and client) answer | `root=C:/PTLanes/probe port=7801 players=2 headless=true`; `fixture=zone`; `map=/Game/Maps/RunProto/RB_Garage` |
| `session_status` / `session_stop` | state of both sides / stop both, wait for the runner, kill only the runner it started if it hangs | |
| `eval` | Lua through the repl file protocol (same files and ids as `repl.ps1`); Lua errors are tool errors | `lua="return state()"`, `lua="out(first('BP_PlayerCarNew_C'):GetFullName())"` |
| `find` | live objects of a class in the current world, full names | `class_name=BP_PlayerCarNew_C limit=20` |
| `describe` | properties with current values and functions with parameters, own class first then parents | `target=<full name from find>` or a class name |
| `call` | call a UFunction with numbers, strings, bools, `{"obj": "<path>"}` | `object_path=<car> function=K2_GetActorLocation args_json=[]` |
| `watch` | records ProcessEvent calls whose function name contains the filter (`a\|b` or a list), with the calling object, for N seconds | `filter=Character:Jump seconds=5` while another `eval` acts. The filter matches the whole function path, so a bare `Character` also catches `/Game/Characters/...` animation functions: include the class or function. Only calls through ProcessEvent are seen (Blueprint-to-Blueprint calls inside the script VM are not) and argument values only with `args=true` (`results=true` adds return/out values), see [observe tools](gamemcp/observe.md) |
| `screenshot` | `HighResShot` in a non-headless session, returns the PNG path | open it with an image reader |
| `logs` | tail of the copy's `UE4SS.log` (`game_log=true`: `PenDriverPro.log`), regex filter | `pattern="PT\|" tail=50` |
| `watch_property`, `net_stats`, `screenshot_burst`, `events` | observe and measure: property change log, network numbers, screenshot series, event timeline | [observe tools](gamemcp/observe.md) |
| `xref` | `local/atlas/xref.py` callers / callees / class / find | `command=callers name=SaveGame` |

State and sync (`snapshot`, `compare`, `diff_snapshots`, `fixture_save`, and `session_start fixtures_dir=`): [state tools](gamemcp/state.md).

**Actions** (`teleport`, `move_to`, `jump`, `interact`, `enter_car`, `drive`, `give_item`, `pickup`, `journal`, `promote`, ...): make a
player walk, interact, drive and handle items with one call each, through the game's own input and interaction paths, and turn
the session into a scenario skeleton: [action tools](gamemcp/actions.md). `session_start` also takes `fixtures_dir` (worktrees find the
main checkout's `local/fixtures` themselves).

`session_start` waits for a free game slot (`PT_SLOTS`) and takes 15-60 s headless, longer in a queue. Use your own root
and port (`docs/TESTING.md`, "Parallel lanes"): one session per root, a second `session_start` on a busy root is refused.

## Limits

- `watch` sees only calls that go through the engine's `ProcessEvent` (native code, Lua, delegates, replication entry
  points). Blueprint-to-Blueprint calls inside the script VM are not seen, and argument values are recorded only with `args=true` (see [observe tools](gamemcp/observe.md)); use
  `describe` for signatures and hook the function in Lua if you need its arguments.
- `call` and `eval` change the live game; out params of a UFunction come back as extra result lines in UE4SS Lua form.
  Object arguments must be given as `{"obj": "<path or full name>"}`; structs and arrays are not supported (use `eval`).
- `find` keeps only objects of the current world; widgets and other non-world objects need `any_world=true`.
- `screenshot` needs a rendered window (`headless=false`); a minimized window may not render.
- A hung or crashed game shows as "no answer within N s": see `session_status` and `logs`.
