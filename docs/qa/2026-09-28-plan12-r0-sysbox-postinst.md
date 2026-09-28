# Plan 12 R0 — pra-cek read-only: postinst sysbox-ce 0.7.1, subnet, bip/pool (2026-09-28)

Penanda: **[NYATA]** = dibaca/diukur di sesi ini.

## 1. Paket
- `sysbox-ce_0.7.1.linux_amd64.deb` dari release GitHub `nestybox/sysbox` v0.7.1 (published 2026-07-31T23:47:07Z).
  sha256 `9d6d5484f980d0a17f86c492c1262015c2afb66280bdb97215b79fde6a0261c5` = `digest` asset di GitHub API = `sha256sum`
  lokal [NYATA].
- Control: `Pre-Depends: jq`; `Depends: debconf, fuse, lsb-release, rsync, iptables`. `fuse` dipenuhi `fuse3`
  (`Provides: fuse`). `apt-get install -s` → paket baru hanya `jq libjq1 libonig5 sysbox-ce`, tanpa upgrade/remove [NYATA].
- Isi: `/usr/bin/sysbox-{runc,mgr,fs}`, unit `sysbox{,-mgr,-fs}.service`, `/lib/sysctl.d/99-sysbox-sysctl.conf`.

## 2. Analisis maintainer script (dibaca utuh: `dpkg-deb -e`)
| Script | Perilaku yang relevan untuk dockerd prod |
|---|---|
| `preinst install` | hanya cek distro/kernel (Ubuntu 24.04 → kernel ≥ 6.8; host 6.8.0-142 lolos) |
| `config` (debconf) | bila dockerd jalan **dan** `bip`/`default-address-pools` belum ada di `daemon.json` (regex `^[ ]+"bip": "…"` & `^[ ]+"default-address-pools"`) **dan** ada container → **exit 1** (instal dibatalkan, bukan restart) |
| `postinst configure` → `adjust_docker_config_runtime` | tambah `runtimes.sysbox-runc` bila belum ada (via `jq`, indent 4) → flag `runtime_changed`. Bila entri sudah ada tetapi `docker info` belum menampilkan `sysbox-runc` → flag juga diset |
| `postinst` → `adjust_docker_config_network` | tulis `bip: 172.20.0.1/16` dan pool `172.25.0.0/16 size 24` **hanya bila kunci belum ada/kosong** → flag `network_changed` |
| `postinst` → keputusan | `network_changed` → `systemctl restart docker` **kecuali** ada container. Deteksi container = `docker ps -a \| wc -l \| egrep -q "1$"` — **bug**: jumlah baris berakhiran 1 (11, 21, 31, …) dianggap "tidak ada container" → restart. `runtime_changed` saja → `kill -SIGHUP $(pidof dockerd)` (reload) |
| `postinst` lain | `sysctl -w` runtime: `fs.inotify.max_queued_events/max_user_watches/max_user_instances` → 1048576, `kernel.keys.maxkeys` 20000, `maxbytes` 1400000 (pid_max sudah 4194304); `useradd sysbox`; `mkdir /var/lib/sysboxfs`; start `sysbox-fs/mgr/sysbox` |
| `prerm`/`postrm` | stop unit sysbox; `postrm` membersihkan konfigurasi (dibaca, tidak menyentuh container lain) |

**Kesimpulan (jalur tanpa restart TERKONFIRMASI):** bila `bip` **dan** `default-address-pools` sudah ada di
`daemon.json` sebelum instal, `network_changed` tidak pernah diset → cabang `systemctl restart docker` tidak tercapai.
Bila `runtimes.sysbox-runc` juga sudah ada dan sudah di-reload (SIGHUP) sebelumnya, postinst tidak mengubah
`daemon.json` sama sekali dan tidak mengirim SIGHUP. Karena bug deteksi container di atas, menulis kunci network lebih dulu
adalah **wajib**, bukan sekadar optimasi (33 container → 34 baris; cukup satu container baru/hilang untuk memicu restart).

## 3. Reload dockerd (moby docker-v29.8.1, dibaca dari source)
- `daemon/reload.go` + `reload_unix.go`: opsi reload = debug, max-concurrent-*, shutdown/stop timeout, features, labels,
  registry, live-restore, network-diagnostic-port, NRI, dan platform (**`runtimes`**, default-runtime, shm-size, ipc/cgroupns).
  `bip`, `default-address-pools`, `builder` **bukan** opsi reload → diabaikan saat SIGHUP, berlaku pada restart berikutnya.
- `config.Reload` memvalidasi seluruh file (`Validate`) sebelum menerapkan; `dockerd --validate --config-file` lolos untuk file
  kandidat ("configuration OK") [NYATA].
- `daemon/runtime_unix.go`: path runtime di-`LookPath` secara malas (saat container dibuat), jadi entri runtime sebelum binari
  terpasang tidak menggagalkan reload.
- Unit `docker.service`: `ExecReload=/bin/kill -s HUP $MAINPID` [NYATA `systemctl cat docker`].

## 4. Nilai `bip` / `default-address-pools` identik perilaku sekarang
- `docker0` = `172.17.0.1/16` [NYATA `ip -4 addr show docker0`] → `bip: 172.17.0.1/16`.
- Pool bawaan (moby v29.8.1 `daemon/libnetwork/ipamutils/utils.go` `localScopeDefaultNetworks`): 172.17/16, 172.18/16,
  172.19/16, 172.20/14, 172.24/14, 172.28/14 (size 16) + 192.168.0.0/16 (size 20) → ditulis persis sama.
- Semua 25 network bridge platform bersubnet eksplisit (10.100.x.0/24; `bridge` 172.17.0.0/16) [NYATA `docker network inspect`].

## 5. Subnet `ci-runner` 10.100.18.0/24
- `git grep '10\.100\.18\.'` di semua ref lokal + remote repo infra (di luar plan 12/ADR 0014): **0 hasil**. `/opt/src`
  (compose/env/md) & `/etc`: 0 hasil. Tidak ada network docker di 10.100.18.0/24. `DOCKER-USER` kosong (`-N DOCKER-USER`) [NYATA].

## 6. Status [UNVERIFIED] plan 12
- "Tanpa restart bila bip/pool ditulis dulu (isi postinst 0.7.1)" → **RESOLVED** (§2).
