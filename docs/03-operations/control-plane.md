# Operasional — Control plane PROD (T16a)

- **Publik:** `https://cp.bimacreative.tech` (router `traefik/dynamic/platform/cp.yml`, sertifikat LE production `le-http`).
- **Stack:** `/opt/infra/web/control-plane/` (CLAUDE.md §3.1) · project compose `web-control-plane`.
- **Image:** lokal `control-plane:<short-sha>` dibangun dari repo `/opt/src/control-plane` commit `main`
  (saat ini **`control-plane:4fc3828`**, label `org.opencontainers.image.revision`). Tidak ada registry (GHCR menyusul CI).
- **Auth:** Auth.js OIDC → Keycloak realm `platform`, client `control-plane` (confidential, PKCE S256), callback
  `https://cp.bimacreative.tech/api/auth/callback/keycloak`.
- **Terkait:** repo control-plane `README.md` §Kebutuhan deploy T16, `keycloak.md`, `traefik.md`, `postgres.md`, ADR 0004.

## Isi stack

| Path / service | Isi | Git |
|---|---|---|
| `docker-compose.yml` | `migrate` (one-shot), `web` (container `control-plane`), `worker` (container `control-plane-worker`) | ya |
| `.env` | `DATABASE_URL`, `AUTH_SECRET`, `AUTH_URL`, `AUTH_KEYCLOAK_{ID,SECRET,ISSUER}`, `NODE_ENV`, `LOG_LEVEL` — **600 root** | **tidak** (`.gitignore` root: `.env`) |

| Service | Network | Limit (ADR 0004) | Healthcheck |
|---|---|---|---|
| `migrate` | `db` | 256m / 0.25 | — (one-shot, `restart: "no"`) |
| `web` → `control-plane:3000` | `db`, `proxy` (Traefik + egress ke `auth.bimacreative.tech`) | 384m / 0.5 | `GET /api/health` |
| `worker` | `db` saja | 256m / 0.25 | heartbeat file `/tmp/worker-heartbeat` (< 60 s) |

Hardening semua service: `user 1001:1001`, `read_only` + tmpfs, `cap_drop: [ALL]`, `no-new-privileges`, log 10m×3,
tanpa port publish. `web` & `worker` `depends_on: migrate (service_completed_successfully)` → setiap
`docker compose up -d` menjalankan migrasi drizzle dulu; migrasi gagal = container lama tetap jalan (tidak di-recreate).

## Router Traefik (`dynamic/platform/cp.yml`)

| Router | Rule | Middleware |
|---|---|---|
| `cp-auth` (prio 100) | `Host(cp…) && (PathPrefix(/api/auth/signin) \|\| PathPrefix(/api/auth/callback))` | `crowdsec`, `security-headers`, **`ratelimit-login`** (10/menit/IP, burst 10) |
| `cp-login-action` (prio 90) | `Host(cp…) && Path(/login) && Method(POST)` | `crowdsec`, `security-headers`, **`ratelimit-login`** |
| `cp` (prio 1) | `Host(cp…)` — termasuk `/api/auth/{session,csrf,providers,signout}` | `crowdsec`, `security-headers`, `ratelimit-default` |

CSP **tidak** diset Traefik — aplikasi (`src/proxy.ts`) mengirim CSP dengan nonce per request. `security-headers`
hanya menambah HSTS (`max-age=300`, naik setelah QA), nosniff, `X-Frame-Options: DENY`, referrer & permissions policy.

**Ratelimit login dipersempit (H3, 2026-09-23).** Sebelumnya `ratelimit-login` berlaku untuk seluruh `/api/auth/*`,
termasuk `/api/auth/session` yang dipanggil klien saat navigasi/refresh sesi. Sekarang hanya:
- `/api/auth/signin*` — memulai alur OIDC (cookie state/PKCE/nonce + redirect ke Keycloak);
- `/api/auth/callback*` — menukar authorization code → token (request keluar ke Keycloak = amplifikasi);
- `POST /login` — tombol "Masuk" adalah Server Action (`src/app/actions.ts` `loginAction` → `signIn()` di server),
  **tidak** lewat `/api/auth/signin`; tanpa router ini alur login nyata hanya kena `ratelimit-default`.

`/api/auth/csrf` **tidak** diberi `ratelimit-login`: hanya token HMAC tanpa state server; provider satu-satunya
Keycloak OIDC (tidak ada Credentials provider) → tidak ada permukaan brute-force password di control plane.
Brute-force password ditangani Keycloak (`ratelimit-login` pada `/login-actions` + brute force detection realm).
Bucket rate limit per router: `cp-auth` (signin + callback bersama) dan `cp-login-action` terpisah.

Verifikasi (container uji `--network proxy --ip 10.100.0.250`, `--resolve cp.bimacreative.tech:443:<ip traefik>`):
15× `GET /api/auth/session` → 15× 200; 15× `GET /api/auth/csrf` → 15× 200; 15× `GET /api/auth/signin/keycloak` →
10× 302 lalu 5× 429; `GET /api/auth/callback/keycloak` berikutnya → 429 (bucket sama); 12× `POST /login` → 10× 200
lalu 2× 429; 15× `GET /login` → 15× 200.

## Deploy / upgrade

```bash
# 1) build tag baru dari commit main repo control-plane (context = git archive → tanpa file lokal/.env)
cd /opt/src/control-plane && git fetch && git checkout main && git pull --ff-only
TAG=$(git rev-parse --short=7 main)
git archive --format=tar main | docker build -t control-plane:$TAG \
  --label org.opencontainers.image.revision=$(git rev-parse main) -
# 2) pin tag baru di compose (default ${CONTROL_PLANE_TAG:-<tag>}) → commit di repo infra
cd /opt/infra/web/control-plane && sed -i "s/CONTROL_PLANE_TAG:-[0-9a-f]\{7\}/CONTROL_PLANE_TAG:-$TAG/" docker-compose.yml
docker compose config -q
# 3) migrasi (opsional terpisah — `up -d` juga menjalankannya) lalu recreate web+worker
docker compose run --rm --no-deps migrate
docker compose up -d
docker compose ps                # control-plane & control-plane-worker (healthy)
# 4) smoke
curl -sI https://cp.bimacreative.tech/ | grep -i -E '^HTTP|^location|content-security-policy'   # 307 → /login + CSP nonce
curl -s  https://cp.bimacreative.tech/api/auth/providers                                          # 200 JSON keycloak
```
Downtime saat recreate ± 5–10 s (satu replika). Perubahan `.env` → `docker compose up -d` (recreate).

## Rollback

Migrasi drizzle hanya maju — rollback image aman **selama migrasi baru bersifat additive** (cek `drizzle/` diff
sebelum upgrade; migrasi destruktif butuh backup DB `control_plane` dulu: `sudo systemctl start restic-backup.service`).
```bash
cd /opt/infra/web/control-plane
docker images control-plane                        # tag yang tersedia lokal
CONTROL_PLANE_TAG=<tag-lama> docker compose up -d  # cepat (sementara)
# permanen: kembalikan docker-compose.yml dari git (git checkout <rev> -- web/control-plane/) → docker compose up -d
```
Tag sebelumnya di host: `control-plane:0.1.0-scaffold` (build T12 dari `/opt/src`, image id `743e0032be51`). Jangan
`docker image prune` tag yang masih menjadi target rollback.

## Riwayat cutover T16a (2026-09-23)

- Sebelumnya container berjalan dari `/opt/src/control-plane/docker-compose.yml` (project `control-plane`, image
  `control-plane:0.1.0-scaffold`, internal saja). `.env` disalin (`install -m 600`, isi identik — `cmp`) ke
  `/opt/infra/web/control-plane/.env`.
- Urutan: `docker compose run --rm migrate` (stack baru, sukses) → stop+rm `web`/`worker` lama → `up -d` stack baru.
  Nama container sama (`control-plane`, `control-plane-worker`) sehingga target Traefik tidak berubah. Downtime internal
  ± 8 s (belum ada router publik saat itu). Stack lama: `docker compose ps -a` di `/opt/src/control-plane` kosong.
- **Jangan** menjalankan `docker compose up` di `/opt/src/control-plane` lagi — nama container bentrok (gagal) dan
  memakai `.env` lama. Compose di repo itu hanya untuk pengembangan lokal.
- Sertifikat: `le-http-staging` dulu (issuer `(STAGING)`), 307/200 terverifikasi, entri `cp` dihapus dari
  `acme-staging.json` (backup `acme-staging.json.bak-t16a-*`), resolver → `le-http`, restart Traefik → issuer
  `Let's Encrypt YE1`, `Verify return code: 0`.

## Verifikasi (2026-09-23)

- `GET /` → `307 location: /login`, header `content-security-policy: … 'nonce-…' 'strict-dynamic' …` (satu CSP, dari app).
- `GET /login` → 200, atribut `nonce="…"` di `<script>` cocok dengan header CSP.
- `GET /api/auth/providers` → 200 `{"keycloak":{…,"callbackUrl":"https://cp.bimacreative.tech/api/auth/callback/keycloak"}}`.
- `GET /api/auth/csrf` (cookie jar) → token 64 char; `POST /api/auth/signin/keycloak` (csrfToken + callbackUrl) →
  `302` ke `https://auth.bimacreative.tech/realms/platform/protocol/openid-connect/auth?response_type=code&client_id=control-plane&redirect_uri=…&code_challenge_method=S256&state=…&nonce=…`;
  cookie `__Host-authjs.csrf-token`, `__Secure-authjs.{state,nonce,pkce.code_verifier,callback-url}`.
- Halaman login Keycloak (URL di atas) → 200, `<title>Sign in to platform`.
- **NOT TESTABLE:** login end-to-end (callback → sesi → `/dashboard`) — belum ada user di realm `platform`
  (pembuatan user/role = keputusan user/Lead, di luar T16a).

## Belum / berikutnya

- Staging `cp.staging.bimacreative.tech` (T16 penuh): menunggu client Keycloak di realm `platform-staging`, DB/role
  `control_plane_staging` + `pg_hba`, `.env` staging.
- Image di registry (GHCR) + `infra-deploy` wrapper untuk user `deploy` (CLAUDE.md §3.7).
