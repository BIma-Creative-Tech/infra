# Plan NN — <nama fitur/fase>

- **Status:** proposed (menunggu GATE 1) <!-- proposed | accepted (tanggal, GATE) -->
- **Tanggal:** <YYYY-MM-DD> · **Penulis:** Analyst
- **Keputusan user yang dipakai:** <# keputusan bila ada>
- **Terkait:** <CLAUDE.md §..., ADR NNNN, plan lain, docs/discovery/...>

## 1. Scope

IN: <daftar konkret>
OUT: <yang TIDAK termasuk plan ini, dikerjakan di plan/fase lain>

## 2. Fakta yang memengaruhi desain

| Fakta | Sumber | Implikasi |
|---|---|---|
| <fakta> | <perintah/dokumen resmi, tanggal fetch bila web> | <dampak ke desain> |

## 3. Dependency graph

| ID | Task | Agent | depends_on | File/dir disentuh | Paralel dengan |
|---|---|---|---|---|---|
| T01 | <task> | <agent> | <ID/prasyarat> | <path> | <ID lain / —> |

Gelombang paralel: [T01‖...] → [...] → ...

## 4. Threat model ringkas (STRIDE)

| STRIDE | Ancaman | Mitigasi | Verifikasi QA |
|---|---|---|---|
| S/T/R/I/D/E | <ancaman> | <mitigasi yang harus diimplementasikan> | <perintah uji> |

## 5. Acceptance criteria

```
<perintah> → <hasil yang diharapkan>
```

## 6. Risiko

| # | Risiko | Mitigasi |
|---|---|---|
| 1 | <risiko> | <mitigasi> |

## 7. Rollback

<Per task/role, langkah persis untuk mengembalikan kondisi sebelum plan ini dijalankan.>
