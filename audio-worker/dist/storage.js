import path from "node:path";
import { createReadStream, createWriteStream } from "node:fs";
import { Readable } from "node:stream";
import { pipeline } from "node:stream/promises";
const asNonEmptyString = (value) => {
    if (typeof value !== "string")
        return null;
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
};
const buildKnownBuckets = (config) => [
    config.masterBucket,
    "beats-masters",
    config.watermarkedBucket,
    "beats-watermarked",
    config.watermarkAssetsBucket,
    "watermark-assets",
].filter((value, index, values) => Boolean(value) && values.indexOf(value) === index);
export const parseStorageReference = (candidate, fallbackBucket, config) => {
    const raw = candidate.trim();
    if (!raw)
        return null;
    const knownBuckets = buildKnownBuckets(config);
    if (!/^https?:\/\//i.test(raw)) {
        const normalized = raw.replace(/^\/+/, "");
        if (!normalized)
            return null;
        for (const bucket of knownBuckets) {
            if (normalized.startsWith(`${bucket}/`)) {
                return {
                    bucket,
                    path: normalized.slice(bucket.length + 1),
                };
            }
        }
        return { bucket: fallbackBucket, path: normalized };
    }
    try {
        const parsed = new URL(raw);
        const segments = parsed.pathname.split("/").filter(Boolean);
        const objectIndex = segments.findIndex((segment) => segment === "object");
        if (objectIndex >= 0 && objectIndex + 3 < segments.length) {
            return {
                bucket: segments[objectIndex + 2],
                path: decodeURIComponent(segments.slice(objectIndex + 3).join("/")),
            };
        }
        for (const bucket of knownBuckets) {
            const bucketIndex = segments.findIndex((segment) => segment === bucket);
            if (bucketIndex >= 0) {
                return {
                    bucket,
                    path: decodeURIComponent(segments.slice(bucketIndex + 1).join("/")),
                };
            }
        }
    }
    catch {
        return null;
    }
    return null;
};
export const storageRefToString = (ref) => `${ref.bucket}/${ref.path}`;
export const resolveMasterReference = (product, config) => {
    const candidates = [product.master_path, product.master_url]
        .map(asNonEmptyString)
        .filter((value) => Boolean(value));
    for (const candidate of candidates) {
        const parsed = parseStorageReference(candidate, config.masterBucket, config);
        if (!parsed)
            continue;
        if (parsed.bucket === config.masterBucket || parsed.bucket === "beats-masters") {
            return parsed;
        }
    }
    return null;
};
export const resolveMasterDownloadSource = async (supabase, product, config) => {
    const canonicalRef = resolveMasterReference(product, config);
    if (!canonicalRef) {
        return null;
    }
    const canonicalExists = await objectExists(supabase, canonicalRef);
    if (!canonicalExists) {
        throw new Error(`master_not_found_in_storage:${storageRefToString(canonicalRef)}`);
    }
    return {
        canonicalRef,
        downloadRef: canonicalRef,
    };
};
export const resolvePreviewReference = (product, config) => {
    const fallbackBucket = asNonEmptyString(product.watermarked_bucket) ?? config.watermarkedBucket;
    const candidates = [product.watermarked_path, product.preview_url, product.exclusive_preview_url]
        .map(asNonEmptyString)
        .filter((value) => Boolean(value));
    for (const candidate of candidates) {
        const parsed = parseStorageReference(candidate, fallbackBucket, config);
        if (parsed)
            return parsed;
    }
    return null;
};
export const objectExists = async (supabase, ref) => {
    const directory = path.posix.dirname(ref.path) === "." ? "" : path.posix.dirname(ref.path);
    const fileName = path.posix.basename(ref.path);
    const { data, error } = await supabase.storage.from(ref.bucket).list(directory, {
        limit: 100,
        search: fileName,
    });
    if (error) {
        throw new Error(`Failed to list storage object ${storageRefToString(ref)}: ${error.message}`);
    }
    return (data ?? []).some((entry) => entry.name === fileName);
};
export const downloadObjectBuffer = async (supabase, ref, maxBytes) => {
    const { data, error } = await supabase.storage.from(ref.bucket).download(ref.path);
    if (error || !data) {
        throw new Error(`Failed to download ${storageRefToString(ref)}: ${error?.message ?? "unknown"}`);
    }
    const blob = data;
    if (typeof blob.size === "number" && blob.size > maxBytes) {
        throw new Error(`Object too large for processing: ${storageRefToString(ref)} (${blob.size} bytes > ${maxBytes})`);
    }
    const buffer = Buffer.from(await blob.arrayBuffer());
    if (buffer.byteLength > maxBytes) {
        throw new Error(`Object too large for processing: ${storageRefToString(ref)} (${buffer.byteLength} bytes > ${maxBytes})`);
    }
    return buffer;
};
export const downloadObjectToFile = async (supabase, ref, maxBytes, destinationPath, signal) => {
    const bucketApi = supabase.storage.from(ref.bucket);
    const downloader = signal
        ? bucketApi.download(ref.path, {}, { signal })
        : bucketApi.download(ref.path);
    const { data, error } = await downloader.asStream();
    if (error || !data) {
        throw new Error(`Failed to stream-download ${storageRefToString(ref)}: ${error?.message ?? "unknown"}`);
    }
    const nodeStream = Readable.fromWeb(data);
    const writer = createWriteStream(destinationPath, { flags: "w" });
    let totalBytes = 0;
    nodeStream.on("data", (chunk) => {
        if (typeof chunk === "string") {
            totalBytes += Buffer.byteLength(chunk);
        }
        else if (chunk instanceof Uint8Array) {
            totalBytes += chunk.byteLength;
        }
        else {
            totalBytes += Buffer.byteLength(String(chunk));
        }
        if (totalBytes > maxBytes) {
            nodeStream.destroy(new Error(`Object too large for processing: ${storageRefToString(ref)} (${totalBytes} bytes > ${maxBytes})`));
        }
    });
    await pipeline(nodeStream, writer);
    return totalBytes;
};
export const loadWatermarkAsset = async (supabase, config, watermarkPath) => {
    const ref = {
        bucket: config.watermarkAssetsBucket,
        path: watermarkPath,
    };
    const buffer = await downloadObjectBuffer(supabase, ref, config.watermarkMaxBytes);
    return { ref, buffer };
};
export const uploadPreviewFile = async (supabase, ref, filePath) => {
    const stream = createReadStream(filePath);
    try {
        const { error } = await supabase.storage.from(ref.bucket).upload(ref.path, stream, {
            contentType: "audio/mpeg",
            cacheControl: "3600",
            upsert: true,
        });
        if (error) {
            throw new Error(`Failed to upload ${storageRefToString(ref)}: ${error.message}`);
        }
    }
    finally {
        stream.destroy();
    }
};
export const getPublicObjectUrl = (supabase, ref) => supabase.storage.from(ref.bucket).getPublicUrl(ref.path).data.publicUrl;
export const guessMasterExtension = (product, sourcePath) => {
    const sourceExtension = sourcePath.split(".").pop()?.toLowerCase();
    if (sourceExtension && /^[a-z0-9]{2,5}$/.test(sourceExtension)) {
        return sourceExtension;
    }
    const format = asNonEmptyString(product.file_format)?.toLowerCase();
    if (!format)
        return "mp3";
    if (format.includes("wav"))
        return "wav";
    if (format.includes("mpeg") || format.includes("mp3"))
        return "mp3";
    return format.replace(/[^a-z0-9]/g, "") || "mp3";
};
