import { useEffect, useState } from 'react';
import { Pause, Play, RotateCcw, SkipBack, SkipForward } from 'lucide-react';
import { useAudioPlayer } from '../../context/AudioPlayerContext';

function formatTime(time: number) {
  const minutes = Math.floor(time / 60);
  const seconds = Math.floor(time % 60);
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
}

export function GlobalAudioPlayer() {
  const {
    currentTrack,
    isPlaying,
    progress,
    currentTime,
    duration,
    canPlayNext,
    canPlayPrevious,
    togglePlay,
    playNext,
    playPrevious,
    seekTo,
  } = useAudioPlayer();
  const [isChangingTrack, setIsChangingTrack] = useState(false);
  const isFinished = progress >= 100 && !isPlaying;

  useEffect(() => {
    if (!currentTrack) return;

    setIsChangingTrack(true);

    const timeout = setTimeout(() => {
      setIsChangingTrack(false);
    }, 200);

    return () => clearTimeout(timeout);
  }, [currentTrack?.id]);

  if (!currentTrack) {
    return null;
  }

  return (
    <div
      className={`fixed bottom-0 left-0 right-0 z-50 border-t border-zinc-800 bg-black/90 backdrop-blur-md transition-all duration-200 ${
        isChangingTrack ? 'scale-[0.98] opacity-70' : 'scale-100 opacity-100'
      } ${isFinished ? 'border-rose-500/30 opacity-80' : ''}`}
    >
      <div
        className={`h-1 w-full bg-zinc-800 transition-all hover:h-1.5 ${
          isFinished ? 'cursor-default' : 'cursor-pointer'
        }`}
        onClick={(e) => {
          if (!duration || isFinished) return;
          const rect = e.currentTarget.getBoundingClientRect();
          let percent = (e.clientX - rect.left) / rect.width;
          percent = Math.max(0, Math.min(percent, 1));
          const newTime = percent * duration;
          seekTo(newTime);
        }}
      >
        <div
          className="h-full bg-rose-500 transition-all duration-150"
          style={{ width: `${progress}%` }}
        />
      </div>

      <div className="flex items-center justify-between gap-4 px-4 py-3">
        <div className="min-w-0 flex-1">
          <div className="flex items-center gap-3">
            {currentTrack.cover_image_url && (
              <img
                src={currentTrack.cover_image_url}
                alt={currentTrack.title}
                className="h-10 w-10 rounded object-cover"
              />
            )}

            <p className="truncate text-sm font-medium text-white">
              {currentTrack.title}
            </p>
          </div>

          <div className="mt-1 flex justify-between text-xs text-zinc-400">
            <span>{formatTime(currentTime)}</span>
            <span>{formatTime(duration)}</span>
          </div>
        </div>

        <div className="flex items-center gap-2">
          <button
            type="button"
            onClick={playPrevious}
            disabled={!canPlayPrevious}
            className="flex h-10 w-10 items-center justify-center rounded-full border border-zinc-700 text-zinc-300 transition hover:border-zinc-500 hover:text-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            <SkipBack className="h-4 w-4" />
          </button>
          <button
            type="button"
            onClick={() => {
              if (isFinished) {
                seekTo(0);
              }
              togglePlay();
            }}
            className="flex h-10 w-10 items-center justify-center rounded-full border border-rose-500/40 text-rose-400 transition hover:bg-rose-500 hover:text-black"
          >
            {isFinished ? (
              <RotateCcw className="h-5 w-5" />
            ) : isPlaying ? (
              <Pause className="h-5 w-5" />
            ) : (
              <Play className="h-5 w-5" />
            )}
          </button>
          <button
            type="button"
            onClick={playNext}
            disabled={!canPlayNext}
            className="flex h-10 w-10 items-center justify-center rounded-full border border-zinc-700 text-zinc-300 transition hover:border-zinc-500 hover:text-white disabled:cursor-not-allowed disabled:opacity-40"
          >
            <SkipForward className="h-4 w-4" />
          </button>
        </div>
      </div>
    </div>
  );
}
