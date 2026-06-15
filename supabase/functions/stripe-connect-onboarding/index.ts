import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface StripeConnectRequest {
  action: "create_account_link" | "get_status";
  country?: string;
}

interface StripeConnectResponse {
  url?: string;
  stripe_account_id?: string;
  charges_enabled?: boolean;
  details_submitted?: boolean;
  error?: string;
}

interface StripeConnectProfile {
  stripe_account_id: string | null;
  is_producer_active: boolean | null;
  stripe_account_charges_enabled: boolean | null;
  stripe_account_details_submitted: boolean | null;
}

type SupabaseAdminClient = ReturnType<typeof createClient>;
type CorsHeaders = typeof corsHeaders;

const PRODUCTION_SITE_URL = "https://beatelion.com";
const STAGING_SITE_URL = "https://beatelion-staging.vercel.app";

const STRIPE_CONNECT_SUPPORTED_COUNTRIES = new Set([
  "AE", "AG", "AL", "AM", "AR", "AT", "AU", "BA", "BE", "BG", "BH", "BJ", "BN", "BO", "BS", "BW",
  "CA", "CH", "CI", "CL", "CO", "CR", "CY", "CZ", "DE", "DK", "DO", "EC", "EE", "EG", "ES", "ET",
  "FI", "FR", "GB", "GH", "GM", "GR", "GT", "GY", "HK", "HU", "IE", "IL", "IS", "IT", "JM", "JO",
  "JP", "KE", "KH", "KR", "KW", "LC", "LK", "LT", "LU", "LV", "MA", "MC", "MD", "MG", "MK", "MN",
  "MO", "MT", "MU", "MX", "NA", "NG", "NL", "NO", "NZ", "OM", "PA", "PE", "PH", "PK", "PL", "PT",
  "PY", "QA", "RO", "RS", "RW", "SA", "SE", "SG", "SI", "SK", "SN", "SV", "TH", "TN", "TR", "TT",
  "TW", "TZ", "US", "UY", "UZ", "VN", "ZA",
]);

const asNonEmptyString = (value: string | null | undefined): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const normalizeCountryCode = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const normalized = value.trim().toUpperCase();
  return /^[A-Z]{2}$/.test(normalized) ? normalized : null;
};

const resolveAllowedConnectCountries = (): Set<string> => {
  const configuredCountries = asNonEmptyString(Deno.env.get("STRIPE_CONNECT_ALLOWED_COUNTRIES"));
  if (!configuredCountries) return STRIPE_CONNECT_SUPPORTED_COUNTRIES;

  const allowed = new Set<string>();
  for (const token of configuredCountries.split(",")) {
    const country = normalizeCountryCode(token);
    if (country && STRIPE_CONNECT_SUPPORTED_COUNTRIES.has(country)) {
      allowed.add(country);
    }
  }

  return allowed.size > 0 ? allowed : STRIPE_CONNECT_SUPPORTED_COUNTRIES;
};

const validateConnectCountry = (value: unknown): { country: string | null; error: string | null } => {
  const country = normalizeCountryCode(value);
  if (!country) {
    return {
      country: null,
      error: "Country is required before creating a Stripe Connect account",
    };
  }

  if (!STRIPE_CONNECT_SUPPORTED_COUNTRIES.has(country)) {
    return {
      country: null,
      error: "This country is not supported for Stripe Connect Express onboarding",
    };
  }

  if (!resolveAllowedConnectCountries().has(country)) {
    return {
      country: null,
      error: "This country is not enabled for Stripe Connect onboarding",
    };
  }

  return { country, error: null };
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

    const stripeProfile = profile as StripeConnectProfile | null;

    if (profileError || !stripeProfile) {
      return new Response(
        JSON.stringify({ error: "User profile not found" }),
        { status: 404, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    if (!stripeProfile.is_producer_active) {
      return new Response(
        JSON.stringify({ error: "User is not a producer" }),
        { status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Handle different actions
    if (body.action === "create_account_link") {
      return await handleCreateAccountLink(
        userId,
        stripeProfile,
        body.country,
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
  profile: StripeConnectProfile,
  requestedCountry: unknown,
  supabaseAdmin: SupabaseAdminClient,
  stripeSecretKey: string,
  corsHeaders: CorsHeaders
): Promise<Response> {
  let stripeAccountId = profile.stripe_account_id;
  const appUrl = resolveAppUrl();
  const returnUrl = `${appUrl}/producer`;
  const refreshUrl = `${appUrl}/producer`;

  // If no account exists, create one
  if (!stripeAccountId) {
    const { country, error: countryError } = validateConnectCountry(requestedCountry);
    if (countryError || !country) {
      return new Response(
        JSON.stringify({ error: countryError ?? "Invalid Stripe Connect country" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const accountParams = new URLSearchParams({
      type: "express",
      country,
      "capabilities[card_payments][requested]": "true",
      "capabilities[transfers][requested]": "true",
      "metadata[beatelion_user_id]": userId,
    });

    const accountResponse = await fetch("https://api.stripe.com/v1/accounts", {
      method: "POST",
      headers: {
        Authorization: `Bearer ${stripeSecretKey}`,
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: accountParams.toString(),
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
  profile: StripeConnectProfile,
  corsHeaders: CorsHeaders
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
