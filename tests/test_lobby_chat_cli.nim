## Standalone check for tools/lobby_chat/lobby_chat.nim's embedded fallback
## page. Deliberately NOT wired into tests/tests.nim (that file is actively
## owned/edited by a sibling lane this session) -- run directly:
##   nim r tests/test_lobby_chat_cli.nim
##
## The one thing that must never regress silently: the canonical fallback
## page every seat plays when its lobby-chat LLM call never lands (no key,
## an error, a timeout, an invalid page) must ITSELF always validate clean
## against the real VM -- a fallback that fails to compile would mean "no
## API key" degrades to a seat that can't act at all, exactly the "never
## block the field" failure this whole feature exists to prevent.
import std/unittest
import ../src/ctf/policy_page
import ../tools/lobby_chat/lobby_chat

suite "lobby_chat fallback page":
  test "FallbackPageJson parses and validates with zero errors":
    let page = parsePolicyPage(FallbackPageJson)
    let errors = validate(page, DefaultPathRegistry)
    check errors.len == 0

  test "FallbackPageJson has the required shape":
    let page = parsePolicyPage(FallbackPageJson)
    check page.version == 1
    check page.name.len > 0
    check page.rules.len > 0
