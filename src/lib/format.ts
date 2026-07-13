import { copy, normalizeLanguage } from "./i18n";
import type { Language, ProviderSnapshot } from "../types";

export function clampPercent(value: number): number {
  return Math.min(100, Math.max(0, Math.round(value)));
}

export function quotaTier(percent: number | null): "unknown" | "healthy" | "caution" | "critical" {
  if (percent === null) return "unknown";
  if (percent >= 50) return "healthy";
  if (percent >= 10) return "caution";
  return "critical";
}

export function formatResetTime(value: string | null, now = new Date(), language: Language = "zh-CN"): string {
  const t = copy[normalizeLanguage(language)];
  if (!value) return t.resetTimeUnknown;
  const target = new Date(value);
  if (Number.isNaN(target.getTime())) return t.resetTimeUnknown;
  const delta = target.getTime() - now.getTime();
  if (delta <= 0) return t.resetUpdating;
  const minutes = Math.ceil(delta / 60_000);
  if (minutes < 60) return t.resetInMinutes(minutes);
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 24) return t.resetInHours(hours, rest);
  const days = Math.floor(hours / 24);
  return t.resetInDays(days, hours % 24);
}

export function formatCompactResetTime(value: string | null, now = new Date()): string {
  const t = copy["zh-CN"];
  if (!value) return t.resetTimeUnknown;
  const target = new Date(value);
  if (Number.isNaN(target.getTime())) return t.resetTimeUnknown;
  const delta = target.getTime() - now.getTime();
  if (delta <= 0) return t.resetUpdating;
  const minutes = Math.ceil(delta / 60_000);
  if (minutes < 60) return `${minutes}分钟后重置`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 24) return rest ? `${hours}小时${rest}分钟后重置` : `${hours}小时后重置`;
  const days = Math.floor(hours / 24);
  return `${days}天${hours % 24}小时后重置`;
}

export function formatInlineResetTime(value: string | null, now = new Date()): string {
  if (!value) return "--";
  const target = new Date(value);
  if (Number.isNaN(target.getTime())) return "--";
  const delta = target.getTime() - now.getTime();
  if (delta <= 0) return "重置中";
  const minutes = Math.ceil(delta / 60_000);
  if (minutes < 60) return `${minutes}分钟`;
  const hours = Math.floor(minutes / 60);
  const rest = minutes % 60;
  if (hours < 24) return rest ? `${hours}小时${rest}分钟` : `${hours}小时`;
  const days = Math.floor(hours / 24);
  const hourRest = hours % 24;
  return hourRest ? `${days}天${hourRest}小时` : `${days}天`;
}

export function needsFastRefresh(snapshot: ProviderSnapshot, now = new Date()): boolean {
  const reset = snapshot.shortWindow?.resetsAt ?? snapshot.weeklyWindow?.resetsAt;
  if (!reset) return false;
  const remaining = new Date(reset).getTime() - now.getTime();
  return remaining > -5 * 60_000 && remaining <= 15 * 60_000;
}

export function formatResetDate(value: string | null, language: Language = "zh-CN"): string {
  const t = copy[normalizeLanguage(language)];
  if (!value) return t.dateUnknown;
  const isoDate = /^(\d{4})-(\d{2})-(\d{2})/.exec(value);
  if (isoDate) {
    return `${Number(isoDate[2])}/${Number(isoDate[3])}`;
  }
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return t.dateUnknown;
  return new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric" }).format(date);
}

export function formatDateTime(value: string, language: Language): string {
  const t = copy[normalizeLanguage(language)];
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return t.creditExpiresUnknown;
  return new Intl.DateTimeFormat("zh-CN", { month: "numeric", day: "numeric", hour: "2-digit", minute: "2-digit" }).format(date);
}
