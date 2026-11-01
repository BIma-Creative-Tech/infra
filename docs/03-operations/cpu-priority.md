# Operasi — prioritas CPU per tier container (`cpu-priority-guard`)

Role Ansible `cpu_priority` (`ansible/roles/cpu_priority`) + swapfile kedua (role `sysctl_swap`, `swap_extra_files`).
Selalu `--check --diff` dulu:

```bash
cd /opt/infra/ansible
/opt/ansible-venv/bin/ansible-playbook site.yml --tags cpu_priority --check --diff
```

## 1. Latar (insiden 2026-10-13 22:30 WIB)

DRMS prod (`drms-kas.bimacreative.tech`) tidak bisa dipakai: sesi lain menjalankan 5 container ad-hoc
`docker run node:24 … npm ci / tsc / vitest` paralel di VPS 4 vCPU (ditambah CPU steal hypervisor ±70%). Semua container
berbobot CPU sama (cgroup v2 `cpu.weight` 100), sehingga build/test ad-hoc merebut CPU setara dengan Postgres, Traefik,
Keycloak dan app prod.

Perbaikan live oleh Lead (malam itu, sebelum role ini ada): `docker update --cpu-shares` per tier, `systemctl set-property
user.slice CPUWeight=20`, `docker update --cpus 1.5 drms-pk-web`, swapfile kedua `/swapfile2` 4 GiB. Role ini
mengodifikasi keadaan tersebut.

### Kenapa bukan di compose

Mengubah `cpu_shares` di compose stack inti (postgres, traefik, keycloak, crowdsec, mailserver, …) mengubah hash config
compose → `docker compose up -d` rutin berikutnya akan **me-recreate** layanan kritis tanpa diduga. Karena itu bobot
ditegakkan oleh timer host dengan `docker update` (live, tanpa restart). Pengecualian: DRMS prod
(`web/clients/drms-proyekkas/docker-compose.yml`) — di-deploy ulang rutin (recreate terjadi tetap), jadi nilainya juga
ditulis di compose: `drms-pk-web` `cpus: 1.5` + `cpu_shares: 10240`, `drms-pk-worker` `cpu_shares: 10240`.

## 2. Tier

| Tier | cpu-shares | cgroup `cpu.weight` | Container |
|---|---|---|---|
| prod | 10240 | 639 (teramati) | drms-pk-web, drms-pk-worker, postgres, traefik, crowdsec, keycloak, odoo-pool-a, web-ditled-prod, web-expomedia-prod, web-bct-prod, control-plane, control-plane-worker, mailserver, webmail |
| observability/tools | tidak diset | 100 (teramati) | grafana, loki, prometheus, alloy, node-exporter, uptime-kuma, umami — **sengaja tidak tercantum** |
| staging | 512 | 59 (teramati) | drms-pk-stg, drms-pk-stg-worker, erajaya-staging-web, web-expomedia-staging, web-bct-staging, web-starter-staging, odoo-staging, control-plane-staging, control-plane-staging-worker, control-plane-staging-mailpit |
| job runner CI | 256 (dari `ci-runner-supervisor`) | 35 (dihitung) | container berlabel `ci-runner=1` — **tidak disentuh** guard |
| ad-hoc | 64 (+ `--cpus 1.0` bila tanpa limit) | 12 (dihitung) | container running **tanpa** label `com.docker.compose.project` dan **tanpa** label `ci-runner`, cpu-shares belum diset |

Override `--cpus` per container: `drms-pk-web` = 1.5 (`cpu_priority_cpus_overrides`; harus sama dengan `cpus:` di compose).

Sesi login (SSH, build/test manual di shell) ada di `user.slice` dengan `CPUWeight=20` (system.slice = 100).

Nilai `cpu.weight` "teramati" dibaca 2026-10-13 dari `/sys/fs/cgroup/system.slice/docker-<id>.scope/cpu.weight`
(drms-pk-web 639, drms-pk-stg 59, grafana 100; runc 1.5.1). Nilai "dihitung" memakai formula konversi shares → weight
runc yang mereproduksi tepat 639 (10240) dan 59 (512): `ceil(10^((l² + 125·l)/612 − 7/34))`, `l = log2(shares)` — belum
diamati di container nyata.

Konsekuensi container ad-hoc: `docker run --rm` diagnostik (mis. curl di `observability.md`) atau container sementara
skrip yang berjalan > 60 s juga ikut diturunkan ke 64 / 1 CPU. Itu disengaja; container compose (`docker compose run`)
membawa label project sehingga tidak tersentuh.

## 3. Komponen

| Komponen | Lokasi | Catatan |
|---|---|---|
| Skrip | `/usr/local/sbin/cpu-priority-guard` (sumber `ansible/roles/cpu_priority/files/`) | `--dry-run` = cetak rencana tanpa mengubah apa pun |
| Config | `/etc/cpu-priority/tiers.conf` (template role) | `prod <nama>`, `staging <nama>`, `cpus <nama> <desimal>`, `*_shares`, `adhoc_cpus`; config invalid → exit 2 |
| Service | `cpu-priority-guard.service` (oneshot, `Nice=10`, `CPUWeight=10`, hardening pola `container-metrics`) | `OnFailure=infra-unit-failure@%n.service` → email (anti-spam 60 menit) |
| Timer | `cpu-priority-guard.timer` | `OnBootSec=1min`, `OnUnitActiveSec=60s`, `AccuracySec=10s` |
| user.slice | `/etc/systemd/system/user.slice.d/50-cpu-weight.conf` | `[Slice] CPUWeight=20` |
| user.slice (live, lama) | `/etc/systemd/system.control/user.slice.d/50-CPUWeight.conf` | dibuat `systemctl set-property` saat insiden; **dibiarkan** (prioritas lebih tinggi, isi sama) |
| Swap | `/swapfile` + `/swapfile2` (masing-masing 4 GiB, `group_vars/all.yml` `swap_file`, `swap_extra_files`) | role `sysctl_swap`; file yang sudah ada & aktif → tanpa perubahan |

Perilaku tiap run: `docker update` dipanggil **hanya** bila nilai berbeda; tiap perubahan dicatat ke journal
(`<nama>: (<tier>) cpu-shares lama→baru`). Tidak pernah stop/kill/restart. Container yang hilang di tengah run dilewati.
`docker update` gagal untuk container yang masih ada → unit failed → alert. Limit CPU ad-hoc yang sudah ada (NanoCpus
atau CpuQuota/CpuPeriod) tidak pernah diubah.

Status cepat:

```bash
systemctl list-timers cpu-priority-guard.timer --no-pager
journalctl -t cpu-priority-guard --since today --no-pager      # hanya berisi baris bila ada perubahan
/usr/local/sbin/cpu-priority-guard --dry-run                   # 0 perubahan = host sesuai config
docker ps --format '{{.Names}}' | sort | xargs -r docker inspect -f '{{.Name}} shares={{.HostConfig.CpuShares}} nano={{.HostConfig.NanoCpus}}'
cat /sys/fs/cgroup/user.slice/cpu.weight                        # 20
```

## 4. Menambah container client baru ke tier

1. Tambahkan `container_name` ke `cpu_priority_prod` atau `cpu_priority_staging` (`ansible/roles/cpu_priority/defaults/main.yml`,
   atau override di `group_vars`). Nama harus unik di kedua list.
2. Limit `--cpus` khusus? Tambahkan ke `cpu_priority_cpus_overrides` **dan** samakan `cpus:` di compose stack itu
   (berbeda → compose dan guard saling menimpa di setiap deploy).
3. `ansible-playbook site.yml --tags cpu_priority --check --diff` → periksa diff `tiers.conf` → jalankan tanpa `--check`.
4. Verifikasi: `/usr/local/sbin/cpu-priority-guard --dry-run` → 0 perubahan dalam ≤ 60 s setelah container ada,
   `docker inspect -f '{{.HostConfig.CpuShares}}' <nama>`.

Container compose yang tidak dicantumkan tetap berbobot 100 (seperti observability). Jangan menulis `cpu_shares` di compose
stack inti (lihat §1).

## 5. Rollback

```bash
# hentikan guard (nilai yang sudah diterapkan di container TETAP)
systemctl disable --now cpu-priority-guard.timer
# atau seluruh role: cpu_priority_state: absent → --tags cpu_priority
```

Mengembalikan bobot container:

- **Recreate** container (deploy berikutnya / `docker compose up -d` stack itu) → nilai kembali ke compose (stack inti:
  tidak diset = weight 100). Cara yang terverifikasi bobotnya (grafana: tidak diset → 100).
- Atau live tanpa restart: `docker update --cpu-shares 1024 <nama…>` → weight 100 menurut formula §2 (**dihitung, belum
  diamati live**; cek `cat /sys/fs/cgroup/system.slice/docker-$(docker inspect -f '{{.Id}}' <nama>).scope/cpu.weight`).
- `drms-pk-web` `--cpus`: kembali lewat compose (deploy) atau `docker update --cpus <nilai> drms-pk-web`.

user.slice (belum diuji): hapus **kedua** drop-in (`/etc/systemd/system/user.slice.d/50-cpu-weight.conf` dan
`/etc/systemd/system.control/user.slice.d/50-CPUWeight.conf`) → `systemctl daemon-reload` → cek
`cat /sys/fs/cgroup/user.slice/cpu.weight`; bila belum 100: `systemctl set-property --runtime user.slice CPUWeight=100`.

Swap kedua: `swapoff /swapfile2`, hapus baris fstab, `swap_extra_files: []`, baru `rm /swapfile2` (pastikan RAM cukup
sebelum `swapoff`).
