## Ordered content-validation stages for uploaded Season 2 play modules.

import crunchy/[common, sha256]

import manifest, module_interface, runtime, types

type
  ModuleValidationResult* = object
    accepted*: bool
    reason*: string
    detail*: string
    sha256*: string
    moduleInterface*: ModuleInterface
    manifest*: PlayManifest
    module*: RuntimeModule

proc reject(result: var ModuleValidationResult; reason, detail: string) =
  result.reason = reason
  result.detail = detail

proc close*(result: var ModuleValidationResult) =
  if result.module != nil:
    result.module.close()
    result.module = nil

proc validateUploadedModule*(runtime: RuntimeEngine;
    bytes: openArray[byte]): ModuleValidationResult =
  ## Runs stages 1(size only), 2, and 3-6 in their normative order. Admission
  ## accounting and seat-local naming remain outside this content-only unit.
  if bytes.len > MaxModuleBytes:
    result.reject("tooLarge", "module exceeds MaxModuleBytes")
    return

  result.sha256 = sha256(bytes).toHex()
  try:
    runtime.validateModuleBytes(bytes)
  except ShellRuntimeError as error:
    result.reject("binaryInvalid", error.msg)
    return

  try:
    result.moduleInterface = inspectModuleInterface(bytes)
  except ModuleInterfaceError as error:
    result.reject(error.reason, error.msg)
    return

  try:
    result.module = runtime.compileValidatedModule(bytes)
  except ShellRuntimeError as error:
    result.reject("compileFailed", error.msg)
    return

  var manifestBytes: string
  try:
    manifestBytes = result.module.probeManifestBytes(ManifestFuel.uint64)
  except ShellRuntimeError as error:
    result.close()
    result.reject("manifestProbe", error.msg)
    return

  try:
    result.manifest = parseManifest(move(manifestBytes),
      result.moduleInterface.hasRetune)
  except ManifestError as error:
    result.close()
    result.reject("manifestInvalid", error.msg)
    return
  except ValueError as error: # CanonicalReader's CanonicalError
    result.close()
    result.reject("manifestInvalid", error.msg)
    return
  result.accepted = true
