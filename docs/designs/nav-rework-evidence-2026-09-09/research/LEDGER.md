# Navigation throughput research ledger

Status: active native optimization and qualification. B=1,024 remains provisional; Phase 10/11 and final fleet/Docker gates are incomplete. The entries below are chronological; see the final continuation and SCOREBOARD.md for current state.

- Source baseline: 20234cc7; james/s2-nav-rework, fresh origin/main comparison 89 ahead / 0 behind, clean main worktree.
- Isolated local worktree: ../coworld-ctf-worktrees/nav-throughput-research, branch james/nav-throughput-research.
- Claude peer: tmux nav-research-peer. Owns PEER_PLAN.md and META_RESEARCH.md only until next negotiated unit. Main owns all other paths.
- Live budget is 1,024; historical handoff section 3 value 4,096 is stale. Moving-goal historic x86 numbers invalidated by threat-cloud harness confound.
- Broker aws.readonly account 751442549699 has no sandbox devbox; sandbox identity fallback resolved i-0bd98ccf84b6ea6a6 at 3.81.19.75, m6i.8xlarge, running. SSH confirms Xeon 8375C, 32 vCPU, 16 cores, SMT2, one NUMA node.
- Broker role Kubernetes call rejected Unauthorized. Configured kube identity succeeds. Game nodes are in softmax-tournament, not softmax-main (main contains app/infra nodes). Production game pod/node join being captured.
- Remote ~/metta and its services are protected. Old ~/coworld-ctf-nav has dependency directories and an older HEAD; create a separate research checkout rather than update it.
- Devbox root 84% used / 32 GiB available. Avoid Docker builds there without a capacity check.
- Meta-research and baseline protocol review underway. No main optimization experiment may start before loop is recorded and peer reviewed.
- No Asana write, publishing, push, PR or merge authorized. Updates are local artifacts only.
- B0 registered in BASELINE_PREREG.md then launched at remote PID 3005344, nohup ~/run_nav_throughput_baseline_20260909.sh, results ~/nav-throughput-results-20260909/B0. 1024 completed; sweep continues. Raw files retrieved incrementally.
- First local tool change imports existing bitworld/profile and starts/finishes Fluffy capture around --tick only. This uses existing game-thread markers; no production src change. Separate profiled executable/run required; profile startup text means stdout is not clean JSON for that diagnostic run.
- B0 complete: three pinned repeats at all four budgets. Report B0_REPORT.md, 72 validated rows B0_SUMMARY.json, B0_SHA256SUMS. Largest tested headroom-passing B1024; largest tested ordinary4/5-passing B2048 (max4.994589 is near boundary). Neither is complete production qualification.
- Fluffy PROFILE complete at B1024, 756 tick frames / 18144 seat observations, trace and per-name summary retained. Scheduled danger and planning dominate trace durations; nested totals overlap. No guest installed in this synthetic harness, so no invokeStep proof; actual profiled server/demo still required.
- I0 extra-clock off/A-A registered, launched remote PID3047188; separate on-A1, off-B, on-A2 binaries, three interleaved repeats each; inspect results and compare pop arrays before claiming equivalence.
- Metta CLI preflight: clean metta_6 main fast-forwarded to current 79891cfa; plain uv refused outside Nix, corrected via nix develop (no bypass). CLI help verified. No coworld/softmax CLI used yet.
- Owned new sandbox host created with current metta box CLI: jamesboggs-nav-throughput-c6a, i-0b37d010a49d1a53d, c6a.4xlarge, public98.91.195.140, AMI ami-05a3e9423ae4d7a19. Creation at about22:18UTC. Track host lifetime and terminate only this owned instance when campaign no longer needs it. Broker does not vend sandbox identity; metta box uses sandbox SSO. CLI also uses existing GitHub login (broker does not vend GitHub) and its standard setup credential transfer.
- Original coworld main tree remains clean; experiment changes only in isolated nav-throughput-research worktree. No algorithm/src changes yet.
- C6a setup initial clone failed early EOF because setup raced the still-transferring bundle (orchestrator error). Transfer completed; local and remote SHA256 now match f5f33cad75c66f39661b7b85a59779d8ad4fc15ab82fc85eef3a626ffc1fc5d8. Failed clone left no checkout. Resume clone/sync/fetch only, retain original failure log; no benchmark data existed or was discarded.
- I0 complete and all9 pop arrays identical; see I0_REPORT.md. No consistent clock-removal speedup established. GameVersion guard passes current baseline: mainGV62, branchGV63.

## Resume checkpoint (22:26UTC approximate)

- Active goal thread01a08835-4e9b-7ae0-af9f-3af82e9023d3; do not mark complete. User asked follow handoff, including long research effort.
- Peer accepted research loop (PEER_CARDS section7). Then granted exclusive ownership of tools/bench_body_nav_rework.nim for --latency addition, preserving root profile/timing toggle edits. Read LATENCY_BRIEF.md; main must NOT edit harness while peer works. Peer sentinel LATENCY HARNESS READY. Peer report research/LATENCY_REPORT.md. No other src owner.
- Correct completion marker is installedRoute.revision, not seat.revision (request generation). Reset sets generations to0. Peer must prove actual publication and preserve tick workloads.
- C6a setup now complete, EPYC7R13 16vCPU/8cores/SMT2, root190GiB free. B0-c6a prereg frozen before launch; sweep remotePID9272 using same four budgets and three pinned repetitions, no algorithm change. Runtime deps under that checkout. Collect ~/nav-throughput-results-20260909/B0 into local B0-c6a (NOT B0, which is Xeon).
- Xeon full quality+activation launched remotePID3063502 at B1024 baseline binary. Results ~/nav-throughput-results-20260909/QUALITY. Check run.exit and JSON completeness. Not canonical Docker yet. Inspect pool/shared memory versus handoff16MiB and complete allocation ledger; current global cap256MiB includes colossal and needs explicit justification.
- metta box new session exec81159 is still transferring standard CLI credentials/settings after successful host initialization; no need to repeat launch. Failed Claude skill-transfer printed; not needed for benchmark host. Poll completion once as needed.
- Next: verify peer diff and latency semantics; build/run two fresh latency processes on real hardware; finish C6a baseline and appropriate fleet-tail comparison; retain selected exact-B first-goal latency; finish inherited fixtures/viewer/full-suite/compile shapes/containment/Docker/docs. Do NOT start H11/H2 optimization before inherited Phase10/11 done.
- Documentation checkpoint audit: tested runner outputs and reports agree; B0 summary validates72 rows,120 samples/row, nearest-rank p95 and max, pop cap. I0 report matches all9 raw JSONs. Fluffy valid JSON and existing marker counts verified. No source behavior changes this session yet; tool profiling/timing toggle documented in RESEARCH_LOOP/I0/PROFILE reports. Broader Phase11 docs audit remains pending.

- Quality3072/0missing/0illegal passed, expected route hash. Memory gap identified: conservative shared pool17510959B>16MiB; global256MiB gate insufficient. Proposed half-size default existing Dial bucket ring saves1572864B; pending peer review, no src change. Full colossal262713692B justifies256MiB cap only for total colossal.

## Continuation1

Previous turn classified progress (baseline+I0+Fluffy+platform evidence, owned host provisioned).
- Fresh origin fetch still89ahead/0behind; no rebase needed. Main Coworld remains protected.
- Full B0-c6a complete:1024 worst2.481313/2.568848ms;2048 3.168633/3.276519 PASS headroom;3072 3.820500/3.964618 PASS4/5 only;4096 4.514640/4.783795 FAIL. B0_C6A_SUMMARY.json validates72 rows.
- C6a qualification prep installed CI-pinned Nim2.2.10 via nimby, both server shapes and builds of server/baseline/four shards completed (inspect exit files). No full suite run yet; final fixtures and memory fix may require recompilation first. Docker pins2.2.4 separately; B0 uses2.2.6 for historic comparability.
- tools/record_br_golden.sh needed missing --threads:on/-d:noSignalHandler on server and verification builds. Added flags; bash syntax check passes. Existing native script otherwise fails with sanctioned WASMTIME_C_API set. No gameplay/source change.
- Owned tail host via current metta box CLI: jamesboggs-nav-throughput-m5a, i-08b7fb62b50e0740a, m5a.4xlarge,3.90.148.165. Started around22:30UTC. Setup transferring baseline bundle then pinned toolchain; task terminal handle39160 is CLI credential-copy tail, do not repeat launch. Record lifetime and retire only owned hosts when work no longer needs them.

## Continuation 2 checkpoint

- M5a setup complete, actual AMD EPYC 7571 /16 vCPU /8 cores SMT2. B0-m5a preregistered then launched PID9517 via run_nav_baseline.sh. B1024 finished; matrix ongoing, no concurrent benchmark on host. Collect remote B0 into local B0-m5a, never overwrite Xeon B0.
- Peer MEMORY_REVIEW.md confirms correct shared scope and exact Dial collision semantics. M0_PREREG.md registered. Root changed only default bucket count to131072 (max supported262144 unchanged) and added route/pop-count equality test comparing262144/131072/2 buckets under variable danger.
- Focused test_shell_body_nav_rework passes on c6a with CI Nim2.2.10, useMalloc, runtime-linked. Log remote QUALIFICATION/test-nav-memory.log, RESULT0. Candidate is not accepted yet.
- M0 interleaved parent/candidate tick plus candidate full quality/activation launched c6a PID16705, run_memory_qualification.sh, results M0/. Uses original unchanged harness, Nim2.2.6 matched to B0, B1024. No benchmark concurrency. Pool shared cap still must be added to harness after peer ownership ends, and all65 activation rows checked explicitly.
- LATENCY peer provisional finding: far waves hit2000tick cap; periodic danger generation refresh unconditionally restarts search (~63 restarts per wave). Root verified publishDangerGeneration and cancelStaleRouteJob source. This is not yet real-EC2 latency evidence. Preserve all failures. Peer still owns harness until LATENCY HARNESS READY; report/durable local LATENCY/ being finalized. Must verify on EC2 and resolve inherited correctness/acceptance implications before choosing budget or starting optimization programme.
- Root sent peer request to finish report/sentinel and release harness so pool memory gate can be added. No production generation behavior changed. Do not suppress refreshes or tune wave cap to produce success.
- No commits, viewer/fixture/full-suite completion, or Phase10/11 sentinel yet. Goal remains active.

- Peer delivered LATENCY HARNESS READY and durable LATENCY_REPORT.md/LATENCY raw data+hashes. Root owns harness again. Added explicit shared upper-bound field and pool16MiB gate to activationRow, including all allocator overhead conservatively. Not yet final tested.
- Peer now independently reviewing liveness semantics and existing dynamic invalidation practice, read LIVENESS_REVIEW_BRIEF.md; owns only LIVENESS_REVIEW.md. No src edits authorized for peer.
- Xeon originalsrc B1024 latency diagnostic launched PID3154181 using run_latency_xeon.sh, two sequential fresh processes, CPU5, results remote LATENCY/. Harness includes completion workload and pool memory gate; source unchanged, separate from M0. Collect to local LATENCY-xeon rather than peer Mac LATENCY/.
- M0 three interleaved processes each finished. Local M0/TIMING_SUMMARY.json verifies36 rows/120samples and every parent/candidate pop array equal. Parent worstp95/max2.484543/2.524236ms, candidate2.484964/2.642113ms. Both headroompass; no material p95 improvement claimed.
- M0 original quality command incorrectly used Docker-only --all and canonical guard refused before work. Failure JSON/stderr/exit retained. Correct native --quality --activation with new gated harness is running via shell session90187 on c6a; build log build-candidate-gated.log, native-quality-activation.*. This is explicitly noncanonical; canonical Docker stillrequired. Harness remoteSHA256 matched local f460932dd22fbbfb4987deacc576f8894c3f9f2d68f6bcb70bb2c82ad05f6a33 duringcompile. Transfer session12558 completed. EarlierM0DONE onlymeansscriptended, NOT qualitypass.
- Next collect native quality/memory and m5a fullB0 (poll loghandle87177), verify Xeonlatency and peer liveness review; finish Phase10/11 gaps beforeoptimizations. Nativecorrectedrun90187 ongoing; ownedc6a/m5a remain billable, originalXeonprotected.

## Continuation 3 checkpoint

Previous turn: progress, not merely waiting. This turn collected decisive measurements.
- B0-m5a complete, source20234cc7, AMD EPYC7571. B1024 worstp95/max6.055890/6.129271ms; higher budgets fail too. B0_M5A_SUMMARY.json validates72 rows. Registered floor follow-up completed B0/256/512: worst4.237955/4.292386,4.677157/4.777420,5.129240/5.168551ms. Even zero pops fails ordinary4ms p95, so budget tuning alone cannot qualify this production family. Retain B0-m5a-floor/; no selected fleet budget.
- Xeon LATENCY two processes complete, non-timing data identical to one another and peer Mac results. Farwaves all capped2000ticks (80/160 unpublished seatwaves); near18/48/51 and54/135/141. LATENCY_XEON_REPORT.md. Search-cadence failure is now real-EC2 reproduced.
- M0 native fullcorpus passes same3072/hash/pops; all64 pool shared totals manually verified <=16MiB, largest15938095B; colossal total261140828B. First native compile raced harness transfer, lacked new capfields; retained and reported honestly. Subsequent forced rebuild after verified transfer passed --activation --pool-index29 (largestpool+colossal) with new capfields; M0/gate-verified.json and gate-harness.sha256. Canonical fullDocker stillpending.
- M0 viewer Docker rebuild completed handle34466, changesonlytrackedctf_replay.wasm. Moduleeval/stamp running in nexttoolhandle; inspect log. Source notchanged duringbuild. Freshfetchstill89ahead/0behind.
- L0 registered in L0_PREREG.md, peer LIVENESS_REVIEW.md accepted with corrections underway. Preserve in-flight job only for exact ordered source equality; retain installed-route expiry everycadence to keepzonepricefreshness. Public rebuildDanger/initializeDanger remain forced; reuse onlyin scheduled path. No L0src editsyet. Need meaningful tests, GameVersionclaimscan/bump because maskschange, ninefixtures/viewer/finalqual.
- Provisioningc8i-flex attempted using sanctionedmettaCLI; RunInstances refused VcpuLimitExceeded (account208vCPU). No c8i launched. CLI richtraceback exposedGitHubOAuthcredential in tooloutput. User immediately alerted and asyncrotation request sent. Never copyrawtraceback/token toartifacts. Furtherprovisioning throughcredential paused pendingrotation andcapacity. Existingofflinebenchmarks/localworkcontinue. m8i notattempted. No tokenrevocationdonewithoutuserauthorization; no secretmatchesinresearch artifact scan.
- Existingownedhosts c6a i-0b37d010a49d1a53d andm5a i-08b7fb62b50e0740a stillrunning/billable andneeded; originalXeonprotected. No additionalinstancecreated. No Asana/push/PR/merge.

- Localcheckpoint8265f53a committed baseline/evidence/M0+viewer afterdocumentationaudit. Node moduleeval andsimstamp passed; rawpatchcontext blanklines intentionally retained (gitdiffcheck excludes only stored.patch artifacts). No remote push.
- L0 implemented aftercheckpoint: private rebuildSelectedDanger shared byforcedpublic rebuildDanger andscheduledpath. Scheduledpath comparespreviouscount/orderedpoints, skipsraster+packed+generationonlywhenidentical, refreshesdangerTick andstillclearsinstalledRoute. Changedbranchunchanged. No newretainedstate orsentinel. Addedtwo focusedtestscovering unchangedinflight,expiry,removal/return/reordering. Fullfocusedtest_shell_body_nav_rework passes on c6a Nim2.2.10.
- Peer ownsonly L0_CODE_REVIEW.md for independentdiffreview against8265f53a; nosrcownership. L0 productiontiming+latency script run_liveness.sh launchedc6a aftertestscomplete; resultL0/,threeinterleavedM0parent/L0candidate --tick each andtwofreshcandidate --latency. Nim2.2.6 CPU5. Parent body_nav fromremoteHEAD20234cc7 but ringremainsM0 131072, asintended. Allresultsexitsretained; no acceptanceclaimyet. Originalpublicinitializerforced.
- c8i/m8i benchmarkingstillpendingquotaandGitHubtokenrotation; userasyncquestionpending. Do notrerunprovisioningorprintCLIexceptionlocals. Existinghostsusableindependently.

## Continuation 4

- L0 c6a done: all3pairedtiming runs and2latency processes complete. m5a all3pairedtimings complete, latency stillrunning PID12047 at lastcheck (runner11262). FullreportsL0_REPORT.md. Bothhosts timingonlymodestlybetter;m5astill5.740836/5.838279ms fail. c6afarstillonly3seats/wavepublish, cap2000 fails. L0 notacceptedqualification.
- L0 testsstrengthened perpeerreview: forcedrebuild comparison,selfmovementwithoutreordering,forcedinitializerstillincrements. Macfocused11testspass. RebuiltL0viewerandmodule/source-stamp pass. Runtimebehavior experimental,notshippable;GV/fixturescyclependingacceptance.
- Peer FLOOR OPTIONS READY, QUALIFICATION_FLOOR_OPTIONS.md withL1review. One shared packed scratch~85466Bpool/~778752Bcolossal fits ifledgered. Exactcompare+swaponlychanged protects in-flightwork withoutweakeningchanged-tablebarrier. L1 notimplementedyet. Ordered-source reuse alonemissesreorders. Cross-seat rasterreuse couldflatterthisidentical-startworkload; do notclaimrealproductionfloorreductionfromitalone. Fleetexclusionisoutsideauthorizedlocalchanges; noinfrachangeperformed.
- c8i/m8i remainingplatformmeasurementblockedbyquota+pendingGitHubtokenrotation, butlocalqualificationworkcontinues. Noadditionalprovisioningattempt.

- L0 checkpoint c5f39376 committed with explicitfailedqualificationreport andrebuiltviewer. Fetch revealed newmaincommit e0a789af (tools/glory only); synced immediatelyvia localmerge beforeL1 edits. Current HEAD getwithgitrevparse. No navsourcechangefrommain. Notecheckpointcommanddidnotstoponbehind1; correctedbymerge,notignored.
- L1 registered andimplemented: one shared packedWeightScratch allocatedatnavactivation, explicitlycountedinowner/allocator/sharedgate; packinto scratch, exactseqcompare, swaponchanged, generationpreservedonlyforequaltable. Publicinitializeusesforce=true; scheduledexpirykept. L0hitavoidszeroingalreadyemptylargeinstalledroute. Focused12testspasslocally; peerreview L1_CODE_REVIEW.md underway.
- L1 c6a runnerPID20898 active,run_packed_identity.sh; copies priorL0candidatebinaryasparent, buildsnewcandidateNim2.2.6,threepairedtickprocesses,twofreshlatencythenfullnativequalityactivation. ResultsremoteL1/. No concurrentbenchmarkonhost. Waitingforactualsuccess/failure,notclaimedaccepted.
- Actual serverFluffy attempt launchedlocallyusingunmodified tools/run_shell_demo.sh,port21894,TMPDIR=research/PROFILE_SERVER,ProfileTicks240,tracepathserver-trace.json. PIDinPROFILE_SERVER/launcher.pid (printtoolresult). ThisdoesnotgateMacwallclock; neededactualguestinvoke traces beyondsyntheticprofile. Scriptprobe/buildmayfail; inspectlauncher.log andrealPID beforeacting. Once tracecomplete,stoponlythis launcher soits trapcleanspresence/serverchildren; retainlogs. No hostedupload.

## Continuation 5 checkpoint

- L1 c6a fullycomplete:12localfocusedtests,peerreview,3pairedtickruns,2latencyruns,full3072quality+65activationrows. Samequalityhash; poolsharedmax16023601B,colossaltotal261919620B. ReportL1_REPORT.md/rawL1-c6a/. L1 failsregisteredallpublish2000tickcriterion: only3seats/farwave; ZEROrestarts;80completions/81admissionsover2000ticks re-requestingseats0/1/2 whileothersneveradmitted. No claimdoublingoracceptedliveness.
- ACCEPTANCE_MAP peer audit found2000tick allpublish was OUR experimentcriterion, not inheritedPhase10gate; retainfailures/reportcensoring, do notinventgate. ExistingstableSJF+expiryexplainsremainingadmissionstarvation. m5afloorstillindependenthard4/5failure. Activationratio gatehistoryneedsverification: rawL1fullratio poolmax2.563,colossal2.420; currentpassmemoryonly. Don'texclude mixednav fromratio toclaimpass.
- Peer latestunit COMPILER_REVIEW_BRIEF.md: investigateproductionNim2.2.4 vsbaseline2.2.6,exactCPUtargetflagswithoutfastmath,primaryGCCdocs. Also correctauditGVclaim(remotewire-over-identityGV63, next64) andupdateL1evidence. No code/benchownershipforpeer.
- ActualFluffyservercaptureCOMPLETE viaunmodifiedrun_shell_demo.sh foregroundPTYsession84213,port21894,localMacinformational. Trace88044events,1728invokeStep,8invokeInit,246danger/planningevents. PROFILE_SERVER/REPORT.md,summary.json,manifest.json,trace.sha256. SentCtrl-C aftertracecapture;toolreturned130 andlsofconfirmednoportlistener. InitialnohupPID33572absent/noRUNDIR,recordedfailedlaunch;foregroundretryusedafterauthoritativeabsence. No hostedupload/productionmutation.
- FullserverL1compilechecks linked/stub initiatedlocaltoolsession57896; poll/readL1-local/server-check-exits.json beforeclaiming. L1viewer nowstale again; noL1commituntilcheckpointviewer/audit. Sourcechanges3filesbody_nav,test,harness,baseHEAD1aeffbd2. L0checkpointc5f39376; mainmerge1aeffbd2onlytools/glory. Next64GVclaimnotyetmade.
- Potentialsafeprovisioningpath identifiedbutNOTexecuted: existingmetta.setup.tools.sandbox.ec2.launch_instance helper canlaunchbarebenchmarkhostwithtoken-freeuserdata; bypassesonlyCLIcredential-loading/tracebackpath,notAWSquotaortoolchain. ReusehelperthroughNix andofflinebundlebootstrap afterfreeingownedhostslot, ratherthanusingexposedGitHubtoken. No hoststopped/terminatedyet; c6a/m5a idleaftercompletedruns,neededforremainingwork. Quota208andtokenrotationstillpending; no c8i/m8ilaunched. Do notread/printEC2UserData (earlierCLIembeddedtokenthere).

- L1 fullserverlinked/stubchecks both exit0. L1viewerDockerbuild nowrunning; do noteditsrcuntilsnapshotfinishes, pollcurrenthandle/log beforecommit. No newproductionacceptanceclaim.

## Continuation 6

- L1 checkpoint d88fe68d committed after syncing origin/main (judge documentation only). Both server shapes and viewer passed; L1 remains a failed all-publish experiment, not doubled throughput.
- C6a stopped, disk preserved. Credential-free helper launched c8i i-045ddd6df51150967 at 98.91.229.56; setup complete, baseline runner PID4199 active. C0 m5a runner14019 finished timing and is running quality/activation. Do not overlap benchmarks.
- S1 preregistered; portable positive float conversion change and boundary tests now local. No S1 benchmark result yet.

- C0 m5a complete, quality/activation exit0. Native worst5.793836/5.857997ms, Docker5.404456/5.496837ms; all pop arrays equal; both fail whole-body gate. C0_REPORT.md. S1 boundary suite13tests passes locally; peer review pending. S1 m5a runner21049 active, ~/nav-s1.log, resultsS1/, three pairs then quality/activation. C8 B0 runner4199 reached3072 and is finishing4096.

- B0 c8i complete and retrieved: all four budgets pass headroom, B4096 worst3.574419/3.822601ms. B0_C8I_REPORT.md. Verified no benchmark before rotating owned slot. C8i now stopped; m8i i-0382a6e0a77c014d7 running54.91.165.255. Offlinebundle/setup transfer session91356 active; setup not started yet.
- S1 three pairs complete: refresh1.105472->1.080091ms worst, whole-body5.721624->5.713180ms p95; no meaningful whole-body gain. Fullqualityactivation runningPID21049. S1_REVIEW.md says exact valid finite raster inputs, undefined invalid conversion pre-existing; no extra production guard warranted. Viewer build58402 active. Peer now RASTER_REVIEW.md codegen/precompute investigation, no source ownership.

- m8i bundle transfer91356 completed. Setup launched throughssh57347; inspect returnedPID and ~/nav-throughput-setup.log. Same savedbundle SHA expectedf5f33cad75c66f39661b7b85a59779d8ad4fc15ab82fc85eef3a626ffc1fc5d8. Baseline runner uploaded asrun_baseline_c6a.sh but notstarted onm8i.

- M8i setup initialPID2849 failed because transfer usedbaseline.bundle while script expectsnav-throughput-baseline-20260909.bundle. Preservedinitiallog, renamedverifiedownedinput, retryPID3449 completed. Actualbaseline nowPID4537, ~/nav-baseline.log. No duplicatedbench.
- S1 viewerbuild58402 andqa_module_eval passed module/GV/source-stamp checks. Syncedorigin/main5edb2bce via localmerged5967c82 beforecheckpoint; onlytools/glory+glorydocs changed. SourceS1unchanged.

- New major scopefinding verified againstsource: currentmanifestbattle-royale-s2 usesbrpool16 (11largermaps) andexplicitgunRange1300; frozenharness/corpus64S2mapsand331. Server passesconfig.gunRange, sopeer1050defaultclaimnotcorrect. PRODUCTION_SHAPE_FINDING.md recordscoveragegap; donotclaimliveconfigurationverifiedoroldbaselineprodqualification. NextG0 isolateactualrange then11mapcoverage withoutweakeningfrozen3072qualitygate.

- M8i baseline4537 completed allfourbudgets andrawretrievedB0-m8i. B4096 worst3.537775/3.699664ms. Hostidlebutretainedfornextproduction-shapecomparison. S1 m5a21049 stillliveat9min04, qualitycomplete/all64activationrowsdone, colossalrunning. Do notrestart.
- PeerRASTER_REVIEW.md nowwritten; investigateexactcell-centerblockedtable orinlining. Need readfullreviewandvalidatebeforeimplementing. Userinformedconfigured1300px and11-mapvs64-mapcoveragegap. No qualification sentinel.

- S1 fullydoneexit0, allqualityandmemorypass, poparraysmatch. S1_REPORT.md has exactroutehashfromrawJSON (useartifactratherthanearliermanuallytranscribedhash). Candidate retained2.30%weightrefreshimprovement only. M5aidle, sourceparentrestoredbyrunnertrap. Viewercheckpass. Readycheckpoint.

## Continuation 8

- G0 finished22645, rawretrievedG0-m5a; 331worst5.691996/5.807979ms vs1300worst13.982918/15.593524ms. Dangerp95max8.078249ms; weaponp95max11.960938ms acrossdifferentrows. No percentile subtraction/addition. G0_REPORT.md. M5aidle andsourcesrestored.
- Harness --tick-gun-range onlyaffectstick, default331; --configured-tick readsmanifest1300/brpool16 andcovers11maps withactivation+sixrows. Shared selectPairs exportedfromexplicitcorpuswriter, nofixturemutation. FirstNimcheckfailedquotinglabel; fixedcheckpassed (bothlogsretained). PeerG1_REVIEW.md pending.
- G1 m8i PID5447 active, ~/g1-input/run_g1.sh and~/nav-g1.log; results~/nav-throughput-results-20260909/G1. InputfourfilesS1body_nav/query+harness+corpuswriter, snapshots/traprestore. One11-map diagnostic screen, notrepeatqualification. Rootlocalchangesaretoolsharness+writer+researchdocs only; S1sourcecheckpoint29cf46f3.

- G1 m8i5447 completeexit1; all11mapsrecordedandrawretrievedG1-m8i. All11failtimingand16MiBsharedcap; worst15.015300/15.193815ms onmap3; maxshared30755007B map4. Totalmax61776703B under256MiBdoesnotwaivepoolcap. G1_REPORT.md. Bothm5aandm8iidle; c6a/c8istopped,disksretained; protectedXeonuntouched.
- G1 reviewpendingClaude; localpeerprobe underG1-local-peer. Nextinvestigate existingmap reference lifetime aroundselectPairs: outermapremainsinscopewhileactivation/tickallocatesnewmap. Ledger is pernavsystembutRSS/cachecontextneedsclarifying; scope selectionmap in a block beforefinaltiming. PreserveinitialG1negativeevidence. No productionR1sourceimplemented. ProposedR1precomputedcell-centerwalltable needsledger;weaponfloorandgiantshared-memoryreductionalso required.

## Continuation 9

- Sourcefreshness96ahead0behind checked. Peer G1_REVIEW.md saysdiagnosticcorrect, notesusage/provenance/lifecycle; root appliedexplicitvariant/map_path metadata, usagepoolmeaning, and scopedselectPairs map toblock so it is released beforemeasurement. OldG1evidenceremainsinitialscreen; subsequentbaselinepairsuseupdatedharness.
- CriticalM1ownershipdefectverifiedinm5aS1generatedC: dangerKernel/perimeter areeqdup perseatbutledgercountedonce. Root GEOMETRY_ACCOUNTING_CORRECTION.md appendedtoM0/L0/L1/S1/C0/G1reports. Peer independentlyconfirmedMEMORY_SHARING_REVIEW.md. Underreported32seatpayload~1.013MB331/~13.718MB1300 inclpriorsequenceoverhead; nominaltotalcapverdictsunchanged,giantsharedstillfails.
- M1 preregisteredandimplementedprivateDangerGeometry refowner kernel/perimeter/radius. Rootsrcbody_navonly; ledgercountsowner+overhead. Focused13testspassed, localgeneratedC refdupbodyonlynimIncRef(savedM1-candidate-generated-c.txt), parentseqdup snippet saved. NoR1sighttableyet.
- M1 m5a PID23784 active, ~/m1-input/run_m1.sh, ~/nav-m1.log, resultsM1/. Threepaired1300tickruns finished; fullqualityactivation running(pool14at3min05). Do notrestart. Inputfourfiles copied withownbackup/traprestore. Sameharnessbotharms; parentS1, candidateM1.
- PeerWEAPON_RANGE_REVIEW.md proposesexactintegerDDA/ties-even rayClear and range-squaredcompare. Root researchedRedBlobline-drawingprimaryguide; no W1sourceedityet. Do notassumenewfixturebytesidenticalbecausebotsnondeterministic. Foractualmaskcomparisonaddper-tickencodedmasks tocommonharness beforepairedW1.
- Newremainingmemoryaudit: seq.capacity mayexceedlen, notablyM1sharedperimeteradd-grown. Nim2exports system.capacity. Peeraskedtoauditmixedgraph/index/nav retainedcounts; do notclaimexactallocatedupperboundbasedonlyonlengths. Do notrelaxcaps.

- M1 fullserverlinked/stubchecks both exit0; harnessreviewfixcheckexit0. M1-check-exits.json. Three1300pxm5apairs complete: parentworst13.835260/15.513166ms, candidate13.792467/15.353760ms; allpoparraysmatch. No substantialbodytimespeedup. Fullqualityactivationstillrunning23784; noM1commit/viewerbuildyet.

## Continuation 10

- W1 implementedintegerincrementalrayClear only, wallpredicate/distance/boundsunchanged. Tests262144single-wall smallrays+20000seededlong/reverse comparisons pass; body-mapandbody-seat suites pass. Testlongwidthnowextended8192toincludecolossal; reruncurrenttesthandle. PeerW1_REVIEW.md independently176Mcoordinatechecks0mismatches; rootcorrectedpeerfalse3312maximum(proofmustinclude6422colossal/theoreticalvalidatorbound8388608).
- Harnessrecords126ticks(initial+warmups+measured)*roster encodedmasks outsidebodytiming, commonbothW1arms. W1m5aPID25438 active ~/w1-input/run_w1.sh and~/nav-w1.log. Three1300pairsdone, allmasks/poparraysmatch; parentworst13.820488/15.464153ms, candidate11.448389/12.762947ms. Fullqualityrunningpool60at5min29. RawW1-m5a partialretrieved; donotrestart.
- M1fullquality/activationdoneexit0rawM1-m5a; unchangedhash/pops. M1_REPORT.md sayslogicalledgerpassnotfinalallocatedproof. W1inputusesM1priorcapacitycounters; keep unitsdistinct.
- M2capacityaccountingimplemented inbody_nav,body_route_query,body_route_index,body_hazard. Uses system.capacity forseqpayloads/headerpresence; preservesseats.lenexistenceguard. Newextrareservedbridgecapacitytest passes (14focusedtests). No compaction. CAPACITY_AUDIT.md. AddedactivationResult catchesBodyMapError intoexplicitfailedrow soallmapdiagnostics surviveconstructorcaprefusal.
- M2m8iPID6444 active ~/m2-input/run_m2.sh, ~/nav-m2.log, resultsM2/. Runs65activationthenconfigured11mapdiagnostic. InputincludescurrentM1+W1+capacitycounters+harness; onlyallocationresultsareM2metric. PairedtimingsarenotM2claim. Sourcesbackup/traprestore. Rootallunitsstilluncommittedsince29cf46f3; preserve separateexperimentpatches/results forcheckpointing afterverification.

- W1andM2completeandrawretrieved. W1full3072qualitysamehash/pops, zero missing/illegal, pre-capacityledgerpassed. W1_REPORT.md. M2all65capacityrows pass poolmax16059225B,colossaltotal265221452B; configured11allsharedfail,max31340947B. M2_REPORT.md. Bothhostsnowidleafterconfirmedprocesscompletion, sourcebackupsrestored.
- Liveconfigurationreadback attemptedthroughbrokerobservatory.db.read, per-sessionID, sanctionedNix/uv: DBconnectionrefused atRDS5432. Credentialneverprinted; LIVE_CONFIG.json andLIVE_CONFIG_DIAGNOSTIC.json containonlyfailurecategory. UnauthenticatedGETcoworldsreturned403. No livevariantclaimverified; sourceconfiguredscreenlabelstands.
- PeerHAZARD_LEDGER_REVIEW.md pending: scratchstoresrefs tohazard+safeCachebutretainedBytescurrentlysizeofonly, activationRowbare navneverinstallscontext. Needresolvefullcapownershipbeforefinalmemoryclaim. W2directwallread/checkelisionproposalnotimplemented; reviewproofagainstmapbound8,388,608requested, no productionguarddisabled.

## Continuation 11

- M3 m8i PID7394 completed; raw M3-m8i retrieved, 65/65 activation rows pass: shared pool max16,150,745B, colossal total266,089,555B. All11 configured maps still fail shared cap, max31,521,758B. M3_REPORT.md; context retention peer review pending. m8i idle confirmed.
- W2 m5a PID27076 three pairs complete, all masks and pops identical. Parent worst11.543802/12.864276ms, candidate10.375292/10.534817ms. Full corpus/activation still running; raw partial W2-m5a retained.
- R1 preregistered, implemented exact per-cell sight predicate in reference-shared DangerGeometry; new capacity/owner fields ledgered, checks retained. Parent snapshot R1-parent-body_nav.nim. Focused15 tests passed. No timing claim yet. Peer owns M3_REVIEW and GIANT_MEMORY_PLAN only, root source ownership unchanged.

## Continuation 12

- Checkpoint reconstruction proceeds in separate owned worktree nav-throughput-checkpoints, branch james/nav-throughput-checkpoints, based71a61745. Local commits bed15e11 G0,9e4971f1 G1,5a6c4963 M1,da13e2c7 W1. Each source unit has Docker viewer rebuild and stamp/module check. M2 is prepared there, viewer passes; first native test failed missing bitworld because new checkout lacked generated nim.cfg. Ran sanctioned nimby --global sync nimby.lock, rerun14tests passed. Preserve both logs. M2 not committed yet at this entry. Root research source remains untouched by checkpoint reconstruction; do not overwrite it with the older checkpoint source. Input snapshots are ignored checkpoint-inputs/, plus raw source patches and eventual commits.
- R1 complete: m5a1300px threepairs p95/max10.367423/10.601260 ->7.984246/8.777049ms; dangerp95 max8.101009->3.609313ms. 331pxfollowup5.693231/5.729582 ->4.572689/4.644561ms. Allmasks/pops identical; fullm8i3072 quality unchanged, all65 original memory pass, configured11 shared fail. R1_REPORT. All65 memory deltas exactlygridcells+32ownerfields+16allocationallowance.
- W6 complete: m5a1300px pairs8.201069/8.788592 ->5.960683/6.704114ms; weaponp956.005851->3.173188ms. Allmasks/pops identical; fullquality/activation passes andbothlocalservercompile shapes pass. W6_REPORT. Rootbody_map includesW6 (major-axis specialization), superseded locally by currentW7prototype.
- W7 preregistered after Hart/SciPy research and peer CLEARANCE_SKIP_REVIEW. Reuses exact immutableChebyshevclearance toskipknown-empty ray samples; int64 floorDiv for multistepminoraxis, existingincrementalpath forclearance1. Existing262144+20000 andnewsaturation/border tests pass. tools/investigate_body_ray_clearance.nim verifieszero-wall equivalence/boundary/eight-neighborLipschitz forall76maps. Initialm8i10227 verifierfailed atfirstconfiguredmap becausebr_map_pool entriesarealready specs, notwrapped in spec; no timingrun. Raw W7-m8i-attempt1, originaltoolW7-clearance-initial.nim retained. Fixedformatselection, repairedrunnerusesdistinctW7-repaired resultsdir, launchpendingtoolhandle94437. Do not overwriteinitialfailure. RootW7timingnotlauncheduntilclearancepass.
- Peer BRIDGE_ENCODING_REVIEW recommendsuint8directionperbridgestep first memory unit (~3.8MBgiantsaving), preserve reverse reconstruction and directed paths. NOT IMPLEMENTED. GIANT_MEMORY_PLAN correctedclampedboundaryarithmetic andint8parentdirection suggestion. Needcompletecheckpointbacklogbeforememorysourceunit.

- NEW USER RULING: up to4x non-colossal memory caps allowed as needed. MEMORY_CAP_RULING.md records exact instruction. Choose32 MiB shared (2x), keep256 MiB total/colossal. Code cap update pending branch sync; no prior raw failures rewritten. Drop unnecessary giant-memory compression implementation; preserve proposals only.

## CAP32 and D0a follow-up

Primary consolidated through W7 addaad7a with newer notes restored from verified external backup; SCOREBOARD reconciliation retained all experiments. Synced origin/main23e17ecd (unrelated stranger-walk tools). CAP32 checkpoint a875b16f implements32MiB shared cap, passes76 memory rows and frozen3072 quality; configured timing and75 non-colossal activation ratios remain failed. D0a paired m5a improves worstp95 5.948740->5.838907ms, exact masks/pops/fullquality/ledgers; viewer checkpoint in progress. Owned m5a and m8i runs complete, no overlapping benchmark processes. Claude reviewing exact ray-prefix sharing as a possible later hypothesis; no implementation authorized by the research card yet.

## Activation and wavefront continuation

- Retained A0 at872e5499: four undirected fine-edge tests, full76 graph arrays and3072 quality unchanged, mixed construction20.88–21.91% faster. A1 ataa3f7f79: exact two-edge bridge shortcut, about50% further mixed construction improvement; all76 memory and fullquality unchanged. Native repeated activation now passes63/64 frozen non-colossal maps plus colossal; configured11 single-screen activation allpass. Only frozen48 remains2.081–2.097x. Tick selection remains incomplete and B1024provisional.
- WF0negative checkpoint1d8d1644:13/14m5a rows slower. WF1 corrected operation model fails both preregistered range thresholds; no implementation. Root/peer next hypothesis is trace-gated exact shared per-source LOS reuse; CACHE_TRACE_RECON_REQUEST.md, peer CACHE_TRACE_PLAN.md pending. No cache implemented or additional cap increase.
- bd03d778 fixes harness activation verdict: explicit memory/time booleans,2x/3x integer-time check, aggregate requiresboth. FrozenA0/A1/C1 JSON predates fix; manual ratio evaluation remains necessary. Mac refusal smoke checked reporting only.
- A2diagnostic Fluffy profile DONE on native m8i:map48 index mean300.175ms, pockets133.170,validation58.099,sidefields51.555,legalmoves49.324. A2_PROFILE_REPORT.md; no productionA2optimization. m8i jobs finished and restored sources.
- C1 current native-vs-production-Docker comparison source872e5499 is still running on ownedm5a:initialattemptfailedmissingBuildx, packageinstalled0.30.1, repairedPID40142,~/run_c1_repaired.sh,~/nav-throughput-results-20260909/C1-repaired,~/c1-repaired-launch.log. Do not overlap m5a timing. Initial and repaired evidence kept separate. Three331pxpairs and first1300pair fetched; initial1300Docker p95/max5.133279/5.157380ms stillfail. Waitforallpairs andDockerquality/activationbeforefinalC1report.
- Main merged through25a8cc30; GV65 and viewer stamps current. Final ninefixtures/fullqualification/containment/Phase10/11sentinels stillpending, no remote publication/Asana/prod writes. Usermemoryruling implemented32MiBnon-colossal shared,256MiBtotal/colossal unchanged.

## C2 integration and native activation attribution

- Local checkpoint b971d898 retains C2 shared visibility caching over V1+A4+H1. Full 3,072-case quality has H1 hash ee2488d32085fb4de3457c4cf841298c14b87add2225964d934f80f2a7c1013d and 31,814,084 pops. All 76 integrated memory rows pass, maximum non-colossal shared bound 32,464,268 B, maximum total 229,158,347 B, including the cache owner allowance corrected by 16 B. C2_STATUS.md preserves all results and limits. No cap increase beyond 32 MiB is needed.
- Isolated C2 m5a short workloads fit B1024 headroom but configured timing passes 0/11, worst p95/max 6.484532/6.680327 ms. All 27 recorded-trace native pairs improve total/p95 with exact raster chains. Changing-source diagnostic regresses up to 1.08%; this negative prediction result is retained.
- A5 real native Fluffy profiles are complete on m5a and m8i, with identical source hashes and counters. Map48 index construction means 840.828/252.443 ms, pockets 445.193/133.749 ms. Pixel work does not show uniquely worse host scaling. A5_NATIVE_REVIEW.md and raw A5-m5a/A5-m8i traces support the next exact activation screen.
- C3 row-cursor arithmetic is provisional in root source for regression tests. All local cache tests and full quality remain exact; m8i recorded-trace totals are flat while 23/27 p95 pairs regress up to 8.06%. Repeated-source diagnostics improve 5–13%. Native m5a full paired configured runs continue under run_c3.sh. Do not describe C3 as retained or choose B from partial results.
- Claude owns the isolated nav-validation-symmetry A6 direct/eager/lazy standability screen and A6 artifacts. Root owns primary source, C3 and native hosts. A6_ROOT_REVIEW.md specifies the scope and proof obligations. Protected original checkout and m6i ~/metta remain untouched; no remote publication or external task writes.

## Native follow-up queue and latest results

- A5/A6 evidence checkpoint138683ec: native m8i lazy construction improves3.45–4.12%, direct loses11.1–11.7%. Full lazy m8i quality, all76activation/memory rows and7focused index tests pass; all76retained ledgers equal A4. No source integration. m5a A6 runner58413 waits for C3 PID56947 and its DONE, then runs the same frozen three-arm screen.
- C3 m5a first pair is complete:66 exact masks/pop rows, worst p95 6.479911→6.357101ms,0/11maps pass. Runner56947 continues allthreepairs; root source still provisional C3. C3 local9cache+17nav tests/fullH1quality/both explicit server shapes/viewer checks pass. m8i realtrace tradeoff is still23/27p95 regressions, flat totals.
- C5 v2 m8i native trace is DONE, raw C5-v2-m8i/. It proves first fills, not recurring danger work:10/120measured samples at16seats,26/120at32, none aftertick31. Mean measured-fill bitmap replay731–740us, weightpack421–424us. All6traced/count masks/pop rows agree. Profiled timing is attribution only. m5a runner59153 waits for A6PID58413 and A6-screen/DONE, then runs the same C5v2snapshot.
- C6 read-only count screen sees16–30% of replayed cells in full64-bit words; no numeric count gate had been preregistered. Root authorized a C2-based, full-word-span micro screen in peer nav-source-cache only. C6_ROOT_REVIEW.md defines exactness, five paired native micro runs and a10%replay threshold before whole-body work. Peer freezes C5v2 first; no primary/native source edits authorized for peer. Root owns native runners.
- Current retained checkpoints: b971d898 C2,8d965a99 corrected canonical memory/latency guidance,63d2020d C4negative full-raster-reuse screen,138683ec A5/A6evidence. Upstream remains2bb289f8 at lastfetch, behind0. No completed P10/P11 or finalB claim.

### C3 decision after final peer review

C3 rejected: 179/198 configured p95 rows improved about 1.25% median, but 0/11 maps passed and 23/27 recorded-trace p95 pairs slowed. Restored only the owned C3 source and viewer to retained HEAD; preserved the multi-range cache regression test and all evidence. C8 remains isolated pending native measurement.

### Native completion C8 and A6 m5a

Both runners completed and restored owned hosts cleanly. C8 rejected:27/27actualtrace totals slower,26/27p95 slower; quality3072exact. A6 m5a65+11qualification:62/76activation time,76/76memory,0/11tickmaps. A6 remains isolated. Peer C7tools-only micro active, A7early-visited proposal pending peer review. Primary source is retainedC2, HEAD98c71887.

### A7 local exactness screen

After peer A7_REVIEW_READY, root created nav-early-visited at fixed A6 experimental basef9dff753. Owns only that tree and A7evidence. Four materialized arms: eager, eager-early, lazy, lazy-early; predicate move only. Local runner session99122. Initial build lacked generated nim.cfg; fixed with canonical nimby --global sync nimby.lock and preserved failure log, then reran. No primary source changes. Native A7 runner uses real public constructor without Fluffy/counters for timing, separate from prior A6 attribution.

### C7 and A7 native progress

C7v2m8i completed, all60micro rows exact; list/C2 ratios0.4138–0.5107 pass20%replay gate. m5a replicatePID63545 active. Peer full64-slot cache candidate authorized in C7_IMPLEMENT_REVIEW.md, with current memory proposal below64MiBshared/256MiBtotal and no primary cap/source change.

A7local fourarm checks complete, additionalv2exact-edge coverage finds12real differences preserved across allarms (original craftedpinch failsbothmodes; correctedcoverageclaim). m8i publicconstructor runnerPID43378DONE/clean; combinedlazy+early median~5.2%gain vs eager, early-onlysubthreshold. m5ainputs uploaded, do notlaunchuntilC7runnerDONEandrestore. PrimaryHEAD7fe0c3a3, src/viewer/testclean.

### C7 full v1 negative and ownership diagnosis

PrimaryHEAD e10b6f11, no primary src/viewer/cap changes. C7fullv1m8iPID44713DONE/clean: all27trace pairs exact but totalratio1.4794–1.6740median1.5978; changing-source regimes1.8106–1.9725, repeated0.6829–0.7744; full3072qualityoldhash. Raw C7-full-m8i/ and summaries retained. m5av1PID66386stillactive (do not touch native checkout untilDONE/restored).

Root generated-C audit proves new addVisibleCell localcache ownership eqcopy/eqdestroy with nimIncRef/nimDecRefIsLast pernonzero firstvisit, unlikeC2directfield access; artifact C7-full-generated-owner-C.txt. Its contribution to slowdown is unmeasured until correctedpair; do not call memorytraffic solecause. Peer nowowns minimal correction in C7_REFCOUNT_REVIEW.md, preservesv1.

C9counts-only proposal independently matchedall9sequential LRUtraces (C9_ROOT_COUNT_CHECK.json). No C9implementation authorized. First/second-hit materialization incomparability and trace-end censoring documented in rootreview; C5synthetic no-fill attribution is not a real-play stage-shareproof. Both owned nativehosts nowhave c7-full-input complete; runner run_c7_full.sh. A7subthresholdresultscheckpointed e10b6f11.

### C9 native conversion screen

C7 corrected m8i DONE and source restoration verified; all3072 quality exact oldhash. C9 tools-only native micro launched m8iPID49030 via run_c9_owned.sh, frozenC2parent, CPU5, five rounds/eight configurations, rotatingthree arms. No primarysource/cap changes. m5aC7correctedPID68495still finishing quality; do not overlap. Peer C9 MICRO READY and C7 REFCOUNT PEER REVIEW READY verified; peer agrees eagerC7notadoption.

C7 corrected m5aDONE/restored, full3072qualityexactoldhash,27trace/24regimepairs exact but18/27p95slower. C9m8iDONE/restored,40rows exact, all8medianconfigurationspass preregisteredlimits. m5aC9replicatePID70584nowactive, run_c9_owned.sh, no overlappingjob. Peer owns documents-only C9plan before implementation; must account for retainedbitmapPLUSlist.

C9m5aPID70584DONE/restored; all40rows exact and8medianconfigurationspass. C9microbothhosts passes; fullcandidate notyetimplemented. Peer correcting estimate-not-bound wording and slotpadding in memory plan; root will gate actualtrace/miss and wholebody before retaining.

C9 FULL READY verified, frozenad45ee07, source/tests/generatedC/counts reviewed. Nativefull m8iPID50020 andm5aPID71922active, no overlap. A8 COUNT REVIEW READY verifies inputs; original1000callminimum corrected pre-run against existingA6total457to100repeatedemptycalls plus25%dequeues. Rootowns A8diagnostic in nav-early-visited; peer sourcefrozen anddocs/handoffonly.

A8countdiagnostic DONE/restored: map48exact189repeatedemptyfailures,356784/805625dequeues44.2866%, zeroresult/dequeuemismatches; configured3/5/6zerorepeats. Pre-run corrected100calls/25%dequeue criterion passes. A8_COUNT_RESULT.md; rootrequestspeerplanscreen, no memoizationimplemented. C9fullnative stillactive m8i50020/m5a71922.

C9fullbothhostsDONE/restored; m8i17/17screenchecks pass, m5a3changing-source medianfails1.0140/1.0164/1.0119vs1.01. Allquality/outputs exact; noadoption. IsolatedintegratedC9cache13/13passed, snapshots/patch saved thenownedfilesrestored in nav-deferred-cache. Primaryunchanged. A8v2all76countsDONE/restored1991calls; onlymap48recurrence. First128failurekeysserveall189hits, maxobservedtargets50; bounded128x64arrayplan underpeerreview, no memoimplementation. Bothnativehosts idle.

A8 memo experiment implemented in nav-deferred-cache from retained A4; primary unchanged. Five focused tests pass; all 19 retained sequence field hashes and stats identical on all76maps. Counted map48 confirms189hits and356784saveddequeues. Actual temporary memo37896B, no retained increase. Native A8-memo runner launching on both idlehosts (m8iPID52173, m5aPIDpending), CPU5, threeinterleavedpairs. Source parent/candidate/run under A8/memo. Peer C9diagnosticdocuments complete, A8source review pending. Existing tools/profile_body_route_index.nim change in nav-early-visited left untouched.

A8 native m8iPID52173 andm5aPID74264 DONE. Frozenrawresults retrieved. m8i6.15593%gain passes, m5a4.96858%fails5%criterion; candidate rejected, no fullqualification or productionintegration. Local exactpath check stillrunning; peer source review pending. C9wordingcorrection pending.

After f6d906de: both native hosts remain idle and A8 sources restored. Root C10 tools-only counts on retained C2 (nav-deferred-cache) completed six maps/ranges with64whole-map origins each; safe four-cell groups cover98.81–99.70%of setbits. No production source edits or native timing yet. Peer nav-research-peer is reviewing NEXT_UNIT_REQUEST.md plus C10_SIMD_PROPOSAL.md/C10_COUNTS_RESULT.md; no implementation authorized to peer. Next plan file pending.

C10 frozen three-arm native: m8i launch52986 DONE;90processrows exact, scalar1300ratios0.7145–0.7278, SIMD0.4398–0.4520, incrementalSIMD0.6148–0.6222; all localchecks pass. Native m5a launch75157 nowrunning, samehashes/runner; root execsession75566 observes launch chain, do notrestart. Peer owns C11 pureinteger row-span proof only. C10/m8i-summary.json andrawfiles retrieved; no productionchange or fullqualificationyet.

C10m5a75157DONE, bothhosts restored, rawdataretrieved/evaluatorpassed. SIMDselectedfornextscreen bypre-set20%/5%rules; all180microprocessrows exact. Rootwillpreparefullsourceisolatedcandidate; primaryunchanged. PeerC11countsactive, C10resultreviewqueuedafter.

C10 full-source native launched m8iPID54502 andm5aPID76802, C10-full resultdirs, frozenC10/full source/runner. Five pairs of9traces/4regimes plusstrict3072quality. Rootlocalnav-deferred-cache nowholds isolatedcandidatebody_nav (othertrackedfilesclean); primarysrcunchanged. Fullsource local9cache/17navtests,5crafted/256border andbothservercompilechecks pass. PeerC11counts plusC10micro-result/fullsource reviews active. Do not restart nativejobs whilethesehandleslive.
