# Runbook — <nama prosedur>

- **Kapan dipakai:** <trigger/kondisi yang membuat runbook ini relevan>
- **Terkait:** <ADR/plan/CLAUDE.md § yang relevan>
- **Prasyarat:** <akses, kredensial, kondisi yang harus sudah terpenuhi>

## Diagnosa (bila runbook untuk insiden)

<Perintah read-only untuk memastikan penyebab sebelum mengubah apa pun.>

```
<perintah>
```

## Langkah <N>. <nama langkah>

<Penjelasan singkat.>

```
<perintah persis>
```

**Verifikasi** (harus lolos sebelum lanjut):
```
<perintah verifikasi> → <hasil yang diharapkan>
```

<Ulangi blok "Langkah" sebanyak perlu. Untuk prosedur berisiko (mis. menyentuh sshd/ufw/DB
prod), tulis satu langkah = satu verifikasi, dan sebutkan kondisi STOP bila verifikasi
gagal.>

## Rollback

<Langkah persis untuk mengembalikan kondisi sebelum runbook ini dijalankan, termasuk
perintah dan cara memverifikasi rollback berhasil.>

## Catatan

<Batasan, UNVERIFIED yang perlu dicek ulang implementer, risiko yang diterima sadar.>
