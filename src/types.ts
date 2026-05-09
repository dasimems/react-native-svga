import type { ViewStyle } from 'react-native';

export type ScaleMode = 'fill' | 'aspectFit' | 'aspectFill';

export type SoundPlayOn = 'start' | 'finish';

export interface SvgaSound {
  key: string;
  url: string;
  playOn: SoundPlayOn;
  volume?: number;
}

export interface SvgaPlayerHandle {
  play: () => void;
  pause: () => void;
  stop: () => void;
  seekToFrame: (frame: number) => void;
  seekToProgress: (progress: number) => void;
}

export interface SvgaPlayerProps {
  source: string;

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
