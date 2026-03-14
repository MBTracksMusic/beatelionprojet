import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

const DEFAULT_LIMIT = 200;
const MAX_LIMIT = 1000;
const DEFAULT_MINUTES = 60;
const MAX_MINUTES = 24 * 60;

type SupabaseAdminClient = any;

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const asPositiveInt = (value: string | null, fallback: number, max: number) => {
  if (!value) return fallback;
  const parsed = Number(value);
  if (!Number.isFinite(parsed)) return fallback;
  const normalized = Math.trunc(parsed);
  return Math.max(1, Math.min(normalized, max));
};

const jsonResponse = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), { status, headers: JSON_HEADERS });

serveWithErrorHandling("pipeline-metrics", async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: JSON_HEADERS });
  }

  if (req.method !== "GET") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  const supabaseUrl = asNonEmptyString(Deno.env.get("SUPABASE_URL"));
  const serviceRoleKey = asNonEmptyString(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const pipelineMetricsSecret = asNonEmptyString(Deno.env.get("PIPELINE_METRICS_SECRET"));
  if (!supabaseUrl || !serviceRoleKey || !pipelineMetricsSecret) {
    return jsonResponse(500, { error: "Missing server configuration" });
  }

  const providedSecret = asNonEmptyString(req.headers.get("x-pipeline-metrics-secret"));
  if (!providedSecret || providedSecret !== pipelineMetricsSecret) {
    return jsonResponse(401, { error: "Unauthorized" });
  }

  const url = new URL(req.url);
  const limit = asPositiveInt(url.searchParams.get("limit"), DEFAULT_LIMIT, MAX_LIMIT);
  const minutes = asPositiveInt(url.searchParams.get("minutes"), DEFAULT_MINUTES, MAX_MINUTES);
  const component = asNonEmptyString(url.searchParams.get("component"));
  const metricName = asNonEmptyString(url.searchParams.get("metric_name"));

  const sinceIso = new Date(Date.now() - minutes * 60_000).toISOString();

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAdminClient;

  let query = supabaseAdmin
    .from("pipeline_metrics")
    .select("id,component,metric_name,metric_value,labels,created_at")
    .gte("created_at", sinceIso)
    .order("created_at", { ascending: false })
    .limit(limit);

  if (component) {
    query = query.eq("component", component);
  }

  if (metricName) {
    query = query.eq("metric_name", metricName);
  }

  const { data, error } = await query;
  if (error) {
    return jsonResponse(500, { error: "Unable to load pipeline metrics" });
  }

  return jsonResponse(200, {
    filters: {
      component,
      metric_name: metricName,
      limit,
      minutes,
      since: sinceIso,
    },
    metrics: (data as Array<Record<string, unknown>> | null) ?? [],
  });
});
