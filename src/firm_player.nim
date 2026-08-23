## Firm player: a policy is just a prompt.
##
## Connects to the game, delivers its prompt (from PLAYER_PROMPT, or a
## default strategy covering both roles), then idles until the final frame.
## All of the actual decision making happens inside the game server, which
## sends this seat's prompt to Claude every shift.
##
## The role is dealt by the seed after seating, so a prompt must cover both:
## the seat may open the episode as the MANAGER or as one of the four
## machine operators.
##
## PLAYER_SCRIPTED=steady (or 1) registers the seat as the built-in
## competent baseline instead; PLAYER_SCRIPTED=taskmaster as the
## drive-it-into-the-ground baseline. The server plays those
## deterministically, no LLM.
##
## To field your own policy, reuse this image and set PLAYER_PROMPT:
##   coworld upload-policy <firm-image> --name my-firm \
##     --run /bin/firm-player --secret-env PLAYER_PROMPT="<your strategy>"

import
  std/[json, options, os, strutils],
  whisky

const DefaultPrompt = """
If you are the MANAGER: read the board one shift ahead and move machines onto
the line the firm can actually sell, switching early enough to pay for the
2-hour changeover. Set the pool high enough that an hour of work is worth more
to a worker than it costs - below about 35% of revenue on an even split,
working and shirking pay a worker the same. Use the split to reward output, but
remember that a machine can be worn rather than idle: if a machine's output
falls while its operator says it needs maintenance, cutting its share is how
you get a dead machine. Say in the memo WHY the orders are what they are; the
workers cannot see the board.
If you are a WORKER: watch your condition. Six hours running and three
maintaining holds a machine steady forever; ten hours running kills it in three
shifts and the manager will read the collapse as laziness. Work the hours that
pay: your share of the pool times the pool's share of revenue, against $1.50 an
hour of effort. Follow a line order unless you have a reason not to - you
cannot see demand and the manager can. Tell the manager what your machine
actually needs, and keep your own running tally in your notes.
"""

when isMainModule:
  let url = getEnv("COWORLD_PLAYER_WS_URL")
  if url.len == 0:
    quit("COWORLD_PLAYER_WS_URL is not set", 1)
  var prompt = getEnv("PLAYER_PROMPT")
  if prompt.len == 0:
    prompt = DefaultPrompt
  let scripted = getEnv("PLAYER_SCRIPTED").strip()

  proc promptFrame(): string =
    $ %*{"type": "prompt", "prompt": prompt, "scripted": scripted}

  echo "firm player: connecting to game"
  let socket = newWebSocket(url)
  socket.send(promptFrame())
  echo "firm player: prompt delivered (", prompt.len, " chars",
    (if scripted.len > 0: ", scripted " & scripted else: ""), ")"

  ## whisky's receiveMessage RAISES on a close frame or a truncated read
  ## (only a timeout returns none), and mummy's send merely queues — the
  ## game's quit(0) can outrun the flushed final frame. A dead socket is a
  ## normal end of episode, not a player failure, so exit 0 on it.
  try:
    while true:
      let received = socket.receiveMessage()
      if received.isNone:
        echo "firm player: connection closed, exiting"
        break
      let message = received.get()
      if message.kind != TextMessage:
        continue
      try:
        let payload = parseJson(message.data)
        case payload{"type"}.getStr()
        of "welcome":
          echo "firm player: seated at slot ",
            payload{"slot"}.getInt(), " as ", payload{"name"}.getStr(),
            " (", payload{"role"}.getStr(), ")"
          ## Re-deliver the prompt after the welcome, in case the first send
          ## raced the server's slot registration.
          socket.send(promptFrame())
        of "final":
          echo "firm player: final scores ", payload{"scores"}
          break
        else:
          discard
      except CatchableError as error:
        echo "firm player: ignoring bad frame: ", error.msg
  except CatchableError as error:
    echo "firm player: socket closed by the game (", error.msg, "), exiting"
  try:
    socket.close()
  except CatchableError:
    discard
