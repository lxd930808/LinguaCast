/**
 * Low-level UMP helpers.
 *
 * Primary download path uses googlevideo's SabrStream, which already consumes
 * MEDIA_HEADER / MEDIA / MEDIA_END parts. This module remains for offline fixture
 * tests and diagnostics that inspect raw UMP buffers.
 */
import { CompositeBuffer, UmpReader } from 'googlevideo/ump';
import { MediaHeader, UMPPartId } from 'googlevideo/protos';

export interface UmpPartSummary {
  type: number;
  typeName: string;
  size: number;
  headerId?: number;
  itag?: number;
  sequenceNumber?: number;
  isInitSeg?: boolean;
  contentLength?: number;
}

function partTypeName(type: number): string {
  const entry = Object.entries(UMPPartId).find(([, value]) => value === type);
  return entry?.[0] ?? `UNKNOWN_${type}`;
}

export function summarizeUmpBuffer(buffer: Uint8Array): UmpPartSummary[] {
  const reader = new UmpReader(new CompositeBuffer([buffer]));
  const summaries: UmpPartSummary[] = [];

  reader.read((part) => {
    const summary: UmpPartSummary = {
      type: part.type,
      typeName: partTypeName(part.type),
      size: part.size
    };

    if (part.type === UMPPartId.MEDIA_HEADER) {
      try {
        const bytes = part.data.chunks.length
          ? concatenate(part.data.chunks)
          : new Uint8Array();
        const header = MediaHeader.decode(bytes);
        summary.headerId = header.headerId;
        summary.itag = header.itag;
        summary.sequenceNumber = header.sequenceNumber;
        summary.isInitSeg = header.isInitSeg;
        summary.contentLength = header.contentLength
          ? Number(header.contentLength)
          : undefined;
      } catch {
        // Ignore decode failures in diagnostic mode.
      }
    }

    if (part.type === UMPPartId.MEDIA_END || part.type === UMPPartId.MEDIA) {
      const first = part.data.chunks[0]?.[0];
      if (typeof first === 'number') {
        summary.headerId = first;
      }
    }

    summaries.push(summary);
    return true;
  });

  return summaries;
}

function concatenate(chunks: Uint8Array[]): Uint8Array {
  const total = chunks.reduce((sum, chunk) => sum + chunk.byteLength, 0);
  const out = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    out.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return out;
}
