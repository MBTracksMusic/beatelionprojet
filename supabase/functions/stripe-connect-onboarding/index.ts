import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface StripeConnectRequest {
  action: "create_account_link" | "get_status" | "replace_account_country";
  country?: string;
}

interface StripeConnectResponse {
  url?: string;
  stripe_account_id?: string | null;
  charges_enabled?: boolean;
  details_submitted?: boolean;
  payouts_enabled?: boolean;
  country?: string | null;
  can_replace_account?: boolean;
  error?: string;
}

interface StripeConnectProfile {
  stripe_account_id: string | null;
  is_producer_active: boolean | null;
  stripe_account_charges_enabled: boolean | null;
  stripe_account_details_submitted: boolean | null;
  stripe_account_country: string | null;
}

interface StripeAccount {
  id: string;
  country?: string | null;
  charges_enabled?: boolean | null;
  details_submitted?: boolean | null;
  payouts_enabled?: boolean | null;
}

interface StripeAccountLink {
  url?: string;
  error?: { message?: string };
}

type SupabaseAdminClient = ReturnType<typeof createClient<any>>;
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

class HttpError extends Error {
  status: number;

  constructor(status: number, message: string) {
    super(message);
    this.status = status;
  }
}

const jsonResponse = (
  payload: Record<string, unknown>,
  status: number,
  corsHeaders: CorsHeaders,
) => new Response(
  JSON.stringify(payload),
  { status, headers: { ...corsHeaders, "Content-Type": "application/json" } },
);

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

const stripeApiFetch = async <T>(
  path: string,
  stripeSecretKey: string,
  init: RequestInit,
): Promise<T> => {
  const response = await fetch(`https://api.stripe.com${path}`, {
    ...init,
    headers: {
      Authorization: `Bearer ${stripeSecretKey}`,
      "Content-Type": "application/x-www-form-urlencoded",
      ...(init.headers ?? {}),
    },
  });

  const payload = await response.json().catch(() => ({}));
  const stripeError = payload?.error?.message;

  if (!response.ok || stripeError) {
    throw new HttpError(
      response.ok ? 400 : response.status,
      typeof stripeError === "string" ? stripeError : "Stripe request failed",
    );
  }

  return payload as T;
};

const retrieveStripeAccount = async (
  stripeAccountId: string,
  stripeSecretKey: string,
): Promise<StripeAccount> => {
  return await stripeApiFetch<StripeAccount>(
    `/v1/accounts/${encodeURIComponent(stripeAccountId)}`,
    stripeSecretKey,
    { method: "GET" },
  );
};

const createStripeAccount = async (
  userId: string,
  country: string,
  stripeSecretKey: string,
): Promise<StripeAccount> => {
  const accountParams = new URLSearchParams({
    type: "express",
    country,
    "capabilities[card_payments][requested]": "true",
    "capabilities[transfers][requested]": "true",
    "metadata[beatelion_user_id]": userId,
  });

  return await stripeApiFetch<StripeAccount>(
    "/v1/accounts",
    stripeSecretKey,
    {
      method: "POST",
      body: accountParams.toString(),
    },
  );
};

const createStripeAccountLink = async (
  stripeAccountId: string,
  returnUrl: string,
  refreshUrl: string,
  stripeSecretKey: string,
): Promise<string> => {
  const link = await stripeApiFetch<StripeAccountLink>(
    "/v1/account_links",
    stripeSecretKey,
    {
      method: "POST",
      body: new URLSearchParams({
        account: stripeAccountId,
        type: "account_onboarding",
        refresh_url: refreshUrl,
        return_url: returnUrl,
      }).toString(),
    },
  );

  if (!link.url) {
    throw new HttpError(502, "Stripe did not return an onboarding URL");
  }

  return link.url;
};

// An account can be replaced with the correct country as long as it never
// became able to move money (no charges and no payouts enabled). We intentionally
// allow replacement even after details were submitted: a producer who submitted
// the wrong country (e.g. the legacy FR-hardcoded onboarding) but could never get
// charges/payouts enabled would otherwise be permanently stuck on an account they
// cannot use. Once charges or payouts are enabled, the account is live and locked.
const canReplaceIncompleteAccount = (
  account: StripeAccount,
  profile: StripeConnectProfile,
): boolean => {
  return !account.charges_enabled
    && !account.payouts_enabled
    && !profile.stripe_account_charges_enabled;
};

const syncStripeAccountToProfile = async (
  userId: string,
  account: StripeAccount,
  supabaseAdmin: SupabaseAdminClient,
): Promise<void> => {
  const { error } = await supabaseAdmin
    .from("user_profiles")
    .update({
      stripe_account_charges_enabled: account.charges_enabled || false,
      stripe_account_details_submitted: account.details_submitted || false,
      stripe_account_country: normalizeCountryCode(account.country) ?? null,
    })
    .eq("id", userId);

  if (error) {
    console.error("[stripe-connect-onboarding] Failed to sync account status:", {
      userId,
      accountId: account.id,
      error: error.message,
    });
    throw new HttpError(500, "Failed to sync Stripe account status");
  }
};

const saveStripeAccountToProfile = async (
  userId: string,
  account: StripeAccount,
  fallbackCountry: string,
  supabaseAdmin: SupabaseAdminClient,
): Promise<void> => {
  const { error } = await supabaseAdmin
    .from("user_profiles")
    .update({
      stripe_account_id: account.id,
      stripe_account_charges_enabled: account.charges_enabled || false,
      stripe_account_details_submitted: account.details_submitted || false,
      stripe_account_country: normalizeCountryCode(account.country) ?? fallbackCountry,
      stripe_account_created_at: new Date().toISOString(),
    })
    .eq("id", userId);

  if (!error) return;

  console.error("[stripe-connect-onboarding] Failed to save account ID:", error);

  if (error.code === "23505") {
    throw new HttpError(409, "Stripe account already linked to another user");
  }

  throw new HttpError(500, "Failed to save account ID");
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
    const supabaseAdmin = createClient<any>(
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
      .select("stripe_account_id, is_producer_active, stripe_account_charges_enabled, stripe_account_details_submitted, stripe_account_country")
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
      return await handleGetStatus(
        userId,
        stripeProfile,
        supabaseAdmin,
        stripeSecretKey,
        corsHeaders,
      );
    } else if (body.action === "replace_account_country") {
      return await handleReplaceAccountCountry(
        userId,
        stripeProfile,
        body.country,
        supabaseAdmin,
        stripeSecretKey,
        corsHeaders,
      );
    } else {
      return jsonResponse({ error: "Invalid action" }, 400, corsHeaders);
    }
  } catch (error) {
    console.error("[stripe-connect-onboarding] Error:", error);
    return jsonResponse(
      {
        error: error instanceof Error ? error.message : "Internal server error",
      },
      error instanceof HttpError ? error.status : 500,
      corsHeaders,
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
      return jsonResponse({ error: countryError ?? "Invalid Stripe Connect country" }, 400, corsHeaders);
    }

    const account = await createStripeAccount(userId, country, stripeSecretKey);
    stripeAccountId = account.id;
    await saveStripeAccountToProfile(userId, account, country, supabaseAdmin);
  } else {
    const requestedNormalizedCountry = normalizeCountryCode(requestedCountry);
    if (requestedNormalizedCountry) {
      const account = await retrieveStripeAccount(stripeAccountId, stripeSecretKey);
      await syncStripeAccountToProfile(userId, account, supabaseAdmin);
      const existingCountry = normalizeCountryCode(account.country) ?? profile.stripe_account_country;

      if (existingCountry && requestedNormalizedCountry !== existingCountry) {
        return jsonResponse(
          {
            error: `A Stripe Connect account already exists with country ${existingCountry}. Stripe locks country after account creation.`,
            country: existingCountry,
          },
          409,
          corsHeaders,
        );
      }
    }
  }

  // Create account link
  console.log("[stripe-connect-onboarding] Redirect URLs", {
    environment: Deno.env.get("ENVIRONMENT") ?? "development",
    appUrl,
    returnUrl,
    refreshUrl,
  });

  const url = await createStripeAccountLink(stripeAccountId, returnUrl, refreshUrl, stripeSecretKey);

  console.log("[stripe-connect-onboarding] Account link created", {
    userId,
    stripeAccountId,
  });

  return jsonResponse({ url }, 200, corsHeaders);
}

async function handleReplaceAccountCountry(
  userId: string,
  profile: StripeConnectProfile,
  requestedCountry: unknown,
  supabaseAdmin: SupabaseAdminClient,
  stripeSecretKey: string,
  corsHeaders: CorsHeaders
): Promise<Response> {
  if (!profile.stripe_account_id) {
    return jsonResponse(
      { error: "No existing Stripe Connect account to replace" },
      400,
      corsHeaders,
    );
  }

  const { country, error: countryError } = validateConnectCountry(requestedCountry);
  if (countryError || !country) {
    return jsonResponse({ error: countryError ?? "Invalid Stripe Connect country" }, 400, corsHeaders);
  }

  const existingAccount = await retrieveStripeAccount(profile.stripe_account_id, stripeSecretKey);
  await syncStripeAccountToProfile(userId, existingAccount, supabaseAdmin);
  const syncedProfile: StripeConnectProfile = {
    ...profile,
    stripe_account_charges_enabled: existingAccount.charges_enabled || false,
    stripe_account_details_submitted: existingAccount.details_submitted || false,
    stripe_account_country: normalizeCountryCode(existingAccount.country) ?? profile.stripe_account_country,
  };

  const existingCountry = syncedProfile.stripe_account_country;
  if (existingCountry === country) {
    return jsonResponse(
      { error: `The existing Stripe Connect account already uses ${country}`, country },
      409,
      corsHeaders,
    );
  }

  if (!canReplaceIncompleteAccount(existingAccount, syncedProfile)) {
    return jsonResponse(
      {
        error: "This Stripe Connect account is already submitted or active. Contact support to reset it.",
        country: existingCountry,
      },
      409,
      corsHeaders,
    );
  }

  const replacementAccount = await createStripeAccount(userId, country, stripeSecretKey);
  await saveStripeAccountToProfile(userId, replacementAccount, country, supabaseAdmin);

  const appUrl = resolveAppUrl();
  const returnUrl = `${appUrl}/producer`;
  const refreshUrl = `${appUrl}/producer`;
  const url = await createStripeAccountLink(replacementAccount.id, returnUrl, refreshUrl, stripeSecretKey);

  console.log("[stripe-connect-onboarding] Replaced incomplete account country", {
    userId,
    previousStripeAccountId: profile.stripe_account_id,
    previousCountry: existingCountry,
    replacementStripeAccountId: replacementAccount.id,
    replacementCountry: country,
  });

  return jsonResponse(
    {
      url,
      stripe_account_id: replacementAccount.id,
      country,
    },
    200,
    corsHeaders,
  );
}

async function handleGetStatus(
  userId: string,
  profile: StripeConnectProfile,
  supabaseAdmin: SupabaseAdminClient,
  stripeSecretKey: string,
  corsHeaders: CorsHeaders
): Promise<Response> {
  if (profile.stripe_account_id) {
    const account = await retrieveStripeAccount(profile.stripe_account_id, stripeSecretKey);
    await syncStripeAccountToProfile(userId, account, supabaseAdmin);

    const response: StripeConnectResponse = {
      stripe_account_id: account.id,
      charges_enabled: account.charges_enabled || false,
      details_submitted: account.details_submitted || false,
      payouts_enabled: account.payouts_enabled || false,
      country: normalizeCountryCode(account.country) ?? profile.stripe_account_country,
      can_replace_account: canReplaceIncompleteAccount(account, {
        ...profile,
        stripe_account_charges_enabled: account.charges_enabled || false,
        stripe_account_details_submitted: account.details_submitted || false,
      }),
    };

    return jsonResponse(response as unknown as Record<string, unknown>, 200, corsHeaders);
  }

  const response: StripeConnectResponse = {
    stripe_account_id: profile.stripe_account_id,
    charges_enabled: profile.stripe_account_charges_enabled || false,
    details_submitted: profile.stripe_account_details_submitted || false,
    country: profile.stripe_account_country,
    can_replace_account: false,
  };

  return jsonResponse(response as unknown as Record<string, unknown>, 200, corsHeaders);
}
