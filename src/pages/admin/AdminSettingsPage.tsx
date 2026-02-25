import { useEffect, useState } from 'react';
import toast from 'react-hot-toast';
import { Card } from '../../components/ui/Card';
import { Input } from '../../components/ui/Input';
import { Button } from '../../components/ui/Button';
import { supabase } from '../../lib/supabase/client';

const SOCIAL_SETTINGS_KEY = 'social_links';

interface SocialLinksForm {
  twitter: string;
  instagram: string;
  youtube: string;
}

const EMPTY_FORM: SocialLinksForm = {
  twitter: '',
  instagram: '',
  youtube: '',
};

const HTTP_URL_REGEX = /^https?:\/\//i;

const sanitizeUrl = (value: unknown) => {
  if (typeof value !== 'string') return '';
  const trimmed = value.trim();
  return HTTP_URL_REGEX.test(trimmed) ? trimmed : '';
};

const isAllowedUrl = (value: string) => value.length === 0 || HTTP_URL_REGEX.test(value);

export function AdminSettingsPage() {
  const [form, setForm] = useState<SocialLinksForm>(EMPTY_FORM);
  const [isLoading, setIsLoading] = useState(true);
  const [isSaving, setIsSaving] = useState(false);

  useEffect(() => {
    const loadSocialLinks = async () => {
      setIsLoading(true);
      const { data, error } = await supabase
        .from('app_settings')
        .select('value')
        .eq('key', SOCIAL_SETTINGS_KEY)
        .maybeSingle();

      if (error) {
        console.error('admin social settings load error', error);
        toast.error('Impossible de charger les liens sociaux.');
        setIsLoading(false);
        return;
      }

      const payload = data?.value;
      const parsed = (payload && typeof payload === 'object' ? payload : {}) as Record<string, unknown>;
      setForm({
        twitter: sanitizeUrl(parsed.twitter),
        instagram: sanitizeUrl(parsed.instagram),
        youtube: sanitizeUrl(parsed.youtube),
      });
      setIsLoading(false);
    };

    void loadSocialLinks();
  }, []);

  const handleSave = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault();
    if (isSaving) return;

    const nextForm: SocialLinksForm = {
      twitter: form.twitter.trim(),
      instagram: form.instagram.trim(),
      youtube: form.youtube.trim(),
    };

    if (!isAllowedUrl(nextForm.twitter) || !isAllowedUrl(nextForm.instagram) || !isAllowedUrl(nextForm.youtube)) {
      toast.error('Utilisez uniquement des URLs http(s).');
      return;
    }

    setIsSaving(true);
    const { error } = await supabase
      .from('app_settings')
      .upsert(
        {
          key: SOCIAL_SETTINGS_KEY,
          value: nextForm,
          updated_at: new Date().toISOString(),
        },
        { onConflict: 'key' },
      );

    if (error) {
      console.error('admin social settings save error', error);
      toast.error('Impossible d’enregistrer les liens sociaux.');
      setIsSaving(false);
      return;
    }

    setForm(nextForm);
    toast.success('Liens sociaux mis à jour.');
    setIsSaving(false);
  };

  return (
    <Card className="p-6 border-zinc-800">
      <h2 className="text-xl font-semibold text-white">Paramètres sociaux</h2>
      <p className="text-zinc-400 text-sm mt-1">
        Configurez les liens Twitter, Instagram et YouTube affichés dans le footer.
      </p>

      <form onSubmit={handleSave} className="mt-6 space-y-4">
        <Input
          type="url"
          label="Twitter URL"
          value={form.twitter}
          onChange={(event) => setForm((prev) => ({ ...prev, twitter: event.target.value }))}
          placeholder="https://twitter.com/..."
          disabled={isLoading || isSaving}
        />
        <Input
          type="url"
          label="Instagram URL"
          value={form.instagram}
          onChange={(event) => setForm((prev) => ({ ...prev, instagram: event.target.value }))}
          placeholder="https://instagram.com/..."
          disabled={isLoading || isSaving}
        />
        <Input
          type="url"
          label="YouTube URL"
          value={form.youtube}
          onChange={(event) => setForm((prev) => ({ ...prev, youtube: event.target.value }))}
          placeholder="https://youtube.com/@..."
          disabled={isLoading || isSaving}
        />

        <div className="pt-2">
          <Button type="submit" isLoading={isLoading || isSaving}>
            Enregistrer
          </Button>
        </div>
      </form>
    </Card>
  );
}
