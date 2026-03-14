import { insertPipelineMetrics } from "./pipelineMetrics.ts";

type SupabaseAdminClient = any;

type PipelineRunStatus = "start" | "success" | "failure";

type PipelineRunEvent = {
  component: string;
  runId: string;
  status: PipelineRunStatus;
  processedCount?: number;
  errorCount?: number;
  durationMs?: number;
  labels?: Record<string, unknown>;
};

type PipelineRunAlertConfig = {
  durationThresholdMs?: number;
  zeroProcessedConsecutiveRuns?: number;
  skipZeroProcessedAlert?: boolean;
};

const DEFAULT_DURATION_THRESHOLD_MS = 15_000;
const DEFAULT_ZERO_PROCESSED_CONSECUTIVE_RUNS = 3;

const asFiniteNumber = (value: unknown): number | null => {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return null;
};

const normalizeCount = (value: unknown) => {
  const numeric = asFiniteNumber(value);
  if (numeric === null) return 0;
  return Math.max(0, Math.trunc(numeric));
};

const normalizeDuration = (value: unknown) => {
  const numeric = asFiniteNumber(value);
  if (numeric === null) return 0;
  return Math.max(0, Math.round(numeric));
};

const insertMonitoringAlert = async (
  supabaseAdmin: SupabaseAdminClient,
  params: {
    eventType: string;
    severity: "info" | "warning" | "critical";
    details: Record<string, unknown>;
  },
) => {
  const { error } = await supabaseAdmin.rpc("log_monitoring_alert", {
    p_event_type: params.eventType,
    p_severity: params.severity,
    p_source: "internal_pipeline_worker",
    p_entity_type: "pipeline_worker",
    p_entity_id: null,
    p_details: params.details,
  });

  if (error) {
    throw new Error(`log_monitoring_alert_failed:${error.message}`);
  }
};

export const safeRecordPipelineRunEvent = async (
  supabaseAdmin: SupabaseAdminClient,
  event: PipelineRunEvent,
) => {
  try {
    const processedCount = normalizeCount(event.processedCount);
    const errorCount = normalizeCount(event.errorCount);
    const durationMs = normalizeDuration(event.durationMs);

    await insertPipelineMetrics(supabaseAdmin, [
      {
        component: event.component,
        metricName: "worker_run",
        metricValue: durationMs,
        labels: {
          run_id: event.runId,
          status: event.status,
          processed_count: processedCount,
          error_count: errorCount,
          duration_ms: durationMs,
          ...(event.labels ?? {}),
        },
      },
    ]);
  } catch (error) {
    console.error(`[${event.component}] pipeline run metric failed`, {
      runId: event.runId,
      status: event.status,
      error: error instanceof Error ? error.message : String(error),
    });
  }
};

export const safeEmitPipelineRunAlerts = async (
  supabaseAdmin: SupabaseAdminClient,
  params: {
    component: string;
    runId: string;
    status: Exclude<PipelineRunStatus, "start">;
    processedCount: number;
    errorCount: number;
    durationMs: number;
    config?: PipelineRunAlertConfig;
  },
) => {
  const processedCount = normalizeCount(params.processedCount);
  const errorCount = normalizeCount(params.errorCount);
  const durationMs = normalizeDuration(params.durationMs);
  const durationThresholdMs = Math.max(
    1_000,
    normalizeDuration(params.config?.durationThresholdMs ?? DEFAULT_DURATION_THRESHOLD_MS),
  );
  const zeroProcessedConsecutiveRuns = Math.max(
    2,
    normalizeCount(params.config?.zeroProcessedConsecutiveRuns ?? DEFAULT_ZERO_PROCESSED_CONSECUTIVE_RUNS),
  );

  try {
    if (errorCount > 0) {
      await insertMonitoringAlert(supabaseAdmin, {
        eventType: "pipeline_worker_errors",
        severity: "critical",
        details: {
          component: params.component,
          run_id: params.runId,
          status: params.status,
          processed_count: processedCount,
          error_count: errorCount,
          duration_ms: durationMs,
        },
      });
    }

    if (durationMs > durationThresholdMs) {
      await insertMonitoringAlert(supabaseAdmin, {
        eventType: "pipeline_worker_duration_exceeded",
        severity: "warning",
        details: {
          component: params.component,
          run_id: params.runId,
          status: params.status,
          processed_count: processedCount,
          error_count: errorCount,
          duration_ms: durationMs,
          threshold_ms: durationThresholdMs,
        },
      });
    }

    if (
      params.status === "success" &&
      processedCount === 0 &&
      params.config?.skipZeroProcessedAlert !== true
    ) {
      const { data, error } = await supabaseAdmin
        .from("pipeline_metrics")
        .select("labels, created_at")
        .eq("component", params.component)
        .eq("metric_name", "worker_run")
        .contains("labels", { status: "success" })
        .order("created_at", { ascending: false })
        .limit(zeroProcessedConsecutiveRuns);

      if (error) {
        throw new Error(`pipeline_metrics_recent_runs_query_failed:${error.message}`);
      }

      const recentRuns = (data as Array<{ labels?: Record<string, unknown> | null }> | null) ?? [];
      if (recentRuns.length >= zeroProcessedConsecutiveRuns) {
        const allZeroProcessed = recentRuns.every((run) => {
          const labels = run.labels ?? {};
          const isSkipped = labels.skip_zero_processed_alert === true || labels.skip_zero_processed_alert === "true";
          const processed = normalizeCount(labels.processed_count);
          return !isSkipped && processed === 0;
        });

        if (allZeroProcessed) {
          await insertMonitoringAlert(supabaseAdmin, {
            eventType: "pipeline_worker_zero_processed_streak",
            severity: "warning",
            details: {
              component: params.component,
              run_id: params.runId,
              consecutive_runs: zeroProcessedConsecutiveRuns,
              processed_count: processedCount,
              error_count: errorCount,
              duration_ms: durationMs,
            },
          });
        }
      }
    }
  } catch (error) {
    console.error(`[${params.component}] pipeline alert emit failed`, {
      runId: params.runId,
      status: params.status,
      error: error instanceof Error ? error.message : String(error),
    });
  }
};
