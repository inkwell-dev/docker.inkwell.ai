// Capture mode only — run by `make capture-real` once the worker is back on the
// report's clock.
//
// While the worker ran on the real clock (it must, to embed the documents the AI
// figures upload), its analytics cron recomputed every "last 30 days" rollup for
// the real month — in which the seeded corpus has no reading at all — so the
// evaluation panels read zero. This queues the two aggregation jobs at once, so
// the worker, now on the report's clock again, rebuilds them before the
// evaluation page is photographed.
import { Queue } from 'bullmq';

const url = new URL(process.env.REDIS_URL);
const connection = {
  host: url.hostname,
  port: Number(url.port || 6379),
  password: decodeURIComponent(url.password) || undefined,
};
const queue = new Queue('analytics', { connection });
await queue.add('aggregate-article-metrics', {});
await queue.add('aggregate-writer-metrics', {});
await queue.close();
console.log('queued the article and writer rollups');
