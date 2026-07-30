# Terminal (MW2 2009) — authored off docs/designs/mw2-reference/prepped/terminal-grid.png.
#
# Measured, not recalled. The plate's playable envelope was extracted per column
# (top edge y~32-90, bottom edge y~590-646) and its wall strokes enumerated as
# components; the callouts below sit where those components sit. Two engine
# facts shaped the final placement:
#   * the spawn LANE repair clears x 82..290 and x 945..1153 across y 165..493,
#     so the west ticket hall and the east gate rooms are authored ABOVE and
#     BELOW that band, framing each pedestal apron rather than sitting on it;
#   * the flag ring (617,329) r70 is force-carved, so the middle of the
#     concourse is open floor by fiat — which is what a concourse should be.
#
# Shape of the map: one long open CONCOURSE running the whole length of the
# field through y~200-490, a row of enterable rooms along its north side
# (ticket hall, security checkpoint, escalators, bookstore, cafeteria, gate 24),
# a second row along its south side (baggage claim, Burger Town, cargo dock,
# gate 21), and the 747 parked on the apron at the EAST end.
from mw2_author import room, hbar, vbar

SHAPES = (
    # ---------------------------------------------------------- out of bounds
    # Plate envelope: nothing is walkable above y~32 or below y~646. These are
    # the airside apron and the neighbouring rooftops.
    [
        ("north apron", 96, 8, 1043, 32),
        ("south apron", 96, 620, 1043, 32),
    ]

    # ============================================ NORTH SIDE OF THE CONCOURSE
    # Six enterable rooms in a row, every door opening SOUTH into the hall.
    # --- ticket hall (west end, behind the red pedestal) -------------------
    + room("ticket hall", 96, 40, 200, 124,
           doors=[("S", 48, 48), ("S", 136, 40), ("E", 40, 56)])
    + [
        ("departures board", 168, 56, 56, 12),
        ("check-in desk A", 120, 76, 152, 16),
        ("check-in desk B", 120, 108, 152, 16),
        ("baggage scale west", 120, 132, 24, 12),
        ("baggage scale east", 248, 132, 24, 12),
    ]
    # --- security checkpoint ----------------------------------------------
    + room("security checkpoint", 336, 40, 168, 152,
           doors=[("W", 48, 56), ("S", 64, 48), ("E", 56, 48)])
    + [
        ("scanner arch west", 360, 72, 16, 48),
        ("scanner arch mid", 408, 72, 16, 48),
        ("scanner arch east", 456, 72, 16, 48),
        ("bag conveyor", 360, 136, 112, 16),
        ("queue stanchion", 400, 160, 40, 12),
    ]
    # --- escalators up from arrivals --------------------------------------
    + room("escalator well", 544, 40, 128, 112,
           doors=[("S", 40, 48), ("E", 40, 48)])
    + [
        ("escalator flight up", 568, 60, 16, 32),
        ("escalator flight down", 600, 60, 16, 32),
        ("escalator landing", 632, 60, 16, 32),
    ]
    # --- bookstore ---------------------------------------------------------
    + room("bookstore", 704, 40, 120, 96, doors=[("S", 40, 40)])
    + [
        ("bookstore shelf north", 720, 60, 88, 12),
        ("bookstore shelf mid", 720, 80, 88, 12),
        ("bookstore shelf south", 720, 100, 88, 12),
    ]
    # --- cafeteria ---------------------------------------------------------
    + room("cafeteria", 856, 40, 144, 136,
           doors=[("S", 48, 48), ("W", 48, 48)])
    + [
        ("cafeteria table row north", 880, 64, 96, 14),
        ("cafeteria table row mid", 880, 92, 96, 14),
        ("cafeteria serving counter", 880, 116, 96, 14),
    ]
    # --- gate 24 lounge (east end, behind the blue pedestal) --------------
    + room("gate 24 lounge", 1032, 40, 104, 124,
           doors=[("S", 32, 44), ("W", 40, 48)])
    + [
        ("gate 24 bench north", 1048, 68, 56, 14),
        ("gate 24 bench south", 1048, 96, 56, 14),
        ("gate 24 desk", 1048, 124, 56, 16),
    ]

    # ================================================== THE CONCOURSE ITSELF
    # A colonnade of piers down both flanks, shops as islands, and the
    # mezzanine gallery over the east half. The middle stays open.
    + [
        ("concourse pier NW", 408, 192, 16, 96),
        ("concourse pier NW2", 488, 192, 16, 96),
        ("concourse pier NE2", 728, 192, 16, 96),
        ("concourse pier NE", 800, 192, 16, 96),
        ("concourse pier SW", 408, 376, 16, 100),
        ("concourse pier SW2", 488, 376, 16, 100),
        ("concourse pier SE2", 728, 376, 16, 100),
        ("concourse pier SE", 800, 376, 16, 100),
        ("escalator head house", 552, 192, 80, 56),
    ]
    + room("bureau de change", 296, 200, 96, 104,
           doors=[("E", 40, 48), ("S", 32, 48)])
    + room("smoking lounge", 840, 200, 96, 104,
           doors=[("W", 40, 48), ("S", 32, 48)])
    + hbar("mezzanine gallery wall", 664, 840, 216, t=16,
           gaps=[(704, 744), (784, 824)])
    + [
        ("info desk", 496, 304, 48, 40),
        ("planter west", 496, 352, 40, 40),
        ("gate 19 seating", 320, 320, 56, 24),
        ("gate 20 seating", 320, 360, 56, 24),
        ("gate 22 seating", 856, 320, 56, 24),
        ("gate 23 seating", 856, 360, 56, 24),
        ("duty free island", 696, 296, 88, 56),
        ("newsstand", 696, 368, 56, 32),
        ("luggage trolley rank", 640, 400, 96, 48),
    ]
    # The hall's south face: the wall the south-side rooms hang off.
    + hbar("concourse south wall", 296, 944, 476, t=16,
           gaps=[(352, 392), (528, 568), (704, 744), (872, 912)])

    # ============================================ SOUTH SIDE OF THE CONCOURSE
    + room("baggage claim", 96, 492, 200, 128,
           doors=[("N", 48, 48), ("N", 136, 40), ("E", 40, 56)])
    + [
        ("carousel belt north", 120, 520, 152, 16),
        ("carousel belt south", 120, 560, 152, 16),
        ("luggage stack", 128, 584, 48, 16),
        ("oversize counter", 216, 584, 56, 16),
    ]
    + room("Burger Town", 336, 492, 160, 128,
           doors=[("N", 56, 48), ("E", 48, 48)])
    + [
        ("Burger Town counter", 352, 520, 112, 16),
        ("Burger Town booth row", 352, 552, 112, 14),
        ("Burger Town fryer", 440, 576, 40, 24),
    ]
    + room("cargo dock", 528, 500, 136, 120, doors=[("N", 48, 44)])
    + [
        ("pallet stack A", 552, 528, 40, 32),
        ("pallet stack B", 608, 528, 40, 32),
        ("forklift", 568, 576, 56, 24),
    ]
    + room("gate 21 boarding", 696, 492, 144, 128,
           doors=[("N", 48, 48), ("E", 40, 48)])
    + [
        ("gate 21 bench north", 712, 520, 96, 14),
        ("gate 21 bench south", 712, 552, 96, 14),
        ("gate 21 desk", 712, 584, 56, 16),
    ]

    # ========================================= THE 747, PARKED AT THE EAST END
    # Tail toward the terminal, nose out to the taxiway; the cabin is walkable
    # (two doors), which is how the real map plays.
    + [("747 tailfin", 872, 496, 32, 96)]
    + room("747 fuselage", 904, 520, 216, 72,
           doors=[("N", 64, 40), ("S", 140, 40)])
    + [
        ("747 cabin seats port", 920, 532, 168, 12),
        ("747 cabin seats starboard", 920, 560, 168, 12),
        ("747 nose cone", 1120, 536, 16, 40),
        ("747 port wing", 968, 496, 96, 24),
        ("747 starboard wing", 968, 592, 96, 24),
        ("jetway to gate 26", 928, 592, 16, 28),
    ]
)
