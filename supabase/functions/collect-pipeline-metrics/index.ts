import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { safeInsertPipelineMetrics } from "../_shared/pipelineMetrics.ts";
import {
  safeEmitPipelineRunAlerts,
  safeRecordPipelineRunEvent,
} from "../_shared/pipelineRunMonitoring.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

const DEFAULT_LOOKBACK_MINUTES = 60;
const MAX_LOOKBACK_MINUTES = 24 * 60;

type SupabaseAdminClient = any;

type BacklogSnapshot = {
  event_outbox_pending: number;
  event_bus_pending: number;
  email_queue_pending: number;
  email_queue_failed: number;
};

type PipelineHealthRow = {
  outbox_backlog: number;
  email_queue_backlog: number;
  failed_emails: number;
  avg_latency: number;
  events_per_minute: number;
};

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const asJsonObject = (value: unknown): Record<string, unknown> | null => {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  return value as Record<string, unknown>;
};

const asFiniteNumber = (value: unknown) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null;
  }
  return value;
};

const normalizeNumeric = (value: unknown) => {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string") {
    const parsed = Number(value);
    if (Number.isFinite(parsed)) return parsed;
  }
  return 0;
};

const jsonResponse = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), { status, headers: JSON_HEADERS });

const parseRequestBody = async (req: Request) => {
  const rawBody = await req.text();
  if (rawBody.trim() === "") {
    return { ok: true as const, body: {} as Record<string, unknown> };
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return {
      ok: false as const,
      response: jsonResponse(400, { error: "Invalid JSON payload" }),
    };
  }

  const body = asJsonObject(parsed);
  if (!body) {
    return {
      ok: false as const,
      response: jsonResponse(400, { error: "JSON payload must be an object" }),
    };
  }

  return { ok: true as const, body };
};

const resolveLookbackMinutes = (value: unknown) => {
  const numeric = asFiniteNumber(value);
  if (numeric === null) return DEFAULT_LOOKBACK_MINUTES;
  const normalized = Math.trunc(numeric);
  return Math.max(1, Math.min(normalized, MAX_LOOKBACK_MINUTES));
};

serveWithErrorHandling("collect-pipeline-metrics", async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: JSON_HEADERS });
  }

  if (req.method !== "POST") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  const parsed = await parseRequestBody(req);
  if (!parsed.ok) {
    return parsed.response;
  }

  const supabaseUrl = asNonEmptyString(Deno.env.get("SUPABASE_URL"));
  const serviceRoleKey = asNonEmptyString(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const pipelineCollectorSecret = asNonEmptyString(Deno.env.get("PIPELINE_COLLECTOR_SECRET"));
  if (!supabaseUrl || !serviceRoleKey || !pipelineCollectorSecret) {
    return jsonResponse(500, { error: "Missing server configuration" });
  }

  const providedSecret = asNonEmptyString(req.headers.get("x-pipeline-collector-secret"));
  if (!providedSecret || providedSecret !== pipelineCollectorSecret) {
    return jsonResponse(401, { error: "Unauthorized" });
  }

  const body = parsed.body;
  const lookbackMinutes = resolveLookbackMinutes(body.lookback_minutes);
  const sinceIso = new Date(Date.now() - lookbackMinutes * 60_000).toISOString();

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAdminClient;
  const runId = crypto.randomUUID();
  const runStartedAtMs = Date.now();
  await safeRecordPipelineRunEvent(supabaseAdmin, {
    component: "collect-pipeline-metrics",
    runId,
    status: "start",
  });

  const finalizeRun = async (params: {
    status: "success" | "failure";
    processedCount: number;
    errorCount: number;
    extraLabels?: Record<string, unknown>;
    skipZeroProcessedAlert?: boolean;
  }) => {
    const durationMs = Date.now() - runStartedAtMs;
    await safeRecordPipelineRunEvent(supabaseAdmin, {
      component: "collect-pipeline-metrics",
      runId,
      status: params.status,
      processedCount: params.processedCount,
      errorCount: params.errorCount,
      durationMs,
      labels: {
        ...(params.extraLabels ?? {}),
        ...(params.skipZeroProcessedAlert ? { skip_zero_processed_alert: true } : {}),
      },
    });
    await safeEmitPipelineRunAlerts(supabaseAdmin, {
      component: "collect-pipeline-metrics",
      runId,
      status: params.status,
      processedCount: params.processedCount,
      errorCount: params.errorCount,
      durationMs,
      config: {
        durationThresholdMs: 10_000,
        zeroProcessedConsecutiveRuns: 3,
        skipZeroProcessedAlert: params.skipZeroProcessedAlert === true,
      },
    });
  };

  const { data: backlogRows, error: backlogError } = await supabaseAdmin
    .rpc("pipeline_backlog_snapshot");

  if (backlogError) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "backlog_snapshot_failed" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to collect backlog snapshot" });
  }

  const backlogList = Array.isArray(backlogRows)
    ? backlogRows as BacklogSnapshot[]
    : (backlogRows ? [backlogRows as BacklogSnapshot] : []);

  const backlogRow = backlogList[0] ?? {
    event_outbox_pending: 0,
    event_bus_pending: 0,
    email_queue_pending: 0,
    email_queue_failed: 0,
  };

  if (backlogList.length === 0) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "backlog_snapshot_empty" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Backlog snapshot returned no rows" });
  }

  const { data: healthRowRaw, error: healthError } = await supabaseAdmin
    .from("pipeline_health")
    .select("outbox_backlog,email_queue_backlog,failed_emails,avg_latency,events_per_minute")
    .single();

  if (healthError) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "pipeline_health_query_failed" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to collect pipeline health" });
  }

  const healthRow = (healthRowRaw as PipelineHealthRow | null) ?? {
    outbox_backlog: 0,
    email_queue_backlog: 0,
    failed_emails: 0,
    avg_latency: 0,
    events_per_minute: 0,
  };

  if (!healthRowRaw) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "pipeline_health_empty" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Pipeline health returned no rows" });
  }

  const [sentCountResult, failedCountResult, outboxProcessedResult, outboxFailedResult] = await Promise.all([
    supabaseAdmin
      .from("email_queue")
      .select("id", { head: true, count: "exact" })
      .eq("status", "sent")
      .gte("processed_at", sinceIso),
    supabaseAdmin
      .from("email_queue")
      .select("id", { head: true, count: "exact" })
      .eq("status", "failed")
      .gte("created_at", sinceIso),
    supabaseAdmin
      .from("event_outbox")
      .select("id", { head: true, count: "exact" })
      .eq("status", "processed")
      .gte("processed_at", sinceIso),
    supabaseAdmin
      .from("event_outbox")
      .select("id", { head: true, count: "exact" })
      .eq("status", "failed")
      .gte("processed_at", sinceIso),
  ]);

  const sentCount = sentCountResult.count ?? 0;
  const failedCount = failedCountResult.count ?? 0;
  const outboxProcessedCount = outboxProcessedResult.count ?? 0;
  const outboxFailedCount = outboxFailedResult.count ?? 0;
  const countErrors = [
    sentCountResult.error,
    failedCountResult.error,
    outboxProcessedResult.error,
    outboxFailedResult.error,
  ].filter(Boolean);

  if (countErrors.length > 0) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: countErrors.length,
      extraLabels: { reason: "count_queries_failed", count_errors: countErrors.length },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to aggregate pipeline counts" });
  }
  const errorRatePct = sentCount + failedCount > 0
    ? (failedCount / (sentCount + failedCount)) * 100
    : 0;

  const metricsInserted = await safeInsertPipelineMetrics(
    supabaseAdmin,
    [
      {
        component: "collect-pipeline-metrics",
        metricName: "queue_backlog",
        metricValue: normalizeNumeric(backlogRow.event_outbox_pending),
        labels: { queue: "event_outbox", status: "pending" },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "queue_backlog",
        metricValue: normalizeNumeric(backlogRow.event_bus_pending),
        labels: { queue: "event_bus", status: "pending" },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "queue_backlog",
        metricValue: normalizeNumeric(backlogRow.email_queue_pending),
        labels: { queue: "email_queue", status: "pending" },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "queue_backlog",
        metricValue: normalizeNumeric(backlogRow.email_queue_failed),
        labels: { queue: "email_queue", status: "failed" },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "pipeline_latency_ms",
        metricValue: normalizeNumeric(healthRow.avg_latency),
        labels: { scope: "end_to_end_avg_1h" },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "events_processed",
        metricValue: outboxProcessedCount,
        labels: { scope: `outbox_last_${lookbackMinutes}m` },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "events_failed",
        metricValue: outboxFailedCount,
        labels: { scope: `outbox_last_${lookbackMinutes}m` },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "email_sent",
        metricValue: sentCount,
        labels: { scope: `email_last_${lookbackMinutes}m` },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "email_failed",
        metricValue: failedCount,
        labels: { scope: `email_last_${lookbackMinutes}m` },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "error_rate_pct",
        metricValue: errorRatePct,
        labels: { scope: `email_last_${lookbackMinutes}m` },
      },
      {
        component: "collect-pipeline-metrics",
        metricName: "events_per_minute",
        metricValue: normalizeNumeric(healthRow.events_per_minute),
        labels: { scope: "outbox_last_5m" },
      },
    ],
    "collect-pipeline-metrics",
  );

  if (!metricsInserted) {
    await finalizeRun({
      status: "failure",
      processedCount: outboxProcessedCount + sentCount,
      errorCount: failedCount + outboxFailedCount + 1,
      extraLabels: { reason: "metrics_insert_failed" },
    });
    return jsonResponse(500, { error: "Unable to write pipeline metrics" });
  }

  const runErrorCount = failedCount + outboxFailedCount;
  await finalizeRun({
    status: runErrorCount > 0 ? "failure" : "success",
    processedCount: outboxProcessedCount + sentCount,
    errorCount: runErrorCount,
    extraLabels: {
      lookback_minutes: lookbackMinutes,
      outbox_processed: outboxProcessedCount,
      outbox_failed: outboxFailedCount,
      email_sent: sentCount,
      email_failed: failedCount,
      error_rate_pct: Number(errorRatePct.toFixed(4)),
    },
  });

  return jsonResponse(200, {
    lookbackMinutes,
    backlog: {
      event_outbox_pending: normalizeNumeric(backlogRow.event_outbox_pending),
      event_bus_pending: normalizeNumeric(backlogRow.event_bus_pending),
      email_queue_pending: normalizeNumeric(backlogRow.email_queue_pending),
      email_queue_failed: normalizeNumeric(backlogRow.email_queue_failed),
    },
    health: {
      outbox_backlog: normalizeNumeric(healthRow.outbox_backlog),
      email_queue_backlog: normalizeNumeric(healthRow.email_queue_backlog),
      failed_emails: normalizeNumeric(healthRow.failed_emails),
      avg_latency: normalizeNumeric(healthRow.avg_latency),
      events_per_minute: normalizeNumeric(healthRow.events_per_minute),
    },
    summary: {
      outboxProcessedCount,
      outboxFailedCount,
      sentCount,
      failedCount,
      errorRatePct,
    },
  });
});
