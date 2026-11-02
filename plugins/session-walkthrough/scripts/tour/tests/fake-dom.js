'use strict';
// Minimal DOM shim for the overlay tests. It implements only what overlay.js
// and the tests use, and it counts listeners so cleanup can be proven.

class FakeEventTarget {
  constructor() {
    this.listeners = [];
  }
  addEventListener(type, fn, opts) {
    const capture = typeof opts === 'boolean' ? opts : !!(opts && opts.capture);
    if (!this.listeners.some((l) => l.type === type && l.fn === fn && l.capture === capture)) {
      this.listeners.push({ type, fn, capture });
    }
  }
  removeEventListener(type, fn, opts) {
    const capture = typeof opts === 'boolean' ? opts : !!(opts && opts.capture);
    this.listeners = this.listeners.filter((l) => !(l.type === type && l.fn === fn && l.capture === capture));
  }
  dispatchEvent(event) {
    if (!event.target) event.target = this;
    // Capture listeners on the document first, then the target, then bubble.
    const path = [];
    for (let node = this; node; node = node.parentNode) path.push(node);
    for (const node of path.slice().reverse()) {
      for (const l of node.listeners.filter((x) => x.type === event.type && x.capture)) l.fn.call(node, event);
      if (event._stopped) return !event.defaultPrevented;
    }
    for (const node of path) {
      if (node !== this && !event.bubbles) break;
      for (const l of node.listeners.filter((x) => x.type === event.type && !x.capture)) l.fn.call(node, event);
      if (event._stopped) break;
    }
    return !event.defaultPrevented;
  }
}

class FakeEvent {
  constructor(type, init) {
    this.type = type;
    this.bubbles = !!(init && init.bubbles);
    this.defaultPrevented = false;
    this.target = null;
    Object.assign(this, init || {});
  }
  preventDefault() { this.defaultPrevented = true; }
  stopPropagation() { this._stopped = true; }
  stopImmediatePropagation() { this._stopped = true; }
}

class FakeElement extends FakeEventTarget {
  constructor(tagName, ownerDocument) {
    super();
    this.tagName = String(tagName).toUpperCase();
    this.ownerDocument = ownerDocument;
    this.childNodes = [];
    this.parentNode = null;
    this.attributes = {};
    this.style = {};
    this.className = '';
    this.id = '';
    this._text = '';
    this.rect = { left: 0, top: 0, width: 0, height: 0 };
    this.value = '';
    this.disabled = false;
    this.hidden = false;
  }
  get firstChild() { return this.childNodes[0] || null; }
  get parentElement() { return this.parentNode instanceof FakeElement ? this.parentNode : null; }
  get isConnected() {
    let node = this;
    while (node.parentNode) node = node.parentNode;
    return node === this.ownerDocument;
  }
  get textContent() {
    return this._text + this.childNodes.map((c) => c.textContent).join('');
  }
  set textContent(value) {
    this.childNodes.forEach((c) => { c.parentNode = null; });
    this.childNodes = [];
    this._text = String(value);
  }
  appendChild(child) {
    if (child.parentNode) child.parentNode.removeChild(child);
    child.parentNode = this;
    this.childNodes.push(child);
    return child;
  }
  removeChild(child) {
    const at = this.childNodes.indexOf(child);
    if (at < 0) throw new Error('not a child');
    this.childNodes.splice(at, 1);
    child.parentNode = null;
    return child;
  }
  remove() { if (this.parentNode) this.parentNode.removeChild(this); }
  setAttribute(name, value) { this.attributes[name] = String(value); if (name === 'id') this.id = String(value); }
  getAttribute(name) { return name in this.attributes ? this.attributes[name] : null; }
  removeAttribute(name) { delete this.attributes[name]; }
  contains(node) {
    for (let n = node; n; n = n.parentNode) if (n === this) return true;
    return false;
  }
  getBoundingClientRect() {
    if (this.style.display === 'none' || this.hidden || !this.isConnected) {
      return { left: 0, top: 0, width: 0, height: 0, right: 0, bottom: 0 };
    }
    let r = typeof this.rect === 'function' ? this.rect() : this.rect;
    // Overlay nodes are positioned from their inline style.
    if (this.style.left !== undefined && this.style.top !== undefined && this.style.width !== undefined) {
      r = {
        left: parseFloat(this.style.left), top: parseFloat(this.style.top),
        width: parseFloat(this.style.width),
        height: this.style.height !== undefined ? parseFloat(this.style.height) : this.fixedHeight || 180
      };
    }
    return { ...r, right: r.left + r.width, bottom: r.top + r.height };
  }
  focus() { this.ownerDocument.activeElement = this; }
  click() { this.dispatchEvent(new FakeEvent('click', { bubbles: true })); }
  scrollIntoView() { this.scrolledIntoView = (this.scrolledIntoView || 0) + 1; }
  matches(selector) { return matches(this, selector); }
  querySelector(selector) { return this.querySelectorAll(selector)[0] || null; }
  querySelectorAll(selector) {
    const out = [];
    const walk = (node) => {
      for (const child of node.childNodes) {
        if (matches(child, selector)) out.push(child);
        walk(child);
      }
    };
    walk(this);
    return out;
  }
}

function matches(el, selector) {
  selector = selector.trim();
  if (selector.startsWith('#')) return el.id === selector.slice(1);
  if (selector.startsWith('.')) return String(el.className).split(/\s+/).includes(selector.slice(1));
  const attr = /^\[([\w-]+)(?:="([^"]*)")?\]$/.exec(selector);
  if (attr) return attr[2] === undefined ? attr[1] in el.attributes : el.attributes[attr[1]] === attr[2];
  if (/^[a-z0-9]+$/i.test(selector)) return el.tagName === selector.toUpperCase();
  throw new Error('fake DOM does not support selector ' + selector);
}

class FakeDocument extends FakeEventTarget {
  constructor() {
    super();
    this.ownerDocument = this;
    this.childNodes = [];
    this.parentNode = null;
    this.documentElement = new FakeElement('html', this);
    this.appendChildToSelf(this.documentElement);
    this.head = this.documentElement.appendChild(new FakeElement('head', this));
    this.body = this.documentElement.appendChild(new FakeElement('body', this));
    this.activeElement = this.body;
    this.isConnected = true;
  }
  appendChildToSelf(child) { child.parentNode = this; this.childNodes.push(child); }
  createElement(tag) { return new FakeElement(tag, this); }
  getElementById(id) { return this.documentElement.querySelectorAll('#' + id)[0] || null; }
  querySelector(selector) { return this.documentElement.querySelector(selector); }
  querySelectorAll(selector) { return this.documentElement.querySelectorAll(selector); }
  contains(node) { return this.documentElement.contains(node); }
}

class FakeStorage {
  constructor() { this.map = new Map(); }
  get length() { return this.map.size; }
  key(i) { return Array.from(this.map.keys())[i] || null; }
  getItem(k) { return this.map.has(k) ? this.map.get(k) : null; }
  setItem(k, v) { this.map.set(k, String(v)); }
  removeItem(k) { this.map.delete(k); }
  keys() { return Array.from(this.map.keys()); }
}

function createWindow(options) {
  options = options || {};
  const document = new FakeDocument();
  const win = new FakeEventTarget();
  win.document = document;
  win.innerWidth = options.width || 1280;
  win.innerHeight = options.height || 800;
  win.devicePixelRatio = options.devicePixelRatio || 1;
  win.sessionStorage = new FakeStorage();
  win.Event = FakeEvent;
  win.setTimeout = setTimeout;
  win.clearTimeout = clearTimeout;
  win.setInterval = setInterval;
  win.clearInterval = clearInterval;
  win.requestAnimationFrame = (fn) => setTimeout(fn, 0);
  win.scrolls = [];
  win.scrollBy = (opts) => { win.scrolls.push(opts); };
  return win;
}

// Every node, listener, storage key and timer global, for residue checks.
function snapshot(win) {
  const doc = win.document;
  const nodes = [];
  const walk = (node) => { nodes.push(node); node.childNodes.forEach(walk); };
  walk(doc.documentElement);
  return {
    nodeCount: nodes.length,
    windowListeners: win.listeners.length,
    documentListeners: doc.listeners.length,
    elementListeners: nodes.reduce((n, el) => n + el.listeners.length, 0),
    storageKeys: win.sessionStorage.keys().sort(),
    globals: Object.keys(win).filter((k) => !['listeners', 'scrolls'].includes(k)).sort(),
    setInterval: win.setInterval,
    setTimeout: win.setTimeout
  };
}

module.exports = { FakeElement, FakeDocument, FakeEvent, FakeStorage, createWindow, snapshot };
