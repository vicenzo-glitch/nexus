// Nexus feed server — tanpa dependensi, cukup Node 18+
//
// Jalankan:
//   NEXUS_SCAN_KEY=rahasia-scanner NEXUS_READ_KEY=rahasia-finder node nexus-server.js
//
// Endpoint:
//   POST /ingest  (header x-nexus-key = SCAN_KEY)  -> dipanggil Nexus Scanner
//   GET  /feed    (header x-nexus-key = READ_KEY)  -> dipanggil Nexus Finder
//   GET  /health                                   -> cek server hidup

const http = require("http");
const crypto = require("crypto");

const PORT = Number(process.env.PORT) || 3000;
const SCAN_KEY = process.env.NEXUS_SCAN_KEY || "";
const READ_KEY = process.env.NEXUS_READ_KEY || "";
const TTL_MS = (Number(process.env.NEXUS_TTL_SEC) || 480) * 1000; // egg hilang dari feed kalau tidak discan ulang
const MAX_BODY = 128 * 1024;
const MAX_EGGS_PER_INGEST = 60;
const MAX_ITEMS = 5000;

if (!SCAN_KEY || !READ_KEY) {
  console.error("Set dulu NEXUS_SCAN_KEY dan NEXUS_READ_KEY (isi bebas, bikin yang panjang & acak).");
  process.exit(1);
}

// id egg -> entry. Satu server (jobId) selalu diganti utuh tiap scan,
// jadi egg yang sudah dicuri / hilang ikut hilang dari feed.
const items = new Map();
const byJob = new Map(); // jobId -> Set<id>

function safeEqual(a, b) {
  const ba = Buffer.from(String(a || ""));
  const bb = Buffer.from(String(b || ""));
  if (ba.length !== bb.length) return false;
  return crypto.timingSafeEqual(ba, bb);
}

function str(v, max) {
  return String(v == null ? "" : v).slice(0, max);
}

function num(v, fallback) {
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

function dropJob(jobId) {
  const ids = byJob.get(jobId);
  if (!ids) return new Map();
  const old = new Map();
  for (const id of ids) {
    const it = items.get(id);
    if (it) old.set(id, it);
    items.delete(id);
  }
  byJob.delete(jobId);
  return old;
}

function ingest(body) {
  const jobId = str(body.jobId, 80);
  const placeId = Math.floor(num(body.placeId, 0));
  if (!jobId || !placeId) return { ok: false, error: "jobId/placeId kosong" };

  const players = Math.max(0, Math.floor(num(body.players, 0)));
  const maxPlayers = Math.max(0, Math.floor(num(body.maxPlayers, 0)));
  const eggs = Array.isArray(body.eggs) ? body.eggs.slice(0, MAX_EGGS_PER_INGEST) : [];

  const now = Date.now();
  const old = dropJob(jobId);
  const ids = new Set();

  for (const e of eggs) {
    if (!e || typeof e !== "object") continue;
    const uid = str(e.uid, 80);
    const value = num(e.value, 0);
    if (!uid || value <= 0) continue;

    const id = jobId + ":" + uid;
    const prev = old.get(id);
    items.set(id, {
      id,
      name: str(e.name, 60) || "Unknown",
      value,
      size: num(e.size, 0),
      weight: num(e.weight, 0),
      rarity: Math.floor(num(e.rarity, 0)),
      rarityName: str(e.rarityName, 40),
      mutation: str(e.mutation, 120),
      area: str(e.area, 40),
      image: str(e.image, 200),
      placeId,
      jobId,
      players,
      maxPlayers,
      firstSeen: prev ? prev.firstSeen : now, // "x detik lalu" dihitung dari pertama kali egg terlihat
      lastSeen: now,
    });
    ids.add(id);
  }

  if (ids.size > 0) byJob.set(jobId, ids);

  // batas memori kasar: buang yang paling lama tidak terlihat
  if (items.size > MAX_ITEMS) {
    const sorted = [...items.values()].sort((a, b) => a.lastSeen - b.lastSeen);
    for (const it of sorted.slice(0, items.size - MAX_ITEMS)) {
      items.delete(it.id);
      const set = byJob.get(it.jobId);
      if (set) set.delete(it.id);
    }
  }
  return { ok: true, stored: ids.size };
}

function prune() {
  const cutoff = Date.now() - TTL_MS;
  for (const [id, it] of items) {
    if (it.lastSeen < cutoff) {
      items.delete(id);
      const set = byJob.get(it.jobId);
      if (set) {
        set.delete(id);
        if (set.size === 0) byJob.delete(it.jobId);
      }
    }
  }
}
setInterval(prune, 15 * 1000).unref();

function feed(query) {
  prune();
  const min = num(query.get("min"), 0);
  const limit = Math.min(50, Math.max(1, Math.floor(num(query.get("limit"), 10))));
  const placeId = Math.floor(num(query.get("placeId"), 0));
  const now = Date.now();

  const list = [...items.values()]
    .filter((it) => it.value >= min)
    .filter((it) => !placeId || it.placeId === placeId)
    .filter((it) => !(it.maxPlayers > 0 && it.players >= it.maxPlayers)) // server penuh tidak bisa di-join
    .sort((a, b) => b.firstSeen - a.firstSeen)
    .slice(0, limit)
    .map((it) => ({
      id: it.id,
      name: it.name,
      value: it.value,
      size: it.size,
      weight: it.weight,
      rarity: it.rarity,
      rarityName: it.rarityName,
      mutation: it.mutation,
      area: it.area,
      image: it.image,
      placeId: it.placeId,
      jobId: it.jobId,
      players: it.players,
      maxPlayers: it.maxPlayers,
      ageSec: Math.max(0, Math.floor((now - it.firstSeen) / 1000)),
    }));

  return { ok: true, count: list.length, items: list };
}

function send(res, code, obj) {
  const data = JSON.stringify(obj);
  res.writeHead(code, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(data),
  });
  res.end(data);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://x");
  const key = req.headers["x-nexus-key"];

  if (req.method === "GET" && url.pathname === "/health") {
    return send(res, 200, { ok: true, items: items.size });
  }

  if (req.method === "GET" && url.pathname === "/feed") {
    if (!safeEqual(key, READ_KEY)) return send(res, 401, { ok: false, error: "key salah" });
    return send(res, 200, feed(url.searchParams));
  }

  if (req.method === "POST" && url.pathname === "/ingest") {
    if (!safeEqual(key, SCAN_KEY)) return send(res, 401, { ok: false, error: "key salah" });

    let size = 0;
    const chunks = [];
    req.on("data", (c) => {
      size += c.length;
      if (size > MAX_BODY) {
        send(res, 413, { ok: false, error: "body terlalu besar" });
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => {
      if (res.writableEnded) return;
      let body;
      try {
        body = JSON.parse(Buffer.concat(chunks).toString("utf8"));
      } catch {
        return send(res, 400, { ok: false, error: "JSON tidak valid" });
      }
      const out = ingest(body || {});
      send(res, out.ok ? 200 : 400, out);
    });
    return;
  }

  send(res, 404, { ok: false, error: "not found" });
});

server.listen(PORT, () => console.log("Nexus server jalan di port " + PORT));
