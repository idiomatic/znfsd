"use strict";

// Polls the snapshot once a second and fills the tables.

let previous = null;

function cell(text, className) {
  const td = document.createElement("td");
  td.textContent = text;
  if (className) td.className = className;
  return td;
}

function fill(id, rows, columns) {
  const body = document.querySelector(`#${id} tbody`);
  body.replaceChildren();
  if (rows.length === 0) {
    const tr = document.createElement("tr");
    const td = cell("none", "empty");
    td.colSpan = columns.length;
    tr.append(td);
    body.append(tr);
    return;
  }
  for (const row of rows) {
    const tr = document.createElement("tr");
    for (const [get, className] of columns) tr.append(cell(get(row), className?.(row)));
    body.append(tr);
  }
}

const number = (n) => n.toLocaleString();
const time = (ms) => new Date(ms).toLocaleTimeString();

function bytes(n) {
  const units = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < units.length - 1) { n /= 1024; i++; }
  return `${i === 0 ? n : n.toFixed(1)} ${units[i]}`;
}

function duration(ms) {
  const s = Math.floor(ms / 1000);
  const parts = [[Math.floor(s / 86400), "d"], [Math.floor(s / 3600) % 24, "h"], [Math.floor(s / 60) % 60, "m"], [s % 60, "s"]];
  return parts.filter(([v], i) => v > 0 || i === 3).slice(0, 2).map(([v, u]) => `${v}${u}`).join(" ");
}

function ago(now, ms) {
  return `${duration(Math.max(0, now - ms))} ago`;
}

async function refresh() {
  const status = document.getElementById("status");
  try {
    const response = await fetch("/activity.json", { cache: "no-store" });
    if (!response.ok) throw new Error(response.statusText);
    const s = await response.json();
    const a = s.activity;
    document.getElementById("uptime").textContent = duration(a.now_ms - a.started_ms);
    document.getElementById("total").textContent = number(a.total_calls);
    if (previous) {
      const seconds = (a.now_ms - previous.now_ms) / 1000;
      const rate = seconds > 0 ? (a.total_calls - previous.total_calls) / seconds : 0;
      document.getElementById("rate").textContent = rate.toFixed(1);
    }
    previous = a;
    status.textContent = "live";
    status.className = "";

    fill("clients", a.clients, [
      [(c) => c.address],
      [(c) => number(c.calls), () => "n"],
      [(c) => bytes(c.bytes), () => "n"],
      [(c) => ago(a.now_ms, c.last_ms)],
    ]);
    fill("procedures", a.procedures, [
      [(p) => p.program],
      [(p) => p.procedure],
      [(p) => number(p.calls), () => "n"],
      [(p) => number(p.errors), (p) => (p.errors > 0 ? "n bad" : "n")],
      [(p) => number(p.average_us), () => "n"],
      [(p) => bytes(p.bytes), () => "n"],
    ]);
    fill("exports", s.exports, [[(e) => e.path], [(e) => e.client], [(e) => e.options]]);
    fill("mounts", s.mounts, [[(m) => m.host], [(m) => m.path]]);
    fill("locks", s.locks, [[(l) => l.host], [(l) => l.path], [(l) => l.range], [(l) => l.kind]]);
    fill("recent", a.recent.slice(0, 50), [
      [(r) => time(r.time_ms)],
      [(r) => r.client],
      [(r) => r.program],
      [(r) => r.procedure],
      [(r) => r.outcome, (r) => (r.outcome === "success" || r.outcome === "none" ? "" : "bad")],
      [(r) => bytes(r.bytes), () => "n"],
      [(r) => number(r.us), () => "n"],
    ]);
  } catch (error) {
    status.textContent = "disconnected";
    status.className = "bad";
  }
}

refresh();
setInterval(refresh, 1000);
