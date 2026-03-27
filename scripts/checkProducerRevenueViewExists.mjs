import { execFileSync } from 'node:child_process';

export function checkProducerRevenueViewExists() {
  const dbUrl = process.env.SUPABASE_DB_URL;

  if (!dbUrl) {
    throw new Error('Missing SUPABASE_DB_URL');
  }

  const result = execFileSync(
    'psql',
    [
      dbUrl,
      '-Atc',
      "SELECT to_regclass('public.producer_revenue_view');",
    ],
    {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe'],
    },
  ).trim();

  return result === 'producer_revenue_view' || result === 'public.producer_revenue_view';
}

if (process.argv[1] && import.meta.url === new URL(`file://${process.argv[1]}`).href) {
  try {
    const exists = checkProducerRevenueViewExists();
    console.log(exists ? 'producer_revenue_view exists' : 'producer_revenue_view missing');
    process.exit(exists ? 0 : 1);
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    console.error(`Unable to check producer_revenue_view: ${message}`);
    process.exit(1);
  }
}
