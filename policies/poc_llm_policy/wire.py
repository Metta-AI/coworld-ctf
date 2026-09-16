"""Season 2 play-seat wire codec, written from the byte layouts alone.

Everything here is a transcription of two files that are the protocol's ground
truth:

* ``src/shell/types.nim`` -- the opcode table and the wire limits.
* ``src/shell/packets.nim`` -- the exact field order, the length equations, and
  the rejection rules (short header, length mismatch, trailing bytes,
  non-zero reserved bytes, limit exceeded).

and one more for the payload encoding:

* ``src/shell/canonical.nim`` -- the single canonical JSON byte encoding that
  every PlayCall payload must be in.

No Nim is imported or linked; this is what an outside policy author has to
write. Integers are little-endian, every packet starts ``u8 op, u8 ver`` with
ver = 1, and every reserved byte is zero.
"""

from __future__ import annotations

import math
import struct

# ── Opcodes (src/shell/types.nim, the §4.3 packet table) ──────────────────
OP_MODULE_UPLOAD = 0xA0
OP_PLAY_CALL = 0xA1
OP_STATUS_ACK = 0xA2
OP_LOBBY_CHAT_SEND = 0xA3
OP_PLAY_CONTEXT = 0xB0
OP_PLAY_VIEW = 0xB1
OP_LOBBY_CHAT_BROADCAST = 0xB2

SHELL_PROTOCOL_VERSION = 1

# ── Wire limits (same file) ───────────────────────────────────────────────
MAX_MODULE_BYTES = 262144
MAX_CALL_BYTES = 4096
MAX_LADDER_ENTRIES = 16
MAX_ACTIVE_OVERLAYS = 2
LOBBY_CHAT_MAX_BYTES = 512
STATUS_ACK_PACKET_BYTES = 16


class WireError(Exception):
    """A packet that the production codec would have rejected."""


# ── Canonical JSON (src/shell/canonical.nim) ──────────────────────────────
# Object keys sorted byte-ascending, no insignificant whitespace, integers as
# plain JSON numbers, floats in the one canonical grammar below, and every
# 64-bit identity as a decimal string rather than a number.


def canonical_float(value: float) -> str:
    """The canonical spelling of a JSON float.

    A direct port of ``canonicalFloat`` in src/shell/canonical.nim. Python's
    ``repr`` gives the same shortest round-trip digits as Nim's ``$``, so only
    the notation rules have to be reproduced: plain notation for
    ``1e-6 <= |x| < 1e21`` with an integral value keeping its ``.0``, and
    ``d[.ddd]e<sign><exponent>`` with an unpadded exponent outside that range.
    """
    if math.isnan(value) or math.isinf(value):
        raise WireError("non-finite floats are not encodable")
    if value == 0.0:
        return "0.0"
    negative = value < 0
    text = repr(abs(value))
    if "e" in text:
        mantissa, _, exponent = text.partition("e")
        exp10 = int(exponent)
    else:
        mantissa, exp10 = text, 0
    dot = mantissa.find(".")
    int_len = len(mantissa) if dot < 0 else dot
    digits = mantissa.replace(".", "")
    point_at = int_len + exp10
    lead = 0
    while lead < len(digits) - 1 and digits[lead] == "0":
        lead += 1
    digits = digits[lead:]
    point_at -= lead
    while len(digits) > 1 and digits[-1] == "0":
        digits = digits[:-1]
    magnitude = abs(value)
    if 1e-6 <= magnitude < 1e21:
        if point_at <= 0:
            out = "0." + "0" * (-point_at) + digits
        elif point_at >= len(digits):
            out = digits + "0" * (point_at - len(digits)) + ".0"
        else:
            out = digits[:point_at] + "." + digits[point_at:]
    else:
        canonical_exp = point_at - 1
        out = digits[0]
        if len(digits) > 1:
            out += "." + digits[1:]
        out += "e" + ("+" if canonical_exp >= 0 else "-") + str(abs(canonical_exp))
    return "-" + out if negative else out


_ESCAPES = {
    '"': '\\"',
    "\\": "\\\\",
    "\b": "\\b",
    "\f": "\\f",
    "\n": "\\n",
    "\r": "\\r",
    "\t": "\\t",
}


def canonical_string(value: str) -> str:
    out = ['"']
    for char in value:
        escape = _ESCAPES.get(char)
        if escape is not None:
            out.append(escape)
        elif ord(char) < 0x20:
            out.append("\\u%04x" % ord(char))
        else:
            out.append(char)
    out.append('"')
    return "".join(out)


def canonical_json(node) -> str:
    """Serialize a Python value under the canonical rules.

    The producer owns set-kind sorting and neutral-field omission; this
    function owns key order, spacing, and scalar formatting.
    """
    if node is None:
        return "null"
    if isinstance(node, bool):
        return "true" if node else "false"
    if isinstance(node, int):
        return str(node)
    if isinstance(node, float):
        return canonical_float(node)
    if isinstance(node, str):
        return canonical_string(node)
    if isinstance(node, (list, tuple)):
        return "[" + ",".join(canonical_json(item) for item in node) + "]"
    if isinstance(node, dict):
        parts = []
        for key in sorted(node.keys()):
            parts.append(canonical_string(key) + ":" + canonical_json(node[key]))
        return "{" + ",".join(parts) + "}"
    raise WireError(f"not encodable: {type(node).__name__}")


# ── Client → server encoders ──────────────────────────────────────────────


def encode_module_upload(upload_id: int, wasm: bytes) -> bytes:
    """0xA0: u8 op, u8 ver, u64 uploadId, u32 len, u8[len] wasm. Total 14+len."""
    if len(wasm) > MAX_MODULE_BYTES:
        raise WireError(f"module is {len(wasm)} bytes, cap is {MAX_MODULE_BYTES}")
    return (
        struct.pack("<BBQI", OP_MODULE_UPLOAD, SHELL_PROTOCOL_VERSION,
                    upload_id, len(wasm))
        + wasm
    )


def encode_play_call(proposal_id: int, call_bytes: bytes) -> bytes:
    """0xA1: u8 op, u8 ver, u64 proposalId, u32 len, canonical ladder JSON."""
    if len(call_bytes) > MAX_CALL_BYTES:
        raise WireError(f"call is {len(call_bytes)} bytes, cap is {MAX_CALL_BYTES}")
    return (
        struct.pack("<BBQI", OP_PLAY_CALL, SHELL_PROTOCOL_VERSION,
                    proposal_id, len(call_bytes))
        + call_bytes
    )


def encode_status_ack(mark: int) -> bytes:
    """0xA2: u8 op, u8 ver, u8[6] reserved zero, u64 mark. Fixed 16 bytes."""
    packet = struct.pack("<BB6xQ", OP_STATUS_ACK, SHELL_PROTOCOL_VERSION, mark)
    if len(packet) != STATUS_ACK_PACKET_BYTES:
        raise WireError("StatusAck must be exactly 16 bytes")
    return packet


def encode_lobby_chat(text: str) -> bytes:
    """0xA3: u8 op, u8 ver, u32 len, u8[len] UTF-8. Total 6+len.

    The cap is measured on the raw UTF-8 payload first, so the text is
    truncated on encoded byte boundaries, not on characters.
    """
    payload = text.encode("utf-8")
    if len(payload) > LOBBY_CHAT_MAX_BYTES:
        payload = payload[:LOBBY_CHAT_MAX_BYTES]
        while payload:
            try:
                payload.decode("utf-8")
                break
            except UnicodeDecodeError:
                payload = payload[:-1]
    return struct.pack("<BBI", OP_LOBBY_CHAT_SEND, SHELL_PROTOCOL_VERSION,
                       len(payload)) + payload


# ── Server → client decoders ──────────────────────────────────────────────


class _Cursor:
    def __init__(self, data: bytes) -> None:
        self.data = data
        self.at = 0

    def take(self, count: int) -> bytes:
        if count < 0 or count > len(self.data) - self.at:
            raise WireError(f"short packet at offset {self.at}")
        chunk = self.data[self.at:self.at + count]
        self.at += count
        return chunk

    def u8(self) -> int:
        return self.take(1)[0]

    def u32(self) -> int:
        return struct.unpack("<I", self.take(4))[0]

    def u64(self) -> int:
        return struct.unpack("<Q", self.take(8))[0]

    def payload(self) -> bytes:
        return self.take(self.u32())

    def require_end(self) -> None:
        if self.at < len(self.data):
            raise WireError(f"trailing bytes at offset {self.at}")


def decode_server_packet(data: bytes) -> dict | None:
    """Decode one 0xB0/0xB1/0xB2 packet, or return None for anything else.

    A play socket also receives the legacy Sprite broadcast stream, so a
    conforming client must ignore leading bytes it does not own rather than
    treat them as protocol errors.
    """
    if not data:
        return None
    opcode = data[0]
    if opcode not in (OP_PLAY_CONTEXT, OP_PLAY_VIEW, OP_LOBBY_CHAT_BROADCAST):
        return None
    if len(data) < 2 or data[1] != SHELL_PROTOCOL_VERSION:
        raise WireError("wrong protocol version")
    cursor = _Cursor(data)
    cursor.take(2)
    if opcode == OP_PLAY_CONTEXT:
        packet = {
            "kind": "play_context",
            "control": cursor.payload().decode("utf-8"),
            "context": cursor.payload().decode("utf-8"),
        }
    elif opcode == OP_PLAY_VIEW:
        tick = cursor.u32()
        packet = {
            "kind": "play_view",
            "tick": tick,
            "control": cursor.payload().decode("utf-8"),
            "view": cursor.payload().decode("utf-8"),
        }
    else:
        ordinal = cursor.u64()
        tick = cursor.u32()
        seat = cursor.u8()
        team = cursor.u8()
        packet = {
            "kind": "lobby_chat",
            "ordinal": ordinal,
            "tick": tick,
            "seat": seat,
            "team": team,
            "text": cursor.payload().decode("utf-8"),
        }
    cursor.require_end()
    return packet
