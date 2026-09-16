import type { EvalIntent, EvalLanguage, EvalMedia, EvalMatchRule, EvalQuery } from './types.js';

const OFF_TOPIC: EvalMatchRule[] = [
  { kind: 'title_contains', terms: ['minecraft walkthrough', 'fortnite clip', 'gta v funny', 'asmr slime'] }
];

function query(input: {
  id: string;
  query: string;
  language: EvalLanguage;
  intent: EvalIntent;
  media?: EvalMedia[];
  publishedAfter?: string | null;
  duration?: EvalQuery['duration'];
  relevant: EvalMatchRule[];
  preferred?: EvalMatchRule[];
  unacceptable?: EvalMatchRule[];
  ambiguous?: boolean;
  expectQualifiedHit?: boolean;
  expectZero?: boolean;
  notes: string;
}): EvalQuery {
  return {
    media: input.media ?? ['youtube', 'podcast'],
    publishedAfter: input.publishedAfter ?? null,
    duration: input.duration ?? null,
    preferred: input.preferred ?? input.relevant,
    unacceptable: input.unacceptable ?? OFF_TOPIC,
    ambiguous: input.ambiguous ?? false,
    expectQualifiedHit: input.expectQualifiedHit ?? true,
    expectZero: input.expectZero ?? false,
    ...input
  };
}

export const EVAL_CORPUS: EvalQuery[] = [
  query({
    id: 'en-topic-01',
    query: 'Agent Harness interview',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['agent harness', 'agent harnesses'] }],
    notes: 'Topic search for agent harness interviews'
  }),
  query({
    id: 'en-topic-02',
    query: 'AI coding agent long discussion',
    language: 'en',
    intent: 'topic',
    duration: 'long',
    relevant: [{ kind: 'title_contains', terms: ['coding agent', 'ai agent', 'software agent'] }],
    notes: 'Long-form coding agent discussions'
  }),
  query({
    id: 'en-topic-03',
    query: 'recursive self improvement RSI large language models',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['recursive self-improvement', 'recursive self improvement', 'rsi'] }],
    notes: 'Disambiguate RSI as AI term, not finance'
  }),
  query({
    id: 'en-topic-04',
    query: 'bilingual subtitle English learning method',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['bilingual subtitle', 'dual subtitle', 'language learning'] }],
    notes: 'Language learning with subtitles'
  }),
  query({
    id: 'en-topic-05',
    query: 'YouTube SABR streaming protocol explained',
    language: 'en',
    intent: 'topic',
    media: ['youtube'],
    relevant: [{ kind: 'title_contains', terms: ['sabr', 'youtube streaming'] }],
    notes: 'Technical SABR topic'
  }),
  query({
    id: 'en-topic-06',
    query: 'AI for accounting audit sampling',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['audit sampling', 'accounting ai', 'audit'] }],
    notes: 'Professional accounting AI'
  }),
  query({
    id: 'en-topic-07',
    query: 'prompt injection defense patterns',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['prompt injection', 'jailbreak defense'] }],
    notes: 'Security topic'
  }),
  query({
    id: 'en-topic-08',
    query: 'local LLM on Apple Silicon',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['apple silicon', 'mlx', 'local llm', 'ollama'] }],
    notes: 'Local model inference'
  }),
  query({
    id: 'en-person-01',
    query: 'Satya Nadella recent podcast',
    language: 'en',
    intent: 'person',
    media: ['podcast'],
    relevant: [
      { kind: 'title_contains', terms: ['satya nadella'] },
      { kind: 'source_type', sourceType: 'podcast_episode' }
    ],
    preferred: [{ kind: 'source_type', sourceType: 'podcast_episode' }],
    notes: 'Person search must return episodes, not a show named after him'
  }),
  query({
    id: 'en-person-02',
    query: 'Dario Amodei interview',
    language: 'en',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['dario amodei'] }],
    notes: 'Anthropic CEO interviews'
  }),
  query({
    id: 'en-person-03',
    query: 'Andrej Karpathy lecture',
    language: 'en',
    intent: 'person',
    media: ['youtube'],
    relevant: [{ kind: 'title_contains', terms: ['karpathy'] }],
    notes: 'Known educator/lectures'
  }),
  query({
    id: 'en-person-04',
    query: 'Sam Altman podcast appearance',
    language: 'en',
    intent: 'person',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['sam altman'] }, { kind: 'source_type', sourceType: 'podcast_episode' }],
    notes: 'Guest appearance, not a show he hosts'
  }),
  query({
    id: 'en-person-05',
    query: 'Fei-Fei Li interview',
    language: 'en',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['fei-fei li', 'fei fei li'] }],
    notes: 'Person with hyphenated name'
  }),
  query({
    id: 'en-person-06',
    query: 'Geoffrey Hinton recent talk',
    language: 'en',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['geoffrey hinton', 'hinton'] }],
    notes: 'Recent talk by a named researcher'
  }),
  query({
    id: 'en-person-07',
    query: 'Demis Hassabis podcast',
    language: 'en',
    intent: 'person',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['demis hassabis'] }, { kind: 'source_type', sourceType: 'podcast_episode' }],
    notes: 'DeepMind person episode'
  }),
  query({
    id: 'en-person-08',
    query: 'Yann LeCun interview about world models',
    language: 'en',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['yann lecun', 'lecun'] }],
    notes: 'Person plus topic'
  }),
  query({
    id: 'en-show-01',
    query: 'Acquired NVIDIA episode',
    language: 'en',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['acquired'] }, { kind: 'publisher_contains', terms: ['acquired'] }],
    preferred: [{ kind: 'title_contains', terms: ['nvidia'] }],
    notes: 'Known show plus episode topic'
  }),
  query({
    id: 'en-show-02',
    query: 'Hard Fork AI episode',
    language: 'en',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['hard fork'] }, { kind: 'publisher_contains', terms: ['hard fork'] }],
    notes: 'NYT Hard Fork'
  }),
  query({
    id: 'en-show-03',
    query: 'Lex Fridman podcast',
    language: 'en',
    intent: 'show',
    relevant: [{ kind: 'publisher_contains', terms: ['lex fridman'] }, { kind: 'title_contains', terms: ['lex fridman'] }],
    notes: 'Show name search should return the show, not random guests named Lex'
  }),
  query({
    id: 'en-show-04',
    query: 'This American Life',
    language: 'en',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['this american life'] }],
    notes: 'Exact show title'
  }),
  query({
    id: 'en-show-05',
    query: 'Planet Money inflation',
    language: 'en',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'publisher_contains', terms: ['planet money'] }],
    preferred: [{ kind: 'title_contains', terms: ['inflation'] }],
    notes: 'Show plus topic filter'
  }),
  query({
    id: 'en-show-06',
    query: 'Accidental Tech Podcast',
    language: 'en',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['accidental tech podcast', 'atp'] }],
    notes: 'Exact show'
  }),
  query({
    id: 'en-channel-01',
    query: '@ycombinator agent talks',
    language: 'en',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['y combinator', 'ycombinator'] }],
    preferred: [{ kind: 'title_contains', terms: ['agent'] }],
    notes: 'Channel handle plus topic'
  }),
  query({
    id: 'en-channel-02',
    query: '3Blue1Brown linear algebra',
    language: 'en',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['3blue1brown'] }],
    notes: 'Distinctive channel name'
  }),
  query({
    id: 'en-channel-03',
    query: 'Fireship javascript shorts vs long form',
    language: 'en',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['fireship'] }],
    notes: 'Channel whose shorts should be downranked'
  }),
  query({
    id: 'en-channel-04',
    query: 'Two Minute Papers',
    language: 'en',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['two minute papers'] }],
    notes: 'Channel name search'
  }),
  query({
    id: 'en-channel-05',
    query: 'Veritasium science',
    language: 'en',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['veritasium'] }],
    notes: 'Known science channel'
  }),
  query({
    id: 'en-recent-01',
    query: 'recent six months AI coding agent long interviews',
    language: 'en',
    intent: 'recent',
    duration: 'long',
    publishedAfter: '2026-02-28T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['coding agent', 'ai agent', 'software engineering agent'] }],
    notes: 'Explicit recency window of 2026-02-28'
  }),
  query({
    id: 'en-recent-02',
    query: 'this year OpenAI announcements',
    language: 'en',
    intent: 'recent',
    publishedAfter: '2026-01-01T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['openai'] }],
    notes: 'Calendar year filter'
  }),
  query({
    id: 'en-recent-03',
    query: 'latest Anthropic Claude news',
    language: 'en',
    intent: 'recent',
    publishedAfter: '2026-02-28T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['anthropic', 'claude'] }],
    notes: 'Latest news should not surface 2023 clips as recommendations'
  }),
  query({
    id: 'en-recent-04',
    query: 'recent Apple WWDC sessions',
    language: 'en',
    intent: 'recent',
    media: ['youtube'],
    publishedAfter: '2026-01-01T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['wwdc'] }],
    notes: 'Year-bounded Apple developer sessions'
  }),
  query({
    id: 'en-recent-05',
    query: 'past 30 days podcast about AI regulation',
    language: 'en',
    intent: 'recent',
    media: ['podcast'],
    publishedAfter: '2026-08-01T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['regulation', 'ai policy', 'ai act'] }],
    notes: 'Tight recency for podcasts'
  }),
  query({
    id: 'zh-topic-01',
    query: '帮我找 Agent Harness 的深度讨论',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['agent harness'] }],
    notes: 'Chinese request must yield English provider queries'
  }),
  query({
    id: 'zh-topic-02',
    query: '本地大模型在苹果芯片上怎么跑',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['apple silicon', 'mlx', 'local llm', 'ollama'] }],
    notes: 'Chinese topic with English technical terms'
  }),
  query({
    id: 'zh-topic-03',
    query: '双语字幕学英语的方法',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['bilingual', 'subtitle', 'english learning', 'dual subtitle'] }],
    notes: 'Product-adjacent learning topic'
  }),
  query({
    id: 'zh-topic-04',
    query: '提示词注入怎么防御',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['prompt injection'] }],
    notes: 'Security topic from Chinese'
  }),
  query({
    id: 'zh-topic-05',
    query: '会计审计抽样和 AI',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['audit sampling', 'accounting', 'audit'] }],
    notes: 'Domain Chinese query'
  }),
  query({
    id: 'zh-topic-06',
    query: 'YouTube SABR 协议是什么',
    language: 'zh',
    intent: 'topic',
    media: ['youtube'],
    relevant: [{ kind: 'title_contains', terms: ['sabr'] }],
    notes: 'Keep SABR as entity'
  }),
  query({
    id: 'zh-topic-07',
    query: 'AI 编程代理长访谈',
    language: 'zh',
    intent: 'topic',
    duration: 'long',
    relevant: [{ kind: 'title_contains', terms: ['coding agent', 'ai agent'] }],
    notes: 'Long interview intent'
  }),
  query({
    id: 'zh-topic-08',
    query: '递归自我改进 RSI 和大模型',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['recursive self-improvement', 'recursive self improvement'] }],
    notes: 'Do not rewrite RSI into finance'
  }),
  query({
    id: 'zh-person-01',
    query: '找 Satya Nadella 最近参加的播客',
    language: 'zh',
    intent: 'person',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['satya nadella'] }, { kind: 'source_type', sourceType: 'podcast_episode' }],
    notes: 'Chinese wrapper around English person entity'
  }),
  query({
    id: 'zh-person-02',
    query: 'Karpathy 的课',
    language: 'zh',
    intent: 'person',
    media: ['youtube'],
    relevant: [{ kind: 'title_contains', terms: ['karpathy'] }],
    notes: 'Keep Latin name'
  }),
  query({
    id: 'zh-person-03',
    query: '李飞飞访谈',
    language: 'zh',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['fei-fei li', 'fei fei li', '李飞飞'] }],
    notes: 'Chinese name of a known researcher'
  }),
  query({
    id: 'zh-person-04',
    query: 'Sam Altman 最近上过哪些播客',
    language: 'zh',
    intent: 'person',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['sam altman'] }, { kind: 'source_type', sourceType: 'podcast_episode' }],
    notes: 'Person episode from Chinese'
  }),
  query({
    id: 'zh-person-05',
    query: 'Hinton 最近的演讲',
    language: 'zh',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['hinton'] }],
    notes: 'Surname-only person query'
  }),
  query({
    id: 'zh-person-06',
    query: 'Demis Hassabis 播客',
    language: 'zh',
    intent: 'person',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['demis hassabis'] }],
    notes: 'Keep full Latin name'
  }),
  query({
    id: 'zh-person-07',
    query: 'Dario Amodei 采访',
    language: 'zh',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['dario amodei'] }],
    notes: 'Person interview'
  }),
  query({
    id: 'zh-person-08',
    query: 'Yann LeCun 世界模型访谈',
    language: 'zh',
    intent: 'person',
    relevant: [{ kind: 'title_contains', terms: ['lecun', 'world model'] }],
    notes: 'Person plus Chinese topic'
  }),
  query({
    id: 'zh-show-01',
    query: '找 Acquired 关于 NVIDIA 的那期',
    language: 'zh',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'publisher_contains', terms: ['acquired'] }],
    preferred: [{ kind: 'title_contains', terms: ['nvidia'] }],
    notes: 'Do not mix unrelated NVIDIA shows'
  }),
  query({
    id: 'zh-show-02',
    query: 'Hard Fork 最近一期',
    language: 'zh',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['hard fork'] }],
    notes: 'Show title kept verbatim'
  }),
  query({
    id: 'zh-show-03',
    query: 'This American Life 节目',
    language: 'zh',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['this american life'] }],
    notes: 'English show title in Chinese session'
  }),
  query({
    id: 'zh-show-04',
    query: 'Planet Money 通胀',
    language: 'zh',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'publisher_contains', terms: ['planet money'] }],
    notes: 'Show plus Chinese topic word'
  }),
  query({
    id: 'zh-show-05',
    query: 'Lex Fridman 节目',
    language: 'zh',
    intent: 'show',
    relevant: [{ kind: 'publisher_contains', terms: ['lex fridman'] }],
    notes: 'Show not guest disambiguation'
  }),
  query({
    id: 'zh-show-06',
    query: 'ATP Accidental Tech Podcast',
    language: 'zh',
    intent: 'show',
    media: ['podcast'],
    relevant: [{ kind: 'title_contains', terms: ['accidental tech podcast'] }],
    notes: 'Abbreviation plus full title'
  }),
  query({
    id: 'zh-channel-01',
    query: '看 @ycombinator 最近谈 agent 的视频',
    language: 'zh',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['y combinator', 'ycombinator'] }],
    notes: 'Keep handle'
  }),
  query({
    id: 'zh-channel-02',
    query: '3Blue1Brown 线性代数',
    language: 'zh',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['3blue1brown'] }],
    notes: 'Channel plus Chinese math term'
  }),
  query({
    id: 'zh-channel-03',
    query: 'Fireship',
    language: 'zh',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['fireship'] }],
    notes: 'Bare channel name'
  }),
  query({
    id: 'zh-channel-04',
    query: 'Veritasium 科学视频',
    language: 'zh',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['veritasium'] }],
    notes: 'Science channel'
  }),
  query({
    id: 'zh-channel-05',
    query: 'Two Minute Papers 频道',
    language: 'zh',
    intent: 'channel',
    media: ['youtube'],
    relevant: [{ kind: 'publisher_contains', terms: ['two minute papers'] }],
    notes: 'English channel in Chinese UI'
  }),
  query({
    id: 'zh-recent-01',
    query: '最近半年关于 AI coding agent 的长访谈',
    language: 'zh',
    intent: 'recent',
    duration: 'long',
    publishedAfter: '2026-02-28T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['coding agent', 'ai agent'] }],
    notes: 'Relative time must become absolute 2026-02-28'
  }),
  query({
    id: 'zh-recent-02',
    query: '今年 OpenAI 发布会',
    language: 'zh',
    intent: 'recent',
    publishedAfter: '2026-01-01T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['openai'] }],
    notes: 'This-year filter'
  }),
  query({
    id: 'zh-recent-03',
    query: '最近 Claude 的更新讲解',
    language: 'zh',
    intent: 'recent',
    publishedAfter: '2026-02-28T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['claude', 'anthropic'] }],
    notes: 'Recency plus product name'
  }),
  query({
    id: 'zh-recent-04',
    query: '近一个月 AI 监管播客',
    language: 'zh',
    intent: 'recent',
    media: ['podcast'],
    publishedAfter: '2026-08-01T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['regulation', 'policy', 'ai act'] }],
    notes: 'Tight Chinese recency'
  }),
  query({
    id: 'zh-recent-05',
    query: '今年 WWDC 视频',
    language: 'zh',
    intent: 'recent',
    media: ['youtube'],
    publishedAfter: '2026-01-01T00:00:00Z',
    relevant: [{ kind: 'title_contains', terms: ['wwdc'] }],
    notes: 'Year-bounded WWDC'
  }),
  query({
    id: 'en-amb-01',
    query: 'apple',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['apple'] }],
    ambiguous: true,
    notes: 'Company vs fruit vs show name'
  }),
  query({
    id: 'en-amb-02',
    query: 'python',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['python'] }],
    ambiguous: true,
    notes: 'Language vs snake'
  }),
  query({
    id: 'en-amb-03',
    query: 'transformer',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['transformer'] }],
    ambiguous: true,
    notes: 'ML architecture vs toys vs electrical'
  }),
  query({
    id: 'en-amb-04',
    query: 'mercury',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['mercury'] }],
    ambiguous: true,
    notes: 'Planet vs bank vs element'
  }),
  query({
    id: 'en-amb-05',
    query: 'agent',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['agent'] }],
    ambiguous: true,
    notes: 'AI agent vs real-estate vs spy'
  }),
  query({
    id: 'zh-amb-01',
    query: '苹果',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['apple', '苹果'] }],
    ambiguous: true,
    notes: 'Chinese ambiguous brand/fruit'
  }),
  query({
    id: 'zh-amb-02',
    query: 'RSI',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['rsi', 'recursive', 'relative strength'] }],
    ambiguous: true,
    notes: 'Finance vs AI vs injury'
  }),
  query({
    id: 'zh-amb-03',
    query: 'canvas',
    language: 'zh',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['canvas'] }],
    ambiguous: true,
    notes: 'LMS vs HTML vs art'
  }),
  query({
    id: 'zh-amb-04',
    query: 'pilot',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['pilot'] }],
    ambiguous: true,
    notes: 'Episode pilot vs GitHub copilot vs aviation'
  }),
  query({
    id: 'zh-amb-05',
    query: 'harmony',
    language: 'en',
    intent: 'topic',
    relevant: [{ kind: 'title_contains', terms: ['harmony'] }],
    ambiguous: true,
    notes: 'Music vs OS vs AI model name'
  }),
  query({
    id: 'en-zero-01',
    query: 'asdkfjhaskdf qwerzxcv podcast',
    language: 'en',
    intent: 'topic',
    relevant: [],
    preferred: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Nonsense tokens should yield empty or filtered empty'
  }),
  query({
    id: 'en-zero-02',
    query: 'left-handed underwater basket weaving symposium 1823',
    language: 'en',
    intent: 'topic',
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'No public relevant content expected'
  }),
  query({
    id: 'en-zero-03',
    query: 'podcast about the municipal budget of a fictional city Zzyzx-9',
    language: 'en',
    intent: 'show',
    media: ['podcast'],
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Fictional show'
  }),
  query({
    id: 'en-zero-04',
    query: 'YouTube channel @not-a-real-handle-xyz123999',
    language: 'en',
    intent: 'channel',
    media: ['youtube'],
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Unknown handle'
  }),
  query({
    id: 'en-zero-05',
    query: 'interview with the emperor of Antarctica 2026',
    language: 'en',
    intent: 'person',
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Impossible person'
  }),
  query({
    id: 'zh-zero-01',
    query: '不存在的播客节目《量子织毛衣周报》',
    language: 'zh',
    intent: 'show',
    media: ['podcast'],
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Made-up Chinese show'
  }),
  query({
    id: 'zh-zero-02',
    query: '关于 1823 年左手水下编篮会议的访谈',
    language: 'zh',
    intent: 'topic',
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'No public relevant content'
  }),
  query({
    id: 'zh-zero-03',
    query: 'qwertyuiopasdfgh 最近视频',
    language: 'zh',
    intent: 'recent',
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Noise plus recency'
  }),
  query({
    id: 'zh-zero-04',
    query: '@zzzz-not-a-channel-999 的教程',
    language: 'zh',
    intent: 'channel',
    media: ['youtube'],
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Unknown channel'
  }),
  query({
    id: 'zh-zero-05',
    query: '虚构人物 Zzyzx Nadella IX 的播客',
    language: 'zh',
    intent: 'person',
    media: ['podcast'],
    relevant: [],
    expectQualifiedHit: false,
    expectZero: true,
    notes: 'Impossible person episode'
  })
];
