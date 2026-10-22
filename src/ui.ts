// DOM overlay: start screen, tool roll, top bar, hint toast, help and settings.

import type { Feel } from './carver';
import { SIZES, SPECIES, type Species } from './species';
import { TOOLS, type ToolId } from './tools';
import type { Prefs, SaveMeta } from './persist';

const ICON: Record<string, string> = {
  menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
  undo: '<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>',
  flip: '<path d="M7 4v16M7 4 4 7M7 4l3 3"/><path d="M17 20V4M17 20l-3-3M17 20l3-3"/>',
  sound: '<path d="M11 5 6 9H3v6h3l5 4V5z"/><path d="M15.5 8.5a5 5 0 0 1 0 7M18.5 5.5a9 9 0 0 1 0 13"/>',
  mute: '<path d="M11 5 6 9H3v6h3l5 4V5z"/><path d="m22 9-6 6M16 9l6 6"/>',
  gear: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.8-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1a1.7 1.7 0 0 0-1.1-1.5 1.7 1.7 0 0 0-1.8.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.8 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1a1.7 1.7 0 0 0 1.5-1.1 1.7 1.7 0 0 0-.3-1.8l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.8.3H9a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.8-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.8V9a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>',
  help: '<circle cx="12" cy="12" r="9"/><path d="M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6v.6M12 17h.01"/>',
};

// Tool icons drawn as little silhouettes (blade light, handle warm).
const TOOL_ICON: Record<ToolId, string> = {
  sloyd: '<path d="M4 20 15 9l2 2L6 22z" fill="#d8dde2"/><rect x="15" y="3" width="4" height="9" rx="2" transform="rotate(45 17 7.5)" fill="#b07a4a"/>',
  detail: '<path d="M7 19 13 13l1.5 1.5-6 5.5z" fill="#d8dde2"/><rect x="14" y="3.5" width="3.4" height="10" rx="1.7" transform="rotate(45 15.7 8.5)" fill="#b07a4a"/>',
  hook: '<path d="M4.5 16.5c-1.5-2 0-4.5 2.2-3.4l5.8-5.8 1.6 1.6-6.4 6.4" fill="none" stroke="#d8dde2" stroke-width="2"/><rect x="14" y="2.5" width="4" height="9" rx="2" transform="rotate(45 16 7)" fill="#b07a4a"/>',
  ugouge: '<path d="M4 20c0-1.8 1.4-3 3-3l7-7 1.8 1.8-7 7c0 1.6-1.2 3-3 3" fill="#d8dde2"/><ellipse cx="18" cy="6" rx="2.6" ry="4.4" transform="rotate(45 18 6)" fill="#b07a4a"/>',
  vgouge: '<path d="M3.5 20.5 6 15l8-8 2 2-8 8z" fill="#d8dde2"/><path d="M3.5 20.5 6 15l2.5 2.5z" fill="#6c7279"/><ellipse cx="18" cy="6" rx="2.6" ry="4.4" transform="rotate(45 18 6)" fill="#7a4e2c"/>',
  saw: '<path d="M2 15 14 3l3 3L5 18z" fill="#d8dde2"/><path d="M2 15l1-0.2 0.2 1 1-0.2 0.2 1 1-0.2 0.2 1" stroke="#6c7279" fill="none"/><rect x="15" y="12" width="3.6" height="9" rx="1.8" transform="rotate(-45 16.8 16.5)" fill="#7a4e2c"/>',
  sand: '<rect x="5" y="7" width="14" height="10" rx="1.5" fill="#c7a57a"/><path d="M7 9.5h10M7 12h10M7 14.5h10" stroke="#a88660" stroke-dasharray="1 1.4"/>',
};

const FEEL: Record<Feel, [string, string]> = {
  with: ['With the grain · clean curls', '#9bd27a'],
  across: ['Across the grain · short chips', '#e6c45c'],
  against: ['Against the grain · tear-out', '#e2775c'],
  end: ['End grain · slow and tough', '#d9a35c'],
  saw: ['Sawing', '#c9b49a'],
  sand: ['Sanding', '#c9b49a'],
};

const svg = (inner: string, vb = '0 0 24 24') => `<svg viewBox="${vb}" aria-hidden="true">${inner}</svg>`;

export function swatchCss(s: Species) {
  return `repeating-radial-gradient(circle at 50% 50%, ${s.heart} 0 3px, ${s.sap} 3px 6px), ${s.sap}`;
}

export interface UiHandlers {
  begin(species: string, size: string): void;
  resume(): void;
  tool(id: ToolId): void;
  undo(): void;
  flip(): void;
  mute(m: boolean): void;
  setVoxel(v: boolean): void;
  setQuality(q: Prefs['quality']): void;
  newLog(): void;
}

export class Ui {
  private root = document.getElementById('ui')!;
  private hintEl!: HTMLDivElement;
  private hintTimer = 0;
  private lastFeel: Feel | null = null;
  private toolBtns = new Map<ToolId, HTMLButtonElement>();
  private undoBtn!: HTMLButtonElement;
  private muteBtn!: HTMLButtonElement;
  private startEl!: HTMLDivElement;
  private helpEl!: HTMLDivElement;
  private settingsEl!: HTMLDivElement;
  private confirmEl!: HTMLDivElement;
  private loadingEl!: HTMLDivElement;
  private selSpecies = SPECIES[0].id;
  private selSize = SIZES[1].id;

  constructor(private h: UiHandlers, private prefs: Prefs) {
    this.buildHud();
    this.buildStart();
    this.buildHelp();
    this.buildSettings();
    this.buildConfirm();
    this.loadingEl = this.el('div', 'loading', 'Choosing a log…');
    this.loadingEl.hidden = true;
    this.root.append(this.loadingEl);
  }

  private el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', html = ''): HTMLElementTagNameMap[K] {
    const e = document.createElement(tag);
    if (cls) e.className = cls;
    if (html) e.innerHTML = html;
    return e;
  }

  private iconBtn(icon: string, title: string, on: () => void) {
    const b = this.el('button', 'icon-btn', svg(ICON[icon]));
    b.title = title;
    b.setAttribute('aria-label', title);
    b.addEventListener('click', on);
    return b;
  }

  private buildHud() {
    const hud = this.el('div', 'hud');
    const top = this.el('div', 'topbar');
    const left = this.el('div', 'group');
    left.append(
      this.iconBtn('menu', 'New log', () => (this.confirmEl.hidden = false)),
      (this.undoBtn = this.iconBtn('undo', 'Undo (Z)', () => this.h.undo())),
      this.iconBtn('flip', 'Switch grip end (F)', () => this.h.flip()),
    );
    const right = this.el('div', 'group');
    this.muteBtn = this.iconBtn(this.prefs.muted ? 'mute' : 'sound', 'Sound', () => {
      this.prefs.muted = !this.prefs.muted;
      this.muteBtn.innerHTML = svg(ICON[this.prefs.muted ? 'mute' : 'sound']);
      this.h.mute(this.prefs.muted);
    });
    right.append(
      this.muteBtn,
      this.iconBtn('gear', 'Settings', () => (this.settingsEl.hidden = false)),
      this.iconBtn('help', 'How to whittle', () => (this.helpEl.hidden = false)),
    );
    top.append(left, right);

    const roll = this.el('div', 'toolroll');
    for (const t of TOOLS) {
      const b = this.el('button', 'tool', svg(TOOL_ICON[t.id]) + `<span>${t.name.replace(' knife', '')}</span><span class="k">${t.key}</span>`);
      b.title = `${t.name} (${t.key}) — ${t.help}`;
      b.addEventListener('click', () => this.h.tool(t.id));
      this.toolBtns.set(t.id, b);
      roll.append(b);
    }
    this.hintEl = this.el('div', 'hint');
    hud.append(top, roll, this.hintEl);
    this.root.append(hud);
  }

  private buildStart() {
    const s = this.el('div', 'start');
    const inner = this.el('div', 'start-inner');
    inner.innerHTML = `<h1>Whittle</h1><p class="tag">Pull up a stool. Pick a log. Take your time.</p><h3>Wood</h3>`;
    const woods = this.el('div', 'woods');
    const woodBtns: HTMLButtonElement[] = [];
    for (const sp of SPECIES) {
      const b = this.el('button', 'wood' + (sp.id === this.selSpecies ? ' on' : ''),
        `<span class="swatch" style="background:${swatchCss(sp)}"></span><span><div class="nm">${sp.name}</div><div class="bl">${sp.blurb}</div></span>`);
      b.addEventListener('click', () => {
        this.selSpecies = sp.id;
        woodBtns.forEach((x) => x.classList.toggle('on', x === b));
      });
      woodBtns.push(b);
      woods.append(b);
    }
    inner.append(woods, Object.assign(this.el('h3'), { textContent: 'Log size' }));
    const sizes = this.el('div', 'sizes');
    const sizeBtns: HTMLButtonElement[] = [];
    for (const sz of SIZES) {
      const b = this.el('button', 'chip' + (sz.id === this.selSize ? ' on' : ''), sz.name);
      b.addEventListener('click', () => {
        this.selSize = sz.id;
        sizeBtns.forEach((x) => x.classList.toggle('on', x === b));
      });
      sizeBtns.push(b);
      sizes.append(b);
    }
    inner.append(sizes);
    const actions = this.el('div', 'actions');
    const begin = this.el('button', 'btn primary', 'Start carving');
    begin.addEventListener('click', () => this.h.begin(this.selSpecies, this.selSize));
    actions.append(begin);
    const resume = this.el('button', 'btn', 'Continue last carving');
    resume.dataset.role = 'resume';
    resume.addEventListener('click', () => this.h.resume());
    actions.append(resume);
    inner.append(actions);
    s.append(inner);
    this.startEl = s;
    this.root.append(s);
  }

  private modal(title: string, body: string, wire?: (card: HTMLDivElement) => void) {
    const scrim = this.el('div', 'scrim');
    const card = this.el('div', 'card', `<h2>${title}</h2>${body}`);
    const row = this.el('div', 'row');
    const close = this.el('button', 'btn primary', 'Done');
    close.addEventListener('click', () => (scrim.hidden = true));
    row.append(close);
    card.append(row);
    scrim.append(card);
    scrim.addEventListener('click', (e) => { if (e.target === scrim) scrim.hidden = true; });
    scrim.hidden = true;
    wire?.(card);
    this.root.append(scrim);
    return scrim;
  }

  private buildHelp() {
    this.helpEl = this.modal('How to whittle', `
      <p><b>Carve</b> by dragging across the wood. Each stroke takes an even layer; go over an area again to go deeper.</p>
      <p><b>Turn the log</b> by dragging off the wood, with two fingers, or with the right mouse button. <b>Pinch</b> or scroll to bring it closer.</p>
      <p><b>Read the grain.</b> Fibres run the length of the log.</p>
      <ul>
        <li>Cutting along them lifts long, clean curls.</li>
        <li>Cutting across them makes short chips and fuzz.</li>
        <li>On a slope, cut <b>downhill</b>, from high to low. Cutting uphill lets the blade follow the fibres in and tear them out.</li>
        <li>End grain is the toughest; take light cuts.</li>
      </ul>
      <p><b>Saw</b> by dragging back and forth along your line. Saw all the way through and the piece drops off. <b>Sandpaper</b> blends facets into smooth curves.</p>
      <p>Keys: <b>1–7</b> tools · <b>Z</b> undo · <b>F</b> switch grip · <b>H</b> hide interface.</p>`);
  }

  private buildSettings() {
    this.settingsEl = this.modal('Settings', `
      <div class="setting"><div>Look<small>Smooth surfaces or classic voxels</small></div>
        <div class="seg" data-k="look"><button data-v="smooth">Smooth</button><button data-v="voxel">Voxel</button></div></div>
      <div class="setting"><div>Detail<small>Applies to the next log</small></div>
        <div class="seg" data-k="quality"><button data-v="standard">Standard</button><button data-v="high">High</button></div></div>`,
    (card) => {
      const sync = () => {
        card.querySelectorAll<HTMLButtonElement>('[data-k="look"] button').forEach((b) =>
          b.classList.toggle('on', (b.dataset.v === 'voxel') === this.prefs.voxel));
        card.querySelectorAll<HTMLButtonElement>('[data-k="quality"] button').forEach((b) =>
          b.classList.toggle('on', b.dataset.v === this.prefs.quality));
      };
      card.querySelectorAll<HTMLButtonElement>('[data-k="look"] button').forEach((b) =>
        b.addEventListener('click', () => { this.prefs.voxel = b.dataset.v === 'voxel'; this.h.setVoxel(this.prefs.voxel); sync(); }));
      card.querySelectorAll<HTMLButtonElement>('[data-k="quality"] button').forEach((b) =>
        b.addEventListener('click', () => { this.prefs.quality = b.dataset.v as Prefs['quality']; this.h.setQuality(this.prefs.quality); sync(); }));
      sync();
    });
  }

  private buildConfirm() {
    this.confirmEl = this.modal('Start a new log?', `<p>Your current carving will be set aside. It stays saved until you start carving the new log.</p>`,
      (card) => {
        const row = card.querySelector('.row')!;
        const go = this.el('button', 'btn', 'Choose new log');
        go.addEventListener('click', () => { this.confirmEl.hidden = true; this.h.newLog(); });
        row.prepend(go);
        (row.lastChild as HTMLButtonElement).textContent = 'Keep carving';
      });
  }

  showStart(save: SaveMeta | null) {
    this.startEl.hidden = false;
    this.root.classList.add('at-start');
    const r = this.startEl.querySelector<HTMLButtonElement>('[data-role="resume"]')!;
    r.hidden = !save;
    if (save) {
      const sp = SPECIES.find((x) => x.id === save.species);
      r.textContent = `Continue ${sp ? sp.name.toLowerCase() : ''} carving`;
    }
  }

  hideStart() { this.startEl.hidden = true; this.root.classList.remove('at-start'); }
  setLoading(on: boolean) { this.loadingEl.hidden = !on; }

  setTool(id: ToolId) {
    for (const [k, b] of this.toolBtns) b.classList.toggle('active', k === id);
  }

  setUndo(can: boolean) { this.undoBtn.disabled = !can; }

  toggleHidden() { this.root.classList.toggle('hidden'); }

  feel(f: Feel) {
    window.clearTimeout(this.hintTimer);
    if (f !== this.lastFeel) {
      const [txt, col] = FEEL[f];
      this.hintEl.innerHTML = `<span class="dot" style="background:${col}"></span>${txt}`;
      this.lastFeel = f;
    }
    this.hintEl.classList.add('show');
    this.hintTimer = window.setTimeout(() => { this.hintEl.classList.remove('show'); this.lastFeel = null; }, 1400);
  }
}
