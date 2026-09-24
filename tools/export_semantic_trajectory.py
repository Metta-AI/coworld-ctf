"""Join one private Season 2 play-seat journal to accepted replay calls.

Run export_play_call_records.nim on the matching replay first. The replay's
manifest and exact canonical ladder bytes are authoritative; a player status
alone cannot establish which call the game executed.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
from uuid import NAMESPACE_URL, uuid5


def export(
    trace_path: Path,
    replay_path: Path,
    calls_path: Path,
    results_path: Path,
    output: Path,
    episode_id: str,
    source_revision: str,
    policy_revision: str,
) -> dict:
    if not episode_id or not policy_revision or len(source_revision) != 40 or any(
        char not in "0123456789abcdef" for char in source_revision
    ):
        raise ValueError("Episode, policy, and pinned 40-character source revision are required")
    rows = [json.loads(line) for line in trace_path.read_text().splitlines()]
    if not rows:
        raise ValueError("Private play-seat journal has no call attempts")
    replay = json.loads(calls_path.read_text())
    if replay["manifest_verified"] is not True:
        raise ValueError("Season 2 replay manifest did not verify")
    replay_digest = hashlib.sha256(replay_path.read_bytes()).hexdigest()
    if replay["replay_sha256"] != replay_digest:
        raise ValueError("Call records were decoded from another replay")
    results = json.loads(results_path.read_text())
    if results.get("reason") == "fault":
        raise ValueError("Faulted CTF episode cannot be exported as complete")
    seat = rows[0]["seat"]
    if any(row["game"] != "coworld-ctf" or row["seat"] != seat for row in rows):
        raise ValueError("Journal must contain one CTF seat")
    if not 0 <= seat < len(results["scores"]):
        raise ValueError("Results omit the journaled seat")
    replay_calls = {call["call_number"]: call for call in replay["calls"] if call["seat"] == seat}
    if len(replay_calls) != sum(call["seat"] == seat for call in replay["calls"]):
        raise ValueError("Duplicate replay call number for seat")
    seen_proposals = set()
    joined_calls = set()
    decisions = []
    for index, row in enumerate(rows):
        proposal_id = row["proposal_id"]
        if proposal_id in seen_proposals:
            raise ValueError("Duplicate play-call proposal ID")
        seen_proposals.add(proposal_id)
        status = row["status"]
        executed = None
        if status is not None and status["kind"] == "call_accepted":
            if int(status["proposal_id"]) != proposal_id:
                raise ValueError("Accepted call status names another proposal")
            call_number = int(status["epoch"])
            if call_number not in replay_calls:
                raise ValueError("Accepted call is absent from hash-verified replay")
            call = replay_calls[call_number]
            if call_number in joined_calls or call["ladder_json"] != row["submitted_call_json"]:
                raise ValueError("Accepted play call differs from hash-verified replay")
            joined_calls.add(call_number)
            executed = {
                "call_number": call_number,
                "ladder": row["submitted_call"],
                "entries": call["entries"],
                "record_sha256": call["record_sha256"],
                "replay_time_ms": call["replay_time_ms"],
            }
        elif status is not None and status["kind"] == "call_rejected":
            if int(status["proposal_id"]) != proposal_id:
                raise ValueError("Rejected call status names another proposal")
        elif status is not None:
            raise ValueError("Unexpected play-call status kind")
        decision_id = f"seat:{seat}:proposal:{proposal_id}"
        origin = row["origin"]
        attempt_id = f"{decision_id}:player"
        attempts = []
        if row["model_request"] is not None and origin == "fallback":
            attempts.append({
                "attempt_id": f"{decision_id}:model",
                "policy": row["model"],
                "origin": "model",
                "response": {"request": row["model_request"], "text": row["model_response_text"]},
                "parsed_action": None,
                "accepted": False,
                "rejection_reason": row["model_error"],
            })
        attempts.append({
            "attempt_id": attempt_id,
            "policy": row["model"] if origin == "model" else policy_revision,
            "origin": "model" if origin == "model" else "fallback" if origin == "fallback" else "teacher",
            "response": (
                {"request": row["model_request"], "text": row["model_response_text"],
                 "parsed": row["parsed_response"]}
                if origin == "model"
                else row["parsed_response"]
            ),
            "parsed_action": row["submitted_call"],
            "accepted": executed is not None,
            "rejection_reason": status["reason"] if status is not None and executed is None else None,
        })
        action_status = (
            "missing" if status is None else "rejected" if executed is None else
            "fallback" if origin == "fallback" else "accepted"
        )
        decisions.append({
            "schema_version": "1",
            "event_type": "decision",
            "event_id": str(uuid5(NAMESPACE_URL, episode_id + ":" + decision_id)),
            "episode_id": episode_id,
            "decision_id": decision_id,
            "decision_index": index,
            "game": "coworld-ctf",
            "game_version": str(replay["game_version"]),
            "source_revision": source_revision,
            "seat": str(seat),
            "visibility": "private",
            "observation": {"context": row["context"], "view": row["view"], "tick": row["view_tick"]},
            "prompt": row["prompt"],
            "attempts": attempts,
            "selected_attempt_id": attempt_id if executed is not None else None,
            "executed_action": executed,
            "action_status": action_status,
            "fallback_origin": "starter-canned" if action_status == "fallback" else None,
            "reward": None,
            "terminal": False,
        })
    if joined_calls != set(replay_calls):
        raise ValueError("Replay contains accepted seat calls absent from private journal")
    complete = {
        "schema_version": "1",
        "episode": {
            "schema_version": "1",
            "event_type": "episode",
            "event_id": str(uuid5(NAMESPACE_URL, episode_id + ":episode")),
            "episode_id": episode_id,
            "game": "coworld-ctf",
            "game_version": str(replay["game_version"]),
            "source_revision": source_revision,
            "status": "completed",
            "outcome": {"results": results, "replay_sha256": replay_digest},
            "participant_outcomes": {"scores": results["scores"]},
        },
        "decisions": decisions,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    descriptor = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
        stream.write(json.dumps(complete, separators=(",", ":"), ensure_ascii=False) + "\n")
    return complete


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--replay", type=Path, required=True)
    parser.add_argument("--calls", type=Path, required=True)
    parser.add_argument("--results", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--episode-id", required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--policy-revision", required=True)
    args = parser.parse_args()
    complete = export(args.trace, args.replay, args.calls, args.results, args.output,
                      args.episode_id, args.source_revision, args.policy_revision)
    print(json.dumps({"decisions": len(complete["decisions"]), "output": str(args.output)}))


if __name__ == "__main__":
    main()
