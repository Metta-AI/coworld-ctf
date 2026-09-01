# MONET — the house test policy

The fourth persona on the starter seam and the painter after Picasso. The
three starters (`../starters/`) are worked examples handed to players, each
embodying one instinct; MONET is the house entry: the research program's
measured doctrine, translated to the play-calling layer. It runs on the
identical machinery (`../starters/common/starter_harness.py` over the PoC
protocol client) — nothing in the protocol layer is forked.

## Where every rule comes from

The doctrine is not vibes; each line of `system_prompt.md` and each harness
clamp traces to a measured finding of the S1/S2 research program or to the
engine's own pricing:

| doctrine | source |
| --- | --- |
| even trades refused; commit needs 2 of numbers/health/surprise | attrition-margin study: even trade is negative-EV; a tag is only ~16% banked |
| recovery is the first call after a fight | conversion study: the lineage won fights and never banked the life (5.9x worse healing, medkits never taken) |
| count guns you can SEE; never reason about cooldowns/hoppers | Picasso SEAL ledger: `tempoPress` RETIRED — "press their reload" is unobservable on this engine; `fireSuperiority`'s enemy-health gap |
| never turn your back on a live gun | Picasso SEAL ledger: `holdVsGun`, the focus-fire audit fix |
| prefer weakened + isolated | Picasso SEAL lever #1 `dangerScore` (greatest-threat-first), shipped in the champion base — and already engine-side in `target_law` |
| partner never-list, spaced crossfire | friendly fire was the single biggest measured loss; the engine prices it: dTeamKill −60g |
| avenge a fallen partner, once | dRevengeKill's BR partner gate: 18g, one mint per episode |
| truce politics between duos | owner ruling 9/1: 16 duos of 2 exist to force inter-duo alliance dynamics; betrayal is part of the economy |
| jackal + clustered tags | third-party economics + HeatLadder [1,2,4,8]: streaks multiply — fight SIZE, not fight count |
| enter the ring with a lead; range over brawl | candB zone schedule ships and closes fully (late dps lethal); dLongshotKill 30g vs dPointBlankKill 12g |
| endgame convergence at ≤3 duos | the known endgame stall: full-health seats decline point-blank finishes and the ring picks the winner |

## The three structural clamps (`adjust_entries`)

1. **Truce honor** — every pact's partners are mirrored into every
   `target_law` never-list. Releasing a seat requires DROPPING the pact on
   the same call; betrayal is a decision, never an accident of aim.
2. **Fire discipline** — the duo partner rides every never-list whether or
   not the model remembered.
3. **Conversion** — a `supply_run` rung is guaranteed in every ladder,
   above the rotation controller and below any fight controller.

## Honest gaps (current field truth, 2026-09-01)

- BR's glory economy today is combat-only: dAssist/dRescue are CTF-gated and
  the stacking team-context modifier is a ruling, not landed code. The
  politics therefore pays through FIGHT ECONOMICS (numbers advantage,
  jackal profit) today, and starts minting team glory when the increment-2
  BR overlay lands. The persona is deliberately shaped for that future.
- The loot rework (`lootStart`/`downedMode`/`bandagePickups`) is built but
  dark on the shipped `battle-royale-s2` variant; conversion runs through
  medkit `supply_run` only until it arms.
- The model's live observability is thin (static lobby context + partner
  vitals + kill feed); the between-calls game is carried by the WASM plays.

## Run it

Exactly like a starter (see `../starters/README.md` for the server-side
rig). From the repository root:

```bash
python3 -m venv .venv && .venv/bin/pip install "websockets>=13"
POC_HOST=127.0.0.1 POC_PORT=21820 POC_SLOT=0 POC_TOKEN=<token> \
POC_PLAYBOOK=<dir of .wasm> \
  .venv/bin/python policies/monet/policy.py --canned
```

`--canned` exercises the persona offline across the four scripted turns
(opening politics → consolidation → jackal → endgame truce-break). Model
turns: 4, spread across the match arc (`recall_count=3`, 45s spacing) —
override with `POC_RECALL_SECONDS`/`POC_RECALL_COUNT`.

Offline self-check (no server, validates prompt assembly + every canned
call through the harness's own repair path + the clamps):

```bash
python3 policies/monet/selfcheck.py
```

## Verification bar

Never crown MONET off one seed — the one-page BR series proved winner-by-
stance flips with the seed (wide-intel won 31337, tight-trade won 20260830).
Any "better than the starters" claim rides a multi-seed series with seats
swapped across seeds; duo seating is k/k+16, never consecutive.
