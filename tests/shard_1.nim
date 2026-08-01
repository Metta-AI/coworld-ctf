## CI shard 1 of 4. The shards are balanced by measured suite runtime so the
## four binaries finish together; when adding a test module, put it in the
## currently fastest shard (tests.nim imports all four, so every shard member
## is also part of the full local run).
{.warning[UnusedImport]: off.}
import
  test_clock_floor,
  test_cog_drive,
  test_ctf_game,
  test_damage_pop,
  test_identity_privacy,
  test_input_buffer,
  test_lobby_join_timeout,
  test_plasma_arc,
  test_replay_requests,
  test_rich_events,
  test_trade_pair,
  # LAST on purpose, not alphabetical: this module hot-switches the
  # process-wide board render caches onto a pool map and leaves them there,
  # so any board-state test that runs after it in the same binary sees the
  # wrong map (test_shouts/test_shield_bubble fail exactly that way).
  test_replay_switch_caches
{.warning[UnusedImport]: on.}
