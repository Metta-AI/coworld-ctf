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

  # EVERY entry of this tool's own arg tree rides through every stage, and
  # that is load-bearing rather than tidy. A secret's reader is the tool's arg
  # tree — here {base, help, nim, worker1} — and the grant is a SUBSET match
  # against the arg tree of the job that wants it, with no inheritance (caos's
  # no-delegation invariant). A stage that drops `nim` or `help` stops being
  # recognisable as this tool and SILENTLY loses the secret, failing later at
  # the token check as if none had been declared. Nothing reads either value;
  # carrying them is what makes a stage this tool.
  next=("--worker1:@=/cas/args/worker1" --stage=realize
        "--help:@=/cas/args/help" "--nim:@=/cas/args/nim")
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

  # Let the SERVER convert the delta, and ask what it converted to.
  #
  # This stage used to pull the base with `skopeo copy --format oci`, tar
  # layer00, append its diff_id to the config and its descriptor to the
  # manifest — which is `convert_git_image` reimplemented in bash, against the
  # same base, with the same arithmetic and a second place for it to be wrong.
  # `caos resolve-image` returns the ref the server already computed and
  # cached, so there is one implementation of that arithmetic again.
  delta=$(caos hash /cas/args/result/image) || fail "hashing the image delta"
  ref=$(caos resolve-image "$delta") || fail "converting the image delta $delta"

  R=/tmp/result; rm -rf "$R"; mkdir -p "$R"
  printf '%s' "$ref" > "$R/ref"
  caos put "$R" /cas/converted

  fwd=("--worker1:@=/cas/args/worker1" --stage=push
       "--help:@=/cas/args/help" "--nim:@=/cas/args/nim")
  for a in player name server upload-salt; do
    [ -e "/cas/args/$a" ] && fwd+=("--$a:@=/cas/args/$a")
  done
  then_=$(caos curry --base:@=/cas/args/base "${fwd[@]}") || fail "currying push"
  caos map-then /cas/converted --then:hash="$then_"
  ;;

push)
  caos get -r /cas/args/in     # { ref } — what the server converted the delta to
  ref=$(cat /cas/args/in/ref) || fail "no converted ref"

  # resolve-image answers through the server's registry_pull_host, which is the
  # HOST daemon's view (localhost:5000); a worker is on caos-net and cannot
  # reach that. Rewrite it to the name the network answers to.
  #
  # This is a rough edge in resolve-image rather than something to be proud of
  # here: the server knows one address and hands it to callers on both sides of
  # its network. The clean fix is for runnerd to inject the registry address the
  # way it already injects CAOS_WORKER_REDIS_ADDR.
  case "$ref" in
    localhost:*|127.0.0.1:*) ref="caos-registry:${ref#*:}" ;;
  esac

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
  # client_hash is the image's CONFIG digest — exactly what coworld reads from
  # `docker image inspect --format {{.Id}}` (upload.py, _local_image_client_hash).
  # Ask the registry, not a daemon.
  chash=$(skopeo inspect --tls-verify=false --raw "docker://$ref" | jq -r '.config.digest') \
    || fail "reading the config digest of $ref"
  [ -n "$chash" ] && [ "$chash" != null ] || fail "no config digest for $ref"

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
    skopeo copy --src-tls-verify=false --dest-creds "$creds" \
      "docker://$ref" "docker://$reg/$repo:$tag" \
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
    echo "image:       $ref"
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
