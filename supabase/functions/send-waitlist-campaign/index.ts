import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";
import { requireAdminUser } from "../_shared/auth.ts";

type CampaignResponse =
  | { success: true; sent?: number }
  | { error: true };

type WaitlistRow = {
  email: string;
};

const RESEND_ENDPOINT = "https://api.resend.com/emails";
const DEFAULT_FROM_EMAIL = "Beatelion <noreply@beatelion.com>";
const CAMPAIGN_SUBJECT = "🚀 Beatelion est en ligne !";
const CAMPAIGN_HTML =
  "<h1>🔥 Beatelion est ouvert</h1><p>La plateforme est maintenant disponible</p><a href=\"https://beatelion.com\">Accéder au site</a>";
const MAX_EMAILS = 200;

const jsonResponse = (
  payload: CampaignResponse,
  status: number,
  corsHeaders: Record<string, string>,
) =>
  new Response(JSON.stringify(payload), {
    status,
    headers: {
      ...corsHeaders,
      "Content-Type": "application/json",
    },
  });

const asNonEmptyString = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const delay = (ms: number) =>
  new Promise<void>((resolve) => {
    setTimeout(resolve, ms);
  });

const sendCampaignEmail = async (email: string, apiKey: string): Promise<boolean> => {
  const from = asNonEmptyString(Deno.env.get("RESEND_FROM_EMAIL")) || DEFAULT_FROM_EMAIL;
  const response = await fetch(RESEND_ENDPOINT, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      Authorization: `Bearer ${apiKey}`,
    },
    body: JSON.stringify({
      from,
      to: email,
      subject: CAMPAIGN_SUBJECT,
      html: CAMPAIGN_HTML,
    }),
  });

  return response.ok;
};

Deno.serve(async (req: Request): Promise<Response> => {
  const corsHeaders = resolveCorsHeaders(req.headers.get("origin"));

  if (req.method === "OPTIONS") {
    return new Response("ok", {
      status: 200,
      headers: corsHeaders,
    });
  }

  if (req.method !== "POST") {
    return jsonResponse({ error: true }, 405, corsHeaders);
  }

  try {
    const authResult = await requireAdminUser(req, corsHeaders);
    if ("error" in authResult) {
      return authResult.error;
    }

    const { supabaseAdmin } = authResult;

    const { data, error } = await supabaseAdmin
      .from("waitlist")
      .select("email")
      .order("created_at", { ascending: true });

    if (error || !data) {
      return jsonResponse({ error: true }, 500, corsHeaders);
    }

    const resendApiKey = asNonEmptyString(Deno.env.get("RESEND_API_KEY"));
    if (!resendApiKey) {
      return jsonResponse({ error: true }, 500, corsHeaders);
    }

    const users = (data as WaitlistRow[]).slice(0, MAX_EMAILS);
    if (users.length === 0) {
      return jsonResponse({ success: true, sent: 0 }, 200, corsHeaders);
    }

    let sent = 0;

    for (const entry of users) {
      const email = asNonEmptyString(entry.email);
      if (!email) {
        continue;
      }

      const emailSent = await sendCampaignEmail(email, resendApiKey);
      if (!emailSent) {
        // TODO: add monitoring for per-recipient campaign delivery failures.
        continue;
      }

      sent += 1;

      await delay(150);
    }

    return jsonResponse({ success: true, sent }, 200, corsHeaders);
  } catch {
    return jsonResponse({ error: true }, 500, corsHeaders);
  }
});
