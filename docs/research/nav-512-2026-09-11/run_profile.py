from pathlib import Path
import runpy
namespace=runpy.run_path('/workspace/ctf/docs/reports/nav-budget-screen-2026-09-11/run_native.py')
for budget in (256,512):
    namespace['run'](budget,32,1)
    Path('/results/profile.json').replace(Path(f'/results/game-r1-b{budget}-s32/fluffy.json'))
