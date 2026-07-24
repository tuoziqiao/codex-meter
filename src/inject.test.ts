import { readFile } from "node:fs/promises";
import { JSDOM } from "jsdom";
import { describe, expect, it } from "vitest";

interface InjectedState {
  timer?: unknown;
  setQuota: (quota: { status: string; percent: number | null; resetsAt: string | null }) => void;
  dispose: () => void;
}

describe("title-bar quota injection", () => {
  it("renders pushed quota data without a mock timer", async () => {
    const script = await readFile(
      new URL("../src-tauri/resources/inject.js", import.meta.url),
      "utf8",
    );
    const dom = new JSDOM(`<!doctype html><html><body>
      <div class="group/application-menu-top-bar">
        <div><button aria-haspopup="menu" aria-label="帮助">帮助</button></div>
      </div>
    </body></html>`, {
      runScripts: "outside-only",
      url: "app://-/index.html",
    });

    dom.window.eval(script);
    const state = (dom.window as unknown as { __CODEX_METER_STATE__: InjectedState })
      .__CODEX_METER_STATE__;
    expect(state).toBeDefined();
    expect(state.timer).toBeUndefined();

    state.setQuota({
      status: "ok",
      percent: 49,
      resetsAt: "2026-08-20T00:00:00",
    });
    const host = dom.window.document.getElementById("codex-meter-widget");
    const battery = host?.shadowRoot?.querySelector<HTMLElement>(".battery");
    const fill = host?.shadowRoot?.querySelector<HTMLElement>(".battery-fill");
    const text = host?.shadowRoot?.querySelector<HTMLElement>(".battery-text");
    const date = host?.shadowRoot?.querySelector<HTMLElement>(".date");
    const styleText = host?.shadowRoot?.querySelector("style")?.textContent ?? "";

    expect(host?.previousElementSibling?.getAttribute("aria-label")).toBe("帮助");
    expect(battery?.dataset.level).toBe("warning");
    expect(fill?.style.width).toBe("49%");
    expect(text?.textContent).toBe("49");
    expect(date?.textContent).toBe("8月20日");
    expect(date?.hidden).toBe(false);
    expect(styleText).toMatch(/\.date\s*\{[^}]*display:\s*none/);
    expect(styleText).toMatch(/\.widget:hover \.date\s*\{[^}]*display:\s*inline/);

    state.setQuota({
      status: "ok",
      percent: 19,
      resetsAt: "2026-08-20T00:00:00",
    });
    expect(battery?.dataset.level).toBe("critical");
    expect(fill?.style.width).toBe("19%");
    expect(text?.textContent).toBe("19");
    expect(styleText).toContain('.battery[data-level="critical"] .battery-text');
    expect(styleText).toMatch(/\.battery\[data-level="critical"\] \.battery-text\s*\{[^}]*color:\s*#666/);

    state.setQuota({ status: "unavailable", percent: null, resetsAt: null });
    expect(text?.textContent).toBe("--");
    expect(date?.hidden).toBe(true);

    state.dispose();
    expect(dom.window.document.getElementById("codex-meter-widget")).toBeNull();
    dom.window.close();
  });
});
