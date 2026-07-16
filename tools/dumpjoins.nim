import std/[os, strformat], ../src/ctf/replays
let path = commandLineParams()[0]
let data = loadReplay(path)
for j in data.joins:
  echo &"player{j.player}: slot={j.slot} name=\"{j.name}\""
