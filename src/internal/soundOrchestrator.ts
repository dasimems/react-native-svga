import type { SvgaSound } from '../types';

export interface SoundManagerLike {
  loadSound: (key: string, url: string) => Promise<void>;
  unloadSound: (key: string) => void;
  playSound: (key: string, volume: number) => void;
}

export const playSoundsForTrigger = (
  manager: SoundManagerLike,
  sounds: SvgaSound[] | undefined,
  trigger: SvgaSound['playOn']
): void => {
  if (!sounds?.length) return;
  for (const sound of sounds) {
    if (sound.playOn !== trigger) continue;
    const volume = sound.volume ?? 1.0;
    manager.playSound(sound.key, volume);
  }
};

export const loadSoundSafely = async (
  manager: SoundManagerLike,
  sound: SvgaSound,
  isCancelled: () => boolean,
  onError?: (message: string) => void
): Promise<void> => {
  try {
    await manager.loadSound(sound.key, sound.url);
  } catch (err: unknown) {
    if (isCancelled()) return;
    const message = err instanceof Error ? err.message : String(err);
    onError?.(`Failed to load sound "${sound.key}": ${message}`);
  }
};

export const unloadAllSounds = (
  manager: SoundManagerLike,
  sounds: SvgaSound[] | undefined
): void => {
  if (!sounds?.length) return;
  for (const sound of sounds) manager.unloadSound(sound.key);
};

export const shouldMuteBuiltInAudio = (
  explicit: boolean | undefined,
  sounds: SvgaSound[] | undefined
): boolean => {
  if (explicit !== undefined) return explicit;
  return !!sounds && sounds.length > 0;
};
