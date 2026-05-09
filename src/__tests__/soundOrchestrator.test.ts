import {
  loadSoundSafely,
  playSoundsForTrigger,
  shouldMuteBuiltInAudio,
  unloadAllSounds,
  type SoundManagerLike,
} from '../internal/soundOrchestrator';
import type { SvgaSound } from '../types';

const buildManager = (): jest.Mocked<SoundManagerLike> => ({
  loadSound: jest.fn().mockResolvedValue(undefined),
  unloadSound: jest.fn(),
  playSound: jest.fn(),
});

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

describe('playSoundsForTrigger', () => {
  it('plays only sounds matching the trigger', () => {
    const manager = buildManager();
    const sounds: SvgaSound[] = [
      { key: 'a', url: 'u1', playOn: 'start', volume: 0.5 },
      { key: 'b', url: 'u2', playOn: 'finish' },
      { key: 'c', url: 'u3', playOn: 'start' },
    ];

    playSoundsForTrigger(manager, sounds, 'start');

    expect(manager.playSound).toHaveBeenCalledTimes(2);
    expect(manager.playSound).toHaveBeenNthCalledWith(1, 'a', 0.5);
    expect(manager.playSound).toHaveBeenNthCalledWith(2, 'c', 1.0);
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
      [{ key: 'a', url: 'u', playOn: 'start' }],
      'start'
    );
    expect(manager.playSound).toHaveBeenCalledWith('a', 1.0);
  });
});

describe('loadSoundSafely', () => {
  const sound: SvgaSound = {
    key: 'cheer',
    url: 'https://x.test/cheer.mp3',
    playOn: 'finish',
  };

  it('loads via the manager', async () => {
    const manager = buildManager();
    await loadSoundSafely(manager, sound, () => false);
    expect(manager.loadSound).toHaveBeenCalledWith(
      'cheer',
      'https://x.test/cheer.mp3'
    );
  });

  it('reports load errors via onError', async () => {
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
  it('unloads each sound key', () => {
    const manager = buildManager();
    unloadAllSounds(manager, [
      { key: 'a', url: 'u1', playOn: 'start' },
      { key: 'b', url: 'u2', playOn: 'finish' },
    ]);
    expect(manager.unloadSound).toHaveBeenCalledTimes(2);
    expect(manager.unloadSound).toHaveBeenNthCalledWith(1, 'a');
    expect(manager.unloadSound).toHaveBeenNthCalledWith(2, 'b');
  });

  it('is a no-op for empty/undefined input', () => {
    const manager = buildManager();
    unloadAllSounds(manager, undefined);
    unloadAllSounds(manager, []);
    expect(manager.unloadSound).not.toHaveBeenCalled();
  });
});
