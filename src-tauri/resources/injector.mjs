import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const scriptPath = fileURLToPath(import.meta.url);
const here = path.dirname(scriptPath);
const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);
const BROWSER_ID_PATTERN = /^[A-Za-z0-9._-]{1,200}$/;

// --- Argument parsing ---
function parseArgs(argv) {
  const options = { port: 9335, browserId: null, mode: "watch", timeoutMs: 30000 };
  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--port") options.port = Number(argv[++i]);
    else if (arg === "--browser-id") options.browserId = argv[++i];
    else if (arg === "--watch") options.mode = "watch";
    else if (arg === "--once") options.mode = "once";
    else if (arg === "--timeout-ms") options.timeoutMs = Number(argv[++i]);
    else throw new Error(`Unknown argument: ${arg}`);
  }
  if (!Number.isInteger(options.port) || options.port < 1024 || options.port > 65535) {
    throw new Error(`Invalid port: ${options.port}`);
  }
  if (!options.browserId || !BROWSER_ID_PATTERN.test(options.browserId)) {
    throw new Error("Missing or invalid --browser-id");
  }
  return options;
}

// --- Security: CDP URL validation ---
function validatedDebuggerUrl(target, port) {
  const url = new URL(target.webSocketDebuggerUrl);
  const pathIsValid = /^\/devtools\/(?:page|browser)\/[A-Za-z0-9._-]{1,200}$/.test(url.pathname);
  if (url.protocol !== "ws:" || !LOOPBACK_HOSTS.has(url.hostname) || Number(url.port) !== port ||
      url.username || url.password || url.search || url.hash || !pathIsValid) {
    throw new Error("Rejected a CDP WebSocket URL outside the allowed loopback endpoint shape");
  }
  return url.href;
}

function browserIdFromVersion(version, port) {
  const url = validatedDebuggerUrl(version, port);
  const parsed = new URL(url);
  const match = parsed.pathname.match(/^\/devtools\/browser\/([A-Za-z0-9._-]{1,200})$/);
  if (!match || parsed.search || parsed.hash || !BROWSER_ID_PATTERN.test(match[1])) {
    throw new Error("Rejected an invalid CDP browser identity URL");
  }
  return match[1];
}

function isValidCdpPageTarget(item, port) {
  if (item?.type !== "page" || !item.url?.startsWith("app://") || typeof item.id !== "string" ||
      !BROWSER_ID_PATTERN.test(item.id) || !item.webSocketDebuggerUrl) return false;
  try {
    const debuggerUrl = new URL(validatedDebuggerUrl(item, port));
    return debuggerUrl.pathname === `/devtools/page/${item.id}`;
  } catch {
    return false;
  }
}

// --- CDP JSON helpers ---
async function fetchCdpJson(port, resource) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 2000);
  try {
    const response = await fetch(`http://127.0.0.1:${port}${resource}`, {
      redirect: "error",
      signal: controller.signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    return await response.json();
  } finally {
    clearTimeout(timeout);
  }
}

async function listAppTargets(port, expectedBrowserId) {
  const targets = await fetchCdpJson(port, "/json/list");
  if (!Array.isArray(targets)) throw new Error("CDP target list is not an array");
  if (expectedBrowserId) {
    const version = await fetchCdpJson(port, "/json/version");
    const actualBrowserId = browserIdFromVersion(version, port);
    if (actualBrowserId !== expectedBrowserId) {
      throw new Error(`CDP browser identity changed from ${expectedBrowserId} to ${actualBrowserId}`);
    }
  }
  return targets.filter((item) => isValidCdpPageTarget(item, port));
}

// --- CDP Session ---
class CdpSession {
  constructor(target, port) {
    this.target = target;
    this.ws = new WebSocket(validatedDebuggerUrl(target, port));
    this.nextId = 1;
    this.pending = new Map();
    this.listeners = new Map();
    this.closed = false;
  }

  async open() {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        try { this.ws.close(); } catch { /* ignore */ }
        reject(new Error("CDP WebSocket open timed out"));
      }, 5000);
      this.ws.addEventListener("open", () => { clearTimeout(timeout); resolve(); }, { once: true });
      this.ws.addEventListener("error", () => { clearTimeout(timeout); reject(new Error("CDP WebSocket open failed")); }, { once: true });
    });
    this.ws.addEventListener("message", (event) => this.onMessage(event));
    this.ws.addEventListener("error", () => this.close());
    this.ws.addEventListener("close", () => {
      this.closed = true;
      for (const waiter of this.pending.values()) {
        clearTimeout(waiter.timeout);
        waiter.reject(new Error("CDP socket closed"));
      }
      this.pending.clear();
    });
    await this.send("Runtime.enable");
    await this.send("Page.enable");
    return this;
  }

  onMessage(event) {
    let message;
    try { message = JSON.parse(String(event.data)); } catch { return; }
    if (!message || typeof message !== "object") return;
    if (message.id) {
      const waiter = this.pending.get(message.id);
      if (!waiter) return;
      clearTimeout(waiter.timeout);
      this.pending.delete(message.id);
      if (message.error) waiter.reject(new Error(`${message.error.message} (${message.error.code})`));
      else waiter.resolve(message.result);
      return;
    }
    for (const listener of this.listeners.get(message.method) ?? []) listener(message.params ?? {});
  }

  on(method, listener) {
    const listeners = this.listeners.get(method) ?? [];
    listeners.push(listener);
    this.listeners.set(method, listeners);
  }

  send(method, params = {}) {
    if (this.closed) return Promise.reject(new Error("CDP session is closed"));
    return new Promise((resolve, reject) => {
      const id = this.nextId++;
      const timeout = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP command timed out: ${method}`));
      }, 10000);
      this.pending.set(id, { resolve, reject, timeout });
      try {
        this.ws.send(JSON.stringify({ id, method, params }));
      } catch (error) {
        clearTimeout(timeout);
        this.pending.delete(id);
        reject(error);
      }
    });
  }

  async evaluate(expression) {
    const result = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
      userGesture: false,
    });
    if (result.exceptionDetails) {
      const detail = result.exceptionDetails.exception?.description ?? result.exceptionDetails.text;
      throw new Error(`Renderer evaluation failed: ${detail}`);
    }
    return result.result?.value;
  }

  close() {
    for (const waiter of this.pending.values()) {
      clearTimeout(waiter.timeout);
      waiter.reject(new Error("CDP session closed"));
    }
    this.pending.clear();
    if (!this.closed) {
      try { this.ws.close(); } catch { /* ignore */ }
    }
    this.closed = true;
  }
}

// --- Probe & inject ---
async function probeSession(session) {
  return session.evaluate(`(() => {
    const markers = {
      shell: Boolean(document.querySelector('main.main-surface')),
      sidebar: Boolean(document.querySelector('aside.app-shell-left-panel')),
      main: Boolean(document.querySelector('[role="main"]')),
    };
    return {
      markers,
      codex: location.protocol === 'app:' && (markers.shell || markers.main),
    };
  })()`);
}

async function waitForCodexProbe(session, timeoutMs = 1800) {
  const deadline = Date.now() + timeoutMs;
  let probe = null;
  while (Date.now() < deadline) {
    try {
      probe = await probeSession(session);
      if (probe?.codex) return probe;
    } catch { /* renderer may be between documents */ }
    await new Promise((resolve) => setTimeout(resolve, 50));
  }
  return probe;
}

async function loadInjectScript() {
  const scriptPath = path.join(here, "inject.js");
  return fs.readFile(scriptPath, "utf8");
}

async function applyToSession(session, script) {
  return session.evaluate(script);
}

function quotaExpression(quota) {
  return `window.__CODEX_METER_STATE__?.setQuota(${JSON.stringify(quota)})`;
}

async function applyQuotaToSession(session, quota) {
  if (!quota || session.closed) return;
  await session.evaluate(quotaExpression(quota));
}

function parseControlLine(line) {
  const normalized = line.trim();
  if (!normalized) return null;
  if (normalized.toLowerCase() === "shutdown") return { type: "shutdown" };

  const message = JSON.parse(normalized);
  if (message?.type === "shutdown") return { type: "shutdown" };
  if (message?.type !== "quota") return null;
  return {
    type: "quota",
    status: typeof message.status === "string" ? message.status : "unavailable",
    percent: typeof message.percent === "number" && Number.isFinite(message.percent)
      ? Math.min(100, Math.max(0, message.percent))
      : null,
    resetsAt: typeof message.resetsAt === "string" ? message.resetsAt : null,
  };
}

function earlyPayloadFor(script) {
  return `(() => {
    const key = "__CODEX_METER_EARLY__";
    if (window[key]) return;
    window[key] = true;
    let observer = null;
    let timeout = null;
    const stop = () => { observer?.disconnect(); observer = null; if (timeout) clearTimeout(timeout); };
    const install = () => {
      if (!document.body) return false;
      stop();
      ${script}
      return true;
    };
    if (install()) return;
    if (typeof MutationObserver === "function" && document.documentElement) {
      observer = new MutationObserver(install);
      observer.observe(document.documentElement, { childList: true, subtree: true });
    }
    timeout = setTimeout(stop, 10000);
  })()`;
}

async function registerEarlyPayload(session, script) {
  const result = await session.send("Page.addScriptToEvaluateOnNewDocument", {
    source: earlyPayloadFor(script),
  });
  return result.identifier ?? null;
}

async function removeEarlyPayload(session, identifier) {
  if (!identifier || session.closed) return;
  await session.send("Page.removeScriptToEvaluateOnNewDocument", { identifier }).catch(() => {});
}

const CLEANUP_EXPRESSION = `(() => {
  const state = window.__CODEX_METER_STATE__;
  if (typeof state?.dispose === "function") {
    state.dispose();
    return true;
  }
  state?.observer?.disconnect();
  if (state?.timer) clearInterval(state.timer);
  if (state?.ensureTimer) clearInterval(state.ensureTimer);
  state?.cancelScheduledUpdate?.();
  document.querySelectorAll("#codex-meter-widget").forEach((element) => element.remove());
  delete window.__CODEX_METER_STATE__;
  return true;
})()`;

async function removeWidget(session) {
  if (session.closed) return;
  // Sweep more than once so an already-queued renderer callback cannot
  // re-attach a detached host after the first cleanup evaluation.
  for (let attempt = 0; attempt < 3; attempt += 1) {
    await session.evaluate(CLEANUP_EXPRESSION);
    if (attempt < 2) await new Promise((resolve) => setTimeout(resolve, 150));
  }
}

// --- Connect helpers ---
async function connectTarget(target, port) {
  return new CdpSession(target, port).open();
}

async function connectCodexTargets(port, timeoutMs, expectedBrowserId) {
  const deadline = Date.now() + timeoutMs;
  let lastError;
  while (Date.now() < deadline) {
    try {
      const targets = await listAppTargets(port, expectedBrowserId);
      const connected = [];
      for (const target of targets) {
        let session;
        try {
          session = await connectTarget(target, port);
          const probe = await probeSession(session);
          if (probe?.codex) connected.push({ target, session, probe });
          else session.close();
        } catch (error) {
          session?.close();
          lastError = error;
        }
      }
      if (connected.length) return connected;
      lastError = new Error("No page matched the expected Codex shell markers");
    } catch (error) {
      lastError = error;
    }
    await new Promise((resolve) => setTimeout(resolve, 350));
  }
  throw new Error(`No verified Codex renderer on 127.0.0.1:${port}: ${lastError?.message ?? "timed out"}`);
}

// --- Watch mode ---
async function runWatch(options) {
  const script = await loadInjectScript();
  const sessions = new Map();     // targetId -> CdpSession
  const earlyScripts = new Map(); // targetId -> identifier
  const targetFailures = new Map();
  let latestQuota = null;
  let stdinBuffer = "";
  let stopping = false;
  const stop = () => { stopping = true; };
  process.on("SIGINT", stop);
  process.on("SIGTERM", stop);
  const onStdinData = (chunk) => {
    stdinBuffer += String(chunk);
    const lines = stdinBuffer.split(/\r?\n/);
    stdinBuffer = lines.pop() ?? "";
    for (const line of lines) {
      let message;
      try {
        message = parseControlLine(line);
      } catch (error) {
        console.error(`[codex-meter] ignored invalid control message: ${error.message}`);
        continue;
      }
      if (message?.type === "shutdown") {
        stop();
      } else if (message?.type === "quota") {
        latestQuota = message;
        for (const [id, session] of sessions) {
          applyQuotaToSession(session, latestQuota).catch((error) => {
            console.error(`[codex-meter] quota update failed for ${id}: ${error.message}`);
          });
        }
      }
    }
  };
  process.stdin.setEncoding("utf8");
  process.stdin.on("data", onStdinData);
  process.stdin.on("end", stop);
  process.stdin.resume();

  const rejectTarget = (target, baseDelayMs, error = null) => {
    const previous = targetFailures.get(target.id) ?? { failures: 0, lastLogAt: 0 };
    const failures = previous.failures + 1;
    const delayMs = Math.min(30000, baseDelayMs * (2 ** Math.min(failures - 1, 4)));
    const now = Date.now();
    if (error && (failures === 1 || now - previous.lastLogAt >= 30000)) {
      console.error(`[codex-meter] inject failed for ${target.id}: ${error.message}; retrying in ${delayMs}ms`);
      previous.lastLogAt = now;
    }
    targetFailures.set(target.id, { failures, lastLogAt: previous.lastLogAt, until: now + delayMs });
  };

  console.log(`[codex-meter] watching for Codex targets on port ${options.port} (browser-id: ${options.browserId})`);

  while (!stopping) {
    let targets = [];
    try {
      targets = await listAppTargets(options.port);
    } catch (error) {
      console.error(`[codex-meter] failed to list targets: ${error.message}`);
      await new Promise((resolve) => setTimeout(resolve, 2000));
      continue;
    }

    // Clean up stale sessions
    const activeIds = new Set(targets.map((t) => t.id));
    for (const [id, session] of sessions) {
      if (!activeIds.has(id) || session.closed) {
        await removeEarlyPayload(session, earlyScripts.get(id));
        earlyScripts.delete(id);
        session.close();
        sessions.delete(id);
        targetFailures.delete(id);
      }
    }

    // Connect new targets
    for (const target of targets) {
      if (stopping) break;
      if (sessions.has(target.id)) continue;
      if ((targetFailures.get(target.id)?.until ?? 0) > Date.now()) continue;

      let session;
      let earlyId = null;
      try {
        session = await connectTarget(target, options.port);

        // Register early payload so it survives page reloads
        try {
          earlyId = await registerEarlyPayload(session, script);
          if (earlyId) earlyScripts.set(target.id, earlyId);
        } catch (error) {
          console.error(`[codex-meter] early injection unavailable for ${target.id}: ${error.message}`);
        }

        // Probe to confirm this is a Codex window
        const probe = await waitForCodexProbe(session);
        if (!probe?.codex) {
          await removeEarlyPayload(session, earlyId);
          rejectTarget(target, 5000);
          session.close();
          continue;
        }

        // Inject the widget
        await applyToSession(session, script);
        await applyQuotaToSession(session, latestQuota);
        sessions.set(target.id, session);
        targetFailures.delete(target.id);
        console.log(`[codex-meter] injected target ${target.id}`);

        // Listen for page loads to re-inject
        session.on("Page.loadEventFired", () => {
          setTimeout(() => {
            if (stopping) return;
            applyToSession(session, script)
              .then(() => applyQuotaToSession(session, latestQuota))
              .catch((error) => {
                console.error(`[codex-meter] reinject failed for ${target.id}: ${error.message}`);
              });
          }, 300);
        });
      } catch (error) {
        await removeEarlyPayload(session, earlyId);
        session?.close();
        rejectTarget(target, 2500, error);
      }
    }

    await new Promise((resolve) => setTimeout(resolve, 1500));
  }

  // Cleanup on exit
  for (const [id, session] of sessions) {
    await removeEarlyPayload(session, earlyScripts.get(id));
    await removeWidget(session).catch((error) => {
      console.error(`[codex-meter] cleanup failed for ${id}: ${error.message}`);
    });
    session.close();
  }
  process.off("SIGINT", stop);
  process.off("SIGTERM", stop);
  process.stdin.off("data", onStdinData);
  process.stdin.off("end", stop);
  process.stdin.pause();
  console.log("[codex-meter] stopped");
}

// --- Once mode ---
async function runOnce(options) {
  const script = await loadInjectScript();
  const connected = await connectCodexTargets(options.port, options.timeoutMs, options.browserId);
  try {
    for (const { target, session } of connected) {
      await applyToSession(session, script);
      console.log(`[codex-meter] injected target ${target.id}`);
    }
  } finally {
    for (const { session } of connected) session.close();
  }
}

// --- Entry point ---
if (path.resolve(process.argv[1] || "") === path.resolve(scriptPath)) {
  try {
    const options = parseArgs(process.argv.slice(2));
    if (options.mode === "watch") await runWatch(options);
    else await runOnce(options);
  } catch (error) {
    console.error(`[codex-meter] ${error.message}`);
    process.exitCode = 1;
  }
}
