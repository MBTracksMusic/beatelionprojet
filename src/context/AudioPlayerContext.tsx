import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react';

export type Track = {
  id: string;
  title: string;
  audioUrl: string;
  cover_image_url?: string | null;
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
  playTrack: (track: Track) => void;
  playQueue: (tracks: Track[], startIndex?: number) => void;
  togglePlay: () => void;
  seekTo: (time: number) => void;
  playNext: () => void;
  playPrevious: () => void;
};

const AudioPlayerContext = createContext<AudioPlayerContextType | null>(null);

export function AudioPlayerProvider({ children }: { children: ReactNode }) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  const fadeIntervalRef = useRef<number | null>(null);
  const [currentTrack, setCurrentTrack] = useState<Track | null>(null);
  const [isPlaying, setIsPlaying] = useState(false);
  const [progress, setProgress] = useState(0);
  const [currentTime, setCurrentTime] = useState(0);
  const [duration, setDuration] = useState(0);
  const [queue, setQueue] = useState<Track[]>([]);
  const [currentIndex, setCurrentIndex] = useState(-1);
  const queueRef = useRef<Track[]>([]);
  const currentIndexRef = useRef(-1);

  useEffect(() => {
    queueRef.current = queue;
  }, [queue]);

  useEffect(() => {
    currentIndexRef.current = currentIndex;
  }, [currentIndex]);

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
    setQueue([]);
    setIsPlaying(false);
    setCurrentTrack(null);
    setCurrentTime(0);
    setDuration(0);
    setProgress(0);
    setCurrentIndex(-1);
  };

  const ensureAudio = () => {
    if (!audioRef.current) {
      audioRef.current = new Audio();
      audioRef.current.ontimeupdate = () => {
        if (!audioRef.current) return;
        const current = audioRef.current.currentTime;
        const total = Number.isFinite(audioRef.current.duration)
          ? audioRef.current.duration
          : 0;
        const rawProgress = total > 0 ? (current / total) * 100 : 0;
        setCurrentTime(current);
        setDuration(total);
        setProgress(Math.min(rawProgress, 100));
      };
      audioRef.current.onloadedmetadata = () => {
        if (!audioRef.current) return;
        const total = Number.isFinite(audioRef.current.duration)
          ? audioRef.current.duration
          : 0;
        setDuration(total);
      };
      audioRef.current.onended = () => {
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

    if (audio.volume < 1) {
      return;
    }

    clearFadeInterval();

    const startingVolume = audio.volume || 1;
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
        audio.volume = 1;
      }
    }, intervalTime);
  };

  const playAudioTrack = (track: Track, index?: number) => {
    if (!track.audioUrl) {
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
    clearFadeInterval();
    audio.pause();
    audio.volume = 1;
    audio.src = track.audioUrl;
    audio.preload = 'auto';
    audio.currentTime = 0;
    setCurrentTime(0);
    setDuration(0);
    setProgress(0);
    setCurrentTrack(track);
    void audio.play().then(() => {
      setIsPlaying(true);
    }).catch(() => {
      setIsPlaying(false);
      });
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
        fadeOutAndPause();
        setIsPlaying(false);
      } else {
        clearFadeInterval();
        audio.volume = 1;
        void audio.play().then(() => {
          setIsPlaying(true);
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
      fadeOutAndPause();
      setIsPlaying(false);
    } else {
      clearFadeInterval();
      audio.volume = 1;
      void audio.play().then(() => {
        setIsPlaying(true);
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
        playTrack,
        playQueue,
        togglePlay,
        seekTo,
        playNext,
        playPrevious,
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
