import { useEffect, useRef, useState, type ChangeEvent } from 'react';
import { useAuth } from '../lib/auth/hooks';
import { useTranslation } from '../lib/i18n';
import { updateProfile, updatePassword } from '../lib/auth/service';
import { supabase } from '../lib/supabase/client';
import { extractStoragePathFromCandidate } from '../lib/utils/storage';
import { Card } from '../components/ui/Card';
import { Input } from '../components/ui/Input';
import { Button } from '../components/ui/Button';
import { Select } from '../components/ui/Select';
import { User, Lock, Globe, Save, Camera, Instagram, Youtube, Cloud, Music2, Disc3 } from 'lucide-react';
import toast from 'react-hot-toast';

const AVATAR_BUCKET = import.meta.env.VITE_SUPABASE_AVATAR_BUCKET || 'avatars';
const MAX_AVATAR_SIZE = 2 * 1024 * 1024; // 2 MB
const MAX_SOCIAL_LINK_LENGTH = 255;

type SocialLinkKey = 'instagram' | 'youtube' | 'soundcloud' | 'tiktok' | 'spotify';

export function SettingsPage() {
  const { profile, refreshProfile } = useAuth();
  const { language, setLanguage } = useTranslation();
  const [activeTab, setActiveTab] = useState<'profile' | 'security' | 'preferences'>('profile');
  const avatarInputRef = useRef<HTMLInputElement>(null);

  const [profileData, setProfileData] = useState({
    username: profile?.username || '',
    full_name: profile?.full_name || '',
    bio: profile?.bio || '',
    website_url: profile?.website_url || '',
  });

  const [passwordData, setPasswordData] = useState({
    newPassword: '',
    confirmPassword: '',
  });

  const [isLoading, setIsLoading] = useState(false);
  const [isAvatarUploading, setIsAvatarUploading] = useState(false);
  const [avatarPreviewUrl, setAvatarPreviewUrl] = useState(profile?.avatar_url || '');
  const [avatarError, setAvatarError] = useState<string | null>(null);
  const [selectedAvatarFile, setSelectedAvatarFile] = useState<File | null>(null);
  const [localAvatarObjectUrl, setLocalAvatarObjectUrl] = useState<string | null>(null);
  const [socialLinksData, setSocialLinksData] = useState<Record<SocialLinkKey, string>>(() => {
    const links = profile?.social_links || {};
    return {
      instagram: typeof links.instagram === 'string' ? links.instagram : '',
      youtube: typeof links.youtube === 'string' ? links.youtube : '',
      soundcloud: typeof links.soundcloud === 'string' ? links.soundcloud : '',
      tiktok: typeof links.tiktok === 'string' ? links.tiktok : '',
      spotify: typeof links.spotify === 'string' ? links.spotify : '',
    };
  });

  useEffect(() => {
    if (!selectedAvatarFile) {
      setAvatarPreviewUrl(profile?.avatar_url || '');
    }
  }, [profile?.avatar_url, selectedAvatarFile]);

  useEffect(() => {
    const links = profile?.social_links || {};
    setSocialLinksData({
      instagram: typeof links.instagram === 'string' ? links.instagram : '',
      youtube: typeof links.youtube === 'string' ? links.youtube : '',
      soundcloud: typeof links.soundcloud === 'string' ? links.soundcloud : '',
      tiktok: typeof links.tiktok === 'string' ? links.tiktok : '',
      spotify: typeof links.spotify === 'string' ? links.spotify : '',
    });
  }, [profile?.id, profile?.social_links]);

  useEffect(() => {
    return () => {
      if (localAvatarObjectUrl) {
        URL.revokeObjectURL(localAvatarObjectUrl);
      }
    };
  }, [localAvatarObjectUrl]);

  const getAvatarExtension = (file: File) => {
    if (file.type === 'image/jpeg') return 'jpg';
    if (file.type === 'image/png') return 'png';
    if (file.type === 'image/webp') return 'webp';
    if (file.type === 'image/gif') return 'gif';
    const fileNameParts = file.name.split('.');
    const fromName = fileNameParts.length > 1 ? fileNameParts.pop() : null;
    return (fromName || 'jpg').toLowerCase();
  };

  const handleAvatarChange = (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = '';
    if (!file) return;

    if (!file.type.startsWith('image/')) {
      setAvatarError('Le fichier doit être une image.');
      toast.error('Le fichier doit être une image.');
      return;
    }

    if (file.size > MAX_AVATAR_SIZE) {
      setAvatarError('Image trop volumineuse (max 2 Mo).');
      toast.error('Image trop volumineuse (max 2 Mo).');
      return;
    }

    if (localAvatarObjectUrl) {
      URL.revokeObjectURL(localAvatarObjectUrl);
    }

    const previewUrl = URL.createObjectURL(file);
    setLocalAvatarObjectUrl(previewUrl);
    setSelectedAvatarFile(file);
    setAvatarPreviewUrl(previewUrl);
    setAvatarError(null);
  };

  const uploadAvatarAndGetUrl = async (file: File) => {
    if (!profile?.id) {
      throw new Error('Utilisateur non authentifié');
    }

    setIsAvatarUploading(true);
    setAvatarError(null);

    try {
      const previousAvatarPath = extractStoragePathFromCandidate(profile.avatar_url, AVATAR_BUCKET);
      if (previousAvatarPath) {
        const { error: removeError } = await supabase.storage
          .from(AVATAR_BUCKET)
          .remove([previousAvatarPath]);
        if (removeError) {
          console.warn('avatar remove warning', removeError);
        }
      }

      const extension = getAvatarExtension(file);
      const avatarPath = `${profile.id}/avatar.${extension}`;
      const { error: uploadError } = await supabase.storage
        .from(AVATAR_BUCKET)
        .upload(avatarPath, file, { upsert: true, cacheControl: '3600' });

      if (uploadError) throw uploadError;

      const { data: publicData } = supabase.storage
        .from(AVATAR_BUCKET)
        .getPublicUrl(avatarPath);

      if (!publicData?.publicUrl) {
        throw new Error('Impossible de récupérer l’URL de l’avatar.');
      }

      return publicData.publicUrl;
    } catch (error) {
      const message = error instanceof Error ? error.message : 'Erreur lors de l’upload de l’avatar';
      setAvatarError(message);
      throw error;
    } finally {
      setIsAvatarUploading(false);
    }
  };

  const normalizeSocialLink = (value: string, label: string) => {
    const trimmed = value.trim();
    if (!trimmed) return null;

    if (trimmed.toLowerCase().includes('javascript:')) {
      throw new Error(`Lien ${label} invalide.`);
    }

    const withProtocol = /^https?:\/\//i.test(trimmed) ? trimmed : `https://${trimmed}`;
    if (withProtocol.length > MAX_SOCIAL_LINK_LENGTH) {
      throw new Error(`Lien ${label} trop long (max ${MAX_SOCIAL_LINK_LENGTH} caractères).`);
    }

    return withProtocol;
  };

  const buildNormalizedSocialLinks = () => {
    return {
      instagram: normalizeSocialLink(socialLinksData.instagram, 'Instagram'),
      youtube: normalizeSocialLink(socialLinksData.youtube, 'YouTube'),
      soundcloud: normalizeSocialLink(socialLinksData.soundcloud, 'SoundCloud'),
      tiktok: normalizeSocialLink(socialLinksData.tiktok, 'TikTok'),
      spotify: normalizeSocialLink(socialLinksData.spotify, 'Spotify'),
    };
  };

  const handleProfileUpdate = async (e: React.FormEvent) => {
    e.preventDefault();
    setIsLoading(true);

    try {
      const normalizedSocialLinks = buildNormalizedSocialLinks();

      let avatarUrl = profile?.avatar_url || undefined;
      if (selectedAvatarFile) {
        avatarUrl = await uploadAvatarAndGetUrl(selectedAvatarFile);
      }

      await updateProfile({
        username: profileData.username,
        full_name: profileData.full_name,
        bio: profileData.bio,
        website_url: profileData.website_url,
        avatar_url: avatarUrl,
      });

      if (profile?.id) {
        const { error: socialLinksUpdateError } = await supabase
          .from('user_profiles')
          .update({ social_links: normalizedSocialLinks })
          .eq('id', profile.id);

        if (socialLinksUpdateError) {
          throw socialLinksUpdateError;
        }
      }

      await refreshProfile();
      if (localAvatarObjectUrl) {
        URL.revokeObjectURL(localAvatarObjectUrl);
        setLocalAvatarObjectUrl(null);
      }
      setSelectedAvatarFile(null);
      setAvatarError(null);
      setAvatarPreviewUrl(avatarUrl || '');
      setSocialLinksData({
        instagram: normalizedSocialLinks.instagram || '',
        youtube: normalizedSocialLinks.youtube || '',
        soundcloud: normalizedSocialLinks.soundcloud || '',
        tiktok: normalizedSocialLinks.tiktok || '',
        spotify: normalizedSocialLinks.spotify || '',
      });
      toast.success('Profil mis à jour avec succès');
    } catch (error) {
      console.error('Error updating profile', error);
      const message = error instanceof Error ? error.message : 'Erreur lors de la mise à jour du profil';
      toast.error(message);
    } finally {
      setIsLoading(false);
    }
  };

  const handlePasswordUpdate = async (e: React.FormEvent) => {
    e.preventDefault();

    if (passwordData.newPassword !== passwordData.confirmPassword) {
      toast.error('Les mots de passe ne correspondent pas');
      return;
    }

    if (passwordData.newPassword.length < 8) {
      toast.error('Le mot de passe doit contenir au moins 8 caractères');
      return;
    }

    setIsLoading(true);

    try {
      await updatePassword(passwordData.newPassword);
      toast.success('Mot de passe mis à jour avec succès');
      setPasswordData({ newPassword: '', confirmPassword: '' });
    } catch (error) {
      console.error('Error updating password', error);
      toast.error('Erreur lors de la mise à jour du mot de passe');
    } finally {
      setIsLoading(false);
    }
  };

  const handleLanguageChange = async (newLanguage: string) => {
    setLanguage(newLanguage as 'fr' | 'en' | 'de');
    try {
      await updateProfile({ language: newLanguage as 'fr' | 'en' | 'de' });
      toast.success('Langue mise à jour');
    } catch (error) {
      console.error('Error updating language', error);
      toast.error('Erreur lors de la mise à jour de la langue');
    }
  };

  const tabs = [
    { id: 'profile', label: 'Profil', icon: User },
    { id: 'security', label: 'Sécurité', icon: Lock },
    { id: 'preferences', label: 'Préférences', icon: Globe },
  ];

  return (
    <div className="pt-20 pb-12 px-4">
      <div className="max-w-4xl mx-auto">
        <div className="mb-8">
          <h1 className="text-3xl font-bold text-white mb-2">Paramètres</h1>
          <p className="text-zinc-400">Gérez vos informations et préférences</p>
        </div>

        <div className="flex gap-4 mb-6 border-b border-zinc-800">
          {tabs.map((tab) => (
            <button
              key={tab.id}
              onClick={() => setActiveTab(tab.id as typeof activeTab)}
              className={`flex items-center gap-2 px-4 py-3 border-b-2 transition-colors ${
                activeTab === tab.id
                  ? 'border-rose-500 text-white'
                  : 'border-transparent text-zinc-400 hover:text-white'
              }`}
            >
              <tab.icon className="w-4 h-4" />
              {tab.label}
            </button>
          ))}
        </div>

        {activeTab === 'profile' && (
          <Card className="p-6">
            <form onSubmit={handleProfileUpdate} className="space-y-6">
              <div>
                <h2 className="text-xl font-semibold text-white mb-4">
                  Informations du profil
                </h2>
                <div className="space-y-4">
                  <div className="rounded-xl border border-zinc-800 bg-zinc-900/50 p-4">
                    <p className="text-sm font-medium text-zinc-300 mb-3">Avatar</p>
                    <div className="flex items-center gap-4">
                      {avatarPreviewUrl ? (
                        <img
                          src={avatarPreviewUrl}
                          alt={profile?.username || 'Avatar'}
                          className="w-20 h-20 rounded-full object-cover border border-zinc-700"
                        />
                      ) : (
                        <div className="w-20 h-20 rounded-full bg-zinc-800 border border-zinc-700 flex items-center justify-center">
                          <User className="w-8 h-8 text-zinc-500" />
                        </div>
                      )}
                      <div className="space-y-2">
                        <input
                          ref={avatarInputRef}
                          type="file"
                          accept="image/*"
                          className="hidden"
                          onChange={handleAvatarChange}
                        />
                        <Button
                          type="button"
                          variant="secondary"
                          onClick={() => avatarInputRef.current?.click()}
                          disabled={isLoading || isAvatarUploading}
                          className="flex items-center gap-2"
                        >
                          <Camera className="w-4 h-4" />
                          Changer l’avatar
                        </Button>
                        <p className="text-xs text-zinc-500">Formats image • max 2 Mo</p>
                        {avatarError && (
                          <p className="text-xs text-red-400">{avatarError}</p>
                        )}
                      </div>
                    </div>
                  </div>

                  <Input
                    type="text"
                    label="Nom d'utilisateur"
                    value={profileData.username}
                    onChange={(e) =>
                      setProfileData({ ...profileData, username: e.target.value })
                    }
                    leftIcon={<User className="w-5 h-5" />}
                    required
                  />
                  <Input
                    type="text"
                    label="Nom complet"
                    value={profileData.full_name}
                    onChange={(e) =>
                      setProfileData({ ...profileData, full_name: e.target.value })
                    }
                  />
                  <div>
                    <label className="block text-sm font-medium text-zinc-300 mb-2">
                      Bio
                    </label>
                    <textarea
                      value={profileData.bio}
                      onChange={(e) =>
                        setProfileData({ ...profileData, bio: e.target.value })
                      }
                      rows={4}
                      className="w-full px-4 py-3 bg-zinc-800 border border-zinc-700 rounded-lg text-white placeholder-zinc-500 focus:outline-none focus:border-rose-500 transition-colors"
                      placeholder="Parlez-nous de vous..."
                    />
                  </div>
                  <div>
                    <p className="text-sm font-medium text-zinc-300 mb-2">Réseaux sociaux</p>
                    <div className="grid grid-cols-1 md:grid-cols-2 gap-3">
                      <Input
                        type="text"
                        label="Instagram"
                        value={socialLinksData.instagram}
                        onChange={(e) =>
                          setSocialLinksData({ ...socialLinksData, instagram: e.target.value })
                        }
                        placeholder="https://instagram.com/votrecompte"
                        leftIcon={<Instagram className="w-4 h-4" />}
                        maxLength={MAX_SOCIAL_LINK_LENGTH}
                      />
                      <Input
                        type="text"
                        label="YouTube"
                        value={socialLinksData.youtube}
                        onChange={(e) =>
                          setSocialLinksData({ ...socialLinksData, youtube: e.target.value })
                        }
                        placeholder="https://youtube.com/@votrechaine"
                        leftIcon={<Youtube className="w-4 h-4" />}
                        maxLength={MAX_SOCIAL_LINK_LENGTH}
                      />
                      <Input
                        type="text"
                        label="SoundCloud"
                        value={socialLinksData.soundcloud}
                        onChange={(e) =>
                          setSocialLinksData({ ...socialLinksData, soundcloud: e.target.value })
                        }
                        placeholder="https://soundcloud.com/votrecompte"
                        leftIcon={<Cloud className="w-4 h-4" />}
                        maxLength={MAX_SOCIAL_LINK_LENGTH}
                      />
                      <Input
                        type="text"
                        label="TikTok"
                        value={socialLinksData.tiktok}
                        onChange={(e) =>
                          setSocialLinksData({ ...socialLinksData, tiktok: e.target.value })
                        }
                        placeholder="https://www.tiktok.com/@votrecompte"
                        leftIcon={<Music2 className="w-4 h-4" />}
                        maxLength={MAX_SOCIAL_LINK_LENGTH}
                      />
                      <Input
                        type="text"
                        label="Spotify"
                        value={socialLinksData.spotify}
                        onChange={(e) =>
                          setSocialLinksData({ ...socialLinksData, spotify: e.target.value })
                        }
                        placeholder="https://open.spotify.com/artist/..."
                        leftIcon={<Disc3 className="w-4 h-4" />}
                        maxLength={MAX_SOCIAL_LINK_LENGTH}
                      />
                    </div>
                  </div>
                  <Input
                    type="url"
                    label="Site web"
                    value={profileData.website_url}
                    onChange={(e) =>
                      setProfileData({ ...profileData, website_url: e.target.value })
                    }
                    placeholder="https://example.com"
                  />
                </div>
              </div>

              <Button type="submit" isLoading={isLoading || isAvatarUploading} className="flex items-center gap-2">
                <Save className="w-4 h-4" />
                Enregistrer les modifications
              </Button>
            </form>
          </Card>
        )}

        {activeTab === 'security' && (
          <Card className="p-6">
            <form onSubmit={handlePasswordUpdate} className="space-y-6">
              <div>
                <h2 className="text-xl font-semibold text-white mb-4">
                  Changer le mot de passe
                </h2>
                <div className="space-y-4">
                  <Input
                    type="password"
                    label="Nouveau mot de passe"
                    value={passwordData.newPassword}
                    onChange={(e) =>
                      setPasswordData({ ...passwordData, newPassword: e.target.value })
                    }
                    leftIcon={<Lock className="w-5 h-5" />}
                    placeholder="••••••••"
                    required
                  />
                  <Input
                    type="password"
                    label="Confirmer le mot de passe"
                    value={passwordData.confirmPassword}
                    onChange={(e) =>
                      setPasswordData({ ...passwordData, confirmPassword: e.target.value })
                    }
                    leftIcon={<Lock className="w-5 h-5" />}
                    placeholder="••••••••"
                    required
                  />
                </div>
              </div>

              <Button type="submit" isLoading={isLoading} className="flex items-center gap-2">
                <Save className="w-4 h-4" />
                Mettre à jour le mot de passe
              </Button>
            </form>
          </Card>
        )}

        {activeTab === 'preferences' && (
          <Card className="p-6">
            <div className="space-y-6">
              <div>
                <h2 className="text-xl font-semibold text-white mb-4">
                  Préférences de langue
                </h2>
                <Select
                  label="Langue de l'interface"
                  value={language}
                  onChange={(e) => handleLanguageChange(e.target.value)}
                  options={[
                    { value: 'fr', label: 'Français' },
                    { value: 'en', label: 'English' },
                    { value: 'de', label: 'Deutsch' },
                  ]}
                />
              </div>
            </div>
          </Card>
        )}
      </div>
    </div>
  );
}
