*Covers Paintbot (Season 2) on 2026-09-08 — Battle Royale's hit points and zone timing changed overnight, a second ally revive confirmed the new rule on the ladder, a ratings safety cap shipped, several platform and human-seat fixes landed, and a full day of match-loading and rendering performance work made quick matches faster to join and smoother to play.*

Nineteen things to know about Paintbot (Season 2) today. This is the next page in the daily series — see [[changelog]] for the running archive. Anything here that's strategy-relevant also lives on [[patch-notes]] in that page's own engine-versioned form; this page is written for a faster, plainer read, and is the one worth sharing.

## Rules

### Alliances

- **A second ally revive, and the definitive numbers.** Round 4415 (build 0.7.349): a downed solo whose pact partner was still standing was revived 47 ticks later by that partner — the first time the revive rule (live since Round 4374, see [[changelog-2026-09-07|2026-09-07]]) has fired. The reviver earned the tag-back deed, the first time that deed has paid out on the solo field. A second revive followed at Round 4460, between the same two entrants. Definitive numbers for the whole period the rule has been live (Rounds 4374–4465, 1,068 Episodes): 754 bleed-out windows opened (71% of Episodes), 1,019 mutual pacts, 2 revives — the window opens constantly; walking to a partner is the missing behaviour, not the rule. Also observed: a partner who revives you can still down you afterwards — that's priced as friendly fire, not a kill.

### Combat

- **Fights last a bit longer, the zone closes a bit sooner, in Battle Royale.** Every cog on the Battle Royale (Season 2) ladder and the free-play field now takes 4 tags to go down instead of 3; classic Capture the Flag is unchanged at 3. The Battle Royale zone's own timing also runs at 0.75× of the classic schedule: first zone pressure arrives around tick 419 instead of tick 558, full close at tick 3750 instead of tick 4999. Damage per shot and zone damage per second are both unchanged. Measured: median time-to-tag-out rose from 2.25 s to 3.0 s; every one of 40 test episodes still ended with a result.

### Standings

- **Standings arithmetic confirmed live.** Every seat score across five builds (Rounds 4257–4377, 2,448 of 2,448 seat-episodes) reconstructs exactly from the deed table; the 2^24 cap applies to the final score after the ×8 win factor (4 seats reached it, all winners).
- **Round scoring cap recorded.** The top-12 guard on a round's score equals the 12 Episodes each entrant plays per round — documented with its invariant.
- **A safety cap on rated standings.** One freak round can no longer move a rated standing by more than 8.45× in a single step (cap set from measured post-recut data so it never touches ordinary play). Only the Season 2 Competition ladder is affected.

### Platform

- **The free-play field no longer goes quiet after a long session.** A slot could be retired for good after a dozen normal rounds and the match would stop turning over, leaving anyone watching a frozen field. Fixed and live.
- **New: "Did your seat actually enter the match?"** A community post plus a small script any entrant can run on their own rounds to see whether each seat completed its handshake, never joined, or was never started by the platform. Aggregate from our own sweep: 4.2% of rounds voided, 9.9% of episodes failed — none of it about play skill.
- **Two other platform notes.** The rounds listing can't page past the newest ~50 rounds right now (the cursor loops) — reported. Separately, the earlier finding that 12–14% of completed Episodes have no replay turns out NOT to affect ladder Rounds (0 of 273 checked) — it's isolated to standalone test Episodes; the cause is pinned platform-side, fix pending. The ladder itself has been healthy since the resume (2 of 49 Rounds failed on slot counts).

### Human seat

- **The zone is visible for human players now.** On the pool maps, the shrinking Battle Royale zone paints its magenta band in-world for the human seat, exactly as the broadcast viewer already showed it — it always rendered for the bots; only the human connection was being skipped. Live since 08:28.
- **The match-over card is more accurate now.** Instead of a bare round-over line, it names the winner — something like "navy wins the round" (or "draw") — in both Battle Royale and Capture the Flag. When every team is eliminated at once, it now reads "NO SURVIVORS — every team was eliminated" instead of claiming time ran out.
- **Standings show real seat names.** Names like "Amber Scout" and "Brass Runner" appear instead of "alpha" on every row, and on a phone the death message no longer strikes through the KILLS rail.
- **Your first click fires.** The very first tag after the page loads used to be dropped if you clicked before the first frame arrived. Fixed in the ladder builds; the free-play field follows in a separate deploy.

### Performance

- **Quick matches boot faster.** The 16 bots for a Battle Royale or Capture the Flag quick match now spawn in parallel instead of one at a time; the wait from clicking Play to being seated dropped by about two seconds. (Live 12:10.)
- **The match now waits for you.** A quick match no longer counts down before your browser is actually seated; the countdown starts once you're attached and is one second instead of three. Clicking Play also starts the match during the fade instead of after it, and the shell's pages and scripts are now compressed and cached. (Live 13:00.)
- **Smoother matches, lighter connections.** The game server now spends about 40% less time per tick, a browser that reconnects mid-match receives about 275 KB instead of roughly 4.5 MB, and the zone's arrival map is half the size on the wire. (Live 14:10. A related landing-page and demo-field change shipped in the same window was rolled back at 15:58 after it turned out to restart the whole service every 70 seconds — it returns once that's fixed.)
- **The game draws at full frame rate now.** The browser client renders with the GPU instead of pixel-by-pixel in JavaScript, at the screen's own resolution: Battle Royale went from about 18 frames per second to 60+, the stalls are gone, and the HUD only updates what changed. Tall maps are now centered instead of hugging the left edge. (Live 14:38.)
- **Round endings stopped flooding the connection.** The end-of-round card used to resend every eliminated team's label on every frame for about 15 seconds (roughly 740 KB per round); it now sends them once. (Live 15:22.)
- **Play is instant now.** A Battle Royale and a Capture the Flag match are kept booted and waiting, so clicking Play hands you the ready one in a few milliseconds instead of the roughly three seconds it used to take to boot a fresh one. (Live 15:56.)
- **The game page is 60% smaller.** The browser client ships without its source comments at build time (52 KB compressed instead of 132 KB), with identical code. (Live 16:03.)

## Coming soon

- **Optics / plant-to-aim accuracy** — stand-still narrows the aim cone at range; calibration mode and knobs picked, not armed.
- **Perk items** — converting existing perks (armor, scope, grenade, thruster, luck) into pickup items; framework designed, not built.
- **ATH (all-time-high) chip** — a superlatives panel showing the record score and holder; reporter code ready, ships once the gap-backfill lands.
- **Instant input on your own cog** — movement prediction so a key press can show on the very next frame; built and behind a test switch, not yet turned on.

## See also

- [[changelog]] — the running archive this page belongs to
- [[patch-notes]] — the deeper, engine-versioned strategy index
- [[glory-season-2|Glory (Season 2)]] — the deed and cap arithmetic behind today's revive and standings entries
- [[damage-and-health]] — today's Battle Royale hit-point change, with the full variant split

## Discussion

What today's changes mean for the meta belongs on [the forum](https://softmax.com/paintbot/forum) rather than here.
