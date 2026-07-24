(() => {
  const HOST_ID = "codex-meter-widget";
  const VERSION = "0.3.0";

  const previous = window.__CODEX_METER_STATE__;
  if (typeof previous?.dispose === "function") {
    previous.dispose();
  } else {
    if (previous?.observer) previous.observer.disconnect();
    if (previous?.timer) clearInterval(previous.timer);
    if (previous?.ensureTimer) clearInterval(previous.ensureTimer);
    previous?.cancelScheduledUpdate?.();
  }
  document.getElementById(HOST_ID)?.remove();

  let currentQuota = {
    status: "loading",
    percent: null,
    resetsAt: null,
  };

  // --- CSS (Shadow DOM, isolated from host page) ---
  const cssText = `
    :host {
      all: initial;
      display: inline-flex;
      align-self: center;
      flex: 0 0 auto;
      height: 24px;
      color: var(--titlebar-text-color, currentColor);
      pointer-events: none;
      font-family: var(--titlebar-font-family, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif);
      -webkit-font-smoothing: antialiased;
      -webkit-app-region: no-drag;
    }
    .widget {
      box-sizing: border-box;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      height: 24px;
      padding: 4px 8px 4px 6px;
      pointer-events: auto;
      cursor: default;
      user-select: none;
      -webkit-user-select: none;
      transition: opacity 200ms ease;
    }
    .widget:hover { opacity: 0.85; }

    /* --- Battery --- */
    .battery {
      position: relative;
      display: inline-flex;
      align-items: center;
      width: 32px;
      height: 17px;
      flex-shrink: 0;
    }
    .battery-body {
      position: relative;
      box-sizing: border-box;
      width: 100%;
      height: 100%;
      border: 1.5px solid var(--titlebar-text-color, currentColor);
      border-radius: 3.5px;
      overflow: hidden;
      display: flex;
      align-items: center;
      justify-content: center;
    }
    .battery-tip {
      position: absolute;
      right: -3.5px;
      top: 50%;
      transform: translateY(-50%);
      width: 2.5px;
      height: 7px;
      border-radius: 0 1.5px 1.5px 0;
      background: var(--titlebar-text-color, currentColor);
    }
    .battery-fill {
      position: absolute;
      left: 0;
      top: 0;
      bottom: 0;
      border-radius: 2px 0 0 2px;
      transition: width 600ms cubic-bezier(0.25, 0.1, 0.25, 1),
                  background-color 400ms ease;
    }
    .battery-text {
      position: relative;
      z-index: 1;
      font-size: 12px;
      font-weight: 650;
      font-variant-numeric: tabular-nums;
      letter-spacing: -0.1px;
      line-height: 1;
      color: #fff;
      text-shadow: 0 0 2px rgba(0,0,0,0.25);
      transform: translateY(-0.5px);
    }
    .battery[data-level="warning"] .battery-text {
      color: rgba(0, 0, 0, 0.82);
      text-shadow: none;
    }
    .battery[data-level="critical"] .battery-text {
      color: #666;
      text-shadow: none;
    }
    .battery[data-level="unknown"] .battery-text {
      color: var(--titlebar-text-color, currentColor);
      text-shadow: none;
    }

    /* --- Date (hidden until hover) --- */
    .date {
      font-family: var(--titlebar-font-family, inherit);
      font-size: var(--titlebar-font-size, 14px);
      font-weight: var(--titlebar-font-weight, 400);
      letter-spacing: normal;
      line-height: var(--titlebar-line-height, 14px);
      color: var(--titlebar-text-color, currentColor);
      white-space: nowrap;
      display: none;
    }
    .widget:hover .date {
      display: inline;
    }

    /* --- Theme: dark (default) --- */
    :host {
      --fill-green: #30d158;
      --fill-yellow: #FFCC00;
      --fill-red: #FF3B30;
    }
    /* --- Theme: light --- */
    :host([data-theme="light"]) {
      --fill-green: #34c759;
      --fill-yellow: #FFCC00;
      --fill-red: #FF3B30;
    }
  `;

  // --- Helpers ---
  const clamp = (v, min, max) => Math.min(max, Math.max(min, v));
  let disposed = false;

  function detectTheme() {
    const root = document.documentElement;
    const body = document.body;
    const classes = `${root?.className || ""} ${body?.className || ""}`.toLowerCase();
    if (/\b(dark|electron-dark|theme-dark|appearance-dark)\b/.test(classes)) return "dark";
    if (/\b(light|electron-light|theme-light|appearance-light)\b/.test(classes)) return "light";
    const dataTheme = (
      root?.getAttribute?.("data-theme") ||
      root?.getAttribute?.("data-appearance") ||
      root?.getAttribute?.("data-color-mode") ||
      body?.getAttribute?.("data-theme") ||
      ""
    ).toLowerCase();
    if (dataTheme.includes("dark")) return "dark";
    if (dataTheme.includes("light")) return "light";
    try {
      if (window.matchMedia?.("(prefers-color-scheme: dark)")?.matches) return "dark";
    } catch { /* ignore */ }
    return "light";
  }

  function fillColor(percent) {
    if (percent < 20) return "var(--fill-red)";
    if (percent < 50) return "var(--fill-yellow)";
    return "var(--fill-green)";
  }

  function fillLevel(percent) {
    if (percent < 20) return "critical";
    if (percent < 50) return "warning";
    return "normal";
  }

  function formatResetDate(value) {
    if (typeof value !== "string" || !value) return "";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return "";
    return `${date.getMonth() + 1}月${date.getDate()}日`;
  }

  function findTitlebarAnchor() {
    const titlebar = document.querySelector('[class~="group/application-menu-top-bar"]');
    if (!titlebar) return null;

    const menuButtons = Array.from(titlebar.querySelectorAll('button[aria-haspopup="menu"]'));
    return menuButtons.find((button) => {
      const label = (button.getAttribute("aria-label") || button.textContent || "").trim();
      return label === "帮助" || label.toLowerCase() === "help";
    }) || menuButtons.at(-1) || null;
  }

  function syncTitlebarStyles(anchor) {
    const style = getComputedStyle(anchor);
    host.style.setProperty("--titlebar-text-color", style.color);
    host.style.setProperty("--titlebar-font-family", style.fontFamily);
    host.style.setProperty("--titlebar-font-size", style.fontSize);
    host.style.setProperty("--titlebar-font-weight", style.fontWeight);
    host.style.setProperty("--titlebar-line-height", style.lineHeight);
  }

  function mountInTitlebar() {
    if (disposed) return false;
    const anchor = findTitlebarAnchor();
    if (!anchor) return false;

    if (host.parentElement !== anchor.parentElement || host.previousElementSibling !== anchor) {
      anchor.insertAdjacentElement("afterend", host);
    }
    syncTitlebarStyles(anchor);
    return true;
  }

  // --- Build DOM ---
  const host = document.createElement("div");
  host.id = HOST_ID;
  host.setAttribute("aria-hidden", "true");
  host.setAttribute("data-theme", detectTheme());

  const shadow = host.attachShadow({ mode: "open" });

  const styleNode = document.createElement("style");
  styleNode.textContent = cssText;

  const widget = document.createElement("div");
  widget.className = "widget";

  // Battery container
  const battery = document.createElement("div");
  battery.className = "battery";

  const batteryBody = document.createElement("div");
  batteryBody.className = "battery-body";

  const batteryFill = document.createElement("div");
  batteryFill.className = "battery-fill";

  const batteryText = document.createElement("span");
  batteryText.className = "battery-text";

  const batteryTip = document.createElement("div");
  batteryTip.className = "battery-tip";

  batteryBody.appendChild(batteryFill);
  batteryBody.appendChild(batteryText);
  battery.appendChild(batteryBody);
  battery.appendChild(batteryTip);

  // Date
  const dateEl = document.createElement("span");
  dateEl.className = "date";

  widget.appendChild(battery);
  widget.appendChild(dateEl);
  shadow.appendChild(styleNode);
  shadow.appendChild(widget);
  mountInTitlebar();

  // --- Update ---
  function update() {
    if (disposed) return;
    const percent = currentQuota.percent;
    const available = Number.isFinite(percent);
    if (available) {
      const normalized = clamp(Math.round(percent), 0, 100);
      batteryFill.style.width = `${normalized}%`;
      batteryFill.style.backgroundColor = fillColor(normalized);
      batteryText.textContent = String(normalized);
      battery.dataset.level = fillLevel(normalized);
    } else {
      batteryFill.style.width = "0%";
      batteryFill.style.backgroundColor = "transparent";
      batteryText.textContent = "--";
      battery.dataset.level = "unknown";
    }

    const resetDate = available ? formatResetDate(currentQuota.resetsAt) : "";
    dateEl.textContent = resetDate;
    dateEl.hidden = !resetDate;
    host.dataset.status = currentQuota.status;
    host.setAttribute("data-theme", detectTheme());
    mountInTitlebar();
  }

  function setQuota(payload) {
    const value = payload?.percent;
    currentQuota = {
      status: typeof payload?.status === "string" ? payload.status : "unavailable",
      percent: typeof value === "number" && Number.isFinite(value) ? clamp(value, 0, 100) : null,
      resetsAt: typeof payload?.resetsAt === "string" ? payload.resetsAt : null,
    };
    update();
  }

  update();

  // --- Theme observer ---
  let observer = null;
  let observerTimeout = null;
  const cancelScheduledUpdate = () => {
    if (!observerTimeout) return;
    clearTimeout(observerTimeout);
    observerTimeout = null;
  };
  const scheduleUpdate = () => {
    if (disposed) return;
    cancelScheduledUpdate();
    observerTimeout = setTimeout(() => {
      observerTimeout = null;
      update();
    }, 200);
  };
  observer = new MutationObserver(() => scheduleUpdate());
  observer.observe(document.documentElement, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["class", "data-theme", "data-appearance", "data-color-mode"],
  });

  // --- Re-attach if Codex re-renders its title bar ---
  const ensureAlive = () => {
    mountInTitlebar();
  };
  const ensureTimer = setInterval(ensureAlive, 1000);

  const dispose = () => {
    if (disposed) return;
    disposed = true;
    observer.disconnect();
    cancelScheduledUpdate();
    clearInterval(ensureTimer);
    host.remove();
    if (window.__CODEX_METER_STATE__?.dispose === dispose) {
      delete window.__CODEX_METER_STATE__;
    }
  };

  // --- State ---
  window.__CODEX_METER_STATE__ = {
    observer,
    cancelScheduledUpdate,
    ensureTimer,
    setQuota,
    dispose,
    version: VERSION,
  };

  console.log(`[codex-meter] widget injected (v${VERSION})`);
})();
