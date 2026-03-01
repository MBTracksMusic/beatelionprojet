import { useCallback, useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Button } from '../../components/ui/Button';
import { Card } from '../../components/ui/Card';
import { Input } from '../../components/ui/Input';
import { supabase } from '../../lib/supabase/client';
import { slugify } from '../../lib/utils/format';

type ForumCategoryRow = {
  id: string;
  name: string;
  slug: string;
  description: string | null;
  created_at: string;
};

const FORUM_CATEGORIES_TABLE = 'forum_categories' as any;

interface CategoryFormState {
  name: string;
  description: string;
}

const EMPTY_FORM: CategoryFormState = {
  name: '',
  description: '',
};

export function AdminForumCategoriesPage() {
  const [categories, setCategories] = useState<ForumCategoryRow[]>([]);
  const [form, setForm] = useState<CategoryFormState>(EMPTY_FORM);
  const [editingId, setEditingId] = useState<string | null>(null);
  const [isLoading, setIsLoading] = useState(true);
  const [actionKey, setActionKey] = useState<string | null>(null);

  const isSubmitting = actionKey === 'submit';

  const sortedCategories = useMemo(
    () => [...categories].sort((a, b) => a.name.localeCompare(b.name, 'fr')),
    [categories],
  );

  const resetForm = () => {
    setForm(EMPTY_FORM);
    setEditingId(null);
  };

  const loadCategories = useCallback(async () => {
    setIsLoading(true);
    const { data, error } = await supabase
      .from(FORUM_CATEGORIES_TABLE)
      .select('id, name, slug, description, created_at')
      .order('name', { ascending: true });

    if (error) {
      console.error('Error loading forum categories', error);
      toast.error('Impossible de charger les categories forum.');
      setCategories([]);
      setIsLoading(false);
      return;
    }

    setCategories((data as unknown as ForumCategoryRow[] | null) ?? []);
    setIsLoading(false);
  }, []);

  useEffect(() => {
    void loadCategories();
  }, [loadCategories]);

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (isSubmitting) return;

    const name = form.name.trim();
    const description = form.description.trim();

    if (name.length === 0) {
      toast.error('Le nom de la categorie est requis.');
      return;
    }

    const slug = slugify(name);
    if (!slug) {
      toast.error('Impossible de generer un slug valide.');
      return;
    }

    setActionKey('submit');

    if (editingId) {
      const { data, error } = await supabase
        .from(FORUM_CATEGORIES_TABLE)
        .update({
          name,
          slug,
          description: description || null,
        })
        .eq('id', editingId)
        .select('id, name, slug, description, created_at')
        .single();

      if (error) {
        console.error('Error updating forum category', error);
        toast.error('Modification impossible.');
        setActionKey(null);
        return;
      }

      const nextCategory = data as unknown as ForumCategoryRow;
      setCategories((prev) => prev.map((category) => (category.id === editingId ? nextCategory : category)));
      toast.success('Categorie mise a jour.');
      resetForm();
      setActionKey(null);
      return;
    }

    const { data, error } = await supabase
      .from(FORUM_CATEGORIES_TABLE)
      .insert({
        name,
        slug,
        description: description || null,
      })
      .select('id, name, slug, description, created_at')
      .single();

    if (error) {
      console.error('Error creating forum category', error);
      toast.error('Creation impossible.');
      setActionKey(null);
      return;
    }

    setCategories((prev) => [...prev, data as unknown as ForumCategoryRow]);
    toast.success('Categorie creee.');
    resetForm();
    setActionKey(null);
  };

  const startEdit = (category: ForumCategoryRow) => {
    setEditingId(category.id);
    setForm({
      name: category.name,
      description: category.description ?? '',
    });
  };

  const deleteCategory = async (categoryId: string) => {
    setActionKey(`delete:${categoryId}`);
    const { error } = await supabase.from(FORUM_CATEGORIES_TABLE).delete().eq('id', categoryId);

    if (error) {
      console.error('Error deleting forum category', error);
      toast.error('Suppression impossible.');
      setActionKey(null);
      return;
    }

    setCategories((prev) => prev.filter((category) => category.id !== categoryId));
    if (editingId === categoryId) {
      resetForm();
    }
    toast.success('Categorie supprimee.');
    setActionKey(null);
  };

  return (
    <div className="space-y-4">
      <Card className="p-4 sm:p-5">
        <div className="flex flex-col gap-2 sm:flex-row sm:items-end sm:justify-between">
          <div>
            <h2 className="text-xl font-semibold text-white">Forum Categories</h2>
            <p className="text-zinc-400 text-sm mt-1">
              Creez, modifiez et supprimez les categories du forum.
            </p>
          </div>
          <Button variant="outline" onClick={() => void loadCategories()}>
            Actualiser
          </Button>
        </div>
      </Card>

      <Card className="p-4 sm:p-5">
        <h3 className="text-lg font-semibold text-white mb-4">
          {editingId ? 'Modifier la categorie' : 'Nouvelle categorie'}
        </h3>
        <form onSubmit={handleSubmit} className="space-y-4">
          <Input
            label="Nom"
            value={form.name}
            onChange={(event) => setForm((prev) => ({ ...prev, name: event.target.value }))}
            placeholder="General"
            disabled={isSubmitting}
          />
          <div>
            <label className="block text-sm font-medium text-zinc-300 mb-1.5" htmlFor="forum-category-description">
              Description
            </label>
            <textarea
              id="forum-category-description"
              value={form.description}
              onChange={(event) => setForm((prev) => ({ ...prev, description: event.target.value }))}
              placeholder="Description courte de la categorie"
              disabled={isSubmitting}
              rows={4}
              className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-2.5 text-white placeholder-zinc-500 focus:border-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500/50 disabled:cursor-not-allowed disabled:opacity-50"
            />
          </div>
          <div className="flex flex-wrap gap-3">
            <Button type="submit" isLoading={isSubmitting}>
              {editingId ? 'Enregistrer' : 'Creer la categorie'}
            </Button>
            {editingId && (
              <Button type="button" variant="outline" onClick={resetForm} disabled={isSubmitting}>
                Annuler
              </Button>
            )}
          </div>
        </form>
      </Card>

      <Card className="p-4 sm:p-5">
        <h3 className="text-lg font-semibold text-white mb-4">Categories existantes</h3>
        {isLoading ? (
          <p className="text-zinc-400">Chargement...</p>
        ) : sortedCategories.length === 0 ? (
          <p className="text-zinc-500">Aucune categorie.</p>
        ) : (
          <div className="space-y-3">
            {sortedCategories.map((category) => (
              <div key={category.id} className="rounded-lg border border-zinc-800 bg-zinc-950/60 p-4">
                <div className="flex flex-col gap-3 md:flex-row md:items-start md:justify-between">
                  <div className="space-y-1">
                    <p className="text-sm text-zinc-500">
                      {category.slug} • {new Date(category.created_at).toLocaleString('fr-FR')}
                    </p>
                    <h4 className="text-white font-medium">{category.name}</h4>
                    {category.description && (
                      <p className="text-sm text-zinc-300 whitespace-pre-wrap">{category.description}</p>
                    )}
                  </div>
                  <div className="flex gap-2">
                    <Button type="button" variant="outline" size="sm" onClick={() => startEdit(category)}>
                      Modifier
                    </Button>
                    <Button
                      type="button"
                      variant="danger"
                      size="sm"
                      isLoading={actionKey === `delete:${category.id}`}
                      onClick={() => void deleteCategory(category.id)}
                    >
                      Supprimer
                    </Button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </Card>
    </div>
  );
}
