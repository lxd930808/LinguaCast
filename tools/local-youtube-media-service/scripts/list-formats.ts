import { Innertube, UniversalCache, Platform, type Types } from 'youtubei.js';

Platform.shim.eval = async (
  data: Types.BuildScriptResult,
  env: Record<string, Types.VMPrimative>
) => {
  const properties: string[] = [];
  if (env.n) properties.push(`n: exportedVars.nFunction("${env.n}")`);
  if (env.sig) properties.push(`sig: exportedVars.sigFunction("${env.sig}")`);
  const code = `${data.output}\nreturn { ${properties.join(', ')} }`;
  return new Function(code)();
};

const videoId = process.argv[2] ?? 'jNQXAC9IVRw';

async function main(): Promise<void> {
  const yt = await Innertube.create({ cache: new UniversalCache(false) });
  const info = await yt.getInfo(videoId);
  const formats = info.streaming_data?.adaptive_formats ?? [];
  for (const format of formats) {
    console.log(
      [
        format.itag,
        format.quality_label || format.audio_quality || '',
        format.mime_type,
        format.width && format.height ? `${format.width}x${format.height}` : '',
        format.bitrate
      ].join(' | ')
    );
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
