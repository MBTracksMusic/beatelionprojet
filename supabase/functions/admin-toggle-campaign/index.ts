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

type CampaignUpdate = {
  is_active: boolean;
  max_slots?: number | null;
};

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const hasOwn = (value: Record<string, unknown>, key: string) =>
  Object.prototype.hasOwnProperty.call(value, key);

const asMaxSlots = (value: unknown) => {
  if (value === null) return null;
  if (typeof value === "number" && Number.isInteger(value) && value > 0) return value;
  if (typeof value === "string" && value.trim().length > 0) {
    const parsed = Number(value);
    if (Number.isInteger(parsed) && parsed > 0) return parsed;
  }
  return undefined;
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
  const shouldUpdateMaxSlots = hasOwn(payload, "max_slots");
  const maxSlots = shouldUpdateMaxSlots ? asMaxSlots(payload.max_slots) : undefined;

  if (!campaignType || typeof isActive !== "boolean") {
    return new Response(JSON.stringify({ error: "Invalid campaign_type or is_active" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  if (shouldUpdateMaxSlots && maxSlots === undefined) {
    return new Response(JSON.stringify({ error: "Invalid max_slots" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  if (typeof maxSlots === "number") {
    const { count, error: countError } = await (authContext.supabaseAdmin as any)
      .from("user_profiles")
      .select("id", { count: "exact", head: true })
      .eq("producer_campaign_type", campaignType);

    if (countError) {
      console.error("[admin-toggle-campaign] slot count failed", {
        functionVersion: FUNCTION_VERSION,
        campaignType,
        code: countError.code,
        message: countError.message,
      });
      return new Response(JSON.stringify({ error: "campaign_slot_count_failed" }), {
        status: 500,
        headers: jsonHeaders,
      });
    }

    const slotsUsed = typeof count === "number" ? count : 0;
    if (maxSlots < slotsUsed) {
      return new Response(
        JSON.stringify({
          error: "campaign_slots_below_used",
          message: `max_slots must be greater than or equal to current slots used (${slotsUsed})`,
          slots_used: slotsUsed,
        }),
        {
          status: 409,
          headers: jsonHeaders,
        },
      );
    }
  }

  const update: CampaignUpdate = { is_active: isActive };
  if (shouldUpdateMaxSlots) {
    update.max_slots = maxSlots ?? null;
  }

  const { data, error } = await (authContext.supabaseAdmin as any)
    .from("producer_campaigns")
    .update(update)
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
