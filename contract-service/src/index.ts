import serverless from "serverless-http";
import express from "express";
import type { NextFunction, Request, Response } from "express";
import {
  captureContractServiceException,
  initContractServiceSentry,
} from "./sentry.js";

initContractServiceSentry("contract-service");
const app = express();

app.get("/health", (_req: Request, res: Response) => {
  return res.json({ status: "ok simple" });
});

app.use((error: unknown, req: Request, res: Response, _next: NextFunction) => {
  captureContractServiceException(error, {
    serviceName: "contract-service",
    method: req.method,
    path: req.path,
  });

  return res.status(500).json({
    error: "internal_server_error",
    message: "Unexpected server error",
  });
});

export default serverless(app);
