import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { requireAdminUser } from "../_shared/auth.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const FUNCTION_VERSION = "2026-05-22-admin-toggle-campaign-1";

type CampaignRow = {
  type: string;
  label: string;
  max_slots: number | null;
  is_active: boolean;
  trial_duration: string | null;
};

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

serveWithErrorHandling("admin-toggle-campaign", async (req: Request): Promise<Response> => {
  const corsHeaders = resolveCorsHeaders(req.headers.get("origin")) as Record<string, string>;
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const authContext = await requireAdminUser(req, corsHeaders);
  if ("error" in authContext) return authContext.error;

  const payload = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload || Array.isArray(payload)) {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const campaignType = asNonEmptyString(payload.campaign_type);
  const isActive = payload.is_active;

  if (!campaignType || typeof isActive !== "boolean") {
    return new Response(JSON.stringify({ error: "Invalid campaign_type or is_active" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const { data, error } = await (authContext.supabaseAdmin as any)
    .from("producer_campaigns")
    .update({ is_active: isActive })
    .eq("type", campaignType)
    .select("type, label, max_slots, is_active, trial_duration")
    .maybeSingle();

  if (error) {
    console.error("[admin-toggle-campaign] update failed", {
      functionVersion: FUNCTION_VERSION,
      campaignType,
      isActive,
      code: error.code,
      message: error.message,
    });
    return new Response(JSON.stringify({ error: "campaign_update_failed" }), {
      status: 500,
      headers: jsonHeaders,
    });
  }

  const campaign = data as CampaignRow | null;
  if (!campaign) {
    return new Response(JSON.stringify({ error: "campaign_not_found" }), {
      status: 404,
      headers: jsonHeaders,
    });
  }

  return new Response(JSON.stringify({
    ok: true,
    campaign,
  }), {
    status: 200,
    headers: jsonHeaders,
  });
});
