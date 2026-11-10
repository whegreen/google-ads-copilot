#!/usr/bin/env node
/**
 * compact-session.mjs — ringkas export sesi OpenCode jadi lampiran kecil.
 *
 * Konteks: `/develop-plan` butuh lampiran konteks sesi supaya `/develop-code`
 * bisa lanjut di sesi berikutnya. Export mentah OpenCode = 1–4 MB per sesi
 * (terukur: sesi terbesar di repo ini 4.1 MB) — terlalu besar untuk commit
 * dan tidak worth dibaca agent.
 *
 * Yang dipakai:
 *   1. Compaction summary — field `summary` pada pesan bertipe `compaction`.
 *      OpenCode sendiri yang menulisnya, terstruktur: Objective / Requirements /
 *      Decisions / Work State. Ini yang paling berguna untuk resume.
 *   2. Dialog text-only — fallback saat belum ada compaction. Hanya blok teks
 *      user + assistant, tanpa tool output / reasoning / metadata.
 *
 * Yang dibuang: tool output (71 KB/sesi), reasoning (21 KB/sesi), metadata
 * (`tokens`/`cost`/`model`/`snapshot`/`time`/`id`), dan noise system-reminder.
 *
 * ⚠️ Export TIDAK pakai `--sanitize`: flag itu me-redact SELURUH blok teks
 * (terukur 64 dari 65 blok), sehingga lampiran jadi tidak berguna sebagai
 * konteks. Justru yang di-buang script ini (tool output) yang paling mungkin
 * memuat secret. Scan 5 sesi nyata: text part bersih (JWT / sbp_ / MCP_SECRET /
 * hex-64 / private key = 0 hit).
 *
 * Usage:
 *   node scripts/compact-session.mjs <sessionID> > .opencode/plans/<slug>.session.json
 *   node scripts/compact-session.mjs <sessionID> --out .opencode/plans/<slug>.session.json
 *
 *   ⚠️ Pakai `node` langsung, bukan `npm run compact:session` — npm menulis
 *   header-nya ke stdout dan ikut tercampur ke JSON. (`--out` aman dari mana pun.)
 *
 * Exit 0 = artifact ditulis. Exit 1 = export gagal/kosong (caller fallback
 * ke ringkasan manual di plan).
 *
 * ponytail: tanpa dependensi baru — hanya node builtins. Format export punya
 * 2 bentuk (`{content:[{type:'text'}]}` dan `{text:'...'}`) dan keduanya
 * ditangani; kalau OpenCode ganti format lagi, fallo di `textOf` — bukan
 * diam-diam menghasilkan lampiran kosong.
 */
import { execFileSync } from 'node:child_process';
import { mkdtempSync, openSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

// Noise yang disisipkan OpenCode — bukan bagian dari percakapan.
const NOISE = [
  /^<system-reminder>/,
  /^<environment_details>/,
  /^<local-command-stdout>/,
  /^<local-command-stderr>/,
];

/**
 * Ambil teks manusiawi dari satu pesan.
 * Bentuk A (v2): { content: [{ type: 'text', text }] }
 * Bentuk B (aux) : { text: '...' }
 */
function textOf(msg) {
  const out = [];
  if (typeof msg.text === 'string') out.push(msg.text);
  const content = msg.content;
  if (typeof content === 'string') {
    out.push(content);
  } else if (Array.isArray(content)) {
    for (const part of content) {
      if (part && typeof part === 'object' && part.type === 'text' && typeof part.text === 'string') {
        out.push(part.text);
      }
    }
  }
  return out.join('\n').trim();
}

const isNoise = (text) => NOISE.some((re) => re.test(text));

/**
 * Export sesi ke file temp, bukan pipe.
 *
 * ponytail: `opencode session export` memanggil `process.exit()` sebelum stdout
 * pipe ter-flush → output ke pipe terpotong (terukur 1.9 MB dari 3.9 MB).
 * Redirect ke file (sync write) aman. Karena itu jangan pakai
 * `execFileSync(..., {encoding:'utf8'})` di sini.
 */
function exportSession(sessionID) {
  const dir = mkdtempSync(join(tmpdir(), 'compact-session-'));
  const file = join(dir, 'session.json');
  try {
    execFileSync('opencode', ['session', 'export', sessionID], {
      stdio: ['ignore', openSync(file, 'w'), 'pipe'],
      maxBuffer: 256 * 1024 * 1024,
    });
    return JSON.parse(readFileSync(file, 'utf8'));
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

function compact(data) {
  const messages = data.messages ?? [];

  // 1) Compaction summary — pesan terakhir yang punya summary = paling final.
  const summaries = messages
    .filter((m) => m?.type === 'compaction' && typeof m.summary === 'string' && m.summary.trim())
    .map((m) => ({ reason: m.reason ?? 'auto', summary: m.summary.trim() }));

  // 2) Dialog text-only — fallback / pelengkap.
  const dialogue = [];
  for (const msg of messages) {
    const text = textOf(msg);
    if (!text || isNoise(text)) continue;
    dialogue.push({ role: msg.type ?? 'unknown', text });
  }

  return {
    session: data.info?.id ?? null,
    title: data.info?.title ?? null,
    generated: new Date().toISOString(),
    // Ringkasan terakhir saja — compaction sebelumnya sudah tercakup di dalamnya.
    summary: summaries.length ? summaries[summaries.length - 1].summary : null,
    // Tanpa summary → dialog jadi satu-satunya sumber.
    messages: summaries.length ? [] : dialogue,
  };
}

const args = process.argv.slice(2);
const sessionID = args.find((a) => !a.startsWith('--'));
if (!sessionID) {
  console.error('Usage: node scripts/compact-session.mjs <sessionID> [--out <path>]');
  process.exit(1);
}

const outIndex = args.indexOf('--out');
const outPath = outIndex !== -1 ? args[outIndex + 1] : null;

let data;
try {
  data = exportSession(sessionID);
} catch (err) {
  console.error(`compact-session: export gagal (${err.message}) — fallback: tulis ringkasan manual di plan`);
  process.exit(1);
}

const artifact = compact(data);
const json = `${JSON.stringify(artifact, null, 1)}\n`;

if (!artifact.summary && artifact.messages.length === 0) {
  console.error('compact-session: export kosong — fallback: tulis ringkasan manual di plan');
  process.exit(1);
}

if (outPath) {
  writeFileSync(outPath, json);
  console.error(`compact-session: ditulis ${outPath} (${json.length} bytes)`);
} else {
  process.stdout.write(json);
}
