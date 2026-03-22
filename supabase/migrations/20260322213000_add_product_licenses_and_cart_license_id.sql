/*
  # Product-specific licensing catalog

  Goals:
  - keep the existing global `licenses` catalog for purchases and legal snapshots
  - add product-level pricing overrides and optional Stripe price ids
  - store the selected license on cart items
  - seed a default multi-license structure for existing products
*/

BEGIN;

INSERT INTO public.licenses (
  name,
  description,
  max_streams,
  max_sales,
  youtube_monetization,
  music_video_allowed,
  credit_required,
  exclusive_allowed,
  price
) VALUES
  (
    'Basic',
    'Entry license for non-exclusive beat usage.',
    50000,
    NULL,
    true,
    false,
    true,
    false,
    1900
  ),
  (
    'Unlimited',
    'Extended commercial license with broader monetization rights.',
    NULL,
    NULL,
    true,
    true,
    true,
    false,
    7900
  )
ON CONFLICT (name) DO UPDATE SET
  description = EXCLUDED.description,
  max_streams = EXCLUDED.max_streams,
  max_sales = EXCLUDED.max_sales,
  youtube_monetization = EXCLUDED.youtube_monetization,
  music_video_allowed = EXCLUDED.music_video_allowed,
  credit_required = EXCLUDED.credit_required,
  exclusive_allowed = EXCLUDED.exclusive_allowed,
  price = EXCLUDED.price,
  updated_at = now();

UPDATE public.licenses
SET
  description = 'Extended commercial license with higher distribution limits.',
  price = 4900,
  updated_at = now()
WHERE lower(name) = 'premium';

UPDATE public.licenses
SET
  description = 'Exclusive rights transfer for one-off ownership.',
  price = GREATEST(price, 12000),
  updated_at = now()
WHERE lower(name) = 'exclusive';

CREATE TABLE IF NOT EXISTS public.product_licenses (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  license_id uuid NOT NULL REFERENCES public.licenses(id) ON DELETE RESTRICT,
  license_type text NOT NULL,
  price integer NOT NULL CHECK (price >= 0),
  stripe_price_id text NULL,
  features jsonb NULL,
  sort_order integer NOT NULL DEFAULT 0,
  is_active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT uq_product_licenses_product_license UNIQUE (product_id, license_id)
);

CREATE INDEX IF NOT EXISTS idx_product_licenses_product_id
  ON public.product_licenses (product_id);

CREATE INDEX IF NOT EXISTS idx_product_licenses_license_id
  ON public.product_licenses (license_id);

CREATE INDEX IF NOT EXISTS idx_product_licenses_product_active_sort
  ON public.product_licenses (product_id, is_active, sort_order, price);

ALTER TABLE public.product_licenses ENABLE ROW LEVEL SECURITY;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_policies
    WHERE schemaname = 'public'
      AND tablename = 'product_licenses'
      AND policyname = 'Anyone can read product licenses'
  ) THEN
    CREATE POLICY "Anyone can read product licenses"
      ON public.product_licenses
      FOR SELECT
      TO anon, authenticated
      USING (true);
  END IF;
END
$$;

GRANT SELECT ON TABLE public.product_licenses TO anon;
GRANT SELECT ON TABLE public.product_licenses TO authenticated;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_trigger
    WHERE tgname = 'update_product_licenses_updated_at'
      AND tgrelid = 'public.product_licenses'::regclass
  ) THEN
    CREATE TRIGGER update_product_licenses_updated_at
      BEFORE UPDATE ON public.product_licenses
      FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
  END IF;
END
$$;

ALTER TABLE public.cart_items
  ADD COLUMN IF NOT EXISTS license_id uuid NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'cart_items_license_id_fkey'
      AND conrelid = 'public.cart_items'::regclass
  ) THEN
    ALTER TABLE public.cart_items
      ADD CONSTRAINT cart_items_license_id_fkey
      FOREIGN KEY (license_id)
      REFERENCES public.licenses(id)
      ON DELETE RESTRICT;
  END IF;
END
$$;

CREATE INDEX IF NOT EXISTS idx_cart_items_license_id
  ON public.cart_items (license_id)
  WHERE license_id IS NOT NULL;

UPDATE public.cart_items ci
SET license_id = l.id
FROM public.licenses l
WHERE ci.license_id IS NULL
  AND lower(COALESCE(ci.license_type, '')) = lower(l.name);

CREATE OR REPLACE FUNCTION public.seed_default_product_licenses(p_product_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
  v_product public.products%ROWTYPE;
  v_basic_id uuid;
  v_premium_id uuid;
  v_unlimited_id uuid;
  v_exclusive_id uuid;
BEGIN
  IF p_product_id IS NULL THEN
    RETURN;
  END IF;

  SELECT *
  INTO v_product
  FROM public.products
  WHERE id = p_product_id;

  IF NOT FOUND THEN
    RETURN;
  END IF;

  IF v_product.product_type = 'kit'::public.product_type THEN
    RETURN;
  END IF;

  SELECT id INTO v_basic_id
  FROM public.licenses
  WHERE lower(name) = 'basic'
  ORDER BY created_at ASC
  LIMIT 1;

  SELECT id INTO v_premium_id
  FROM public.licenses
  WHERE lower(name) = 'premium'
  ORDER BY created_at ASC
  LIMIT 1;

  SELECT id INTO v_unlimited_id
  FROM public.licenses
  WHERE lower(name) = 'unlimited'
  ORDER BY created_at ASC
  LIMIT 1;

  SELECT id INTO v_exclusive_id
  FROM public.licenses
  WHERE lower(name) = 'exclusive'
  ORDER BY created_at ASC
  LIMIT 1;

  IF v_product.is_exclusive IS TRUE OR v_product.product_type = 'exclusive'::public.product_type THEN
    IF v_exclusive_id IS NOT NULL THEN
      INSERT INTO public.product_licenses (
        product_id,
        license_id,
        license_type,
        price,
        features,
        sort_order
      )
      VALUES (
        v_product.id,
        v_exclusive_id,
        'exclusive',
        GREATEST(COALESCE(v_product.price, 0), 12000),
        jsonb_build_object(
          'distribution', 'exclusive',
          'transfer_of_rights', true
        ),
        0
      )
      ON CONFLICT (product_id, license_id) DO NOTHING;
    END IF;

    RETURN;
  END IF;

  IF v_basic_id IS NOT NULL THEN
    INSERT INTO public.product_licenses (
      product_id,
      license_id,
      license_type,
      price,
      features,
      sort_order
    )
    VALUES (
      v_product.id,
      v_basic_id,
      'basic',
      1900,
      jsonb_build_object(
        'distribution', 'non-exclusive',
        'tier', 'entry'
      ),
      0
    )
    ON CONFLICT (product_id, license_id) DO NOTHING;
  END IF;

  IF v_premium_id IS NOT NULL THEN
    INSERT INTO public.product_licenses (
      product_id,
      license_id,
      license_type,
      price,
      features,
      sort_order
    )
    VALUES (
      v_product.id,
      v_premium_id,
      'premium',
      4900,
      jsonb_build_object(
        'distribution', 'non-exclusive',
        'tier', 'commercial'
      ),
      1
    )
    ON CONFLICT (product_id, license_id) DO NOTHING;
  END IF;

  IF v_unlimited_id IS NOT NULL THEN
    INSERT INTO public.product_licenses (
      product_id,
      license_id,
      license_type,
      price,
      features,
      sort_order
    )
    VALUES (
      v_product.id,
      v_unlimited_id,
      'unlimited',
      7900,
      jsonb_build_object(
        'distribution', 'non-exclusive',
        'tier', 'unlimited'
      ),
      2
    )
    ON CONFLICT (product_id, license_id) DO NOTHING;
  END IF;
END;
$$;

COMMENT ON FUNCTION public.seed_default_product_licenses(uuid) IS
  'Seeds default product-specific licenses for beats and exclusive products without overwriting existing mappings.';

CREATE OR REPLACE FUNCTION public.seed_default_product_licenses_trigger()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
BEGIN
  PERFORM public.seed_default_product_licenses(NEW.id);
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_seed_default_product_licenses ON public.products;
CREATE TRIGGER trg_seed_default_product_licenses
  AFTER INSERT ON public.products
  FOR EACH ROW
  EXECUTE FUNCTION public.seed_default_product_licenses_trigger();

SELECT public.seed_default_product_licenses(p.id)
FROM public.products p;

COMMIT;
