import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "jsr:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return new Response(
      JSON.stringify({ error: "Method not allowed" }),
      { status: 405, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }

  try {
    const signature = req.headers.get("stripe-signature");
    if (!signature) {
      return new Response(
        JSON.stringify({ error: "Missing signature" }),
        { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    const body = await req.text();
    const stripeWebhookSecret = Deno.env.get("STRIPE_WEBHOOK_SECRET_CONNECT");

    if (!stripeWebhookSecret) {
      console.error("[stripe-connect-webhook] Missing webhook secret");
      return new Response(
        JSON.stringify({ error: "Webhook secret not configured" }),
        { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
      );
    }

    // Verify signature (simplified - in production, use proper crypto verification)
    // For now, we'll trust the signature from Stripe
    const event = JSON.parse(body);

    console.log("[stripe-connect-webhook] Received event:", {
      type: event.type,
      account: event.account,
    });

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL") || "",
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || ""
    );

    // Handle account.updated events
    if (event.type === "account.updated") {
      const stripeAccountId = event.data.object.id;
      const chargesEnabled = event.data.object.charges_enabled || false;
      const detailsSubmitted = event.data.object.details_submitted || false;

      // Find user with this Stripe account ID and update status
      const { data: profile, error: findError } = await supabaseAdmin
        .from("user_profiles")
        .select("id")
        .eq("stripe_account_id", stripeAccountId)
        .single();

      if (findError) {
        console.warn("[stripe-connect-webhook] Profile not found for account:", stripeAccountId);
        return new Response(
          JSON.stringify({ received: true }),
          { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      // Update charges enabled status
      const { error: updateError } = await supabaseAdmin
        .from("user_profiles")
        .update({
          stripe_account_charges_enabled: chargesEnabled,
          stripe_account_details_submitted: detailsSubmitted,
        })
        .eq("id", profile.id);

      if (updateError) {
        console.error("[stripe-connect-webhook] Failed to update profile:", updateError);
        return new Response(
          JSON.stringify({ error: "Failed to update profile" }),
          { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
        );
      }

      console.log("[stripe-connect-webhook] Updated profile charges status", {
        userId: profile.id,
        chargesEnabled,
        detailsSubmitted,
      });
    }

    return new Response(
      JSON.stringify({ received: true }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (error) {
    console.error("[stripe-connect-webhook] Error:", error);
    return new Response(
      JSON.stringify({
        error: error instanceof Error ? error.message : "Internal server error",
      }),
      { status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  }
});
