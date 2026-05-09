import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules';

export type ScaleMode = 'fill' | 'aspectFit' | 'aspectFill';

export interface SvgaProps extends HybridViewProps {
  source: string;
  loops: number;
  autoPlay: boolean;
  speed: number;
  // Audio (baked-in)
  muteBuiltInAudio: boolean;
  builtInAudioVolume: number;
  // Lifecycle
  playInBackground: boolean;
  // Styling
  scaleMode: ScaleMode;

  // Events
  onStart?: () => void;
  onFinish?: () => void;
  onLoop?: (count: number) => void;
  onError?: (message: string) => void;
}
export interface SvgaMethods extends HybridViewMethods {
  play(): void;
  pause(): void;
  stop(): void;
  seekToFrame(frame: number): void;
  seekToProgress(progress: number): void;
  isPlaying(): boolean;
}

export type Svga = HybridView<SvgaProps, SvgaMethods>;
