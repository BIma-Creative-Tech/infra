# R0b - kandidat pembersihan image dockerd host (plan 12, 2026-09-28)

**Status: DAFTAR SAJA - TIDAK ADA YANG DIHAPUS.** Butuh konfirmasi owner (CLAUDE.md §0.5) dan persetujuan sesi pemilik tiap image.

Sumber [NYATA 2026-09-28 ±16:30 WIB]: `docker image ls -a`, `docker inspect` seluruh 33 container (running + stopped),
pencarian ref tag/digest di `/opt/infra/**/.env`, `*.env`, `docker-compose*.yml`. `docker system df`: image 72,48 GB total,
**49,15 GB reclaimable**; build cache 16,91 GB (9,6 GB reclaimable).

Catatan:
- Kolom ukuran = ukuran per image (snapshotter containerd), belum dikurangi layer bersama → jumlah kolom lebih besar dari ruang yang benar-benar kembali (angka riil: `docker system df` ±49 GB).
- Docker tidak mencatat "terakhir dipakai". Kolom *terakhir dipakai* = StartedAt container yang memakai image (bila ada container); selain itu hanya waktu dibuat.
- "Dipakai" = direferensikan container yang ADA (termasuk exited, mis. `*-migrate`). Image yang dirujuk digest di `.env` tetap KEEP walau tanpa container (target deploy/rollback).
- KEEP? = heuristik (rilis sebelumnya / tooling). Sesi pemilik yang memutuskan.

Ringkasan: 145 image ID. KEEP 27, KEEP? 13, **KANDIDAT 105** (jumlah kolom ±104.5 GB).

| Pemilik (kandidat) | jumlah | jumlah kolom ukuran |
|---|---|---|
| ProyekKas/DRMS (sesi app drms) | 46 | 52.9 GB |
| tak bertag (dangling; pemilik tidak diketahui) | 25 | 33.2 GB |
| image dasar/tooling (build & QA) | 24 | 15.2 GB |
| web bct (sesi bct-website) | 6 | 1.9 GB |
| web expomedia (sesi klien) | 2 | 0.6 GB |
| control-plane (sesi control-plane) | 1 | 0.3 GB |
| web starter (template klien) | 1 | 0.3 GB |

## Cara menghapus setelah dikonfirmasi (owner/Lead, bukan otomatis)

```
# per image yang disetujui (ID dari tabel KANDIDAT). TANPA -f: gagal bila ternyata dipakai container -> aman
docker image rm <id>
# build cache lama dockerd host (builder GC sudah membatasi 10 GiB), setelah konfirmasi:
docker builder prune --filter until=72h
# JANGAN: docker system prune / docker image prune -a (menyentuh image rollback & tooling)
```

## Tabel

| Status | ID | repo:tag | ukuran | dibuat | terakhir dipakai | pemilik stack/sesi | dipakai? | alasan |
|---|---|---|---|---|---|---|---|---|
| KANDIDAT | `fa9379e5c9f8` | `proyekkas-migrate:0.1.0-stg-f8529e6` | 1.84GB | 2026-09-23 19:44 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `9121b5e7ff3e` | `proyekkas-web:0.1.0-stg-f8529e6` | 342MB | 2026-09-23 19:44 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `4ff3fd666ce5` | `proyekkas-migrate:0.1.0-stg-4d952ba` | 1.9GB | 2026-09-24 00:30 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `675cf5979303` | `proyekkas-web:0.1.0-stg-4d952ba` | 350MB | 2026-09-24 00:30 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `bdb950639629` | `proyekkas-migrate:0.1.0-stg-3e6d427` | 1.9GB | 2026-09-24 06:28 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `f7f268791093` | `proyekkas-web:0.1.0-stg-3e6d427` | 350MB | 2026-09-24 06:28 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `3dec3fe0f44e` | `proyekkas-web:0.1.0-stg-59ba0a4` | 350MB | 2026-09-24 07:14 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `9c5d1a177817` | `proyekkas-migrate:0.1.0-stg-59ba0a4` | 1.9GB | 2026-09-24 07:22 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `6ec5a6dd2240` | `proyekkas-web:0.1.0-stg-c11907a` | 350MB | 2026-09-24 08:30 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `876c0954f53e` | `proyekkas-migrate:0.1.0-stg-c11907a` | 1.91GB | 2026-09-24 08:37 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2e97d192e61c` | `proyekkas-web:0.1.0-stg-e9c07ab` | 351MB | 2026-09-24 09:19 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `f91cb9a495f4` | `proyekkas-migrate:0.1.0-stg-e9c07ab` | 1.91GB | 2026-09-24 09:20 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `680bc772a8e7` | `proyekkas-migrate:0.1.0-stg-2b5a83f` | 1.93GB | 2026-09-24 19:18 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `73bb40644345` | `proyekkas-web:0.1.0-stg-2b5a83f` | 353MB | 2026-09-24 19:18 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `445ee19730d4` | `proyekkas-web:0.1.0-stg-6fa741a` | 353MB | 2026-09-24 19:58 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `b0a656775693` | `proyekkas-migrate:0.1.0-stg-6fa741a` | 1.93GB | 2026-09-24 20:09 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c450e807b7bf` | `proyekkas-migrate:0.1.0-stg-e7e997a` | 1.93GB | 2026-09-25 10:40 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `8c259ef7672b` | `proyekkas-web:0.1.0-stg-e7e997a` | 353MB | 2026-09-25 10:40 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `abed162717ec` | `proyekkas-migrate:theme-bbb0c3b` | 1.93GB | 2026-09-25 20:27 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e49923a7394e` | `proyekkas-web:theme-bbb0c3b` | 354MB | 2026-09-25 20:27 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2358f4a155cc` | `proyekkas-migrate:0.1.0-stg-43830e6`<br>`proyekkas-migrate:theme-43830e6` | 1.94GB | 2026-09-25 22:04 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `74a65a774ee3` | `proyekkas-web:0.1.0-stg-43830e6`<br>`proyekkas-web:theme-43830e6` | 354MB | 2026-09-25 22:04 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2dd4a6561866` | `proyekkas-web:e1-dcd03c7` | 354MB | 2026-09-26 10:11 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `098476fe0c4e` | `proyekkas-migrate:e1-dcd03c7` | 1.94GB | 2026-09-26 10:11 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `d95890c59f2f` | `proyekkas-migrate:0.1.0-stg-c3b7cbd`<br>`proyekkas-migrate:e2-be6a127` | 1.94GB | 2026-09-26 10:34 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `64169fb7e14b` | `proyekkas-web:0.1.0-stg-c3b7cbd`<br>`proyekkas-web:e2-be6a127` | 354MB | 2026-09-26 10:34 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e79cd9c6e21f` | `proyekkas-web:e6-6d5e2a3` | 355MB | 2026-09-26 16:47 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `a36ed0271ddc` | `proyekkas-migrate:e6-6d5e2a3` | 1.95GB | 2026-09-26 16:48 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `cce610582cea` | `proyekkas-migrate:0.1.0-stg-63c4fb6`<br>`proyekkas-migrate:e4-10667f6` | 1.95GB | 2026-09-26 17:11 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e047d960628c` | `proyekkas-web:0.1.0-stg-63c4fb6`<br>`proyekkas-web:e4-10667f6` | 356MB | 2026-09-26 17:11 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `181e9ed15cd4` | `proyekkas-migrate:0.1.0-stg-a670f4c`<br>`proyekkas-migrate:s2b-42f8dea` | 1.96GB | 2026-09-26 18:37 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `1a229a5dd96f` | `proyekkas-web:0.1.0-stg-a670f4c`<br>`proyekkas-web:s2b-42f8dea` | 356MB | 2026-09-26 18:37 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `7be25a9252b1` | `proyekkas-migrate:0.1.0-stg-47819f6`<br>`proyekkas-migrate:s2a-d7db863` | 1.97GB | 2026-09-26 19:08 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `dacbc3d49aa1` | `proyekkas-web:0.1.0-stg-47819f6`<br>`proyekkas-web:s2a-d7db863` | 357MB | 2026-09-26 19:08 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c7d69448fed2` | `ghcr.io/bctech-adm/proyekkas-migrate:0.2.1-stg-409562e` | 1.98GB | 2026-09-26 22:10 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `cd433bc98091` | `ghcr.io/bctech-adm/proyekkas-web:0.2.1-stg-409562e` | 359MB | 2026-09-26 22:10 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `5490b6cb08c6` | `ghcr.io/bctech-adm/proyekkas-migrate:0.2.1-stg-13b1f05` | 1.98GB | 2026-09-26 22:50 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `31a07e00a601` | `ghcr.io/bctech-adm/proyekkas-web:0.2.1-stg-13b1f05` | 359MB | 2026-09-26 22:50 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `451bccbb1905` | `ghcr.io/bctech-adm/proyekkas-migrate:0.2.1-stg-dc80237` | 1.98GB | 2026-09-27 09:33 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `ff493beb6408` | `ghcr.io/bctech-adm/proyekkas-web:0.2.1-stg-dc80237` | 359MB | 2026-09-27 09:33 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `979fc93c4100` | `ghcr.io/bctech-adm/proyekkas-web:0.3.0-stg-30c1a9e` | 360MB | 2026-09-27 16:18 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `46aab0d0fd38` | `ghcr.io/bctech-adm/proyekkas-migrate:0.3.0-stg-30c1a9e` | 2.03GB | 2026-09-27 16:18 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `33e1b94c1599` | `ghcr.io/bctech-adm/proyekkas-migrate:<none>` | 2.03GB | 2026-09-27 16:41 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `dcffa2af515e` | `ghcr.io/bctech-adm/proyekkas-web:<none>` | 360MB | 2026-09-27 16:41 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c571f917a1c2` | `ghcr.io/bctech-adm/proyekkas-migrate:0.4.0-stg-996430c` | 2.04GB | 2026-09-27 18:22 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `a4d4f28dbb2c` | `ghcr.io/bctech-adm/proyekkas-web:0.4.0-stg-996430c` | 360MB | 2026-09-27 18:22 | - | ProyekKas/DRMS (sesi app drms) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `80852d1dc708` | `control-plane:4fc3828` | 303MB | 2026-09-23 12:52 | - | control-plane (sesi control-plane) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c1fe1679c34d` | `curlimages/curl:8.11.1` | 32.3MB | 2024-12-11 15:46 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `887a259a5a53` | `rhysd/actionlint:1.7.7` | 98.9MB | 2025-01-19 19:00 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `4f34c6d23f4b` | `ghcr.io/jqlang/jq:<none>` | 3.33MB | 2025-07-01 18:42 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `4026b29997dc` | `curlimages/curl:8.15.0` | 33.5MB | 2025-07-17 12:59 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `519591d6871b` | `python:3.12.11-slim-bookworm` | 189MB | 2025-08-09 01:20 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `b27e719ecbfe` | `mcr.microsoft.com/playwright:v1.55.0-noble` | 3.64GB | 2025-08-20 17:41 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `300809dc6d74` | `ghcr.io/astral-sh/ruff:<none>` | 49.5MB | 2025-09-10 23:19 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `463eaf607268` | `curlimages/curl:8.16.0` | 44.1MB | 2025-09-12 14:15 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c00b6bd0aeb3` | `zricethezav/gitleaks:v8.30.1` | 76.6MB | 2026-03-21 09:19 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `1f5038b54f06` | `tecnativa/docker-socket-proxy:v0.5.0` | 65.8MB | 2026-07-27 16:28 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c4717a8d1f01` | `traefik/whoami:v1.12.0` | 19.2MB | 2026-07-29 22:43 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `781a2bdaea47` | `zaproxy/zap-stable:latest` | 3.71GB | 2026-08-07 21:58 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `008173c23f95` | `ubuntu:24.04` | 119MB | 2026-09-11 18:44 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `c4e17ce033de` | `louislam/uptime-kuma:2.5.5-rootless` | 2.49GB | 2026-09-16 20:26 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `82a77884f3af` | `quay.io/keycloak/keycloak:26.7.4` | 756MB | 2026-09-16 21:45 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `294b683cb724` | `alpine:3` | 13MB | 2026-09-18 03:37 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `ebfe2f904627` | `node:24.21.0-alpine` | 242MB | 2026-09-18 04:47 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `3783cc01769c` | `debian:bookworm-slim` | 116MB | 2026-09-18 07:00 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2d74fb22d7f8` | `dart:3.13.4` | 1.21GB | 2026-09-19 07:45 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `0e0ff40c39bc` | `node:24.21.0-bookworm-slim` | 332MB | 2026-09-19 07:48 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2f17fc044b57` | `python:<none>` | 179MB | 2026-09-19 08:07 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `64af3819f927` | `node:24.21.0` | 1.65GB | 2026-09-19 10:17 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `74d609a42ec2` | `axllent/mailpit:v1.31.2` | 50.6MB | 2026-09-19 18:24 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e66db15b8601` | `grafana/k6:latest` | 111MB | 2026-09-21 22:08 | - | image dasar/tooling (build & QA) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2d880fe4589f` | `<none>:<none>` | 1.32GB | 2026-09-23 23:00 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e889ccce02c0` | `<none>:<none>` | 1.32GB | 2026-09-23 23:00 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `a9c5a5db0b36` | `<none>:<none>` | 242MB | 2026-09-24 10:17 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `afca70816948` | `<none>:<none>` | 242MB | 2026-09-24 10:17 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `08b047c0e9ea` | `<none>:<none>` | 241MB | 2026-09-24 10:19 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2b250ae45ec2` | `<none>:<none>` | 1.36GB | 2026-09-24 10:21 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `3885917b3267` | `<none>:<none>` | 1.36GB | 2026-09-24 10:21 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `873bc3bbe29e` | `<none>:<none>` | 1.36GB | 2026-09-24 10:21 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `0ae247d8513d` | `<none>:<none>` | 1.91GB | 2026-09-24 10:23 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `3fe077ce8912` | `<none>:<none>` | 1.91GB | 2026-09-24 10:23 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `a47908c594a8` | `<none>:<none>` | 1.91GB | 2026-09-24 10:24 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `76bc5e565915` | `<none>:<none>` | 1.91GB | 2026-09-24 10:24 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `1ae9f4a2888f` | `<none>:<none>` | 242MB | 2026-09-24 18:43 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `a5b4dc78cdd6` | `<none>:<none>` | 242MB | 2026-09-24 18:43 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `2a848891f28a` | `<none>:<none>` | 1.74GB | 2026-09-24 18:44 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `095928853ec5` | `<none>:<none>` | 241MB | 2026-09-24 18:45 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e9164a9622fc` | `<none>:<none>` | 1.36GB | 2026-09-24 18:46 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `48883e64b4ea` | `<none>:<none>` | 1.37GB | 2026-09-24 18:47 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `ce2ef2bb53a1` | `<none>:<none>` | 1.37GB | 2026-09-24 18:47 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `35034c62a856` | `<none>:<none>` | 1.93GB | 2026-09-24 18:49 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `27c3c989cb7d` | `<none>:<none>` | 1.93GB | 2026-09-24 18:49 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `15b5aaad973c` | `<none>:<none>` | 1.93GB | 2026-09-24 18:49 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `a68563ddbbf5` | `<none>:<none>` | 1.93GB | 2026-09-24 18:49 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `e3bdf124bead` | `<none>:<none>` | 1.93GB | 2026-09-24 18:49 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `985eb6cf077a` | `<none>:<none>` | 1.93GB | 2026-09-24 18:49 | - | tak bertag (dangling; pemilik tidak diketahui) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `d3fd4ecc1742` | `web-bct:dev-7ccf181` | 318MB | 2026-09-26 17:56 | - | web bct (sesi bct-website) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `7a13f5a91ce6` | `web-bct:dev-8568e94` | 319MB | 2026-09-26 18:53 | - | web bct (sesi bct-website) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `20092909e4ba` | `web-bct:dev-96ca786` | 319MB | 2026-09-26 21:01 | - | web bct (sesi bct-website) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `596ae9859b3a` | `web-bct:dev-581e796` | 319MB | 2026-09-27 00:20 | - | web bct (sesi bct-website) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `09fbbda64815` | `web-bct:dev-5f52225` | 319MB | 2026-09-27 06:57 | - | web bct (sesi bct-website) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `084883e14f4d` | `web-bct:prod-4bd1da3` | 319MB | 2026-09-27 06:57 | - | web bct (sesi bct-website) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `1f97d77e424a` | `web-expomedia:dev-7bb2a92` | 288MB | 2026-09-25 18:48 | - | web expomedia (sesi klien) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `4251970dfa30` | `web-expomedia:dev-0e87369` | 288MB | 2026-09-25 18:55 | - | web expomedia (sesi klien) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KANDIDAT | `29b55f5b2183` | `web-starter:dev-fec4c76` | 287MB | 2026-09-25 09:00 | - | web starter (template klien) | tidak | tidak dipakai container mana pun (running/stopped) dan tidak dirujuk .env/compose infra |
| KEEP? | `187dfdd260e0` | `ghcr.io/bctech-adm/proyekkas-migrate:0.3.0` | 1.98GB | 2026-09-27 13:16 | - | ProyekKas/DRMS (sesi app drms) | tidak | kemungkinan target rollback prod DRMS (rilis sebelum yang jalan) - konfirmasi pemilik |
| KEEP? | `093e35e3c6b7` | `ghcr.io/bctech-adm/proyekkas-web:0.3.0` | 359MB | 2026-09-27 13:16 | - | ProyekKas/DRMS (sesi app drms) | tidak | kemungkinan target rollback prod DRMS (rilis sebelum yang jalan) - konfirmasi pemilik |
| KEEP? | `688e6be53b03` | `control-plane:7b85a78` | 307MB | 2026-09-25 12:59 | - | control-plane (sesi control-plane) | tidak | kemungkinan target rollback control-plane (build sebelumnya) - konfirmasi pemilik |
| KEEP? | `2097951f02e7` | `koalaman/shellcheck:v0.10.0` | 19.3MB | 2024-03-08 09:42 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `61862eba1fcf` | `koalaman/shellcheck:v0.11.0` | 20MB | 2025-08-04 07:45 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `9955be09ea7f` | `koalaman/shellcheck-alpine:v0.11.0` | 32.8MB | 2025-08-04 07:46 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `32dac94127fd` | `hadolint/hadolint:v2.15.1` | 67.9MB | 2026-07-31 16:56 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `62b1e65e8869` | `aquasec/trivy:0.74.0` | 254MB | 2026-08-14 18:27 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `58adaa4e8dca` | `curlimages/curl:8.22.0` | 35.4MB | 2026-09-02 16:04 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `acaac22ffc7b` | `semgrep/semgrep:<none>` | 1.56GB | 2026-09-11 02:15 | - | image dasar/tooling (build & QA) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `e5496277be5d` | `ghcr.io/actions/actions-runner:<none>` | 2.15GB | 2026-08-27 07:18 | - | infra plan 12 (runner CI) | tidak | tooling QA/CI lokal (hadolint/trivy/shellcheck/semgrep/curl/basis runner) - dipakai sesi QA |
| KEEP? | `077f3e7f223d` | `ci-runner:2.337.0-1` | 2.22GB | 2026-09-28 16:17 | - | infra plan 12 (runner CI) | tidak | image runner CI aktif (plan 12) - konfirmasi pemilik |
| KEEP? | `b433c0b517a6` | `ghcr.io/bctech-adm/bct-website:0.1.0` | 319MB | 2026-09-27 07:41 | - | web bct (sesi bct-website) | tidak | kemungkinan target rollback web bct - konfirmasi pemilik |
| KEEP | `05cb27505787` | `proyekkas-migrate:0.1.0-stg-3b05b83` | 1.83GB | 2026-09-23 18:34 | - | ProyekKas/DRMS (sesi app drms) | tidak | dirujuk konfigurasi: staging/drms-proyekkas/.env (digest) |
| KEEP | `009c11134d7d` | `proyekkas-web:0.1.0-stg-3b05b83` | 341MB | 2026-09-23 18:34 | - | ProyekKas/DRMS (sesi app drms) | tidak | dirujuk konfigurasi: staging/drms-proyekkas/.env (digest) |
| KEEP | `42682f7f2d09` | `ghcr.io/bctech-adm/proyekkas-web:<none>` | 360MB | 2026-09-27 22:12 | 2026-09-27T15:32:01 | ProyekKas/DRMS (sesi app drms) | ya | dipakai container: drms-pk-worker (running), drms-pk-web (running) |
| KEEP | `139ab67a1e2f` | `ghcr.io/bctech-adm/proyekkas-migrate:<none>` | 2.04GB | 2026-09-27 22:12 | 2026-09-27T15:31:35 | ProyekKas/DRMS (sesi app drms) | ya | dipakai container: drms-pk-migrate (exited) |
| KEEP | `c7b1cb2eb3d9` | `ghcr.io/bctech-adm/proyekkas-web:<none>` | 360MB | 2026-09-27 23:51 | 2026-09-27T17:29:25 | ProyekKas/DRMS (sesi app drms) | ya | dipakai container: drms-pk-stg (running), drms-pk-stg-worker (running) |
| KEEP | `38a5ac8907c9` | `ghcr.io/bctech-adm/proyekkas-migrate:<none>` | 2.04GB | 2026-09-27 23:51 | 2026-09-27T17:28:58 | ProyekKas/DRMS (sesi app drms) | ya | dipakai container: drms-pk-stg-migrate (exited) |
| KEEP | `7963604185e7` | `control-plane:6d94d2b` | 307MB | 2026-09-25 13:44 | 2026-09-26T09:08:10 | control-plane (sesi control-plane) | ya | dipakai container: control-plane-worker (running), control-plane (running), web-control-plane-migrate-1 (exited), control-plane-staging-worker (running), control-plane-staging (running), staging-control-plane-migrate-1 (exited) |
| KEEP | `1b4e4438faca` | `prom/node-exporter:v1.12.1` | 41MB | 2026-07-14 19:11 | 2026-09-25T10:30:39 | image dasar/tooling (build & QA) | ya | dipakai container: node-exporter (running) |
| KEEP | `b8ec653c4423` | `grafana/alloy:v1.19.2` | 901MB | 2026-08-27 03:45 | 2026-09-23T14:03:53 | image dasar/tooling (build & QA) | ya | dipakai container: alloy (running) |
| KEEP | `0f2523fa61ef` | `crowdsecurity/crowdsec:v1.8.1` | 610MB | 2026-09-03 20:24 | 2026-09-25T03:50:09 | image dasar/tooling (build & QA) | ya | dipakai container: crowdsec (running) |
| KEEP | `d0fe7668defe` | `mailserver/docker-mailserver:<none>` | 1.04GB | 2026-09-04 19:40 | 2026-09-25T13:29:48 | image dasar/tooling (build & QA) | ya | dipakai container: mailserver (running) |
| KEEP | `6976aa8a60fe` | `prom/prometheus:v3.13.3` | 362MB | 2026-09-07 19:19 | 2026-09-23T14:03:53 | image dasar/tooling (build & QA) | ya | dipakai container: prometheus (running) |
| KEEP | `ac461fb352ab` | `grafana/grafana:13.2.2` | 1.92GB | 2026-09-14 20:01 | 2026-09-25T02:35:35 | image dasar/tooling (build & QA) | ya | dipakai container: grafana (running) |
| KEEP | `144175ec0039` | `odoo:19.0-20260908` | 3.29GB | 2026-09-16 10:29 | 2026-09-25T15:09:29 | image dasar/tooling (build & QA) | ya | dipakai container: odoo-pool-a (running), odoo-staging (running) |
| KEEP | `a292237a108f` | `louislam/uptime-kuma:2.5.5-slim-rootless` | 849MB | 2026-09-16 20:24 | 2026-09-25T10:52:08 | image dasar/tooling (build & QA) | ya | dipakai container: uptime-kuma (running) |
| KEEP | `85909afc45bd` | `ghcr.io/umami-software/umami:<none>` | 1.47GB | 2026-09-17 11:23 | 2026-09-28T01:51:14 | image dasar/tooling (build & QA) | ya | dipakai container: umami (running) |
| KEEP | `1107dd5274e0` | `grafana/loki:3.7.8` | 211MB | 2026-09-17 20:49 | 2026-09-23T14:03:53 | image dasar/tooling (build & QA) | ya | dipakai container: loki (running) |
| KEEP | `24841fe2de73` | `traefik:v3.7.13` | 253MB | 2026-09-18 04:33 | 2026-09-26T09:11:08 | image dasar/tooling (build & QA) | ya | dipakai container: traefik (running) |
| KEEP | `9e9fde4d32ee` | `python:3-alpine` | 73.7MB | 2026-09-18 04:50 | - | image dasar/tooling (build & QA) | tidak | dirujuk konfigurasi: ansible/collections/ansible_collections/community/docker/tests/integration/targets/setup_docker/vars/main.env |
| KEEP | `efedf3595f1d` | `postgres:16.15-bookworm` | 622MB | 2026-09-19 07:36 | 2026-09-26T09:08:11 | image dasar/tooling (build & QA) | ya | dipakai container: postgres (running) |
| KEEP | `38e4b5295c6b` | `roundcube/roundcubemail:1.7.4-apache-nonroot` | 1.05GB | 2026-09-21 15:04 | 2026-09-25T14:46:36 | image dasar/tooling (build & QA) | ya | dipakai container: webmail (running) |
| KEEP | `b7d1acc78cfd` | `infra/keycloak:26.7.4-optimized` | 762MB | 2026-09-23 11:15 | 2026-09-25T15:06:11 | image dasar/tooling (build & QA) | ya | dipakai container: keycloak (running) |
| KEEP | `17ab1031782a` | `ghcr.io/bctech-adm/bct-website:0.2.0` | 319MB | 2026-09-27 08:46 | 2026-09-27T01:49:20 | web bct (sesi bct-website) | ya | dipakai container: web-bct-prod (running), web-bct-staging (running) |
| KEEP | `b8088e95debe` | `web-expomedia:dev-148b002` | 289MB | 2026-09-25 19:38 | 2026-09-25T13:26:34 | web expomedia (sesi klien) | ya | dipakai container: web-expomedia-prod (running) |
| KEEP | `7558a8c4b130` | `web-expomedia:dev-438adb8` | 292MB | 2026-09-26 09:47 | 2026-09-26T02:50:47 | web expomedia (sesi klien) | ya | dipakai container: web-expomedia-staging (running) |
| KEEP | `8a982f031e08` | `web-starter:dev-d5f6148` | 287MB | 2026-09-25 09:10 | 2026-09-25T02:19:50 | web starter (template klien) | ya | dipakai container: web-starter-staging (running) |
| KEEP | `b8c3d853e03e` | `web-tambang:dev-59dcd4c` | 301MB | 2026-09-25 23:44 | 2026-09-26T02:00:42 | web tambang (sesi klien) | ya | dipakai container: web-tambang-staging (running) |
