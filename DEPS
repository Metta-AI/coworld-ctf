# What this repo's CLIENT reaches for, by path, mounted at DEEP-DEPS/<name>.
#
# `bash` is the name `run-tool` looks up — it is HARDCODED in the client as the
# image every caos-tools/*.sh script runs on. We point it at our own nim image
# rather than caos's std/bash, and that is load-bearing rather than a shortcut:
#
#   - a worker CANNOT evaluate a `.caos-expr`, so a tool script has no way to
#     resolve a second image for itself at runtime. The image it is handed is
#     the only one it gets, and `caos curry --base:@=/cas/args/base` curries
#     onto exactly that.
#   - both our tools need the Nim toolchain anyway, and the test batches MUST
#     run on this image: the test binary hardcodes the ELF interpreter of the
#     glibc it was linked against, which is the one in here.
#
# caos/nim satisfies the contract the name implies — it carries bash, coreutils
# and the same /worker trampoline that runs `worker1` — it just carries nim,
# gcc and ccache too.
./caos/nim bash
