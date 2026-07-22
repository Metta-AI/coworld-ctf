#!/usr/bin/env python3
"""Faithful Python port of sim.nim stepCogDrive, for the offline preview only.

Mirrors the Nim controller (CogDriveState / stepCogDrive) so the preview animates
from the SAME logic that will ship. Angles here are in DEGREES (screen: 0=E, CCW+,
y-up) for the compositor; the Nim uses brads (256/turn). Conversions kept explicit.

Nim constants (sim.nim):
  CogBodyTurnRate=10 brads/frame, CogWheelTurnRate=40, CogReverseMaxBrads=96,
  CogReverseCommitFrames=12, CogMoveMinSpeed=StopThreshold=8, AimBradsTurn=256.
"""
import math

BRAD = 256.0
DEG_PER_BRAD = 360.0 / BRAD
BODY_TURN = 10          # brads/frame
WHEEL_TURN = 40
REVERSE_MAX = 96
COMMIT_FRAMES = 12
MIN_SPEED = 8


def brads_of_vector(dx, dy):
    if dx == 0 and dy == 0:
        return 0.0
    b = math.atan2(-dy, dx) * (BRAD / 2) / math.pi
    return (b % BRAD + BRAD) % BRAD


def brad_diff(a, b):
    d = ((a - b) % BRAD + BRAD) % BRAD
    if d > BRAD / 2:
        d -= BRAD
    return d


def ease_brads(cur, target, max_step):
    d = brad_diff(target, cur)
    step = max(-max_step, min(max_step, d))
    return (cur + step) % BRAD


def _deg2brad(deg):
    return (deg / DEG_PER_BRAD) % BRAD


def _brad2deg(b):
    return (b * DEG_PER_BRAD) % 360.0


def init_state(heading_deg):
    b = _deg2brad(heading_deg)
    return {"bodyHeadingB": b, "wheelToeB": b, "reverseFrames": 0,
            "bodyHeading": _brad2deg(b), "wheelToe": _brad2deg(b)}


def step(state, velX, velY, aim_deg):
    s = dict(state)
    speed = abs(velX) + abs(velY)
    if speed < MIN_SPEED:
        s["wheelToeB"] = ease_brads(s["wheelToeB"], s["bodyHeadingB"], WHEEL_TURN)
        s["reverseFrames"] = max(0, s["reverseFrames"] - 1)
    else:
        travel = brads_of_vector(velX, velY)
        off_body = abs(brad_diff(travel, s["bodyHeadingB"]))
        backward = off_body > REVERSE_MAX
        if backward:
            s["reverseFrames"] = min(s["reverseFrames"] + 1, COMMIT_FRAMES * 2)
        else:
            s["reverseFrames"] = max(0, s["reverseFrames"] - 2)
        committed = s["reverseFrames"] >= COMMIT_FRAMES
        heading_target = s["bodyHeadingB"] if (backward and not committed) else travel
        turn_rate = max(BODY_TURN // 2,
                        BODY_TURN * MIN_SPEED * 4 // max(speed, MIN_SPEED * 4))
        s["bodyHeadingB"] = ease_brads(s["bodyHeadingB"], heading_target, turn_rate)
        s["wheelToeB"] = ease_brads(s["wheelToeB"], travel, WHEEL_TURN)
    s["bodyHeading"] = _brad2deg(s["bodyHeadingB"])
    s["wheelToe"] = _brad2deg(s["wheelToeB"])
    return s


def short_diff(a_deg, b_deg):
    """Signed shortest angular difference in degrees (for turn-rate w)."""
    d = (a_deg - b_deg + 180) % 360 - 180
    return d
