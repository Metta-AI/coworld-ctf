from pathlib import Path
import json
root=Path('/workspace/ctf'); results=Path('/results')
p=root/'src/ctf/server.nim'; original=p.read_text(); s=original
assert 'budgetFrameStarted' not in original, 'Use a fresh checkout for instrumentation'
s=s.replace('  while true:\n    var\n      pendingReplayUri', '  while true:\n    let budgetFrameStarted = getMonoTime()\n    var\n      pendingReplayUri',1)
s=s.replace('          let shellTick = shellEpisode.step(', '          let budgetShellStarted = getMonoTime()\n          let shellTick = shellEpisode.step(',1)
s=s.replace('          shellSeatsThisTick = shellTick.masks.len', '''          let budgetShellNs = (getMonoTime() - budgetShellStarted).inNanoseconds
          if sim.phase == Playing:
            echo "BUDGET_SHELL tick=", sim.tickCount + 1, " ns=", budgetShellNs,
              " pending=", shellTick.nav.pendingPlans,
              " no_path=", shellTick.nav.noPathSeats.len,
              " stale=", shellTick.nav.stalePathSeats.len
          shellSeatsThisTick = shellTick.masks.len''',1)
s=s.replace('    let frameAdvance = runFrameLimiter(', '''    if sim.phase == Playing:
      echo "BUDGET_FRAME tick=", sim.tickCount, " ns=",
        (getMonoTime() - budgetFrameStarted).inNanoseconds
    let frameAdvance = runFrameLimiter(''',1)
assert s != original
p.write_text(s)
(results/'server-original.nim').write_text(original)
