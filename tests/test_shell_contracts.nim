## The play-calling shell's contracts-first commit, held to its own rules
## (docs/designs/strategy-play-calling-shell-2026-08-29.md):
##
## - the canonical encoding is one byte encoding (src/shell/canonical.nim),
##   and every golden fixture in tests/fixtures/shell/ IS canonical bytes;
## - 64-bit identities are decimal strings, full uint64 range, malformed
##   spellings rejected (§5's cross-language rule, 2^53 boundaries included);
## - the packet opcodes and bumped-format record types collide with nothing;
## - the five new config fields (season2Shell, slots[].control,
##   viewIntervalTicks, lobbyChatTicks, playSeatBindTicks) parse, validate,
##   and echo per §5.1/§9.2/P2 — and a gate-off default config's replay JSON
##   gains no byte, the house rule this whole subsystem sits behind.

import std/[algorithm, json, os, strutils, unittest]
import ../src/ctf/sim_config
import ../src/ctf/sim_types
import ../src/shell/types
import ../src/shell/canonical

const FixtureDir = "tests" / "fixtures" / "shell"

const GoldenFiles = [
  "intent.golden.json", "intent_safe_hold.golden.json",
  "combat_policy.golden.json",
  "status_module_accepted.golden.json", "status_module_ready.golden.json",
  "status_module_rejected.golden.json", "status_call_accepted.golden.json",
  "status_call_rejected.golden.json", "status_retune_refused.golden.json",
  "status_play_faulted.golden.json",
  "control_view.golden.json", "control_context.golden.json",
  "play_context.golden.json", "play_view.golden.json",
  "manifest_pact.golden.json", "ladder_call.golden.json"
]

suite "shell canonical encoding":
  test "every golden fixture is its own canonical re-encoding":
    ## Byte equality after a parse round trip is what makes the fixtures
    ## usable as cross-implementation goldens: any producer that emits
    ## canonical bytes reproduces the file exactly.
    for name in GoldenFiles:
      let bytes = readFile(FixtureDir / name)
      # Byte equality with the canonical re-encoding IS the whitespace and
      # key-order proof; raw newlines additionally can never appear
      # (escapeJson escapes them inside strings).
      check canonicalJson(parseJson(bytes)) == bytes
      check '\n' notin bytes

  test "object keys are sorted and sets are pre-sorted in the goldens":
    let intent = parseJson(readFile(FixtureDir / "intent.golden.json"))
    var last = ""
    for key in intent.keys:
      check key > last or last.len == 0
      if key > last: last = key
    var micro: seq[string]
    for flag in intent["micro"]:
      micro.add(flag.getStr())
    var sortedMicro = micro
    sortedMicro.sort()
    check micro == sortedMicro

  test "uint64 identities round-trip at the 2^53 boundaries and the top":
    for value in [0'u64, 9007199254740991'u64, 9007199254740992'u64,
                  high(uint64)]:
      check parseUint64Key(uint64Key(value)) == value

  test "malformed uint64 spellings are rejected":
    expect ValueError: discard parseUint64Key(%7)          # numeric
    expect ValueError: discard parseUint64Key(%"")         # empty
    expect ValueError: discard parseUint64Key(%"07")       # leading zero
    expect ValueError: discard parseUint64Key(%"12x")      # non-digit
    expect ValueError: discard parseUint64Key(%"18446744073709551616") # 2^64
    check parseUint64Key(%"0") == 0'u64                    # bare zero is legal

  test "every status-entry golden fits the 256-byte entry cap":
    for name in GoldenFiles:
      if name.startsWith("status_"):
        check readFile(FixtureDir / name).len <= StatusEntryMaxBytes

suite "shell opcode and record blocks":
  test "packet opcodes sit outside the Sprite v1 client set":
    for op in [OpModuleUpload, OpPlayCall, OpStatusAck, OpLobbyChatSend,
               OpPlayContext, OpPlayView, OpLobbyChatBroadcast]:
      check op > 0x86'u8

  test "record types extend the codec's block without collision":
    for rec in [RecPlayCall, RecBehaviorAnnotation, RecManifest,
                RecLobbyChat, RecDisconnect, RecKick, RecRebind]:
      check rec > 0x06'u8 and rec < 0x81'u8
    check RecPlayCall == 0x10'u8 and RecRebind == 0x16'u8

  test "the derived limits agree with their derivations":
    check PlaySeatReceiveLimitBytes == 14 + MaxModuleBytes
    check MaxRetainedStatusBytes ==
      MaxRetainedStatusEntries * StatusEntryMaxBytes
    check MaxStepsPerSeatPerTick == MaxActiveOverlays + 1

suite "shell config gate":
  test "gate-off default: the replay config JSON gains no byte":
    ## The house rule (§3.2): a gate-off configuration's serialized config
    ## — which is the replay header — must not mention the shell at all.
    let echoed = defaultGameConfig().configJson()
    for key in ["season2Shell", "viewIntervalTicks", "lobbyChatTicks",
                "playSeatBindTicks", "control"]:
      check key notin echoed

  test "defaults are the design's":
    let config = defaultGameConfig()
    check not config.season2Shell
    check config.viewIntervalTicks == ViewIntervalTicksDefault
    check config.lobbyChatTicks == LobbyChatTicksDefault
    check config.playSeatBindTicks == PlaySeatBindTicksDefault

  test "gate-on play-seat config parses, validates, and echoes every key":
    var config = defaultGameConfig()
    config.update($ %*{
      "season2Shell": true, "viewIntervalTicks": 12, "lobbyChatTicks": 480,
      "playSeatBindTicks": 9600, "closedRoster": true, "minPlayers": 2,
      "players": [{"name": "alpha"}, {"name": "beta"}],
      "tokens": ["t-alpha", "t-beta"],
      "slots": [
        {"team": "red", "control": "play"},
        {"team": "blue"}
      ]
    })
    check config.season2Shell
    check config.viewIntervalTicks == 12
    check config.lobbyChatTicks == 480
    check config.playSeatBindTicks == 9600
    check config.slots.len == 2
    check config.slots[0].control == scPlay
    check config.slots[1].control == scInput
    let echoed = config.configJson()
    let node = parseJson(echoed)
    check node["season2Shell"].getBool()
    check node["viewIntervalTicks"].getInt() == 12
    check node["lobbyChatTicks"].getInt() == 480
    check node["playSeatBindTicks"].getInt() == 9600
    check node["slots"][0]["control"].getStr() == "play"
    check not node["slots"][1].hasKey("control")
    # Round trip: the echoed header re-parses to the same shell contract,
    # which is what makes the replay header the provenance.
    var reparsed = defaultGameConfig()
    reparsed.update(echoed)
    check reparsed.season2Shell
    check reparsed.viewIntervalTicks == 12
    check reparsed.slots[0].control == scPlay

  test "gate-on with an all-input roster is legal (the house rule's shape)":
    var config = defaultGameConfig()
    config.update($ %*{"season2Shell": true})
    check config.season2Shell

  test "a play slot under gate-off is playSeatRequiresShell":
    var config = defaultGameConfig()
    expect CtfError:
      config.update($ %*{
        "minPlayers": 2, "closedRoster": true,
        "players": [{"name": "alpha"}, {"name": "beta"}],
        "tokens": ["t-alpha", "t-beta"],
        "slots": [{"team": "red", "control": "play"}, {"team": "blue"}]
      })

  test "an unknown control kind is rejected by name":
    var config = defaultGameConfig()
    expect CtfError:
      config.update($ %*{"slots": [{"control": "psychic"}]})

  test "viewIntervalTicks bounds: 1 and 48 pass, 0 and 49 reject":
    for (value, legal) in [(1, true), (48, true), (0, false), (49, false)]:
      var config = defaultGameConfig()
      if legal:
        config.update($ %*{"viewIntervalTicks": value})
        check config.viewIntervalTicks == value
      else:
        expect CtfError:
          config.update($ %*{"viewIntervalTicks": value})

  test "lobbyChatTicks bounds: 0 and 4320 pass, 4321 rejects":
    for (value, legal) in [(0, true), (720, true), (4320, true),
                           (4321, false)]:
      var config = defaultGameConfig()
      if legal:
        config.update($ %*{"lobbyChatTicks": value})
        check config.lobbyChatTicks == value
      else:
        expect CtfError:
          config.update($ %*{"lobbyChatTicks": value})

  test "playSeatBindTicks: 0 is inert without a play seat, rejected with":
    var inert = defaultGameConfig()
    inert.update($ %*{"playSeatBindTicks": 0})
    check inert.playSeatBindTicks == 0
    var withSeat = defaultGameConfig()
    expect CtfError:
      withSeat.update($ %*{
        "season2Shell": true, "playSeatBindTicks": 0,
        "minPlayers": 2, "closedRoster": true,
        "players": [{"name": "alpha"}, {"name": "beta"}],
        "tokens": ["t-alpha", "t-beta"],
        "slots": [{"team": "red", "control": "play"}, {"team": "blue"}]
      })

  test "playSeatBindTicks bounds: 1 and 14400 pass, 14401 rejects":
    for (value, legal) in [(1, true), (7200, true), (14400, true),
                           (14401, false)]:
      var config = defaultGameConfig()
      if legal:
        config.update($ %*{"playSeatBindTicks": value})
        check config.playSeatBindTicks == value
      else:
        expect CtfError:
          config.update($ %*{"playSeatBindTicks": value})

  test "non-default shell fields echo even under gate-off (provenance)":
    ## The sprayDamage rule: an authored departure is pinned in the header
    ## so the replay identifies its config, while pure defaults stay silent.
    var config = defaultGameConfig()
    config.update($ %*{"lobbyChatTicks": 0})
    let echoed = config.configJson()
    check "lobbyChatTicks" in echoed
    check "season2Shell" notin echoed
