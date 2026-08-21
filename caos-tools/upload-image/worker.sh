#!/usr/bin/env bash
# Push the policy image to softmax and register it as a policy version. See
# .caos-expr for the agent-facing docs; this header is the mechanism.
#
# THREE STAGES, one script, selected by a curried --stage:
#
#   narrow  (default) curry build-image, run-then it
#   realize the `then`: turn build-image's git-docker DELTA into a real OCI
#           image on disk — the delta names its base, so this is where the
#           base's blobs are actually fetched
#   push    the platform conversation: request, push, complete, register
#
# WHY THIS REALIZES THE DELTA ITSELF rather than letting caos convert it. caos's
# convert produces an image in CAOS's registry; softmax needs it in THEIRS, and
# a worker has no way to ask the server for the converted ref (the convert
# happens when a tree is used as an image, which is not what we want to do with
# a policy image — it has no /worker and could not run as a job anyway). So the
# delta is realized here with skopeo, which pulls the base ONCE into worker
# scratch. That is a network fetch in a container, not CAS storage: the 68 MB
# still never enters the CAS.
#
# THE TOKEN IS A SECRET, NOT AN ARGUMENT. caos injects it at /secret/<name>;
# only the secret's NAME and entropy reach this job's cache key, never its
# value, so rotating a token does not invalidate anything (caos SPEC,
# "Secrets"). An --token argument would have put it in the CAS.
set -euo pipefail

fail() { echo "UPLOAD-IMAGE FAIL: $*" >&2; exit 1; }

SECRET=/secret/softmax-token
DEFAULT_SERVER=https://api.softmax.com

stage=narrow
if caos get /cas/args/stage 2>/dev/null; then stage=$(cat /cas/args/stage); fi

case "$stage" in

narrow)
  caos get /cas/args/in
  caos get /cas/args/in/caos-tools
  caos get -r /cas/args/in/caos-tools/build-image

  # build-image runs on OUR image (it only assembles); it curries build-player
  # onto the nim image itself, so `nim` rides along.
  fwd=("--worker1:@=/cas/args/in/caos-tools/build-image/worker.sh"
       "--nim:@=/cas/args/nim")
  for a in player defines runtime; do
    [ -e "/cas/args/$a" ] && fwd+=("--$a:@=/cas/args/$a")
  done
  build=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying build-image"

  next=("--worker1:@=/cas/args/worker1" --stage=realize)
  for a in player name server upload-salt; do
    [ -e "/cas/args/$a" ] && next+=("--$a:@=/cas/args/$a")
  done
  then_=$(caos curry --base:@=/cas/args/base "${next[@]}") || fail "currying realize"

  caos run-then /cas/args/in --run:hash="$build" --then:hash="$then_"
  ;;

realize)
  # --result is build-image's { report, image/{base,config.json,layer00/…} }.
  caos get -r /cas/args/result
  [ -d /cas/args/result/image ] || {
    # build-image bailed (the policy did not compile). Its report is the answer.
    R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
    cp /cas/args/result/report "$R/report" 2>/dev/null || echo "no image produced" > "$R/report"
    grep -q FAILED "$R/report" || echo "FAILED" >> "$R/report"
    caos put "$R" /cas/out; exit 0
  }

  player=baseline
  if [ -e /cas/args/player ]; then caos get /cas/args/player; player=$(cat /cas/args/player); fi

  base=$(cat /cas/args/result/image/base)
  base=${base#docker://}

  # Pull the base into an OCI layout. `dir:` keeps the blobs as files we can
  # extend; skopeo does the token dance.
  #
  # --format oci IS REQUIRED, not a preference. A base pushed as docker v2s2
  # carries v2s2 layer media types, and appending our OCI layer to that
  # manifest produces an image no registry will accept ("unsupported docker
  # v2s2 media type"). Rewriting the base to OCI on the way in makes the two
  # compose. caos's own fetch_base does exactly this, for exactly this reason.
  tls=--src-tls-verify=true
  # No dot in the host means a bare name like caos-registry:5000 — docker's
  # own rule for telling a registry from a path segment, and the caos stack's
  # registry answers plain HTTP. Nothing secret moves here; the base is public.
  case "${base%%/*}" in *.*) ;; *) tls=--src-tls-verify=false ;; esac
  L=/tmp/layout; rm -rf "$L"
  # Keep skopeo's own diagnostic. Swallowing it makes a registry/TLS/auth
  # problem indistinguishable from a missing image, which is exactly the kind
  # of invisible failure this repo keeps paying for.
  skopeo copy --format oci $tls "docker://$base" "dir:$L" >/tmp/pull.log 2>&1 \
    || { echo "--- skopeo ---" >&2; tail -20 /tmp/pull.log >&2
         fail "pulling the base $base"; }

  # Our layer, as an UNCOMPRESSED tar — so its digest and its diff_id are the
  # same value, which is what makes the config and the manifest agree without
  # tarring it twice.
  W=/tmp/layer; rm -rf "$W"; mkdir -p "$W/bin"
  cp "/cas/args/result/image/layer00/bin/$player" "$W/bin/$player"
  chmod 0755 "$W/bin/$player"
  # Deterministic tar: fixed mtime/uid/gid/order, so the same policy binary
  # always produces the same layer digest and therefore the same client_hash.
  # Without this every upload would look like a new image.
  tar --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
      -cf /tmp/layer.tar -C "$W" bin
  ldig=$(sha256sum /tmp/layer.tar | cut -d' ' -f1)
  lsize=$(stat -c %s /tmp/layer.tar)
  cp /tmp/layer.tar "$L/$ldig"

  # Extend the base's config: our diff_id on the end of the rootfs stack, and
  # Cmd naming this policy. Everything else — Env, and SSL_CERT_FILE in
  # particular — is the base's.
  jq --arg d "sha256:$ldig" --arg cmd "/bin/$player" \
     '.rootfs.diff_ids += [$d] | .config.Cmd = [$cmd]' \
     "$L/$(jq -r '.config.digest' "$L/manifest.json" | cut -d: -f2)" \
     > /tmp/config.json || fail "extending the base config"
  cdig=$(sha256sum /tmp/config.json | cut -d' ' -f1)
  csize=$(stat -c %s /tmp/config.json)
  cp /tmp/config.json "$L/$cdig"

  jq --arg cd "sha256:$cdig" --argjson cs "$csize" \
     --arg ld "sha256:$ldig" --argjson ls "$lsize" \
     '.config.digest = $cd | .config.size = $cs
      | .layers += [{mediaType:"application/vnd.oci.image.layer.v1.tar",
                     digest:$ld, size:$ls}]' \
     "$L/manifest.json" > /tmp/manifest.json || fail "extending the manifest"
  mv /tmp/manifest.json "$L/manifest.json"

  # client_hash is the CONFIG digest: coworld reads it as `docker image inspect
  # --format {{.Id}}`, which is exactly the config digest, so we can compute it
  # here without a daemon (see coworld/upload.py, _local_image_client_hash).
  printf 'sha256:%s' "$cdig" > /tmp/client-hash

  caos put "$L" /cas/layout
  fwd=("--worker1:@=/cas/args/worker1" --stage=push "--layout:@=/cas/layout")
  for a in player name server upload-salt; do
    [ -e "/cas/args/$a" ] && fwd+=("--$a:@=/cas/args/$a")
  done
  then_=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying push"
  caos map-then /cas/layout --then:hash="$then_"
  ;;

push)
  caos get -r /cas/args/in     # the OCI layout
  L=/cas/args/in

  # THE SECRET. Absent is a hard failure, per caos's contract: a worker must
  # fail if its secret is missing or invalid, because the run's identity records
  # only the secret's name and entropy — never whether it worked.
  [ -s "$SECRET" ] || fail "no token at $SECRET. Declare it in .caos-secrets/softmax-token with reader=caos-tools/upload-image (see this tool's help)."
  tok=$(cat "$SECRET")

  player=baseline
  if [ -e /cas/args/player ]; then caos get /cas/args/player; player=$(cat /cas/args/player); fi
  name=coworld-ctf-$player
  if [ -e /cas/args/name ]; then caos get /cas/args/name; name=$(cat /cas/args/name); fi
  server=$DEFAULT_SERVER
  if [ -e /cas/args/server ]; then caos get /cas/args/server; server=$(cat /cas/args/server); fi
  chash=$(cat "$L/client-hash" 2>/dev/null) || fail "no client-hash in the layout"

  api() { # $1 = path, $2 = json body
    curl -fsSL -X POST "$server$1" \
      -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
      -d "$2"
  }

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"

  # 1. Ask for an upload slot. The platform answers with the image record and,
  #    when it wants the bytes, where to put them.
  resp=$(api /v2/container_images/upload \
    "$(jq -nc --arg n "$name" --arg h "$chash" '{name:$n, client_hash:$h}')") \
    || fail "POST /v2/container_images/upload rejected (token valid? name taken?)"
  imgid=$(jq -r '.image.id' <<< "$resp")
  [ -n "$imgid" ] && [ "$imgid" != null ] || fail "no image id in the upload response"

  if [ "$(jq -r '.pre_signed_info // "null"' <<< "$resp")" = "null" ]; then
    # The platform already has this content: client_hash matched. Nothing to
    # push, and saying so is the honest report — not "uploaded".
    pushed="reused (the platform already had this client_hash)"
  else
    reg=$(jq -r '.pre_signed_info.registry' <<< "$resp")
    repo=$(jq -r '.pre_signed_info.repository' <<< "$resp")
    tag=$(jq -r '.pre_signed_info.tag' <<< "$resp")
    auth=$(jq -r '.pre_signed_info.authorization_token' <<< "$resp")
    # The token is base64 user:pass, which is what --dest-creds wants decoded.
    creds=$(printf '%s' "$auth" | base64 -d 2>/dev/null) || creds="AWS:$auth"
    skopeo copy --dest-creds "$creds" "dir:$L" "docker://$reg/$repo:$tag" \
      >/tmp/push.log 2>&1 || { tail -20 /tmp/push.log >&2; fail "pushing to $reg/$repo:$tag"; }
    api /v2/container_images/upload/complete "$(jq -nc --arg i "$imgid" '{id:$i}')" \
      >/dev/null || fail "POST /v2/container_images/upload/complete rejected"
    pushed="pushed to $reg/$repo:$tag"
  fi

  # 2. Register the image as a policy version. No `run`: the image has a single
  #    CMD, unlike coworld's python examples which need one.
  pol=$(api /stats/policies/docker-img/complete \
    "$(jq -nc --arg n "$name" --arg i "$imgid" '{name:$n, container_image_id:$i}')") \
    || fail "POST /stats/policies/docker-img/complete rejected"

  { echo "policy:      $name"
    echo "client_hash: $chash"
    echo "image id:    $imgid"
    echo "image:       $pushed"
    echo
    echo "$pol" | jq . 2>/dev/null || echo "$pol"
    echo
    echo "UPLOAD OK"
  } > "$R/report"
  caos put "$R" /cas/out
  ;;

*) fail "unknown stage: $stage" ;;
esac
