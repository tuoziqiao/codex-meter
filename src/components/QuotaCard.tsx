import { memo } from "react";
import { clampPercent, formatInlineResetTime, quotaTier } from "../lib/format";
import { copy } from "../lib/i18n";
import type { ProviderSnapshot } from "../types";

interface Props {
  snapshot: ProviderSnapshot;
  onDrag: () => void;
}

interface QuotaMetricProps {
  label: string;
  percent: number | null;
  resetsAt?: string | null;
}

function localizedBackendMessage(message: string | null): string {
  if (!message) return "额度接口暂时不可用";
  const normalized = message.toLowerCase();
  if (normalized.includes("sign in") || normalized.includes("login")) return "Codex 登录已失效";
  if (normalized.includes("rate limited")) return "请求过于频繁";
  if (normalized.includes("network")) return "网络不可用";
  return "额度接口暂时不可用";
}

function QuotaMetric({ label, percent, resetsAt }: QuotaMetricProps) {
  const available = percent !== null;
  const value = available ? `${percent}%` : "--";
  const resetLabel = formatInlineResetTime(resetsAt ?? null);
  const description = available
    ? `${label}额度剩余 ${percent}%，${resetLabel === "--" ? "重置时间未知" : `${resetLabel}后重置`}`
    : `${label}额度暂无数据`;

  return (
    <div className="quota-metric" aria-label={description}>
      <span className="quota-metric__label">{label}</span>
      <strong className="quota-metric__value">{value}</strong>
      <div
        className={`progress${available ? "" : " progress--unknown"}`}
        role="progressbar"
        aria-label={description}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-valuenow={percent ?? undefined}
        aria-valuetext={description}
      >
        {available ? <span style={{ width: `${percent}%` }} /> : null}
      </div>
      <span className="quota-metric__reset" aria-hidden="true">{resetLabel}</span>
    </div>
  );
}

export const QuotaCard = memo(function QuotaCard({ snapshot, onDrag }: Props) {
  const t = copy["zh-CN"];
  const short = snapshot.shortWindow ? clampPercent(snapshot.shortWindow.remainingPercent) : null;
  const weekly = snapshot.weeklyWindow ? clampPercent(snapshot.weeklyWindow.remainingPercent) : null;
  const showShort = short !== null;
  const showWeekly = weekly !== null;
  const staleAge = Date.now() - new Date(snapshot.updatedAt).getTime();
  const staleExpired = snapshot.status === "stale" && staleAge > 30 * 60_000;
  const available = snapshot.status === "ok" || (snapshot.status === "stale" && !staleExpired);
  const tier = quotaTier(weekly ?? short);
  const message = localizedBackendMessage(snapshot.message);
  const summary = [
    showShort
      ? `5 小时额度剩余 ${short}%${snapshot.shortWindow?.resetsAt ? `，${formatInlineResetTime(snapshot.shortWindow.resetsAt)}后重置` : ""}`
      : null,
    showWeekly
      ? `本周额度${weekly === null ? "暂无数据" : `剩余 ${weekly}%`}${snapshot.weeklyWindow?.resetsAt ? `，${formatInlineResetTime(snapshot.weeklyWindow.resetsAt)}后重置` : ""}`
      : null,
  ].filter(Boolean).join("；");

  return (
    <main
      className={`quota-card quota-card--${snapshot.status} quota-card--${tier}`}
      onMouseDown={(event) => { if (event.button === 0) void onDrag(); }}
    >
      <div className="aurora" aria-hidden="true" />
      <span className="sr-only" aria-live="polite">{available ? summary : message}</span>
      {available ? (
        <section className="compact-metrics" aria-label={summary}>
          {showShort ? <QuotaMetric label="5小时" percent={short} resetsAt={snapshot.shortWindow?.resetsAt} /> : null}
          {showWeekly ? <QuotaMetric label="本周" percent={weekly} resetsAt={snapshot.weeklyWindow?.resetsAt} /> : null}
        </section>
      ) : (
        <section className="compact-error" aria-live="polite">
          <strong>{snapshot.status === "signed_out" ? t.signedInRequired : staleExpired ? t.staleExpired : t.temporarilyUnavailable}</strong>
          <span>{message}</span>
        </section>
      )}
    </main>
  );
});
