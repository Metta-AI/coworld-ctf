# The pinned Nim dependency tree, fetched by nimby itself.
#
# A FIXED-OUTPUT derivation: declaring the output hash is what buys network
# access inside the sandbox, so nimby does the fetching it already knows how to
# do and nimby.lock stays the single source of truth — no generated list of
# per-dep hashes to regenerate and drift.
#
# The output is a self-contained deps tree: one directory per package plus the
# nim.cfg nimby writes, whose `--path:` lines are RELATIVE, so the tree works
# wherever it is mounted (a worker's /cas, a dev shell, an image layer).
{ stdenvNoCC, nimby, git, cacert, lockFile, hash }:

stdenvNoCC.mkDerivation {
  name = "coworld-ctf-nim-deps";

  nativeBuildInputs = [ nimby git cacert ];

  outputHashMode = "recursive";
  outputHashAlgo = "sha256";
  outputHash = hash;

  dontUnpack = true;

  buildCommand = ''
    export HOME="$TMPDIR"
    export GIT_SSL_CAINFO="${cacert}/etc/ssl/certs/ca-bundle.crt"
    # nimby syncs into the CWD (one directory per package) and writes a nim.cfg
    # of relative --path: lines beside them. That directory is the output.
    mkdir -p "$out"
    cd "$out"
    cp ${lockFile} nimby.lock
    nimby sync nimby.lock

    # The checkouts are pinned by commit, so their CONTENT is reproducible —
    # but a .git directory is not (packfiles and refs vary run to run), and this
    # derivation's hash covers every byte. Drop them; nothing downstream reads
    # git history from a dependency.
    find "$out" -name .git -prune -exec rm -rf {} +
    rm -f "$out/nimby.lock"

    # SORT nim.cfg. nimby syncs on four threads and appends each `--path:` line
    # as that package lands, so the file's ORDER is thread-completion order —
    # the one thing here that genuinely differs run to run, and it alone broke
    # the fixed output hash (measured: two fetches of identical content hashed
    # differently). Order is not meaningful to nim, so sorting loses nothing.
    { head -1 nim.cfg; tail -n +2 nim.cfg | LC_ALL=C sort; } > nim.cfg.sorted
    mv nim.cfg.sorted nim.cfg

    # paths.txt — the same srcDirs as one bare relative path per line.
    #
    # nim.cfg itself cannot be used where this tree ends up: nim reads a
    # `nim.cfg` only from the PROJECT directory and its parents, never from a
    # directory handed to `--path:`. And the paths inside it are relative to
    # this root, so `--path:<root>` alone does not resolve `bitworld/runtime`
    # (measured: "cannot open file: bitworld/runtime"). A consumer therefore has
    # to expand them against wherever the tree is mounted, which differs per
    # consumer (/cas in a worker, the store in a dev shell) — so the tree ships
    # the LIST and lets each consumer root it:
    #
    #   while read -r p; do flags+=("--path:$DEPS/$p"); done < "$DEPS/paths.txt"
    tail -n +2 nim.cfg | sed 's|^--path:"||; s|"$||' > paths.txt

    chmod -R u+w "$out"
  '';

  meta.description = "coworld-ctf's nimby.lock dependencies, fetched by nimby";
}
