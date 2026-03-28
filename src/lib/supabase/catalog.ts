import { supabase } from './client';
import type { Database, Json } from './database.types';
import { attachProductLicenses } from '../pricing';
import { fetchPublicProducerProfilesMap } from './publicProfiles';
import type { ProductWithRelations } from './types';

export type CatalogMode = 'beats' | 'exclusives' | 'kits';

export interface CatalogFilters {
  search: string;
  genre: string;
  mood: string;
  bpmMin: string;
  bpmMax: string;
  priceMin: string;
  priceMax: string;
  sort: string;
}

interface FetchCatalogProductsParams {
  mode: CatalogMode;
  filters: CatalogFilters;
  limit?: number;
  restrictToActiveProducers?: boolean;
  hasPremiumAccess?: boolean;
}

interface FetchCatalogProductBySlugParams {
  slug: string;
  routePrefix: string;
}

type CatalogProductRow = Database['public']['Views']['public_catalog_products']['Row'];

const CATALOG_SELECT_COLUMNS = [
  'id',
  'title',
  'price',
  'preview_url',
  'cover_image_url',
  'bpm',
  'key_signature',
].join(', ');

const DEFAULT_TIMESTAMP = new Date(0).toISOString();

const toProduct = (row: Partial<CatalogProductRow> | null | undefined): ProductWithRelations => {
  const createdAt = row?.created_at ?? DEFAULT_TIMESTAMP;
  const updatedAt = row?.updated_at ?? createdAt;
  const producerUsername = row?.producer_username ?? row?.producer_raw_username ?? null;

  return {
    id: row?.id ?? '',
    producer_id: row?.producer_id ?? '',
    title: row?.title ?? '',
    slug: row?.slug ?? '',
    description: row?.description ?? null,
    product_type: (row?.product_type ?? 'beat') as ProductWithRelations['product_type'],
    genre_id: row?.genre_id ?? null,
    mood_id: row?.mood_id ?? null,
    bpm: row?.bpm ?? null,
    key_signature: row?.key_signature ?? null,
    price: row?.price ?? 0,
    early_access_until: row?.early_access_until ?? null,
    watermarked_path: row?.watermarked_path ?? null,
    watermarked_bucket: row?.watermarked_bucket ?? null,
    preview_url: row?.preview_url ?? null,
    exclusive_preview_url: row?.exclusive_preview_url ?? null,
    cover_image_url: row?.cover_image_url ?? null,
    is_exclusive: row?.is_exclusive ?? false,
    is_sold: row?.is_sold ?? false,
    sold_at: row?.sold_at ?? null,
    sold_to_user_id: row?.sold_to_user_id ?? null,
    is_published: row?.is_published ?? false,
    status: row?.status ?? 'active',
    version: row?.version ?? 1,
    original_beat_id: row?.original_beat_id ?? null,
    version_number: row?.version_number ?? 1,
    parent_product_id: row?.parent_product_id ?? null,
    archived_at: row?.archived_at ?? null,
    play_count: row?.play_count ?? 0,
    tags: row?.tags ?? null,
    duration_seconds: row?.duration_seconds ?? null,
    file_format: row?.file_format ?? null,
    license_terms: (row?.license_terms ?? null) as Json,
    watermark_profile_id: row?.watermark_profile_id ?? null,
    created_at: createdAt,
    updated_at: updatedAt,
    deleted_at: row?.deleted_at ?? null,
    producer: row?.producer_id
      ? {
          id: row.producer_id,
          username: producerUsername,
          avatar_url: row?.producer_avatar_url ?? null,
        }
      : undefined,
    genre: row?.genre_id
      ? {
          id: row.genre_id,
          name: row?.genre_name ?? '',
          name_en: row?.genre_name_en ?? row?.genre_name ?? '',
          name_de: row?.genre_name_de ?? row?.genre_name ?? '',
          slug: row?.genre_slug ?? '',
          description: null,
          icon: null,
          sort_order: 0,
          is_active: true,
          created_at: createdAt,
        }
      : undefined,
    mood: row?.mood_id
      ? {
          id: row.mood_id,
          name: row?.mood_name ?? '',
          name_en: row?.mood_name_en ?? row?.mood_name ?? '',
          name_de: row?.mood_name_de ?? row?.mood_name ?? '',
          slug: row?.mood_slug ?? '',
          description: null,
          color: null,
          sort_order: 0,
          is_active: true,
          created_at: createdAt,
        }
      : undefined,
  } as ProductWithRelations;
};

const hasMissingProducerIdentity = (product: ProductWithRelations) => {
  if (!product.producer_id) return false;
  const username = product.producer?.username;
  if (typeof username !== 'string') return true;
  return username.trim().length === 0;
};

const enrichMissingProducerIdentities = async (
  products: ProductWithRelations[]
): Promise<ProductWithRelations[]> => {
  const missingProducerIds = [
    ...new Set(
      products
        .filter(hasMissingProducerIdentity)
        .map((product) => product.producer_id)
        .filter((value): value is string => typeof value === 'string' && value.length > 0)
    ),
  ];

  if (missingProducerIds.length === 0) {
    return products;
  }

  try {
    const profilesMap = await fetchPublicProducerProfilesMap(missingProducerIds);
    if (profilesMap.size === 0) return products;

    return products.map((product) => {
      if (!product.producer_id) return product;
      const profile = profilesMap.get(product.producer_id);
      if (!profile) return product;

      return {
        ...product,
        producer: {
          id: product.producer_id,
          username: profile.username ?? profile.raw_username ?? product.producer?.username ?? null,
          avatar_url: profile.avatar_url ?? product.producer?.avatar_url ?? null,
        } as ProductWithRelations['producer'],
      } as ProductWithRelations;
    });
  } catch (error) {
    console.error('catalog producer identity enrich error', error);
    return products;
  }
};

const applyProducerVisibility = async (
  products: ProductWithRelations[],
  restrictToActiveProducers: boolean
): Promise<ProductWithRelations[]> => {
  if (!restrictToActiveProducers) {
    return enrichMissingProducerIdentities(products);
  }

  const producerIds = [
    ...new Set(
      products
        .map((product) => product.producer_id)
        .filter((value): value is string => typeof value === 'string' && value.length > 0)
    ),
  ];

  if (producerIds.length === 0) {
    return products;
  }

  try {
    const profilesMap = await fetchPublicProducerProfilesMap(producerIds);

    const visibleProducts = products.filter((product) => {
      const profile = profilesMap.get(product.producer_id);
      return profile?.is_producer_active === true;
    });

    return visibleProducts.map((product) => {
      const profile = profilesMap.get(product.producer_id);
      if (!profile) return product;

      return {
        ...product,
        producer: {
          id: product.producer_id,
          username: profile.username ?? profile.raw_username ?? product.producer?.username ?? null,
          avatar_url: profile.avatar_url ?? product.producer?.avatar_url ?? null,
        } as ProductWithRelations['producer'],
      } as ProductWithRelations;
    });
  } catch (error) {
    console.error('catalog producer visibility enrich error', error);
    return enrichMissingProducerIdentities(products);
  }
};

const fetchLegacyCatalogProducts = async (
  params: FetchCatalogProductsParams
): Promise<ProductWithRelations[]> => {
  void params;
  return [];
};

const fetchLegacyCatalogProductBySlug = async (
  params: FetchCatalogProductBySlugParams
): Promise<ProductWithRelations | null> => {
  void params;
  return null;
};

export async function fetchCatalogProducts({
  mode,
  filters,
  limit = 50,
  restrictToActiveProducers = false,
  hasPremiumAccess = false,
}: FetchCatalogProductsParams): Promise<ProductWithRelations[]> {
  const query = supabase
    .from('public_catalog_products')
    .select(CATALOG_SELECT_COLUMNS);

  const { data, error } = await query.limit(limit);
  if (error) {
    console.warn('public_catalog_products query failed, returning empty catalog result', error);
    return fetchLegacyCatalogProducts({ mode, filters, limit, restrictToActiveProducers, hasPremiumAccess });
  }

  const rows = (data as unknown as Partial<CatalogProductRow>[] | null) ?? [];
  const products = rows.map(toProduct);
  const visibleProducts = await applyProducerVisibility(products, restrictToActiveProducers);
  return visibleProducts;
}

export async function fetchCatalogProductBySlug({
  slug,
  routePrefix,
}: FetchCatalogProductBySlugParams): Promise<ProductWithRelations | null> {
  if (!CATALOG_SELECT_COLUMNS.includes('slug')) {
    return fetchLegacyCatalogProductBySlug({ slug, routePrefix });
  }

  const query = supabase
    .from('public_catalog_products')
    .select(CATALOG_SELECT_COLUMNS)
    .eq('slug', slug);

  const { data, error } = await query.maybeSingle();
  if (error) {
    console.warn('public_catalog_products detail query failed, returning null', error);
    return fetchLegacyCatalogProductBySlug({ slug, routePrefix });
  }

  const row = (data as unknown as Partial<CatalogProductRow> | null) ?? null;
  if (!row) {
    return fetchLegacyCatalogProductBySlug({ slug, routePrefix });
  }

  const product = toProduct(row);
  const [enriched] = await enrichMissingProducerIdentities([product]);
  const [withLicenses] = await attachProductLicenses([enriched ?? product]);
  return withLicenses ?? enriched ?? product;
}
