## Per-episode compiled-module cache and shell status encoding.
##
## The cache is keyed only by module content hash. Seat-local decisions such
## as manifest-name binding stay in `compile_plane.nim`; keeping them out of
## this table is what makes cross-seat deduplication safe.

import std/[options, tables]

import std/os

import canonical_fast, manifest, types

const ModuleCacheRuntimeAvailable =
  compileOption("threads") and static(getEnv("WASMTIME_C_API")).len > 0

when ModuleCacheRuntimeAvailable:
  import runtime
else:
  type RuntimeModule* = ref object

  proc close*(module: RuntimeModule) =
    discard module

type
  CachedContentState* = enum
    ccsInFlight
    ccsContentInvalid
    ccsCompiled

  HashClaimKind* = enum
    hckLeader
    hckWaiter
    hckTerminal

  ContentOutcome* = object
    accepted*: bool
    reason*: string
    detail*: string
    manifest*: PlayManifest
    module*: RuntimeModule
    compiledBytes*: int

  HashClaim* = object
    kind*: HashClaimKind
    outcome*: ContentOutcome

  CacheSnapshot* = object
    entries*: int
    inFlight*: int
    contentInvalid*: int
    compiled*: int
    residentBytes*: int

  CacheEntry = object
    state: CachedContentState
    outcome: ContentOutcome

  ModuleCache* = ref object
    entries: Table[string, CacheEntry]
    residentBytes: int

proc closeOutcome(outcome: var ContentOutcome) =
  if outcome.module != nil:
    outcome.module.close()
    outcome.module = nil

proc newModuleCache*(): ModuleCache =
  new(result)
  result.entries = initTable[string, CacheEntry]()

proc close*(cache: ModuleCache) =
  if cache == nil:
    return
  for hash in cache.entries.keys:
    var entry = cache.entries[hash]
    entry.outcome.closeOutcome()
    cache.entries[hash] = entry
  cache.entries.clear()
  cache.residentBytes = 0

proc claimHash*(cache: ModuleCache; hash: string): HashClaim =
  ## Returns leader for the first content worker of a hash, waiter while the
  ## leader is running, or the cached terminal content outcome after it settles.
  if hash in cache.entries:
    let entry = cache.entries[hash]
    if entry.state == ccsInFlight:
      return HashClaim(kind: hckWaiter)
    return HashClaim(kind: hckTerminal, outcome: entry.outcome)
  cache.entries[hash] = CacheEntry(state: ccsInFlight)
  HashClaim(kind: hckLeader)

proc finishLeader*(cache: ModuleCache; hash: string; outcome: ContentOutcome) =
  ## Freezes the first content terminal outcome for a hash. Later uploads can
  ## only join this outcome; they cannot cause another compile/probe pass.
  doAssert hash in cache.entries
  doAssert cache.entries[hash].state == ccsInFlight
  var entry: CacheEntry
  entry.outcome = outcome
  if outcome.accepted:
    entry.state = ccsCompiled
  else:
    entry.state = ccsContentInvalid
  cache.entries[hash] = entry

proc addResidentBytes*(cache: ModuleCache; bytes: int) =
  doAssert bytes >= 0
  if cache != nil:
    cache.residentBytes += bytes

proc snapshot*(cache: ModuleCache): CacheSnapshot =
  if cache == nil:
    return
  result.entries = cache.entries.len
  result.residentBytes = cache.residentBytes
  for entry in cache.entries.values:
    case entry.state
    of ccsInFlight: inc result.inFlight
    of ccsContentInvalid: inc result.contentInvalid
    of ccsCompiled: inc result.compiled

proc residentBytes*(cache: ModuleCache): int =
  if cache == nil: 0 else: cache.residentBytes

proc cachedOutcome*(cache: ModuleCache; hash: string): Option[ContentOutcome] =
  ## Read-only lookup for a compiled content outcome. Seat-local name binding
  ## remains owned by the compile plane; this accessor exposes only the
  ## already-accepted content terminal for runtime binding.
  if cache == nil or hash notin cache.entries:
    return none(ContentOutcome)
  let entry = cache.entries[hash]
  if entry.state == ccsCompiled and entry.outcome.accepted:
    some(entry.outcome)
  else:
    none(ContentOutcome)

proc writeStatusEntry*(w: var CanonicalWriter; entry: StatusEntry) =
  ## Encodes one durable status entry using Appendix P.1 key order. All u64
  ## identities are decimal strings via `addUint64`.
  w.beginObject()
  case entry.kind
  of skCallAccepted:
    w.key("epoch"); w.addUint64(entry.epoch)
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "call_accepted")
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.key("proposal_id"); w.addUint64(entry.acceptedProposalId)
    w.field("tick", entry.tick.int64)
  of skCallRejected:
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "call_rejected")
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.key("proposal_id"); w.addUint64(entry.rejectedProposalId)
    w.field("reason", entry.callReason)
  of skModuleAccepted:
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "module_accepted")
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.key("upload_id"); w.addUint64(entry.acceptedUploadId)
  of skModuleReady:
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "module_ready")
    w.field("name", entry.name)
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.field("sha256", entry.sha256)
    w.key("upload_id"); w.addUint64(entry.readyUploadId)
  of skModuleRejected:
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "module_rejected")
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.field("reason", entry.moduleReason)
    w.key("upload_id"); w.addUint64(entry.rejectedUploadId)
  of skPlayFaulted:
    w.field("code", $entry.faultCode)
    w.field("entry_id", entry.entryId)
    w.key("epoch"); w.addUint64(entry.faultEpoch)
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "play_faulted")
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.field("reason", entry.faultReason)
  of skRetuneRefused:
    w.field("code", $entry.faultCode)
    w.field("entry_id", entry.entryId)
    w.key("epoch"); w.addUint64(entry.faultEpoch)
    w.key("gen"); w.addUint64(entry.originGeneration)
    w.field("kind", "retune_refused")
    w.key("ordinal"); w.addUint64(entry.ordinal)
    w.field("reason", entry.faultReason)
  w.endObject()

proc encodeStatusEntry*(entry: StatusEntry): string =
  var writer = initCanonicalWriter(StatusEntryMaxBytes)
  writer.writeStatusEntry(entry)
  writer.take()

proc fitModuleRejectedReason*(entry: var StatusEntry) =
  ## Reasons are protocol strings, but the complete encoded status entry is
  ## capped. Trim only the reason and leave the identifiers intact.
  doAssert entry.kind == skModuleRejected
  while entry.moduleReason.len > 0 and
      encodeStatusEntry(entry).len > StatusEntryMaxBytes:
    entry.moduleReason.setLen(entry.moduleReason.len - 1)
