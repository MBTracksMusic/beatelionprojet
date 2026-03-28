import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  safeEmitPipelineRunAlerts,
  safeRecordPipelineRunEvent,
} from "../_shared/pipelineRunMonitoring.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

const DEFAULT_STALE_EVENT_LIMIT = 25;
const DEFAULT_FAILED_ALLOCATION_LIMIT = 25;
const MAX_BATCH_LIMIT = 100;
const DEFAULT_MAX_RETRIES = 10;
const MAX_ERROR_LENGTH = 500;
const DEFAULT_EVENT_PROCESSING_LOCK_TIMEOUT_MS = 5 * 60 * 1000;

type SupabaseAdminClient = any;

type StripeEventRow = {
  id: string;
  type: string;
  processed: boolean;
  processing_started_at: string | null;
  processed_at?: string | null;
  error?: string | null;
};

type FailedCreditAllocationRow = {
  id: string;
  stripe_event_id: string;
  stripe_invoice_id: string | null;
  stripe_subscription_id: string | null;
  error_message: string;
  error_code: string | null;
  retry_count: number;
  next_retry_at: string;
};

const asNonEmptyString = (value: unknown): string | null => {
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

const resolveBatchLimit = (value: unknown, fallback: number) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.max(1, Math.min(Math.trunc(value), MAX_BATCH_LIMIT));
};

const resolveMaxRetries = (value: unknown) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_MAX_RETRIES;
  }

  return Math.max(1, Math.min(Math.trunc(value), 100));
};

const getEventProcessingLockTimeoutMs = () => {
  const raw = asNonEmptyString(Deno.env.get("STRIPE_EVENT_PROCESSING_LOCK_TIMEOUT_MS"));
  const parsed = raw ? Number.parseInt(raw, 10) : NaN;
  return Number.isFinite(parsed) && parsed > 0
    ? parsed
    : DEFAULT_EVENT_PROCESSING_LOCK_TIMEOUT_MS;
};

const computeRetryBackoffSeconds = (attempts: number) => {
  const safeAttempts = Number.isFinite(attempts) ? Math.max(1, Math.floor(attempts)) : 1;
  const base = 30 * Math.pow(2, Math.max(0, safeAttempts - 1));
  return Math.min(3600, Math.max(60, Math.floor(base)));
};

const trimError = (error: unknown) => {
  const raw = error instanceof Error ? error.message : String(error);
  return raw.slice(0, MAX_ERROR_LENGTH);
};

const extractRetryErrorCode = (message: string | null) => {
  if (!message) return null;

  for (const candidate of [
    "user_subscription_not_found",
    "allocateMonthlyCredits_missing_invoice_id",
    "allocateMonthlyCredits_load_subscription_period_failed",
    "allocateMonthlyCredits_missing_subscription_period",
  ]) {
    if (message.includes(candidate)) {
      return candidate;
    }
  }

  return null;
};

const logMonitoringAlert = async (
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
    p_source: "process-stripe-recovery",
    p_entity_type: "stripe_recovery_worker",
    p_entity_id: null,
    p_details: params.details,
  });

  if (error) {
    console.error("[process-stripe-recovery] failed to persist monitoring alert", {
      eventType: params.eventType,
      error: error.message,
    });
  }
};

const invokeStripeWebhookReplay = async (
  supabaseAdmin: SupabaseAdminClient,
  internalPipelineSecret: string,
  params: {
    eventId: string;
    replayReason: string;
  },
) => {
  const { eventId, replayReason } = params;

  const { data, error } = await supabaseAdmin.functions.invoke("stripe-webhook", {
    body: {
      replay_event_id: eventId,
      replay_reason: replayReason,
    },
    headers: {
      "x-internal-secret": internalPipelineSecret,
    },
  });

  const responseBody = asJsonObject(data);
  const responseStatus = asNonEmptyString(responseBody?.status);

  const { data: stripeEventRow, error: stripeEventError } = await supabaseAdmin
    .from("stripe_events")
    .select("id, type, processed, processing_started_at, processed_at, error")
    .eq("id", eventId)
    .maybeSingle();

  if (stripeEventError) {
    throw new Error(`stripe_event_reload_failed:${stripeEventError.message}`);
  }

  const loadedEvent = (stripeEventRow as StripeEventRow | null) ?? null;

  return {
    invokeError: error ? trimError(error) : null,
    responseStatus,
    responseBody,
    stripeEvent: loadedEvent,
    processed: loadedEvent?.processed === true,
  };
};

const postponeFailedCreditAllocation = async (
  supabaseAdmin: SupabaseAdminClient,
  failure: FailedCreditAllocationRow,
  seconds: number,
) => {
  const nowMs = Date.now();
  const nowIso = new Date(nowMs).toISOString();
  const nextRetryAt = new Date(nowMs + seconds * 1000).toISOString();

  const { error } = await supabaseAdmin
    .from("failed_credit_allocations")
    .update({
      updated_at: nowIso,
      next_retry_at: nextRetryAt,
    })
    .eq("id", failure.id);

  if (error) {
    throw new Error(`failed_credit_allocation_postpone_failed:${error.message}`);
  }
};

const markFailedCreditAllocationFailure = async (
  supabaseAdmin: SupabaseAdminClient,
  failure: FailedCreditAllocationRow,
  params: {
    errorMessage: string;
    maxRetries: number;
  },
) => {
  const nextRetryCount = failure.retry_count + 1;
  const backoffSeconds = computeRetryBackoffSeconds(nextRetryCount);
  const nowMs = Date.now();
  const nowIso = new Date(nowMs).toISOString();
  const nextRetryAt = new Date(nowMs + backoffSeconds * 1000).toISOString();
  const errorMessage = params.errorMessage.slice(0, MAX_ERROR_LENGTH);
  const errorCode = extractRetryErrorCode(errorMessage) ?? failure.error_code;

  const { error } = await supabaseAdmin
    .from("failed_credit_allocations")
    .update({
      error_message: errorMessage,
      error_code: errorCode,
      retry_count: nextRetryCount,
      updated_at: nowIso,
      next_retry_at: nextRetryAt,
    })
    .eq("id", failure.id);

  if (error) {
    throw new Error(`failed_credit_allocation_update_failed:${error.message}`);
  }

  if (nextRetryCount >= params.maxRetries) {
    await logMonitoringAlert(supabaseAdmin, {
      eventType: "stripe_credit_allocation_retry_exhausted",
      severity: "critical",
      details: {
        failed_credit_allocation_id: failure.id,
        stripe_event_id: failure.stripe_event_id,
        stripe_invoice_id: failure.stripe_invoice_id,
        stripe_subscription_id: failure.stripe_subscription_id,
        retry_count: nextRetryCount,
        error_message: errorMessage,
      },
    });
  }

  return nextRetryCount;
};

const deleteFailedCreditAllocation = async (
  supabaseAdmin: SupabaseAdminClient,
  failureId: string,
) => {
  const { error } = await supabaseAdmin
    .from("failed_credit_allocations")
    .delete()
    .eq("id", failureId);

  if (error) {
    throw new Error(`failed_credit_allocation_delete_failed:${error.message}`);
  }
};

serveWithErrorHandling("process-stripe-recovery", async (req: Request) => {
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
  const serviceRoleKey = asNonEmptyString(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")) ??
    asNonEmptyString(Deno.env.get("SERVICE_ROLE_KEY"));
  const internalPipelineSecret = asNonEmptyString(Deno.env.get("INTERNAL_PIPELINE_SECRET"));
  if (!supabaseUrl || !serviceRoleKey || !internalPipelineSecret) {
    return jsonResponse(500, { error: "Missing server configuration" });
  }

  const providedInternalSecret = asNonEmptyString(req.headers.get("x-internal-secret"));
  if (!providedInternalSecret || providedInternalSecret !== internalPipelineSecret) {
    return jsonResponse(401, { error: "Unauthorized" });
  }

  const body = parsed.body;
  const staleEventLimit = resolveBatchLimit(body.stale_event_limit, DEFAULT_STALE_EVENT_LIMIT);
  const failedAllocationLimit = resolveBatchLimit(
    body.failed_credit_limit,
    DEFAULT_FAILED_ALLOCATION_LIMIT,
  );
  const maxRetries = resolveMaxRetries(body.max_retries);
  const lockTimeoutMs = getEventProcessingLockTimeoutMs();
  const staleBeforeIso = new Date(Date.now() - lockTimeoutMs).toISOString();

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAdminClient;

  const runId = crypto.randomUUID();
  const runStartedAtMs = Date.now();
  await safeRecordPipelineRunEvent(supabaseAdmin, {
    component: "process-stripe-recovery",
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
      component: "process-stripe-recovery",
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
      component: "process-stripe-recovery",
      runId,
      status: params.status,
      processedCount: params.processedCount,
      errorCount: params.errorCount,
      durationMs,
      config: {
        durationThresholdMs: 15_000,
        zeroProcessedConsecutiveRuns: 3,
        skipZeroProcessedAlert: params.skipZeroProcessedAlert === true,
      },
    });
  };

  const { data: staleEventsData, error: staleEventsError } = await supabaseAdmin
    .from("stripe_events")
    .select("id, type, processed, processing_started_at, processed_at, error")
    .eq("processed", false)
    .not("processing_started_at", "is", null)
    .lt("processing_started_at", staleBeforeIso)
    .order("processing_started_at", { ascending: true })
    .limit(staleEventLimit);

  if (staleEventsError) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "stale_events_query_failed" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to load stale stripe events" });
  }

  const nowIso = new Date().toISOString();
  const { data: failedAllocationsData, error: failedAllocationsError } = await supabaseAdmin
    .from("failed_credit_allocations")
    .select("id, stripe_event_id, stripe_invoice_id, stripe_subscription_id, error_message, error_code, retry_count, next_retry_at")
    .lte("next_retry_at", nowIso)
    .lt("retry_count", maxRetries)
    .order("next_retry_at", { ascending: true })
    .limit(failedAllocationLimit);

  if (failedAllocationsError) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "failed_credit_allocations_query_failed" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to load failed credit allocations" });
  }

  const staleEvents = (staleEventsData as StripeEventRow[] | null) ?? [];
  const failedAllocations = (failedAllocationsData as FailedCreditAllocationRow[] | null) ?? [];
  const failedByEventId = new Map<string, FailedCreditAllocationRow>();

  for (const row of failedAllocations) {
    const eventId = asNonEmptyString(row.stripe_event_id);
    if (eventId && !failedByEventId.has(eventId)) {
      failedByEventId.set(eventId, row);
    }
  }

  const eventIds = new Set<string>();
  for (const staleEvent of staleEvents) {
    if (staleEvent.id) eventIds.add(staleEvent.id);
  }
  for (const eventId of failedByEventId.keys()) {
    eventIds.add(eventId);
  }

  if (eventIds.size === 0) {
    await finalizeRun({
      status: "success",
      processedCount: 0,
      errorCount: 0,
      extraLabels: {
        stale_event_count: 0,
        failed_credit_count: 0,
      },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(200, {
      ok: true,
      recovered_events: 0,
      resolved_failed_credit_allocations: 0,
      retried_failed_credit_allocations: 0,
      deferred_failed_credit_allocations: 0,
      stale_event_count: 0,
      failed_credit_count: 0,
    });
  }

  let recoveredEvents = 0;
  let resolvedFailedCreditAllocations = 0;
  let retriedFailedCreditAllocations = 0;
  let deferredFailedCreditAllocations = 0;
  let errorCount = 0;
  let exhaustedFailedCreditAllocations = 0;

  for (const eventId of eventIds) {
    const relatedFailure = failedByEventId.get(eventId) ?? null;
    const replayReason = relatedFailure ? "failed_credit_allocation_retry" : "stale_processing_recovery";

    try {
      const replayResult = await invokeStripeWebhookReplay(supabaseAdmin, internalPipelineSecret, {
        eventId,
        replayReason,
      });

      if (replayResult.responseStatus === "already_processing") {
        if (relatedFailure) {
          await postponeFailedCreditAllocation(supabaseAdmin, relatedFailure, 60);
          deferredFailedCreditAllocations += 1;
        }
        continue;
      }

      if (replayResult.processed) {
        recoveredEvents += 1;

        if (relatedFailure) {
          await deleteFailedCreditAllocation(supabaseAdmin, relatedFailure.id);
          resolvedFailedCreditAllocations += 1;
        }

        continue;
      }

      const failureMessage = replayResult.invokeError
        ?? asNonEmptyString(replayResult.stripeEvent?.error)
        ?? `stripe_replay_not_processed:${eventId}`;

      if (relatedFailure) {
        const nextRetryCount = await markFailedCreditAllocationFailure(supabaseAdmin, relatedFailure, {
          errorMessage: failureMessage,
          maxRetries,
        });
        retriedFailedCreditAllocations += 1;
        if (nextRetryCount >= maxRetries) {
          exhaustedFailedCreditAllocations += 1;
        }
      } else {
        await logMonitoringAlert(supabaseAdmin, {
          eventType: "stripe_stale_event_replay_failed",
          severity: "warning",
          details: {
            stripe_event_id: eventId,
            replay_reason: replayReason,
            error_message: failureMessage,
          },
        });
      }

      errorCount += 1;
    } catch (error) {
      const failureMessage = trimError(error);

      if (relatedFailure) {
        const nextRetryCount = await markFailedCreditAllocationFailure(supabaseAdmin, relatedFailure, {
          errorMessage: failureMessage,
          maxRetries,
        });
        retriedFailedCreditAllocations += 1;
        if (nextRetryCount >= maxRetries) {
          exhaustedFailedCreditAllocations += 1;
        }
      } else {
        await logMonitoringAlert(supabaseAdmin, {
          eventType: "stripe_stale_event_replay_failed",
          severity: "warning",
          details: {
            stripe_event_id: eventId,
            replay_reason: replayReason,
            error_message: failureMessage,
          },
        });
      }

      errorCount += 1;
    }
  }

  await finalizeRun({
    status: errorCount > 0 ? "failure" : "success",
    processedCount: recoveredEvents,
    errorCount,
    extraLabels: {
      stale_event_count: staleEvents.length,
      failed_credit_count: failedAllocations.length,
      resolved_failed_credit_allocations: resolvedFailedCreditAllocations,
      retried_failed_credit_allocations: retriedFailedCreditAllocations,
      deferred_failed_credit_allocations: deferredFailedCreditAllocations,
      exhausted_failed_credit_allocations: exhaustedFailedCreditAllocations,
    },
    skipZeroProcessedAlert: recoveredEvents === 0 && errorCount === 0,
  });

  return jsonResponse(errorCount > 0 ? 207 : 200, {
    ok: errorCount === 0,
    recovered_events: recoveredEvents,
    resolved_failed_credit_allocations: resolvedFailedCreditAllocations,
    retried_failed_credit_allocations: retriedFailedCreditAllocations,
    deferred_failed_credit_allocations: deferredFailedCreditAllocations,
    exhausted_failed_credit_allocations: exhaustedFailedCreditAllocations,
    stale_event_count: staleEvents.length,
    failed_credit_count: failedAllocations.length,
    stale_before: staleBeforeIso,
  });
});
