import type { ArtifactWriter } from './writer.js';
import type { SearchArtifactSink, SearchRunDocument } from '../search/artifact-sink.js';
import { redactSearchDocument } from '../search/artifact-sink.js';

export class ArtifactWriterSearchSink implements SearchArtifactSink {
  constructor(private readonly writerFor: (researchId: string) => ArtifactWriter | null) {}

  persist(document: SearchRunDocument): { artifactId: string } | null {
    const writer = this.writerFor(document.researchId);
    if (!writer) return null;
    const safe = redactSearchDocument(document);
    const kind = safe.platform === 'youtube' ? 'youtube_search' : 'podcast_search';
    const producer = safe.platform === 'youtube' ? 'search_youtube' : 'search_podcasts';
    const saved = writer.save({
      kind,
      contents: `${JSON.stringify(safe, null, 2)}\n`,
      producer,
      evidenceLevel: 'search_metadata'
    });
    return { artifactId: saved.artifactId };
  }
}
