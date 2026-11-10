---
name: backlog-workflow
description: >
  Menjalankan pekerjaan backlog dengan urutan step-by-step yang tetap dan
  konsisten, dalam dua mode: CREATE (fitur/modul baru) dan DEVELOPMENT
  (refactor/perbaikan existing). Setiap langkah adalah gate — tidak boleh
  dilewati; selesai hanya jika artifact exit criteria ada. Use whenever the
  user says "backlog create", "backlog development", "mengerjakan backlog",
  "buat fitur baru", "buat modul baru", "refactor", "perbaiki fitur", "task
  backlog", "bikin backlog", "jalankan workflow backlog", atau menyebut salah
  satu langkah dari workflow ini.
---

# Backlog Workflow

Dua workflow tetap. Jangan menambah, mengurangi, atau menukar urutan langkah.
Setiap langkah punya **exit criteria** (artifact yang harus ada). Langkah
belum selesai selama artifact belum ada. Tidak boleh lanjut ke langkah
berikutnya sebelum gate sebelumnya lolos.

## Aturan Bersama (berlaku di kedua mode)

- **Doc conventions**: repo ini tidak punya `docs/` tree. Dokumentasi = file
  markdown top-level (`ARCHITECTURE.md`, `APPLY-LAYER.md`, `OPERATOR-PLAYBOOK.md`,
  `README.md`, `CHANGELOG.md`), skill (`skills/<skill>/SKILL.md`), atau referensi
  analitik (`google-ads/references/<topik>-playbook.md`). Dokumen yang diubah
  harus menjelaskan kondisi SETELAH perubahan, bukan menumpuk riwayat.
- **Ponytail review** = gate wajib: jalankan ladder YAGNI dari skill `ponytail`
  (load via skill tool), tulis hasilnya ke dokumentasi yang sedang dikerjakan,
  baru boleh lanjut. Hasil minimal: apa yang dipangkas / apa yang disederhanakan
  dan alasannya satu baris. **Prasyarat**: exit step sebelumnya sudah Tercapai —
  dokumentasi ditulis lebih dulu, baru review; review tanpa artifact doc dari
  step sebelumnya = belum jalan.
- **Definition of Done** di langkah implementasi: syntax check clean —
  `python3 -m compileall -q scripts/ evals/` untuk Python, `bash -n <file.sh>`
  untuk shell — dan test yang tersentuh pass.
- **Test minimal**: non-trivial logic meninggalkan SATU runnable check
  (per skill ponytail). Tidak menambah test tanpa alasan.
- **Panduan testing mengikat**: semua step test wajib mengikuti layer test repo
  ini untuk decides test apa di layer mana; eksekusi selalu
  `python3 evals/run.py` lalu `bash evals/test-shell-regressions.sh`. Layer:
  (1) `evals/cases.json` — intent classification; (2) `evals/decision_cases.json` —
  keputusan tracking/budget/structure; (3) `evals/apply_cases.json` — parsing
  manifest + guardrail apply; (4) `evals/fixtures/` — fixture input nyata;
  (5) `evals/test-shell-regressions.sh` — regresi shell. Area→command:
  logika Python/scripts → `evals/run.py`; regresi retrieval ladder / negative
  inventory → `evals/test-shell-regressions.sh`. Langgar panduan = gate gagal.
- Tentukan mode di awal: CREATE kalau target belum ada, DEVELOPMENT kalau
  target sudah ada.

## Mode CREATE — fitur/modul baru

1. **Step 1 — Update backlog** (exit: entry baru ADA di `CHANGELOG.md` bagian
   `## Unreleased` — atau file tracker baru kalau user minta. Format: entri
   ringkas + checklist item. Buat file analisis/doc placeholder jika belum ada.
2. **Step 2 — Analisis kebutuhan pre-requisite test untuk cek regresi**
   (exit: bagian "Test Regresi" ADA di doc yang relevan; berisi area terdampak,
   test existing yang melindungi area itu, dan test pre-requisite yang harus
   ada sebelum implementasi — bukan setelah; pemilihan layer ikut daftar layer
   di atas).
3. **Step 3 — Ponytail review + implement pre-requisite test**
   (exit: hasil ponytail review ditulis di doc; test pre-requisite ADA dan PASS
   — jalankan `python3 evals/run.py` dan `bash evals/test-shell-regressions.sh`,
   jangan asumsi).
4. **Step 4 — Update dokumentasi + buang redundan** (exit: doc yang relevan
   ter-update, merefleksikan kondisi setelah implementasi, dengan
   wireframe/deskripsi behavior; bagian doc yang kedaluwarsa/duplikat DIHAPUS,
   bukan ditumpuk).

## Mode DEVELOPMENT — refactor/perbaikan existing

1. **Step 1 — Analisis kebutuhan refactor dari dokumentasi → update dokumentasi DAHULU**
   (exit: doc relevan ter-update — kode BELUM boleh disentuh. Dokumen menyatakan
   target refactor: apa yang berubah, kenapa, apa yang tidak berubah; bagian
   doc yang kedaluwarsa/duplikat DIHAPUS saat update, jangan menumpuk).
2. **Step 2 — Ponytail review → update dokumentasi**
   (exit: hasil review tertulis di doc; doc mengunci scope final — termasuk
   bagian yang DIHAPUS dari rencana).
3. **Step 3 — Analisis kebutuhan test untuk cek regresi → update dokumentasi**
   (exit: bagian "Test Regresi" ADA di doc: area terdampak, test existing yang
   melindungi, test minimal yang harus ditambah/ubah — pemilihan layer ikut
   daftar layer di atas).
4. **Step 4 — Ponytail review → update dokumentasi**
   (exit: hasil review tertulis **di doc**; daftar test final terkunci di doc —
   test yang tidak perlu dicoret dengan alasan; kandidat hapus/edit test
   existing = DECISION GATE wajib ke user).
5. **Step 5 — Implement**
   (exit: kode jadi; syntax check clean — `python3 -m compileall -q scripts/ evals/`
   dan `bash -n` untuk file shell tersentuh).
6. **Step 6 — Ponytail review + cek test minimal regresi**
   (exit: hasil review tertulis di doc; test yang terkunci di Step 4 ADA dan
   PASS — eksekusi `python3 evals/run.py` lalu
   `bash evals/test-shell-regressions.sh`; tidak ada test baru di luar daftar
   tanpa alasan tertulis).
7. **Step 7 — Jelaskan perubahan dengan wireframe, simplify dokumentasi, hilangkan yang tidak perlu**
   (exit: doc berisi deskripsi/wireframe perubahan (sebelum/sesudah); bagian doc
   yang tidak relevan/duplikat/menggambarkan kondisi lama DIHAPUS; `CHANGELOG.md`
   entry di-update statusnya).

## Output ke user

Tiap langkah selesai, lapor dalam 1-2 baris: langkah apa, artifact apa yang
dibuat/diubah. Di akhir workflow: ringkasan 3 baris maksimal.

## Failure Modes

- Langkah dilewati → kembali ke langkah yang exit criteria-nya belum ada.
- Implementasi sebelum dokumentasi (mode DEVELOPMENT) → undo kode, ulangi Step 1.
- Test ditulis setelah implementasi tanpa analisis → ulangi Step 3/4.
- Doc menumpuk (tidak ada yang dihapus) → step dokumentasi belum selesai
  (berlaku di Step 1/2/4/7 mode mana pun, bukan hanya Step 7 DEVELOPMENT).
- Test tidak ikut panduan layer `evals/` (salah layer, over-budget,
  eksekusi asal) → ulangi step test terkait.
