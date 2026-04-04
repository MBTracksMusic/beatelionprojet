import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface StripeConnectRequest {
  action: "create_account_link" | "get_status";
}

interface StripeConnectResponse {
  url?: string;
  stripe_account_id?: string;
  charges_enabled?: boolean;
  details_submitted?: boolean;
  error?: string;
}

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

const resolveAppUrl = (): string => {
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

  return "http://localhost:5173";
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  try {
    // Get auth header
    const authHeader = req.headers.get("Authorization");
    if (!authHeader) {
      return new Response(
        JSON.stringify({ error: "Missing authorization header" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Initialize Supabase client with service role
    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
    );

    // Get user from auth header
    const token = authHeader.replace("Bearer ", "");
    const { data, error: authError } = await supabaseAdmin.auth.getClaims(token);

    if (authError || !data?.claims?.sub) {
      return new Response(
        JSON.stringify({ error: "Unauthorized" }),
        { status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const userId = data.claims.sub;
    const body: StripeConnectRequest = await req.json();
    const stripeSecretKey = Deno.env.get("STRIPE_SECRET_KEY");

    if (!stripeSecretKey) {
      throw new Error("Missing STRIPE_SECRET_KEY environment variable");
    }

    // Get user profile
    const { data: profile, error: profileError } = await supabaseAdmin
      .from("user_profiles")
      .select("stripe_account_id, is_producer_active, stripe_account_charges_enabled, stripe_account_details_submitted")
      .eq("id", userId)
      .single();

    if (profileError || !profile) {
      return new Response(
        JSON.stringify({ error: "User profile not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!profile.is_producer_active) {
      return new Response(
        JSON.stringify({ error: "User is not a producer" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Handle different actions
    if (body.action === "create_account_link") {
      return await handleCreateAccountLink(
        userId,
        profile,
        supabaseAdmin,
        stripeSecretKey,
        corsHeaders
      );
    } else if (body.action === "get_status") {
      return await handleGetStatus(profile, corsHeaders);
    } else {
      return new Response(
        JSON.stringify({ error: "Invalid action" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  } catch (error) {
    console.error("[stripe-connect-onboarding] Error:", error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : "Internal server error",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});

async function handleCreateAccountLink(
  userId: string,
  profile: any,
  supabaseAdmin: any,
  stripeSecretKey: string,
  corsHeaders: any
): Promise<Response> {
  let stripeAccountId = profile.stripe_account_id;
  const appUrl = resolveAppUrl();
  const returnUrl = `${appUrl}/producer`;
  const refreshUrl = `${appUrl}/producer`;

  // If no account exists, create one
  if (!stripeAccountId) {
    const accountResponse = await fetch("https://api.stripe.com/v1/accounts", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeSecretKey}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: "type=express&capabilities[card_payments][requested]=true&capabilities[transfers][requested]=true",
    });

    const account = await accountResponse.json();

    if (account.error) {
      return new Response(
        JSON.stringify({ error: account.error.message }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    stripeAccountId = account.id;

    // Save account ID to database
    const { error: updateError } = await supabaseAdmin
      .from("user_profiles")
      .update({
        stripe_account_id: stripeAccountId,
        stripe_account_created_at: new Date().toISOString(),
      })
      .eq("id", userId);

    if (updateError) {
      console.error("[stripe-connect-onboarding] Failed to save account ID:", updateError);

      // Check for unique constraint violation (error code 23505)
      if (updateError.code === "23505") {
        return new Response(
          JSON.stringify({ error: "Stripe account already linked to another user" }),
          { status: 409, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      return new Response(
        JSON.stringify({ error: "Failed to save account ID" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }
  }

  // Create account link
  console.log("[stripe-connect-onboarding] Redirect URLs", {
    environment: Deno.env.get("ENVIRONMENT") ?? "development",
    appUrl,
    returnUrl,
    refreshUrl,
  });

  const linkResponse = await fetch(
    `https://api.stripe.com/v1/account_links`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeSecretKey}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        account: stripeAccountId,
        type: "account_onboarding",
        refresh_url: refreshUrl,
        return_url: returnUrl,
      }).toString(),
    }
  );

  const link = await linkResponse.json();

  if (link.error) {
    return new Response(
      JSON.stringify({ error: link.error.message }),
      { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  console.log("[stripe-connect-onboarding] Account link created", {
    userId,
    stripeAccountId,
  });

  return new Response(
    JSON.stringify({ url: link.url }),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}

async function handleGetStatus(
  profile: any,
  corsHeaders: any
): Promise<Response> {
  const response: StripeConnectResponse = {
    stripe_account_id: profile.stripe_account_id,
    charges_enabled: profile.stripe_account_charges_enabled || false,
    details_submitted: profile.stripe_account_details_submitted || false,
  };

  return new Response(
    JSON.stringify(response),
    { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
  );
}
