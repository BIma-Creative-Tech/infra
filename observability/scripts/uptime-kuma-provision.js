// Provisioning awal Uptime Kuma 2.5.5 (T14a) — idempoten. Dijalankan oleh
// scripts/uptime-kuma-provision.sh di container sementara dari image Uptime Kuma yang sama
// (socket.io-client ada di /app/node_modules), network `proxy`, langsung ke http://uptime-kuma:3001
// (tanpa lewat Traefik). Event socket.io diverifikasi dari source image 2.5.5:
//   server/server.js: "setup"(username, password, cb), "login"({username,password,token}, cb),
//                     "add"(monitor, cb), event server→client "monitorList"
//   server/socket-handlers/status-page-socket-handler.js: "addStatusPage"(title, slug, cb),
//                     "saveStatusPage"(slug, config, imgDataUrl, publicGroupList, cb)
// Monitor = objek default src/pages/EditMonitor.vue `monitorDefaults` + override per monitor.
"use strict";
const fs = require("fs");
const { io } = require("/app/node_modules/socket.io-client");

const URL = "http://uptime-kuma:3001";
const USERNAME = "platform-admin";
const PASSWORD = fs.readFileSync("/run/secrets/uptime-kuma-admin-password", "utf8").trim();
const SLUG = "platform";
const STATUS_HOST = "status.bimacreative.tech";

const MONITORS = [
  { name: "Control plane (cp)", url: "https://cp.bimacreative.tech/" },
  { name: "Keycloak OIDC discovery (platform)", url: "https://auth.bimacreative.tech/realms/platform/.well-known/openid-configuration" },
  { name: "Odoo demo (prod pool)", url: "https://demo.erp.bimacreative.tech/web/health" },
  { name: "Odoo demo (staging pool)", url: "https://demo.staging.bimacreative.tech/web/health" },
];

const monitorDefaults = {
  type: "http", parent: null, wsSubprotocol: "", method: "GET", protocol: null, location: "world",
  ipFamily: null, interval: 60, retryInterval: 60, resendInterval: 0, maxretries: 2,
  retryOnlyOnStatusCodeFailure: false, notificationIDList: {}, ignoreTls: false, upsideDown: false,
  expiryNotification: true, domainExpiryNotification: false, maxredirects: 10,
  accepted_statuscodes: ["200-299"], saveResponse: false, saveErrorResponse: true, responseMaxLength: 1024,
  dns_resolve_type: "A", dns_resolve_server: "", docker_container: "", docker_host: null, proxyId: null,
  basic_auth_user: "", basic_auth_pass: "", bearer_token: "", mqttUsername: "", mqttPassword: "",
  mqttTopic: "", mqttWebsocketPath: "", mqttSuccessMessage: "", mqttCheckType: "keyword", authMethod: null,
  oauth_auth_method: "client_secret_basic", httpBodyEncoding: "json", kafkaProducerBrokers: [],
  kafkaProducerSaslOptions: { mechanism: "None" }, cacheBust: false, kafkaProducerSsl: false,
  kafkaProducerAllowAutoTopicCreation: false, gamedigGivenPortOnly: true, gamedigToken: "",
  remote_browser: null, screenshot_delay: 0, rabbitmqNodes: [], rabbitmqUsername: "", rabbitmqPassword: "",
  conditions: [], system_service_name: "", sshAuthMethod: "password", ntpStratumThreshold: 5,
  ntpTimeOffsetThreshold: 1000, ntpRootDispersionThreshold: 500,
};

const socket = io(URL, { transports: ["websocket"], reconnection: false, timeout: 10000 });
const emit = (ev, ...args) => new Promise((resolve) => socket.emit(ev, ...args, resolve));
let monitorList = null;
let needSetup = false;
// Didaftarkan SEBELUM connect: server mengirim "setup" segera di handler "connection".
socket.on("setup", () => { needSetup = true; });
socket.on("monitorList", (list) => { monitorList = list; });
const waitFor = async (fn, ms = 10000) => {
  const t0 = Date.now();
  while (!fn()) { if (Date.now() - t0 > ms) throw new Error("timeout"); await new Promise((r) => setTimeout(r, 200)); }
};
const fail = (msg) => { console.error("GAGAL:", msg); process.exit(1); };

socket.on("connect_error", (e) => fail("connect: " + e.message));
socket.on("connect", async () => {
  try {
    await new Promise((r) => setTimeout(r, 1000));
    if (needSetup) {
      const r = await emit("setup", USERNAME, PASSWORD);
      if (!r.ok) fail("setup: " + r.msg);
      console.log("admin dibuat:", USERNAME);
    } else {
      console.log("admin sudah ada (setup dilewati)");
    }
    const login = await emit("login", { username: USERNAME, password: PASSWORD, token: "" });
    if (!login.ok) fail("login: " + login.msg);
    await waitFor(() => monitorList !== null);

    const existing = Object.values(monitorList);
    const ids = [];
    for (const m of MONITORS) {
      const found = existing.find((e) => e.name === m.name);
      if (found) { console.log("monitor ada:", m.name, "id", found.id); ids.push(found.id); continue; }
      const r = await emit("add", { ...monitorDefaults, ...m });
      if (!r.ok) fail("add " + m.name + ": " + r.msg);
      console.log("monitor dibuat:", m.name, "id", r.monitorID);
      ids.push(r.monitorID);
    }

    const add = await emit("addStatusPage", "Status Platform", SLUG);
    if (add.ok) console.log("status page dibuat:", SLUG);
    else console.log("status page:", add.msg, "(dilanjutkan: simpan konfigurasi)");

    const config = {
      slug: SLUG, title: "Status Platform", description: "Status layanan platform bimacreative.tech",
      autoRefreshInterval: 300, theme: "auto", showTags: false, footerText: "", customCSS: "",
      showPoweredBy: false, rssTitle: "", showOnlyLastHeartbeat: false, showCertificateExpiry: false,
      analyticsId: null, analyticsScriptUrl: null, analyticsType: null,
      // Host ini → `/` langsung menampilkan status page (server.js: request.hostname in domainMappingList).
      domainNameList: [STATUS_HOST],
    };
    const groups = [{ name: "Layanan", monitorList: ids.map((id) => ({ id })) }];
    const save = await emit("saveStatusPage", SLUG, config, "/icon.svg", groups);
    if (!save.ok) fail("saveStatusPage: " + save.msg);
    console.log("status page disimpan:", SLUG, "monitor", ids.join(","), "domain", STATUS_HOST);
    socket.close();
    process.exit(0);
  } catch (e) {
    fail(e.message);
  }
});
