import { useEffect, useMemo, useState } from 'react';
import toast from 'react-hot-toast';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { ChevronLeft } from 'lucide-react';
import { Button } from '../../components/ui/Button';
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from '../../components/ui/Card';
import { Input } from '../../components/ui/Input';
import { useForumActions, useForumCategories } from '../../lib/forum/hooks';

export function CreateTopicPage() {
  const navigate = useNavigate();
  const [searchParams] = useSearchParams();
  const categorySlugParam = searchParams.get('category') || '';
  const { categories, isLoading, error } = useForumCategories();
  const { createTopic, isSubmitting } = useForumActions();

  const [categoryId, setCategoryId] = useState('');
  const [title, setTitle] = useState('');
  const [content, setContent] = useState('');

  useEffect(() => {
    if (!categorySlugParam || categories.length === 0) return;
    const category = categories.find((item) => item.slug === categorySlugParam);
    if (category) {
      setCategoryId(category.id);
    }
  }, [categories, categorySlugParam]);

  const selectedCategory = useMemo(
    () => categories.find((item) => item.id === categoryId) ?? null,
    [categories, categoryId],
  );

  const handleSubmit = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();

    const trimmedTitle = title.trim();
    const trimmedContent = content.trim();

    if (!categoryId || !trimmedTitle || !trimmedContent) {
      toast.error('Categorie, titre et message sont obligatoires.');
      return;
    }

    try {
      const topic = await createTopic({
        categoryId,
        title: trimmedTitle,
        content: trimmedContent,
      });

      toast.success('Topic cree.');
      navigate(`/forum/${selectedCategory?.slug ?? categorySlugParam}/${topic.slug}`);
    } catch (createError) {
      console.error('Failed to create topic', createError);
      toast.error('Impossible de creer ce topic.');
    }
  };

  return (
    <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
      <div className="max-w-3xl mx-auto px-4 space-y-8">
        <div className="space-y-4">
          <Link to="/forum" className="inline-flex items-center gap-2 text-zinc-400 hover:text-white">
            <ChevronLeft className="h-4 w-4" />
            Retour au forum
          </Link>
          <div>
            <h1 className="text-3xl font-bold text-white">Creer un topic</h1>
            <p className="text-zinc-400">Lancez une nouvelle discussion dans la categorie adaptee.</p>
          </div>
        </div>

        <Card className="border-zinc-800">
          <CardHeader>
            <CardTitle>Nouveau topic</CardTitle>
            <CardDescription>Le premier message sera publie avec le topic.</CardDescription>
          </CardHeader>
          <CardContent>
            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label htmlFor="forum-category" className="block text-sm font-medium text-zinc-300 mb-1.5">
                  Categorie
                </label>
                <select
                  id="forum-category"
                  value={categoryId}
                  onChange={(event) => setCategoryId(event.target.value)}
                  disabled={isSubmitting || isLoading}
                  className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-2.5 text-white focus:border-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500/50"
                >
                  <option value="">Selectionner une categorie</option>
                  {categories.map((category) => (
                    <option key={category.id} value={category.id}>
                      {category.name}{category.is_premium_only ? ' • Premium' : ''}
                    </option>
                  ))}
                </select>
              </div>

              <Input
                label="Titre"
                value={title}
                onChange={(event) => setTitle(event.target.value)}
                placeholder="Ex: Comment organiser ses stems pour un client ?"
                disabled={isSubmitting}
              />

              <div>
                <label htmlFor="forum-topic-message" className="block text-sm font-medium text-zinc-300 mb-1.5">
                  Message
                </label>
                <textarea
                  id="forum-topic-message"
                  value={content}
                  onChange={(event) => setContent(event.target.value)}
                  disabled={isSubmitting}
                  rows={10}
                  className="w-full rounded-lg border border-zinc-700 bg-zinc-900 px-4 py-3 text-white placeholder-zinc-500 focus:border-rose-500 focus:outline-none focus:ring-2 focus:ring-rose-500/50"
                  placeholder="Detaillez clairement votre sujet, votre contexte et votre question."
                />
              </div>

              {error && (
                <p className="text-sm text-red-300">{error}</p>
              )}

              <div className="flex justify-end gap-3">
                <Link to="/forum">
                  <Button type="button" variant="ghost">
                    Annuler
                  </Button>
                </Link>
                <Button type="submit" isLoading={isSubmitting}>
                  Publier le topic
                </Button>
              </div>
            </form>
          </CardContent>
        </Card>
      </div>
    </div>
  );
}
