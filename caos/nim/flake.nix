{
  # The coworld-ctf Nim worker image: a toolchain and an interpreter, and
  # deliberately NOTHING of this project.
  #
  # It carries no project dependencies — those come from the `deps` job as an
  # ordinary arg — which is what keeps this image generic (any Nim project can
  # ride it) and keeps it from rebuilding every time nimby.lock moves.
  #
  # Its own directory with its own flake.lock, NOT the repo root flake: the
  # flake-builder keys an image on the directory it is handed, so a root-flake
  # image would rebuild on every source edit.
  #
  # /worker (checked in beside this file) runs the `worker1` arg with bash, so
  # one image serves every job in the pipeline — compiling ctf, compiling the
  # tests, and running a batch of tests — with the script, not the image, being
  # the worker. Running the tests needs THIS image specifically: the test
  # binary hardcodes the ELF interpreter of the glibc it was linked against,
  # which is the one in here.
  description = "coworld-ctf nim worker: nim + ccache + gcc, /worker runs `worker1`";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    nimby-src = {
      url = "github:treeform/nimby/0.1.26";
      flake = false;
    };
  };

  outputs =
    { self, nixpkgs, nimby-src }:
    let
      forSystem =
        system:
        let
          pkgs = import nixpkgs { inherit system; };

          # nimby fetches the pinned deps inside the `deps` job. Built from
          # source: the upstream release binary is a non-Nix dynamic ELF.
          nimby = pkgs.stdenv.mkDerivation {
            pname = "nimby";
            version = "0.1.26";
            src = nimby-src;
            nativeBuildInputs = [ pkgs.nim ];
            buildPhase = ''
              export HOME="$TMPDIR"
              nim c -d:release --hints:off --nimcache:"$TMPDIR/nc" -o:nimby src/nimby.nim
            '';
            installPhase = ''
              install -Dm755 nimby "$out/bin/nimby"
            '';
          };

          workerRoot = pkgs.runCommand "ctf-nim-worker-root" { } ''
            mkdir -p $out
            install -m 755 ${./worker} $out/worker
          '';

          # A `gcc` that is really ccache. Shipping ccache in the image is not
          # enough on its own, and neither is putting this directory first on
          # PATH: the nixpkgs nim wrapper bakes an ABSOLUTE compiler path into
          # its config, so nim execs /nix/store/...-gcc-wrapper/bin/gcc and
          # never consults PATH. What routes the build through here is the
          # explicit `--gcc.exe:/ccache-bin/gcc` in caos-tools/lib/common.sh;
          # PATH order only keeps a bare `gcc` consistent with it. Without the
          # flag this looks entirely correct — `command -v gcc` even reports the
          # wrapper — while ccache records zero calls.
          #
          # printf rather than a heredoc: nix strips the common indentation from
          # a ''-string, so a heredoc body written here lands in the script with
          # leading spaces — and a shebang is only honoured at byte 0.
          ccacheBin = pkgs.runCommand "ctf-nim-ccache-bin" { } ''
            mkdir -p $out/ccache-bin
            for tool in gcc cc g++ c++; do
              printf '#!/bin/sh\nexec %s/bin/ccache %s/bin/%s "$@"\n' \
                ${pkgs.ccache} ${pkgs.gcc} "$tool" > $out/ccache-bin/$tool
              chmod +x $out/ccache-bin/$tool
            done
          '';
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "ctf-nim";
          tag = "latest";
          # One store path per layer, so the toolchain and its parts dedup
          # independently. No Entrypoint: runnerd forces `/bin/caos runner`,
          # which execs /worker.
          maxLayers = 100;
          contents = [
            workerRoot
            ccacheBin
            # The interpreter and the shell tools a worker script leans on.
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.diffutils
            # The Nim toolchain and the C compiler it drives.
            pkgs.nim
            pkgs.gcc
            pkgs.binutils
            # `nim c` is 75% C compilation on this project; ccache takes a
            # forced rebuild from ~15s to ~4s and is backed by redis, so a
            # fresh container starts warm without a volume.
            pkgs.ccache
            # nimby clones the pinned deps; it shells out to git and curl.
            nimby
            pkgs.git
            pkgs.curl
            pkgs.cacert
            # What the deps link against at build/run time.
            pkgs.zlib
            pkgs.openssl
          ];
          config = {
            Env = [
              # /ccache-bin first, so `gcc` is the ccache wrapper above.
              "PATH=/ccache-bin:/bin"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              # Home has to be writable for nimby and ccache defaults.
              "HOME=/tmp"
              # curly resolves libcurl at RUNTIME via dlopen, not link time, and
              # a nix image has no ld.so.cache for it to search. Without this
              # every test binary dies on `could not load: libcurl.so(|.4)` —
              # at run time, so the compile looks perfectly healthy first.
              "LD_LIBRARY_PATH=${
                pkgs.lib.makeLibraryPath [ pkgs.curl pkgs.zlib pkgs.openssl ]
              }"
            ];
          };
        };
    in
    {
      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value = { caosImage = forSystem system; };
        }) [ "x86_64-linux" "aarch64-linux" ]
      );
    };
}
