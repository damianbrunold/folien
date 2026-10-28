// A rich-text editor on a contenteditable element, driven by the model in
// richtext-model.js: every edit arrives as a beforeinput event, is applied
// to the model, and the paragraphs are drawn again with the slide renderer
// (renderRichText), so what you edit is exactly what the slide shows.
// Input the browser does not let us cancel (IME composition, some
// spelling corrections) is read back from the DOM and reconciled.
//
//   const ed = new RichTextEditor(el, {
//     text, base, design,       // rich text, box text style, design
//     beforeChange(typing),     // about to change (for undo); typing:
//                               // false for formatting, paste, cut
//     change(text),             // changed
//     selectionChange(),        // caret or selection moved
//     keydown(e),               // keys the editor does not handle
//     tab(e),                   // Tab: true if handled (else: list level)
//     pasteFiles(files),        // files were pasted (images, videos)
//   });
//   ed.focus(); ed.toggleMark("b"); ed.destroy();

import { renderRichText } from "./render.js";
import * as rt from "./richtext-model.js";

const CLIP_TYPE = "application/x-folien-richtext";

export class RichTextEditor {
  constructor(el, opts) {
    this.el = el;
    this.opts = opts;
    this.text = rt.ensureText(rt.clone(opts.text));
    this.pendingMarks = null; // marks for the next typed text (collapsed selection)
    this.composing = false;
    el.contentEditable = "true";
    el.spellcheck = true;
    el.classList.add("editing");
    this.handlers = {
      beforeinput: (e) => this.onBeforeInput(e),
      input: () => this.onInput(),
      compositionstart: () => (this.composing = true),
      compositionend: () => {
        this.composing = false;
        this.onInput();
      },
      keydown: (e) => this.onKeyDown(e),
      copy: (e) => this.onCopy(e, false),
      cut: (e) => this.onCopy(e, true),
      paste: (e) => this.onPaste(e),
      drop: (e) => e.preventDefault(),
    };
    for (const [k, h] of Object.entries(this.handlers)) el.addEventListener(k, h);
    this.selHandler = () => {
      if (this.el.contains(document.getSelection().anchorNode)) {
        this.lastSel = this.getSelection();
        // Pending marks belong to the caret position they were set at.
        if (this.pendingMarks) {
          const sel = this.getSelection();
          if (!this.pendingAt || !sel || rt.comparePos(sel.focus, this.pendingAt) !== 0 ||
              rt.comparePos(sel.anchor, this.pendingAt) !== 0) this.pendingMarks = null;
        }
        if (opts.selectionChange) opts.selectionChange();
      }
    };
    document.addEventListener("selectionchange", this.selHandler);
    this.render(null);
  }

  destroy() {
    for (const [k, h] of Object.entries(this.handlers)) this.el.removeEventListener(k, h);
    document.removeEventListener("selectionchange", this.selHandler);
    this.el.contentEditable = "false";
    this.el.classList.remove("editing");
  }

  focus(selectAll) {
    this.el.focus({ preventScroll: true });
    if (selectAll) this.setSelection(rt.startPos(), rt.endPos(this.text));
    else this.setSelection(rt.endPos(this.text), rt.endPos(this.text));
  }

  // --- drawing and the DOM <-> model mapping --------------------------

  render(sel) {
    this.el.replaceChildren();
    renderRichText(this.el, this.text, this.opts.base, this.opts.design, {});
    for (const m of this.el.querySelectorAll(".marker")) m.contentEditable = "false";
    if (sel) this.setSelection(sel.anchor, sel.focus);
  }

  paraDivs() {
    return Array.from(this.el.children).filter((c) => c.classList.contains("para"));
  }

  // Text nodes of a paragraph div that hold its characters (not markers).
  textNodes(div) {
    const out = [];
    const walk = document.createTreeWalker(div, NodeFilter.SHOW_TEXT, {
      acceptNode: (n) =>
        n.parentElement.closest(".marker") ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT,
    });
    while (walk.nextNode()) out.push(walk.currentNode);
    return out;
  }

  // Model position of a DOM point (node, offset) inside the editor.
  toPos(node, offset) {
    const divs = this.paraDivs();
    if (node === this.el) {
      if (offset >= divs.length) return rt.endPos(this.text);
      return { p: Math.max(0, divs.indexOf(this.el.children[offset])), o: 0 };
    }
    const elem = node.nodeType === Node.TEXT_NODE ? node.parentElement : node;
    const div = elem.closest(".para");
    const p = divs.indexOf(div);
    if (p < 0) return rt.endPos(this.text);
    let o = 0;
    if (node.nodeType === Node.TEXT_NODE && !elem.closest(".marker")) {
      for (const t of this.textNodes(div)) {
        if (t === node) return { p, o: o + offset };
        o += t.length;
      }
      return { p, o };
    }
    // An element point: count the characters before its offset-th child.
    const stop = node.childNodes[offset] || null;
    for (const t of this.textNodes(div)) {
      if (stop && (stop === t || stop.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING)) break;
      if (!stop && !node.contains(t) && node.compareDocumentPosition(t) & Node.DOCUMENT_POSITION_FOLLOWING) break;
      o += t.length;
    }
    return { p, o };
  }

  // DOM point of a model position.
  toDom(pos) {
    const div = this.paraDivs()[pos.p];
    if (!div) return [this.el, this.el.childNodes.length];
    let o = pos.o;
    const nodes = this.textNodes(div);
    for (const t of nodes) {
      if (o <= t.length) return [t, o];
      o -= t.length;
    }
    if (nodes.length) {
      const last = nodes[nodes.length - 1];
      return [last, last.length];
    }
    const br = div.querySelector("br");
    return [div, br ? Array.prototype.indexOf.call(div.childNodes, br) : div.childNodes.length];
  }

  getSelection() {
    const s = document.getSelection();
    if (!s.anchorNode || !this.el.contains(s.anchorNode)) return null;
    return {
      anchor: this.toPos(s.anchorNode, s.anchorOffset),
      focus: this.toPos(s.focusNode, s.focusOffset),
    };
  }

  setSelection(anchor, focus) {
    const [an, ao] = this.toDom(anchor);
    const [fn, fo] = this.toDom(focus || anchor);
    document.getSelection().setBaseAndExtent(an, ao, fn, fo);
  }

  // The selection as an ordered range [start, end]; the whole text if
  // the editor has no selection.
  range() {
    // When a toolbar control has the focus, the last selection counts.
    const sel = this.getSelection() || this.lastSel;
    if (!sel) return rt.wholeRange(this.text);
    return rt.orderRange(sel.anchor, sel.focus);
  }

  // --- applying changes -----------------------------------------------

  // Applies f (which changes this.text and returns the new selection or
  // position, or nothing to keep the selection). typing: the change is
  // part of typing (undo groups those).
  edit(f, typing) {
    const prev = this.getSelection() || this.lastSel;
    if (this.opts.beforeChange) this.opts.beforeChange(!!typing);
    const pos = f();
    this.el.focus({ preventScroll: true });
    this.render(pos ? { anchor: pos.anchor || pos, focus: pos.focus || pos } : prev);
    if (this.opts.change) this.opts.change(rt.clone(this.text));
  }

  replaceSelection(frag) {
    const [s, e] = this.range();
    this.edit(() => {
      let pos = rt.comparePos(s, e) === 0 ? s : rt.deleteRange(this.text, s, e);
      return rt.insertFragment(this.text, pos, frag);
    });
  }

  typeText(str) {
    const [s, e] = this.range();
    const marks = this.pendingMarks || rt.marksAt(this.text, s);
    this.pendingMarks = null;
    this.edit(() => {
      const pos = rt.comparePos(s, e) === 0 ? s : rt.deleteRange(this.text, s, e);
      return rt.insertText(this.text, pos, str, marks);
    }, true);
  }

  deleteBy(stepper) {
    const [s, e] = this.range();
    if (rt.comparePos(s, e) !== 0) {
      this.edit(() => rt.deleteRange(this.text, s, e), true);
      return;
    }
    const other = stepper(s);
    if (rt.comparePos(other, s) === 0) return;
    this.edit(() => rt.deleteRange(this.text, s, other), true);
  }

  onBeforeInput(e) {
    if (e.isComposing || e.inputType === "insertCompositionText") return; // reconciled on input
    e.preventDefault();
    const t = e.inputType;
    if (t === "insertText") {
      if (e.data) this.typeText(e.data);
    } else if (t === "insertReplacementText") {
      const data = e.data || (e.dataTransfer && e.dataTransfer.getData("text/plain")) || "";
      const ranges = e.getTargetRanges();
      if (ranges.length) {
        const r = ranges[0];
        const s = this.toPos(r.startContainer, r.startOffset);
        const en = this.toPos(r.endContainer, r.endOffset);
        this.edit(() => {
          const pos = rt.deleteRange(this.text, s, en);
          return rt.insertText(this.text, pos, data, rt.marksAt(this.text, pos));
        }, true);
      } else this.typeText(data);
    } else if (t === "insertParagraph") {
      const [s, e2] = this.range();
      this.edit(() => {
        const pos = rt.comparePos(s, e2) === 0 ? s : rt.deleteRange(this.text, s, e2);
        return rt.splitParagraph(this.text, pos);
      }, true);
    } else if (t === "insertLineBreak") {
      this.typeText("\n");
    } else if (t === "deleteContentBackward") {
      this.deleteBy((p) => rt.charStep(this.text, p, -1));
    } else if (t === "deleteContentForward") {
      this.deleteBy((p) => rt.charStep(this.text, p, 1));
    } else if (t === "deleteWordBackward") {
      this.deleteBy((p) => rt.wordBoundary(this.text, p, -1));
    } else if (t === "deleteWordForward") {
      this.deleteBy((p) => rt.wordBoundary(this.text, p, 1));
    } else if (t === "deleteSoftLineBackward" || t === "deleteHardLineBackward") {
      this.deleteBy((p) => ({ p: p.p, o: 0 }));
    } else if (t === "deleteSoftLineForward" || t === "deleteHardLineForward") {
      this.deleteBy((p) => ({ p: p.p, o: rt.paraText(this.text.paragraphs[p.p]).length }));
    } else if (t === "deleteByCut" || t === "deleteContent") {
      this.deleteBy((p) => p);
    } else if (t === "formatBold") this.toggleMark("b");
    else if (t === "formatItalic") this.toggleMark("i");
    else if (t === "formatUnderline") this.toggleMark("u");
    // Everything else (drag and drop, browser undo, other formatting) is
    // ignored: undo is the editor's own, formatting goes through the
    // toolbar.
  }

  onInput() {
    if (this.composing) return;
    // Whatever the browser changed by itself: read each paragraph back.
    const divs = this.paraDivs();
    if (divs.length !== this.text.paragraphs.length) {
      this.render(null);
      return;
    }
    const sel = this.getSelection();
    let changed = false;
    divs.forEach((div, i) => {
      const s = this.textNodes(div).map((t) => t.data).join("");
      if (s !== rt.paraText(this.text.paragraphs[i])) {
        if (!changed && this.opts.beforeChange) this.opts.beforeChange(true);
        rt.reconcileParagraph(this.text, i, s);
        changed = true;
      }
    });
    if (changed) {
      this.render(sel);
      if (this.opts.change) this.opts.change(rt.clone(this.text));
    }
  }

  onKeyDown(e) {
    const mod = e.ctrlKey || e.metaKey;
    if (e.key === "Tab") {
      e.preventDefault();
      if (this.opts.tab && this.opts.tab(e)) return;
      this.shiftLevel(e.shiftKey ? -1 : 1);
      return;
    }
    if (mod && !e.altKey && (e.key === "b" || e.key === "i" || e.key === "u")) {
      e.preventDefault();
      this.toggleMark(e.key);
      return;
    }
    if (mod && e.key.toLowerCase() === "a") {
      e.preventDefault();
      this.setSelection(rt.startPos(), rt.endPos(this.text));
      return;
    }
    if (this.opts.keydown) this.opts.keydown(e);
  }

  onCopy(e, cut) {
    const [s, en] = this.range();
    if (rt.comparePos(s, en) === 0) return;
    e.preventDefault();
    const frag = rt.sliceText(this.text, s, en);
    e.clipboardData.setData("text/plain", rt.plainText(frag));
    e.clipboardData.setData(CLIP_TYPE, JSON.stringify(frag));
    if (cut) this.edit(() => rt.deleteRange(this.text, s, en));
  }

  onPaste(e) {
    e.preventDefault();
    const dt = e.clipboardData;
    const files = Array.from(dt.files || []).concat(
      dt.files && dt.files.length
        ? []
        : Array.from(dt.items || []).filter((i) => i.kind === "file").map((i) => i.getAsFile()).filter(Boolean),
    );
    if (files.length && this.opts.pasteFiles) {
      this.opts.pasteFiles(files);
      return;
    }
    const rich = dt.getData(CLIP_TYPE);
    if (rich) {
      try {
        const frag = JSON.parse(rich);
        if (frag && Array.isArray(frag.paragraphs)) {
          this.replaceSelection(frag);
          return;
        }
      } catch (err) {
        // fall back to plain text
      }
    }
    const plain = dt.getData("text/plain");
    if (plain) {
      const [s] = this.range();
      this.replaceSelection(rt.fragmentFromPlain(plain, rt.marksAt(this.text, s)));
    }
  }

  // --- formatting (also used by the toolbar) ---------------------------

  isCollapsed() {
    const [s, e] = this.range();
    return rt.comparePos(s, e) === 0;
  }

  hasMark(key) {
    const [s, e] = this.range();
    if (this.pendingMarks && rt.comparePos(s, e) === 0) return !!this.pendingMarks[key];
    return rt.rangeHasMark(this.text, s, e, key);
  }

  markValue(key) {
    const [s, e] = this.range();
    if (this.pendingMarks && rt.comparePos(s, e) === 0) return this.pendingMarks[key];
    return rt.rangeMarkValue(this.text, s, e, key);
  }

  paragraphProp(key) {
    const [s] = this.range();
    return this.text.paragraphs[s.p][key];
  }

  setMark(key, value) {
    const sel = this.getSelection() || this.lastSel;
    const [s, e] = this.range();
    if (rt.comparePos(s, e) === 0) {
      // Nothing selected: the next typed text gets the mark.
      const m = Object.assign({}, this.pendingMarks || rt.marksAt(this.text, s));
      if (value === undefined || value === false) delete m[key];
      else m[key] = value;
      this.el.focus({ preventScroll: true });
      this.setSelection(s);
      this.pendingMarks = m;
      this.pendingAt = s;
      if (this.opts.selectionChange) this.opts.selectionChange();
      return;
    }
    this.edit(() => {
      rt.setMark(this.text, s, e, key, value);
      return sel;
    });
  }

  toggleMark(key) {
    this.setMark(key, this.hasMark(key) ? undefined : true);
  }

  setParagraphProps(props) {
    const sel = this.getSelection() || this.lastSel;
    const [s, e] = this.range();
    this.edit(() => {
      rt.setParagraphProps(this.text, s, e, props);
      return sel;
    });
  }

  shiftLevel(delta) {
    const sel = this.getSelection() || this.lastSel;
    const [s, e] = this.range();
    this.edit(() => {
      rt.shiftLevel(this.text, s, e, delta);
      return sel;
    });
  }
}
