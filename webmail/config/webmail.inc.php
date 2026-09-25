<?php
// Webmail Expomedia — override konfigurasi Roundcube 1.7.4 (ADR 0012, plan 08). Di-mount ro ke /var/roundcube/config/;
// entrypoint image (docker-entrypoint.sh) meng-include semua /var/roundcube/config/*.php DI AKHIR config.docker.inc.php,
// sehingga nilai di sini menimpa nilai dari env ROUNDCUBEMAIL_*. Nama opsi diverifikasi dari config/defaults.inc.php dan
// plugins/password/{config.inc.php.dist,password.php,drivers/httpapi.php} di image roundcube/roundcubemail:1.7.4-apache-nonroot.
// TIDAK ada secret di file ini: des_key dari /run/secrets/roundcube_des_key (entrypoint), token helper dari
// /run/secrets/pwhelper_token.

// --- IMAP / SMTP: nama sertifikat mail.expomedia.id (ADR 0011, SNI) → di-resolve ke 10.100.16.2 (extra_hosts, network
//     internal webmail-mail). Verifikasi sertifikat AKTIF (CA sistem + nama host).
$config['imap_host'] = 'ssl://mail.expomedia.id:993';
$config['smtp_host'] = 'tls://mail.expomedia.id:587';
$config['smtp_user'] = '%u';
$config['smtp_pass'] = '%p';
$webmail_tls = [
    'ssl' => [
        'verify_peer'       => true,
        'verify_peer_name'  => true,
        'peer_name'         => 'mail.expomedia.id',
        'allow_self_signed' => false,
        'SNI_enabled'       => true,
        'cafile'            => '/etc/ssl/certs/ca-certificates.crt',
    ],
];
$config['imap_conn_options'] = $webmail_tls;
$config['smtp_conn_options'] = $webmail_tls;
unset($webmail_tls);

// --- Login: HANYA @expomedia.id. Filter dievaluasi pada input mentah SEBELUM domain ditambahkan (rcmail::login →
//     login_input_checks), jadi menerima "sales" atau "sales@expomedia.id"; domain lain & noreply@ (akun teknis form kontak)
//     → "login gagal" tanpa koneksi IMAP. username_domain_forced = sabuk pengaman kedua (domain lain diganti expomedia.id).
$config['login_username_filter'] = '/^(?!noreply(@|$))[a-z0-9][a-z0-9._-]{0,63}(@expomedia\.id)?$/i';
$config['username_domain'] = 'expomedia.id';
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
$config['use_https'] = true;              // TLS di Traefik; force_https eksklusif dengan use_https (defaults.inc.php) → off
$config['force_https'] = false;
$config['proxy_whitelist'] = ['10.100.15.0/24'];   // webmail-edge: hanya Traefik (+ webmail sendiri)
$config['trusted_host_patterns'] = ['webmail\.expomedia\.id'];  // healthcheck mengirim Host yang sama
$config['x_frame_options'] = 'sameorigin';   // pratinjau pesan = iframe same-origin (#messagecontframe); DENY merusaknya
$config['cipher_method'] = 'AES-256-CBC'; // des_key 32 char (webmail/scripts/bootstrap.sh)
$config['enable_installer'] = false;

// --- Tampilan
$config['product_name'] = 'Webmail Expomedia';
$config['display_product_info'] = 1;      // nama saja, tanpa versi
$config['useragent'] = 'Webmail Expomedia';   // tanpa versi Roundcube di header mail keluar
$config['language'] = 'id_ID';
$config['skin'] = 'elastic';
$config['support_url'] = '';
$config['enable_spellcheck'] = false;

// --- Pengiriman: satu identitas, alamat tidak bisa diubah (cegah From palsu; SPOOF_PROTECTION DMS tetap berlaku).
$config['identities_level'] = 3;
$config['max_message_size'] = '10M';      // DMS message_size_limit 10240000 (docs/clients/expomedia.md §6)
$config['max_recipients'] = 50;
$config['max_group_members'] = 50;
$config['sendmail_delay'] = 5;

// --- Plugin (minimal)
$config['plugins'] = ['archive', 'zipdownload', 'password'];

// --- Ganti password self-service → helper `pwhelper` di mailserver (ADR 0012). Helper memverifikasi ulang password lama,
//     allowlist alamat, kebijakan, rate limit; Roundcube hanya lapisan UX.
$config['password_driver'] = 'httpapi';
$config['password_confirm_current'] = true;
$config['password_minimum_length'] = 10;
$config['password_force_save'] = false;
$config['password_log'] = true;           // "Password changed for user … from <ip>" (tanpa password)
$config['password_disabled'] = false;     // kill switch UI: isi teks alasan, lalu recreate webmail
$config['password_login_exceptions'] = ['noreply@expomedia.id', 'postmaster@expomedia.id', 'dmarc@expomedia.id'];
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
    'http_errors'     => false,   // 4xx helper → PASSWORD_ERROR ("Tidak dapat menyimpan sandi baru."), bukan pengecualian
                                  // Guzzle → CONNECT_ERROR ("… Koneksi error.") yang menyesatkan (drivers/httpapi.php)
    'headers'         => ['Authorization' => 'Bearer ' . trim((string) @file_get_contents('/run/secrets/pwhelper_token'))],
];
