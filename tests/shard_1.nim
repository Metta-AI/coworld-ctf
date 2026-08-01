## CI shard 1 of 4. The shards are balanced by measured suite runtime so the
## four binaries finish together; when adding a test module, put it in the
## currently fastest shard (tests.nim imports all four, so every shard member
## is also part of the full local run).
{.warning[UnusedImport]: off.}
import
  test_artlog,
  test_clock_floor,
  test_fast_mode,
  test_four_team,
  test_identity_privacy,
  test_kill_badges,
  test_live_event_emission,
  test_replay,
  test_replay_requests,
  test_rich_events,
  test_sprite_collisions,
  test_trade_pair
{.warning[UnusedImport]: on.}
