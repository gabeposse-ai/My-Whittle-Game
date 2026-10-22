// Synthesised sound: filtered noise shaped by what the blade is doing, plus a quiet fire bed.
// Clean cuts with the grain are a smooth hiss; against the grain adds raspy crackle; harder
// woods sit higher and drier; the saw has a rhythmic rasp; sandpaper is a soft scrub.

import type { Feel } from './carver';

export class Sfx {
  private ctx: AudioContext | null = null;
  private master!: GainNode;
  private noise!: AudioBuffer;
  private cutGain!: GainNode;
  private cutFilter!: BiquadFilterNode;
  private sawGain!: GainNode;
  private sandGain!: GainNode;
  private crackleTimer = 0;
  private _muted = false;

  get muted() { return this._muted; }

  /** Must be called from a user gesture (iOS requirement). */
  start() {
    if (this.ctx) {
      if (this.ctx.state === 'suspended') void this.ctx.resume();
      return;
    }
    const Ctx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    if (!Ctx) return;
    const ctx = new Ctx();
    this.ctx = ctx;
    this.master = ctx.createGain();
    this.master.gain.value = this._muted ? 0 : 0.8;
    this.master.connect(ctx.destination);

    const len = ctx.sampleRate * 2;
    this.noise = ctx.createBuffer(1, len, ctx.sampleRate);
    const d = this.noise.getChannelData(0);
    for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;

    const loop = (filter: BiquadFilterNode, gain: GainNode) => {
      const src = ctx.createBufferSource();
      src.buffer = this.noise;
      src.loop = true;
      src.playbackRate.value = 0.7 + Math.random() * 0.6;
      src.connect(filter).connect(gain).connect(this.master);
      src.start();
    };

    this.cutFilter = ctx.createBiquadFilter();
    this.cutFilter.type = 'bandpass';
    this.cutFilter.frequency.value = 2600;
    this.cutFilter.Q.value = 0.9;
    this.cutGain = ctx.createGain();
    this.cutGain.gain.value = 0;
    loop(this.cutFilter, this.cutGain);

    const sawF = ctx.createBiquadFilter();
    sawF.type = 'bandpass';
    sawF.frequency.value = 1700;
    sawF.Q.value = 2.2;
    this.sawGain = ctx.createGain();
    this.sawGain.gain.value = 0;
    loop(sawF, this.sawGain);

    const sandF = ctx.createBiquadFilter();
    sandF.type = 'lowpass';
    sandF.frequency.value = 1500;
    this.sandGain = ctx.createGain();
    this.sandGain.gain.value = 0;
    loop(sandF, this.sandGain);

    // Fire bed: low rumble + occasional crackles.
    const rumbleF = ctx.createBiquadFilter();
    rumbleF.type = 'lowpass';
    rumbleF.frequency.value = 260;
    const rumbleG = ctx.createGain();
    rumbleG.gain.value = 0.05;
    loop(rumbleF, rumbleG);
    this.scheduleCrackle();
  }

  private scheduleCrackle() {
    const ctx = this.ctx;
    if (!ctx) return;
    window.clearTimeout(this.crackleTimer);
    this.crackleTimer = window.setTimeout(() => {
      this.click(0.02 + Math.random() * 0.05, 1800 + Math.random() * 3000, 0.004 + Math.random() * 0.01);
      this.scheduleCrackle();
    }, 80 + Math.random() * 900);
  }

  private click(vol: number, freq: number, dur: number) {
    const ctx = this.ctx;
    if (!ctx) return;
    const src = ctx.createBufferSource();
    src.buffer = this.noise;
    const f = ctx.createBiquadFilter();
    f.type = 'highpass';
    f.frequency.value = freq;
    const g = ctx.createGain();
    const t = ctx.currentTime;
    g.gain.setValueAtTime(vol, t);
    g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
    src.connect(f).connect(g).connect(this.master);
    src.start(t, Math.random() * 1.5, dur + 0.02);
  }

  /** Feed the current cutting activity: `speed` in inches/second, `amount` ~ removed volume. */
  cut(feel: Feel, speed: number, amount: number, hardness: number) {
    const ctx = this.ctx;
    if (!ctx) return;
    const t = ctx.currentTime;
    const level = Math.min(1, speed / 6) * Math.min(1, 0.3 + amount * 0.15);
    if (feel === 'saw') {
      this.sawGain.gain.setTargetAtTime(Math.min(0.5, speed / 20), t, 0.03);
      return;
    }
    if (feel === 'sand') {
      this.sandGain.gain.setTargetAtTime(Math.min(0.35, speed / 14), t, 0.04);
      return;
    }
    const base = feel === 'end' ? 3400 : feel === 'across' ? 3000 : 2300;
    this.cutFilter.frequency.setTargetAtTime(base * (1 + (1 - hardness) * 0.5), t, 0.05);
    this.cutFilter.Q.value = feel === 'with' ? 0.7 : 1.6;
    this.cutGain.gain.setTargetAtTime(0.5 * level, t, 0.025);
    if ((feel === 'against' || feel === 'across') && Math.random() < 0.5) this.click(0.18 * level, 2500, 0.012);
  }

  stopCut() {
    const ctx = this.ctx;
    if (!ctx) return;
    const t = ctx.currentTime;
    this.cutGain.gain.setTargetAtTime(0, t, 0.06);
    this.sawGain.gain.setTargetAtTime(0, t, 0.08);
    this.sandGain.gain.setTargetAtTime(0, t, 0.08);
  }

  /** A soft thud when an offcut lands. */
  thud() {
    this.click(0.25, 120, 0.12);
  }

  setMuted(m: boolean) {
    this._muted = m;
    if (this.ctx) this.master.gain.setTargetAtTime(m ? 0 : 0.8, this.ctx.currentTime, 0.05);
  }
}
