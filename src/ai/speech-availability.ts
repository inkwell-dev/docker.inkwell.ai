/**
 * Whether the configured key can synthesise speech — asked once per process.
 *
 * The Gemini free tier has granted this project a quota of zero before
 * (`ai.service.ts` records the history), and a key that answers 429 for the
 * day should not be asked again on every panel open. So the probe runs on the
 * first check, and both outcomes are remembered until the process restarts.
 * Concurrent first checks share one in-flight probe.
 *
 * The probe itself is injected: it calls `generateSpeech` in production, which
 * jest cannot load (ESM-only), and a stub in the spec.
 */
export class SpeechAvailability {
  private result: boolean | null = null;
  private inflight: Promise<boolean> | null = null;

  constructor(private readonly probe: (() => Promise<void>) | null) {}

  check(): Promise<boolean> {
    if (this.result !== null) return Promise.resolve(this.result);
    if (!this.probe) return Promise.resolve((this.result = false));
    if (!this.inflight) {
      this.inflight = this.probe()
        .then(() => true)
        .catch(() => false)
        .then((ok) => {
          this.result = ok;
          this.inflight = null;
          return ok;
        });
    }
    return this.inflight;
  }
}
