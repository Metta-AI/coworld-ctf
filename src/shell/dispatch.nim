## Leading-byte dispatch for a bound play-seat WebSocket message.
##
## Shell packets are classified before Sprite parsing. The server owns the
## consumer registrations; this module only validates framing and returns a
## typed result without touching sim or seat state.

import bitworld/spriteprotocol

import ./[packets, types]
import ./vote_packets as votePackets

type
  PlayReceiveReject* = enum
    prrEmpty
    prrMalformedShellPacket
    prrUnknownOpcode

  PlayReceiveKind* = enum
    prRejected
    prSprite
    prIgnoredSpriteInput
    prIgnoredSpriteReady
    prIgnoredSpriteDebug
    prModuleUpload
    prPlayCall
    prStatusAck
    prLobbyChat
    prBallotCast

  PlayReceive* = object
    case kind*: PlayReceiveKind
    of prRejected:
      rejection*: PlayReceiveReject
    of prSprite, prIgnoredSpriteDebug:
      spriteBytes*: string
    of prModuleUpload:
      moduleUpload*: ModuleUploadPacket
    of prPlayCall:
      playCall*: PlayCallPacket
    of prStatusAck:
      statusAck*: StatusAckPacket
    of prLobbyChat:
      lobbyChat*: LobbyChatSendPacket
    of prBallotCast:
      ballotCast*: BallotCastPacket
    of prIgnoredSpriteInput, prIgnoredSpriteReady:
      discard

proc classifyPlaySeatMessage*(message: string): PlayReceive =
  if message.len == 0:
    return PlayReceive(kind: prRejected, rejection: prrEmpty)
  let opcode = message[0].uint8
  if opcode in [OpModuleUpload, OpPlayCall, OpStatusAck, OpLobbyChatSend]:
    try:
      let packet = message.decodeClientPacket()
      case packet.kind
      of cpkModuleUpload:
        return PlayReceive(kind: prModuleUpload,
          moduleUpload: packet.moduleUpload)
      of cpkPlayCall:
        return PlayReceive(kind: prPlayCall, playCall: packet.playCall)
      of cpkStatusAck:
        return PlayReceive(kind: prStatusAck, statusAck: packet.statusAck)
      of cpkLobbyChatSend:
        return PlayReceive(kind: prLobbyChat,
          lobbyChat: packet.lobbyChatSend)
    except packets.PacketError:
      return PlayReceive(kind: prRejected,
        rejection: prrMalformedShellPacket)
  if opcode == OpBallotCastReserved:
    ## MAP VOTE: `0xA4` decodes via the STANDALONE codec module
    ## (vote_packets.nim) rather than packets.nim's `decodeClientPacket`
    ## switch — that switch's opcode set is the packets lane's own
    ## sequenced work (see vote_packets.nim's header); this arm lifts
    ## mechanically onto it once 0xA4 joins `ClientPacketKind`.
    try:
      return PlayReceive(kind: prBallotCast,
        ballotCast: message.decodeBallotCast())
    except votePackets.PacketError:
      return PlayReceive(kind: prRejected,
        rejection: prrMalformedShellPacket)
  case opcode
  of SpriteClientInput:
    PlayReceive(kind: prIgnoredSpriteInput)
  of SpriteClientReady:
    PlayReceive(kind: prIgnoredSpriteReady)
  of SpriteClientChat, SpriteClientMouseMove, SpriteClientMouseButton:
    PlayReceive(kind: prSprite, spriteBytes: message)
  of SpriteClientDebugSprite:
    PlayReceive(kind: prIgnoredSpriteDebug, spriteBytes: message)
  else:
    PlayReceive(kind: prRejected, rejection: prrUnknownOpcode)
