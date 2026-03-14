import dotenv from "dotenv";
import http from "node:http";
import { captureWorkerException, initWorkerSentry } from "./sentry.js";

dotenv.config();
initWorkerSentry("audio-worker");

const log = (level: "info" | "warn" | "error", event: string, meta: Record<string, unknown> = {}) => {
  const payload = {
    level,
    event,
    ts: new Date().toISOString(),
    ...meta,
  };
  const line = JSON.stringify(payload);

  if (level === "error") {
    captureWorkerException(meta.error ?? new Error(event), {
      serviceName: "audio-worker",
      event,
      ...meta,
    });
    console.error(line);
    return;
  }

  if (level === "warn") {
    console.warn(line);
    return;
  }

  console.info(line);
};

const main = async () => {
  const [{ assertFfmpegAvailable }, { config, publicConfig }, { createSupabaseAdminClient }, { AudioWorkerService }] =
    await Promise.all([
      import("./ffmpeg.js"),
      import("./config.js"),
      import("./supabaseClient.js"),
      import("./worker.js"),
    ]);

  await assertFfmpegAvailable(config.ffmpegBin, config.ffprobeBin);

  const supabase = createSupabaseAdminClient(config);
  const worker = new AudioWorkerService({ supabase, config });
  const port = Number(process.env.PORT || 10000);
  const server = http.createServer((req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain" });
    res.end("Audio worker is running");
  });

  server.listen(port, () => {
    console.log(JSON.stringify({
      level: "info",
      event: "http_server_started",
      port,
    }));
  });

  log("info", "worker_starting", publicConfig);

  const runPromise = worker.run();
  let shutdownStarted = false;

  const shutdown = async (signal: string) => {
    if (shutdownStarted) return;
    shutdownStarted = true;

    log("warn", "shutdown_requested", {
      signal,
      workerId: config.workerId,
    });

    worker.stop();

    const forceExitTimer = setTimeout(() => {
      log("error", "shutdown_timeout", {
        signal,
        workerId: config.workerId,
        shutdownGraceMs: config.shutdownGraceMs,
      });
      process.exit(1);
    }, config.shutdownGraceMs);

    try {
      await runPromise;
      clearTimeout(forceExitTimer);
      log("info", "worker_stopped", {
        workerId: config.workerId,
      });
      process.exit(0);
    } catch (error) {
      clearTimeout(forceExitTimer);
      log("error", "worker_stopped_with_error", {
        workerId: config.workerId,
        error: error instanceof Error ? error.message : String(error),
      });
      process.exit(1);
    }
  };

  process.on("SIGINT", () => {
    void shutdown("SIGINT");
  });

  process.on("SIGTERM", () => {
    void shutdown("SIGTERM");
  });

  await runPromise;
};

main().catch((error) => {
  log("error", "worker_boot_failed", {
    error: error instanceof Error ? error.message : String(error),
  });
  process.exit(1);
});
