import { captureException } from "./sentry.ts";

export interface LoggerContext {
  functionName: string;
  requestId?: string;
}

const serializeError = (error: unknown) => {
  if (error instanceof Error) {
    return {
      name: error.name,
      message: error.message,
      stack: error.stack,
    };
  }

  if (typeof error === "string") return { message: error };

  try {
    return { payload: JSON.parse(JSON.stringify(error)) };
  } catch {
    return { payload: String(error) };
  }
};

const writeLog = (
  level: "info" | "warn" | "error",
  message: string,
  context: LoggerContext,
  meta: Record<string, unknown> = {},
) => {
  const payload = {
    timestamp: new Date().toISOString(),
    level,
    function_name: context.functionName,
    request_id: context.requestId ?? null,
    message,
    ...meta,
  };

  const line = JSON.stringify(payload);

  if (level === "error") {
    console.error(line);
    return;
  }

  if (level === "warn") {
    console.warn(line);
    return;
  }

  console.info(line);
};

export const createLogger = (context: LoggerContext) => {
  return {
    info: (message: string, meta: Record<string, unknown> = {}) => {
      writeLog("info", message, context, meta);
    },

    warn: (message: string, meta: Record<string, unknown> = {}) => {
      writeLog("warn", message, context, meta);
    },

    error: (message: string, meta: Record<string, unknown> = {}) => {
      const error = meta.error;
      if (error !== undefined) {
        captureException(error, {
          functionName: context.functionName,
          requestId: context.requestId,
        });
      }

      writeLog("error", message, context, {
        ...meta,
        ...(error !== undefined ? { error: serializeError(error) } : {}),
      });
    },
  };
};
