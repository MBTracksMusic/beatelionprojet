import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';
import { trackBeatComplete, trackBeatPause, trackBeatPlay } from '../lib/analytics';
import { buildResolvedAudioSourceCandidates, type AudioSourceFields } from '../lib/audio/sources';
import { supabase } from '../lib/supabase/client';
import { isTrackableBeatId, trackInteraction } from '../lib/tracking';

export type Track = AudioSourceFields & {
  id: string;
  title: string;
  audioUrl: string;
  cover_image_url?: string | null;
  producerId?: string;
};

const VOLUME_STORAGE_KEY = 'beatelion:player-volume';
const MUTED_STORAGE_KEY = 'beatelion:player-muted';

const clampVolume = (value: number) => Math.max(0, Math.min(1, value));

const readStoredVolume = (): number => {
  if (typeof window === 'undefined') return 1;
  try {
    const raw = window.localStorage.getItem(VOLUME_STORAGE_KEY);
    if (raw === null) return 1;
    const parsed = Number.parseFloat(raw);
    return Number.isFinite(parsed) ? clampVolume(parsed) : 1;
  } catch {
    return 1; // localStorage bloqué (private mode strict, etc.)
  }
};

const readStoredMuted = (): boolean => {
  if (typeof window === 'undefined') return false;
  try {
    return window.localStorage.getItem(MUTED_STORAGE_KEY) === '1';
  } catch {
    return false;
  }
};

type AudioPlayerContextType = {
  currentTrack: Track | null;
  isPlaying: boolean;
  progress: number;
  currentTime: number;
  duration: number;
  queue: Track[];
  currentIndex: number;
  canPlayNext: boolean;
  canPlayPrevious: boolean;
  volume: number;
  isMuted: boolean;
  playTrack: (track: Track) => void;
  playQueue: (tracks: Track[], startIndex?: number) => void;
  togglePlay: () => void;
  seekTo: (time: number) => void;
  playNext: () => void;
  playPrevious: () => void;
  setVolume: (next: number) => void;
  toggleMute: () => void;
};

const AudioPlayerContext = createContext<AudioPlayerContextType | null>(null);

export function AudioPlayerProvider({ children }: { children: ReactNode }) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const fadeIntervalRef = useRef<number | null>(null);
  const currentTrackRef = useRef<Track | null>(null);
  const currentTimeRef = useRef(0);
  const durationRef = useRef(0);
  const playbackRequestIdRef = useRef(0);
  const sourceCandidatesRef = useRef<string[]>([]);
  const sourceCandidateIndexRef = useRef(0);
  const handledFailureKeyRef = useRef<string | null>(null);
  const [currentTrack, setCurrentTrack] = useState<Track | null>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [progress, setProgress] = useState(0);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [queue, setQueue] = useState<Track[]>([]);
  const [currentIndex, setCurrentIndex] = useState(-1);
  const [volume, setVolumeState] = useState<number>(() => readStoredVolume());
  const [isMuted, setIsMutedState] = useState<boolean>(() => readStoredMuted());
  const queueRef = useRef<Track[]>([]);
  const currentIndexRef = useRef(-1);
  const volumeRef = useRef(volume);
  const isMutedRef = useRef(isMuted);

  // Volume effectivement appliqué à l'élément <audio> : 0 si muet, sinon le volume choisi.
  const getEffectiveVolume = () => (isMutedRef.current ? 0 : volumeRef.current);

  useEffect(() => {
    queueRef.current = queue;
  }, [queue]);

  useEffect(() => {
    volumeRef.current = volume;
  }, [volume]);

  useEffect(() => {
    isMutedRef.current = isMuted;
  }, [isMuted]);

  // Applique le volume à l'audio en cours (sauf pendant un fondu) et le persiste.
  useEffect(() => {
    if (audioRef.current && fadeIntervalRef.current === null) {
      audioRef.current.volume = isMuted ? 0 : volume;
    }
    try {
      window.localStorage.setItem(VOLUME_STORAGE_KEY, String(volume));
      window.localStorage.setItem(MUTED_STORAGE_KEY, isMuted ? '1' : '0');
    } catch {
      /* localStorage bloqué (private mode strict, etc.) */
    }
  }, [volume, isMuted]);

  useEffect(() => {
    currentIndexRef.current = currentIndex;
  }, [currentIndex]);

  useEffect(() => {
    currentTrackRef.current = currentTrack;
  }, [currentTrack]);

  useEffect(() => {
    currentTimeRef.current = currentTime;
  }, [currentTime]);

  useEffect(() => {
    durationRef.current = duration;
  }, [duration]);

  useEffect(() => {
    return () => {
      if (fadeIntervalRef.current !== null) {
        window.clearInterval(fadeIntervalRef.current);
      }
      audioRef.current?.pause();
      audioRef.current = null;
    };
  }, []);

  const resetPlayerState = () => {
    queueRef.current = [];
    currentIndexRef.current = -1;
    currentTrackRef.current = null;
    currentTimeRef.current = 0;
    durationRef.current = 0;
    sourceCandidatesRef.current = [];
    sourceCandidateIndexRef.current = 0;
    handledFailureKeyRef.current = null;
    setQueue([]);
    setIsPlaying(false);
    setCurrentTrack(null);
    setCurrentTime(0);
    setDuration(0);
    setProgress(0);
    setCurrentIndex(-1);
  };

  const setVolume = (next: number) => {
    const clamped = clampVolume(next);
    setVolumeState(clamped);
    // Remonter le curseur au-dessus de 0 rétablit automatiquement le son.
    if (clamped > 0 && isMutedRef.current) {
      setIsMutedState(false);
    }
  };

  const toggleMute = () => {
    setIsMutedState((prev) => !prev);
  };

  const ensureAudio = () => {
    if (!audioRef.current) {
      audioRef.current = new Audio();
      audioRef.current.volume = getEffectiveVolume();
      audioRef.current.ontimeupdate = () => {
        if (!audioRef.current) return;
        const current = audioRef.current.currentTime;
        const total = Number.isFinite(audioRef.current.duration)
          ? audioRef.current.duration
          : 0;
        const rawProgress = total > 0 ? (current / total) * 100 : 0;
        currentTimeRef.current = current;
        durationRef.current = total;
        setCurrentTime(current);
        setDuration(total);
        setProgress(Math.min(rawProgress, 100));
      };
      audioRef.current.onloadedmetadata = () => {
        if (!audioRef.current) return;
        const total = Number.isFinite(audioRef.current.duration)
          ? audioRef.current.duration
          : 0;
        durationRef.current = total;
        setDuration(total);
      };
      audioRef.current.onended = () => {
        const finishedTrack = currentTrackRef.current;
        const finishedDuration = Math.max(
          0,
          Math.round(durationRef.current || audioRef.current?.duration || currentTimeRef.current || 0),
        );

        if (finishedTrack && isTrackableBeatId(finishedTrack.id)) {
          trackBeatComplete(finishedTrack.id);
          void trackInteraction({
            beatId: finishedTrack.id,
            action: 'complete',
            duration: finishedDuration,
          });
        }

        const nextIndex = currentIndexRef.current + 1;
        if (nextIndex < queueRef.current.length) {
          const nextTrack = queueRef.current[nextIndex] ?? null;
          if (nextTrack) {
            playAudioTrack(nextTrack, nextIndex);
            return;
          }
        }

        setIsPlaying(false);
        setQueue([]);
        queueRef.current = [];
        setCurrentIndex(-1);
        currentIndexRef.current = -1;
      };
      audioRef.current.onerror = () => {
        const activeTrack = currentTrackRef.current;
        if (!activeTrack) {
          setIsPlaying(false);
          return;
        }

        const failureKey = `${playbackRequestIdRef.current}:${sourceCandidateIndexRef.current}`;
        if (handledFailureKeyRef.current === failureKey) {
          return;
        }
        handledFailureKeyRef.current = failureKey;

        const nextIndex = sourceCandidateIndexRef.current + 1;
        const nextCandidate = sourceCandidatesRef.current[nextIndex];
        if (!nextCandidate) {
          setIsPlaying(false);
          return;
        }

        tryPlayResolvedSource(activeTrack, nextIndex, playbackRequestIdRef.current);
      };
    }
    return audioRef.current;
  };

  const clearFadeInterval = () => {
    if (fadeIntervalRef.current !== null) {
      window.clearInterval(fadeIntervalRef.current);
      fadeIntervalRef.current = null;
    }
  };

  const fadeOutAndPause = () => {
    const audio = audioRef.current;
    if (!audio) {
      return;
    }

    clearFadeInterval();

    // Volume à restaurer après la pause (le volume choisi par l'utilisateur).
    const targetVolume = getEffectiveVolume();
    const startingVolume = audio.volume;

    // Déjà silencieux : pause immédiate, sans fondu (sinon l'audio ne se mettrait jamais en pause).
    if (startingVolume <= 0) {
      audio.pause();
      audio.volume = targetVolume;
      return;
    }

    const steps = 5;
    const intervalTime = 20;
    const volumeStep = startingVolume / steps;
    let currentStep = 0;

    fadeIntervalRef.current = window.setInterval(() => {
      audio.volume = Math.max(0, audio.volume - volumeStep);
      currentStep += 1;

      if (currentStep >= steps) {
        clearFadeInterval();
        audio.pause();
        audio.volume = targetVolume;
      }
    }, intervalTime);
  };

  const reportBeatPlay = (track: Track) => {
    if (!isTrackableBeatId(track.id)) {
      return;
    }

    trackBeatPlay({
      beatId: track.id,
      title: track.title,
      producerId: track.producerId,
    });
    void trackInteraction({
      beatId: track.id,
      action: 'play',
    });
    // 42501 = auth_required: anonymous listeners are skipped by design (anti-bot).
    void supabase
      .rpc('increment_play_count', { p_product_id: track.id })
      .then(({ error }) => {
        if (error && error.code !== '42501') {
          console.error('increment_play_count failed', error);
        }
      });
  };

  const reportBeatPause = (track: Track | null) => {
    if (!track || !isTrackableBeatId(track.id)) {
      return;
    }

    trackBeatPause(track.id);
    void trackInteraction({
      beatId: track.id,
      action: 'pause',
      duration: currentTimeRef.current,
    });
  };

  const shouldRetryTrackResolution = (audio: HTMLAudioElement) =>
    !audio.currentSrc || audio.error !== null || (currentTimeRef.current === 0 && durationRef.current === 0);

  const tryPlayResolvedSource = (track: Track, candidateIndex: number, requestId: number) => {
    const audio = ensureAudio();
    if (!audio) {
      return;
    }

    const candidateUrl = sourceCandidatesRef.current[candidateIndex];
    if (!candidateUrl) {
      setIsPlaying(false);
      return;
    }

    sourceCandidateIndexRef.current = candidateIndex;
    handledFailureKeyRef.current = null;
    clearFadeInterval();
    audio.pause();
    audio.volume = getEffectiveVolume();
    audio.src = candidateUrl;
    audio.preload = 'auto';
    audio.currentTime = 0;
    void audio.play().then(() => {
      if (requestId !== playbackRequestIdRef.current || candidateIndex !== sourceCandidateIndexRef.current) {
        return;
      }

      setIsPlaying(true);
      reportBeatPlay(track);
    }).catch((error: unknown) => {
      if (requestId !== playbackRequestIdRef.current || candidateIndex !== sourceCandidateIndexRef.current) {
        return;
      }

      if (error instanceof DOMException && error.name === 'NotAllowedError') {
        setIsPlaying(false);
        return;
      }

      const failureKey = `${requestId}:${candidateIndex}`;
      if (handledFailureKeyRef.current === failureKey) {
        return;
      }
      handledFailureKeyRef.current = failureKey;

      const nextIndex = candidateIndex + 1;
      if (!sourceCandidatesRef.current[nextIndex]) {
        setIsPlaying(false);
        return;
      }

      tryPlayResolvedSource(track, nextIndex, requestId);
    });
  };

  const playAudioTrack = (track: Track, index?: number) => {
    const resolvedCandidates = buildResolvedAudioSourceCandidates(track);
    if (resolvedCandidates.length === 0) {
      return;
    }

    const audio = ensureAudio();
    if (!audio) {
      return;
    }

    if (typeof index === 'number') {
      currentIndexRef.current = index;
      setCurrentIndex(index);
    }
    const requestId = playbackRequestIdRef.current + 1;
    playbackRequestIdRef.current = requestId;
    sourceCandidatesRef.current = resolvedCandidates;
    sourceCandidateIndexRef.current = 0;
    handledFailureKeyRef.current = null;
    currentTrackRef.current = track;
    currentTimeRef.current = 0;
    durationRef.current = 0;
    setCurrentTime(0);
    setDuration(0);
    setProgress(0);
    setCurrentTrack(track);
    tryPlayResolvedSource(track, 0, requestId);
  };

  const playTrack = (track: Track) => {
    if (!track.audioUrl) {
      return;
    }

    const audio = ensureAudio();
    if (!audio) {
      return;
    }

    if (currentTrack?.id === track.id) {
      if (isPlaying) {
        reportBeatPause(currentTrackRef.current);
        fadeOutAndPause();
        setIsPlaying(false);
      } else {
        if (shouldRetryTrackResolution(audio)) {
          playAudioTrack(track, currentIndexRef.current >= 0 ? currentIndexRef.current : undefined);
          return;
        }

        clearFadeInterval();
        audio.volume = getEffectiveVolume();
        void audio.play().then(() => {
          setIsPlaying(true);
          if (currentTrackRef.current) {
            reportBeatPlay(currentTrackRef.current);
          }
        }).catch(() => {
          setIsPlaying(false);
        });
      }
      return;
    }

    const nextQueue = [track];
    queueRef.current = nextQueue;
    setQueue(nextQueue);
    currentIndexRef.current = 0;
    setCurrentIndex(0);
    playAudioTrack(track, 0);
  };

  const playQueue = (tracks: Track[], startIndex = 0) => {
    const playableTracks = tracks.filter((track) => Boolean(track.audioUrl));
    if (playableTracks.length === 0) {
      return;
    }

    const safeIndex = Math.max(0, Math.min(startIndex, playableTracks.length - 1));
    const selectedTrack = playableTracks[safeIndex];
    const sameQueue =
      queueRef.current.length === playableTracks.length &&
      queueRef.current.every((track, index) => track.id === playableTracks[index]?.id);

    if (currentTrack?.id === selectedTrack.id && sameQueue) {
      togglePlay();
      return;
    }

    queueRef.current = playableTracks;
    setQueue(playableTracks);
    currentIndexRef.current = safeIndex;
    setCurrentIndex(safeIndex);
    playAudioTrack(selectedTrack, safeIndex);
  };

  const togglePlay = () => {
    const audio = ensureAudio();
    if (!audio) {
      return;
    }

    if (isPlaying) {
      reportBeatPause(currentTrackRef.current);
      fadeOutAndPause();
      setIsPlaying(false);
    } else {
      if (currentTrackRef.current && shouldRetryTrackResolution(audio)) {
        playAudioTrack(
          currentTrackRef.current,
          currentIndexRef.current >= 0 ? currentIndexRef.current : undefined,
        );
        return;
      }

      clearFadeInterval();
      audio.volume = getEffectiveVolume();
      void audio.play().then(() => {
        setIsPlaying(true);
        if (currentTrackRef.current) {
          reportBeatPlay(currentTrackRef.current);
        }
      }).catch(() => {
        setIsPlaying(false);
      });
    }
  };

  const seekTo = (time: number) => {
    if (!audioRef.current) {
      return;
    }

    const safeTime = Math.max(0, Math.min(time, duration));
    audioRef.current.currentTime = safeTime;
    currentTimeRef.current = safeTime;
    setCurrentTime(safeTime);
    setProgress(duration > 0 ? (safeTime / duration) * 100 : 0);
  };

  const playNext = () => {
    const nextIndex = currentIndexRef.current + 1;
    if (nextIndex >= queueRef.current.length) {
      if (audioRef.current) {
        audioRef.current.pause();
      }
      resetPlayerState();
      return;
    }

    const nextTrack = queueRef.current[nextIndex];
    if (nextTrack) {
      playAudioTrack(nextTrack, nextIndex);
    }
  };

  const playPrevious = () => {
    if (currentIndexRef.current === 0 && currentTrack) {
      seekTo(0);
      return;
    }

    const previousIndex = currentIndexRef.current - 1;
    if (previousIndex < 0) {
      return;
    }

    const previousTrack = queueRef.current[previousIndex];
    if (previousTrack) {
      playAudioTrack(previousTrack, previousIndex);
    }
  };

  return (
    <AudioPlayerContext.Provider
      value={{
        currentTrack,
        isPlaying,
        progress,
        currentTime,
        duration,
        queue,
        currentIndex,
        canPlayNext: currentIndex >= 0 && currentIndex < queue.length - 1,
        canPlayPrevious: currentIndex > 0 || (currentIndex === 0 && Boolean(currentTrack)),
        volume,
        isMuted,
        playTrack,
        playQueue,
        togglePlay,
        seekTo,
        playNext,
        playPrevious,
        setVolume,
        toggleMute,
      }}
    >
      {children}
    </AudioPlayerContext.Provider>
  );
}

export function useAudioPlayer() {
  const ctx = useContext(AudioPlayerContext);
  if (!ctx) {
    throw new Error('useAudioPlayer must be used inside provider');
  }
  return ctx;
}
