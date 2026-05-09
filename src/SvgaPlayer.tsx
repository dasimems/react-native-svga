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

    const soundsRef = useRef(sounds);
    soundsRef.current = sounds;
    const onStartRef = useRef(onStart);
    onStartRef.current = onStart;
    const onFinishRef = useRef(onFinish);
    onFinishRef.current = onFinish;
    const onLoopRef = useRef(onLoop);
    onLoopRef.current = onLoop;
    const onErrorRef = useRef(onError);
    onErrorRef.current = onError;

    useImperativeHandle(
      ref,
      (): SvgaPlayerHandle => ({
        play: () => hybridRef.current?.play(),
        pause: () => hybridRef.current?.pause(),
        stop: () => hybridRef.current?.stop(),
        seekToFrame: (f) => hybridRef.current?.seekToFrame(f),
        seekToProgress: (p) => hybridRef.current?.seekToProgress(p),
        isPlaying: () => hybridRef.current?.isPlaying() ?? false,
      }),
      []
    );

    useEffect(() => {
      if (!sounds?.length) return undefined;
      let cancelled = false;
      const load = async () => {
        await Promise.all(
          sounds.map((s) =>
            loadSoundSafely(
              svgaManager,
              s,
              () => cancelled,
              (m) => onErrorRef.current?.(m)
            )
          )
        );
      };
      load();
      return () => {
        cancelled = true;
        unloadAllSounds(svgaManager, sounds);
      };
    }, [sounds]);

    useEffect(() => {
      if (playInBackground) return undefined;
      let wasPlayingForBg = false;
      const onChange = (state: AppStateStatus) => {
        if (state === 'active') {
          if (!wasPlayingForBg) return;
          wasPlayingForBg = false;
          hybridRef.current?.play();
          return;
        }
        wasPlayingForBg = hybridRef.current?.isPlaying() ?? false;
        if (wasPlayingForBg) hybridRef.current?.pause();
      };
      const subscription = AppState.addEventListener('change', onChange);
      return () => subscription.remove();
    }, [playInBackground]);

    useEffect(() => {
      return () => {
        hybridRef.current?.stop();
      };
    }, []);

    const handleStart = useCallback(() => {
      playSoundsForTrigger(svgaManager, soundsRef.current, 'start');
      onStartRef.current?.();
    }, []);

    const handleFinish = useCallback(() => {
      playSoundsForTrigger(svgaManager, soundsRef.current, 'finish');
      onFinishRef.current?.();
    }, []);

    const handleLoop = useCallback((count: number) => {
      onLoopRef.current?.(count);
    }, []);

    const handleError = useCallback((message: string) => {
      onErrorRef.current?.(message);
    }, []);

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
