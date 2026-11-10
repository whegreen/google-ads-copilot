---
description: Fase develop (step 5-7) — eksekusi saved plan hasil /develop-plan
---

Target: $ARGUMENTS. Load skill `backlog-workflow` mode DEVELOPMENT, HANYA Step 5-7, + ladder `ponytail`. Tampilkan checklist ini di awal dan update statusnya tiap step selesai.

**PREFLIGHT (gate, sebelum Step 5)** — cari di `.opencode/plans/` file yang frontmatter `target`-nya cocok dengan target ini (bukan match nama file):
- Tidak ADA, atau `status` bukan `planning-done` → STOP. Minta user jalankan `/develop-plan "<target>"` dulu; jangan menulis kode.
- ADA tapi bagian `Scope Terkunci` / `Test Regresi Terkunci` kosong → STOP, selesaikan perencanaan dulu.
- Lolos → set `status: in-dev` + `updated` di frontmatter plan, baru mulai Step 5.

- [ ] Step 5 (build): implement test pre-requisite sesuai daftar terkunci di plan → harus PASS (jangan asumsi). Eksekusi: `python3 evals/run.py` (intent + decision + parser + apply) → `bash evals/test-shell-regressions.sh` (regresi shell). Jangan full suite tiap iterasi — `python3 evals/run.py` sudah mencakup semua case dalam hitungan detik; filter per-area kalau runner mendukung. Terlarang tanpa izin: ubah source produksi demi test hijau, longgarkan assertion, hapus/`skip` test existing. Exit: test ADA dan PASS, tanpa test di luar daftar.
- [ ] Step 6 (build): implement kode → syntax clean: `python3 -m compileall -q scripts/ evals/` untuk Python, `bash -n <file.sh>` untuk shell. Exit: kode jadi + syntax check clean.
- [ ] Step 7 (build): ponytail review akhir (load skill `ponytail`) atas kode Step 6 + scope terkunci plan → tulis hasil review ke doc (bukan hanya di chat), lalu sederhanakan doc: tambah wireframe sebelum/sesudah kalau relevan, HAPUS bagian duplikat/kadaluarsa, update `CHANGELOG.md`. Exit: hasil review tertulis di doc + doc ramping + changelog updated.

**Close-out**: update `.opencode/plans/<slug>.md` → `status: done`, centang Step 5-7, tautkan commit/PR. Lalu `git rm .opencode/plans/<slug>.session.json` (bila ada) — lampiran sudah tidak perlu: ringkasan final permanen di plan + `.megamemory/knowledge.db`.

Aturan: 1-2 baris laporan per step (step apa, artifact apa). Step tanpa exit artifact = belum selesai, tidak boleh lanjut. Ringkasan akhir maks 3 baris.
