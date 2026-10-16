/* Copyright 2026 GoldesqueMoON; SPDX-License-Identifier: Apache-2.0 */
/* Offline PDF watermark editor. All files remain in this browser session. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const state = { bytes: null, pdf: null, name: '', page: 1, image: null, renderTask: null, renderToken: 0 };
  const controls = ['kind','text','font','fontSize','textColor','imageFile','scale','opacity',
    'chroma','chromaColor','tolerance','positionMode','grid','margin','x','y','pageMode','pageSpec','zoom'];
  let timer = 0;
  const num = (id, fallback = 0) => Number.isFinite(Number($(id).value)) ? Number($(id).value) : fallback;
  const mm = value => value * 72 / 25.4;
  const status = (message, error = false) => { $('message').textContent = message; $('message').style.color = error ? '#b3261e' : '#657184'; };

  function pages() {
    if (!state.pdf) return new Set();
    if ($('pageMode').value === 'all') return new Set(Array.from({length: state.pdf.numPages}, (_, i) => i + 1));
    const value = $('pageSpec').value.trim().replaceAll('，', ',');
    if (!value) throw Error('请输入页码，例如 1,3,5-8');
    const result = new Set();
    for (const part of value.split(',')) {
      const token = part.trim();
      const match = /^(\d+)(?:\s*-\s*(\d+))?$/.exec(token);
      if (!match) throw Error(`无效页码：${token || '空项'}`);
      const start = Number(match[1]), end = match[2] ? Number(match[2]) : start;
      if (start < 1 || end > state.pdf.numPages || start > end) throw Error(`页码超出范围或顺序错误：${token}`);
      for (let i = start; i <= end; i++) result.add(i);
    }
    return result;
  }

  function updateMode() {
    const panel = document.querySelector('.controls');
    panel.classList.toggle('image', $('kind').value === 'image');
    panel.classList.toggle('absolute', $('positionMode').value === 'absolute');
    panel.classList.toggle('custom', $('pageMode').value === 'custom');
    updatePageStatus();
    queueRender();
  }

  function updatePageStatus() {
    if (!state.pdf) return;
    try {
      const selected = pages();
      $('pageStatus').textContent = `已选择 ${selected.size} / ${state.pdf.numPages} 页`;
      $('pageStatus').style.color = '#376347';
    } catch (error) {
      $('pageStatus').textContent = error.message;
      $('pageStatus').style.color = '#b3261e';
    }
  }

  async function loadPdf(file) {
    if (!file) return;
    status('正在打开 PDF…');
    try {
      const bytes = new Uint8Array(await file.arrayBuffer());
      // The worker script is loaded as a classic script above for file:// use.
      const pdf = await pdfjsLib.getDocument({data: bytes.slice(), disableWorker: true}).promise;
      if (!pdf.numPages) throw Error('PDF 没有页面');
      if (state.pdf) await state.pdf.destroy();
      state.bytes = bytes;
      state.pdf = pdf;
      state.name = file.name;
      state.page = 1;
      $('fileName').textContent = `${file.name} · ${pdf.numPages} 页`;
      $('save').disabled = false;
      $('empty').style.display = 'none';
      $('preview').style.display = 'block';
      updatePageStatus();
      await render();
      status(`已打开 ${file.name}`);
    } catch (error) {
      status(`打开失败：${error.message}`, true);
      alert(`无法打开 PDF：\n${error.message}`);
    }
  }

  function decodeImage(file) {
    return new Promise((resolve, reject) => {
      const url = URL.createObjectURL(file);
      const img = new Image();
      img.onload = () => { URL.revokeObjectURL(url); resolve(img); };
      img.onerror = () => { URL.revokeObjectURL(url); reject(Error('无法读取图片')); };
      img.src = url;
    });
  }

  function mark(widthPt, quality = 3) {
    const scale = Math.max(0.01, num('scale', 100) / 100);
    const canvas = document.createElement('canvas');
    const ctx = canvas.getContext('2d', {willReadFrequently: true});
    let w, h;
    if ($('kind').value === 'image') {
      if (!state.image) throw Error('请选择水印图片');
      w = Math.min(widthPt * 0.3 * scale, widthPt * 3);
      h = w * state.image.naturalHeight / state.image.naturalWidth;
      canvas.width = Math.max(1, Math.round(w * quality));
      canvas.height = Math.max(1, Math.round(h * quality));
      ctx.drawImage(state.image, 0, 0, canvas.width, canvas.height);
      if ($('chroma').checked) {
        const key = $('chromaColor').value;
        const rgb = [1,3,5].map(index => parseInt(key.slice(index,index + 2), 16));
        const tolerance = num('tolerance');
        const data = ctx.getImageData(0, 0, canvas.width, canvas.height);
        for (let i = 0; i < data.data.length; i += 4) {
          if (Math.max(Math.abs(data.data[i] - rgb[0]), Math.abs(data.data[i+1] - rgb[1]),
                       Math.abs(data.data[i+2] - rgb[2])) <= tolerance) data.data[i+3] = 0;
        }
        ctx.putImageData(data, 0, 0);
      }
    } else {
      const text = $('text').value;
      if (!text) throw Error('请输入水印文字');
      const size = Math.max(1, num('fontSize', 36) * scale * quality);
      const family = $('font').value.replaceAll('"', '\\"');
      ctx.font = `${size}px "${family}"`;
      const lines = text.split('\n');
      const lineHeight = size * 1.25;
      const pad = Math.ceil(4 * quality);
      canvas.width = Math.max(1, Math.ceil(Math.max(...lines.map(line => ctx.measureText(line).width)) + 2*pad));
      canvas.height = Math.max(1, Math.ceil(lineHeight * lines.length + 2*pad));
      ctx.font = `${size}px "${family}"`;
      ctx.textBaseline = 'top';
      ctx.fillStyle = $('textColor').value;
      lines.forEach((line, i) => ctx.fillText(line, pad, pad + i*lineHeight));
      w = canvas.width / quality;
      h = canvas.height / quality;
    }
    return {canvas, w, h};
  }

  function position(pageW, pageH, w, h) {
    if ($('positionMode').value === 'absolute') return {x: mm(num('x')), y: mm(num('y'))};
    const edge = mm(num('margin'));
    const index = num('grid');
    const x = [edge, (pageW-w)/2, pageW-w-edge][index % 3];
    const y = [edge, (pageH-h)/2, pageH-h-edge][Math.floor(index / 3)];
    return {x, y};
  }

  function queueRender() {
    clearTimeout(timer);
    timer = setTimeout(render, 150);
  }

  async function render() {
    if (!state.pdf) return;
    const token = ++state.renderToken;
    if (state.renderTask) {
      state.renderTask.cancel();
      try { await state.renderTask.promise; } catch (_) { /* expected cancellation */ }
      state.renderTask = null;
    }
    try {
      const page = await state.pdf.getPage(state.page);
      if (token !== state.renderToken) return;
      const unit = page.getViewport({scale: 1});
      const area = $('canvasArea');
      const zoom = $('zoom').value;
      const factor = zoom === 'fit' ? Math.min((area.clientWidth - 44)/unit.width,
        (area.clientHeight - 44)/unit.height, 2.5) : Number(zoom);
      const cssScale = Math.max(0.1, factor);
      const dpr = Math.min(window.devicePixelRatio || 1, 3);
      const canvas = $('preview');
      canvas.width = Math.ceil(unit.width * cssScale * dpr);
      canvas.height = Math.ceil(unit.height * cssScale * dpr);
      canvas.style.width = `${unit.width * cssScale}px`;
      canvas.style.height = `${unit.height * cssScale}px`;
      const ctx = canvas.getContext('2d');
      ctx.fillStyle = 'white';
      ctx.fillRect(0, 0, canvas.width, canvas.height);
      state.renderTask = page.render({canvasContext: ctx, viewport: page.getViewport({scale: cssScale*dpr})});
      await state.renderTask.promise;
      state.renderTask = null;
      if (token !== state.renderToken) return;
      try {
        if (pages().has(state.page)) {
          const item = mark(unit.width, Math.max(2, cssScale*dpr));
          const p = position(unit.width, unit.height, item.w, item.h);
          ctx.globalAlpha = num('opacity') / 100;
          ctx.drawImage(item.canvas, p.x*cssScale*dpr, p.y*cssScale*dpr,
            item.w*cssScale*dpr, item.h*cssScale*dpr);
          ctx.globalAlpha = 1;
        }
      } catch (error) { status(`预览提示：${error.message}`, true); }
      $('pageNumber').textContent = `${state.page} / ${state.pdf.numPages}`;
      $('prev').disabled = state.page <= 1;
      $('next').disabled = state.page >= state.pdf.numPages;
    } catch (error) {
      if (error.name !== 'RenderingCancelledException') status(`预览失败：${error.message}`, true);
    }
  }

  function imageBytes(canvas) {
    const base64 = canvas.toDataURL('image/png').split(',')[1];
    return Uint8Array.from(atob(base64), c => c.charCodeAt(0));
  }

  function visibleSize(page) {
    const angle = ((page.getRotation().angle % 360) + 360) % 360;
    const crop = page.getCropBox();
    return angle === 90 || angle === 270
      ? {width: crop.height, height: crop.width, angle, crop}
      : {width: crop.width, height: crop.height, angle, crop};
  }

  function drawMark(page, png, p, w, h, visible) {
    // Convert top-left visible-page coordinates into PDF's bottom-left system.
    const {x, y, width: W, height: H} = visible.crop;
    const a = visible.angle;
    const common = {width: w, height: h, opacity: num('opacity')/100};
    if (a === 0) page.drawImage(png, {...common, x:x+p.x, y:y+H-p.y-h});
    else if (a === 90) page.drawImage(png, {...common, x:x+p.y+h, y:y+p.x, rotate:PDFLib.degrees(90)});
    else if (a === 180) page.drawImage(png, {...common, x:x+W-p.x, y:y+p.y+h, rotate:PDFLib.degrees(180)});
    else if (a === 270) page.drawImage(png, {...common, x:x+W-p.y-h, y:y+H-p.x, rotate:PDFLib.degrees(270)});
    else throw Error(`不支持 ${a}° 页面旋转`);
  }

  async function exportPdf() {
    if (!state.bytes || !state.pdf) return;
    let selected;
    try { selected = pages(); mark((await state.pdf.getPage(1)).getViewport({scale:1}).width, 1); }
    catch (error) { alert(`请检查设置：\n${error.message}`); return; }
    $('save').disabled = true;
    status('正在导出，请稍候…');
    try {
      const pdf = await PDFLib.PDFDocument.load(state.bytes.slice(), {updateMetadata:false});
      let cache = new Map();
      for (let i = 0; i < pdf.getPageCount(); i++) {
        if (!selected.has(i+1)) continue;
        const page = pdf.getPage(i);
        const visible = visibleSize(page);
        const item = mark(visible.width, 3);
        const key = `${visible.width}:${item.w}:${item.h}`;
        let png = cache.get(key);
        if (!png) {
          png = await pdf.embedPng(imageBytes(item.canvas));
          cache.set(key, png);
        }
        const p = position(visible.width, visible.height, item.w, item.h);
        drawMark(page, png, p, item.w, item.h, visible);
        if (i % 5 === 0) { status(`正在处理第 ${i+1} / ${pdf.getPageCount()} 页…`); await new Promise(r => setTimeout(r, 0)); }
      }
      const bytes = await pdf.save();
      const blob = new Blob([bytes], {type:'application/pdf'});
      const url = URL.createObjectURL(blob);
      const link = document.createElement('a');
      link.href = url;
      link.download = state.name.replace(/\.pdf$/i, '') + '_watermarked.pdf';
      document.body.append(link);
      link.click();
      link.remove();
      setTimeout(() => URL.revokeObjectURL(url), 60000);
      status(`已导出：${link.download}（${selected.size} 页带水印）`);
    } catch (error) {
      status(`导出失败：${error.message}`, true);
      alert(`导出失败：\n${error.message}`);
    } finally { $('save').disabled = false; }
  }

  async function loadFonts() {
    if (!('queryLocalFonts' in window)) {
      alert('当前浏览器不支持读取本机字体。可使用下拉框中的常见系统字体；建议使用新版 Edge 或 Chrome。');
      return;
    }
    try {
      const fonts = await window.queryLocalFonts();
      const families = [...new Set(fonts.map(font => font.family))].sort((a,b) => a.localeCompare(b));
      if (!families.length) {
        status('浏览器未返回系统字体，已保留常见字体选项', true);
        return;
      }
      const selected = $('font').value;
      $('font').replaceChildren(...families.map(family => new Option(family, family)));
      if (families.includes(selected)) $('font').value = selected;
      status(`已读取 ${families.length} 种系统字体`);
      queueRender();
    } catch (error) { status(`读取字体失败：${error.message}`, true); }
  }

  $('pdfFile').addEventListener('change', event => loadPdf(event.target.files[0]));
  $('imageFile').addEventListener('change', async event => {
    try { state.image = await decodeImage(event.target.files[0]); queueRender(); }
    catch (error) { status(error.message, true); }
  });
  $('prev').addEventListener('click', () => { if (state.page > 1) { state.page--; render(); } });
  $('next').addEventListener('click', () => { if (state.page < state.pdf.numPages) { state.page++; render(); } });
  $('save').addEventListener('click', exportPdf);
  $('loadFonts').addEventListener('click', loadFonts);
  for (const id of controls) {
    if (id === 'imageFile') continue;
    $(id).addEventListener('input', () => {
      $('scaleValue').value = `${num('scale')}%`;
      $('opacityValue').value = `${num('opacity')}%`;
      $('toleranceValue').value = String(num('tolerance'));
      updatePageStatus();
      queueRender();
    });
    $(id).addEventListener('change', updateMode);
  }
  new ResizeObserver(() => { if ($('zoom').value === 'fit') queueRender(); }).observe($('canvasArea'));
  pdfjsLib.GlobalWorkerOptions.workerSrc = 'vendor/pdf.worker.min.js';
  updateMode();
})();
