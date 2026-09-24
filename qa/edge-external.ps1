# Uji edge dari LUAR VPS (T17a — kontrol yang NOT TESTABLE dari host). Non-destruktif.
# Jalankan di Windows PowerShell 5.1+/7 (butuh curl.exe bawaan Windows 10+):
#   powershell -ExecutionPolicy Bypass -File .\edge-external.ps1
# Catatan: 2 payload AppSec dapat memicu ban CrowdSec untuk IP Anda — sejak H6 (2026-09-23) ban AppSec hanya
# berlaku di HTTP (bouncer Traefik), TIDAK memblok SSH 2221. Setelah selesai, beri tahu Lead — ban (bila ada)
# dihapus dari sisi VPS.
$ErrorActionPreference = 'Continue'
$PassCount = 0; $FailCount = 0   # PowerShell: nama variabel tidak peka huruf besar/kecil — jangan pakai $P/$p
function Check($name, $ok, $detail) {
  if ($ok) { $script:PassCount++; Write-Host "PASS  $name ($detail)" -ForegroundColor Green }
  else     { $script:FailCount++; Write-Host "FAIL  $name ($detail)" -ForegroundColor Red }
}
function Code($url, [string[]]$extra = @()) {
  $c = & curl.exe -s -o NUL -m 15 -w "%{http_code}" @extra $url
  if (-not $c) { '000' } else { $c }
}
$erp = 'https://demo.erp.bimacreative.tech'; $stg = 'https://demo.staging.bimacreative.tech'
$kc  = 'https://auth.bimacreative.tech'

# 1. Transport & header
$c = Code 'http://demo.erp.bimacreative.tech/web/login'; Check 'http -> https redirect' ($c -in '301','308') $c
$c = Code "$erp/web/login"; Check 'Odoo prod login page' ($c -eq '200') $c
$h = (& curl.exe -s -I -m 15 "$erp/web/login") -join "`n"
Check 'HSTS header'              ($h -match '(?im)^strict-transport-security:') 'HEAD'
Check 'X-Content-Type-Options'   ($h -match '(?im)^x-content-type-options:\s*nosniff') 'HEAD'
Check 'Referrer-Policy'          ($h -match '(?im)^referrer-policy:') 'HEAD'
$c = Code "$erp/web/login" @('--tlsv1.1','--tls-max','1.1'); Check 'TLS 1.1 ditolak' ($c -eq '000') $c
$c = Code "$erp/web/login" @('--tlsv1.2','--tls-max','1.2'); Check 'TLS 1.2 diterima' ($c -eq '200') $c

# 2. Panel admin tidak publik
foreach ($path in '/admin/', '/realms/master/', '/') { $c = Code "$kc$path"; Check "Keycloak $path ditutup" ($c -in '403','404') $c }   # H5: / tidak dirutekan di 443 (404)
$c = Code "$kc/realms/platform/.well-known/openid-configuration"; Check 'Keycloak OIDC discovery' ($c -eq '200') $c
$c = Code 'https://31.97.50.221/dashboard/' @('-k'); Check 'Traefik dashboard tidak ada' ($c -eq '404') $c
foreach ($path in '/web/database/manager', '/web/database/selector') { $c = Code "$erp$path"; Check "Odoo $path ditutup" ($c -eq '403') $c }
$c = Code 'https://tidakada.erp.bimacreative.tech/' @('-k'); Check 'Host tak dikenal -> 404' ($c -eq '404') $c   # -k: host tak dikenal tidak punya sertifikat LE

# 3. Isolasi tenant (DB staging tidak bisa dipilih dari host prod)
$body = '{"jsonrpc":"2.0","method":"call","params":{"db":"demo_staging","login":"x","password":"y"}}'
try {
  $r = Invoke-WebRequest -UseBasicParsing -Method Post -Uri "$erp/web/session/authenticate" -ContentType 'application/json' -Body $body `
       -Headers @{ 'X-Sh-Odoo-Db' = 'demo_staging'; 'X-Odoo-Database' = 'demo_staging' }
  Check 'Tenant crossing ditolak' ($r.Content -match 'Database not found') 'authenticate'
} catch { Check 'Tenant crossing ditolak' $false $_.Exception.Message }

# 4. Port yang harus tertutup / terbuka
foreach ($port in 22, 5432, 8069, 8080) {
  $o = Test-NetConnection 31.97.50.221 -Port $port -WarningAction SilentlyContinue
  Check "Port $port tertutup" (-not $o.TcpTestSucceeded) $o.TcpTestSucceeded
}
$o = Test-NetConnection 31.97.50.221 -Port 2221 -WarningAction SilentlyContinue; Check 'Port 2221 (SSH) terbuka' $o.TcpTestSucceeded $o.TcpTestSucceeded

# 5. Rate limit login (12 request ringan ke STAGING)
$codes = 1..12 | ForEach-Object { Code "$stg/web/login" }
Check 'Rate limit login -> 429' ($codes -contains '429') (($codes | Group-Object | ForEach-Object { "$($_.Name)x$($_.Count)" }) -join ' ')

# 6. WAF AppSec (2 payload saja) + kontrol false positive
$c = Code "$stg/web/health?q=hello"; Check 'Request normal lolos WAF' ($c -eq '200') $c   # bukan /web/login: bucket ratelimit-login baru saja dihabiskan uji sebelumnya
$c = Code "$stg/web/login?q=%3Cscript%3Ealert(1)%3C%2Fscript%3E"; Check 'XSS diblok WAF' ($c -eq '403') $c
$c = Code "$stg/.env"; Check '/.env diblok' ($c -eq '403') $c

# 7. Tombol "Masuk" control plane = Server Action Next.js (H6): 1 GET + 1 POST sah (text/plain + Next-Action).
#    Request sah tidak menghasilkan alert AppSec; bila regresi → 1× 403 (di bawah ambang ban appsec-native).
$cp = 'https://cp.bimacreative.tech'
$html = (& curl.exe -s -m 15 "$cp/login") -join "`n"
if ($html -match '\$ACTION_ID_([0-9a-f]{40,64})') {
  $aid = $Matches[1]
  $hdr = (& curl.exe -s -m 15 -o NUL -D - -X POST "$cp/login" -H "Next-Action: $aid" -H 'Content-Type: text/plain;charset=UTF-8' `
          -H "Origin: $cp" -H 'Accept: text/x-component' --data '[]') -join "`n"
  Check 'Tombol Masuk cp -> redirect Keycloak' ($hdr -match '(?im)^x-action-redirect:\s*https://auth\.bimacreative\.tech/realms/platform/') (($hdr -split "`n")[0])
} else { Check 'Tombol Masuk cp -> redirect Keycloak' $false 'action id tidak ditemukan di /login' }

Write-Host "`nRINGKASAN: PASS=$PassCount FAIL=$FailCount" -ForegroundColor Cyan
