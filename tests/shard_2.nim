## CI shard 2 of 4. See shard_1.nim for the sharding rules.
##
## test_glory landed in 04096969 ("increment 1/3") and was never added to any
## shard -- glory.nim has since been wired into sim.nim/sim_types.nim for
## real (increment 2/3, e11cc008/ba256d95), so its 31-test law suite was
## running dark: `tests/tests.nim` and every CI run compiled and passed
## without ever executing it. Wired in here (fast shard, cheap pure-func
## tests, no SimServer).
{.warning[UnusedImport]: off.}
import
  test_achievements,
  test_board_click_select,
  test_callout_perception,
  test_four_team,
  test_fov,
  test_fx_pools,
  test_glory,
  test_gun_jitter,
  test_item_pool_ingest,
  test_kill_badges,
  test_live_event_emission,
  test_map_los,
  test_mapgen_styles,
  test_medkits,
  test_render_scale,
  test_shield_bubble,
  test_shields,
  test_shot_accuracy,
  test_shouts,
  test_spinning_diamonds,
  test_team_art
{.warning[UnusedImport]: on.}
