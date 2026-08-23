import { Innertube, UniversalCache, Platform, type Types } from 'youtubei.js';
import { generateWebPoToken } from '../src/sabr/webpo-helper.js';

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

const videoId = process.argv[2] ?? 'dQw4w9WgXcQ';

async function main(): Promise<void> {
  const innertube = await Innertube.create({ cache: new UniversalCache(false) });
  const visitorData = innertube.session.context.client.visitorData;
  console.log('visitorData length', visitorData?.length ?? 0);

  const poForVideo = await generateWebPoToken(videoId);
  console.log('poToken(video) length', poForVideo.poToken.length);

  try {
    const info = await innertube.getBasicInfo(videoId);
    console.log('getBasicInfo status', info.playability_status?.status);
    console.log('title', info.basic_info?.title);
    console.log('has serverAbr', Boolean(info.streaming_data?.server_abr_streaming_url));
    console.log(
      'adaptive count',
      info.streaming_data?.adaptive_formats?.length ?? 0
    );
  } catch (error) {
    console.error('getBasicInfo failed', error);
  }

  try {
    const withPo = await Innertube.create({
      cache: new UniversalCache(false),
      po_token: poForVideo.poToken,
      visitor_data: visitorData
    });
    const info2 = await withPo.getBasicInfo(videoId);
    console.log('with po_token status', info2.playability_status?.status);
    console.log('with po_token title', info2.basic_info?.title);
    console.log(
      'with po_token serverAbr',
      Boolean(info2.streaming_data?.server_abr_streaming_url)
    );
  } catch (error) {
    console.error('with po_token failed', error);
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
