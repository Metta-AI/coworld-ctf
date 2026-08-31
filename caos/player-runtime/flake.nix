{
  # The coworld-ctf player RUNTIME base: exactly the closure a nim-built policy
  # needs at run time, and nothing else — no compiler, no shell, no package
  # manager. A policy image is a binary and its libraries.
  #
  # PINNED TO THE SAME NIXPKGS REV AS caos/nim, and that is load-bearing rather
  # than tidiness. Nim bakes ABSOLUTE /nix/store paths into the binary: the
  # RUNPATH for glibc and gcc-lib, and — because the nim `libcurl` package
  # dlopens curl rather than linking it — an absolute path for libcurl.so.4.
  # Those paths exist at run time only if the compiler and this image come from
  # one pin. Measured on the pin below, all three match what `build-player`
  # emits:
  #
  #   glibc-2.42-67     0d8g8n0a11v6f5m2h416ajyxmnkwc3md   (RUNPATH)
  #   gcc-15.3.0-lib    r48746qznwqxxl9qzd8f08ny8mg1dg2y   (RUNPATH)
  #   curl-8.21.0       42ixphp7ffr0vc2pn0pwsmd28igrd0fh   (dlopen target)
  #
  # A MISMATCH FAILS LOUDLY, which is why this coupling is safe to live with:
  # nim's dynlib load runs at module init, before main, so a wrong pin dies at
  # startup with "could not load: libcurl.so(|.4)" and never reaches the
  # websocket. It cannot degrade into a policy that runs but silently drops its
  # telemetry.
  description = "coworld-ctf player runtime base (glibc + curl + cacert)";

  inputs.nixpkgs.url =
    "github:NixOS/nixpkgs/b47ad65d73ab65ded9ab408fe558866d71defee8";

  outputs = { self, nixpkgs }:
    let
      forSystem = system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          # dockerTools images carry no /tmp. artlog builds its zip through
          # getTempDir() before delivery, so a policy without one cannot write
          # its artifact.
          tmpdir = pkgs.runCommand "player-tmp" { } ''
            mkdir -p $out/tmp
            chmod 1777 $out/tmp
          '';
        in
        pkgs.dockerTools.buildLayeredImage {
          name = "coworld-ctf-runtime";
          tag = "latest";
          # One store path per layer, so this closure dedups against any other
          # image built from this pin — and so a policy rebuild re-pushes only
          # its own ~1 MB layer rather than the whole image.
          maxLayers = 100;
          contents = [
            pkgs.glibc             # the ELF interpreter the binary names
            pkgs.gcc-unwrapped.lib # libgcc_s, the other half of the RUNPATH
            pkgs.curl.out          # the dlopen target, by absolute path
            pkgs.cacert
            tmpdir
          ];
          config = {
            # nix curl does not consult /etc/ssl/certs. artlog PUTs its artifact
            # to a presigned HTTPS URL, so without this every upload fails TLS
            # verification — and artlog swallows upload errors by design, so it
            # would fail SILENTLY.
            Env = [ "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt" ];
            Cmd = [ "/bin/baseline" ];
          };
        };
    in
    {
      packages = builtins.listToAttrs (
        map (system: {
          name = system;
          value = { runtimeImage = forSystem system; };
        }) [ "x86_64-linux" "aarch64-linux" ]
      );
    };
}
