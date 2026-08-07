# pocketThreat / hpGate — GV40 re-diagnosis (2026-08-07)

Corpus: 144 league episodes, r2582-r2583, coworld 0.7.207 = GameVersion 40,
re-simulated 144/144 clean with an extractor built at GV40. Free public replays.

```
=== pocket_diag: 144 episodes, 148 steals (max-stale 20t) ===

MAP GEOMETRY: 2 distinct pedestal points
   (1049.0, 329.0)  80
   (186.0, 329.0)  68

STEAL OUTCOME
   capture       48   32.4%
   killed        70   47.3%
   unresolved    30   20.3%

PREMISE A — carrier-killer distance from the pedestal (n=70)
   median    201px   mean    237px
   p25       117px
   p50       209px
   p75       347px
   p90       479px
   >150px (invisible to GrabStackRange today): 48/70   68.6%
   >300px (still invisible at the proposed 300):  21/70   30.0%
   → widening 150→300 newly covers 27/70  38.6% of carrier-killers

PREMISE B — HP at the steal vs conversion
    hp  steals   share  capture    conv  killed  medlife
     1      31  20.9%        2   6.5%      23      37t
     2      38  25.7%       12  31.6%      17     125t
     3      79  53.4%       34  43.0%      30     162t

PREMISE C — does a pocket body-count gate discriminate? (fatal n=70, capture n=48) — counted AT THE STEAL
   bodies within 150px  fatal={0: 55, 1: 8, 2: 5, 3: 2}  capture={0: 36, 1: 10, 2: 2}
   bodies within 300px  fatal={0: 33, 1: 26, 2: 9, 3: 1, 4: 1}  capture={0: 32, 1: 10, 2: 6}

   gate (flag the dive when...)              fatal      capture   spread
   >=1 enemy within 150px               15/70  21.4%   12/48  25.0%    -3.6pp
   >=2 enemy within 150px                7/70  10.0%    2/48   4.2%    +5.8pp  <= today
   >=1 enemy within 300px               37/70  52.9%   16/48  33.3%   +19.5pp
   >=2 enemy within 300px               11/70  15.7%    6/48  12.5%    +3.2pp

   spread ≈ 0 means the gate cannot tell a fatal pocket from a winning one:
   it would suppress good dives at the same rate as bad ones.

placement error: median killer-sample staleness 0t, p90 0t
dropped (no killer sample within 20t): 0
```

## Staleness sensitivity (max-stale 60t)
```
PREMISE C — does a pocket body-count gate discriminate? (fatal n=70, capture n=48) — counted AT THE STEAL
   bodies within 150px  fatal={0: 52, 1: 9, 2: 2, 3: 4, 4: 2, 5: 1}  capture={0: 30, 1: 6, 2: 3, 3: 5, 4: 3, 5: 1}
   bodies within 300px  fatal={0: 25, 1: 28, 2: 8, 3: 5, 4: 1, 5: 3}  capture={0: 22, 1: 7, 2: 8, 3: 3, 4: 6, 5: 1, 6: 1}

   gate (flag the dive when...)              fatal      capture   spread
   >=1 enemy within 150px               18/70  25.7%   18/48  37.5%   -11.8pp
   >=2 enemy within 150px                9/70  12.9%   12/48  25.0%   -12.1pp  <= today
   >=1 enemy within 300px               45/70  64.3%   26/48  54.2%   +10.1pp
   >=2 enemy within 300px               17/70  24.3%   19/48  39.6%   -15.3pp

   spread ≈ 0 means the gate cannot tell a fatal pocket from a winning one:
   it would suppress good dives at the same rate as bad ones.

placement error: median killer-sample staleness 0t, p90 0t
```
