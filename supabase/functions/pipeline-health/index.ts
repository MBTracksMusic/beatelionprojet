import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const JSON_HEADERS = {
  "Content-Type": "application/json",
};

type SupabaseAdminClient = any;

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const jsonResponse = (status: number, payload: Record<string, unknown>) =>
  new Response(JSON.stringify(payload), { status, headers: JSON_HEADERS });

serveWithErrorHandling("pipeline-health", async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: JSON_HEADERS });
  }

  if (req.method !== "GET") {
    return jsonResponse(405, { error: "Method not allowed" });
  }

  const supabaseUrl = asNonEmptyString(Deno.env.get("SUPABASE_URL"));
  const serviceRoleKey = asNonEmptyString(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY"));
  const pipelineHealthSecret = asNonEmptyString(Deno.env.get("PIPELINE_HEALTH_SECRET"));
  if (!supabaseUrl || !serviceRoleKey || !pipelineHealthSecret) {
    return jsonResponse(500, { error: "Missing server configuration" });
  }

  const providedSecret = asNonEmptyString(req.headers.get("x-pipeline-health-secret"));
  if (!providedSecret || providedSecret !== pipelineHealthSecret) {
    return jsonResponse(401, { error: "Unauthorized" });
  }

  const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  }) as SupabaseAdminClient;

  const { data: health, error: healthError } = await supabaseAdmin
    .from("pipeline_health")
    .select("outbox_backlog,email_queue_backlog,failed_emails,avg_latency,events_per_minute")
    .single();

  if (healthError) {
    return jsonResponse(500, { error: "Unable to load pipeline health" });
  }

  const { data: alerts, error: alertsError } = await supabaseAdmin
    .rpc("pipeline_alerts");

  if (alertsError) {
    return jsonResponse(500, { error: "Unable to load pipeline alerts" });
  }

  const activeAlerts = ((alerts as Array<Record<string, unknown>> | null) ?? [])
    .filter((row) => row.is_alert === true);

  return jsonResponse(200, {
    health,
    alerts: (alerts as Array<Record<string, unknown>> | null) ?? [],
    activeAlerts,
  });
});
