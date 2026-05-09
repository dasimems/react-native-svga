import {
  forwardRef,
  memo,
  useCallback,
  useEffect,
  useImperativeHandle,
  useMemo,
  useRef,
} from 'react';
import { AppState, type AppStateStatus } from 'react-native';
import { getHostComponent } from 'react-native-nitro-modules';
import type { Svga, SvgaMethods, SvgaProps } from './internal/Svga.nitro';
import {
  loadSoundSafely,
  playSoundsForTrigger,
  shouldMuteBuiltInAudio,
  unloadAllSounds,
} from './internal/soundOrchestrator';
import { svgaManager } from './SvgaCache';
import type { SvgaPlayerHandle, SvgaPlayerProps } from './types';

const SvgaConfig = require('../nitrogen/generated/shared/json/SvgaConfig.json');

const SvgaView = getHostComponent<SvgaProps, SvgaMethods>(
  'Svga',
  () => SvgaConfig
);

const SvgaPlayerInner = forwardRef<SvgaPlayerHandle, SvgaPlayerProps>(
  (props, ref) => {
    const {
      source,
      loops = 0,
      autoPlay = true,
      speed = 1.0,
      muteBuiltInAudio,
      builtInAudioVolume = 1.0,
      playInBackground = false,
      sounds,
      scaleMode = 'aspectFit',
      style,
      onStart,
      onFinish,
      onLoop,
      onError,
    } = props;

    const hybridRef = useRef<Svga | null>(null);
    const effectiveMute = shouldMuteBuiltInAudio(muteBuiltInAudio, sounds);

    useImperativeHandle(
      ref,
      (): SvgaPlayerHandle => ({
        play: () => hybridRef.current?.play(),
        pause: () => hybridRef.current?.pause(),
        stop: () => hybridRef.current?.stop(),
        seekToFrame: (f) => hybridRef.current?.seekToFrame(f),
        seekToProgress: (p) => hybridRef.current?.seekToProgress(p),
      }),
      []
    );

    useEffect(() => {
      if (!sounds?.length) return undefined;
      let cancelled = false;
      const load = async () => {
        await Promise.all(
          sounds.map((s) =>
            loadSoundSafely(svgaManager, s, () => cancelled, onError)
          )
        );
      };
      load();
      return () => {
        cancelled = true;
        unloadAllSounds(svgaManager, sounds);
      };
    }, [sounds, onError]);

    useEffect(() => {
      if (playInBackground) return undefined;
      const onChange = (state: AppStateStatus) => {
        if (state === 'active') return;
        hybridRef.current?.pause();
      };
      const subscription = AppState.addEventListener('change', onChange);
      return () => subscription.remove();
    }, [playInBackground]);

    useEffect(() => {
      return () => {
        hybridRef.current?.stop();
        svgaManager.stopAllSounds();
      };
    }, []);

    const handleStart = useCallback(() => {
      playSoundsForTrigger(svgaManager, sounds, 'start');
      onStart?.();
    }, [sounds, onStart]);

    const handleFinish = useCallback(() => {
      playSoundsForTrigger(svgaManager, sounds, 'finish');
      onFinish?.();
    }, [sounds, onFinish]);

    const handleLoop = useCallback(
      (count: number) => onLoop?.(count),
      [onLoop]
    );

    const handleError = useCallback(
      (message: string) => onError?.(message),
      [onError]
    );

    const captureRef = useCallback((value: Svga) => {
      hybridRef.current = value;
    }, []);

    const eventHandlers = useMemo(
      () => ({
        onStart: { f: handleStart },
        onFinish: { f: handleFinish },
        onLoop: { f: handleLoop },
        onError: { f: handleError },
      }),
      [handleStart, handleFinish, handleLoop, handleError]
    );

    return (
      <SvgaView
        hybridRef={{ f: captureRef }}
        source={source}
        loops={loops}
        autoPlay={autoPlay}
        speed={speed}
        muteBuiltInAudio={effectiveMute}
        builtInAudioVolume={builtInAudioVolume}
        playInBackground={playInBackground}
        scaleMode={scaleMode}
        style={style}
        {...eventHandlers}
      />
    );
  }
);

SvgaPlayerInner.displayName = 'SvgaPlayer';

export const SvgaPlayer = memo(SvgaPlayerInner);
export type { SvgaPlayerProps, SvgaPlayerHandle, SvgaSound } from './types';
