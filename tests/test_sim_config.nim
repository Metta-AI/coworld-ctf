import std/[json, unittest], ctf/sim

## Feature-agnostic tripwire for configJson(). Twice in one night (7ad98a4,
## and the aim-port that followed it) an edit near the end of configJson()
## silently dropped its final `$node` return line while adding an unrelated
## echo — configJson() then returned "" for every config, and every replay
## written on that build got an EMPTY config header. Neither loss tripped
## the compiler; only a feature-specific round-trip test happened to catch
## it. This test does not know about any one feature: it only asserts the
## SHAPE a working configJson() must have, so it fails on the NEXT dropped
## return too, whichever feature's echo the accident lands next to.
suite "configJson tripwire":
  test "the default config JSON parses and is not empty or near-empty":
    let raw = defaultGameConfig().configJson()
    check raw.len > 0
    let node = parseJson(raw)
    check node.kind == JObject
    # A dropped return makes configJson() return "", which fails parseJson
    # outright (empty input). A return of "{}" or a near-empty object would
    # still parse, so the count floor matters as much as the parse itself:
    # today's default config carries ~47 top-level keys; 30 is a wide floor
    # that tolerates future field churn without needing an update per field,
    # while still catching a return that lost most or all of the object.
    check node.len >= 30
