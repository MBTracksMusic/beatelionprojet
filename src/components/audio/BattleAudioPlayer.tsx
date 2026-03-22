import { type ChangeEvent } from 'react';
import { Pause, Play } from 'lucide-react';
import { useAudioPlayer } from '../../context/AudioPlayerContext';
import { useTranslation } from '../../lib/i18n';

const formatTime = (value: number) => {
  const safeValue = Number.isFinite(value) && value > 0 ? value : 0;
  const minutes = Math.floor(safeValue / 60);
  const seconds = Math.floor(safeValue % 60);
  return `${minutes}:${seconds.toString().padStart(2, '0')}`;
};

interface BattleAudioPlayerProps {
  productId?: string | null | undefined;
  src: string | null | undefined;
  label?: string;
}

export function BattleAudioPlayer({ productId, src, label }: BattleAudioPlayerProps) {
  const { t } = useTranslation();
  const { currentTrack, isPlaying, currentTime, duration, playTrack, seekTo } = useAudioPlayer();

  const trimmedSrc = src?.trim() ?? '';
  const trackId = productId ?? trimmedSrc;
  const canPlay = Boolean(trackId) && Boolean(trimmedSrc);
  const isCurrentTrack = currentTrack?.id === trackId;
  const isPlayingCurrent = isCurrentTrack && isPlaying;
  const displayedCurrentTime = isCurrentTrack ? currentTime : 0;
  const displayedDuration = isCurrentTrack ? duration : 0;

  const handleTogglePlay = () => {
    if (!canPlay || !trackId) {
      return;
    }

    playTrack({
      id: trackId,
      title: label || t('audio.excerptLabel'),
      audioUrl: trimmedSrc,
    });
  };

  const handleSeek = (event: ChangeEvent<HTMLInputElement>) => {
    if (!isCurrentTrack) {
      return;
    }

    const nextValue = Number.parseFloat(event.target.value);
    if (!Number.isFinite(nextValue)) {
      return;
    }

    seekTo(nextValue);
  };

  return (
    <div className="space-y-2">
      <div className="flex flex-col gap-3 sm:flex-row sm:items-center">
        <button
          type="button"
          onClick={handleTogglePlay}
          disabled={!canPlay}
          className="inline-flex h-9 w-9 items-center justify-center rounded-full bg-white text-zinc-900 transition hover:scale-105 disabled:cursor-not-allowed disabled:opacity-60"
          aria-label={isPlayingCurrent ? t('audio.pausePreview') : t('audio.playPreview')}
        >
          {isPlayingCurrent ? (
            <Pause className="h-4 w-4" fill="currentColor" />
          ) : (
            <Play className="h-4 w-4 ml-0.5" fill="currentColor" />
          )}
        </button>

        <div className="flex-1">
          <p className="mb-1 text-xs text-zinc-500">{label || t('audio.excerptLabel')}</p>
          <div className="flex items-center gap-2">
            <input
              type="range"
              min={0}
              max={displayedDuration > 0 ? displayedDuration : 0}
              step={0.1}
              value={displayedDuration > 0 ? Math.min(displayedCurrentTime, displayedDuration) : 0}
              onChange={handleSeek}
              disabled={!isCurrentTrack || displayedDuration <= 0}
              className="h-1 w-full cursor-pointer accent-rose-500 disabled:cursor-not-allowed"
            />
            <span className="whitespace-nowrap text-[11px] text-zinc-500 tabular-nums">
              {formatTime(displayedCurrentTime)} / {formatTime(displayedDuration)}
            </span>
          </div>
        </div>
      </div>

      {!canPlay && <p className="text-xs text-zinc-500">{t('audio.previewUnavailable')}</p>}
    </div>
  );
}
