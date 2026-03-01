import type {
  HybridView,
  HybridViewMethods,
  HybridViewProps,
} from 'react-native-nitro-modules';

export interface SvgaProps extends HybridViewProps {
  color: string;
}
export interface SvgaMethods extends HybridViewMethods {}

export type Svga = HybridView<
  SvgaProps,
  SvgaMethods
>;
