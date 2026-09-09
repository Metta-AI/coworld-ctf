## Standalone reachability probe for the pure `killDeed` classifier
## (src/ctf/glory.nim). No sim stepping needed -- killDeed is a pure
## func of KillContext, so this directly answers "CAN the scoring
## classifier select this deed for some legal context", independent of
## whether the live BR field ever produces that context.
##
## gunRange is set to 331 -- the REAL live br-golden-map.json value this
## census population actually ran under (glory-gradient knowledge base,
## ctf-cap-leg-recipe-longshot-first-x12.md / 01a-raw-code-facts) -- so
## pointBlankPxFor/longshotPxFor scale exactly as they did in the field
## (~35px / ~221px), not the unscaled CTF reference (110px / 700px) a
## bare `KillContext{}` would silently fall back to.
import ctf/glory

const BrGunRange = 331
echo "pointBlankPxFor(331) = ", pointBlankPxFor(BrGunRange)
echo "longshotPxFor(331) = ", longshotPxFor(BrGunRange)

# dSprayKill / dGrenadeKill: never swept by the existing exhaustive
# `killDeed` test (tests/test_glory.nim "a kill resolves to exactly one
# deed for every context") because that sweep never varies
# weaponSpray/weaponGrenade. Check directly, at a distance that is
# ABOVE point-blank and BELOW longshot under the REAL BR scaling.
let sprayCtx = KillContext(weaponSpray: true, rangePx: 100, gunRange: BrGunRange)
doAssert killDeed(sprayCtx) == dSprayKill,
  "dSprayKill unreachable at rangePx=100/gunRange=331: got " & $killDeed(sprayCtx)

let grenadeCtx = KillContext(weaponGrenade: true, rangePx: 100, gunRange: BrGunRange)
doAssert killDeed(grenadeCtx) == dGrenadeKill,
  "dGrenadeKill unreachable at rangePx=100/gunRange=331: got " & $killDeed(grenadeCtx)

# dEscortKill: the CLASSIFIER's own precedence slot is reachable (this
# proves killDeed itself is not the blocker) -- the real question is
# whether `ctx.escorted` can ever become true on a flagless BR map,
# answered separately against sim.nim's escortCarrier feeder.
let escortCtx = KillContext(escorted: true, rangePx: 100, gunRange: BrGunRange)
doAssert killDeed(escortCtx) == dEscortKill,
  "dEscortKill unreachable at rangePx=100/gunRange=331: got " & $killDeed(escortCtx)

# Precedence sanity: spray/grenade/escort are the LOWEST tiers -- confirm
# a higher-precedence fact still shadows them (matches the documented
# hierarchy, glory.nim killDeed comment).
let shadowed = KillContext(weaponSpray: true, victimLevel: AceLevel,
                            rangePx: 100, gunRange: BrGunRange)
doAssert killDeed(shadowed) == dAceTag,
  "ace-level should shadow weaponSpray: got " & $killDeed(shadowed)

# And the SAME rangePx=100, at the UNSCALED reference gunRange (0 =
# unresolved sentinel), lands inside the CTF-reference point-blank
# radius (110px) -- this is NOT a contradiction, it is the exact
# gunRange-sensitivity the census's own raw-code-facts note flagged
# (01a-raw-code-facts-glory-catalog.md): the same shot geometry
# classifies differently depending on which map's gunRange is live.
let sprayCtxUnscaled = KillContext(weaponSpray: true, rangePx: 100)
doAssert killDeed(sprayCtxUnscaled) == dPointBlankKill,
  "expected the unscaled reference to swallow this shot as point-blank"

echo "ALL killDeed REACHABILITY CHECKS PASSED"
