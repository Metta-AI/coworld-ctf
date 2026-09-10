# C1 production-build setup

The initial C1 attempt on owned m5a failed before timing: `sudo docker buildx build --load` reported an unknown --load flag because the Buildx plugin was absent. The native binary did build. No benchmark result is claimed for that attempt; C1-initial-m5a retains its build/source/CPU logs.

Installed Ubuntu's docker-buildx 0.30.1 package with apt on the owned experimental host, then verified `sudo docker buildx version`. Docker daemon access requires sudo on this host. The repository build command and Dockerfile are unchanged. C1-buildx-install.log retains the setup output. Repaired run uses a fresh C1-repaired results directory, run_c1_repaired.sh, PID40142, and c1-repaired-launch.log; do not overlap other m5a timing while it runs.
