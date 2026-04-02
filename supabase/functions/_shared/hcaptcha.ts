import { ApiError } from "./error-handler.ts";

const HCAPTCHA_VERIFY_URL = "https://hcaptcha.com/siteverify";

const DEFAULT_ALLOWED_CAPTCHA_HOSTNAMES = [
  "localhost",
  "127.0.0.1",
  "dev.beatelion.local",
  "beatelion.com",
  "www.beatelion.com",
];

const asNonEmptyString = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const normalizeHostname = (value: string): string | null => {
  const trimmed = value.trim();
  if (!trimmed) return null;

  const fromUrl = (() => {
    try {
      return new URL(trimmed).hostname;
    } catch {
      return null;
    }
  })();

  const candidate = (fromUrl ?? trimmed).toLowerCase().replace(/\.$/, "");

  if (candidate.includes(":") && !candidate.includes("[")) {
    return candidate.split(":")[0] ?? null;
  }

  return candidate;
};

const resolveAllowedCaptchaHostnames = () => {
  const allowed = new Set<string>(
    DEFAULT_ALLOWED_CAPTCHA_HOSTNAMES
      .map((value) => normalizeHostname(value))
      .filter((value): value is string => Boolean(value)),
  );

  const csv = asNonEmptyString(Deno.env.get("HCAPTCHA_ALLOWED_HOSTNAMES"));
  if (csv) {
    for (const token of csv.split(",")) {
      const normalized = normalizeHostname(token);
      if (normalized) {
        allowed.add(normalized);
      }
    }
  }

  return allowed;
};

const ALLOWED_CAPTCHA_HOSTNAMES = resolveAllowedCaptchaHostnames();

// Same slug used in cors.ts — matches all *.vercel.app preview URLs for the project
const VERCEL_PROJECT_SLUG = Deno.env.get("CORS_VERCEL_PROJECT_SLUG")?.trim() ?? "";

function isAllowedCaptchaHostname(hostname: string): boolean {
  if (ALLOWED_CAPTCHA_HOSTNAMES.has(hostname)) return true;

  if (
    VERCEL_PROJECT_SLUG &&
    hostname.endsWith(".vercel.app") &&
    hostname.includes(VERCEL_PROJECT_SLUG)
  ) {
    return true;
  }

  return false;
}

export function getHcaptchaSecret() {
  return asNonEmptyString(Deno.env.get("HCAPTCHA_SECRET_KEY"))
    ?? asNonEmptyString(Deno.env.get("HCAPTCHA_SECRET"));
}

export function extractIpAddress(req: Request): string | null {
  const candidates = [
    req.headers.get("cf-connecting-ip"),
    req.headers.get("x-real-ip"),
    req.headers.get("x-forwarded-for")?.split(",")[0]?.trim() ?? null,
  ];

  for (const candidate of candidates) {
    const ip = asNonEmptyString(candidate);
    if (ip) {
      return ip;
    }
  }

  return null;
}

export async function verifyHcaptchaToken(params: {
  captchaToken: string | null;
  remoteIp?: string | null;
}) {
  if (!params.captchaToken) {
    throw new ApiError(400, "bad_request", "Missing captcha token");
  }

  const secret = getHcaptchaSecret();
  if (!secret) {
    throw new ApiError(500, "internal_server_error", "Captcha configuration error");
  }

  const body = new URLSearchParams({
    secret,
    response: params.captchaToken,
  });

  if (params.remoteIp) {
    body.set("remoteip", params.remoteIp);
  }

  let response: Response;
  try {
    response = await fetch(HCAPTCHA_VERIFY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded" },
      body,
    });
  } catch (error) {
    console.error("[hcaptcha] verify request failed", {
      error: error instanceof Error ? error.message : String(error),
    });
    throw new ApiError(500, "internal_server_error", "Captcha verification unavailable");
  }

  if (!response.ok) {
    console.error("[hcaptcha] verify http error", {
      status: response.status,
    });
    throw new ApiError(500, "internal_server_error", "Captcha verification unavailable");
  }

  const payload = await response.json() as {
    success?: boolean;
    hostname?: string;
    "error-codes"?: string[];
  };

  if (payload.success !== true) {
    throw new ApiError(403, "forbidden", "Captcha verification failed");
  }

  const hostname = normalizeHostname(asNonEmptyString(payload.hostname) ?? "");
  if (!hostname || !isAllowedCaptchaHostname(hostname)) {
    console.warn("[hcaptcha] rejected hostname", {
      hostname,
      allowed: [...ALLOWED_CAPTCHA_HOSTNAMES],
    });
    throw new ApiError(403, "forbidden", "Captcha verification failed");
  }
}
