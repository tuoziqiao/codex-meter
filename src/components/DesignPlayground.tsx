import { useMemo, useState, type CSSProperties } from "react";
import type { ProviderSnapshot } from "../types";
import { QuotaCard } from "./QuotaCard";

const preview: ProviderSnapshot = {
  provider: "codex",
  displayName: "CODEX",
  plan: "PRO",
  shortWindow: { remainingPercent: 74, resetsAt: new Date(Date.now() + 78 * 60_000).toISOString(), windowSeconds: 18_000 },
  weeklyWindow: { remainingPercent: 42, resetsAt: new Date(Date.now() + 3.2 * 86_400_000).toISOString(), windowSeconds: 604_800 },
  resetCredits: 1,
  resetCreditExpiresAt: [new Date(Date.now() + 9 * 86_400_000).toISOString()],
  updatedAt: new Date().toISOString(),
  status: "ok",
  message: null,
};
interface Values {
  radius: number;
  numberSize: number;
  progressHeight: number;
  brightness: number;
  motion: number;
  cool: string;
  glow: string;
  warm: string;
}

type PreviewMode = 74 | 35 | 8 | "unavailable" | "stale" | "signed_out";

const previewModes: Array<{ value: PreviewMode; label: string }> = [
  { value: 74, label: "74% 充足" },
  { value: 35, label: "35% 注意" },
  { value: 8, label: "8% 紧张" },
  { value: "unavailable", label: "暂不可用" },
  { value: "stale", label: "数据过期" },
  { value: "signed_out", label: "未登录" },
];

const defaults: Values = { radius: 38, numberSize: 64, progressHeight: 6, brightness: 100, motion: 18, cool: "#7188bd", glow: "#fff4c3", warm: "#ff7653" };

function initialPreviewMode(): PreviewMode {
  const mode = new URLSearchParams(window.location.search).get("mode");
  if (mode === "healthy") return 74;
  if (mode === "caution") return 35;
  if (mode === "critical") return 8;
  if (mode === "unavailable" || mode === "stale" || mode === "signed_out") return mode;
  return 74;
}

export function DesignPlayground() {
  const [values, setValues] = useState(defaults);
  const [previewMode, setPreviewMode] = useState<PreviewMode>(() => initialPreviewMode());
  const params = new URLSearchParams(window.location.search);
  const screenshotMode = params.has("shot");
  const shotKind = params.get("shot");
  const style = useMemo(() => ({
    "--card-radius": `${values.radius}px`,
    "--number-size": `${values.numberSize}px`,
    "--progress-height": `${values.progressHeight}px`,
    "--card-brightness": `${values.brightness}%`,
    "--motion-duration": `${values.motion}s`,
    "--cool": values.cool,
    "--glow": values.glow,
    "--warm": values.warm,
  }) as CSSProperties, [values]);

  const makePreview = (mode: PreviewMode): ProviderSnapshot => {
    if (typeof mode === "number") {
      return {
        ...preview,
        shortWindow: preview.shortWindow ? { ...preview.shortWindow, remainingPercent: mode } : null,
        weeklyWindow: preview.weeklyWindow ? { ...preview.weeklyWindow, remainingPercent: mode } : null,
      };
    }
    if (mode === "stale") {
      return { ...preview, status: "stale", updatedAt: new Date(Date.now() - 2 * 60 * 60_000).toISOString(), message: "刷新失败，请稍后重试。" };
    }
    return {
      ...preview,
      status: mode,
      shortWindow: null,
      weeklyWindow: null,
      resetCredits: null,
      message: mode === "signed_out" ? "Codex 登录已失效，请重新登录。" : "额度接口暂时不可用，将自动重试。",
    };
  };

  const activePreview = useMemo<ProviderSnapshot>(() => makePreview(previewMode), [previewMode]);

  const update = <K extends keyof Values>(key: K, value: Values[K]) => setValues((current) => ({ ...current, [key]: value }));

  if (screenshotMode) {
    if (shotKind === "states") {
      return (
        <div className="screenshot-stage screenshot-stage--states" style={style}>
          {[74, 35, 8].map((mode) => (
            <div className="design-card-frame" key={mode}>
              <QuotaCard snapshot={makePreview(mode as PreviewMode)} onDrag={() => {}} />
            </div>
          ))}
        </div>
      );
    }

    return (
      <div className="screenshot-stage" style={style}>
        <div className="design-card-frame">
          <QuotaCard snapshot={activePreview} onDrag={() => {}} />
        </div>
      </div>
    );
  }

  return (
    <div className="design-workbench">
      <section className="design-stage" style={style}>
        <div className="design-preview-switch" aria-label="Quota status preview">
          {previewModes.map((mode) => (
            <button key={mode.value} className={previewMode === mode.value ? "is-active" : ""} onClick={() => setPreviewMode(mode.value)}>{mode.label}</button>
          ))}
        </div>
        <div className="design-card-frame">
          <QuotaCard snapshot={activePreview} onDrag={() => {}} />
        </div>
      </section>
      <aside className="design-controls">
        <div>
          <p className="design-kicker">CodexMeter</p>
          <h1>视觉调节</h1>
          <p className="design-description">实时预览紧凑额度条的显示效果。</p>
        </div>
        <Range label="圆角" value={values.radius} min={24} max={64} unit="px" onChange={(v) => update("radius", v)} />
        <Range label="主数字" value={values.numberSize} min={56} max={110} unit="px" onChange={(v) => update("numberSize", v)} />
        <Range label="进度条" value={values.progressHeight} min={4} max={12} unit="px" onChange={(v) => update("progressHeight", v)} />
        <Range label="亮度" value={values.brightness} min={70} max={125} unit="%" onChange={(v) => update("brightness", v)} />
        <Range label="动效" value={values.motion} min={6} max={40} unit="s" onChange={(v) => update("motion", v)} />
        <div className="color-row">
          <Color label="冷色" value={values.cool} onChange={(v) => update("cool", v)} />
          <Color label="高光" value={values.glow} onChange={(v) => update("glow", v)} />
          <Color label="暖色" value={values.warm} onChange={(v) => update("warm", v)} />
        </div>
        <button className="reset-design" onClick={() => setValues(defaults)}>重置设计</button>
      </aside>
    </div>
  );
}

function Range({ label, value, min, max, unit, onChange }: { label: string; value: number; min: number; max: number; unit: string; onChange: (value: number) => void }) {
  return <label className="range-control"><span>{label}<output>{value}{unit}</output></span><input type="range" min={min} max={max} value={value} onChange={(event) => onChange(Number(event.target.value))} /></label>;
}

function Color({ label, value, onChange }: { label: string; value: string; onChange: (value: string) => void }) {
  return <label className="color-control"><input type="color" value={value} onChange={(event) => onChange(event.target.value)} /><span>{label}</span></label>;
}
