import React, { memo, useCallback, useEffect } from 'react';
import type { ViewStyle } from 'react-native';
import { getHostComponent } from 'react-native-nitro-modules';
import type { SvgaMethods, SvgaProps } from './internal/Svga.nitro';
import { svgaManager } from './SvgaCache';
const SvgaConfig = require('../nitrogen/generated/shared/json/SvgaConfig.json');

const SvgaView = getHostComponent<SvgaProps, SvgaMethods>(
  'Svga',
  () => SvgaConfig
);

export interface SvgaSound {
  key: string;
  url: string;
  playOn: 'start' | 'finish';
  volume?: number;
}

export interface SvgaPlayerProps {
  // Core
  source: string;
  loops?: number;
  autoPlay?: boolean;
  speed?: number;

  // Built-in audio (baked into .svga bundle)
  muteBuiltInAudio?: boolean;
  builtInAudioVolume?: number;

  // Extra sounds (outside the bundle)
  sounds?: SvgaSound[];

  // Styling
  scaleMode?: 'fill' | 'aspectFit' | 'aspectFill';
  style?: ViewStyle;

  // Events
  onStart?: () => void;
  onFinish?: () => void;
  onLoop?: (count: number) => void;
  onError?: (message: string) => void;
}

export const SvgaPlayer: React.FC<SvgaPlayerProps> = memo(
  ({
    source,
    loops = 0,
    autoPlay = true,
    speed = 1.0,
    muteBuiltInAudio = false,
    builtInAudioVolume = 1.0,
    sounds,
    scaleMode = 'aspectFit',
    style,
    onStart,
    onFinish,
    onLoop,
    onError,
  }) => {
    // Preload extra sounds when source changes
    useEffect(() => {
      if (!sounds?.length) return;
      const load = async () => {
        await Promise.all(
          sounds.map((s) => svgaManager.loadSound(s.key, s.url))
        );
      };
      load();
      return () => {
        sounds.forEach((s) => svgaManager.unloadSound(s.key));
      };
    }, [source, sounds]);

    const handleStart = useCallback(() => {
      sounds
        ?.filter((s) => s.playOn === 'start')
        .forEach((s) => svgaManager.playSound(s.key, s.volume ?? 1.0));
      onStart?.();
    }, [onStart, sounds]);

    const handleFinish = useCallback(() => {
      sounds
        ?.filter((s) => s.playOn === 'finish')
        .forEach((s) => svgaManager.playSound(s.key, s.volume ?? 1.0));
      svgaManager.stopAllSounds();
      onFinish?.();
    }, [onFinish, sounds]);

    return (
      <SvgaView
        source={source}
        loops={loops}
        autoPlay={autoPlay}
        speed={speed}
        muteBuiltInAudio={muteBuiltInAudio}
        builtInAudioVolume={builtInAudioVolume}
        scaleMode={scaleMode}
        style={style}
        onStart={{ f: handleStart }}
        onFinish={{ f: handleFinish }}
        onLoop={{ f: onLoop }}
        onError={{ f: onError }}
      />
    );
  }
);

SvgaPlayer;
