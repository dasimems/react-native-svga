import { getHostComponent } from 'react-native-nitro-modules';
const SvgaConfig = require('../nitrogen/generated/shared/json/SvgaConfig.json');
import type {
  SvgaMethods,
  SvgaProps,
} from './Svga.nitro';

export const SvgaView = getHostComponent<
  SvgaProps,
  SvgaMethods
>('Svga', () => SvgaConfig);
