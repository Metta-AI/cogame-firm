## Deterministic payoffs for Firm's Jev candidate actions against four
## taskmaster opponents. Repeat the chosen candidate every shift.

import firm/[llm, sim]

for (seed, choices) in [
    (1, @["steady", "low_pay", "high_pay", "taskmaster"]),
    (3, @["steady", "rest", "taskmaster"])
]:
  for choice in choices:
    var config = defaultGameConfig()
    config.seed = seed
    for seat in 0 ..< Seats:
      config.players.add(PlayerConfig(name: "P" & $seat))
      config.tokens.add("t" & $seat)
    var game = initSim(config)
    while not game.done:
      for seat in game.orderedSeats():
        var action = scriptedAction(game, seat, skTaskmaster)
        if seat == 0:
          for candidate in game.jevCandidates(seat):
            if candidate.name == choice:
              action = candidate.decision
        if game.isManager(seat):
          game.applyMemo(seat, action.orders, action.payroll, action.split,
            action.say, action.notes, action.scripted)
        else:
          game.applyWork(seat, action.line, action.run, action.maint,
            action.say, action.notes, action.scripted)
    echo seed, " ", choice, " seat0_score=", game.score(0),
      " profit=", game.firmProfit
