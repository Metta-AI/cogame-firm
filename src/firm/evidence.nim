## Private evidence artifacts: exclusive creation, no spectator publication.
import std/[json, os, posix]

proc writePrivate*(destination, content: string) =
  let parent = destination.parentDir()
  if parent.len > 0 and not dirExists(parent):
    createDir(parent)
    setFilePermissions(parent, {fpUserRead, fpUserWrite, fpUserExec})
  let descriptor = posix.open(destination.cstring, O_WRONLY or O_CREAT or O_EXCL, Mode(0o600))
  if descriptor < 0:
    raiseOSError(osLastError())
  var output: File
  if not open(output, FileHandle(descriptor), fmWrite):
    let code = osLastError()
    discard posix.close(descriptor)
    raiseOSError(code)
  defer: output.close()
  output.write(content)

proc appendPrivate*(destination: string, record: JsonNode) =
  ## The owning host creates this file privately before starting its workers.
  let output = open(destination, fmAppend)
  defer: output.close()
  output.writeLine($record)

import sim

proc installedAction*(world: Sim, seat, eventStart: int): JsonNode =
  for index in eventStart ..< world.events.len:
    let event = world.events[index]
    if event.seat != seat: continue
    case event.kind
    of evMemo:
      return %*{"orders": event.orders, "payroll": event.payroll,
        "split": event.split, "directive": event.say, "notes": event.text}
    of evWork:
      return %*{"line": event.line, "run": event.run, "maint": event.maint,
        "report": event.say, "notes": event.text}
    else: discard
  raise newException(ValueError, "missing installed action event")
