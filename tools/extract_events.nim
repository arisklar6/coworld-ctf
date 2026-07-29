## Re-simulates one .bitreplay with the tier-2 event sink enabled
## (sim.collectEvents) and prints the drained SimEvent stream as JSON lines —
## one object per event, in tick order — followed by a final summary object.
## Replay hashes are still validated every step (mismatchQuit), so a clean run
## also proves the recording re-simulates deterministically.
##
## Usage: nim r tools/extract_events.nim [replay-path] [--out <path>]

import
  std/[json, os, strutils],
  ../src/ctf/replays,
  ../src/ctf/sim

type
  ExtractEventsError = object of CatchableError

const
  UsageText =
    "Usage: nim r tools/extract_events.nim [replay-path] [--out <path>]"
  GameDir = currentSourcePath().parentDir().parentDir()
  DefaultReplayPath = GameDir / "tests" / "replays" / "ctf.bitreplay"

proc fail(message: string) =
  ## Raises one extraction failure.
  raise newException(ExtractEventsError, message)

proc parseArgs(): tuple[replayPath, outPath: string] {.used.} =
  ## Returns the replay path and --out path passed on the command line.
  result.outPath = ""
  var
    paths: seq[string]
    params = commandLineParams()
    i = 0
  while i < params.len:
    let arg = params[i]
    if arg == "--":
      discard
    elif arg in ["--help", "-h"]:
      echo UsageText
      quit(0)
    elif arg == "--out":
      if i + 1 >= params.len:
        fail("--out requires a path.\n" & UsageText)
      inc i
      result.outPath = params[i].absolutePath()
    elif arg.startsWith("--"):
      fail("Unknown option: " & arg & "\n" & UsageText)
    else:
      paths.add(arg)
    inc i
  if paths.len > 1:
    fail("Expected at most one replay path.\n" & UsageText)
  result.replayPath =
    if paths.len == 0: DefaultReplayPath else: paths[0].absolutePath()

proc replayConfig(data: ReplayData): GameConfig =
  ## Returns the game config embedded in a replay.
  result = defaultGameConfig()
  result.update(data.configJson)

proc key*(kind: SimEventKind): string =
  ## Returns the JSON event key for one tier-2 event kind.
  case kind
  of Shot: "shot"
  of Hit: "hit"
  of Damage: "damage"
  of Kill: "kill"
  of Death: "death"
  of FlagSteal: "flag_steal"
  of FlagReturn: "flag_return"
  of Capture: "capture"
  of Respawn: "respawn"
  of Heal: "heal"
  of PhaseChange: "phase"

proc jsonRow*(event: SimEvent): JsonNode =
  ## Returns one JSON-lines row for a tier-2 sim event.
  result = newJObject()
  result["tick"] = %event.tick
  result["kind"] = %event.kind.key()
  result["source"] = %event.source
  result["target"] = %event.target
  result["weapon"] = %event.weapon
  result["amount"] = %event.amount
  result["hp"] = %event.hp
  result["blocked"] = %event.blocked
  result["x"] = %event.x
  result["y"] = %event.y

type
  ExtractResult* = object
    ## One replay's full tier-2 extraction plus the final tier-1 snapshot,
    ## from a single hash-validated re-simulation walk.
    events*: seq[SimEvent]     ## every drained event, in emission order.
    ticks*: int                ## final simulated tick.
    resultsJson*: string       ## playerResultsJson at the final tick.
    slotShotsFired*: seq[int]  ## final in-sim accuracy counters by slot.
    slotShotsHit*: seq[int]
    slotAddress*: seq[string]  ## each slot's recorded join name. A hosted
                               ## league replay records the league player name
                               ## here, so attribution never has to ASSUME a
                               ## slot-to-entrant mapping.
    slotTeam*: seq[string]     ## each slot's team ("red" / "blue").
    winner*: string            ## "red" / "blue", or "" when drawn/unfinished.
    isDraw*: bool
    finished*: bool            ## whether the replay reached GameOver.

proc extractEvents*(data: ReplayData): ExtractResult =
  ## Re-simulates one replay with the tier-2 sink on and returns every event
  ## in emission order. Raises ReplayError on any recorded-hash mismatch.
  let previousDir = getCurrentDir()
  setCurrentDir(GameDir)
  try:
    var
      sim = initSimServer(data.replayConfig())
      replay = initReplayPlayer(data)
    sim.gameEventLoggingEnabled = false
    sim.collectEvents = true
    replay.looping = false
    replay.mismatchQuit = true
    while replay.playing:
      replay.stepReplay(sim)
      # Drain the sink every tick so it never grows past one tick's worth.
      for event in sim.events:
        result.events.add(event)
      sim.events.setLen(0)
      result.ticks = sim.tickCount
    result.resultsJson = sim.playerResultsJson()
    let resultSlotCount = parseJson(result.resultsJson)["names"].len
    result.slotShotsFired = newSeq[int](resultSlotCount)
    result.slotShotsHit = newSeq[int](resultSlotCount)
    result.slotAddress = newSeq[string](resultSlotCount)
    result.slotTeam = newSeq[string](resultSlotCount)
    for player in sim.players:
      if player.joinOrder >= 0 and player.joinOrder < resultSlotCount:
        result.slotShotsFired[player.joinOrder] = player.shotsFired
        result.slotShotsHit[player.joinOrder] = player.shotsHit
        result.slotAddress[player.joinOrder] = player.address
        result.slotTeam[player.joinOrder] = teamText(player.team)
    result.finished = sim.phase == GameOver
    result.isDraw = sim.isDraw
    if result.finished and not sim.isDraw:
      result.winner = teamText(sim.winner)
  finally:
    setCurrentDir(previousDir)

proc extractEventsJsonl*(data: ReplayData): string =
  ## Returns the full JSON-lines extraction: one row per event plus a final
  ## summary object.
  let extraction = extractEvents(data)
  var lines = newSeqOfCap[string](extraction.events.len + 1)
  for event in extraction.events:
    lines.add($event.jsonRow())
  var summary = newJObject()
  summary["type"] = %"summary"
  summary["ticks"] = %extraction.ticks
  summary["events"] = %extraction.events.len
  summary["gameVersion"] = %GameVersion
  summary["finished"] = %extraction.finished
  summary["draw"] = %extraction.isDraw
  summary["winner"] = %extraction.winner
  # The roster travels WITH the events so a scan of the JSONL alone can
  # attribute every slot without re-reading the league API.
  summary["slot_address"] = %extraction.slotAddress
  summary["slot_team"] = %extraction.slotTeam
  summary["slot_shots_fired"] = %extraction.slotShotsFired
  summary["slot_shots_hit"] = %extraction.slotShotsHit
  lines.add($summary)
  lines.join("\n") & "\n"

proc runExtract(replayPath, outPath: string) {.used.} =
  ## Extracts one replay's event stream to stdout or --out.
  if not fileExists(replayPath):
    fail("Replay file does not exist: " & replayPath)
  let output = extractEventsJsonl(loadReplay(replayPath))
  if outPath.len > 0:
    writeFile(outPath, output)
  else:
    stdout.write(output)

when isMainModule:
  try:
    let (replayPath, outPath) = parseArgs()
    runExtract(replayPath, outPath)
  except ExtractEventsError as e:
    stderr.writeLine("extract_events failed: " & e.msg)
    quit(1)
  except ReplayError as e:
    stderr.writeLine("extract_events replay error: " & e.msg)
    quit(1)
  except CtfError as e:
    stderr.writeLine("extract_events sim error: " & e.msg)
    quit(1)
