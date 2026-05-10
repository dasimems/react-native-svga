import type { ViewStyle } from 'react-native';

export type ScaleMode = 'fill' | 'aspectFit' | 'aspectFill';

export type SoundPlayOn = 'start' | 'finish';

export interface SvgaSound {
  key: string;
  url: string;
  playOn: SoundPlayOn;
  volume?: number;
}

/**
 * A single item passed to `SvgaCache.preload`. A bare URL string is treated as
 * `{ url, cacheKey: url }`, preserving the previous string-array API. Passing
 * `{ url, cacheKey }` decouples cache identity from the download URL — useful
 * when the bytes at a stable URL can change (signed URLs, content-version
 * bumps, tenant-scoped assets, etc.). Bumping `cacheKey` triggers a fresh
 * download on next request without changing the URL surface.
 */
export interface SvgaPreloadItem {
  url: string;
  cacheKey?: string;
}

export type SvgaPreloadInput = string | SvgaPreloadItem;

export interface SvgaPlayerHandle {
  play: () => void;
  pause: () => void;
  stop: () => void;
  seekToFrame: (frame: number) => void;
  seekToProgress: (progress: number) => void;
  isPlaying: () => boolean;
}

export interface SvgaPlayerProps {
  source: string;

  /**
   * Identity used for cache lookup and storage. Defaults to `source` when
   * omitted. Change `cacheKey` to force a fresh download for the same URL —
   * the new bytes are stored under the new key, and any in-flight player
   * already showing the old key keeps playing it until released.
   */
  cacheKey?: string;

  loops?: number;
  autoPlay?: boolean;
  speed?: number;

  muteBuiltInAudio?: boolean;
  builtInAudioVolume?: number;

  /**
   * When false (default), playback (frames + audio) automatically stops when
   * the player leaves the visible window or the app is backgrounded. Set to
   * true if you want the audio to keep playing while the screen is offscreen
   * or the app is backgrounded - similar to background playback in a video
   * player.
   */
  playInBackground?: boolean;

  sounds?: SvgaSound[];

  scaleMode?: ScaleMode;
  style?: ViewStyle;

  onStart?: () => void;
  onFinish?: () => void;
  onLoop?: (count: number) => void;
  onError?: (message: string) => void;
}
