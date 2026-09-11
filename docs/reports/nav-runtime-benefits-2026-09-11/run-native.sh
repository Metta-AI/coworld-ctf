#!/bin/sh
set -eu
cd /workspace/ctf
nim=/root/.nimby/nim/bin/nim
$nim --version > /results/compiler.txt
uname -a > /results/machine.txt
lscpu >> /results/machine.txt
sha256sum src/shell/body_map.nim src/shell/body_nav.nim tools/bench_body_port.nim tests/fixtures/br-golden-map.json > /results/candidate-sources.sha256
$nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on --nimcache:/tmp/nav-candidate-cache --out:/results/candidate tools/bench_body_port.nim > /results/build-candidate.log 2>&1
for test in test_shell_body_ray test_shell_body_danger_exact test_shell_body_nav; do
  $nim c -d:release -d:useMalloc --threads:on --opt:speed --stackTrace:on -r --out:/results/$test tests/$test.nim > /results/$test.log 2>&1
done
sha256sum /results/baseline /results/candidate > /results/binaries.sha256
for pair in 1 2 3 4 5; do
  order='baseline candidate'
  if [ $((pair % 2)) -eq 0 ]; then order='candidate baseline'; fi
  for variant in $order; do
    for probe in danger ray; do
      taskset -c 5 /results/$variant --case "$probe" --warmups 5 --samples 50 --output /results/$pair-$variant-$probe.json > /dev/null
    done
  done
done
