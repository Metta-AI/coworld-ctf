{
  description = "Coworld CTF — Nim capture-the-flag game server, bots, and tooling";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    # Nimby is the project's dependency manager (see README / Dockerfile). It is
    # a single-file, stdlib-only Nim program, so we build it from source instead
    # of downloading the release binary (which does not run unpatched on Nix).
    nimby-src = {
      url = "github:treeform/nimby/0.1.26";
      flake = false;
    };
  };

  outputs = { self, nixpkgs, nimby-src }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "x86_64-darwin"
        "aarch64-darwin"
      ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems
          (system: f system (import nixpkgs { inherit system; }));
    in
    {
      packages = forAllSystems (system: pkgs: rec {
        # `nimby use <ver>` is unnecessary here — the shell already provides
        # nim 2.2.10 from nixpkgs — but `nimby sync -g nimby.lock` is how the
        # pinned deps in nimby.lock get cloned into ~/.nimby/pkgs.
        nimby = pkgs.stdenv.mkDerivation {
          pname = "nimby";
          version = "0.1.26";
          src = nimby-src;

          nativeBuildInputs = [ pkgs.nim pkgs.makeWrapper ];

          buildPhase = ''
            runHook preBuild
            export HOME="$TMPDIR"
            nim c -d:release --hints:off \
              --nimcache:"$TMPDIR/nimcache" \
              -o:nimby src/nimby.nim
            runHook postBuild
          '';

          installPhase = ''
            runHook preInstall
            install -Dm755 nimby "$out/bin/nimby"
            # nimby shells out to git (clone/fetch/checkout) and curl (Nim
            # tarballs, packages.json).
            wrapProgram "$out/bin/nimby" \
              --prefix PATH : ${pkgs.lib.makeBinPath [ pkgs.git pkgs.curl ]}
            runHook postInstall
          '';

          meta = {
            description = "Nim package manager used by coworld-ctf (nimby.lock)";
            homepage = "https://github.com/treeform/nimby";
            license = pkgs.lib.licenses.mit;
            mainProgram = "nimby";
          };
        };

        default = nimby;
      });

      devShells = forAllSystems (system: pkgs:
        let
          inherit (pkgs) lib stdenv;

          python = pkgs.python3.withPackages (ps: with ps; [
            # tools/proxy_harness_binary.py, tools/jitter_harness.py
            fastapi
            uvicorn
            websockets
            # scripts/campaign_puddles.py (optional import)
            pyyaml
            # tools/ci/test_next_coworld_version.py
            pytest
          ]);

          # curly/libcurl load libcurl at runtime via dynlib, and pixie/zippy
          # want zlib around. On Linux, windy/paddy (pulled in by nimby.lock)
          # link X11/GL/udev/evdev — CI installs libudev-dev + libevdev-dev for
          # exactly this reason.
          runtimeLibs = [ pkgs.curl.out pkgs.zlib ]
            ++ lib.optionals stdenv.hostPlatform.isLinux (with pkgs; [
              udev
              libevdev
              libGL
              libx11
              libxcursor
              libxi
              libxrandr
              libxext
            ]);
        in
        {
          default = pkgs.mkShell {
            name = "coworld-ctf";

            packages = [
              # Nim toolchain. nixpkgs-unstable ships 2.2.10, the version the
              # README pins via `nimby use 2.2.10` (ctf.nimble needs >= 2.2.4).
              pkgs.nim
              self.packages.${system}.nimby

              # Nim compiles through a C compiler and links with pkg-config.
              pkgs.pkg-config
              pkgs.git
              pkgs.curl

              # tools/*.cjs QA harnesses and the wasm replay-viewer smoke test.
              pkgs.nodejs_22

              python
            ];

            # Headers/libs for `nim c` when a dep links C libraries.
            buildInputs = runtimeLibs;

            env = {
              # curly resolves libcurl.so.4 at runtime, not link time.
              LD_LIBRARY_PATH = lib.makeLibraryPath runtimeLibs;
            };

            # Quiet under direnv / `nix develop --command` — only greet a
            # real interactive terminal.
            shellHook = ''
              if [ -t 1 ]; then
                echo "coworld-ctf dev shell — nim $(nim --version | head -1 | cut -d' ' -f4), node $(node --version), python $(python3 --version | cut -d' ' -f2)"
                if [ ! -f nim.cfg ]; then
                  echo
                  echo "  nim.cfg is missing — sync the pinned Nim deps first:"
                  echo "    nimby sync -g nimby.lock"
                fi
                cat <<'EOF'

  run server   COGAME_HOST=0.0.0.0 COGAME_PORT=2000 \
                 COGAME_CONFIG_URI=file://$PWD/config.json nim r src/ctf.nim
  run tests    nim c -r tests/tests.nim            (from the repo root)
  baseline bot nim c players/baseline/baseline.nim
  map editor   nim c --threads:on --mm:orc -r tools/map_editor.nim 8099
  replay dump  nim r tools/expand_replay.nim tests/replays/<file>.bitreplay

  The static replay viewer (wasm) builds through Docker —
  Dockerfile.replay-viewer pins emsdk; use tools/build_replay_viewer.sh.

EOF
              fi
            '';
          };
        });
    };
}
