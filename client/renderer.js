// Firm shared renderer + drivers.
//
// One canvas scene — the factory floor. A glass office sits at the top with
// the manager cog behind its window, the order board hanging beside it (two
// bars, line A and line B, next shift's numbers ghosted behind them) and the
// pool and running profit printed under it. Four machine bays run across the
// floor, one per machine: the operator cog in its machine colour, the machine
// body, the LINE tag, a 0–100 condition gauge and the output dock of crates.
// On a memo, paper slips fly from the office to every bay carrying the line
// each machine was ordered onto; on a settlement, coins stream back out along
// the split. Under the floor a chart tracks demand against units made per
// line, with the profit and wages lines and an amber rule at the demand
// switch.
//
// Fed by three drivers: live /global websocket, live /player websocket, and
// replay (from the game's /replay websocket or the static wasm bundle). All
// state derivation happens server-side / wasm-side; this file only draws
// state objects (see sim.tableStateJson).
(function () {
  "use strict";

  // Ink & Print palette, matching the coworld-ctf broadcast chrome. The
  // MACHINE, not the slot, carries the colour: machine 1 is red, 2 blue, 3
  // green, 4 yellow, and the office is violet — so a spectator reads
  // "machine 3 is the green one" and the scorebug agrees with the floor.
  var COLORS = ["red", "blue", "green", "yellow", "violet", "orange"];
  var COLOR_HEX = {
    red: "#e0523a",
    blue: "#3f7cc4",
    green: "#45a85e",
    yellow: "#ddc531",
    violet: "#a86fd6",
    orange: "#e08a3a"
  };
  var PAPER = "#f2e8d8";
  var PAPER_DIM = "#b8ac98";
  var INK = "#2a1f16";
  var AMBER = "#e8a33d";
  var GHOST = "#8a7f72";
  var CRATE = "#c9a46a";
  var CRATE_EDGE = "#6b4c22";
  var BAD = "#e0523a";
  var GOOD = "#45a85e";
  var STRIP = "rgba(242, 232, 216, 0.06)";
  var OFFICE_COLOR = "violet";
  // Timing of the shift transition: slips fly from the office, coins slide
  // back, speech bubbles pop, sparks and wrenches run while work is fresh.
  var SLIDE_MS = 900;
  var SLIP_MS = 900;
  var BUBBLE_HOLD_MS = 6000;
  var WORK_MS = 2600;
  var NARROW = 560;

  function assetUrl(base, name) {
    return base.replace(/\/$/, "") + "/" + name;
  }

  function loadImages(base, names, done) {
    var images = {};
    var pending = names.length;
    names.forEach(function (name) {
      var img = new Image();
      img.onload = img.onerror = function () {
        pending -= 1;
        if (pending === 0) done(images);
      };
      img.src = assetUrl(base, name);
      images[name] = img;
    });
  }

  // The machine a seat runs decides its colour; the manager is the office.
  function seatColor(seat) {
    if (!seat || seat.roleId === 0) return OFFICE_COLOR;
    return COLORS[(seat.worker || 0) % 4];
  }

  function machineColor(index) {
    return COLORS[index % 4];
  }

  function cogSprite(color) {
    return color === OFFICE_COLOR ? "cog_manager.png" :
      "cog_worker_" + color + ".png";
  }

  function makeRenderer(canvas, assetBase, onReady) {
    var ctx = canvas.getContext("2d");
    var names = ["cog_manager.png", "cog_worker_red.png",
      "cog_worker_blue.png", "cog_worker_green.png", "cog_worker_yellow.png",
      "arena_floor.png"];
    loadImages(assetBase, names, function (images) {
      onReady({
        draw: function (view) { draw(ctx, canvas, images, view); }
      });
    });
  }

  function ellipsize(ctx, text, maxWidth) {
    if (ctx.measureText(text).width <= maxWidth) return text;
    var cut = text;
    while (cut.length > 1 && ctx.measureText(cut + "…").width > maxWidth) {
      cut = cut.slice(0, -1);
    }
    return cut + "…";
  }

  function hexToRgb(hex) {
    var n = parseInt(hex.slice(1), 16);
    return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
  }
  function rgba(hex, alpha) {
    var c = hexToRgb(hex);
    return "rgba(" + c[0] + "," + c[1] + "," + c[2] + "," + alpha + ")";
  }

  // Words and numerals a casual spectator can read: $45.60, $2,188.80.
  function money(value) {
    var n = Math.round((value || 0) * 100) / 100;
    var sign = n < 0 ? "-" : "";
    var body = Math.abs(n).toFixed(2);
    var parts = body.split(".");
    parts[0] = parts[0].replace(/\B(?=(\d{3})+(?!\d))/g, ",");
    return sign + "$" + parts.join(".");
  }

  function roundRect(ctx, x, y, w, h, r) {
    ctx.beginPath();
    ctx.moveTo(x + r, y);
    ctx.arcTo(x + w, y, x + w, y + h, r);
    ctx.arcTo(x + w, y + h, x, y + h, r);
    ctx.arcTo(x, y + h, x, y, r);
    ctx.arcTo(x, y, x + w, y, r);
    ctx.closePath();
  }

  // ---- Layout --------------------------------------------------------------

  // The floor is a FIXED arena, always drawn to fit the frame: the office
  // strip on top, four machine bays under it (2 x 2 when the frame is narrow),
  // and the chart across the bottom.
  function computeLayout(width, height) {
    var margin = 10;
    var narrow = width < NARROW;
    var chartH = Math.max(74, Math.min(height * 0.28, 170));
    var floorTop = margin;
    var floorH = height - chartH - margin * 2;
    var officeH = Math.min(floorH * (narrow ? 0.3 : 0.36), 190);
    var bayTop = floorTop + officeH + 4;
    var bayH = floorTop + floorH - bayTop;
    var cols = narrow ? 2 : 4;
    var rows = narrow ? 2 : 1;
    var pitch = (width - 2 * margin) / cols;
    var rowH = bayH / rows;
    var size = Math.max(26, Math.min(76, pitch * 0.30, rowH * 0.34));
    var bays = [];
    for (var i = 0; i < 4; i++) {
      var col = i % cols;
      var row = Math.floor(i / cols);
      bays.push({
        x: margin + pitch * (col + 0.5),
        y: bayTop + rowH * row,
        w: pitch,
        h: rowH
      });
    }
    return {
      width: width, height: height, narrow: narrow, margin: margin,
      size: size, scale: size / 76, pitch: pitch,
      floorTop: floorTop, floorH: floorH,
      office: { x: width / 2, y: floorTop, w: width - 2 * margin, h: officeH },
      bays: bays,
      chart: { x: margin, y: height - chartH - margin, w: width - 2 * margin,
        h: chartH }
    };
  }

  // ---- Drawing -------------------------------------------------------------

  function draw(ctx, canvas, images, view) {
    var w = canvas.width;
    var h = canvas.height;
    var seats = view.seats || [];
    var machines = view.machines || [];
    var board = view.board || {};
    var now = view.now || Date.now();
    var L = computeLayout(w, h);
    var scale = L.scale;
    var fx = view.effects || {};

    // Floor.
    var floor = images["arena_floor.png"];
    if (floor && floor.width) {
      ctx.fillStyle = ctx.createPattern(floor, "repeat");
    } else {
      ctx.fillStyle = "#16110d";
    }
    ctx.fillRect(0, 0, w, h);
    ctx.fillStyle = "rgba(18, 13, 9, 0.45)";
    ctx.fillRect(0, 0, w, h);

    ctx.save();
    ctx.fillStyle = STRIP;
    roundRect(ctx, 4, L.floorTop, w - 8, L.floorH, 10 * scale);
    ctx.fill();
    ctx.restore();

    var manager = null;
    seats.forEach(function (seat) { if (seat.roleId === 0) manager = seat; });

    drawOffice(ctx, images, L, view, manager, board, scale, fx, now);

    for (var m = 0; m < 4; m++) {
      var machine = machines[m] || {};
      var seat = seats[machine.seat] || null;
      drawBay(ctx, images, L, m, machine, seat, view, scale, {
        now: now,
        workAt: fx.workAt ? fx.workAt[m] : null,
        settleAt: fx.settleAt,
        memoAt: fx.memoAt,
        say: fx.lastSay ? fx.lastSay[m] : "",
        sayAt: fx.sayAt ? fx.sayAt[m] : null,
        payDelta: fx.payDelta ? fx.payDelta[m] : 0,
        pending: seat && seat.pending && !view.done
      });
    }

    drawChart(ctx, L.chart, view, scale);
  }

  function drawOffice(ctx, images, L, view, manager, board, scale, fx, now) {
    var O = L.office;
    var boxW = Math.min(O.w * (L.narrow ? 0.56 : 0.30), 300);
    var boxH = Math.min(O.h * 0.74, 150);
    var x = O.x - boxW / 2;
    // Bottom-aligned in the strip, so the memo bubble has headroom above it.
    var y = O.y + (O.h - boxH);

    // Glass office: a lit window with the manager cog behind it.
    ctx.save();
    ctx.fillStyle = "rgba(232, 163, 61, 0.10)";
    roundRect(ctx, x, y, boxW, boxH, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = rgba(COLOR_HEX[OFFICE_COLOR], 0.75);
    ctx.lineWidth = 2;
    ctx.stroke();
    ctx.restore();

    var size = Math.min(boxH * 0.68, L.size * 1.15);
    var sprite = images[cogSprite(OFFICE_COLOR)];
    if (sprite && sprite.width) {
      ctx.save();
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, x + 8 * scale, y + boxH - size - 6 * scale,
        size, size);
      ctx.restore();
    }

    ctx.save();
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    var tx = x + size + 14 * scale;
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("THE OFFICE", tx, y + 7 * scale);
    ctx.font = "600 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.fillText(ellipsize(ctx, manager ? manager.name : "—",
      boxW - size - 20 * scale), tx, y + 21 * scale);
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = AMBER;
    ctx.fillText("POOL " + (view.payroll || 0) + "%", tx, y + 39 * scale);
    ctx.fillStyle = PAPER;
    var ledger = view.ledger || {};
    ctx.fillText("PROFIT " + money(ledger.profitTotal), tx, y + 56 * scale);
    ctx.restore();

    // The order board hangs beside the office: two bars, next shift ghosted.
    var bw = Math.min(O.w * (L.narrow ? 0.18 : 0.20), 190);
    var bx = L.narrow ? O.x + boxW / 2 + 6 * scale :
      O.x + boxW / 2 + 18 * scale;
    if (bx + bw > L.margin + O.w) bx = L.margin + O.w - bw;
    drawOrderBoard(ctx, bx, y, bw, boxH, board, scale, view);

    // Paper planes: on a memo a slip flies from the office to each bay.
    if (typeof fx.memoAt === "number") {
      var t = Math.min(1, (now - fx.memoAt) / SLIP_MS);
      var eased = 1 - Math.pow(1 - t, 2);
      var orders = fx.memoOrders || [];
      for (var i = 0; i < L.bays.length; i++) {
        var bay = L.bays[i];
        var sx = O.x + (bay.x - O.x) * eased;
        var sy = (y + boxH * 0.5) +
          (bay.y + bay.h * 0.18 - (y + boxH * 0.5)) * eased -
          Math.sin(eased * Math.PI) * 16 * scale;
        drawSlip(ctx, sx, sy, "→ LINE " + (orders[i] || "?"), scale,
          COLOR_HEX[machineColor(i)]);
      }
    }

    // The memo itself pops as a speech bubble over the office.
    if (fx.lastMemo) {
      var age = typeof fx.memoSayAt === "number" ? now - fx.memoSayAt :
        BUBBLE_HOLD_MS;
      var alpha = age < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.4, 1 - (age - BUBBLE_HOLD_MS) / 4000);
      // Beside the office when the frame is wide enough for it, above it
      // otherwise — never over the readouts if that can be helped.
      var room = x - L.margin;
      if (room > 170 * scale) {
        drawBubble(ctx, L.margin + room / 2, y + boxH * 0.92, fx.lastMemo,
          room - 12 * scale, scale, alpha);
      } else {
        drawBubble(ctx, O.x, Math.max(y - 2 * scale, 48 * scale), fx.lastMemo,
          Math.min(L.width * 0.72, 360), scale, alpha);
      }
    }
  }

  function drawOrderBoard(ctx, x, y, w, h, board, scale, view) {
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, x, y, w, h, 5 * scale);
    ctx.fill();
    ctx.strokeStyle = view.switched ? AMBER : "rgba(242, 232, 216, 0.14)";
    ctx.lineWidth = 1;
    ctx.stroke();
    ctx.font = "700 " + Math.round(9 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("ORDER BOARD", x + 6 * scale, y + 5 * scale);
    var maxV = Math.max(1, board.demandA || 0, board.demandB || 0,
      board.nextA || 0, board.nextB || 0);
    var barX = x + 26 * scale;
    var barW = w - 34 * scale;
    var rows = [
      { label: "A", now: board.demandA || 0, next: board.nextA || 0 },
      { label: "B", now: board.demandB || 0, next: board.nextB || 0 }
    ];
    rows.forEach(function (row, i) {
      var by = y + (h * (i === 0 ? 0.34 : 0.66)) - 9 * scale;
      var bh = 15 * scale;
      // Next shift, ghosted behind.
      ctx.fillStyle = "rgba(242, 232, 216, 0.18)";
      ctx.fillRect(barX, by - 3 * scale, barW * row.next / maxV, bh + 6 * scale);
      ctx.fillStyle = i === 0 ? COLOR_HEX.blue : COLOR_HEX.green;
      ctx.fillRect(barX, by, barW * row.now / maxV, bh);
      ctx.font = "700 " + Math.round(12 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = PAPER;
      ctx.textBaseline = "middle";
      ctx.fillText(row.label, x + 8 * scale, by + bh / 2);
      ctx.fillText(String(row.now), barX + 4 * scale, by + bh / 2);
      ctx.font = "600 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = GHOST;
      ctx.fillText("next " + row.next, barX + barW - 40 * scale,
        by + bh / 2);
    });
    ctx.restore();
  }

  function drawBay(ctx, images, L, index, machine, seat, view, scale, opts) {
    var bay = L.bays[index];
    var color = machineColor(index);
    var size = L.size;
    var cx = bay.x;
    var cogY = bay.y + bay.h * 0.34;

    // Bay plate.
    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.28)";
    roundRect(ctx, bay.x - bay.w / 2 + 3, bay.y + 2, bay.w - 6, bay.h - 6,
      6 * scale);
    ctx.fill();
    ctx.restore();

    var line = machine.setup || "?";
    var order = machine.order || "?";
    var defied = order !== "?" && line !== order;
    var idle = machine.run === 0;
    var fresh = typeof opts.workAt === "number" &&
      opts.now - opts.workAt < WORK_MS;

    drawTag(ctx, cx, bay.y + 12 * scale, "MACHINE " + (index + 1),
      COLOR_HEX[color], scale);

    // The operator cog, with an idle sway when it ran no hours.
    var sprite = images[cogSprite(color)];
    ctx.save();
    var sway = idle && fresh ?
      Math.sin((opts.now - opts.workAt) / 260) * 3 * scale : 0;
    ctx.translate(cx - size * 0.62 + sway, cogY);
    if (sprite && sprite.width) {
      ctx.imageSmoothingEnabled = false;
      ctx.drawImage(sprite, -size / 2, -size / 2, size, size);
    } else {
      ctx.fillStyle = COLOR_HEX[color];
      ctx.fillRect(-size / 3, -size / 3, size / 1.5, size / 1.5);
    }
    ctx.restore();

    // The machine body, with sparks while it runs and a turning wrench
    // while it is maintained.
    drawMachine(ctx, cx + size * 0.5, cogY, size * 0.86, scale, color,
      fresh ? machine.run : 0, fresh ? machine.maint : 0, opts.now);

    // Acting halo while the floor waits on this seat.
    if (opts.pending) {
      ctx.save();
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2;
      ctx.setLineDash([6, 5]);
      ctx.beginPath();
      ctx.arc(cx - size * 0.62, cogY, size * 0.62, 0, Math.PI * 2);
      ctx.stroke();
      ctx.restore();
    }

    // Line tag, amber when the machine is not on the line it was ordered on.
    drawTag(ctx, cx - size * 0.62, cogY + size * 0.66,
      "LINE " + line, defied ? AMBER : COLOR_HEX[color], scale);

    ctx.save();
    ctx.textAlign = "center";
    ctx.textBaseline = "alphabetic";
    ctx.font = "600 " + Math.round(12 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.shadowColor = "rgba(0,0,0,0.8)";
    ctx.shadowBlur = 4;
    ctx.fillText(ellipsize(ctx, (seat && seat.name) || "", bay.w * 0.9), cx,
      bay.y + bay.h - 6 * scale);
    ctx.restore();

    // Condition gauge: green → amber → red, with the number printed.
    drawGauge(ctx, cx - bay.w * 0.40, cogY + size * 0.94, bay.w * 0.44,
      9 * scale, machine.condition, scale);

    // Output dock: the shift's units as crates, or the printed count when
    // the frame is too narrow for crate art.
    drawDock(ctx, cx + bay.w * 0.04, cogY + size * 0.86, bay.w * 0.42,
      Math.max(18 * scale, bay.h * 0.22), machine.units || 0, scale,
      L.narrow);

    if (defied) {
      drawTag(ctx, cx + size * 0.5, bay.y + 12 * scale, "DEFIED ORDERS", BAD,
        scale);
    } else if (idle && view.shiftsPlayed > 0) {
      drawTag(ctx, cx + size * 0.5, bay.y + 12 * scale, "IDLE", BAD, scale);
    }

    // Payday: coins stream from the office along the split, with the amount
    // printed and a green/red delta against last shift's pay.
    if (typeof opts.settleAt === "number") {
      var t = Math.min(1, (opts.now - opts.settleAt) / SLIDE_MS);
      var eased = 1 - Math.pow(1 - t, 3);
      var fromX = L.office.x;
      var fromY = L.office.y + L.office.h * 0.6;
      var coinX = fromX + (cx - fromX) * eased;
      var coinY = fromY + (cogY - fromY) * eased;
      drawCoins(ctx, coinX, coinY, scale, machine.share || 0);
    }
    if (view.shiftsPlayed > 0) {
      ctx.save();
      ctx.textAlign = "center";
      ctx.textBaseline = "alphabetic";
      ctx.font = "700 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.fillStyle = AMBER;
      ctx.shadowColor = "rgba(0,0,0,0.85)";
      ctx.shadowBlur = 3;
      ctx.fillText(money(machine.pay) + "  " + (machine.share || 0) + "%", cx,
        bay.y + bay.h - 20 * scale);
      if (opts.payDelta) {
        ctx.font = "600 " + Math.round(10 * scale) +
          "px 'rajdhani', system-ui, sans-serif";
        ctx.fillStyle = opts.payDelta > 0 ? GOOD : BAD;
        ctx.fillText((opts.payDelta > 0 ? "▲ " : "▼ ") +
          money(Math.abs(opts.payDelta)), cx + bay.w * 0.32,
          bay.y + bay.h - 20 * scale);
      }
      ctx.restore();
    }

    // The worker's report, as a speech bubble over the cog.
    if (opts.say) {
      var age = typeof opts.sayAt === "number" ? opts.now - opts.sayAt :
        BUBBLE_HOLD_MS;
      var alpha = age < BUBBLE_HOLD_MS ? 1 :
        Math.max(0.4, 1 - (age - BUBBLE_HOLD_MS) / 4000);
      drawBubble(ctx, cx, cogY - size * 0.56, opts.say, bay.w * 0.96, scale,
        alpha);
    }
  }

  function drawMachine(ctx, x, y, size, scale, color, run, maint, now) {
    ctx.save();
    ctx.fillStyle = "#4c3b2c";
    roundRect(ctx, x - size / 2, y - size / 2, size, size * 0.9, 4 * scale);
    ctx.fill();
    ctx.fillStyle = "rgba(242, 232, 216, 0.07)";
    roundRect(ctx, x - size / 2 + 3 * scale, y - size / 2 + 3 * scale,
      size - 6 * scale, size * 0.36, 3 * scale);
    ctx.fill();
    ctx.strokeStyle = rgba(COLOR_HEX[color], 0.8);
    ctx.lineWidth = 2;
    ctx.stroke();
    // Belt slot.
    ctx.fillStyle = "rgba(242, 232, 216, 0.10)";
    ctx.fillRect(x - size * 0.36, y + size * 0.14, size * 0.72, size * 0.10);
    ctx.restore();

    if (run > 0) {
      // Sparks off the head, intensity from the hours run.
      ctx.save();
      var count = Math.min(10, 2 + run);
      for (var i = 0; i < count; i++) {
        var phase = (now / 90 + i * 1.7) % 6.283;
        var r = (4 + (i % 3) * 4) * scale * (1 + run / 12);
        ctx.fillStyle = i % 2 ? AMBER : PAPER;
        ctx.globalAlpha = 0.55 + 0.45 * Math.abs(Math.sin(phase));
        ctx.fillRect(x + Math.cos(phase) * r - scale,
          y - size * 0.38 + Math.sin(phase) * r * 0.6 - scale,
          2 * scale, 2 * scale);
      }
      ctx.restore();
    }
    if (maint > 0) {
      // A turning wrench.
      ctx.save();
      ctx.translate(x + size * 0.34, y - size * 0.34);
      ctx.rotate((now / 400) % 6.283);
      ctx.strokeStyle = PAPER;
      ctx.lineWidth = 2.2 * scale;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(-5 * scale, -5 * scale);
      ctx.lineTo(5 * scale, 5 * scale);
      ctx.stroke();
      ctx.beginPath();
      ctx.arc(-6 * scale, -6 * scale, 3 * scale, 0.6, 5.2);
      ctx.stroke();
      ctx.restore();
    }
  }

  function drawGauge(ctx, x, y, w, h, condition, scale) {
    var value = typeof condition === "number" && condition >= 0 ?
      condition : 0;
    ctx.save();
    ctx.fillStyle = "rgba(242, 232, 216, 0.12)";
    ctx.fillRect(x, y, w, h);
    ctx.fillStyle = value >= 60 ? GOOD : value >= 30 ? AMBER : BAD;
    ctx.fillRect(x, y, w * Math.max(0, Math.min(1, value / 100)), h);
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER;
    ctx.textAlign = "left";
    ctx.textBaseline = "bottom";
    ctx.fillText("COND " + value, x, y - 2 * scale);
    ctx.restore();
  }

  function drawDock(ctx, x, y, w, h, units, scale, narrow) {
    ctx.save();
    ctx.font = "700 " + Math.round(13 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "bottom";
    ctx.fillStyle = units > 0 ? PAPER : GHOST;
    ctx.shadowColor = "rgba(0,0,0,0.9)";
    ctx.shadowBlur = 3;
    ctx.fillText(units + " units", x, y + h);
    ctx.restore();
    if (narrow || units <= 0) return;
    drawCrateCluster(ctx, x + w * 0.5, y + h * 0.36, units, scale, CRATE,
      CRATE_EDGE, false);
  }

  // A compact crate cluster: up to 12 crates in rows of 4.
  function drawCrateCluster(ctx, cx, cy, units, scale, fill, edge, tag) {
    var n = Math.min(12, Math.max(1, Math.ceil(units / 2)));
    var cs = 11 * scale;
    var cols = Math.min(4, n);
    var rows = Math.ceil(n / cols);
    var x0 = cx - cols * cs / 2;
    var y0 = cy + rows * cs / 2 - cs;
    ctx.save();
    for (var i = 0; i < n; i++) {
      var cxi = x0 + (i % cols) * cs;
      var cyi = y0 - Math.floor(i / cols) * cs;
      drawCrate(ctx, cxi, cyi, cs - 1, fill, edge);
    }
    if (tag) {
      ctx.font = "700 " + Math.round(13 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "center";
      ctx.textBaseline = "bottom";
      ctx.fillStyle = PAPER;
      ctx.shadowColor = "rgba(0,0,0,0.9)";
      ctx.shadowBlur = 3;
      ctx.fillText(String(units), cx, y0 - rows * cs + cs - 3 * scale);
    }
    ctx.restore();
  }

  function drawCrate(ctx, x, y, s, fill, edge) {
    ctx.fillStyle = fill;
    ctx.fillRect(x, y, s, s);
    ctx.strokeStyle = edge;
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, s - 1, s - 1);
    ctx.beginPath();
    ctx.moveTo(x + 1, y + s / 2);
    ctx.lineTo(x + s - 1, y + s / 2);
    ctx.stroke();
  }

  function drawCoins(ctx, x, y, scale, share) {
    ctx.save();
    var n = Math.max(1, Math.min(6, Math.round((share || 0) / 12) + 1));
    for (var i = 0; i < n; i++) {
      ctx.fillStyle = AMBER;
      ctx.beginPath();
      ctx.arc(x + (i % 3) * 6 * scale - 6 * scale,
        y + Math.floor(i / 3) * 6 * scale, 3.2 * scale, 0, Math.PI * 2);
      ctx.fill();
      ctx.strokeStyle = "rgba(0,0,0,0.4)";
      ctx.lineWidth = 1;
      ctx.stroke();
    }
    ctx.restore();
  }

  function drawSlip(ctx, x, y, text, scale, accent) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var pad = 5 * scale;
    var bw = ctx.measureText(text).width + pad * 2;
    var bh = 15 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 4;
    ctx.fillStyle = PAPER;
    ctx.fillRect(x - bw / 2, y - bh / 2, bw, bh);
    ctx.shadowColor = "transparent";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 1.5;
    ctx.strokeRect(x - bw / 2, y - bh / 2, bw, bh);
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, x, y + scale);
    ctx.restore();
  }

  function drawTag(ctx, x, y, text, accent, scale) {
    ctx.save();
    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    var label = text.toUpperCase();
    var pad = 5 * scale;
    var bw = ctx.measureText(label).width + pad * 2;
    var bh = 15 * scale;
    ctx.fillStyle = "rgba(242, 232, 216, 0.95)";
    ctx.strokeStyle = accent;
    ctx.lineWidth = 2;
    roundRect(ctx, x - bw / 2, y - bh / 2, bw, bh, 4 * scale);
    ctx.fill();
    ctx.stroke();
    ctx.fillStyle = INK;
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(label, x, y + scale);
    ctx.restore();
  }

  function wrapLines(ctx, text, maxWidth, maxLines) {
    var words = text.split(/\s+/);
    var lines = [];
    var line = "";
    words.forEach(function (word) {
      var probe = line ? line + " " + word : word;
      if (ctx.measureText(probe).width > maxWidth && line) {
        lines.push(line);
        line = word;
      } else {
        line = probe;
      }
    });
    if (line) lines.push(line);
    var overflow = lines.length > maxLines;
    lines = lines.slice(0, maxLines);
    if (overflow && lines.length) {
      lines[lines.length - 1] = ellipsize(ctx, lines[lines.length - 1] + "…",
        maxWidth);
    }
    return lines.map(function (l) { return ellipsize(ctx, l, maxWidth); });
  }

  function drawBubble(ctx, x, bottom, text, maxW, scale, alpha) {
    ctx.save();
    ctx.globalAlpha = alpha;
    ctx.font = Math.round(10.5 * scale) +
      "px -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif";
    var pad = 6 * scale;
    var lineH = 13 * scale;
    var lines = wrapLines(ctx, text, maxW - pad * 2, 3);
    var bw = 0;
    lines.forEach(function (l) { bw = Math.max(bw, ctx.measureText(l).width); });
    bw += pad * 2;
    var bh = lines.length * lineH + pad * 2 - 2;
    var y = bottom - bh - 6 * scale;
    ctx.shadowColor = "rgba(0,0,0,0.6)";
    ctx.shadowBlur = 5;
    ctx.fillStyle = PAPER;
    roundRect(ctx, x - bw / 2, y, bw, bh, 5 * scale);
    ctx.fill();
    ctx.shadowColor = "transparent";
    ctx.beginPath();
    ctx.moveTo(x - 5 * scale, y + bh);
    ctx.lineTo(x, y + bh + 6 * scale);
    ctx.lineTo(x + 5 * scale, y + bh);
    ctx.closePath();
    ctx.fill();
    ctx.fillStyle = INK;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    lines.forEach(function (l, i) {
      ctx.fillText(l, x - bw / 2 + pad, y + pad + i * lineH);
    });
    ctx.restore();
  }

  // Demand against units made per line, plus profit and wages, with an amber
  // rule at the demand switch — the picture of whether the floor followed
  // the board.
  function drawChart(ctx, rect, view, scale) {
    var series = view.series || {};
    var demandA = series.demandA || [];
    var demandB = series.demandB || [];
    var madeA = series.madeA || [];
    var madeB = series.madeB || [];
    var profit = series.profit || [];
    var shifts = Math.max(view.shifts || 0, 4);
    var padL = 30 * scale;
    var padR = 74 * scale;
    var padT = 14 * scale;
    var padB = 14 * scale;
    var x0 = rect.x + padL;
    var x1 = rect.x + rect.w - padR;
    var y0 = rect.y + padT;
    var y1 = rect.y + rect.h - padB;
    var maxY = 8;
    [demandA, demandB, madeA, madeB].forEach(function (s) {
      s.forEach(function (v) { if (v > maxY) maxY = v; });
    });
    maxY = Math.ceil(maxY * 1.15 / 4) * 4;
    var maxMoney = 1;
    profit.forEach(function (v) { if (v > maxMoney) maxMoney = v; });
    function px(shift) { return x0 + (x1 - x0) * shift / shifts; }
    function py(v) { return y1 - (y1 - y0) * v / maxY; }
    function pm(v) { return y1 - (y1 - y0) * v / (maxMoney * 1.2); }

    ctx.save();
    ctx.fillStyle = "rgba(18, 13, 9, 0.55)";
    roundRect(ctx, rect.x, rect.y, rect.w, rect.h, 6 * scale);
    ctx.fill();
    ctx.strokeStyle = "rgba(242, 232, 216, 0.12)";
    ctx.lineWidth = 1;
    ctx.stroke();

    ctx.font = "700 " + Math.round(10 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.fillStyle = PAPER_DIM;
    ctx.textAlign = "left";
    ctx.textBaseline = "top";
    ctx.fillText("DEMAND VS UNITS MADE", rect.x + 8 * scale,
      rect.y + 3 * scale);
    ctx.strokeStyle = "rgba(242, 232, 216, 0.14)";
    for (var g = 0; g <= 4; g++) {
      var gv = maxY * g / 4;
      var gy = py(gv);
      ctx.beginPath();
      ctx.moveTo(x0, gy);
      ctx.lineTo(x1, gy);
      ctx.stroke();
      ctx.fillStyle = GHOST;
      ctx.font = "600 " + Math.round(9 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.fillText(String(Math.round(gv)), x0 - 4 * scale, gy);
    }
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (var s = 0; s <= shifts; s += 1) {
      ctx.fillStyle = GHOST;
      ctx.fillText(String(s), px(s), y1 + 2 * scale);
    }

    function stepped(values, color, dashed) {
      if (!values.length) return;
      ctx.strokeStyle = color;
      ctx.lineWidth = 2;
      if (dashed) ctx.setLineDash([4, 3]); else ctx.setLineDash([]);
      ctx.beginPath();
      values.forEach(function (v, i) {
        var x = px(i);
        if (i === 0) ctx.moveTo(x, py(v));
        else {
          ctx.lineTo(x, py(values[i - 1]));
          ctx.lineTo(x, py(v));
        }
      });
      ctx.stroke();
      ctx.setLineDash([]);
    }
    stepped(demandA, rgba(COLOR_HEX.blue, 0.75), true);
    stepped(demandB, rgba(COLOR_HEX.green, 0.75), true);
    stepped(madeA, COLOR_HEX.blue, false);
    stepped(madeB, COLOR_HEX.green, false);

    if (profit.length) {
      ctx.strokeStyle = AMBER;
      ctx.lineWidth = 2;
      ctx.beginPath();
      profit.forEach(function (v, i) {
        var x = px(i);
        if (i === 0) ctx.moveTo(x, pm(v)); else ctx.lineTo(x, pm(v));
      });
      ctx.stroke();
    }

    // The demand switch, and the now-line.
    if (typeof view.switchShift === "number" &&
        view.switchShift <= shifts) {
      ctx.strokeStyle = rgba(AMBER, 0.55);
      ctx.setLineDash([2, 3]);
      ctx.beginPath();
      ctx.moveTo(px(view.switchShift), y0 - 4 * scale);
      ctx.lineTo(px(view.switchShift), y1);
      ctx.stroke();
      ctx.setLineDash([]);
      ctx.fillStyle = AMBER;
      ctx.font = "700 " + Math.round(8 * scale) +
        "px 'rajdhani', system-ui, sans-serif";
      ctx.textAlign = "left";
      ctx.textBaseline = "top";
      ctx.fillText("DEMAND SWITCH", px(view.switchShift) + 3 * scale,
        y0 - 4 * scale);
    }
    var nowX = px(view.shift || 0);
    ctx.strokeStyle = rgba(PAPER, 0.8);
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    ctx.moveTo(nowX, y0 - 4 * scale);
    ctx.lineTo(nowX, y1);
    ctx.stroke();

    // Legend.
    var lx = x1 + 10 * scale;
    var ly = y0;
    var legend = [
      { label: "A made", color: COLOR_HEX.blue },
      { label: "B made", color: COLOR_HEX.green },
      { label: "profit", color: AMBER }
    ];
    ctx.font = "600 " + Math.round(9.5 * scale) +
      "px 'rajdhani', system-ui, sans-serif";
    ctx.textAlign = "left";
    ctx.textBaseline = "middle";
    legend.forEach(function (row, i) {
      ctx.fillStyle = row.color;
      ctx.fillRect(lx, ly + i * 13 * scale - 3 * scale, 10 * scale, 6 * scale);
      ctx.fillStyle = PAPER_DIM;
      ctx.fillText(row.label, lx + 14 * scale, ly + i * 13 * scale);
    });
    ctx.strokeStyle = "rgba(242, 232, 216, 0.5)";
    ctx.setLineDash([3, 2]);
    ctx.beginPath();
    ctx.moveTo(lx, ly + 3 * 13 * scale);
    ctx.lineTo(lx + 10 * scale, ly + 3 * 13 * scale);
    ctx.stroke();
    ctx.setLineDash([]);
    ctx.fillStyle = PAPER_DIM;
    ctx.fillText("demand", lx + 14 * scale, ly + 3 * 13 * scale);
    ctx.restore();
  }

  // ---- Names ---------------------------------------------------------------

  // The agents only ever hear anonymous cog aliases ("Sprocket", "Gizmo");
  // the payload carries the policy names separately, spectator-side only.
  // A name map swaps them in wherever a name is RENDERED while the
  // underlying events keep the aliases. Baseline fillers keep their alias.
  function isBaselineFiller(name) {
    return /^baseline(\s*\(\d+\))?$/i.test(name);
  }

  function makeNameMap(tableNames, policyNames) {
    var table = tableNames || [];
    var display = table.map(function (name, i) {
      var policy = policyNames && policyNames[i];
      return (policy && !isBaselineFiller(policy)) ? policy : name;
    });
    var byAlias = {};
    table.forEach(function (name, i) {
      if (name && display[i] && display[i] !== name) byAlias[name] = display[i];
    });
    var aliases = Object.keys(byAlias);
    var pattern = aliases.length ? new RegExp(
      "\\b(?:" + aliases.map(function (name) {
        return name.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      }).join("|") + ")\\b", "g") : null;
    return {
      seat: function (i) { return display[i] || ("Seat " + i); },
      text: function (text) {
        if (!pattern) return text;
        return text.replace(pattern, function (match) {
          return byAlias[match];
        });
      }
    };
  }

  function applyNames(seats, nameMap) {
    return (seats || []).map(function (seat, i) {
      var copy = Object.assign({}, seat);
      copy.name = nameMap.seat(i);
      return copy;
    });
  }

  function clampName(name) {
    var n = name || "";
    return n.length > 24 ? n.slice(0, 23) + "…" : n;
  }

  // ---- Event feed ----------------------------------------------------------

  function lineList(orders) {
    return (orders || []).join(" ");
  }

  function splitList(split) {
    return (split || []).join("/");
  }

  // `ctx` carries what a line needs from earlier events: who is on which
  // machine, and the running ledger.
  function describeEvent(event, nameMap, ctx) {
    function name(i) {
      return clampName(nameMap.seat(i));
    }
    switch (event.kind) {
      case "start":
        return "The floor opens — four machines in perfect condition, " +
          "machines 1-3 on line A and machine 4 on line B.";
      case "shift":
        return "The board wants " + event.demandA + " A and " +
          event.demandB + " B. Orders: " +
          lineList((event.machines || []).map(function (m) {
            return m.order;
          })) + " · pool " + event.payroll + "% · shares " +
          splitList(event.split) + ".";
      case "memo":
        return name(event.seat) + " (Manager) posts: \"" +
          (event.say || "(no memo)") + "\" — orders " +
          lineList(event.orders) + ", pool " + event.payroll +
          "%, shares " + splitList(event.split) + ".";
      case "work":
        var machine = "Machine " + ((event.worker || 0) + 1);
        var tail = "";
        if (ctx.orders && ctx.orders[event.worker] &&
            ctx.orders[event.worker] !== event.line) {
          tail += " · DEFIED ORDERS";
        }
        if (event.run === 0) tail += " · IDLE";
        return name(event.seat) + " (" + machine + ") runs line " +
          event.line + " " + event.run + "h, maintains " + event.maint +
          "h" + tail;
      case "settle":
        var paid = (event.pay || []).map(function (v, i) {
          return "Machine " + (i + 1) + " " + money(v);
        }).join(", ");
        return "Shift " + event.shift + " settles — " +
          ((event.soldA || 0) + (event.soldB || 0)) + " sold, " +
          ((event.surplusA || 0) + (event.surplusB || 0)) + " scrapped, " +
          "revenue " + money(event.revenue) + ", wages " + money(event.pool) +
          ", profit " + money(event.profit) + ". Paid: " + paid + ".";
      case "end":
        return "Final — profit " + money(ctx.profitTotal) + " over " +
          event.shift + " shift" + (event.shift === 1 ? "" : "s") +
          ", wages " + money(ctx.wagesTotal) + "." +
          (event.text === "deadline" ?
            " Episode deadline — the whistle went early; scored on " +
            event.shift + " shifts." : "");
      default: return JSON.stringify(event);
    }
  }

  function blockHead(block) {
    return block < 0 ? "SETUP" : "SHIFT " + block;
  }

  // Renders the full transcript grouped into one section per shift.
  // currentIndex (replay) marks how far playback has reached; omit it for
  // live views.
  function renderFeed(element, events, nameMap, currentIndex) {
    var live = currentIndex === undefined;
    var limit = live ? events.length : currentIndex;
    var html = "";
    var lastBlock = null;
    var ctx = { orders: null, profitTotal: 0, wagesTotal: 0 };
    var lastNotes = {};
    for (var i = 0; i < events.length; i++) {
      var event = events[i];
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.shift;
      if (block !== lastBlock) {
        html += '<div class="feed-round-head">' + blockHead(block) + "</div>";
        lastBlock = block;
      }
      var text = describeEvent(event, nameMap, ctx);
      if (event.kind === "shift") {
        ctx.orders = (event.machines || []).map(function (m) {
          return m.order;
        });
      }
      if (event.kind === "settle") {
        ctx.profitTotal += event.profit || 0;
        ctx.wagesTotal += event.pool || 0;
      }
      var cls = "feed-line feed-" + event.kind +
        (event.kind === "work" ? " seat" + ((event.worker || 0) % 4) : "") +
        (event.kind === "end" ? " feed-rwin" : "") +
        (i >= limit ? " feed-future" : "");
      if (event.kind === "work" && ctx.orders &&
          ctx.orders[event.worker] &&
          ctx.orders[event.worker] !== event.line) {
        cls += " feed-defied";
      }
      html += '<div class="' + cls + '">' + escapeHtml(text) + "</div>";
      if (event.kind === "work" && event.say) {
        html += '<div class="feed-line feed-report' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " says: " +
            nameMap.text(event.say)) + "</div>";
      }
      // Notes: dim, only when the seat's notes changed.
      if ((event.kind === "work" || event.kind === "memo") && event.text &&
          event.text !== lastNotes[event.seat]) {
        lastNotes[event.seat] = event.text;
        html += '<div class="feed-line feed-notes' +
          (i >= limit ? " feed-future" : "") + '">' +
          escapeHtml(clampName(nameMap.seat(event.seat)) + " notes: " +
            nameMap.text(event.text)) + "</div>";
      }
    }
    element.innerHTML = html;

    if (live || limit >= events.length) {
      element.scrollTop = element.scrollHeight;
      return;
    }
    // Keep the playhead's neighbourhood in view while scrubbing.
    var lines = element.querySelectorAll(".feed-line");
    var target = null;
    for (var l = 0; l < lines.length; l++) {
      if (!lines[l].classList.contains("feed-future")) target = lines[l];
    }
    if (target && element.dataset.anchor !== String(limit)) {
      element.dataset.anchor = String(limit);
      element.scrollTo({
        top: Math.max(target.offsetTop - element.offsetTop -
          element.clientHeight * 0.6, 0)
      });
    }
  }

  function escapeHtml(text) {
    return text.replace(/[&<>"]/g, function (c) {
      return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c];
    });
  }

  // ---- Animation bookkeeping ----------------------------------------------

  // Turns a monotonically-growing event list into transient view effects:
  // when the memo was filed (slips fly), when each machine worked (sparks,
  // wrench, idle sway), when the shift settled (coins slide), and each bay's
  // last spoken line.
  function makeEffects() {
    var seen = 0;
    var memoAt = null;
    var memoSayAt = null;
    var memoOrders = null;
    var lastMemo = "";
    var settleAt = null;
    var workAt = [null, null, null, null];
    var sayAt = [null, null, null, null];
    var lastSay = ["", "", "", ""];
    var lastPay = [0, 0, 0, 0];
    var payDelta = [0, 0, 0, 0];
    return {
      // `quiet` (a scrub jump): the whole prefix lands at once, so only the
      // newest event gets to animate.
      absorb: function (events, quiet) {
        var now = Date.now();
        for (; seen < events.length; seen++) {
          var event = events[seen];
          var animate = !quiet || seen >= events.length - 1;
          if (event.kind === "shift") {
            workAt = [null, null, null, null];
            settleAt = null;
            memoAt = null;
          } else if (event.kind === "memo") {
            memoAt = animate ? now : null;
            memoOrders = event.orders || null;
            if (event.say) {
              lastMemo = event.say;
              memoSayAt = animate ? now : null;
            }
          } else if (event.kind === "work") {
            workAt[event.worker] = animate ? now : null;
            if (event.say) {
              lastSay[event.worker] = event.say;
              sayAt[event.worker] = animate ? now : null;
            }
          } else if (event.kind === "settle") {
            settleAt = animate ? now : null;
            (event.pay || []).forEach(function (value, i) {
              payDelta[i] = value - lastPay[i];
              lastPay[i] = value;
            });
          }
        }
      },
      reset: function () {
        seen = 0; memoAt = null; memoSayAt = null; memoOrders = null;
        lastMemo = ""; settleAt = null;
        workAt = [null, null, null, null];
        sayAt = [null, null, null, null];
        lastSay = ["", "", "", ""];
        lastPay = [0, 0, 0, 0];
        payDelta = [0, 0, 0, 0];
      },
      view: function () {
        return { effects: { memoAt: memoAt, memoSayAt: memoSayAt,
          memoOrders: memoOrders, lastMemo: lastMemo, settleAt: settleAt,
          workAt: workAt.slice(), sayAt: sayAt.slice(),
          lastSay: lastSay.slice(), payDelta: payDelta.slice() } };
      }
    };
  }

  // ---- Scorebug, header, demand bar, endscreen -----------------------------

  function matchHeader(state, config) {
    var parts = [];
    if (state) {
      var total = state.shifts || (config && config.shifts) || 0;
      if (state.gameDone || state.done) {
        parts.push("FINAL");
        parts.push("PROFIT " + money((state.ledger || {}).profitTotal));
      } else {
        parts.push("SHIFT " + (state.shift || 0) + (total ? " / " + total : ""));
        var waiting = (state.seats || []).filter(function (s) {
          return s.pending;
        });
        parts.push(waiting.length ? "WAITING ON " + waiting.length :
          "SETTLED");
      }
    }
    return parts.join(" · ");
  }

  function updateDemandBar(element, state) {
    if (!element || !state) return;
    var board = state.board || {};
    var ledger = state.ledger || {};
    var narrow = element.clientWidth > 0 && element.clientWidth < NARROW;
    var text = narrow ?
      "A " + (board.demandA || 0) + " · B " + (board.demandB || 0) + " · " +
        (state.payroll || 0) + "%" :
      "SHIFT " + (state.shift || 0) + "/" + (state.shifts || 0) +
        " · BOARD A " + (board.demandA || 0) + " · B " + (board.demandB || 0) +
        " · NEXT A " + (board.nextA || 0) + " · B " + (board.nextB || 0) +
        " · POOL " + (state.payroll || 0) + "%" +
        " · PROFIT " + money(ledger.profitTotal);
    if (element.textContent !== text) element.textContent = text;
  }

  function updateScorebug(container, state, nameMap) {
    if (!container || !state || !state.seats) return;
    var html = "";
    state.seats.forEach(function (seat, index) {
      var plateName = nameMap ? nameMap.seat(index) : seat.name;
      var isManager = seat.roleId === 0;
      var ledger = state.ledger || {};
      html += '<div class="plate ' + seatColor(seat) +
        (isManager ? " manager" : "") + '">' +
        '<span class="plate-name">' + escapeHtml(clampName(plateName)) +
        "</span>" +
        (seat.pending && !state.gameDone ?
          '<span class="plate-it">▶</span>' : "") +
        '<span class="plate-score">' +
        escapeHtml(money(isManager ? ledger.profitTotal : seat.net)) +
        "</span>" +
        // plate-role / plate-rating: both are .plate-label for styling, but the
        // scorebug has to be able to shed them independently as the frame
        // narrows, and "the first .plate-label" is not a thing CSS can select.
        '<span class="plate-label plate-role">' +
        escapeHtml(isManager ? "Manager" : "Machine " + ((seat.worker || 0) + 1)) +
        "</span>" +
        (isManager ? "" : '<span class="plate-share">' + (seat.share || 0) +
          "%</span>") +
        (!isManager && seat.idle && state.shiftsPlayed > 0 ?
          '<span class="plate-idle">idle</span>' : "") +
        (!isManager && !seat.obeyed ?
          '<span class="plate-defied">defied</span>' : "") +
        '<span class="plate-label plate-rating">' +
        escapeHtml((seat.score || 0).toFixed(2)) + "</span>" +
        "</div>";
    });
    if (container.dataset.html !== html) {
      container.dataset.html = html;
      container.innerHTML = html;
    }
  }

  function reasonLine(results) {
    switch (results.reason) {
      case "deadline":
        return "episode deadline: scored on " + (results.shifts || 0) +
          " of " + (results.maxShifts || results.shifts || 0) + " shifts";
      default: return "";
    }
  }

  // Final standings overlay: verdict up top, ranked rows below.
  function updateEndscreen(container, results, show, nameMap) {
    if (!container) return;
    container.classList.toggle("show", !!show);
    if (!show || !results || container.dataset.built === "yes") return;
    container.dataset.built = "yes";
    var names = (results.names || []).map(function (name, i) {
      return nameMap ? nameMap.seat(i) : name;
    });
    var scores = results.scores || [];
    var roles = results.roles || [];
    var pay = results.pay || [];
    var units = results.units || [];
    var machineOf = [];
    var nextMachine = 0;
    names.forEach(function (_, i) {
      machineOf[i] = roles[i] === "Manager" ? -1 : nextMachine++;
    });
    var order = names.map(function (_, i) { return i; });
    order.sort(function (a, b) { return (scores[b] || 0) - (scores[a] || 0); });
    var topIndex = order.length ? order[0] : -1;
    var managerIndex = roles.indexOf("Manager");
    var verdict = topIndex < 0 ? "NO SHIFT PLAYED" :
      topIndex === managerIndex ?
        escapeHtml(names[topIndex]) + " RAN A TIGHT SHOP" :
        escapeHtml(names[topIndex]) + " TOOK THE FLOOR";
    var reason = reasonLine(results);
    var html = '<div class="end-panel">' +
      '<div class="end-title">FINAL — ' + (results.shifts || 0) + " SHIFT" +
      ((results.shifts || 0) === 1 ? "" : "S") + " · PROFIT " +
      escapeHtml(money(results.profit)) + "</div>" +
      '<div class="end-verdict">' + verdict + "</div>" +
      (reason ? '<div class="end-reason">' + escapeHtml(reason) + "</div>" :
        "") +
      '<div class="end-rows">' +
      '<span class="end-head"></span><span class="end-head"></span>' +
      '<span class="end-head">role</span>' +
      '<span class="end-head">machine</span>' +
      '<span class="end-head">units</span>' +
      '<span class="end-head">paid / profit</span>' +
      '<span class="end-head">score</span>';
    order.forEach(function (i, rank) {
      var leader = i === topIndex;
      var cell = function (value) {
        return '<span class="end-cell' + (leader ? " end-row-winner" : "") +
          '">' + value + "</span>";
      };
      var isManager = roles[i] === "Manager";
      html += '<span class="end-cell rank' +
        (leader ? " end-row-winner" : "") + '">' + (rank + 1) + "</span>" +
        '<span class="end-cell name ' +
        (isManager ? OFFICE_COLOR : machineColor(machineOf[i])) +
        (leader ? " end-row-winner" : "") + '">' + escapeHtml(names[i]) +
        "</span>" +
        cell(escapeHtml(roles[i] || "")) +
        cell(isManager ? "MACHINE –" : "MACHINE " + (machineOf[i] + 1)) +
        cell(isManager ? "–" : (units[i] || 0)) +
        cell(escapeHtml(money(isManager ? results.profit : pay[i]))) +
        cell(((scores || [])[i] || 0).toFixed(2));
    });
    html += "</div></div>";
    container.innerHTML = html;
  }

  function bindFeedToggle(button, startCollapsed) {
    if (!button) return;
    if (startCollapsed) {
      document.body.classList.add("feed-collapsed");
      requestAnimationFrame(function () {
        window.dispatchEvent(new Event("resize"));
      });
    }
    function refresh() {
      button.textContent =
        document.body.classList.contains("feed-collapsed") ?
          "« LOG" : "LOG »";
    }
    button.onclick = function () {
      document.body.classList.toggle("feed-collapsed");
      refresh();
      window.dispatchEvent(new Event("resize"));
    };
    refresh();
  }

  // ---- Drivers -------------------------------------------------------------

  function stateToView(state, nameMap, effects, extras) {
    var view = effects.view();
    view.seats = applyNames(state.seats, nameMap);
    view.machines = state.machines || [];
    view.managerSeat = state.managerSeat;
    view.board = state.board || {};
    view.ledger = state.ledger || {};
    view.series = state.series || {};
    view.payroll = state.payroll || 0;
    view.split = state.split || [];
    view.directive = state.directive || "";
    view.switchShift = state.switchShift;
    view.switched = (state.board || {}).switched;
    view.shift = state.shift || 0;
    view.shifts = state.shifts || 0;
    view.shiftsPlayed = state.shiftsPlayed || 0;
    view.phase = state.phase || "";
    view.now = Date.now();
    Object.assign(view, extras || {});
    return view;
  }

  // A redacted player frame becomes a five-seat state with the seat's own
  // half filled in so the same scene draws.
  function playerFrameToState(data) {
    if (data.seats) return data;
    var isManager = data.role === "Manager";
    var floor = data.floor || [];
    var seats = [];
    var machines = [];
    for (var i = 0; i < 4; i++) {
      var entry = floor[i] || {};
      machines.push({
        machine: i + 1,
        seat: i + 1,
        name: entry.name || "—",
        setup: entry.setup || "?",
        order: entry.order || "?",
        condition: -1,
        run: -1,
        maint: -1,
        units: entry.units || 0,
        pay: entry.pay || 0,
        share: (data.split || [])[i] || 0,
        obeyed: entry.setup === entry.order,
        idle: false
      });
    }
    if (!isManager && data.own) {
      var own = data.own;
      var index = (data.machine || 1) - 1;
      if (machines[index]) {
        machines[index].condition = own.condition;
        machines[index].run = own.run;
        machines[index].maint = own.maint;
        machines[index].units = own.units;
        machines[index].pay = own.pay;
        machines[index].setup = own.setup;
        machines[index].order = own.order;
        machines[index].name = data.name;
      }
    }
    seats.push({
      name: isManager ? data.name : "The office",
      role: "Manager", roleId: 0, worker: -1, score: 0, pending: !data.done
    });
    for (var m = 0; m < 4; m++) {
      seats.push({
        name: machines[m].name, role: "Worker", roleId: 1, worker: m,
        score: 0, share: machines[m].share, pay: machines[m].pay,
        units: machines[m].units, line: machines[m].setup,
        order: machines[m].order, condition: machines[m].condition,
        run: machines[m].run, maint: machines[m].maint,
        obeyed: machines[m].obeyed, idle: false, pending: !data.done
      });
    }
    return {
      seats: seats, machines: machines, managerSeat: 0,
      board: data.board || {}, ledger: data.ledger || {},
      series: {}, payroll: data.payroll || 0, split: data.split || [],
      directive: data.directive || "", shift: data.shift,
      shifts: data.shifts, shiftsPlayed: data.shiftsPlayed,
      phase: data.done ? "done" : "shift", gameDone: data.done,
      reason: data.reason, events: []
    };
  }

  function attachLive(options) {
    // options: {canvas, feed, status, clock, scorebug, demandbar, endscreen,
    //           assetBase, wsPath, onFrame}
    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var latest = null;
      var nameMap = makeNameMap([], null);
      var effects = makeEffects();
      var scheme = location.protocol === "https:" ? "wss://" : "ws://";
      var url = scheme + location.host + options.wsPath;

      function setStatus(text, live) {
        if (!options.status) return;
        options.status.textContent = text;
        options.status.classList.toggle("live", !!live);
      }

      function connect() {
        var socket = new WebSocket(url);
        socket.onmessage = function (frame) {
          var data = JSON.parse(frame.data);
          if (data.type === "state" || data.type === "final") {
            if (data.type === "state") latest = playerFrameToState(data);
            if (latest) {
              nameMap = makeNameMap(seatNames(latest), latest.policyNames);
              effects.absorb(latest.events || []);
              if (options.feed) {
                renderFeed(options.feed, latest.events || [], nameMap,
                  undefined);
              }
              if (options.clock) {
                options.clock.textContent = matchHeader(latest, latest);
              }
              updateDemandBar(options.demandbar, latest);
              updateScorebug(options.scorebug, latest, nameMap);
            }
            if (data.type === "final") {
              updateEndscreen(options.endscreen, data, true, nameMap);
            }
            if (latest && (latest.done || latest.gameDone)) {
              setStatus("final", false);
            }
          }
          if (options.onFrame) options.onFrame(data);
        };
        socket.onclose = function () {
          setStatus("disconnected", false);
          setTimeout(connect, 2000);
        };
        socket.onopen = function () {
          setStatus("live", true);
        };
      }
      connect();

      function seatNames(data) {
        return (data.seats || []).map(function (s) { return s.name; });
      }

      (function frame() {
        if (latest) {
          var view = stateToView(latest, nameMap, effects, {
            done: !!(latest.done || latest.gameDone)
          });
          renderer.draw(view);
        }
        requestAnimationFrame(frame);
      })();
    });
  }

  // Scrubber: a click/drag-to-seek track with one span per shift and a
  // LABELLED, CLICKABLE button per beat — memo, work, settle and end each
  // get their own marker kind, and each seeks to its own event.
  function markBeat(container, index, total, kind, team, label, onSeek) {
    var marker = document.createElement("button");
    marker.type = "button";
    marker.className = "beat-marker " + kind +
      (typeof team === "number" ? " seat" + (team % 4) : "");
    marker.style.left = ((index + 1) / total * 100) + "%";
    marker.title = label;
    marker.setAttribute("aria-label", label);
    marker.onclick = function (evt) {
      evt.stopPropagation();
      onSeek(index + 1);
    };
    container.appendChild(marker);
    return marker;
  }

  function beatLabel(event, nameMap) {
    switch (event.kind) {
      case "memo":
        return "Shift " + event.shift + " — the manager's memo";
      case "work":
        return "Shift " + event.shift + " — " +
          clampName(nameMap.seat(event.seat)) + " works line " + event.line;
      case "settle":
        return "Shift " + event.shift + " settles — profit " +
          money(event.profit);
      case "end":
        return "Final";
      default:
        return event.kind;
    }
  }

  function buildScrub(container, events, nameMap, onSeek) {
    container.innerHTML = "";
    var track = document.createElement("div");
    track.className = "scrub-track";
    container.appendChild(track);
    var fill = document.createElement("div");
    fill.className = "scrub-fill";
    container.appendChild(fill);
    var blockStarts = [];
    var lastBlock = null;
    events.forEach(function (event, i) {
      var block = event.kind === "start" ? -1 :
        event.kind === "end" ? lastBlock : event.shift;
      if (block !== lastBlock) {
        blockStarts.push(i);
        lastBlock = block;
      }
    });
    blockStarts.forEach(function (startIdx, r) {
      var endIdx = r + 1 < blockStarts.length ?
        blockStarts[r + 1] : events.length;
      var span = document.createElement("div");
      span.className = "round-span" + (r % 2 ? " alt" : "");
      span.style.left = (startIdx / events.length * 100) + "%";
      span.style.width = ((endIdx - startIdx) / events.length * 100) + "%";
      container.appendChild(span);
      if (r > 0 && r % 4 === 0) {
        var sep = document.createElement("div");
        sep.className = "round-sep";
        sep.style.left = (startIdx / events.length * 100) + "%";
        container.appendChild(sep);
      }
    });
    events.forEach(function (event, i) {
      var kind = event.kind;
      if (kind !== "memo" && kind !== "work" && kind !== "settle" &&
          kind !== "end") {
        return;
      }
      markBeat(container, i, events.length, kind,
        kind === "work" ? event.worker : null,
        beatLabel(event, nameMap), onSeek);
    });
    var head = document.createElement("div");
    head.className = "scrub-head";
    container.appendChild(head);

    function seekFromEvent(evt) {
      var rect = container.getBoundingClientRect();
      if (!rect.width) return;   // hidden/unlaid-out page: nothing to seek
      var x = (evt.touches ? evt.touches[0].clientX : evt.clientX) -
        rect.left;
      var fraction = Math.max(0, Math.min(x / rect.width, 1));
      onSeek(Math.round(fraction * events.length));
    }
    var dragging = false;
    container.addEventListener("pointerdown", function (evt) {
      dragging = true;
      try { container.setPointerCapture(evt.pointerId); } catch (ignore) {}
      seekFromEvent(evt);
    });
    container.addEventListener("pointermove", function (evt) {
      if (dragging) seekFromEvent(evt);
    });
    container.addEventListener("pointerup", function () {
      dragging = false;
    });

    return {
      update: function (index) {
        var pct = events.length ? (index / events.length * 100) : 0;
        fill.style.width = pct + "%";
        head.style.left = pct + "%";
      }
    };
  }

  function attachReplay(options) {
    // options: {canvas, feed, scrub, playButton, label, clock, scorebug,
    //           demandbar, endscreen, assetBase, payload}
    var payload = options.payload;
    var events = payload.events || [];
    var states = payload.states || [];
    var config = payload.config || {};
    var nameMap = makeNameMap(payload.names, payload.policyNames);
    var index = 0;
    var playing = true;
    var lastStep = 0;

    makeRenderer(options.canvas, options.assetBase, function (renderer) {
      var effects = makeEffects();
      var scrub = buildScrub(options.scrub, events, nameMap, function (next) {
        playing = false;
        setIndex(next, true);
      });
      if (options.playButton) {
        options.playButton.onclick = function () {
          playing = !playing;
          if (playing && index >= events.length) setIndex(0, true);
        };
      }

      function currentState() {
        return states[Math.min(index, states.length - 1)] ||
          { seats: [], phase: "", shift: 0 };
      }

      function setIndex(next, jumped) {
        index = Math.max(0, Math.min(next, events.length));
        scrub.update(index);
        if (jumped) {
          effects.reset();
        }
        effects.absorb(events.slice(0, index), jumped);
        if (options.feed) renderFeed(options.feed, events, nameMap, index);
        if (options.label) {
          options.label.textContent = index + " / " + events.length;
        }
        if (options.clock) {
          options.clock.textContent = matchHeader(currentState(), config);
        }
        updateDemandBar(options.demandbar, currentState());
        updateScorebug(options.scorebug, currentState(), nameMap);
        // Every seek re-evaluates the endcard, so scrubbing below the last
        // event always dismisses it.
        updateEndscreen(options.endscreen, payload.results,
          index >= events.length && events.length > 0, nameMap);
      }
      setIndex(0, true);

      (function frame(timestamp) {
        // Dwell on what the viewer is currently looking at: a settlement
        // gets read, a memo a little longer than a worker's hours.
        var shown = index > 0 ? events[index - 1] : null;
        var stepMs = shown && shown.kind === "settle" ? 1700 :
          shown && shown.kind === "memo" ? 1400 :
          shown && shown.kind === "work" ? (shown.say ? 900 : 550) :
          shown && shown.kind === "shift" ? 1100 :
          shown && shown.kind === "end" ? 1500 :
          600;
        if (playing && index < events.length &&
            timestamp - lastStep > stepMs) {
          lastStep = timestamp;
          setIndex(index + 1, false);
        }
        if (options.playButton) {
          var running = playing && index < events.length;
          options.playButton.textContent = running ? "❚❚" : "▶";
          options.playButton.classList.toggle("on", running);
        }
        var view = stateToView(currentState(), nameMap, effects, {
          done: index >= events.length && events.length > 0
        });
        renderer.draw(view);
        requestAnimationFrame(frame);
      })(0);

      document.documentElement.setAttribute("data-replay-loaded", "true");
    });
  }

  window.FirmRenderer = {
    attachLive: attachLive,
    attachReplay: attachReplay,
    renderFeed: renderFeed,
    bindFeedToggle: bindFeedToggle
  };
})();
