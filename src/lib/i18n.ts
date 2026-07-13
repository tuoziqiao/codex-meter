import type { Language } from "../types";

export const DEFAULT_LANGUAGE: Language = "zh-CN";

export const copy = {
  "zh-CN": {
    active: "正在消耗额度",
    availableLabel: (percent: number) => `本周额度剩余 ${percent}%`,
    creditExpiresUnknown: "到期时间未知",
    dateUnknown: "日期未知",
    errorUnavailable: "额度接口暂时不可用，将自动重试。",
    loadingQuota: "正在读取额度",
    resetInDays: (days: number, hours: number) => `${days} 天 ${hours} 小时后重置`,
    resetInHours: (hours: number, minutes: number) => minutes ? `${hours} 小时 ${minutes} 分钟后重置` : `${hours} 小时后重置`,
    resetInMinutes: (minutes: number) => `${minutes} 分钟后重置`,
    resetTimeUnknown: "重置时间未知",
    resetUpdating: "正在更新额度",
    signedInRequired: "请先登录 Codex",
    staleExpired: "额度数据已过期",
    temporarilyUnavailable: "暂时无法读取",
    weeklyUnavailable: "本周额度暂无数据",
  },
} as const;

export function normalizeLanguage(_value: unknown): Language {
  return DEFAULT_LANGUAGE;
}
