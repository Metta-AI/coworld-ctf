{
  # The coworld-ctf IMAGE worker: skopeo, jq and a shell, and deliberately no
  # compiler. Image work does not belong in caos/nim — that image is a Nim
  # toolchain, and it carries no tar, no gzip, no jq and no skopeo, which is
  # exactly right for what it is.
  #
  # NOTHING HERE TOUCHES A CONTAINER ENGINE. `build-image` assembles a
  # git-docker delta (a `base` ref plus a layer tree) and lets the caos server
  # convert it; `upload-image` moves an image registry-to-registry with skopeo.
  # Neither needs a docker daemon, so neither needs the root-equivalent
  # CAOS_GRANT_ENGINE_SOCKET that a `docker build` inside a worker would.
  #
  # Its own directory and its own flake.lock, like caos/nim: the flake-builder
  # keys an image on the directory it is handed, so a root-flake image would
  # rebuild on every source edit.
  description = "coworld-ctf image worker: skopeo + jq, /worker runs `worker1`";

  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/b47ad65d73ab65ded9ab408fe558866d71defee8";

  outputs = { self, nixpkgs }:
    let
      forSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          workerRoot = pkgs.runCommand "ctf-imgtools-worker" { } ''
            mkdir -p $out
            install -m 755 ${./worker} $out/worker
          '';
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "ctf-imgtools";
          tag = "latest";
          maxLayers = 100;
          contents = [
            workerRoot
            pkgs.bashInteractive
            pkgs.coreutils
            pkgs.findutils
            pkgs.gnugrep
            pkgs.gnused
            pkgs.gnutar
            pkgs.gzip
            # The three that do the actual work.
            pkgs.skopeo   # registry-to-registry copy, no daemon
            pkgs.jq       # image configs and the coworld API are JSON
            pkgs.curl
            pkgs.cacert
          ];
          config = {
            Env = [
              "PATH=/bin"
              "SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt"
              "HOME=/tmp"
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
