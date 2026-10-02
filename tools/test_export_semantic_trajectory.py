"""The private journal must agree with hash-bound accepted replay calls."""

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from export_semantic_trajectory import export


class ExportTests(unittest.TestCase):
    def test_verified_call_and_tampering(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            replay = root / "game.bitreplay"
            replay.write_bytes(b"season-2-game")
            ladder = '{"plays":[]}'
            call = {"seat": 0, "call_number": 7, "ladder_json": ladder,
                    "record_sha256": "ab" * 32, "replay_time_ms": 12, "entries": []}
            calls = root / "calls.json"
            calls.write_text(json.dumps({"manifest_verified": True, "game_version": 63,
                "replay_sha256": hashlib.sha256(replay.read_bytes()).hexdigest(),
                "calls": [call]}))
            trace = root / "trace.jsonl"
            row = {"event_type": "play_call_attempt", "game": "coworld-ctf", "seat": 0, "proposal_id": 3,
                   "status": {"kind": "call_accepted", "proposal_id": "3", "epoch": "7"},
                   "submitted_call": {"plays": []}, "submitted_call_json": ladder,
                   "context": {}, "view": {"tick": 1}, "view_tick": 1,
                   "origin": "fallback", "model": "chat-model", "model_request": {"model": "chat-model"},
                   "model_response_text": None, "model_error": "provider refused",
                   "parsed_response": {"call": {"entries": []}}, "prompt": [{"role": "user", "content": "go"}]}
            trace.write_text(json.dumps(row) + "\n")
            results = root / "results.json"
            results.write_text(json.dumps({"scores": [3]}))
            output = root / "complete.jsonl"
            args = (trace, replay, calls, results, output, "episode-1", "a" * 40, "canned-v1")
            episode = export(*args)
            self.assertEqual(episode["decisions"][0]["action_status"], "fallback")
            self.assertEqual(len(episode["decisions"][0]["attempts"]), 2)
            self.assertEqual(output.stat().st_mode & 0o777, 0o600)

            row["origin"] = "model"
            row["model_response_text"] = '{"call":{"entries":[]}}'
            row["model_error"] = None
            trace.write_text(json.dumps(row) + "\n")
            model_episode = export(trace, replay, calls, results, root / "model.jsonl", *args[-3:])
            self.assertEqual(model_episode["decisions"][0]["attempts"][0]["response"],
                             row["model_response_text"])
            self.assertEqual(model_episode["decisions"][0]["observation"]["model_request"],
                             row["model_request"])

            row["status"] = None
            trace.write_text(json.dumps(row) + "\n" + json.dumps({
                "event_type": "play_call_status", "seat": 0, "proposal_id": 3,
                "status": {"kind": "call_accepted", "proposal_id": "3", "epoch": "7"}
            }) + "\n")
            journaled = export(trace, replay, calls, results, root / "journaled.jsonl", *args[-3:])
            self.assertEqual(journaled["decisions"][0]["action_status"], "accepted")
            trace.write_text(json.dumps(row) + "\n")
            recovered = export(trace, replay, calls, results, root / "recovered.jsonl", *args[-3:])
            self.assertEqual(recovered["decisions"][0]["executed_action"]["status_source"],
                             "verified_replay")

            replay.write_bytes(b"another-game")
            with self.assertRaisesRegex(ValueError, "another replay"):
                export(trace, replay, calls, results, root / "tampered.jsonl", *args[-3:])
            replay.write_bytes(b"season-2-game")
            row["status"] = {"kind": "call_accepted", "proposal_id": "3", "epoch": "7"}
            row["submitted_call_json"] = '{"plays":[1]}'
            trace.write_text(json.dumps(row) + "\n")
            with self.assertRaisesRegex(ValueError, "differs"):
                export(trace, replay, calls, results, root / "wrong-call.jsonl", *args[-3:])


if __name__ == "__main__":
    unittest.main()
