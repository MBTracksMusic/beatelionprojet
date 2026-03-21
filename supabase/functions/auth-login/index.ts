import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import { serveWithErrorHandling, ApiError } from "../_shared/error-handler.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";
import { extractIpAddress, verifyHcaptchaToken } from "../_shared/hcaptcha.ts";

type LoginRequestBody = {
  email?: string;
  password?: string;
  captchaToken?: string;
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

serveWithErrorHandling("auth-login", async (req: Request) => {
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
  }) as LoginRequestBody;

  const email = asNonEmptyString(body.email)?.toLowerCase() ?? null;
  const password = asNonEmptyString(body.password);
  const captchaToken = asNonEmptyString(body.captchaToken);

  if (!email || !EMAIL_REGEX.test(email)) {
    throw new ApiError(400, "bad_request", "Invalid email");
  }

  if (!password) {
    throw new ApiError(400, "bad_request", "Missing password");
  }

  await verifyHcaptchaToken({
    captchaToken,
    remoteIp: extractIpAddress(req),
  });

  const supabase = createAuthClient();
  const { data, error } = await supabase.auth.signInWithPassword({
    email,
    password,
  });

  if (error) {
    throw new ApiError(error.status ?? 400, "bad_request", error.message);
  }

  return jsonResponse({
    user: data.user,
    session: data.session,
  }, corsHeaders, 200);
});
