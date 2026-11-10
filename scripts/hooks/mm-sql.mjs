#!/usr/bin/env node
// mm-sql.mjs — pengganti `sqlite3` CLI untuk git hooks megamemory.
//
// Kenapa ada: image devcontainer tidak punya binary `sqlite3`, jadi pre-push/post-merge
// selalu `exit 0` di guard `command -v sqlite3`. Akibatnya WAL tidak pernah di-checkpoint
// sebelum `knowledge.db` di-commit, sementara `*.db-wal` di-gitignore → db masuk git
// dalam kondisi tidak konsisten lalu korup. Node >=22 sudah punya `node:sqlite`, jadi pakai itu.
//
// ponytail: SEMUA cek (query/integrity/repair) buka db READ-ONLY. Buka writable pada state
// tidak sehat = SQLite menerapkan WAL basi lalu truncate db (insiden 2026-10-19: knowledge.db
// tinggal 155 halaman + perintahnya sendiri yang merusak). Hanya `checkpoint` writable, dan
// hook memanggilnya setelah status ok.
//
// Fail-safe by design: error apa pun → print "0"/"bad" + exit 0 (hook tidak pernah blokir commit
// karena masalah megamemory).Nomor 0 = "tidak ada konflik".
//
// Usage:
//   node mm-sql.mjs checkpoint <db>
//   node mm-sql.mjs query      <db> <sql>
//   node mm-sql.mjs integrity  <db>   → "ok" | "bad"
//   node mm-sql.mjs repair     <db>   → "ok" | "healed" | "bad" | "missing" (alias doctor)
//   node mm-sql.mjs doctor     <db>   → repair + probe tulis di SALINAN db (deteksi "quick_check
//                                       ok tapi penulis gagal", mis. server megamemory yang mati
//                                       dengan "Timeline logging failed: database disk image is
//                                       malformed" padahal cek read-only bilang ok)
//   node mm-sql.mjs selftest          → "ok" | "bad"

import { createHash } from 'node:crypto';
import { copyFileSync, existsSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, truncateSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { basename, join } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

const [cmd, dbPath, sql] = process.argv.slice(2);

const out = (s) => process.stdout.write(s);

// quick_check read-only: mendeteksi db tidak sehat TANPA memicu recovery yang menulis.
// ponytail: koneksi WAJIB ditutup walau quick_check melempar error — koneksi sisa masih memegang
// inode -shm lama, dan sesudah sidecar disidangkan buka berikutnya gagal "disk I/O error"
// (ketemu saat simulasi insiden 2026-10-19: repair balas "bad" padahal db sudah pulih).
const healthy = (path) => {
  // existsSync dulu: DatabaseSync membuat file kosong baru bila path tak ada (false positive 'ok').
  if (!existsSync(path)) return false;
  let db;
  try {
    db = new DatabaseSync(path, { readOnly: true });
    return db.prepare('PRAGMA quick_check').get()?.quick_check === 'ok';
  } catch {
    return false;
  } finally {
    try {
      db?.close();
    } catch {
      /* sudah tertutup / gagal dibuka */
    }
  }
};

// WAL/SHM basi dari generasi db sebelumnya (mis. knowledge.db ditimpa pull/checkout) → disidangkan
// ke `<db>-wal.stale-<ts>`, bukan dihapus, supaya isinya masih bisa diperiksa manual.
// Ceiling: WAL yang sebenarnya masih valid tapi tak terbaca read-only (mis. shm-nya hilang) ikut
// terkarantina — konsep uncommitted di dalamnya bisa hilang, tapi file .stale masih ada.
const quarantine = (path, exts = ['-wal', '-shm']) => {
  const stamp = `.stale-${Date.now()}`;
  let moved = 0;
  for (const ext of exts) {
    if (existsSync(path + ext)) {
      renameSync(path + ext, path + ext + stamp);
      moved++;
    }
  }
  return moved;
};

// probe tulis di SALINAN db (db asli tidak pernah dibuka writable): true = penulis normal,
// false = penulis gagal ("malformed"), null = tidak bisa disalin (izin/disk) → tidak bisa dipastikan.
// ponytail: menyalin db yang sedang ditulis proses lain bisa menghasilkan salinan robek, jadi
// doctor memanggil probe dua kali sebelum menyidangkan apa pun (lihat doctor).
const probeWrite = (path) => {
  let dir;
  try {
    dir = mkdtempSync(join(tmpdir(), 'mm-doctor-'));
    for (const ext of ['', '-wal', '-shm']) {
      if (existsSync(path + ext)) copyFileSync(path + ext, join(dir, basename(path) + ext));
    }
  } catch {
    if (dir) rmSync(dir, { recursive: true, force: true });
    return null;
  }
  try {
    const db = new DatabaseSync(join(dir, basename(path)));
    try {
      db.exec('CREATE TABLE _mm_probe(x); INSERT INTO _mm_probe VALUES (1); DROP TABLE _mm_probe;');
    } finally {
      db.close();
    }
    return true;
  } catch {
    return false;
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

// doctor: repair + probe tulis. Cek read-only bisa bilang "ok" padahal penulis gagal (insiden
// 2026-10-19 lanjutan: server megamemory mati dengan "Timeline logging failed: database disk image
// is malformed"). Di kasus itu -shm (indeks WAL) disidangkan dulu SENDIRIAN — isi -wal tetap utuh
// dan penulis berikutnya membangun ulang indeksnya; -wal hanya disidangkan kalau cek read-only
// sendiri sudah gagal. Ceiling: db yang sehat tapi ditulis proses lain bisa menghasilkan salinan
// robek → itu sebabnya probe diulang sekali sebelum ada yang disidangkan.
const doctor = (path) => {
  if (!existsSync(path)) return 'missing';
  if (healthy(path)) {
    if (probeWrite(path) === false && probeWrite(path) === false) {
      return quarantine(path, ['-shm']) > 0 && probeWrite(path) !== false ? 'healed' : 'bad';
    }
    return 'ok'; // sehat (WAL sehat tidak pernah disentuh)
  }
  if (!existsSync(path + '-wal')) return 'bad'; // korup asli, bukan WAL basi → restore dari git
  return quarantine(path) > 0 && healthy(path) ? 'healed' : 'bad';
};

const repair = doctor; // alias — hook lama (pre-push/post-merge) otomatis ikut dapat probe tulis

const sha = (path) => createHash('sha256').update(readFileSync(path)).digest('hex');
const assert = (cond, msg) => {
  if (!cond) throw new Error(msg);
};

// Satu self-check yang gagal kalau logika read-only / sidang WAL berubah.
// ponytail: fixture dibuat on-the-fly (bukan disimpan di repo), jalan <2s, tanpa framework.
const selftest = () => {
  const dir = mkdtempSync(join(tmpdir(), 'mm-sql-'));
  try {
    // case 1: db sehat + WAL panas (koneksi dibiarkan terbuka) → tidak ada yang boleh disentuh
    const okDb = join(dir, 'ok.db');
    const keep = new DatabaseSync(okDb);
    keep.exec('PRAGMA journal_mode=WAL; CREATE TABLE nodes(id TEXT);');
    for (let i = 0; i < 500; i++) keep.prepare('INSERT INTO nodes VALUES (?)').run(`n${i}`);
    assert(healthy(okDb), 'db sehat harus lolos quick_check');
    const sidecars = readdirSync(dir).filter((f) => f.startsWith('ok.db-')).sort();
    assert(repair(okDb) === 'ok', 'repair pada db sehat harus "ok"');
    assert(
      JSON.stringify(readdirSync(dir).filter((f) => f.startsWith('ok.db-')).sort()) === JSON.stringify(sidecars),
      'db sehat tidak boleh disentuh repair'
    );
    assert(doctor(okDb) === 'ok', 'doctor pada db sehat + WAL panas harus "ok" (probe tulis tidak boleh salah vonis)');
    assert(
      JSON.stringify(readdirSync(dir).filter((f) => f.startsWith('ok.db-')).sort()) === JSON.stringify(sidecars),
      'doctor pada db sehat tidak boleh menyentuh sidecar'
    );
    keep.close();

    // case 2: db korup + WAL basi → integrity "bad" tanpa mengubah byte db, repair menyidangkan WAL
    const badDb = join(dir, 'bad.db');
    const b = new DatabaseSync(badDb);
    b.exec("CREATE TABLE nodes(id TEXT); INSERT INTO nodes VALUES ('x');");
    b.close();
    truncateSync(badDb, Math.floor(readFileSync(badDb).length / 2));
    writeFileSync(badDb + '-wal', 'wal-basi-bukan-generasi-db-ini');
    assert(!healthy(badDb), 'db korup harus terbaca "bad"');
    assert(probeWrite(badDb) === false, 'probe tulis harus mendeteksi db korup');
    const digest = sha(badDb);
    assert(repair(badDb) === 'bad', 'db korup asli (bukan WAL basi) tetap "bad"');
    assert(sha(badDb) === digest, 'cek/repair tidak boleh mengubah byte db');
    assert(readdirSync(dir).some((f) => f.startsWith('bad.db-wal.stale-')), 'WAL basi harus disidangkan');
    assert(doctor(badDb) === 'bad', 'doctor pada db korup (tanpa -wal lagi) tetap "bad"');

    // case 3: WAL generasi lama (subset halaman gen1) menempel di db generasi baru → "bad",
    // quarantine harus memulihkannya jadi "healed" — persis insiden 2026-10-19.
    const staleDb = join(dir, 'stale.db');
    const s = new DatabaseSync(staleDb);
    s.exec('PRAGMA journal_mode=WAL; CREATE TABLE nodes(id TEXT, body TEXT);');
    for (let i = 0; i < 1500; i++) s.prepare('INSERT INTO nodes VALUES (?,?)').run(`n${i}`, 'x'.repeat(200));
    s.exec('PRAGMA wal_checkpoint(TRUNCATE);');
    for (let i = 0; i < 5; i++) s.prepare('INSERT INTO nodes VALUES (?,?)').run(`dirty${i}`, 'z');
    const oldWal = readFileSync(staleDb + '-wal');
    for (let i = 1500; i < 2200; i++) s.prepare('INSERT INTO nodes VALUES (?,?)').run(`n${i}`, 'y'.repeat(200));
    s.exec('PRAGMA wal_checkpoint(TRUNCATE);');
    s.close();
    writeFileSync(staleDb + '-wal', oldWal);
    const digest3 = sha(staleDb);
    assert(!healthy(staleDb), 'WAL generasi lama harus terbaca tidak sehat');
    assert(doctor(staleDb) === 'healed', 'sidang WAL basi harus memulihkan db ("healed")');
    assert(healthy(staleDb), 'db harus sehat sesudah sidang');
    assert(sha(staleDb) === digest3, 'sidang WAL tidak boleh mengubah byte db (sidecar dipindah, bukan ditulis ulang)');
    // ponytail: cabang "read-only ok tapi penulis gagal" (sidang -shm saja) belum punya fixture —
    // read-only selalu ikut membaca isi -wal, jadi sulit dibuat tanpa memalsukan driver.

    return 'ok';
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
};

try {
  if (cmd === 'checkpoint') {
    new DatabaseSync(dbPath).prepare('PRAGMA wal_checkpoint(TRUNCATE)').get();
    out('0');
  } else if (cmd === 'query') {
    const db = new DatabaseSync(dbPath, { readOnly: true });
    const row = db.prepare(sql).get();
    db.close();
    out(String(Object.values(row ?? { v: 0 })[0] ?? 0));
  } else if (cmd === 'integrity') {
    // ponytail: quick_check (~ms, db kecil) — hook skip auto-commit db korup, push tetap lanjut.
    out(healthy(dbPath) ? 'ok' : 'bad');
  } else if (cmd === 'repair' || cmd === 'doctor') {
    out(doctor(dbPath));
  } else if (cmd === 'selftest') {
    out(selftest());
  } else {
    out('0');
  }
} catch {
  out(cmd === 'integrity' || cmd === 'repair' || cmd === 'doctor' || cmd === 'selftest' ? 'bad' : '0');
}
