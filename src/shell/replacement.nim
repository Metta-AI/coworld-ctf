## Section 7.2 ladder replacement table.
##
## This module is deliberately pure: packet decoding, call validation, module
## lookup, guest invocation, and Store ownership stay in their owning layers.
## Callers pass the already-validated outgoing/incoming identity and apply the
## returned action to their concrete entry state.

import types

type
  ReplacementEntry* = object
    entryId*: string
    playName*: string
    moduleHash*: string
    paramsBytes*: string
    state*: PlayInstanceState
    retune*: bool

  ReplacementAction* = enum
    raStartAbsent
    raAdoptIdentical
    raPendingRetune

  ReplacementDecision* = object
    matched*: bool
    action*: ReplacementAction
    nextState*: PlayInstanceState
    keepGuest*: bool
    keepCache*: bool
    oldParamsBytes*: string

proc replacementKeyMatches*(outgoing, incoming: ReplacementEntry): bool =
  ## §7.2 matches by entryId, play name, and the seat-local module hash.
  outgoing.entryId == incoming.entryId and
    outgoing.playName == incoming.playName and
    outgoing.moduleHash == incoming.moduleHash

proc classifyReplacement*(outgoing: openArray[ReplacementEntry];
                          incoming: ReplacementEntry): ReplacementDecision =
  ## Implements the §7.2 replacement table for one incoming entry.
  ##
  ## Only live/parked outgoing entries can be adopted. Pending retunes are not
  ## adoptable, because their old params were already quarantined and their
  ## new params never reached guest state.
  result.action = raStartAbsent
  result.nextState = pisAbsent
  for old in outgoing:
    if not old.replacementKeyMatches(incoming):
      continue
    result.matched = true
    if old.state in {pisLive, pisParked} and incoming.retune:
      if old.paramsBytes == incoming.paramsBytes:
        result.action = raAdoptIdentical
        result.nextState = old.state
        result.keepGuest = true
        result.keepCache = true
      else:
        result.action = raPendingRetune
        result.nextState = pisPendingRetune
        result.keepGuest = true
        result.keepCache = false
        result.oldParamsBytes = old.paramsBytes
    return

