import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { requireAdminUser } from "../_shared/auth.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const BASE_CORS_HEADERS = {
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type, Authorization, X-Client-Info, Apikey",
};

const DEFAULT_ALLOWED_CORS_ORIGINS = [
  "https://beatelion.com",
  "https://www.beatelion.com",
  "http://localhost:5173",
  "http://127.0.0.1:5173",
  "http://dev.beatelion.local:5173",
];

const DEFAULT_CORS_ORIGIN = DEFAULT_ALLOWED_CORS_ORIGINS[0];

const normalizeOrigin = (value: string): string | null => {
  try {
    return new URL(value).origin;
  } catch {
    return null;
  }
};

const resolveAllowedCorsOrigins = () => {
  const allowed = new Set<string>(DEFAULT_ALLOWED_CORS_ORIGINS);

  const csv = Deno.env.get("CORS_ALLOWED_ORIGINS");
  if (typeof csv === "string" && csv.trim().length > 0) {
    for (const token of csv.split(",")) {
      const normalized = normalizeOrigin(token.trim());
      if (normalized) {
        allowed.add(normalized);
      }
    }
  }

  for (const envValue of [
    Deno.env.get("APP_URL"),
    Deno.env.get("SITE_URL"),
    Deno.env.get("PUBLIC_SITE_URL"),
    Deno.env.get("VITE_APP_URL"),
  ]) {
    if (typeof envValue !== "string") continue;
    const normalized = normalizeOrigin(envValue.trim());
    if (normalized) {
      allowed.add(normalized);
    }
  }

  return allowed;
};

const ALLOWED_CORS_ORIGINS = resolveAllowedCorsOrigins();

const resolveRequestOrigin = (req: Request) => {
  const rawOrigin = req.headers.get("origin");
  if (!rawOrigin) return null;
  const normalized = normalizeOrigin(rawOrigin);
  if (!normalized) return null;
  return ALLOWED_CORS_ORIGINS.has(normalized) ? normalized : null;
};

const buildCorsHeaders = (origin: string | null) => ({
  ...BASE_CORS_HEADERS,
  "Access-Control-Allow-Origin": origin ?? DEFAULT_CORS_ORIGIN,
  "Vary": "Origin",
});

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

serveWithErrorHandling("admin-get-campaign", async (req: Request): Promise<Response> => {
  const requestOrigin = resolveRequestOrigin(req);
  const corsHeaders = buildCorsHeaders(requestOrigin);
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

  try {
    const authContext = await requireAdminUser(req, corsHeaders);
    if ("error" in authContext) {
      return authContext.error;
    }

    const { supabaseAdmin } = authContext;

    const payload = await req.json().catch(() => null) as Record<string, unknown> | null;
    if (!payload || Array.isArray(payload)) {
      return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
        status: 400,
        headers: jsonHeaders,
      });
    }

    const campaignType = asNonEmptyString(payload.campaign_type);
    if (!campaignType) {
      return new Response(JSON.stringify({ error: "Invalid or missing campaign_type" }), {
        status: 400,
        headers: jsonHeaders,
      });
    }

    // Fetch campaign config (slots info)
    const { data: campaignRow, error: campaignError } = await supabaseAdmin
      .from("producer_campaigns")
      .select("type, label, max_slots, is_active, trial_duration")
      .eq("type", campaignType)
      .maybeSingle();

    if (campaignError) {
      console.error("[admin-get-campaign] failed to load campaign", {
        campaignType,
        message: campaignError.message,
      });
      return new Response(JSON.stringify({ error: "Unable to load campaign config" }), {
        status: 500,
        headers: jsonHeaders,
      });
    }

    if (!campaignRow) {
      return new Response(JSON.stringify({ error: "campaign_not_found" }), {
        status: 404,
        headers: jsonHeaders,
      });
    }

    // Fetch producers via safe RPC (admin-checked inside)
    const { data: producers, error: rpcError } = await supabaseAdmin.rpc(
      "admin_list_campaign_producers_safe",
      { p_campaign_type: campaignType },
    );

    if (rpcError) {
      console.error("[admin-get-campaign] RPC error", {
        code: rpcError.code,
        message: rpcError.message,
        campaignType,
      });
      return new Response(JSON.stringify({ error: "rpc_error", message: rpcError.message }), {
        status: 500,
        headers: jsonHeaders,
      });
    }

    const slots_used = Array.isArray(producers) ? producers.length : 0;

    return new Response(
      JSON.stringify({
        campaign: {
          type: campaignRow.type,
          label: campaignRow.label,
          max_slots: campaignRow.max_slots ?? null,
          is_active: campaignRow.is_active,
          trial_duration: campaignRow.trial_duration ?? null,
          slots_used,
          slots_remaining: campaignRow.max_slots != null
            ? Math.max(0, campaignRow.max_slots - slots_used)
            : null,
        },
        producers: producers ?? [],
      }),
      {
        status: 200,
        headers: jsonHeaders,
      },
    );
  } catch (error) {
    console.error("[admin-get-campaign] unexpected error", error);
    return new Response(JSON.stringify({ error: "Internal server error" }), {
      status: 500,
      headers: jsonHeaders,
    });
  }
});
