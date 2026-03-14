import * as Sentry from "@sentry/node";

let initialized = false;

const asNonEmptyString = (value: unknown): string | null => {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
};

const normalizeError = (error: unknown): Error => {
  if (error instanceof Error) return error;
  if (typeof error === "string") return new Error(error);
  try {
    return new Error(JSON.stringify(error));
  } catch {
    return new Error("Unknown error");
  }
};

export const initApiSentry = (serviceName = "api") => {
  if (initialized) return;

  const dsn = asNonEmptyString(process.env.SENTRY_DSN);
  if (!dsn) {
    initialized = true;
    return;
  }

  Sentry.init({
    dsn,
    environment:
      asNonEmptyString(process.env.ENVIRONMENT) ||
      asNonEmptyString(process.env.ENV) ||
      asNonEmptyString(process.env.NODE_ENV) ||
      "development",
    tracesSampleRate: Number.parseFloat(process.env.SENTRY_TRACES_SAMPLE_RATE || "0") || 0,
    initialScope: {
      tags: {
        service_name: serviceName,
        runtime: "node",
      },
    },
  });

  process.on("unhandledRejection", (reason) => {
    captureApiException(reason, { serviceName, event: "unhandledRejection" });
  });

  process.on("uncaughtException", (error) => {
    captureApiException(error, { serviceName, event: "uncaughtException" });
  });

  initialized = true;
};

export const captureApiException = (
  error: unknown,
  context: Record<string, unknown> = {},
) => {
  if (!initialized) {
    initApiSentry(typeof context.serviceName === "string" ? context.serviceName : "api");
  }

  if (!asNonEmptyString(process.env.SENTRY_DSN)) {
    return null;
  }

  return Sentry.withScope((scope) => {
    for (const [key, value] of Object.entries(context)) {
      if (typeof value === "string" || typeof value === "number" || typeof value === "boolean") {
        scope.setTag(key, String(value));
      } else {
        scope.setContext(key, { value });
      }
    }

    return Sentry.captureException(normalizeError(error));
  });
};
