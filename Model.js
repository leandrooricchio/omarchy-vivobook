.pragma library

// Pure helpers for the Vivobook Control panel. No QML types here so the
// cursor model and status parsing stay unit-testable.

function parseStatus(text) {
  try {
    var st = JSON.parse(text || "{}") || {}
    return st && typeof st === "object" ? st : {}
  } catch (e) {
    return {}
  }
}

function get(obj, path, fallback) {
  var cur = obj
  var parts = path.split(".")
  for (var i = 0; i < parts.length; i++) {
    if (cur === null || cur === undefined || typeof cur !== "object") return fallback
    cur = cur[parts[i]]
  }
  return cur === undefined || cur === null ? fallback : cur
}

function profileGlyph(profile) {
  switch (String(profile || "")) {
    case "quiet": return "󰾆"
    case "performance": return "󰓅"
    default: return "󰾅"
  }
}

function profileLabel(profile) {
  var s = String(profile || "")
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : "—"
}

function rgbModeGlyph(mode) {
  switch (String(mode || "")) {
    case "breathing": return "󰛨"
    case "rainbow": return "󰏘"
    case "auto": return "󰁪"
    case "off": return "󰛩"
    default: return "󰝤"
  }
}

function tempText(c) {
  return (c === null || c === undefined) ? "—" : Math.round(c) + "°C"
}

// Fan is a sensor only on this model (no curve / PWM exposed); mention it
// only while it is actually spinning so it does not read like a control.
function fanText(fans) {
  if (!fans || !fans.length) return ""
  var rpm = 0
  for (var i = 0; i < fans.length; i++) rpm = Math.max(rpm, fans[i].rpm || 0)
  return rpm > 0 ? " · FAN " + rpm + " rpm" : ""
}

function batteryText(charge) {
  if (!charge || charge.percent === null || charge.percent === undefined) return "—"
  var status = String(charge.status || "")
  return charge.percent + "%" + (status ? " · " + status.toLowerCase() : "")
}

// Rows the cursor can land on. Each section is a vertical list of rows; a row
// of kind "group" is walked horizontally with h/l, "slider" adjusts with h/l,
// "toggle" flips on Enter, "dropdown" opens on Enter and cycles with h/l.
function sections(st) {
  var caps = get(st, "caps", {})
  var out = []
  if (caps.kbd) out.push({ id: "kbd", rows: [{ kind: "slider" }] })
  if (caps.rgbDevice) {
    out.push({ id: "swatches", rows: [{ kind: "group", count: get(st, "rgb.presets", []).length }] })
    out.push({ id: "effect", rows: [{ kind: "group", count: get(st, "rgb.modes", []).length }] })
  }
  if (caps.profile) out.push({ id: "profile", rows: [{ kind: "group", count: get(st, "profile.choices", []).length }] })
  if (caps.chargeDevice) out.push({ id: "charge", rows: [{ kind: "group", count: get(st, "charge.limits", []).length }] })
  out.push({ id: "copilot", rows: [{ kind: "dropdown" }] })
  out.push({ id: "gestures", rows: [
    { kind: "toggle", key: "workspace3" },
    { kind: "toggle", key: "move4" },
    { kind: "toggle", key: "pinchFloat" },
    { kind: "group", key: "up3", count: get(st, "gestures.actions", []).length },
    { kind: "group", key: "down3", count: get(st, "gestures.actions", []).length }
  ] })
  out.push({ id: "edge", rows: [{ kind: "toggle", key: "enabled" }] })
  if (!caps.setupDone) out.push({ id: "setup", rows: [{ kind: "button" }] })
  return out
}

function sectionById(list, id) {
  for (var i = 0; i < list.length; i++) if (list[i].id === id) return list[i]
  return null
}

// Move vertically by delta rows across sections. Returns { section, row, col }.
function moveCursor(list, section, row, col, delta) {
  if (!list.length) return { section: "", row: 0, col: 0 }
  var sIdx = -1
  for (var i = 0; i < list.length; i++) if (list[i].id === section) sIdx = i
  if (sIdx < 0) return { section: list[0].id, row: 0, col: 0 }
  var rows = list[sIdx].rows.length
  var next = row + delta
  if (next >= 0 && next < rows) return { section: section, row: next, col: 0 }
  var nIdx = sIdx + (delta > 0 ? 1 : -1)
  if (nIdx < 0 || nIdx >= list.length) return { section: section, row: row, col: col }
  var target = list[nIdx]
  return { section: target.id, row: delta > 0 ? 0 : target.rows.length - 1, col: 0 }
}

function clampCol(rowSpec, col) {
  if (!rowSpec || rowSpec.kind !== "group") return 0
  var max = Math.max(0, (rowSpec.count || 1) - 1)
  return Math.max(0, Math.min(max, col))
}

function indexOf(list, value) {
  if (!list) return -1
  for (var i = 0; i < list.length; i++) if (String(list[i]) === String(value)) return i
  return -1
}

function cycle(list, value, delta) {
  if (!list || !list.length) return value
  var idx = indexOf(list, value)
  idx = idx < 0 ? 0 : (idx + delta + list.length) % list.length
  return list[idx]
}

function actionLabel(action) {
  switch (String(action || "")) {
    case "fullscreen": return "Full"
    case "maximized": return "Max"
    case "close": return "Close"
    default: return "Off"
  }
}
