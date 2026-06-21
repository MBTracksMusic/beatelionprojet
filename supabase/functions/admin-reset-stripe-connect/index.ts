import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { requireAdminUser } from "../_shared/auth.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

// Admin-only: clear the stored Stripe Connect account on a producer's profile so
// they can restart onboarding cleanly (e.g. an account locked to the wrong country).
//
// Notes:
// - This only clears Beatelion's stored link to the connected account. The old
//   incomplete account is left on Stripe's side; Stripe auto-removes Express
//   accounts that never finished onboarding. We never delete a working account.
// - A guard refuses to clear an account that can already accept payments
//   (charges_enabled=true) unless force=true, so a live producer is never broken.
const FUNCTION_VERSION = "2026-06-21-admin-reset-stripe-connect-1";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

const asNonEmptyString = (value: unknown) => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const asUuid = (value: unknown) => {
  const text = asNonEmptyString(value);
  if (!text || !UUID_RE.test(text)) return null;
  return text;
};

// Stored emails are not always normalized (mixed case), so we match
// case-insensitively. Escape LIKE wildcards first so emails containing "_" or
// "%" cannot match the wrong row.
const asEmail = (value: unknown) => {
  const text = asNonEmptyString(value);
  if (!text) return null;
  return text.toLowerCase();
};

const escapeLikePattern = (value: string) =>
  value.replace(/[\\%_]/g, (match) => `\\${match}`);

type ProfileRow = {
  id: string;
  username: string | null;
  email: string | null;
  stripe_account_id: string | null;
  stripe_account_country: string | null;
  stripe_account_charges_enabled: boolean | null;
  stripe_account_details_submitted: boolean | null;
  stripe_account_created_at: string | null;
};

const PROFILE_COLUMNS =
  "id, username, email, stripe_account_id, stripe_account_country, " +
  "stripe_account_charges_enabled, stripe_account_details_submitted, stripe_account_created_at";

serveWithErrorHandling("admin-reset-stripe-connect", async (req: Request): Promise<Response> => {
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
  const { user: adminUser, supabaseAdmin } = authContext;

  const payload = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload || Array.isArray(payload)) {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const userId = asUuid(payload.user_id);
  const email = asEmail(payload.email);
  const force = payload.force === true;
  const dryRun = payload.dry_run === true;

  if (!userId && !email) {
    return new Response(
      JSON.stringify({ error: "Provide user_id (UUID) or email" }),
      { status: 400, headers: jsonHeaders },
    );
  }

  // Resolve the producer.
  const baseQuery = supabaseAdmin.from("user_profiles").select(PROFILE_COLUMNS);
  const { data: profileData, error: lookupError } = userId
    ? await baseQuery.eq("id", userId).maybeSingle()
    : await baseQuery.ilike("email", escapeLikePattern(email!)).maybeSingle();

  if (lookupError) {
    console.error("[admin-reset-stripe-connect] failed to resolve user", {
      functionVersion: FUNCTION_VERSION,
      code: lookupError.code,
      message: lookupError.message,
    });
    return new Response(
      JSON.stringify({ error: "user_lookup_failed", message: "Unable to resolve user" }),
      { status: 500, headers: jsonHeaders },
    );
  }

  const profile = profileData as ProfileRow | null;
  if (!profile) {
    return new Response(
      JSON.stringify({ error: "user_not_found", message: "No producer found for that user_id/email" }),
      { status: 404, headers: jsonHeaders },
    );
  }

  const before = {
    stripe_account_id: profile.stripe_account_id,
    stripe_account_country: profile.stripe_account_country,
    charges_enabled: profile.stripe_account_charges_enabled ?? false,
    details_submitted: profile.stripe_account_details_submitted ?? false,
    stripe_account_created_at: profile.stripe_account_created_at,
  };
  const targetUser = { id: profile.id, username: profile.username, email: profile.email };

  // Nothing to clear.
  if (!profile.stripe_account_id) {
    return new Response(
      JSON.stringify({
        ok: true,
        reset: false,
        reason: "no_account",
        message: "No Stripe Connect account stored for this user. Nothing to reset.",
        user: targetUser,
        before,
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  // Guard: never wipe an account that can already accept payments unless forced.
  if (before.charges_enabled && !force) {
    return new Response(
      JSON.stringify({
        ok: false,
        reset: false,
        reason: "account_active",
        message:
          "This account can already accept payments (charges_enabled=true). Reset refused to avoid breaking a working producer. Pass force=true to override.",
        user: targetUser,
        before,
      }),
      { status: 409, headers: jsonHeaders },
    );
  }

  // Preview without writing.
  if (dryRun) {
    return new Response(
      JSON.stringify({
        ok: true,
        reset: false,
        reason: "dry_run",
        message: "Dry run. This account WOULD be reset.",
        user: targetUser,
        before,
      }),
      { status: 200, headers: jsonHeaders },
    );
  }

  const { error: updateError } = await (supabaseAdmin as any)
    .from("user_profiles")
    .update({
      stripe_account_id: null,
      stripe_account_charges_enabled: false,
      stripe_account_details_submitted: false,
      stripe_account_country: null,
      stripe_account_created_at: null,
    })
    .eq("id", profile.id);

  if (updateError) {
    console.error("[admin-reset-stripe-connect] failed to clear Stripe Connect data", {
      functionVersion: FUNCTION_VERSION,
      code: updateError.code,
      message: updateError.message,
      targetId: profile.id,
    });
    return new Response(
      JSON.stringify({ error: "reset_failed", message: "Failed to clear Stripe Connect data" }),
      { status: 500, headers: jsonHeaders },
    );
  }

  console.log("[admin-reset-stripe-connect] cleared Stripe Connect account", {
    functionVersion: FUNCTION_VERSION,
    adminId: adminUser.id,
    targetId: profile.id,
    previousAccount: before.stripe_account_id,
    previousCountry: before.stripe_account_country,
    forced: force,
  });

  return new Response(
    JSON.stringify({
      ok: true,
      reset: true,
      message:
        "Stripe Connect account cleared. The producer can restart onboarding and pick the correct country. The old incomplete Stripe account is left on Stripe's side and auto-removed by Stripe.",
      user: targetUser,
      before,
      after: {
        stripe_account_id: null,
        stripe_account_country: null,
        charges_enabled: false,
        details_submitted: false,
        stripe_account_created_at: null,
      },
    }),
    { status: 200, headers: jsonHeaders },
  );
});
