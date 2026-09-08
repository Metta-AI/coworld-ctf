"""Unit test for the seat-appearance classifier — representative snippets in,
expected class out. No network. Run from anywhere:
    python3 tools/seat_connectivity/test_classify.py
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from classify import classify_seat_appearance  # noqa: E402


class TestClassifySeatAppearance(unittest.TestCase):
    def test_handshake_complete_on_real_0xb0_line(self):
        # Real line shape, confirmed against a live policy log during this
        # tool's build (see README.md "Real run" section).
        log = (
            '[aggressive] connecting to ws://job-a65b8ea5-game:8080/'
            'player?slot=15&token=REDACTED\n'
            '[poc] 0xB0 play_context: {"gun_range":1300,"map":{"height":1212,'
            '"name":"br-gen-24540","width":2271},"mode":"br","schema":'
            '"play_context","self":{"seat":15,"team":"pink"},"v":1}\n'
            '[poc] 0xA0 upload bodyguard: upload_id=1 bytes=25416\n'
        )
        self.assertEqual(classify_seat_appearance(log), "HANDSHAKE-COMPLETE")

    def test_no_playcontext_on_documented_failure_line(self):
        log = (
            '[aggressive] connecting to ws://job-deadbeef-game:8080/'
            'player?slot=3&token=REDACTED\n'
            'FAILED: no 0xB0 PlayContext from the server\n'
        )
        self.assertEqual(classify_seat_appearance(log), "NO-PLAYCONTEXT")

    def test_never_joined_when_log_missing_and_metadata_says_lobby_timeout(self):
        self.assertEqual(
            classify_seat_appearance(None, error_type="lobby_timeout",
                                      error="seat 7 never joined lobby"),
            "NEVER-JOINED",
        )

    def test_not_started_when_log_missing_and_metadata_says_container_failed(self):
        self.assertEqual(
            classify_seat_appearance(None, error_type="container_failed",
                                      error="Container game Error with exit code 1"),
            "NOT-STARTED",
        )

    def test_never_joined_when_log_exists_but_stops_before_lobby_per_metadata(self):
        log = '[aggressive] connecting to ws://job-abc-game:8080/player?slot=9\n'
        self.assertEqual(
            classify_seat_appearance(log, error_type=None,
                                      error="did not join within join window"),
            "NEVER-JOINED",
        )

    def test_unknown_when_nothing_recognizable(self):
        self.assertEqual(
            classify_seat_appearance("some unrelated diagnostic chatter\n"),
            "UNKNOWN",
        )
        self.assertEqual(classify_seat_appearance(None), "UNKNOWN")

    def test_not_started_on_clean_404_from_the_policy_log_route(self):
        # Confirmed live (2026-09-07): a 404 on the correct
        # (episode_request_id, policy_version_id, agent_idx) triple means
        # the platform never produced a log for that seat at all — distinct
        # from a 403, which means WE passed the wrong agent/policy pairing.
        self.assertEqual(
            classify_seat_appearance(None, log_fetch_status="http-404"),
            "NOT-STARTED",
        )

    def test_unknown_not_not_started_on_403_wrong_pairing(self):
        # A 403 ("Agent N does not run the specified policy") is OUR
        # bug (bad agent_idx/policy_version_id), not platform evidence of
        # anything — must not be silently folded into NOT-STARTED.
        self.assertEqual(
            classify_seat_appearance(None, log_fetch_status="http-403"),
            "UNKNOWN",
        )


if __name__ == "__main__":
    unittest.main()
