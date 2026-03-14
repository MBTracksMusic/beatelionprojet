import serverless from "serverless-http";
import express from "express";
import { captureContractServiceException, initContractServiceSentry, } from "./sentry.js";
initContractServiceSentry("contract-service");
const app = express();
app.get("/health", (_req, res) => {
    return res.json({ status: "ok simple" });
});
app.use((error, req, res, _next) => {
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
