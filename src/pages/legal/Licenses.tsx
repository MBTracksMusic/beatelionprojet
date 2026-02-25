import { useEffect } from 'react';

const PAGE_TITLE = 'Licence Standard – LevelUpMusic';
const PAGE_DESCRIPTION = 'Conditions de la Licence Standard pour les beats achetés sur LevelUpMusic.';

export function Licenses() {
  useEffect(() => {
    const previousTitle = document.title;
    document.title = PAGE_TITLE;

    const existingMeta = document.querySelector('meta[name="description"]');
    const previousDescription = existingMeta?.getAttribute('content') ?? null;
    let meta = existingMeta as HTMLMetaElement | null;
    let metaCreated = false;

    if (!meta) {
      meta = document.createElement('meta');
      meta.setAttribute('name', 'description');
      document.head.appendChild(meta);
      metaCreated = true;
    }

    meta.setAttribute('content', PAGE_DESCRIPTION);

    return () => {
      document.title = previousTitle;

      if (!meta) return;

      if (metaCreated) {
        meta.remove();
        return;
      }

      if (previousDescription === null) {
        meta.removeAttribute('content');
      } else {
        meta.setAttribute('content', previousDescription);
      }
    };
  }, []);

  return (
    <div className="min-h-screen bg-zinc-950 pt-8 pb-32">
      <div className="max-w-4xl mx-auto px-4 space-y-8">
        <div className="space-y-3">
          <h1 className="text-3xl font-bold text-white">Licence Standard</h1>
          <p className="text-zinc-400">
            Conditions d&apos;utilisation de la Licence Standard pour les beats achetes sur LevelUpMusic.
          </p>
        </div>

        <section className="space-y-3">
          <h2 className="text-2xl font-semibold text-white">1. Objet de la licence</h2>
          <p className="text-zinc-400">
            La Licence Standard accorde un droit non exclusif d&apos;utilisation du beat pour des projets personnels et
            commerciaux dans les limites prevues ci-dessous.
          </p>
        </section>

        <section className="space-y-3">
          <h2 className="text-2xl font-semibold text-white">2. Usage autorise</h2>
          <p className="text-zinc-400">
            L&apos;acheteur peut enregistrer, diffuser et monnayer son titre integre au beat, selon les plafonds de
            streams, ventes ou exploitations indiques au moment de l&apos;achat.
          </p>
        </section>

        <section className="space-y-3">
          <h2 className="text-2xl font-semibold text-white">3. Usage interdit</h2>
          <p className="text-zinc-400">
            La revente du beat seul, la redistribution des stems ou du master, et toute revendication de propriete
            integrale sur la composition originale du producteur sont interdites.
          </p>
        </section>

        <section className="space-y-3">
          <h2 className="text-2xl font-semibold text-white">4. Credit producteur</h2>
          <p className="text-zinc-400">
            L&apos;acheteur doit mentionner le producteur conformement aux obligations de credit associees a la licence
            choisie.
          </p>
        </section>

        <section className="space-y-3">
          <h2 className="text-2xl font-semibold text-white">5. Contrat et preuve d&apos;achat</h2>
          <p className="text-zinc-400">
            Chaque achat valide est associe a un contrat de licence telechargeable depuis l&apos;espace utilisateur, qui
            fait foi entre les parties.
          </p>
        </section>

        <section className="space-y-3">
          <h2 className="text-2xl font-semibold text-white">6. Limitation et evolution</h2>
          <p className="text-zinc-400">
            En cas de depassement des plafonds ou de besoin d&apos;usage etendu, une extension ou une licence superieure
            peut etre requise. Les conditions peuvent etre mises a jour pour les futurs achats.
          </p>
        </section>
      </div>
    </div>
  );
}
