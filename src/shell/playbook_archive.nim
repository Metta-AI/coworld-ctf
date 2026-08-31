## Local playbook archive stored beside a replay.
##
## P5a deliberately assumes a directory named `<replay>.playbook/`, with one
## `<sha256>.wasm` file per module. Hosted artifact plumbing may later retarget
## this container; callers use these procs so that decision does not change the
## replay record format or its hash verification.

import std/[json, os, sets]
import replay_records

type
  PlaybookArchiveError* = object of CatchableError

proc archiveError(message: string) {.noReturn.} =
  raise newException(PlaybookArchiveError, message)

proc playbookArchiveDir*(replayPath: string): string =
  replayPath & ".playbook"

proc validHash(value: string): bool =
  if value.len != 64:
    return false
  for ch in value:
    if ch notin {'0' .. '9', 'a' .. 'f'}:
      return false
  true

proc modulePath(replayPath, moduleSha256: string): string =
  if not moduleSha256.validHash():
    archiveError("playbook module hash must be 64 lowercase hex characters")
  replayPath.playbookArchiveDir() / (moduleSha256 & ".wasm")

proc manifestPath(replayPath: string): string =
  replayPath.playbookArchiveDir() / "manifest.json"

proc writePlaybookModule*(replayPath, moduleBytes: string): string =
  ## Writes one content-addressed module and returns its SHA-256 identity.
  ## A byte-identical duplicate is a no-op; a pre-existing corrupt object is
  ## refused rather than overwritten.
  result = sha256Hex(moduleBytes)
  let
    directory = replayPath.playbookArchiveDir()
    path = modulePath(replayPath, result)
  createDir(directory)
  if fileExists(path):
    if readFile(path) != moduleBytes:
      archiveError("playbook archive object does not match its filename hash")
    return
  writeFile(path, moduleBytes)

proc readPlaybookModule*(replayPath, moduleSha256: string): string =
  let path = modulePath(replayPath, moduleSha256)
  if not fileExists(path):
    archiveError("playbook archive module is missing: " & moduleSha256)
  result = readFile(path)
  if sha256Hex(result) != moduleSha256:
    archiveError("playbook archive module hash mismatch: " & moduleSha256)

proc uniqueHashes(recordedHashes: openArray[string]): seq[string] =
  var seen = initHashSet[string]()
  for moduleSha256 in recordedHashes:
    if not moduleSha256.validHash():
      archiveError("playbook module hash must be 64 lowercase hex characters")
    if moduleSha256 notin seen:
      seen.incl(moduleSha256)
      result.add(moduleSha256)

proc writePlaybookManifest*(replayPath: string,
                            recordedHashes: openArray[string]) =
  ## The archive manifest contains only module identities from call records;
  ## native reflex identities have no bytes and therefore never appear here.
  let hashes = uniqueHashes(recordedHashes)
  createDir(replayPath.playbookArchiveDir())
  var modules = newJArray()
  for moduleSha256 in hashes:
    modules.add(%moduleSha256)
  writeFile(replayPath.manifestPath(), $(%*{"modules": modules}))

proc readPlaybookManifest*(replayPath: string): seq[string] =
  let path = replayPath.manifestPath()
  if not fileExists(path):
    archiveError("playbook archive manifest is missing")
  try:
    let manifest = parseJson(readFile(path))
    if manifest.kind != JObject or manifest.len != 1 or
        not manifest.hasKey("modules") or manifest["modules"].kind != JArray:
      archiveError("playbook archive manifest has the wrong shape")
    var seen = initHashSet[string]()
    for item in manifest["modules"]:
      if item.kind != JString or not item.getStr().validHash():
        archiveError("playbook archive manifest contains an invalid hash")
      let moduleSha256 = item.getStr()
      if moduleSha256 in seen:
        archiveError("playbook archive manifest contains a duplicate hash")
      seen.incl(moduleSha256)
      result.add(moduleSha256)
  except JsonParsingError:
    archiveError("playbook archive manifest is not valid JSON")

proc verifyPlaybookArchive*(replayPath: string,
                            recordedHashes: openArray[string]) =
  ## Verifies the manifest is exactly the replay's distinct module identities,
  ## then verifies each content-addressed object. Extra unlisted files are
  ## harmless: the replay and manifest remain authoritative.
  let expected = uniqueHashes(recordedHashes)
  if replayPath.readPlaybookManifest() != expected:
    archiveError("playbook archive manifest does not match replay hashes")
  for moduleSha256 in expected:
    discard readPlaybookModule(replayPath, moduleSha256)
