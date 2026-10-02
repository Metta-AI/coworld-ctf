include "../src/ctf/llm"

block:
  putEnv("COWORLD_LLM_ENDPOINT", "http://127.0.0.1:9100/")
  putEnv("COWORLD_LLM_MODEL", "anthropic/claude-sonnet-4.6")
  putEnv("ANTHROPIC_API_KEY", "local-key-must-not-win")
  let client = newLlmClient(GameConfig())
  doAssert client.transport == ltSidecar
  for slot in 0 .. 1:
    let request = client.requestFor("rules", "private state", slot)
    doAssert request.url == "http://127.0.0.1:9100/v1/messages"
    doAssert request.headers["X-Coworld-Player-Slot"] == $slot
    let body = parseJson(request.body)
    doAssert body["model"].getStr() == "anthropic/claude-sonnet-4.6"
    doAssert not body.hasKey("anthropic_version")
  client.curl.close()
  echo "Hosted native LLM routing and seat attribution passed"
