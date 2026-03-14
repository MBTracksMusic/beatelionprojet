export const PIPELINE_RECLAIM_AFTER_SECONDS = 600;
export const PIPELINE_ACTIVE_RUN_WINDOW_SECONDS = 45;

export const clampReclaimSeconds = (value: unknown) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return PIPELINE_RECLAIM_AFTER_SECONDS;
  }

  const normalized = Math.trunc(value);
  return Math.max(60, Math.min(normalized, 3600));
};
