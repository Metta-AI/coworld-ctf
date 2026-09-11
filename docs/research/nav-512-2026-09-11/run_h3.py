from pathlib import Path
import runpy,json,subprocess
ns=runpy.run_path('/workspace/ctf/docs/reports/nav-budget-screen-2026-09-11/run_native.py')
run=ns['run']
orders=[(('parent',256),('candidate',512),('parent',512)),
        (('parent',512),('candidate',512),('parent',256)),
        (('candidate',512),('parent',256),('parent',512))]
for repeat,order in enumerate(orders,1):
 for variant,budget in order:
  run.__globals__['RESULTS']=Path('/results')/variant
  print(f"START variant={variant} budget={budget} repeat={repeat}",flush=True)
  try:
   run(budget,32,repeat)
  except (RuntimeError,subprocess.TimeoutExpired) as error:
   d=Path('/results')/variant/f'game-r{repeat}-b{budget}-s32'
   (d/'failure.json').write_text(json.dumps(dict(type=type(error).__name__,error=str(error)))+'\n')
   print(variant,budget,'FAILED',error,flush=True)
