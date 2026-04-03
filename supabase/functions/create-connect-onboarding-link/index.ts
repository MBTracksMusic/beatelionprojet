import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "npm:@supabase/supabase-js@2";
import Stripe from "npm:stripe@17";

const stripe = new Stripe(Deno.env.get("STRIPE_SECRET_KEY") || "");

const PRODUCTION_SITE_URL = "https://beatelion.com";
const STAGING_SITE_URL = "https://beatelion-staging.vercel.app";

const asNonEmptyString = (value: string | null | undefined): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const normalizeSiteUrl = (value: string | null | undefined): string | null => {
  const candidate = asNonEmptyString(value);
  if (!candidate) return null;

  try {
    const parsed = new URL(candidate);
    if (!["http:", "https:"].includes(parsed.protocol)) {
      return null;
    }

    return parsed.toString().replace(/\/+$/, "");
  } catch {
    return null;
  }
};

const getAppUrl = (): string => {
  const environment = (asNonEmptyString(Deno.env.get("ENVIRONMENT")) ?? "development").toLowerCase();

  for (const candidate of [
    Deno.env.get("SITE_URL"),
    Deno.env.get("PUBLIC_SITE_URL"),
  ]) {
    const normalized = normalizeSiteUrl(candidate);
    if (normalized) {
      return normalized;
    }
  }

  if (environment === "production") {
    return PRODUCTION_SITE_URL;
  }

  if (environment === "staging" || environment === "preview") {
    return STAGING_SITE_URL;
  }

  const appUrl = normalizeSiteUrl(Deno.env.get("APP_URL"));
  if (appUrl) {
    return appUrl;
  }

  throw new Error("SITE_URL environment variable not set");
};

Deno.serve(async (req: Request) => {
  // CORS preflight
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type, Authorization",
      },
    });
  }

  // Only POST allowed
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Method not allowed" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    // Extract authorization header
    const authHeader = req.headers.get("Authorization");
    if (!authHeader || !authHeader.startsWith("Bearer ")) {
      return new Response(
        JSON.stringify({ error: "Missing or invalid authorization" }),
        { status: 401, headers: { "Content-Type": "application/json" } }
      );
    }

    const token = authHeader.slice(7);

    // Initialize Supabase admin client
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
    );

    // Verify token and get user claims
    const { data, error: authError } = await supabaseAdmin.auth.getClaims(token);
    if (authError || !data?.claims?.sub) {
      return new Response(JSON.stringify({ error: "Unauthorized" }), {
        status: 401,
        headers: { "Content-Type": "application/json" },
      });
    }

    const userId = data.claims.sub;

    // Fetch user profile with account ID
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("user_profiles")
      .select("id, stripe_account_id")
      .eq("id", userId)
      .single();

    if (profileError || !profile) {
      return new Response(
        JSON.stringify({ error: "User profile not found" }),
        { status: 404, headers: { "Content-Type": "application/json" } }
      );
    }

    // Validate account ID exists
    if (!profile.stripe_account_id) {
      return new Response(
        JSON.stringify({ error: "No Stripe account found. Create one first." }),
        { status: 400, headers: { "Content-Type": "application/json" } }
      );
    }

    const appUrl = getAppUrl();
    const returnUrl = `${appUrl}/producer/onboarding/complete`;
    const refreshUrl = `${appUrl}/producer/onboarding/refresh`;

    console.log("[create-connect-onboarding-link] Redirect URLs", {
      environment: Deno.env.get("ENVIRONMENT") ?? "development",
      appUrl,
      returnUrl,
      refreshUrl,
    });

    // Create onboarding link
    const accountLink = await stripe.accountLinks.create({
      account: profile.stripe_account_id,
      type: "account_onboarding",
      return_url: returnUrl,
      refresh_url: refreshUrl,
    });

    console.log("[create-connect-onboarding-link] Link created", {
      userId,
      accountId: profile.stripe_account_id,
      expiresAt: new Date(accountLink.expires_at * 1000).toISOString(),
    });

    return new Response(
      JSON.stringify({
        url: accountLink.url,
        expires_at: accountLink.expires_at,
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      }
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("[create-connect-onboarding-link] Error", { message });
    return new Response(
      JSON.stringify({ error: "Internal server error", details: message }),
      { status: 500, headers: { "Content-Type": "application/json" } }
    );
  }
});
