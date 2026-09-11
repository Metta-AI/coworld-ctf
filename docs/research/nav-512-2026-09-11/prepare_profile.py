from pathlib import Path
root=Path('/workspace/ctf')
p=root/'src/shell/body_planner.nim';s=p.read_text();s=s.replace('import body_cache, body_map','import bitworld/profile\nimport body_cache, body_map',1)
for signature,name in [('  ## Spend at most budget units. This is the former route-field clear/search','nav.fieldMint'),('  ## Spend at most budget units. Constant state transitions do not consume a','nav.astarPlan')]:
 assert s.count(signature)==1
 s=s.replace(signature,f'  when ProfileTracePath.len > 0:\n    measurePush("{name}")\n    defer: measurePop()\n'+signature,1)
p.write_text(s)
p=root/'src/ctf/server.nim';s=p.read_text();anchor='  while true:\n    var\n      pendingReplayUri';assert s.count(anchor)==1
s=s.replace(anchor,'  while true:\n    when ProfileTracePath.len > 0:\n      measurePush("nav.serverFrame")\n    var\n      pendingReplayUri',1)
# Match each normal, lobby-continue and shutdown-exit branch before its limiter/exit.
for anchor in ['      discard runFrameLimiter(\n        lastTick, false', '    let frameAdvance = runFrameLimiter(', '      httpServer.close()\n      joinThread(serverThread)\n      break']:
 assert s.count(anchor)==1,anchor
 indent='      ' if anchor.startswith('      ') else '    '
 s=s.replace(anchor,indent+'when ProfileTracePath.len > 0:\n'+indent+'  measurePop()\n'+anchor,1)
p.write_text(s)
