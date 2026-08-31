## Leading-byte dispatch for a bound play-seat WebSocket message.
##
## Shell packets are classified before Sprite parsing. The server owns the
## consumer registrations; this module only validates framing and returns a
## typed result without touching sim or seat state.

import bitworld/spriteprotocol

import ./[packets, types]

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
    except PacketError:
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
