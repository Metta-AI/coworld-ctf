from pathlib import Path
import runpy
namespace = runpy.run_path('/workspace/ctf/docs/reports/nav-budget-screen-2026-09-11/run_native.py')
namespace['run'](512, 32, 1)
