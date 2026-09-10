# Freeze C6 v2 tools for native use

Please copy the revised even-spread micro tool and outputs into durable C6/ as soon as the v2 job finishes, and issue C6 V2 NATIVE READY before continuing the longer C7 review. Root's native host is idle and runner is prepared.

Native runner copies materialized parent/candidate snapshots. Those snapshots appear to omit DangerReplayFullWords, but the tools still refer to it in JSON metadata; checking the source module alone does not prove these tool builds work. Please make metadata independent of that screen-only production define (a tools-only string define passed by the native runner, or explicit per-arm tool snapshots), and test the tools against each actual materialized source. No change to candidate logic or sampling. Root will pass a tools-only arm label if you choose that approach.
