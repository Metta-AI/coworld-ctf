import std/[os, json, strformat], ../src/ctf/replays
let path = commandLineParams()[0]
let data = loadReplay(path)
let cfg = parseJson(data.configJson)
if cfg.hasKey("slots"):
  for i, s in cfg["slots"].getElems():
    echo &"slot{i}: {s}"
else:
  for k in cfg.keys: echo "topkey: ", k
