## CI shard 1 of 4. The shards are balanced by measured suite runtime so the
## four binaries finish together; when adding a test module, put it in the
## currently fastest shard (tests.nim imports all four, so every shard member
## is also part of the full local run).
{.warning[UnusedImport]: off.}
import
  test_blocked_damage,
  test_cog_drive,
  test_identity_badges,
  test_identity_privacy,
  test_lull_spans,
  test_map_los,
  test_mapgen,
  test_movement_slide,
  test_replay_requests,
  test_replay_switch_caches,
  test_rich_events
{.warning[UnusedImport]: on.}
