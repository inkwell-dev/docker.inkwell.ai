// Capture mode only — preloaded into the api, the worker and the seed by
// docker-compose.capture.yml through NODE_OPTIONS.
//
// The stack runs under libfaketime with its clock moved back to the report's
// project window. MinIO cannot follow: it is a static Go binary, which reads the
// time without going through libc, so libfaketime has no hold on it. And S3
// signatures are dated — MinIO refuses any request whose date is more than 15
// minutes from its own clock. Left alone, every upload, presign and object read
// fails with "the difference between the request time and the server's time is
// too large".
//
// So the MinIO client alone is given the real time back. Its signatures take
// their date from three helpers, makeDateLong, makeDateShort and getScope; each
// is wrapped to add the libfaketime offset back before formatting. Nothing else
// in the process sees a different clock.
'use strict';

const offsetMs = -Number(process.env.FAKETIME || 0) * 1000;

if (offsetMs) {
  let helper;
  try {
    // By file path: the package's "exports" map refuses a deep import, and the
    // entry it does export (dist/main/minio.js) sits beside internal/.
    const entry = require.resolve('minio', { paths: [process.cwd()] });
    helper = require(require('node:path').join(require('node:path').dirname(entry), 'internal', 'helper.js'));
  } catch {
    helper = null; // a process that does not use MinIO (the web app) has nothing to patch
  }
  if (helper) {
    const real = (date) => new Date((date || new Date()).getTime() + offsetMs);
    const { makeDateLong, makeDateShort, getScope } = helper;
    helper.makeDateLong = (date) => makeDateLong(real(date));
    helper.makeDateShort = (date) => makeDateShort(real(date));
    // getScope formats its date through the module's OWN makeDateShort, which
    // the two lines above cannot reach — so it is shifted at its own door, or
    // the credential scope keeps the faked date and the signature mismatches.
    helper.getScope = (region, date, serviceName) => getScope(region, real(date), serviceName);
  }
}
