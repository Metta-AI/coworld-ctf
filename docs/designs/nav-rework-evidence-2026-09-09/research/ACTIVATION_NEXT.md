# Activation findings and next hypotheses (not implemented)

CAP32 native m8i worst non-colossal ratio is map48: BodyMap349.761ms, route index300.469ms, mixed nav190.257ms, hazard2.192ms, cache0.034ms,total842.713ms (2.4094x). Need save about143ms to reach inherited2x; no waiver.

Two exact candidates to review/measure after current throughput units:

1. buildBodyFineLegality currently tests every undirected4px edge in both directions. Its neighbors are axis/diagonal onefineunit only; segmentClear's visited-cell set is symmetric for these. Evaluate four directions and set the reverse bit too, preservingalllegalbits. Must independently compare everybit on76maps and fullquality. No new memory; intendedactivation-only optimization. General arbitrary-slope ray reversal is a separate question, so prove the restricted4px case.

2. findBodyBridge does bounded BFS for each of up to8 adjacent cellanchors. Most regularcenteranchors differ by twofineunits on eachnonzeroaxis. A legal straight2-edge path is the exact BFS-selected path for axis delta(±2,0)/(0,±2), because cardinalfirsthop precedes competing diagonalfirsthops in NavNeighbors; delta(±2,±2) has a unique2-hop path. Checkthoseexistinglegalbits and returntheexact2nodes whenavailable; otherwiseuseunchangedBFS. No approximatedbridge, costchangeornewcache. A generic1/2-hop earlydiscovery preserving NavNeighbors breadth-firstorder isanotherform, but addsmorecode. Need compareeverybridgeNodes sequence/order/offset/hash beforeclaimingexactness. Couldavoidmuchqueue/seen scanningonopenregularanchorswithoutamemorytrade. Notimplemented; futurepreregistrationrequired.
