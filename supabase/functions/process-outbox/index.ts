import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import {
  PIPELINE_ACTIVE_RUN_WINDOW_SECONDS,
  clampReclaimSeconds,
} from "../_shared/eventPipelineConfig.ts";
import {
  isEmailTemplate,
  isUniqueEmailTemplate,
  type EmailTemplate,
} from "../_shared/emailTemplates.ts";
import { safeInsertPipelineMetrics } from "../_shared/pipelineMetrics.ts";
import {
  safeEmitPipelineRunAlerts,
  safeRecordPipelineRunEvent,
} from "../_shared/pipelineRunMonitoring.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

const MAX_BATCH_SIZE = 50;
const MAX_ERROR_LENGTH = 500;

type EventType =
  | "USER_SIGNUP"
  | "USER_CONFIRMED"
  | "PRODUCER_ACTIVATED"
  | "BEAT_PURCHASED"
  | "LICENSE_GENERATED"
  | "BATTLE_WON"
  | "COMMENT_RECEIVED";

type PipelineMode = "compatibility" | "direct_handlers";

type EventOutboxRow = {
  id: string;
  event_id: string | null;
  event_type: EventType;
  aggregate_type: string | null;
  aggregate_id: string | null;
  user_id: string | null;
  payload: Record<string, unknown> | null;
  source_table: string | null;
  source_record_id: string | null;
  dedupe_key: string | null;
  status: "pending" | "processing" | "processed" | "failed";
  attempts: number;
  max_attempts: number;
  last_error: string | null;
  locked_at: string | null;
  created_at: string;
  processed_at: string | null;
  replayed_from_event_id: string | null;
  replay_reason: string | null;
};

type EventBusInsert = {
  event_type: EventType;
  aggregate_type: string | null;
  aggregate_id: string | null;
  user_id: string | null;
  payload: Record<string, unknown>;
  status: "pending";
  source_outbox_id: string;
};

type EventHandler = {
  event_type: EventType;
  handler_type: "email";
  handler_key: string;
  is_active: boolean;
};

type SupabaseAdminClient = any;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

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

const asUuid = (value: unknown) => {
  const text = asNonEmptyString(value);
  if (!text || !UUID_RE.test(text)) return null;
  return text;
};

const normalizeEmail = (value: unknown) => {
  const email = asNonEmptyString(value);
  if (!email) return null;
  return email.toLowerCase();
};

const trimError = (error: unknown) => {
  const raw = error instanceof Error ? error.message : String(error);
  return raw.slice(0, MAX_ERROR_LENGTH);
};

const isUniqueViolation = (error: unknown) => {
  if (!error || typeof error !== "object") return false;
  const maybeCode = (error as { code?: unknown }).code;
  return maybeCode === "23505";
};

const toTemplate = (value: unknown): EmailTemplate | null =>
  isEmailTemplate(value) ? value : null;

const resolvePipelineMode = (value: string | null): PipelineMode => {
  if (value === "direct_handlers") return "direct_handlers";
  return "compatibility";
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

const resolveBatchLimit = (value: unknown) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return MAX_BATCH_SIZE;
  }
  const normalized = Math.trunc(value);
  return Math.max(1, Math.min(normalized, MAX_BATCH_SIZE));
};

const resolveReclaimSeconds = (value: unknown) => clampReclaimSeconds(value);

const getOrCreateEventBusId = async (
  supabaseAdmin: SupabaseAdminClient,
  outboxEvent: EventOutboxRow,
) => {
  const payload = asJsonObject(outboxEvent.payload) ?? {};
  const eventBusPayload: Record<string, unknown> = {
    ...payload,
    outbox_id: outboxEvent.id,
  };

  if (outboxEvent.replayed_from_event_id) {
    eventBusPayload.replayed_from_outbox_id = outboxEvent.replayed_from_event_id;
  }

  if (outboxEvent.replay_reason) {
    eventBusPayload.replay_reason = outboxEvent.replay_reason;
  }

  const existingEventId = asUuid(outboxEvent.event_id);
  if (existingEventId) {
    const { data: existingById, error: selectByIdError } = await supabaseAdmin
      .from("event_bus")
      .select("id")
      .eq("id", existingEventId)
      .maybeSingle();

    if (!selectByIdError && existingById?.id) {
      return existingById.id as string;
    }
  }

  const insertPayload: EventBusInsert = {
    event_type: outboxEvent.event_type,
    aggregate_type: outboxEvent.aggregate_type,
    aggregate_id: outboxEvent.aggregate_id,
    user_id: outboxEvent.user_id,
    payload: eventBusPayload,
    status: "pending",
    source_outbox_id: outboxEvent.id,
  };

  const { data: inserted, error: insertError } = await supabaseAdmin
    .from("event_bus")
    .insert(insertPayload)
    .select("id")
    .maybeSingle();

  if (!insertError && inserted?.id) {
    return inserted.id as string;
  }

  if (insertError && !isUniqueViolation(insertError)) {
    throw new Error(`event_bus_insert_failed:${insertError.message}`);
  }

  const { data: existingBySource, error: selectBySourceError } = await supabaseAdmin
    .from("event_bus")
    .select("id")
    .eq("source_outbox_id", outboxEvent.id)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();

  if (selectBySourceError) {
    throw new Error(`event_bus_select_failed:${selectBySourceError.message}`);
  }

  if (!existingBySource?.id) {
    throw new Error("event_bus_row_not_found_after_conflict");
  }

  return existingBySource.id as string;
};

const resolveEmailForOutbox = async (
  supabaseAdmin: SupabaseAdminClient,
  outboxEvent: EventOutboxRow,
  cache: Map<string, string | null>,
) => {
  const payloadEmail = normalizeEmail(outboxEvent.payload?.email);
  if (payloadEmail) return payloadEmail;

  const payloadRecipient = normalizeEmail(outboxEvent.payload?.recipient_email);
  if (payloadRecipient) return payloadRecipient;

  const userId = asNonEmptyString(outboxEvent.user_id);
  if (!userId) return null;

  if (cache.has(userId)) {
    return cache.get(userId) ?? null;
  }

  const { data, error } = await supabaseAdmin
    .from("user_profiles")
    .select("email")
    .eq("id", userId)
    .maybeSingle();

  if (error) {
    throw new Error(`resolve_email_from_profile_failed:${error.message}`);
  }

  const resolved = normalizeEmail((data as { email?: string | null } | null)?.email ?? null);
  cache.set(userId, resolved);
  return resolved;
};

const loadDirectEmailHandlers = async (supabaseAdmin: SupabaseAdminClient) => {
  const { data: handlersData, error: handlersError } = await supabaseAdmin
    .from("event_handlers")
    .select("event_type, handler_type, handler_key, is_active")
    .eq("is_active", true)
    .eq("handler_type", "email");

  if (handlersError) {
    throw new Error(`load_event_handlers_failed:${handlersError.message}`);
  }

  const handlers = ((handlersData as EventHandler[] | null) ?? [])
    .filter((row) => row.handler_type === "email" && row.is_active === true);

  const mapping = new Map<EventType, EmailTemplate>();
  for (const handler of handlers) {
    const template = toTemplate(handler.handler_key);
    if (!template) continue;
    if (!mapping.has(handler.event_type)) {
      mapping.set(handler.event_type, template);
    }
  }

  return mapping;
};

const enqueueEmailFromOutbox = async (
  supabaseAdmin: SupabaseAdminClient,
  outboxEvent: EventOutboxRow,
  template: EmailTemplate,
  recipientEmail: string,
) => {
  const queuePayload = {
    ...(outboxEvent.payload ?? {}),
    outbox_id: outboxEvent.id,
    event_id: outboxEvent.event_id,
    event_type: outboxEvent.event_type,
    event_created_at: outboxEvent.created_at,
    aggregate_type: outboxEvent.aggregate_type,
    aggregate_id: outboxEvent.aggregate_id,
    user_id: outboxEvent.user_id,
  };

  const queueUserId = isUniqueEmailTemplate(template)
    ? outboxEvent.user_id
    : null;

  const { error } = await supabaseAdmin
    .from("email_queue")
    .upsert(
      {
        source_event_id: asUuid(outboxEvent.event_id),
        source_outbox_id: outboxEvent.id,
        user_id: queueUserId,
        email: recipientEmail,
        template,
        payload: queuePayload,
        status: "pending",
      },
      {
        onConflict: "source_outbox_id",
        ignoreDuplicates: true,
      },
    );

  if (error) {
    throw new Error(`email_queue_upsert_failed:${error.message}`);
  }
};

serveWithErrorHandling("process-outbox", async (req: Request) => {
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

  const pipelineMode = resolvePipelineMode(asNonEmptyString(Deno.env.get("EVENT_PIPELINE_MODE")));

  const body = parsed.body;
  const limit = resolveBatchLimit(body.limit);
  const reclaimAfterSeconds = resolveReclaimSeconds(body.reclaim_after_seconds);

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAdminClient;
  const runId = crypto.randomUUID();
  const runStartedAtMs = Date.now();
  await safeRecordPipelineRunEvent(supabaseAdmin, {
    component: "process-outbox",
    runId,
    status: "start",
    labels: {
      mode: pipelineMode,
    },
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
      component: "process-outbox",
      runId,
      status: params.status,
      processedCount: params.processedCount,
      errorCount: params.errorCount,
      durationMs,
      labels: {
        mode: pipelineMode,
        ...(params.extraLabels ?? {}),
        ...(params.skipZeroProcessedAlert ? { skip_zero_processed_alert: true } : {}),
      },
    });
    await safeEmitPipelineRunAlerts(supabaseAdmin, {
      component: "process-outbox",
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

  const activeLockThreshold = new Date(Date.now() - PIPELINE_ACTIVE_RUN_WINDOW_SECONDS * 1000).toISOString();
  const { count: activeProcessingCount, error: activeCountError } = await supabaseAdmin
    .from("event_outbox")
    .select("id", { head: true, count: "exact" })
    .eq("status", "processing")
    .gte("locked_at", activeLockThreshold);

  if (activeCountError) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "active_lock_query_failed" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to verify outbox worker state" });
  }

  if ((activeProcessingCount ?? 0) > 0) {
    await finalizeRun({
      status: "success",
      processedCount: 0,
      errorCount: 0,
      extraLabels: { reason: "already_processing" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(429, {
      error: "Outbox worker is already processing",
      activeProcessingCount,
    });
  }

  const { data: claimedRows, error: claimError } = await supabaseAdmin.rpc("claim_outbox_batch", {
    p_limit: limit,
    p_reclaim_after_seconds: reclaimAfterSeconds,
  });

  if (claimError) {
    await finalizeRun({
      status: "failure",
      processedCount: 0,
      errorCount: 1,
      extraLabels: { reason: "claim_batch_failed" },
      skipZeroProcessedAlert: true,
    });
    return jsonResponse(500, { error: "Unable to claim outbox batch" });
  }

  const events = (claimedRows as EventOutboxRow[] | null) ?? [];
  if (events.length === 0) {
    const { count: queueBacklogCount, error: queueBacklogError } = await supabaseAdmin
      .from("event_outbox")
      .select("id", { head: true, count: "exact" })
      .eq("status", "pending");

    if (queueBacklogError) {
      await finalizeRun({
        status: "failure",
        processedCount: 0,
        errorCount: 1,
        extraLabels: { reason: "backlog_query_failed" },
      });
      return jsonResponse(500, { error: "Unable to load outbox backlog" });
    }

    const metricsInserted = await safeInsertPipelineMetrics(
      supabaseAdmin,
      [
        {
          component: "process-outbox",
          metricName: "events_processed",
          metricValue: 0,
          labels: { mode: pipelineMode },
        },
        {
          component: "process-outbox",
          metricName: "events_failed",
          metricValue: 0,
          labels: { mode: pipelineMode },
        },
        {
          component: "process-outbox",
          metricName: "queue_backlog",
          metricValue: queueBacklogCount ?? 0,
          labels: { queue: "event_outbox", status: "pending", mode: pipelineMode },
        },
      ],
      "process-outbox",
    );

    if (!metricsInserted) {
      await finalizeRun({
        status: "failure",
        processedCount: 0,
        errorCount: 1,
        extraLabels: { reason: "metrics_insert_failed" },
      });
      return jsonResponse(500, { error: "Unable to write pipeline metrics" });
    }

    await finalizeRun({
      status: "success",
      processedCount: 0,
      errorCount: 0,
      extraLabels: {
        succeeded: 0,
        failed: 0,
        pending_retry: 0,
        synced_to_event_bus: 0,
        enqueued_emails: 0,
      },
    });

    return jsonResponse(200, {
      mode: pipelineMode,
      processed: 0,
      succeeded: 0,
      failed: 0,
      pendingRetry: 0,
      syncedToEventBus: 0,
      enqueuedEmails: 0,
    });
  }

  let directHandlersByEvent: Map<EventType, EmailTemplate> | null = null;
  if (pipelineMode === "direct_handlers") {
    try {
      directHandlersByEvent = await loadDirectEmailHandlers(supabaseAdmin);
    } catch (error) {
      await finalizeRun({
        status: "failure",
        processedCount: 0,
        errorCount: 1,
        extraLabels: {
          reason: "load_direct_handlers_failed",
          load_error: error instanceof Error ? error.message : String(error),
        },
      });
      return jsonResponse(500, { error: "Unable to load direct handlers" });
    }
  }

  const emailCache = new Map<string, string | null>();

  let succeeded = 0;
  let failed = 0;
  let pendingRetry = 0;
  let syncedToEventBus = 0;
  let enqueuedEmails = 0;
  let stateUpdateFailures = 0;
  const stageLatenciesMs: number[] = [];

  for (const outboxEvent of events) {
    console.log("[process-outbox] processing event", {
      outboxId: outboxEvent.id,
      eventType: outboxEvent.event_type,
      mode: pipelineMode,
      attempt: outboxEvent.attempts + 1,
      maxAttempts: outboxEvent.max_attempts,
    });

    try {
      const nowIso = new Date().toISOString();

      if (pipelineMode === "direct_handlers") {
        const template = directHandlersByEvent?.get(outboxEvent.event_type) ?? null;

        if (template) {
          const recipientEmail = await resolveEmailForOutbox(supabaseAdmin, outboxEvent, emailCache);
          if (!recipientEmail) {
            throw new Error("missing_recipient_email");
          }

          await enqueueEmailFromOutbox(supabaseAdmin, outboxEvent, template, recipientEmail);
          enqueuedEmails += 1;
        }

        const { error: updateProcessedError } = await supabaseAdmin
          .from("event_outbox")
          .update({
            status: "processed",
            processed_at: nowIso,
            locked_at: null,
            last_error: null,
          })
          .eq("id", outboxEvent.id)
          .eq("status", "processing");

        if (updateProcessedError) {
          throw new Error(`event_outbox_update_processed_failed:${updateProcessedError.message}`);
        }
      } else {
        const eventBusId = await getOrCreateEventBusId(supabaseAdmin, outboxEvent);

        const { error: updateProcessedError } = await supabaseAdmin
          .from("event_outbox")
          .update({
            event_id: eventBusId,
            status: "processed",
            processed_at: nowIso,
            locked_at: null,
            last_error: null,
          })
          .eq("id", outboxEvent.id)
          .eq("status", "processing");

        if (updateProcessedError) {
          throw new Error(`event_outbox_update_processed_failed:${updateProcessedError.message}`);
        }

        syncedToEventBus += 1;
      }

      const latencyMs = Date.now() - new Date(outboxEvent.created_at).getTime();
      if (Number.isFinite(latencyMs) && latencyMs >= 0) {
        stageLatenciesMs.push(latencyMs);
      }

      succeeded += 1;
    } catch (error) {
      const nextAttempts = outboxEvent.attempts + 1;
      const nextStatus = nextAttempts >= outboxEvent.max_attempts ? "failed" : "pending";
      const nowIso = new Date().toISOString();
      const lastError = trimError(error);

      console.error("[process-outbox] processing failed", {
        outboxId: outboxEvent.id,
        eventType: outboxEvent.event_type,
        nextStatus,
        lastError,
      });

      const { error: updateFailedError } = await supabaseAdmin
        .from("event_outbox")
        .update({
          attempts: nextAttempts,
          status: nextStatus,
          processed_at: nextStatus === "failed" ? nowIso : null,
          locked_at: null,
          last_error: lastError,
        })
        .eq("id", outboxEvent.id)
        .eq("status", "processing");

      if (updateFailedError) {
        console.error("[process-outbox] outbox update failed", {
          outboxId: outboxEvent.id,
          updateFailedError,
        });
        stateUpdateFailures += 1;
      }

      if (nextStatus === "failed") {
        failed += 1;
      } else {
        pendingRetry += 1;
      }
    }
  }

  const avgStageLatencyMs = stageLatenciesMs.length
    ? stageLatenciesMs.reduce((sum, value) => sum + value, 0) / stageLatenciesMs.length
    : 0;

  const { count: queueBacklogCount, error: queueBacklogError } = await supabaseAdmin
    .from("event_outbox")
    .select("id", { head: true, count: "exact" })
    .eq("status", "pending");

  if (queueBacklogError) {
    await finalizeRun({
      status: "failure",
      processedCount: events.length,
      errorCount: failed + pendingRetry + stateUpdateFailures + 1,
      extraLabels: { reason: "backlog_query_failed" },
    });
    return jsonResponse(500, { error: "Unable to load outbox backlog" });
  }

  const metricsInserted = await safeInsertPipelineMetrics(
    supabaseAdmin,
    [
      {
        component: "process-outbox",
        metricName: "events_processed",
        metricValue: succeeded,
        labels: { mode: pipelineMode },
      },
      {
        component: "process-outbox",
        metricName: "events_failed",
        metricValue: failed,
        labels: { mode: pipelineMode },
      },
      {
        component: "process-outbox",
        metricName: "pipeline_latency_ms",
        metricValue: avgStageLatencyMs,
        labels: { stage: "outbox_processing", mode: pipelineMode },
      },
      {
        component: "process-outbox",
        metricName: "queue_backlog",
        metricValue: queueBacklogCount ?? 0,
        labels: { queue: "event_outbox", status: "pending", mode: pipelineMode },
      },
    ],
    "process-outbox",
  );

  if (!metricsInserted) {
    await finalizeRun({
      status: "failure",
      processedCount: events.length,
      errorCount: failed + pendingRetry + stateUpdateFailures + 1,
      extraLabels: { reason: "metrics_insert_failed" },
    });
    return jsonResponse(500, { error: "Unable to write pipeline metrics" });
  }

  const runErrorCount = failed + pendingRetry + stateUpdateFailures;
  await finalizeRun({
    status: runErrorCount > 0 ? "failure" : "success",
    processedCount: events.length,
    errorCount: runErrorCount,
    extraLabels: {
      succeeded,
      failed,
      pending_retry: pendingRetry,
      synced_to_event_bus: syncedToEventBus,
      enqueued_emails: enqueuedEmails,
      state_update_failures: stateUpdateFailures,
    },
  });

  return jsonResponse(200, {
    mode: pipelineMode,
    processed: events.length,
    succeeded,
    failed,
    pendingRetry,
    syncedToEventBus,
    enqueuedEmails,
  });
});
