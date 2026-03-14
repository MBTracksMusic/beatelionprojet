import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 500;
const MAX_ERROR_LENGTH = 500;

type EventType =
  | "USER_SIGNUP"
  | "USER_CONFIRMED"
  | "PRODUCER_ACTIVATED"
  | "BEAT_PURCHASED"
  | "LICENSE_GENERATED"
  | "BATTLE_WON"
  | "COMMENT_RECEIVED";

type EventOutboxRow = {
  id: string;
  event_type: EventType;
  aggregate_type: string | null;
  aggregate_id: string | null;
  user_id: string | null;
  payload: Record<string, unknown> | null;
  source_table: string | null;
  source_record_id: string | null;
  created_at: string;
};

type ReplayRequestRow = {
  id: string;
};

type SupabaseAdminClient = any;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const ALLOWED_EVENT_TYPES = new Set<EventType>([
  "USER_SIGNUP",
  "USER_CONFIRMED",
  "PRODUCER_ACTIVATED",
  "BEAT_PURCHASED",
  "LICENSE_GENERATED",
  "BATTLE_WON",
  "COMMENT_RECEIVED",
]);

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

const asIsoDate = (value: unknown) => {
  const text = asNonEmptyString(value);
  if (!text) return null;
  const parsed = new Date(text);
  if (Number.isNaN(parsed.getTime())) return "INVALID";
  return parsed.toISOString();
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

const resolveLimit = (value: unknown) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return DEFAULT_LIMIT;
  }
  const normalized = Math.trunc(value);
  return Math.max(1, Math.min(normalized, MAX_LIMIT));
};

serveWithErrorHandling("replay-events", async (req: Request) => {
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
  const eventReplaySecret = asNonEmptyString(Deno.env.get("EVENT_REPLAY_SECRET"));
  if (!supabaseUrl || !serviceRoleKey || !eventReplaySecret) {
    return jsonResponse(500, { error: "Missing server configuration" });
  }

  const providedSecret = asNonEmptyString(req.headers.get("x-event-replay-secret"));
  if (!providedSecret || providedSecret !== eventReplaySecret) {
    return jsonResponse(401, { error: "Unauthorized" });
  }

  const body = parsed.body;
  const rawEventType = asNonEmptyString(body.event_type)?.toUpperCase() ?? null;
  const eventType = rawEventType && ALLOWED_EVENT_TYPES.has(rawEventType as EventType)
    ? rawEventType as EventType
    : null;

  if (rawEventType && !eventType) {
    return jsonResponse(400, { error: "Invalid event_type" });
  }

  const userId = body.user_id === undefined ? null : asUuid(body.user_id);
  if (body.user_id !== undefined && !userId) {
    return jsonResponse(400, { error: "Invalid user_id" });
  }

  const aggregateType = asNonEmptyString(body.aggregate_type);

  const aggregateId = body.aggregate_id === undefined ? null : asUuid(body.aggregate_id);
  if (body.aggregate_id !== undefined && !aggregateId) {
    return jsonResponse(400, { error: "Invalid aggregate_id" });
  }

  const fromDate = body.from_date === undefined ? null : asIsoDate(body.from_date);
  if (fromDate === "INVALID") {
    return jsonResponse(400, { error: "Invalid from_date" });
  }

  const toDate = body.to_date === undefined ? null : asIsoDate(body.to_date);
  if (toDate === "INVALID") {
    return jsonResponse(400, { error: "Invalid to_date" });
  }

  if (fromDate && toDate && new Date(fromDate).getTime() > new Date(toDate).getTime()) {
    return jsonResponse(400, { error: "from_date must be before to_date" });
  }

  const limit = resolveLimit(body.limit);
  const requestedBy = body.requested_by === undefined ? null : asUuid(body.requested_by);
  if (body.requested_by !== undefined && !requestedBy) {
    return jsonResponse(400, { error: "Invalid requested_by" });
  }

  const reason = asNonEmptyString(body.reason) ?? "Manual replay";
  const dryRun = body.dry_run === true;

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAdminClient;

  const { data: replayRequest, error: replayRequestError } = await supabaseAdmin
    .from("event_replay_requests")
    .insert({
      event_type: eventType,
      user_id: userId,
      aggregate_type: aggregateType,
      aggregate_id: aggregateId,
      from_date: fromDate,
      to_date: toDate,
      status: "pending",
      requested_by: requestedBy,
      reason,
    })
    .select("id")
    .single();

  if (replayRequestError || !replayRequest?.id) {
    console.error("[replay-events] request insert failed", replayRequestError);
    return jsonResponse(500, { error: "Unable to create replay request" });
  }

  const requestId = (replayRequest as ReplayRequestRow).id;

  try {
    let query = supabaseAdmin
      .from("event_outbox")
      .select("id,event_type,aggregate_type,aggregate_id,user_id,payload,source_table,source_record_id,created_at")
      .eq("status", "processed")
      .order("created_at", { ascending: true })
      .limit(limit);

    if (eventType) {
      query = query.eq("event_type", eventType);
    }

    if (userId) {
      query = query.eq("user_id", userId);
    }

    if (aggregateType) {
      query = query.eq("aggregate_type", aggregateType);
    }

    if (aggregateId) {
      query = query.eq("aggregate_id", aggregateId);
    }

    if (fromDate) {
      query = query.gte("created_at", fromDate);
    }

    if (toDate) {
      query = query.lte("created_at", toDate);
    }

    const { data: sourceRows, error: sourceRowsError } = await query;
    if (sourceRowsError) {
      throw new Error(`source_query_failed:${sourceRowsError.message}`);
    }

    const sourceEvents = (sourceRows as EventOutboxRow[] | null) ?? [];

    if (dryRun) {
      const processedAt = new Date().toISOString();
      await supabaseAdmin
        .from("event_replay_requests")
        .update({
          status: "processed",
          replay_count: sourceEvents.length,
          processed_at: processedAt,
          last_error: null,
        })
        .eq("id", requestId);

      return jsonResponse(200, {
        requestId,
        dryRun: true,
        matchedEvents: sourceEvents.length,
        replayedEvents: 0,
        failedEvents: 0,
      });
    }

    let replayedEvents = 0;
    let failedEvents = 0;
    let skippedEvents = 0;
    let lastError: string | null = null;

    for (let index = 0; index < sourceEvents.length; index += 1) {
      const sourceEvent = sourceEvents[index];
      const replayDedupeKey = `replay:${requestId}:${sourceEvent.id}:${index + 1}`;

      const { error: insertReplayError } = await supabaseAdmin
        .from("event_outbox")
        .insert({
          event_type: sourceEvent.event_type,
          aggregate_type: sourceEvent.aggregate_type,
          aggregate_id: sourceEvent.aggregate_id,
          user_id: sourceEvent.user_id,
          payload: asJsonObject(sourceEvent.payload) ?? {},
          source_table: sourceEvent.source_table ?? "event_replay",
          source_record_id: sourceEvent.source_record_id,
          dedupe_key: replayDedupeKey,
          status: "pending",
          attempts: 0,
          max_attempts: 10,
          replayed_from_event_id: sourceEvent.id,
          replay_reason: reason,
        });

      if (!insertReplayError) {
        replayedEvents += 1;
        continue;
      }

      if (isUniqueViolation(insertReplayError)) {
        skippedEvents += 1;
        continue;
      }

      failedEvents += 1;
      lastError = trimError(insertReplayError);
      console.error("[replay-events] replay insert failed", {
        requestId,
        sourceEventId: sourceEvent.id,
        insertReplayError,
      });
    }

    const processedAt = new Date().toISOString();
    const nextStatus = failedEvents > 0 && replayedEvents === 0 ? "failed" : "processed";

    const { error: updateRequestError } = await supabaseAdmin
      .from("event_replay_requests")
      .update({
        status: nextStatus,
        replay_count: replayedEvents,
        processed_at: processedAt,
        last_error: lastError,
      })
      .eq("id", requestId);

    if (updateRequestError) {
      console.error("[replay-events] request update failed", {
        requestId,
        updateRequestError,
      });
    }

    return jsonResponse(200, {
      requestId,
      dryRun: false,
      matchedEvents: sourceEvents.length,
      replayedEvents,
      skippedEvents,
      failedEvents,
    });
  } catch (error) {
    const processedAt = new Date().toISOString();
    const errorMessage = trimError(error);

    const { error: updateRequestError } = await supabaseAdmin
      .from("event_replay_requests")
      .update({
        status: "failed",
        processed_at: processedAt,
        last_error: errorMessage,
      })
      .eq("id", requestId);

    if (updateRequestError) {
      console.error("[replay-events] request update failed after fatal error", {
        requestId,
        updateRequestError,
      });
    }

    console.error("[replay-events] fatal error", {
      requestId,
      error: errorMessage,
    });

    return jsonResponse(500, { error: "Unable to replay events", requestId });
  }
});
