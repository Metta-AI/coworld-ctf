# C6 count classification check

The peer diagnostic classifies all sources against the cache before a rebuild, then scans slots afterward. In general this differs from per-source sequential LRU behavior if an earlier source evicts or inserts a later key. Root independently simulated ordered source cells across every changed rebuild in all nine archived traces: zero pre-block-versus-sequential hit classifications differ in this dataset. Thus the existing trace count result is valid for these inputs. Do not generalize the pre-block classifier to new traces; future diagnostics should classify/update LRU sequentially or observe the actual hit path.

The archived NAVSRC pts token includes x:y:seatId; cells contains the exact origin cells. Root used ordered cells for this check. A related C4 key accidentally retained seatId; correcting it to x:y leaves every C4 result row unchanged. Both original and corrected artifacts are retained.
