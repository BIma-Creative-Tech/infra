| cid | job | start-end UTC | result | peak mem (cgroup, incl cache) | peak anon | oom_kill | max pids | /srv/ci used GiB min→max | max load1 | max iowait | log errors |
| f66ff65ef38e | gitleaks · semgrep · trivy fs · hadolint | 10:27:37–10:32:56 | Succeeded | 2.42 GiB | 0.17 GiB | 0 | 93 | 4.7→6.1 | 5.9 | 39 | - |
| a7b30f702007 | lint · typecheck · unit + coverage · openapi drift | 10:33:28–10:37:43 | Succeeded | 2.25 GiB | 1.16 GiB | 0 | 110 | 5.0→5.4 | 3.4 | 6 | - |
| 22946ff1ec99 | integration (throwaway Postgres, migrations as owner, tests as app role) | 10:38:21–10:56:33 | Succeeded | 2.23 GiB | 1.43 GiB | 0 | 212 | 5.4→6.2 | 4.6 | 40 | - |
| b3a6f23aea20 | analyze · format · codegen drift · tests | 10:57:12–11:06:57 | Succeeded | 4.00 GiB | 1.85 GiB | 0 | 110 | 6.0→7.9 | 4.6 | 30 | - |
| 740198e483bb | analyze · format · codegen drift · tests | 11:07:30–11:14:26 | Succeeded | 4.00 GiB | 2.06 GiB | 0 | 109 | 7.9→7.9 | 5.8 | 15 | - |
| ff829b03bd38 | build APKs (staging) | 11:14:58–11:29:46 | Failed | 4.00 GiB | 3.37 GiB | 1 | 200 | 7.9→11.8 | 4.7 | 37 | - |
| 2acccaa179de | gitleaks · semgrep · trivy fs · hadolint | 11:30:21–11:32:12 | Succeeded | 3.82 GiB | 0.49 GiB | 0 | 90 | 11.8→13.3 | 3.4 | 40 | - |
| abee493364a7 | integration (throwaway Postgres, migrations as owner, tests as app role) | 11:32:45–11:51:00 | Succeeded | 3.37 GiB | 1.24 GiB | 0 | 213 | 11.8→12.0 | 4.7 | 11 | - |
| 31b76c0f635a | image build (runner + migrate) · trivy · GHCR push | 11:51:41–11:52:16 | Failed | 0.29 GiB | 0.13 GiB | 0 | 70 | 11.8→11.8 | 4.2 | 0 | - |
| 296c6cd41a31 | lint · typecheck · unit + coverage · openapi drift | 11:52:49–11:55:21 | Succeeded | 2.49 GiB | 1.33 GiB | 0 | 112 | 11.8→11.8 | 3.1 | 0 | - |
| 33e0767acbbe | build APKs (staging) | 11:56:01–12:16:22 | Succeeded | 4.00 GiB | 3.53 GiB | 0 | 202 | 11.8→14.5 | 7.2 | 64 | - |
| 01c8dd883995 | image build (runner + migrate) · trivy · GHCR push | 12:16:59–12:24:31 | Succeeded | 4.00 GiB | 1.76 GiB | 0 | 164 | 14.5→19.4 | 5.8 | 37 | - |
| b5e6fa90d130 | None | – | None | 0.08 GiB | 0.06 GiB | 0 | 40 | 19.2→19.2 | 2.2 | 0 | - |

| target | idle n | idle p50 | idle p95 | busy n | busy p50 | busy p95 | p95 ratio | non-2xx/3xx busy |
| kas | 45 | 0.040 | 0.051 | 210 | 0.043 | 0.096 | 1.90x | 0 |
| erp | 45 | 0.064 | 0.084 | 210 | 0.069 | 0.145 | 1.72x | 0 |
| cp | 45 | 0.046 | 0.061 | 210 | 0.050 | 0.095 | 1.58x | 0 |

swap used KiB min/max: 1992588/2032524; host MemAvailable min: 7256 MiB; drops first/last: 12/12
