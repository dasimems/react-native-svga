import {
  loadSoundSafely,
  namespaceSounds,
  playSoundsForTrigger,
  shouldMuteBuiltInAudio,
  soundsEqual,
  unloadAllSounds,
  type NamespacedSound,
  type SoundManagerLike,
} from '../internal/soundOrchestrator';
import type { SvgaSound } from '../types';

const buildManager = (): jest.Mocked<SoundManagerLike> => ({
  loadSound: jest.fn().mockResolvedValue(undefined),
  unloadSound: jest.fn(),
  playSound: jest.fn(),
});

const ns = (sounds: SvgaSound[], namespace = 'inst'): NamespacedSound[] =>
  namespaceSounds(namespace, sounds);

describe('shouldMuteBuiltInAudio', () => {
  it('returns the explicit value when provided', () => {
    expect(shouldMuteBuiltInAudio(true, [])).toBe(true);
    expect(
      shouldMuteBuiltInAudio(false, [{ key: 'a', url: 'u', playOn: 'start' }])
    ).toBe(false);
  });

  it('mutes when extra sounds are passed and no explicit override', () => {
    expect(
      shouldMuteBuiltInAudio(undefined, [
        { key: 'a', url: 'u', playOn: 'start' },
      ])
    ).toBe(true);
  });

  it('does not mute when no sounds and no override', () => {
    expect(shouldMuteBuiltInAudio(undefined, undefined)).toBe(false);
    expect(shouldMuteBuiltInAudio(undefined, [])).toBe(false);
  });
});

describe('namespaceSounds', () => {
  it('prefixes each user key with the instance namespace', () => {
    const out = namespaceSounds('inst-A', [
      { key: 'cheer', url: 'u', playOn: 'start' },
    ]);
    expect(out).toEqual([
      {
        key: 'inst-A::cheer',
        publicKey: 'cheer',
        url: 'u',
        playOn: 'start',
        volume: undefined,
      },
    ]);
  });

  it('returns an empty array for nullish or empty input', () => {
    expect(namespaceSounds('x', undefined)).toEqual([]);
    expect(namespaceSounds('x', [])).toEqual([]);
  });

  it('produces non-colliding keys for two namespaces', () => {
    const a = namespaceSounds('A', [
      { key: 'cheer', url: 'u', playOn: 'start' },
    ]);
    const b = namespaceSounds('B', [
      { key: 'cheer', url: 'u', playOn: 'start' },
    ]);
    expect(a[0]!.key).not.toEqual(b[0]!.key);
  });
});

describe('soundsEqual', () => {
  it('returns true for identical references', () => {
    const arr = [{ key: 'a', url: 'u', playOn: 'start' as const }];
    expect(soundsEqual(arr, arr)).toBe(true);
  });

  it('returns true for equal-content arrays', () => {
    expect(
      soundsEqual(
        [{ key: 'a', url: 'u', playOn: 'start' }],
        [{ key: 'a', url: 'u', playOn: 'start' }]
      )
    ).toBe(true);
  });

  it('treats undefined and empty array as equivalent', () => {
    expect(soundsEqual(undefined, [])).toBe(true);
    expect(soundsEqual([], undefined)).toBe(true);
    expect(soundsEqual(undefined, undefined)).toBe(true);
  });

  it('returns false on length mismatch', () => {
    expect(
      soundsEqual(
        [{ key: 'a', url: 'u', playOn: 'start' }],
        [
          { key: 'a', url: 'u', playOn: 'start' },
          { key: 'b', url: 'u', playOn: 'start' },
        ]
      )
    ).toBe(false);
  });

  it('returns false on field divergence', () => {
    expect(
      soundsEqual(
        [{ key: 'a', url: 'u', playOn: 'start' }],
        [{ key: 'a', url: 'v', playOn: 'start' }]
      )
    ).toBe(false);
    expect(
      soundsEqual(
        [{ key: 'a', url: 'u', playOn: 'start', volume: 0.5 }],
        [{ key: 'a', url: 'u', playOn: 'start', volume: 0.6 }]
      )
    ).toBe(false);
  });
});

describe('playSoundsForTrigger', () => {
  it('plays only sounds matching the trigger via the namespaced key', () => {
    const manager = buildManager();
    const sounds = ns([
      { key: 'a', url: 'u1', playOn: 'start', volume: 0.5 },
      { key: 'b', url: 'u2', playOn: 'finish' },
      { key: 'c', url: 'u3', playOn: 'start' },
    ]);

    playSoundsForTrigger(manager, sounds, 'start');

    expect(manager.playSound).toHaveBeenCalledTimes(2);
    expect(manager.playSound).toHaveBeenNthCalledWith(1, 'inst::a', 0.5);
    expect(manager.playSound).toHaveBeenNthCalledWith(2, 'inst::c', 1.0);
  });

  it('does nothing for empty or undefined sound list', () => {
    const manager = buildManager();
    playSoundsForTrigger(manager, undefined, 'start');
    playSoundsForTrigger(manager, [], 'finish');
    expect(manager.playSound).not.toHaveBeenCalled();
  });

  it('uses default volume of 1.0 when not specified', () => {
    const manager = buildManager();
    playSoundsForTrigger(
      manager,
      ns([{ key: 'a', url: 'u', playOn: 'start' }]),
      'start'
    );
    expect(manager.playSound).toHaveBeenCalledWith('inst::a', 1.0);
  });
});

describe('loadSoundSafely', () => {
  const sound: NamespacedSound = {
    key: 'inst::cheer',
    publicKey: 'cheer',
    url: 'https://x.test/cheer.mp3',
    playOn: 'finish',
  };

  it('loads via the manager using the namespaced key', async () => {
    const manager = buildManager();
    await loadSoundSafely(manager, sound, () => false);
    expect(manager.loadSound).toHaveBeenCalledWith(
      'inst::cheer',
      'https://x.test/cheer.mp3'
    );
  });

  it('reports load errors via onError using the public key', async () => {
    const manager = buildManager();
    manager.loadSound.mockRejectedValueOnce(new Error('network down'));
    const onError = jest.fn();
    await loadSoundSafely(manager, sound, () => false, onError);
    expect(onError).toHaveBeenCalledWith(
      'Failed to load sound "cheer": network down'
    );
  });

  it('swallows errors silently when cancelled', async () => {
    const manager = buildManager();
    manager.loadSound.mockRejectedValueOnce(new Error('boom'));
    const onError = jest.fn();
    await loadSoundSafely(manager, sound, () => true, onError);
    expect(onError).not.toHaveBeenCalled();
  });

  it('handles non-Error rejection values', async () => {
    const manager = buildManager();
    manager.loadSound.mockRejectedValueOnce('string failure');
    const onError = jest.fn();
    await loadSoundSafely(manager, sound, () => false, onError);
    expect(onError).toHaveBeenCalledWith(
      'Failed to load sound "cheer": string failure'
    );
  });
});

describe('unloadAllSounds', () => {
  it('unloads each namespaced key', () => {
    const manager = buildManager();
    unloadAllSounds(
      manager,
      ns([
        { key: 'a', url: 'u1', playOn: 'start' },
        { key: 'b', url: 'u2', playOn: 'finish' },
      ])
    );
    expect(manager.unloadSound).toHaveBeenCalledTimes(2);
    expect(manager.unloadSound).toHaveBeenNthCalledWith(1, 'inst::a');
    expect(manager.unloadSound).toHaveBeenNthCalledWith(2, 'inst::b');
  });

  it('is a no-op for empty/undefined input', () => {
    const manager = buildManager();
    unloadAllSounds(manager, undefined);
    unloadAllSounds(manager, []);
    expect(manager.unloadSound).not.toHaveBeenCalled();
  });
});
