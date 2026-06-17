import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import {
  createUserClient,
  extractBearerToken,
  requireAdminUser,
} from "../_shared/auth.ts";
import { resolveCorsHeaders } from "../_shared/cors.ts";
import { serveWithErrorHandling } from "../_shared/error-handler.ts";

const FUNCTION_VERSION = "2026-06-17-admin-reset-campaign-trial-1";

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{12}$/i;

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

const asOptionalIsoDate = (value: unknown) => {
  const text = asNonEmptyString(value);
  if (!text) return undefined;

  const date = new Date(text);
  if (Number.isNaN(date.getTime())) return null;

  return date.toISOString();
};

type ResetCampaignTrialRpcResult = {
  success: boolean;
  user_id: string;
  campaign_type: string;
  trial_start: string;
  trial_end: string;
  days_remaining: number;
};

type RpcErrorShape = {
  code?: string;
  message?: string | null;
};

type RpcCallResult<TData> = {
  data: TData | null;
  error: RpcErrorShape | null;
};

async function invokeRpc<TData>(
  client: ReturnType<typeof createUserClient>,
  functionName: string,
  args: Record<string, unknown>,
): Promise<RpcCallResult<TData>> {
  const rpc = client.rpc.bind(client) as unknown as (
    fn: string,
    params?: Record<string, unknown>,
  ) => Promise<RpcCallResult<TData>>;

  return rpc(functionName, args);
}

serveWithErrorHandling("admin-reset-campaign-trial", async (req: Request): Promise<Response> => {
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

  const token = extractBearerToken(req);
  if (!token) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401,
      headers: jsonHeaders,
    });
  }

  const payload = await req.json().catch(() => null) as Record<string, unknown> | null;
  if (!payload || Array.isArray(payload)) {
    return new Response(JSON.stringify({ error: "Invalid JSON body" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const userId = asUuid(payload.user_id);
  const campaignType = asNonEmptyString(payload.campaign_type);
  const trialStart = asOptionalIsoDate(payload.trial_start);

  if (!userId) {
    return new Response(JSON.stringify({ error: "Invalid or missing user_id" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  if (!campaignType) {
    return new Response(JSON.stringify({ error: "Invalid or missing campaign_type" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  if (trialStart === null) {
    return new Response(JSON.stringify({ error: "Invalid trial_start" }), {
      status: 400,
      headers: jsonHeaders,
    });
  }

  const rpcArgs: Record<string, unknown> = {
    p_user_id: userId,
    p_campaign_type: campaignType,
  };

  if (trialStart !== undefined) {
    rpcArgs.p_trial_start = trialStart;
  }

  const supabaseUser = createUserClient(token);
  const { data: result, error: rpcError } = await invokeRpc<ResetCampaignTrialRpcResult>(
    supabaseUser,
    "admin_reset_producer_campaign_trial",
    rpcArgs,
  );

  if (rpcError) {
    const message = rpcError.message ?? "RPC call failed";

    if (rpcError.code === "P0002") {
      return new Response(JSON.stringify({ error: "campaign_not_found", message }), {
        status: 404,
        headers: jsonHeaders,
      });
    }

    if (rpcError.code === "02000") {
      return new Response(JSON.stringify({ error: "user_not_found", message }), {
        status: 404,
        headers: jsonHeaders,
      });
    }

    if (rpcError.code === "22023") {
      return new Response(JSON.stringify({ error: "campaign_membership_mismatch", message }), {
        status: 409,
        headers: jsonHeaders,
      });
    }

    if (rpcError.code === "42501") {
      return new Response(JSON.stringify({ error: "Forbidden", message }), {
        status: 403,
        headers: jsonHeaders,
      });
    }

    console.error("[admin-reset-campaign-trial] RPC error", {
      functionVersion: FUNCTION_VERSION,
      code: rpcError.code,
      message,
      userId,
      campaignType,
    });

    return new Response(JSON.stringify({ error: "rpc_error", message }), {
      status: 500,
      headers: jsonHeaders,
    });
  }

  return new Response(JSON.stringify({
    ok: true,
    result,
  }), {
    status: 200,
    headers: jsonHeaders,
  });
});
