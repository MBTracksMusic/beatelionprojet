import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { ApiError, serveWithErrorHandling } from "../_shared/error-handler.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";

type WaitlistRequestBody = {
  email?: string;
};

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
const RATE_LIMIT_MAX = 5;

const asNonEmptyString = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const extractIpAddress = (req: Request): string => {
  const candidates = [
    req.headers.get("cf-connecting-ip"),
    req.headers.get("x-real-ip"),
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null,
  ];

  for (const candidate of candidates) {
    const value = asNonEmptyString(candidate);
    if (value) return value;
  }

  return "unknown";
};

const createAdminClient = () => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceRoleKey) {
    throw new ApiError(500, "internal_server_error", "Server not configured");
  }

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: {
      persistSession: false,
      autoRefreshToken: false,
    },
  });
};

serveWithErrorHandling("waitlist-submit", async (req: Request) => {
  const corsHeaders = resolveCorsHeaders(req.headers.get("origin"));
  const jsonHeaders = { ...corsHeaders, "Content-Type": "application/json" };

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: jsonHeaders,
    });
  }

  const body = await req.json().catch(() => {
    throw new ApiError(400, "bad_request", "Invalid JSON body");
  }) as WaitlistRequestBody;

  const email = asNonEmptyString(body.email)?.toLowerCase() ?? null;
  if (!email || !EMAIL_REGEX.test(email)) {
    throw new ApiError(400, "bad_request", "Invalid email");
  }

  const supabaseAdmin = createAdminClient();
  const rateLimitKey = `waitlist-submit:${extractIpAddress(req)}`;
  const { data: allowed, error: rateLimitError } = await supabaseAdmin.rpc("check_rate_limit", {
    p_key: rateLimitKey,
    p_limit: RATE_LIMIT_MAX,
  });

  if (rateLimitError) {
    throw new ApiError(500, "internal_server_error", "Rate limit unavailable");
  }

  if (!allowed) {
    throw new ApiError(429, "forbidden", "Too many requests");
  }

  const { error: insertError } = await supabaseAdmin
    .from("waitlist")
    .insert({ email });

  if (insertError) {
    if (insertError.code === "23505") {
      return new Response(JSON.stringify({ status: "duplicate" }), {
        status: 200,
        headers: jsonHeaders,
      });
    }

    throw new ApiError(500, "internal_server_error", "Unable to save email");
  }

  return new Response(JSON.stringify({ status: "ok" }), {
    status: 200,
    headers: jsonHeaders,
  });
});
