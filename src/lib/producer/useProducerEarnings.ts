import { useCallback, useEffect, useState } from 'react';
import { supabase } from '@/lib/supabase/client';
import {
  isProducerEarningsFallbackForced,
  trackProducerEarningsFallback,
} from '@/lib/monitoring/trackProducerEarningsFallback';

export interface ProducerEarningsRow {
  id: string;
  created_at: string;
  product_id: string;
  product_title: string;
  purchase_source: string | null;
  amount_earned_eur: number;
  payout_status: string;
  payout_mode: string;
  payout_processed_at: string | null;
}

type ProducerEarningsSource = 'view' | 'fallback';

type QueryErrorLike = {
  code?: string;
  message?: string;
  details?: string;
  hint?: string;
};

interface FallbackPurchaseRow {
  id: string;
  created_at: string;
  product_id: string;
  purchase_source: string | null;
  producer_share_cents_snapshot: number | null;
  metadata: Record<string, unknown> | null;
  product: {
    title: string | null;
    producer_id: string | null;
  } | null;
}

const isObjectRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === 'object' && value !== null && !Array.isArray(value);

const coerceString = (value: unknown, fallback: string) =>
  typeof value === 'string' && value.trim().length > 0 ? value : fallback;

const coerceNullableString = (value: unknown) =>
  typeof value === 'string' && value.trim().length > 0 ? value : null;

const roundToTwo = (value: number) => Math.round((value + Number.EPSILON) * 100) / 100;

const sortByCreatedAtDesc = (rows: ProducerEarningsRow[]) =>
  [...rows].sort((left, right) => new Date(right.created_at).getTime() - new Date(left.created_at).getTime());

const normalizeProducerEarningRow = (row: ProducerEarningsRow): ProducerEarningsRow => ({
  id: row.id,
  created_at: row.created_at,
  product_id: row.product_id,
  product_title: coerceString(row.product_title, 'Unknown product'),
  purchase_source: typeof row.purchase_source === 'string' ? row.purchase_source : null,
  amount_earned_eur: roundToTwo(typeof row.amount_earned_eur === 'number' ? row.amount_earned_eur : 0),
  payout_status: coerceString(row.payout_status, 'pending'),
  payout_mode: coerceString(row.payout_mode, 'stripe_connect'),
  payout_processed_at: coerceNullableString(row.payout_processed_at),
});

const isProducerRevenueViewMissingError = (error: QueryErrorLike | null | undefined) => {
  if (!error) return false;

  if (error.code === 'PGRST205' || error.code === '42P01') {
    return true;
  }

  const message = `${error.message ?? ''} ${error.details ?? ''} ${error.hint ?? ''}`.toLowerCase();
  return message.includes('producer_revenue_view') || message.includes('relation does not exist');
};

const normalizeViewRows = (rows: ProducerEarningsRow[] | null | undefined): ProducerEarningsRow[] =>
  sortByCreatedAtDesc((rows ?? []).map((row) => normalizeProducerEarningRow(row)));

const normalizeFallbackRows = (rows: FallbackPurchaseRow[] | null | undefined): ProducerEarningsRow[] =>
  sortByCreatedAtDesc((rows ?? []).map((row) => {
    const metadata = isObjectRecord(row.metadata) ? row.metadata : {};

    return normalizeProducerEarningRow({
      id: row.id,
      created_at: row.created_at,
      product_id: row.product_id,
      product_title: row.product?.title?.trim() || 'Unknown product',
      purchase_source: row.purchase_source,
      amount_earned_eur: (row.producer_share_cents_snapshot ?? 0) / 100,
      payout_status: coerceString(metadata.payout_status, 'pending'),
      payout_mode: coerceString(metadata.payout_mode, 'stripe_connect'),
      payout_processed_at: coerceNullableString(metadata.payout_processed_at),
    });
  }));

async function fetchProducerEarningsFromView() {
  const { data, error } = await supabase
    .from('producer_revenue_view')
    .select('*')
    .order('created_at', { ascending: false });

  if (error) {
    throw error;
  }

  return normalizeViewRows((data as ProducerEarningsRow[] | null) ?? []);
}

async function fetchProducerEarningsFromFallback(producerId: string) {
  const { data, error } = await supabase
    .from('purchases')
    .select(`
      id,
      created_at,
      product_id,
      purchase_source,
      producer_share_cents_snapshot,
      metadata,
      product:products!inner(
        title,
        producer_id
      )
    `)
    .eq('product.producer_id', producerId)
    .eq('status', 'completed')
    .order('created_at', { ascending: false });

  if (error) {
    throw error;
  }

  return normalizeFallbackRows((data as FallbackPurchaseRow[] | null) ?? []);
}

export function useProducerEarnings(producerId?: string) {
  const [data, setData] = useState<ProducerEarningsRow[]>([]);
  const [isLoading, setIsLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [source, setSource] = useState<ProducerEarningsSource>('view');

  const refetch = useCallback(async () => {
    if (!producerId) {
      setData([]);
      setError(null);
      setIsLoading(false);
      setSource('view');
      return [];
    }

    setIsLoading(true);
    setError(null);

    const forceFallback = isProducerEarningsFallbackForced();

    try {
      if (forceFallback) {
        const rows = await fetchProducerEarningsFromFallback(producerId);
        trackProducerEarningsFallback(producerId);
        setData(rows);
        setSource('fallback');
        return rows;
      }

      const rows = await fetchProducerEarningsFromView();
      setData(rows);
      setSource('view');
      return rows;
    } catch (fetchError) {
      const queryError = (fetchError ?? null) as QueryErrorLike | null;

      if (forceFallback) {
        console.error('Failed to load producer earnings via forced fallback query', fetchError);
      } else if (isProducerRevenueViewMissingError(queryError)) {
        try {
          const rows = await fetchProducerEarningsFromFallback(producerId);
          trackProducerEarningsFallback(producerId);
          setData(rows);
          setSource('fallback');
          return rows;
        } catch (fallbackError) {
          console.error('Failed to load producer earnings via fallback query', fallbackError);
        }
      } else {
        console.error('Failed to load producer earnings view', fetchError);
      }

      setData([]);
      setError('producer_earnings_load_failed');
      setSource('view');
      return [];
    } finally {
      setIsLoading(false);
    }
  }, [producerId]);

  useEffect(() => {
    void refetch();
  }, [refetch]);

  return {
    data,
    loading: isLoading,
    isLoading,
    error,
    source,
    refetch,
  };
}
