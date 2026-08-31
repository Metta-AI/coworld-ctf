## Deterministic P0 payload builders. These benchmark the landed canonical
## encoder; they are not production view/context producers.

import std/[json, strutils]
import ../../src/shell/canonical

const
  ViewCap* = 32_768
  ContextCap* = 65_536
  TeamTexts = ["red", "blue", "green", "yellow", "black", "silver",
    "ivory", "pink", "umber", "rust", "orange", "plum", "lime", "navy",
    "azure", "peach"]

proc pointNode(x, y: int): JsonNode =
  result = newJArray()
  result.add(%x)
  result.add(%y)

proc buildPlayView*(padding = false): JsonNode =
  # play_view.schema.json top level: schema, v, tick, epoch, self, intent,
  # world, tracks, items, aggressors, kill_feed, shouts, hazards.
  result = %*{
    "schema": "play_view", "v": 1, "tick": 12345, "epoch": "99",
    # self: pos, hp, hp_frac, aim_brads, alive. This is the BR real-max frame,
    # so schema-declared CTF-only lives/carrying are correctly absent.
    "self": {"pos": [1605, 856], "hp": 9, "hp_frac": 0.9,
      "aim_brads": 127, "alive": true},
    # intent.schema.json canonical Intent: schema, v, kind, point,
    # arrive_radius, moving_goal, profile, micro, idle_aim_center_brads,
    # clamp_to_endzone, suppress_fire_freeze, reason. Combat is omitted here.
    "intent": {"schema": "intent", "v": 1, "kind": "navigate_to",
      "point": [3000, 850], "arrive_radius": 24.0, "moving_goal": true,
      "profile": "carrier", "micro": ["formation_bias", "peek_duck"],
      "idle_aim_center_brads": 128, "clamp_to_endzone": true,
      "suppress_fire_freeze": true, "reason": "benchmark"},
    # world: alive_teams and BR zone phase/current/next/ticks_to_shrink/dps.
    "world": {"alive_teams": 16, "zone": {"phase": 3,
      "current": [100, 100, 3000, 1500], "next": [200, 200, 2800, 1300],
      "ticks_to_shrink": 240, "dps": 2}},
    "tracks": [], "items": [], "kill_feed": [], "shouts": [],
    "aggressors": [],
    "hazards": {"grenades": [], "sprays": [], "blast_cues": []}
  }
  for seat in 0 ..< 32:
    # tracks[]: seat, team, pos, aim_brads, hp, fresh_tick, bounty.
    var track = %*{"seat": seat, "team": TeamTexts[seat div 2],
      "pos": pointNode(100 + seat * 31, 200 + seat * 13),
      "aim_brads": (seat * 17) mod 256, "hp": 10 - (seat mod 4),
      "fresh_tick": 12345 - seat}
    if seat mod 7 == 0: track["bounty"] = %true
    result["tracks"].add(track)
    # items[]: kind, pos, present, fresh_tick.
    result["items"].add(%*{"kind": "medkit", "pos": pointNode(40 + seat * 23,
      60 + seat * 11), "present": seat mod 3 != 0,
      "fresh_tick": 12300 + seat})
    # kill_feed[]: tick, killer_team, victim_seat.
    result["kill_feed"].add(%*{"tick": 12000 + seat,
      "killer_team": TeamTexts[seat div 2], "victim_seat": (seat + 1) mod 32})
    # shouts[]: team, slot_letter, text, pos, tick.
    result["shouts"].add(%*{"team": TeamTexts[seat div 2],
      "slot_letter": $char(ord('A') + seat mod 26), "text": "contact",
      "pos": pointNode(500 + seat, 700 - seat), "tick": 12345 - seat})
  for index in 0 ..< 16:
    # aggressors[]: tick, dir_brads, optional seat.
    result["aggressors"].add(%*{"tick": 12340 - index,
      "dir_brads": (index * 19) mod 256, "seat": index})
  for index in 0 ..< 8:
    # hazards.grenades[]: pos, predicted_blast_pos, ticks_to_blast.
    result["hazards"]["grenades"].add(%*{
      "pos": pointNode(900 + index, 800 + index),
      "predicted_blast_pos": pointNode(920 + index, 810 + index),
      "ticks_to_blast": 20 - index})
    # hazards.sprays[] tagged union. Even rows populate visible_cone's
    # attacker_seat/origin/aim_brads/reach_px/max_width_px/covers_self;
    # odd rows populate anonymous_impact's impact_pos/incoming_dir_brads.
    if index mod 2 == 0:
      result["hazards"]["sprays"].add(%*{"kind": "visible_cone",
        "tick": 12340 - index, "attacker_seat": index,
        "origin": pointNode(700 + index, 600 + index), "aim_brads": index * 8,
        "reach_px": 187, "max_width_px": 96, "covers_self": index == 0})
    else:
      result["hazards"]["sprays"].add(%*{"kind": "anonymous_impact",
        "tick": 12340 - index,
        "impact_pos": pointNode(700 + index, 600 + index),
        "incoming_dir_brads": index * 8})
  for index in 0 ..< 4:
    # hazards.blast_cues[]: pos, tick.
    result["hazards"]["blast_cues"].add(%*{
      "pos": pointNode(1000 + index, 500 + index), "tick": 12340 + index})
  # hazards.own_throw: target, release_tick, blast_radius.
  result["hazards"]["own_throw"] = %*{
    "target": [1700, 900], "release_tick": 12360, "blast_radius": 96}
  if padding:
    result["zz_benchmark_padding"] = %""
    let missing = ViewCap - 1 - canonicalJson(result).len
    if missing < 0:
      raise newException(ValueError, "real-max play_view already exceeds its cap")
    result["zz_benchmark_padding"] = %repeat("x", missing)

proc buildPlayContext*(padding = false): JsonNode =
  # play_context.schema.json top level: schema, v, mode, map, roster, self,
  # gun_range, view_interval. map: name/width/height. self:
  # seat/team/duo_partner. roster[]: seat/team/control.
  result = %*{
    "schema": "play_context", "v": 1, "mode": "br",
    "map": {"name": "br-golden", "width": 3211, "height": 1713},
    "roster": [], "self": {"seat": 0, "team": "red", "duo_partner": 1},
    "gun_range": 331, "view_interval": 12
  }
  for seat in 0 ..< 32:
    result["roster"].add(%*{"seat": seat, "team": TeamTexts[seat div 2],
      "control": "play"})
  if padding:
    result["zz_benchmark_padding"] = %""
    let missing = ContextCap - 1 - canonicalJson(result).len
    if missing < 0:
      raise newException(ValueError, "real-max play_context already exceeds its cap")
    result["zz_benchmark_padding"] = %repeat("x", missing)
