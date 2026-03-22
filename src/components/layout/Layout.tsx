import { type ReactNode } from 'react';
import { Outlet } from 'react-router-dom';
import { Header } from './Header';
import { Footer } from './Footer';
import { AudioPlayer } from '../audio/AudioPlayer';
import { usePlayerStore } from '../../lib/stores/player';

interface LayoutProps {
  children?: ReactNode;
  hidePlayer?: boolean;
}

export function Layout({ children, hidePlayer }: LayoutProps) {
  const { currentTrack, playNext, playPrevious } = usePlayerStore();

  return (
    <div className="min-h-screen bg-zinc-950 text-white flex flex-col">
      <Header />
      <main className="flex-1 pt-16 pb-20">{children ?? <Outlet />}</main>
      <Footer />
      {!hidePlayer && (
        <AudioPlayer
          track={currentTrack}
          onNext={playNext}
          onPrevious={playPrevious}
        />
      )}
    </div>
  );
}
