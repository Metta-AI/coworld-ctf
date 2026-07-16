import std/[os], ../players/baseline/baseline/taunts

# Exercises the taunt worker end-to-end against a mock sidecar (see the
# session scratchpad's mock_sidecar.py): bank prefetch, sanitization, the
# coordinate-format filter, and comeback generation — all without a game.

startTaunts()
var bank: seq[string]
var comeback = ""
requestComeback("GIT GUD")
for i in 0 ..< 60:
  sleep(100)
  pollTaunts(bank, comeback)
  if bank.len >= 3 and comeback.len > 0:
    break
echo "bank: ", bank
echo "comeback: ", comeback
doAssert bank.len >= 3, "bank not prefetched"
for t in bank:
  doAssert t.len <= 10, "taunt too long: " & t
  doAssert t != "C12 34", "coordinate-shaped taunt not filtered"
doAssert comeback == "SKILL DIFF"
echo "TAUNT-PIPELINE-OK"
