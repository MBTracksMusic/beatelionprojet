export type PipelineMetricPoint = {
  component: string;
  metricName: string;
  metricValue: number | null;
  labels?: Record<string, unknown>;
};

type SupabaseAdminClient = any;

const normalizeNumber = (value: number | null) => {
  if (value === null) return null;
  if (!Number.isFinite(value)) return null;
  return value;
};

export const insertPipelineMetrics = async (
  supabaseAdmin: SupabaseAdminClient,
  points: PipelineMetricPoint[],
) => {
  if (!points.length) return;

  const rows = points
    .map((point) => ({
      component: point.component,
      metric_name: point.metricName,
      metric_value: normalizeNumber(point.metricValue),
      labels: point.labels ?? {},
    }))
    .filter((row) => row.metric_value !== null);

  if (!rows.length) return;

  const { error } = await supabaseAdmin
    .from("pipeline_metrics")
    .insert(rows);

  if (error) {
    throw new Error(`pipeline_metrics_insert_failed:${error.message}`);
  }
};

export const safeInsertPipelineMetrics = async (
  supabaseAdmin: SupabaseAdminClient,
  points: PipelineMetricPoint[],
  context: string,
) => {
  try {
    await insertPipelineMetrics(supabaseAdmin, points);
    return true;
  } catch (error) {
    console.error(`[${context}] metrics insert failed`, error);
    return false;
  }
};
