import { create } from 'zustand';
import { supabase } from '@/lib/supabase/client';
import { attachProductLicenses, getDefaultProductLicense, resolveProductLicense } from '../pricing';
import { GENRE_SAFE_COLUMNS, MOOD_SAFE_COLUMNS, PRODUCT_SAFE_COLUMNS } from '../supabase/selects';
import type { CartItemWithProduct } from '../supabase/types';

type AddToCartOptions =
  | string
  | {
      licenseId?: string | null;
      licenseType?: string | null;
    };

interface CartState {
  items: CartItemWithProduct[];
  isLoading: boolean;
  fetchCart: () => Promise<void>;
  addToCart: (productId: string, options?: AddToCartOptions) => Promise<void>;
  removeFromCart: (productId: string) => Promise<void>;
  clearCart: () => Promise<void>;
  getTotal: () => number;
  getItemCount: () => number;
}

export const useCartStore = create<CartState>((set, get) => ({
  items: [],
  isLoading: false,

  fetchCart: async () => {
    set({ isLoading: true });
    try {
      const { data: { user } } = await supabase.auth.getUser();
      if (!user) {
        set({ items: [], isLoading: false });
        return;
      }

      const { data, error } = await supabase
        .from('cart_items')
        .select(`
          *,
          product:products(
            ${PRODUCT_SAFE_COLUMNS},
            producer:user_profiles!products_producer_id_fkey(id, username, avatar_url),
            genre:genres(${GENRE_SAFE_COLUMNS}),
            mood:moods(${MOOD_SAFE_COLUMNS})
          )
        ` as any)
        .eq('user_id', user.id);

      if (error) throw error;

      const rows = ((data as unknown as CartItemWithProduct[] | null) ?? []);
      const validItems = rows.filter((item): item is CartItemWithProduct & { product: NonNullable<CartItemWithProduct['product']> } => {
        if (!item.product) return false;
        return item.product.is_published && (!item.product.is_exclusive || !item.product.is_sold);
      });

      const hydratedProducts = await attachProductLicenses(
        validItems
          .map((item) => item.product)
          .filter((product): product is NonNullable<CartItemWithProduct['product']> => Boolean(product))
      );

      const productById = new Map(hydratedProducts.map((product) => [product.id, product]));
      const hydratedItems = validItems.map((item) => {
        const product = productById.get(item.product_id) ?? item.product;
        const selectedLicense =
          resolveProductLicense(product, {
            licenseId: item.license_id,
            licenseType: item.license_type,
          }) ?? getDefaultProductLicense(product);

        return {
          ...item,
          product,
          license_id: item.license_id ?? selectedLicense?.license_id ?? null,
          license_type: item.license_type ?? selectedLicense?.license_type ?? null,
          selected_license: selectedLicense,
        };
      });

      set({ items: hydratedItems, isLoading: false });
    } catch (error) {
      console.error('Error fetching cart:', error);
      set({ isLoading: false });
    }
  },

  addToCart: async (productId: string, options) => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) throw new Error('Must be logged in to add to cart');

    const normalizedOptions =
      typeof options === 'string'
        ? {
            licenseId: null,
            licenseType: options,
          }
        : {
            licenseId: options?.licenseId ?? null,
            licenseType: options?.licenseType ?? null,
          };

    const { error } = await supabase
      .from('cart_items')
      .upsert({
        user_id: user.id,
        product_id: productId,
        license_id: normalizedOptions.licenseId,
        license_type: normalizedOptions.licenseType,
      }, {
        onConflict: 'user_id,product_id',
      });

    if (error) throw error;
    await get().fetchCart();
  },

  removeFromCart: async (productId: string) => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;

    const { error } = await supabase
      .from('cart_items')
      .delete()
      .eq('user_id', user.id)
      .eq('product_id', productId);

    if (error) throw error;
    await get().fetchCart();
  },

  clearCart: async () => {
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;

    const { error } = await supabase
      .from('cart_items')
      .delete()
      .eq('user_id', user.id);

    if (error) throw error;
    set({ items: [] });
  },

  getTotal: () => {
    return get().items.reduce((total, item) => {
      return total + (item.selected_license?.price ?? item.product?.price ?? 0);
    }, 0);
  },

  getItemCount: () => {
    return get().items.length;
  },
}));
