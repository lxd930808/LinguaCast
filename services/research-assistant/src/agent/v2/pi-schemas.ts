import { Type } from '@earendil-works/pi-ai';

import { V2_ALL_TOOLS, type V2ToolName } from './tools.js';

const URI = Type.Object(
  { uri: Type.Optional(Type.String({ minLength: 1, maxLength: 500 })) },
  { additionalProperties: false }
);

const URI_REQUIRED = Type.Object(
  { uri: Type.String({ minLength: 1, maxLength: 500 }) },
  { additionalProperties: false }
);

const WRITE_FILE = Type.Object(
  {
    uri: Type.String({ minLength: 1, maxLength: 500 }),
    contents: Type.String({ minLength: 1, maxLength: 8000 })
  },
  { additionalProperties: false }
);

const SEARCH_FILES = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    uri: Type.Optional(Type.String({ minLength: 1, maxLength: 500 }))
  },
  { additionalProperties: false }
);

const GREP_FILES = Type.Object(
  {
    pattern: Type.String({ minLength: 1, maxLength: 200 }),
    root: Type.Optional(Type.String({ minLength: 1, maxLength: 500 })),
    mode: Type.Optional(Type.String({ maxLength: 16 })),
    glob: Type.Optional(Type.String({ maxLength: 80 })),
    caseSensitive: Type.Optional(Type.Boolean())
  },
  { additionalProperties: false }
);

const ARTIFACT_ID = Type.Object(
  { artifactId: Type.String({ minLength: 1, maxLength: 40 }) },
  { additionalProperties: false }
);

const SAVE_ARTIFACT = Type.Object(
  {
    kind: Type.String({ minLength: 1, maxLength: 40 }),
    contents: Type.String({ minLength: 1, maxLength: 8000 }),
    sourceURL: Type.Optional(Type.String({ maxLength: 2000 })),
    contentKey: Type.Optional(Type.String({ maxLength: 200 }))
  },
  { additionalProperties: false }
);

const WEB_SEARCH = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    locale: Type.Optional(Type.String({ maxLength: 16 })),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 }))
  },
  { additionalProperties: false }
);

const FETCH_PAGE = Type.Object(
  { url: Type.String({ minLength: 8, maxLength: 2000 }) },
  { additionalProperties: false }
);

const QUERY = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 10 }))
  },
  { additionalProperties: false }
);

const SOURCE_LOOKUP = Type.Object(
  {
    sourceId: Type.Optional(Type.String({ maxLength: 80 })),
    videoId: Type.Optional(Type.String({ maxLength: 80 })),
    id: Type.Optional(Type.String({ maxLength: 80 })),
    searchResultId: Type.Optional(Type.String({ maxLength: 40 })),
    artifactId: Type.Optional(Type.String({ maxLength: 40 }))
  },
  { additionalProperties: false }
);

const READ_SEARCH = Type.Object(
  {
    artifactId: Type.Optional(Type.String({ maxLength: 40 })),
    searchRunId: Type.Optional(Type.String({ maxLength: 40 }))
  },
  { additionalProperties: false }
);

const WRITE_MEMORY = Type.Object(
  {
    content: Type.String({ minLength: 1, maxLength: 4000 }),
    type: Type.Optional(Type.String({ maxLength: 40 })),
    sourceArtifactId: Type.Optional(Type.String({ maxLength: 40 })),
    hypothesis: Type.Optional(Type.Boolean())
  },
  { additionalProperties: false }
);

const PROPOSE_MEMORY = Type.Object(
  {
    content: Type.String({ minLength: 1, maxLength: 4000 }),
    reason: Type.Optional(Type.String({ maxLength: 500 }))
  },
  { additionalProperties: false }
);

const RETRIEVE = Type.Object(
  {
    query: Type.String({ minLength: 1, maxLength: 200 }),
    limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 40 }))
  },
  { additionalProperties: false }
);

const TRANSCRIBE = Type.Object(
  { sourceId: Type.String({ minLength: 1, maxLength: 80 }) },
  { additionalProperties: false }
);

const TRANSCRIPT_JOB = Type.Object(
  { transcriptJobId: Type.String({ minLength: 1, maxLength: 40 }) },
  { additionalProperties: false }
);

const EMPTY = Type.Object({}, { additionalProperties: false });

const SAVE_REPORT = Type.Object(
  {
    title: Type.Optional(Type.String({ minLength: 1, maxLength: 80 })),
    markdown: Type.Optional(Type.String({ minLength: 1, maxLength: 8000 })),
    summary: Type.Optional(Type.String({ minLength: 1, maxLength: 8000 })),
    citations: Type.Optional(Type.Array(Type.Object({}, { additionalProperties: true }), { maxItems: 16 })),
    sourceIds: Type.Optional(Type.Array(Type.String({ minLength: 8, maxLength: 40 }), { maxItems: 20 }))
  },
  { additionalProperties: false }
);

export const V2_PARAMETER_SCHEMAS: Record<V2ToolName, ReturnType<typeof Type.Object>> = {
  list_files: URI,
  read_file: URI_REQUIRED,
  write_file: WRITE_FILE,
  search_files: SEARCH_FILES,
  grep_files: GREP_FILES,
  get_artifact: ARTIFACT_ID,
  save_artifact: SAVE_ARTIFACT,
  web_search: WEB_SEARCH,
  fetch_web_page: FETCH_PAGE,
  search_youtube: QUERY,
  get_youtube_video_details: SOURCE_LOOKUP,
  search_podcasts: QUERY,
  get_podcast_episodes: SOURCE_LOOKUP,
  read_search_run: READ_SEARCH,
  write_research_memory: WRITE_MEMORY,
  propose_global_memory: PROPOSE_MEMORY,
  retrieve_evidence: RETRIEVE,
  request_transcription: TRANSCRIBE,
  get_transcript_job: TRANSCRIPT_JOB,
  get_selected_source: EMPTY,
  save_research_report: SAVE_REPORT
};

export const V2_TOOL_DESCRIPTIONS: Record<V2ToolName, string> = {
  list_files: 'List files under a research:// or granted shared:// URI.',
  read_file: 'Read a workspace file by virtual URI.',
  write_file: 'Write a workspace file by virtual URI.',
  search_files: 'Keyword-search workspace files.',
  grep_files: 'Search file contents with a literal or regex pattern.',
  get_artifact: 'Read a saved artifact in this research by artifactId.',
  save_artifact: 'Save a new artifact. Never overwrite an older report.',
  web_search: 'Search the public web. Results are search metadata, not read pages.',
  fetch_web_page: 'Fetch a URL from this turn\'s search results or a policy-passed user URL. Saves a locatable web_page artifact.',
  search_youtube: 'Search YouTube. Returns this run\'s structured top candidates.',
  get_youtube_video_details: 'Read a YouTube source already returned in this turn.',
  search_podcasts: 'Search podcasts. Returns this run\'s structured candidates.',
  get_podcast_episodes: 'Read a podcast source already returned in this turn.',
  read_search_run: 'Read a saved search artifact by artifactId or searchRunId.',
  write_research_memory: 'Write a finding into this research\'s memory.',
  propose_global_memory: 'Propose a global preference. Requires later user confirmation.',
  retrieve_evidence: 'Retrieve locatable evidence for a query from this research\'s artifacts.',
  request_transcription: 'Request transcription for a source from this turn. Confirmation comes from the user, not this call.',
  get_transcript_job: 'Read a transcription job in this research.',
  get_selected_source: 'Read sources collected in this turn.',
  save_research_report:
    'Save a new research report. Factual paragraphs need citations with artifactId, quote, and locator fields from retrieve_evidence.'
};

export function isV2PiToolName(name: string): name is V2ToolName {
  return (V2_ALL_TOOLS as readonly string[]).includes(name);
}
