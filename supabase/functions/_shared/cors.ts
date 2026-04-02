const BASE_ALLOWED_ORIGINS = [
  "http://localhost:5173",
  "http://localhost:3000",
  "https://beatelion.com",
  "https://www.beatelion.com",
];

function resolveAllowedOrigins(): Set<string> {
  const allowed = new Set<string>(BASE_ALLOWED_ORIGINS);

  // Extra exact origins (e.g. a fixed staging custom domain)
  const extra = Deno.env.get("CORS_ALLOWED_ORIGINS");
  if (extra) {
    for (const origin of extra.split(",")) {
      const trimmed = origin.trim();
      if (trimmed) allowed.add(trimmed);
    }
  }

  return allowed;
}

const ALLOWED_ORIGINS = resolveAllowedOrigins();

// e.g. "beatelion" → matches any https://*beatelion*.vercel.app preview URL
const VERCEL_PROJECT_SLUG = Deno.env.get("CORS_VERCEL_PROJECT_SLUG")?.trim() ?? "";

function isAllowedOrigin(origin: string): boolean {
  if (ALLOWED_ORIGINS.has(origin)) return true;

  if (
    VERCEL_PROJECT_SLUG &&
    origin.startsWith("https://") &&
    origin.endsWith(".vercel.app") &&
    origin.includes(VERCEL_PROJECT_SLUG)
  ) {
    return true;
  }

  return false;
}

export function resolveCorsHeaders(origin: string | null) {
  if (!origin || !isAllowedOrigin(origin)) {
    return {
      "Access-Control-Allow-Origin": "null",
      "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
    };
  }

  return {
    "Access-Control-Allow-Origin": origin,
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
  };
}
