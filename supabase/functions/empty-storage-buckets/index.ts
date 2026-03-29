import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json; charset=utf-8",
};

const BUCKETS = [
  "battle-campaign-images",
  "avatars",
  "beats-masters",
  "beats-watermarked",
  "contracts",
  "beats-audio",
  "beats-covers",
] as const;

const PROTECTED_BUCKETS = new Set(["watermark-assets"]);
const LIST_PAGE_SIZE = 100;
const REMOVE_BATCH_SIZE = 1000;

type BucketResult = {
  deleted: number;
  error?: string;
};

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders,
  });
}

function getRequiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) {
    throw new Error(`Missing ${name}`);
  }
  return value;
}

function joinPath(prefix: string, name: string): string {
  return prefix ? `${prefix}/${name}` : name;
}

async function listAllFilePaths(
  supabaseAdmin: SupabaseClient,
  bucket: string,
): Promise<string[]> {
  const filePaths: string[] = [];
  const prefixes: string[] = [""];

  while (prefixes.length > 0) {
    const prefix = prefixes.pop() ?? "";
    let offset = 0;

    while (true) {
      const { data, error } = await supabaseAdmin.storage.from(bucket).list(
        prefix,
        {
          limit: LIST_PAGE_SIZE,
          offset,
          sortBy: { column: "name", order: "asc" },
        },
      );

      if (error) {
        throw new Error(
          `Failed to list "${bucket}"${
            prefix ? ` at "${prefix}"` : ""
          }: ${error.message}`,
        );
      }

      if (!data || data.length === 0) {
        break;
      }

      for (const entry of data) {
        const name = entry.name?.trim();
        if (!name) {
          continue;
        }

        const fullPath = joinPath(prefix, name);

        if (entry.id === null) {
          prefixes.push(fullPath);
          continue;
        }

        filePaths.push(fullPath);
      }

      if (data.length < LIST_PAGE_SIZE) {
        break;
      }

      offset += LIST_PAGE_SIZE;
    }
  }

  return filePaths;
}

async function emptyBucket(
  supabaseAdmin: SupabaseClient,
  bucket: string,
): Promise<BucketResult> {
  const filePaths = await listAllFilePaths(supabaseAdmin, bucket);
  let deleted = 0;

  for (let index = 0; index < filePaths.length; index += REMOVE_BATCH_SIZE) {
    const batch = filePaths.slice(index, index + REMOVE_BATCH_SIZE);
    const { error } = await supabaseAdmin.storage.from(bucket).remove(batch);

    if (error) {
      throw new Error(
        `Failed to remove files from "${bucket}": ${error.message}`,
      );
    }

    deleted += batch.length;
  }

  return { deleted };
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ ok: false, error: "Method not allowed" }, 405);
  }

  try {
    const supabaseUrl = getRequiredEnv("SUPABASE_URL");
    const serviceRoleKey = getRequiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
      auth: {
        autoRefreshToken: false,
        persistSession: false,
      },
    });

    const results: Record<string, BucketResult> = {};
    let hasErrors = false;

    for (const bucket of BUCKETS) {
      if (PROTECTED_BUCKETS.has(bucket)) {
        continue;
      }

      try {
        const result = await emptyBucket(supabaseAdmin, bucket);
        results[bucket] = result;
        console.log("[empty-storage-buckets] bucket emptied", {
          bucket,
          deleted: result.deleted,
        });
      } catch (error) {
        const message = error instanceof Error ? error.message : String(error);
        results[bucket] = {
          deleted: 0,
          error: message,
        };
        hasErrors = true;
        console.error("[empty-storage-buckets] bucket failed", {
          bucket,
          error: message,
        });
      }
    }

    console.log("[empty-storage-buckets] completed", {
      ok: !hasErrors,
      results,
    });

    return json({
      ok: !hasErrors,
      results,
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error("[empty-storage-buckets] fatal", { error: message });
    return json({ ok: false, error: message }, 500);
  }
});
