import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { serveWithErrorHandling, ApiError } from "../_shared/error-handler.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";
import { extractIpAddress, verifyHcaptchaToken } from "../_shared/hcaptcha.ts";
import { sha256Hex } from "../_shared/hash.ts";

type SignUpRequestBody = {
  email?: string;
  password?: string;
  username?: string;
  fullName?: string;
  captchaToken?: string;
  redirectTo?: string;
};

const EMAIL_REGEX = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

const asNonEmptyString = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

function jsonResponse(payload: unknown, corsHeaders: Record<string, string>, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function createAuthClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");

  if (!supabaseUrl || !anonKey) {
    throw new ApiError(500, "internal_server_error", "Server not configured");
  }

  return createClient(supabaseUrl, anonKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

function createAdminClient() {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");

  if (!supabaseUrl || !serviceRoleKey) {
    throw new ApiError(500, "internal_server_error", "Server not configured");
  }

  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

serveWithErrorHandling("auth-signup", async (req: Request) => {
  const origin = req.headers.get("origin");
  const corsHeaders = resolveCorsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { status: 200, headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: "Method not allowed" }, corsHeaders, 405);
  }

  const body = await req.json().catch(() => {
    throw new ApiError(400, "bad_request", "Invalid JSON body");
  }) as SignUpRequestBody;

  const email = asNonEmptyString(body.email)?.toLowerCase() ?? null;
  const password = asNonEmptyString(body.password);
  const username = asNonEmptyString(body.username);
  const fullName = asNonEmptyString(body.fullName);
  const captchaToken = asNonEmptyString(body.captchaToken);
  const redirectTo = asNonEmptyString(body.redirectTo);

  if (!email || !EMAIL_REGEX.test(email)) {
    throw new ApiError(400, "bad_request", "Invalid email");
  }

  if (!password) {
    throw new ApiError(400, "bad_request", "Missing password");
  }

  // Rate limit by IP (BEFORE captcha verification)
  const ipAddress = extractIpAddress(req) ?? "__unknown_ip__";
  const ipHash = await sha256Hex(ipAddress);

  try {
    const supabaseAdmin = createAdminClient();
    const { error: rateLimitError } = await supabaseAdmin.rpc(
      "rpc_contact_submit_rate_limit",
      { p_ip_hash: ipHash },
    );

    if (rateLimitError) {
      const normalizedMessage = rateLimitError.message.toLowerCase();
      if (normalizedMessage.includes("rate_limit_exceeded")) {
        throw new ApiError(429, "rate_limit_exceeded", "Too many signup attempts");
      }
      throw new ApiError(500, "internal_error", "Rate limit check failed");
    }
  } catch (error) {
    if (error instanceof ApiError) throw error;
    throw new ApiError(500, "internal_error", "Rate limit check failed");
  }

  await verifyHcaptchaToken({
    captchaToken,
    remoteIp: ipAddress,
  });

  const supabase = createAuthClient();
  const { data, error } = await supabase.auth.signUp({
    email,
    password,
    options: {
      emailRedirectTo: redirectTo ?? undefined,
      data: {
        username: username ?? email.split("@")[0],
        full_name: fullName ?? undefined,
      },
    },
  });

  if (error) {
    throw new ApiError(error.status ?? 400, "bad_request", error.message);
  }

  return jsonResponse({
    user: data.user,
    session: data.session,
  }, corsHeaders, 200);
});
