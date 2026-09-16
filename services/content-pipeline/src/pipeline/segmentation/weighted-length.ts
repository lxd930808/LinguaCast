// Port of SubtitleWeightedLength (ios/.../SubtitleDisplay.swift). Weights
// CJK/kana/full-width scalars heavier for subtitle length budgeting. Iterates
// Unicode code points (not UTF-16 units) to match Swift unicodeScalars.

export const CJK_FULL_WIDTH_WEIGHT = 1.75;
export const HANGUL_WEIGHT = 1.5;
export const DEFAULT_WEIGHT = 1.0;

export function scalarWeight(value: number): number {
  if (value >= 0x1100 && value <= 0x11ff) return HANGUL_WEIGHT; // Hangul Jamo
  if (value >= 0x2e80 && value <= 0x9fff) return CJK_FULL_WIDTH_WEIGHT; // radicals … ideographs
  if (value >= 0xa000 && value <= 0xa4cf) return CJK_FULL_WIDTH_WEIGHT; // Yi
  if (value >= 0xac00 && value <= 0xd7af) return HANGUL_WEIGHT; // Hangul syllables
  if (value >= 0xf900 && value <= 0xfaff) return CJK_FULL_WIDTH_WEIGHT; // compat ideographs
  if (value >= 0xfe30 && value <= 0xfe4f) return CJK_FULL_WIDTH_WEIGHT; // compat forms
  if (value >= 0xff00 && value <= 0xff60) return CJK_FULL_WIDTH_WEIGHT; // full-width forms
  if (value >= 0xffe0 && value <= 0xffe6) return CJK_FULL_WIDTH_WEIGHT; // full-width signs
  if (value >= 0x3000 && value <= 0x303f) return CJK_FULL_WIDTH_WEIGHT; // CJK punctuation
  if (value >= 0x3040 && value <= 0x30ff) return CJK_FULL_WIDTH_WEIGHT; // Hiragana + Katakana
  if (value >= 0x31f0 && value <= 0x31ff) return CJK_FULL_WIDTH_WEIGHT; // Katakana phonetic ext
  if (value >= 0x0e00 && value <= 0x0e7f) return DEFAULT_WEIGHT; // Thai
  if (value >= 0x20000 && value <= 0x2fa1f) return CJK_FULL_WIDTH_WEIGHT; // CJK ext B..compat sup
  return DEFAULT_WEIGHT;
}

export function weightedLength(text: string): number {
  let total = 0;
  for (const char of text) {
    total += scalarWeight(char.codePointAt(0) ?? 0);
  }
  return total;
}
