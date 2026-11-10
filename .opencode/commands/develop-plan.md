---
description: Fase perencanaan (step 1-4) — dokumentasi + test regresi terkunci, ditutup saved plan; kode belum disentuh
---

Target: $ARGUMENTS. Jalankan mode DEVELOPMENT dari skill `backlog-workflow` (load via skill tool) + ladder `ponytail`, HANYA Step 1-4 (fase perencanaan/dokumentasi). Tampilkan checklist ini di awal dan update statusnya tiap step selesai:

- [ ] Step 1 (plan): analisis kebutuhan refactor dari dokumentasi → update dokumentasi DAHULU (kode belum disentuh). Exit: doc yang relevan stating apa berubah/kenapa/apa tidak berubah. Doc target repo ini = file markdown top-level: `ARCHITECTURE.md`, `APPLY-LAYER.md`, `OPERATOR-PLAYBOOK.md`, `README.md`, `CHANGELOG.md`; logika skill: `skills/<skill>/SKILL.md`; referensi analitik: `google-ads/references/<topik>-playbook.md`. Bagian doc yang kedaluwarsa/duplikat DIHAPUS saat update, jangan ditumpuk.
- [ ] Step 2 (plan + DECISION GATE): cek dulu exit Step 1 lolos (doc ter-update, kode belum disentuh) — belum → selesaikan Step 1. Lalu ponytail review (load skill `ponytail` via skill tool) → tulis hasil (apa dipangkas + alasan 1 baris) di doc. Jika rencana menyentuh fitur, scenario UI, atau kontrak data (field manifest apply, format draft, query GAQL, file di `evals/`) → STOP, pakai `question` tool minta konfirmasi user. Exit: scope final terkunci di doc (termasuk bagian yang DIHAPUS dari rencana). Lanjut hanya setelah user jawab; jawaban tercatat di doc.
- [ ] Step 3 (plan): analisis pre-requisite test regresi → tulis bagian "Test Regresi" di doc (area terdampak, test existing pelindung, test minimal tambahan). WAJIB baca `evals/` dengan urutan: grep `evals/*.json` (case id + expected) dulu (perilaku sudah tercover? jangan tulis baru) → baca `evals/run.py` (harness eksekusi) → baru pilih layer + budget. Layer: (1) `evals/cases.json` intent classification, (2) `evals/decision_cases.json` keputusan tracking/budget/structure, (3) `evals/apply_cases.json` parsing manifest + guardrail apply, (4) `evals/fixtures/` fixture input, (5) `evals/test-shell-regressions.sh` regresi shell. Perilaku sengaja tidak dites → baris `Sengaja tidak dites` + pemicu `add when`. Exit: bagian ADA di doc.
- [ ] Step 4 (plan + DECISION GATE): cek dulu exit Step 3 lolos (bagian "Test Regresi" ADA di doc) — belum → selesaikan Step 3. Lalu ponytail review test → klasifikasi kandidat coret (redundansi lintas layer, overkill layer, copy implementasi, fixture besar, fragmentasi file) + alasan di doc. Kalau ada kandidat coret yang berarti HAPUS/edit test existing → DECISION GATE WAJIB, STOP via `question` (agent tidak boleh menyentuh file test tanpa persetujuan eksplisit); kalau tidak ada kandidat hapus, gate tidak wajib. Exit: daftar test final terkunci di doc.
- [ ] Close-out (saved plan): tulis `.opencode/plans/<slug>.md` (format di bawah) — file inilah yang dibaca `/develop-code` nanti. Exit: plan ADA, `status: planning-done`, lampiran sesi ADA.

## Saved plan — format wajib

`.opencode/plans/<slug>.md`, slug = kebab-case singkat dari target:

```markdown
---
slug: <slug>
target: <target asli>
status: planning-done
created: <YYYY-MM-DD HH:mm>
updated: <YYYY-MM-DD HH:mm>
planning_session: <sessionID OpenCode>
repo: google-ads-copilot
---

## Scope Terkunci
<hasil Step 2: apa dikerjakan, apa dipangkas + alasan 1 baris, jawaban DECISION GATE>

## Test Regresi Terkunci
<daftar final Step 4: file case/evals, layer, budget, perintah eksekusi; baris "Sengaja tidak dites">
<kandidat hapus/edit test existing + persetujuan user, bila ada>

## Doc yang di-update
- <path doc> — <apa yang berubah>

## Step 5-7 (diisi saat /develop-code)
- [ ] Step 5 implement test pre-requisite
- [ ] Step 6 implement kode
- [ ] Step 7 ponytail review akhir + simplify doc
```

## Lampiran konteks sesi

1. Sesi panjang → kompres dulu: `opencode api post /api/session/<sessionID>/compact -d '{}'` (async; tunggu pesan `compaction` muncul — ini yang menghasilkan `summary` terstruktur: Objective / Requirements / Decisions / Work State).
2. Tulis lampiran: `node scripts/compact-session.mjs <sessionID> --out .opencode/plans/<slug>.session.json` (sessionID dari `opencode session list` atau frontmatter plan).
   - **Jangan** pakai `opencode session export` langsung — export mentah 1–4 MB/sesi, dan `--sanitize` me-redact seluruh blok teks sehingga lampiran tak berguna sebagai konteks. Script yang membuang tool output/reasoning/metadata.
   - Hasil: ~6 KB kalau ada compaction summary · ~50 KB fallback dialog text-only (sesi tanpa compaction).
3. Export gagal/kosong → tulis ringkasan keputusan sesi manual di plan; Close-out tidak boleh selesai tanpa lampiran atau ringkasan.

Lampiran `.session.json` **di-commit** (kecil, & berguna lintas mesin). `/develop-code` menghapusnya di Close-out — ringkasan sudah permanen di plan + `.megamemory/knowledge.db`.

STOP setelah Close-out — jangan menyentuh kode. Lanjut kapan pun dengan `/develop-code "<target>"`.

Aturan: 1-2 baris laporan per step (step apa, artifact apa). Step tanpa exit artifact = belum selesai, tidak boleh lanjut. Ringkasan akhir maks 3 baris.
