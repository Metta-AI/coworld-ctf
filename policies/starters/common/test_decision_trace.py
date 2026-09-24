"""Private CTF play-call evidence retains model text and server acceptance."""

import io
import json
import unittest
import urllib.error
from unittest.mock import patch

import starter_harness as harness
import brain


class DecisionTraceTests(unittest.TestCase):
    def seat(self):
        seat = harness.StarterSeat(None, 3)
        seat.context_payload = '{"self":{"seat":3},"roster":[]}'
        seat.view_payload = '{"tick":27,"self":{"hp":4},"visible_enemies":[]}'
        seat.last_view_tick = 27
        seat.next_proposal_id = 8
        return seat

    def test_model_call_retains_exact_prompt_text_and_repaired_call(self):
        primary = brain.OpenAiChatBrain("http://example.invalid/", "pinned-model")
        engine = brain.ResilientBrain(primary)
        reply = {"choices": [{"message": {"content": '```json\n{"call":{"entries":[]}}\n```'}}]}
        with harness._persona_prompt("policy rules"), patch(
            "urllib.request.urlopen", return_value=io.BytesIO(json.dumps(reply).encode())
        ):
            decision = engine.decide("visible summary")
        payload = b'{"plays":[{"play":"edge_ride","entry_id":"ride"}]}'
        status = {"kind": "call_accepted", "proposal_id": "7", "tick": 29, "epoch": "4"}
        out = io.StringIO()

        harness._record_call(out, self.seat(), "opening call", payload, status,
                             "policy rules", "visible summary", decision, engine)

        row = json.loads(out.getvalue())
        self.assertEqual(row["origin"], "model")
        self.assertEqual(row["model_request"]["model"], "pinned-model")
        self.assertEqual(row["model_request"], primary.last_request)
        self.assertEqual(row["model_response_text"], primary.last_raw_response)
        self.assertEqual(row["prompt"], primary.last_request["messages"])
        self.assertEqual(row["view"]["self"]["hp"], 4)
        self.assertEqual(row["submitted_call"]["plays"][0]["play"], "edge_ride")
        self.assertEqual(row["submitted_call_json"], payload.decode())
        self.assertEqual(row["proposal_id"], 7)
        self.assertEqual(row["status"], status)

    def test_fallback_does_not_attribute_a_failed_model_response(self):
        primary = brain.OpenAiChatBrain("http://example.invalid/", "pinned-model")
        primary.last_request = {"model": "pinned-model"}
        primary.last_raw_response = '{"stale":"response"}'
        engine = brain.ResilientBrain(primary)
        engine.error = RuntimeError("provider unavailable")
        out = io.StringIO()

        harness._record_call(out, self.seat(), "re-call 1", b'{"plays":[]}',
                             {"kind": "call_rejected", "proposal_id": "7"},
                             "policy rules", "visible summary", {}, engine)

        row = json.loads(out.getvalue())
        self.assertEqual(row["origin"], "fallback")
        self.assertIsNone(row["model_response_text"])
        self.assertIsNone(row["model_request"])
        self.assertEqual(row["status"]["kind"], "call_rejected")

    def test_failed_model_attempt_is_retained_once_before_canned_fallback(self):
        primary = brain.OpenAiChatBrain("http://example.invalid/", "pinned-model")
        engine = brain.ResilientBrain(primary)
        with harness._persona_prompt("policy rules"), patch(
            "urllib.request.urlopen", side_effect=urllib.error.URLError("denied")
        ):
            first = engine.decide("first visible summary")
            out = io.StringIO()
            harness._record_call(out, self.seat(), "opening call", b'{"plays":[]}',
                                 None, "policy rules", "first visible summary",
                                 first, engine)
            second = engine.decide("second visible summary")
            harness._record_call(out, self.seat(), "re-call 1", b'{"plays":[]}',
                                 None, "policy rules", "second visible summary",
                                 second, engine)

        rows = [json.loads(line) for line in out.getvalue().splitlines()]
        self.assertEqual([row["origin"] for row in rows], ["fallback", "fallback"])
        self.assertEqual(rows[0]["model_request"]["model"], "pinned-model")
        self.assertIn("denied", rows[0]["model_error"])
        self.assertIsNone(rows[1]["model_request"])
        self.assertIsNone(rows[1]["model_error"])


if __name__ == "__main__":
    unittest.main()
