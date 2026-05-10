import type { SvgaSound } from '../types';

export interface SoundManagerLike {
  loadSound: (key: string, url: string) => Promise<void>;
  unloadSound: (key: string) => void;
  playSound: (key: string, volume: number) => void;
}

export interface NamespacedSound {
  key: string;
  publicKey: string;
  url: string;
  playOn: SvgaSound['playOn'];
  volume?: number;
}

export const namespaceSounds = (
  namespace: string,
  sounds: SvgaSound[] | undefined
): NamespacedSound[] => {
  if (!sounds?.length) return [];
  return sounds.map((s) => ({
    key: `${namespace}::${s.key}`,
    publicKey: s.key,
    url: s.url,
    playOn: s.playOn,
    volume: s.volume,
  }));
};

export const playSoundsForTrigger = (
  manager: SoundManagerLike,
  sounds: NamespacedSound[] | undefined,
  trigger: SvgaSound['playOn'],
  isLoaded?: (sound: NamespacedSound) => boolean
): void => {
  if (!sounds?.length) return;
  for (const sound of sounds) {
    if (sound.playOn !== trigger) continue;
    if (isLoaded && !isLoaded(sound)) continue;
    const volume = sound.volume ?? 1.0;
    manager.playSound(sound.key, volume);
  }
};

export const loadSoundSafely = async (
  manager: SoundManagerLike,
  sound: NamespacedSound,
  isCancelled: () => boolean,
  onError?: (message: string) => void
): Promise<void> => {
  try {
    await manager.loadSound(sound.key, sound.url);
  } catch (err: unknown) {
    if (isCancelled()) return;
    const message = err instanceof Error ? err.message : String(err);
    onError?.(`Failed to load sound "${sound.publicKey}": ${message}`);
  }
};

export const unloadAllSounds = (
  manager: SoundManagerLike,
  sounds: NamespacedSound[] | undefined
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

export const soundsEqual = (
  a: SvgaSound[] | undefined,
  b: SvgaSound[] | undefined
): boolean => {
  if (a === b) return true;
  if (!a || !b) return !a?.length && !b?.length;
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) {
    const x = a[i]!;
    const y = b[i]!;
    if (
      x.key !== y.key ||
      x.url !== y.url ||
      x.playOn !== y.playOn ||
      x.volume !== y.volume
    ) {
      return false;
    }
  }
  return true;
};
