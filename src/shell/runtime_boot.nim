## Live boot checks for shell runtime availability. These stay out of
## GameConfig validation so parsing/tools/replay playback can handle legacy or
## stub-runtime configs without starting a live match.

import
  ../ctf/sim_types,
  episode

when not ShellRuntimeAvailable:
  import seats

proc checkPlayRuntimeAvailable*(config: GameConfig) =
  ## Refuses live play-seat boots when this binary was compiled without the
  ## Wasmtime runtime. Replay playback stays exempt by caller placement.
  when ShellRuntimeAvailable:
    discard
  else:
    if config.isPlaySeatEpisode():
      raise newException(
        CtfError,
        "Config selects play-control seats, but this binary was built " &
          "without the play runtime. Rebuild with WASMTIME_C_API set."
      )
