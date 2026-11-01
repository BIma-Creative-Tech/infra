<?php
// Webmail bimacreative.tech — override konfigurasi Roundcube 1.7.4 (ADR 0012 §Revisi 2026-10-25). Salinan pola
// ../../config/webmail.inc.php (instance Expomedia; nama opsi diverifikasi di sana dari config/defaults.inc.php dan
// plugins/password/* image 1.7.4-apache-nonroot). Beda: host mail, domain login, daftar akun teknis, nama produk.
// TIDAK ada secret di file ini: des_key dari /run/secrets/roundcube_des_key (entrypoint; file SENDIRI per instance), token
// helper dari /run/secrets/pwhelper_token.

// --- IMAP / SMTP: mail.bimacreative.tech = sertifikat default DMS (ADR 0005 #5) → di-resolve ke 10.100.16.2 (extra_hosts,
//     network internal webmail-mail). Verifikasi sertifikat AKTIF (CA sistem + nama host + SNI).
$config['imap_host'] = 'ssl://mail.bimacreative.tech:993';
$config['smtp_host'] = 'tls://mail.bimacreative.tech:587';
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$webmail_tls = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        'peer_name'         => 'mail.bimacreative.tech',
        'allow_self_signed' => false,
        'SNI_enabled'       => true,
        'cafile'            => '/etc/ssl/certs/ca-certificates.crt',
    ],
];
$config['imap_conn_options'] = $webmail_tls;
$config['smtp_conn_options'] = $webmail_tls;
unset($webmail_tls);

// --- Login: HANYA @bimacreative.tech. Filter dievaluasi pada input mentah SEBELUM domain ditambahkan → menerima "ade" atau
//     "ade@bimacreative.tech"; domain lain → "login gagal" tanpa koneksi IMAP. Akun teknis/sistem DITOLAK (keputusan
//     2026-10-25, konsisten dengan instance Expomedia yang menolak noreply@/postmaster@/dmarc@):
//       - postmaster@ (penerima alert/abuse@ alias), dmarc@ (rua DMARC), abuse@ (alias), alerts@ (pengirim infra-healthcheck)
//       - semua local-part berakhiran noreply / no-reply: no-reply@ (SMTP DRMS), auth-noreply@ (SMTP Keycloak),
//         drms-noreply@, noreply@ (SMTP_FROM control-plane staging)
$config['login_username_filter'] = '/^(?!(postmaster|dmarc|abuse|alerts)(@|$))(?![a-z0-9._-]*no-?reply(@|$))[a-z0-9][a-z0-9._-]{0,63}(@bimacreative\.tech)?$/i';
$config['username_domain'] = 'bimacreative.tech';
$config['username_domain_forced'] = true;
$config['login_lc'] = 2;
$config['login_username_maxlen'] = 80;
$config['login_password_maxlen'] = 128;
$config['login_rate_limit'] = 3;          // gagal login per menit per user (rcube_user) — di atas rate-limit Traefik per IP
$config['login_autocomplete'] = 1;        // username saja
$config['log_logins'] = true;             // log login sukses/gagal + IP asli (proxy_whitelist) ke stdout

// --- Sesi & proxy
$config['session_lifetime'] = 30;         // menit tidak aktif
$config['session_samesite'] = 'Lax';
$config['ip_check'] = true;
$config['use_https'] = true;              // TLS di Traefik; force_https eksklusif dengan use_https → off
$config['force_https'] = false;
$config['proxy_whitelist'] = ['10.100.15.0/24'];   // webmail-edge: Traefik + container webmail (subnet --internal)
$config['trusted_host_patterns'] = ['webmail\.bimacreative\.tech'];  // healthcheck mengirim Host yang sama
$config['x_frame_options'] = 'sameorigin';   // pratinjau pesan = iframe same-origin
$config['cipher_method'] = 'AES-256-CBC'; // des_key 32 char (scripts/bootstrap.sh)
$config['enable_installer'] = false;

// --- Tampilan
$config['product_name'] = 'Webmail Bima Creative';
$config['display_product_info'] = 1;      // nama saja, tanpa versi
$config['useragent'] = 'Webmail Bima Creative';   // tanpa versi Roundcube di header mail keluar
$config['language'] = 'id_ID';
$config['skin'] = 'elastic';
$config['support_url'] = '';
$config['enable_spellcheck'] = false;

// --- Pengiriman: satu identitas, alamat tidak bisa diubah (cegah From palsu; SPOOF_PROTECTION DMS tetap berlaku).
$config['identities_level'] = 3;
$config['max_message_size'] = '10M';      // DMS message_size_limit 10240000
$config['max_recipients'] = 50;
$config['max_group_members'] = 50;
$config['sendmail_delay'] = 5;

// --- Plugin (minimal)
$config['plugins'] = ['archive', 'zipdownload', 'password'];

// --- Ganti password self-service → helper `pwhelper` di mailserver (ADR 0012). Helper memverifikasi ulang password lama,
//     allowlist alamat (mail/config/pwhelper/allowlist.txt), kebijakan, rate limit; Roundcube hanya lapisan UX.
$config['password_driver'] = 'httpapi';
$config['password_confirm_current'] = true;
$config['password_minimum_length'] = 10;
$config['password_force_save'] = false;
$config['password_log'] = true;           // "Password changed for user … from <ip>" (tanpa password)
$config['password_disabled'] = false;     // kill switch UI: isi teks alasan, lalu recreate container ini
// Sabuk pengaman: akun teknis sudah ditolak login_username_filter; daftar ini menyembunyikan tab Password bila filter diubah.
$config['password_login_exceptions'] = [
    'postmaster@bimacreative.tech', 'dmarc@bimacreative.tech', 'abuse@bimacreative.tech', 'alerts@bimacreative.tech',
    'noreply@bimacreative.tech', 'no-reply@bimacreative.tech', 'auth-noreply@bimacreative.tech',
    'drms-noreply@bimacreative.tech',
];
$config['password_httpapi_url'] = 'http://10.100.16.2:8080/change';
$config['password_httpapi_method'] = 'POST';
$config['password_httpapi_var_user'] = 'user';
$config['password_httpapi_var_curpass'] = 'curpass';
$config['password_httpapi_var_newpass'] = 'newpass';
$config['password_httpapi_expect'] = '/^ok$/';
$config['password_http_client'] = [
    'timeout'         => 60,
    'connect_timeout' => 5,
    'allow_redirects' => false,
    'http_errors'     => false,   // 4xx helper → PASSWORD_ERROR (pesan umum), bukan CONNECT_ERROR yang menyesatkan
    'headers'         => ['Authorization' => 'Bearer ' . trim((string) @file_get_contents('/run/secrets/pwhelper_token'))],
];
