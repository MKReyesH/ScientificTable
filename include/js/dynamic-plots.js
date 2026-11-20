(() => {
  if (window.__quartoDynamicPlotsInit) return;
  window.__quartoDynamicPlotsInit = true;

  const PLOTLY_CDN = "https://cdn.plot.ly/plotly-2.35.2.min.js";
  const PLAY_INTERVAL_MS = 300;
  const TRACE_COLORWAY = [
    "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf"
  ];

  // Loads Plotly asynchronously so it downloads in parallel with MathJax
  function loadPlotly() {
    if (window.Plotly) return Promise.resolve();
    const store = (window.__quartoWidgetLibs = window.__quartoWidgetLibs || {});
    return (store.plotly = store.plotly || new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = PLOTLY_CDN;
      script.async = true;
      script.onload = resolve;
      script.onerror = () => reject(new Error(`Failed to load Plotly from ${PLOTLY_CDN}`));
      document.head.appendChild(script);
    }));
  }

  const hasMathDelimiters = (str) =>
    typeof str === "string" && /(\$\$?[\s\S]+?\$\$?|\\\([\s\S]+?\\\)|\\\[[\s\S]+?\\\])/.test(str);

  // Strips TeX commands to a compact sizing string so Plotly reserves accurate margin space
  const toSizingText = (str) => !str ? "" : String(str)
    .replace(/\\\(|\\\)|\\\[|\\\]|\$\$/g, "")
    .replace(/\$([^$]+)\$/g, "$1")
    .replace(/\\[a-zA-Z]+\{([^}]*)\}/g, "$1")
    .replace(/\\[a-zA-Z]+/g, "x")
    .replace(/[{}^_]/g, "");

  function resolveCurveColor(spec) {
    return spec.color || TRACE_COLORWAY[spec.colorIdx % TRACE_COLORWAY.length];
  }

  function applyTraceColor(trace, color) {
    if (trace.type === "scatter" || trace.type === "scatter3d") {
      trace.line = { ...(trace.line || {}), color };
      trace.marker = { ...(trace.marker || {}), color };
    } else if (trace.type === "contour") {
      trace.line = { ...(trace.line || {}), color };
    } else if (trace.type === "isosurface" || trace.type === "surface") {
      trace.colorscale = [[0, color], [1, color]];
    }
    return trace;
  }

  // Compact recursive-descent expression compiler (supports implicit multiplication, '^', and 'lhs = rhs')
  const MathExpr = (() => {
    const CONSTS = { pi: Math.PI, e: Math.E };
    const FUNCS = {
      sin: Math.sin, cos: Math.cos, tan: Math.tan, asin: Math.asin, acos: Math.acos, atan: Math.atan,
      sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh, exp: Math.exp, log: Math.log, ln: Math.log,
      log10: Math.log10, log2: Math.log2, sqrt: Math.sqrt, abs: Math.abs, sign: Math.sign,
      floor: Math.floor, ceil: Math.ceil, min: Math.min, max: Math.max
    };
    const TOKEN_RE = /\s*(?:((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|([a-zA-Z_]\w*)|([+\-*/^(),]))/y;

    function compileSingle(src) {
      const tokens = [];
      TOKEN_RE.lastIndex = 0;
      while (TOKEN_RE.lastIndex < src.length) {
        const m = TOKEN_RE.exec(src);
        if (!m) break;
        if (m[1] !== undefined) tokens.push({ t: "num", v: Number(m[1]) });
        else if (m[2] !== undefined) tokens.push({ t: "id", v: m[2] });
        else if (m[3] !== undefined) tokens.push({ t: "op", v: m[3] });
      }

      let pos = 0;
      const peek = () => tokens[pos];
      const next = () => tokens[pos++];
      const isOp = (tok, v) => tok && tok.t === "op" && tok.v === v;

      const parseAdd = () => {
        let lhs = parseMul();
        while (isOp(peek(), "+") || isOp(peek(), "-")) {
          const op = next().v, rhs = parseMul(), prev = lhs;
          lhs = op === "+" ? (e) => prev(e) + rhs(e) : (e) => prev(e) - rhs(e);
        }
        return lhs;
      };

      const parseMul = () => {
        let lhs = parseUnary();
        while (true) {
          if (isOp(peek(), "*") || isOp(peek(), "/")) {
            const op = next().v, rhs = parseUnary(), prev = lhs;
            lhs = op === "*" ? (e) => prev(e) * rhs(e) : (e) => prev(e) / rhs(e);
          } else if (peek() && (peek().t === "id" || isOp(peek(), "("))) {
            const rhs = parseUnary(), prev = lhs;
            lhs = (e) => prev(e) * rhs(e);
          } else break;
        }
        return lhs;
      };

      const parseUnary = () => {
        if (isOp(peek(), "+")) { next(); return parseUnary(); }
        if (isOp(peek(), "-")) { next(); const a = parseUnary(); return (e) => -a(e); }
        return parsePow();
      };

      const parsePow = () => {
        const base = parseAtom();
        if (isOp(peek(), "^")) { next(); const exp = parseUnary(); return (e) => Math.pow(base(e), exp(e)); }
        return base;
      };

      const parseAtom = () => {
        const tok = next();
        if (!tok) return () => NaN;
        if (tok.t === "num") return () => tok.v;
        if (isOp(tok, "(")) {
          const inner = parseAdd();
          next();
          return inner;
        }
        const name = tok.v;
        if (FUNCS[name]) {
          next(); // '('
          const args = [];
          if (!isOp(peek(), ")")) {
            args.push(parseAdd());
            while (isOp(peek(), ",")) { next(); args.push(parseAdd()); }
          }
          next(); // ')'
          const fn = FUNCS[name];
          return (e) => fn(...args.map((a) => a(e)));
        }
        if (name in CONSTS) return () => CONSTS[name];
        return (e) => e[name];
      };

      return parseAdd();
    }

    return {
      compile(rawExpr) {
        const parts = rawExpr.split("=");
        if (parts.length === 2) {
          const lhs = compileSingle(parts[0]), rhs = compileSingle(parts[1]);
          return (env) => lhs(env) - rhs(env);
        }
        return compileSingle(parts[0]);
      }
    };
  })();

  // Domain sampling and axis range resolution utilities
  const Domain = {
    sampleAxis([min, max], count, scale = "linear") {
      const pts = new Array(count);
      if (scale === "log") {
        const l0 = Math.log10(min), step = (Math.log10(max) - l0) / (count - 1);
        for (let i = 0; i < count; i++) pts[i] = Math.pow(10, l0 + i * step);
      } else {
        const step = (max - min) / (count - 1);
        for (let i = 0; i < count; i++) pts[i] = min + i * step;
      }
      return pts;
    },

    extent(values, positiveOnly = false) {
      let min = Infinity, max = -Infinity;
      for (const v of values) {
        if (!Number.isFinite(v) || (positiveOnly && v <= 0)) continue;
        if (v < min) min = v;
        if (v > max) max = v;
      }
      return min <= max ? [min, max] : null;
    },

    resolveAxisRange(plotRange, defRange, dataExtent, scale) {
      const r = plotRange || defRange || dataExtent;
      if (!r) return scale === "log" ? [0.1, 100] : [-10, 10];
      if (r[0] === r[1]) return scale === "log" ? [r[0] * 0.5, r[0] * 2] : [r[0] - 1, r[0] + 1];
      return r;
    }
  };

  // Compiles and evaluates analytical expressions (2D/3D explicit and 2D/3D implicit)
  const FunctionBuilder = {
    prepare(def) {
      return { ...def, rawLabel: def.label, fn: MathExpr.compile(def.expr) };
    },

    evaluate(spec, { xrange, yrange, zrange }, scales) {
      const { subtype, fn, mode, smooth } = spec;
      const name = toSizingText(spec.rawLabel);
      const env = { x: 0, y: 0, z: 0 };
      const evalGrid = (xs, ys) => ys.map((y) => {
        env.y = y;
        return xs.map((x) => { env.x = x; const v = fn(env); return Number.isFinite(v) ? v : null; });
      });

      if (subtype === "2d-explicit") {
        const xs = Domain.sampleAxis(xrange, spec.points || 100, scales.xscale);
        const ys = xs.map((x) => { env.x = x; const v = fn(env); return Number.isFinite(v) ? v : null; });
        return {
          type: "scatter", name, x: xs, y: ys, mode, connectgaps: false,
          line: { shape: (smooth ?? true) ? "spline" : "linear" }
        };
      }

      if (subtype === "2d-implicit" || subtype === "3d-explicit") {
        const n = spec.points || 60;
        const xs = Domain.sampleAxis(xrange, n, scales.xscale);
        const ys = Domain.sampleAxis(yrange, n, scales.yscale);
        const z = evalGrid(xs, ys);
        return subtype === "2d-implicit"
          ? { type: "contour", name, x: xs, y: ys, z, contours: { coloring: "lines", start: 0, end: 0, size: 1 }, line: { width: 2.5 }, showscale: false }
          : { type: "surface", name, x: xs, y: ys, z, showscale: false };
      }

      const n = spec.points || 25;
      const xs = Domain.sampleAxis(xrange, n, scales.xscale);
      const ys = Domain.sampleAxis(yrange, n, scales.yscale);
      const zs = Domain.sampleAxis(zrange, n, scales.zscale);
      const flatX = [], flatY = [], flatZ = [], value = [];
      for (const x of xs) {
        env.x = x;
        for (const y of ys) {
          env.y = y;
          for (const z of zs) {
            env.z = z;
            const v = fn(env);
            flatX.push(x); flatY.push(y); flatZ.push(z);
            value.push(Number.isFinite(v) ? v : NaN);
          }
        }
      }
      return {
        type: "isosurface", name, x: flatX, y: flatY, z: flatZ, value,
        isomin: 0, isomax: 0, surface: { count: 1 },
        caps: { x: { show: false }, y: { show: false }, z: { show: false } }, showscale: false
      };
    }
  };

  // Compiles tabular file rows into static 2D/3D traces or slider-driven parameter sweeps
  const FileBuilder = {
    prepare(def) {
      const env = {};
      const rowEnv = (r) => { for (let i = 0; i < r.length; i++) env[`c${i}`] = r[i]; return env; };
      const evalCol = (fn) => def.rows.map((r) => { const v = fn(rowEnv(r)); return Number.isFinite(v) ? v : null; });

      const xs = evalCol(MathExpr.compile(def.x));
      const name = toSizingText(def.label);
      const line = { shape: def.smooth ? "spline" : "linear" };

      if (def.isSweep) {
        const tFn = def.transform ? MathExpr.compile(def.transform) : null;
        const ySeries = def.sweepCols.map((colIdx) =>
          def.rows.map((r) => {
            const rawY = r[colIdx];
            if (!tFn) return rawY;
            rowEnv(r).y = rawY;
            const v = tFn(env);
            return Number.isFinite(v) ? v : null;
          })
        );
        return {
          ...def, rawLabel: def.label, rawParamLabel: def.paramLabel,
          xs, ys: ySeries.flat(), zs: null,
          paramLabel: toSizingText(def.paramLabel),
          initialTrace: { type: "scatter", name, x: xs, y: ySeries[0], mode: def.mode, line },
          frames: ySeries.map((y, idx) => ({ name: String(idx), traces: [0], data: [{ x: xs, y }] }))
        };
      }

      const ys = evalCol(MathExpr.compile(def.y));
      if (def.z) {
        const zs = evalCol(MathExpr.compile(def.z));
        return {
          ...def, rawLabel: def.label, xs, ys, zs,
          trace: { type: "scatter3d", name, x: xs, y: ys, z: zs, mode: def.mode, marker: { size: 3.5 } }
        };
      }

      return {
        ...def, rawLabel: def.label, xs, ys, zs: null,
        trace: { type: "scatter", name, x: xs, y: ys, mode: def.mode, line }
      };
    }
  };

  // Synchronizes Plotly axis, font, and control colors with active Bootstrap CSS variables
  const ThemeSync = {
    getPalette() {
      const s = getComputedStyle(document.body);
      const textColor = s.getPropertyValue("--bs-body-color").trim() || "#212529";
      const borderColor = s.getPropertyValue("--bs-border-color").trim() || "#dee2e6";
      const bgColor = s.getPropertyValue("--bs-body-bg").trim() || "#ffffff";
      return { textColor, borderColor, bgColor, gridColor: `color-mix(in srgb, ${borderColor} 55%, transparent)` };
    },

    buildAxisTheme(titleText, scale, range, p) {
      const axis = {
        type: scale, automargin: true, color: p.textColor, gridcolor: p.gridColor,
        linecolor: p.borderColor, zerolinecolor: p.borderColor, tickfont: { color: p.textColor }
      };
      if (titleText) axis.title = { text: toSizingText(titleText), font: { color: p.textColor }, standoff: 12 };
      if (range) {
        axis.range = scale === "log" ? [Math.log10(range[0]), Math.log10(range[1])] : range;
        axis.autorange = false;
      }
      return axis;
    },

    getThemeRelayout(hasSlider, hasPlayButton, is3d) {
      const p = this.getPalette();
      const u = {
        "font.color": p.textColor,
        "hoverlabel.bgcolor": p.bgColor,
        "hoverlabel.bordercolor": p.borderColor,
        "hoverlabel.font.color": p.textColor
      };
      const prefix = is3d ? "scene." : "";
      for (const ax of (is3d ? ["xaxis", "yaxis", "zaxis"] : ["xaxis", "yaxis"])) {
        Object.assign(u, {
          [`${prefix}${ax}.color`]: p.textColor,
          [`${prefix}${ax}.tickfont.color`]: p.textColor,
          [`${prefix}${ax}.title.font.color`]: p.textColor,
          [`${prefix}${ax}.gridcolor`]: p.gridColor,
          [`${prefix}${ax}.linecolor`]: p.borderColor,
          ...(is3d
            ? { [`${prefix}${ax}.backgroundcolor`]: "rgba(0,0,0,0)" }
            : { [`${prefix}${ax}.zerolinecolor`]: p.borderColor })
        });
      }
      if (hasSlider) {
        Object.assign(u, {
          "sliders[0].font.color": p.textColor,
          "sliders[0].currentvalue.font.color": p.textColor,
          "sliders[0].bordercolor": p.borderColor,
          "sliders[0].bgcolor": p.bgColor
        });
      }
      if (hasPlayButton) {
        Object.assign(u, {
          "updatemenus[0].font.color": p.textColor,
          "updatemenus[0].bordercolor": p.borderColor,
          "updatemenus[0].bgcolor": p.bgColor
        });
      }
      return u;
    }
  };

  class DynamicPlotController {
    constructor(wrapEl, registry) {
      this.wrapEl = wrapEl;
      this.cfg = JSON.parse(wrapEl.dataset.plotConfig || "{}");

      const rawSpecs = this.cfg.curves.map((id, colorIdx) => ({ ...registry.get(id), colorIdx }));
      const sweep = rawSpecs.find((s) => s.isSweep);
      this.is3d = rawSpecs[0].dim === "3d";
      this.hasSlider = Boolean(sweep);
      this.specs = sweep ? [sweep, ...rawSpecs.filter((s) => !s.isSweep)] : rawSpecs;
      this.hasPlayButton = Boolean(sweep && this.cfg.play);
      this.traceVisible = this.specs.map(() => true);
      this.activeStepIdx = 0;
      this.isPlaying = false;
      this.playTimer = null;
      this.isAdvancingFrame = false;
      this.isResampling = false;

      this.mount();
    }

    computeInitialDomains() {
      const files = this.specs.filter((s) => s.kind === "file");
      const fns = this.specs.filter((s) => s.kind === "function");
      const fileX = Domain.extent(files.flatMap((s) => s.xs), this.cfg.xscale === "log");
      const fileY = Domain.extent(files.flatMap((s) => s.ys), this.cfg.yscale === "log");
      const fileZ = this.is3d ? Domain.extent(files.flatMap((s) => s.zs || []), this.cfg.zscale === "log") : null;

      return {
        xrange: Domain.resolveAxisRange(this.cfg.xrange, fns.find((s) => s.xrange)?.xrange, fileX, this.cfg.xscale),
        yrange: Domain.resolveAxisRange(this.cfg.yrange, fns.find((s) => s.yrange)?.yrange, fileY, this.cfg.yscale),
        zrange: this.is3d ? Domain.resolveAxisRange(this.cfg.zrange, fns.find((s) => s.zrange)?.zrange, fileZ, this.cfg.zscale) : null
      };
    }

    buildTraces(domains) {
      const scales = { xscale: this.cfg.xscale, yscale: this.cfg.yscale, zscale: this.cfg.zscale };
      return this.specs.map((spec, idx) => {
        const trace = spec.kind === "function"
          ? FunctionBuilder.evaluate(spec, domains, scales)
          : spec.isSweep
            ? { ...spec.initialTrace, ...(spec.frames[this.activeStepIdx]?.data[0] || {}) }
            : { ...spec.trace };
        applyTraceColor(trace, resolveCurveColor(spec));
        trace.visible = this.traceVisible[idx] ? true : "legendonly";
        return trace;
      });
    }

    buildSidebar(bodyEl) {
      if (this.cfg.legend === false) return;

      const wrap = document.createElement("div");
      wrap.className = "dynamic-plot-sidebar-wrap";

      const toggleBtn = document.createElement("button");
      toggleBtn.type = "button";
      toggleBtn.className = "dynamic-plot-sidebar-toggle";
      toggleBtn.title = "Toggle legend";
      toggleBtn.setAttribute("aria-expanded", "true");
      toggleBtn.addEventListener("click", () => {
        const collapsed = wrap.classList.toggle("is-collapsed");
        toggleBtn.setAttribute("aria-expanded", String(!collapsed));
      });

      const sidebar = document.createElement("div");
      sidebar.className = "dynamic-plot-sidebar";

      this.specs.forEach((spec, idx) => {
        const color = resolveCurveColor(spec);
        const item = document.createElement("label");
        item.className = "dynamic-plot-curve-toggle";

        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.className = "form-check-input dynamic-plot-curve-checkbox";
        checkbox.checked = true;
        checkbox.style.accentColor = color;
        checkbox.addEventListener("change", async () => {
          this.traceVisible[idx] = checkbox.checked;
          item.classList.toggle("is-hidden", !checkbox.checked);
          await Plotly.restyle(this.canvas, { visible: checkbox.checked ? true : "legendonly" }, [idx]);
          this.syncMathOverlays();
        });

        const swatch = document.createElement("span");
        swatch.className = "dynamic-plot-swatch";
        swatch.dataset.mode = spec.mode;
        swatch.style.setProperty("--swatch-color", color);

        const labelSpan = document.createElement("span");
        labelSpan.className = "dynamic-plot-curve-label";
        if (hasMathDelimiters(spec.rawLabel)) labelSpan.innerHTML = MathRenderer.get(spec.rawLabel);
        else labelSpan.textContent = spec.rawLabel;

        item.append(checkbox, swatch, labelSpan);
        sidebar.appendChild(item);
      });

      wrap.append(toggleBtn, sidebar);
      bodyEl.appendChild(wrap);
    }

    buildLayout(palette) {
      const layout = {
        height: this.cfg.height,
        margin: this.is3d ? { l: 10, r: 10, t: 25, b: 10 } : { l: 55, r: 20, t: 25, b: 50 },
        paper_bgcolor: "rgba(0,0,0,0)",
        plot_bgcolor: "rgba(0,0,0,0)",
        colorway: TRACE_COLORWAY,
        font: { color: palette.textColor },
        showlegend: false,
        hoverlabel: { bgcolor: palette.bgColor, bordercolor: palette.borderColor, font: { color: palette.textColor } }
      };

      if (this.is3d) {
        layout.scene = {
          xaxis: ThemeSync.buildAxisTheme(this.cfg.xlabel || "x", this.cfg.xscale, this.cfg.xrange, palette),
          yaxis: ThemeSync.buildAxisTheme(this.cfg.ylabel || "y", this.cfg.yscale, this.cfg.yrange, palette),
          zaxis: ThemeSync.buildAxisTheme(this.cfg.zlabel || "z", this.cfg.zscale, this.cfg.zrange, palette)
        };
      } else {
        const yRange = this.hasSlider ? (this.cfg.yrange || this.homeDomains.yrange) : this.cfg.yrange;
        layout.xaxis = ThemeSync.buildAxisTheme(this.cfg.xlabel, this.cfg.xscale, this.cfg.xrange, palette);
        layout.yaxis = ThemeSync.buildAxisTheme(this.cfg.ylabel, this.cfg.yscale, yRange, palette);
      }

      if (this.hasSlider) {
        const sweepSpec = this.specs[0];
        const sliderPadT = this.cfg.xlabel ? 62 : 32;
        const sliderX = this.hasPlayButton ? 0.085 : 0.0;
        layout.margin.b = sliderPadT + 68;

        layout.sliders = [{
          active: 0,
          pad: { t: sliderPadT, b: 6 },
          len: 1.0 - sliderX,
          x: sliderX,
          currentvalue: {
            visible: true, xanchor: "left",
            prefix: `${sweepSpec.paramLabel}: `,
            font: { color: palette.textColor, size: 13 }
          },
          font: { color: palette.textColor },
          bordercolor: palette.borderColor,
          bgcolor: palette.bgColor,
          steps: sweepSpec.params.map((label, idx) => ({
            label, method: "animate",
            args: [[String(idx)], { mode: "immediate", transition: { duration: 0 }, frame: { duration: 0, redraw: false } }]
          }))
        }];

        if (this.hasPlayButton) {
          layout.updatemenus = [{
            type: "buttons", showactive: false, x: 0.0, y: 0.0,
            xanchor: "left", yanchor: "top", direction: "left",
            pad: { t: sliderPadT - 5, b: 4 },
            font: { color: palette.textColor, size: 11 },
            bgcolor: palette.bgColor,
            bordercolor: palette.borderColor,
            buttons: [{
              label: "\u25B6",
              method: "skip",
              execute: false
            }]
          }];
        }
      }
      return layout;
    }

    advanceToFrame(idx) {
      this.activeStepIdx = idx;
      this.isAdvancingFrame = true;
      Plotly.animate(this.canvas, [String(idx)], {
        mode: "immediate",
        transition: { duration: 0 },
        frame: { duration: 0, redraw: false }
      }).finally(() => {
        this.isAdvancingFrame = false;
      });
      this.syncMathOverlays();
    }

    setPlayLabel(playing) {
      if (!this.hasPlayButton || this.isPlaying === playing) return;
      this.isPlaying = playing;
      Plotly.relayout(this.canvas, {
        "updatemenus[0].buttons[0].label": playing ? "\u275A\u275A" : "\u25B6"
      });
    }

    startPlay() {
      if (this.isPlaying || !this.hasSlider) return;
      const total = this.specs[0].params.length;
      if (total < 2) return;

      this.setPlayLabel(true);
      if (this.activeStepIdx >= total - 1) {
        this.advanceToFrame(0);
      }
      this.playTimer = setInterval(() => {
        if (!this.wrapEl.isConnected) {
          this.stopPlay();
          return;
        }
        this.advanceToFrame((this.activeStepIdx + 1) % total);
      }, PLAY_INTERVAL_MS);
    }

    stopPlay() {
      if (this.playTimer !== null) {
        clearInterval(this.playTimer);
        this.playTimer = null;
      }
      this.setPlayLabel(false);
    }

    placeMathNode(svgEl, htmlContent, { align = "center", rotate = 0 } = {}) {
      if (!svgEl || !this.stageEl) return;
      const stageRect = this.stageEl.getBoundingClientRect();
      const rect = svgEl.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) return;

      svgEl.style.opacity = "0";
      const span = document.createElement("span");
      span.className = "dynamic-plot-math-label";
      span.innerHTML = htmlContent;
      span.style.fontSize = getComputedStyle(svgEl).fontSize || "12px";

      const midY = rect.top + rect.height / 2 - stageRect.top;
      if (align === "left") {
        span.style.left = `${rect.left - stageRect.left}px`;
        span.style.top = `${midY}px`;
        span.style.transform = rotate ? `translate(0, -50%) rotate(${rotate}deg)` : "translate(0, -50%)";
      } else {
        span.style.left = `${rect.left + rect.width / 2 - stageRect.left}px`;
        span.style.top = `${midY}px`;
        span.style.transform = rotate ? `translate(-50%, -50%) rotate(${rotate}deg)` : "translate(-50%, -50%)";
      }
      this.mathLayer.appendChild(span);
    }

    syncMathOverlays() {
      if (!this.mathLayer || !this.canvas) return;
      this.mathLayer.innerHTML = "";

      if (hasMathDelimiters(this.cfg.xlabel)) {
        this.placeMathNode(this.canvas.querySelector("text.xtitle"), MathRenderer.get(this.cfg.xlabel));
      }
      if (hasMathDelimiters(this.cfg.ylabel)) {
        this.placeMathNode(this.canvas.querySelector("text.ytitle"), MathRenderer.get(this.cfg.ylabel), { rotate: -90 });
      }
      if (this.hasSlider && hasMathDelimiters(this.specs[0].rawParamLabel)) {
        const sweepSpec = this.specs[0];
        const stepVal = sweepSpec.params[this.activeStepIdx] ?? sweepSpec.params[0];
        this.placeMathNode(
          this.canvas.querySelector("text.slider-label"),
          `${MathRenderer.get(sweepSpec.rawParamLabel)}: ${stepVal}`,
          { align: "left" }
        );
      }
    }

    attachEvents() {
      this.canvas.on("plotly_relayout", (ev) => {
        if (!this.is3d && this.specs.some((s) => s.kind === "function") && !this.isResampling && ev) {
          let nextX = null, nextY = null;
          if (ev["xaxis.autorange"] || ev["yaxis.autorange"]) {
            nextX = this.homeDomains.xrange;
            nextY = this.homeDomains.yrange;
          } else if (ev["xaxis.range[0]"] !== undefined && ev["xaxis.range[1]"] !== undefined) {
            const r0 = Number(ev["xaxis.range[0]"]), r1 = Number(ev["xaxis.range[1]"]);
            nextX = this.cfg.xscale === "log" ? [Math.pow(10, r0), Math.pow(10, r1)] : [r0, r1];
            nextY = (ev["yaxis.range[0]"] !== undefined && ev["yaxis.range[1]"] !== undefined)
              ? (this.cfg.yscale === "log"
                  ? [Math.pow(10, Number(ev["yaxis.range[0]"])), Math.pow(10, Number(ev["yaxis.range[1]"]))]
                  : [Number(ev["yaxis.range[0]"]), Number(ev["yaxis.range[1]"])])
              : this.homeDomains.yrange;
          }
          if (nextX && Number.isFinite(nextX[0]) && Number.isFinite(nextX[1]) && nextX[0] < nextX[1]) {
            this.isResampling = true;
            try {
              if (this.hasSlider && this.canvas.layout?.sliders?.[0]) {
                this.canvas.layout.sliders[0].active = this.activeStepIdx;
              }
              Plotly.react(this.canvas, this.buildTraces({ xrange: nextX, yrange: nextY, zrange: null }), this.canvas.layout, { responsive: true });
            } finally {
              this.isResampling = false;
            }
          }
        }
        this.syncMathOverlays();
      });

      this.canvas.on("plotly_restyle", () => this.syncMathOverlays());

      const onStep = (idx) => {
        if (Number.isFinite(idx)) this.activeStepIdx = idx;
        this.syncMathOverlays();
      };
      this.canvas.on("plotly_sliderchange", (ev) => {
        if (!this.isAdvancingFrame) this.stopPlay();
        onStep(ev?.slider?.active);
      });
      this.canvas.on("plotly_animatingframe", (ev) => onStep(parseInt(ev?.name, 10)));
      this.canvas.on("plotly_buttonclicked", () => {
        if (this.isPlaying) this.stopPlay();
        else this.startPlay();
      });

      if (typeof ResizeObserver !== "undefined") {
        let raf = null;
        new ResizeObserver(() => {
          cancelAnimationFrame(raf);
          raf = requestAnimationFrame(() => {
            Plotly.Plots.resize(this.canvas);
            this.syncMathOverlays();
          });
        }).observe(this.stageEl);
      }
    }

    mount() {
      this.homeDomains = this.computeInitialDomains();

      const bodyEl = document.createElement("div");
      bodyEl.className = "dynamic-plot-body";

      this.stageEl = document.createElement("div");
      this.stageEl.className = "dynamic-plot-stage";

      this.canvas = document.createElement("div");
      this.canvas.className = "dynamic-plot-canvas";

      this.mathLayer = document.createElement("div");
      this.mathLayer.className = "dynamic-plot-math-layer";

      this.stageEl.append(this.canvas, this.mathLayer);
      bodyEl.appendChild(this.stageEl);
      this.buildSidebar(bodyEl);
      this.wrapEl.appendChild(bodyEl);

      Plotly.newPlot(this.canvas, this.buildTraces(this.homeDomains), this.buildLayout(ThemeSync.getPalette()), {
        responsive: true,
        displaylogo: false
      });

      if (this.hasSlider) {
        Plotly.addFrames(this.canvas, this.specs[0].frames);
      }

      this.attachEvents();
      this.syncMathOverlays();
    }

    syncTheme() {
      if (!this.canvas?.layout) return;
      Plotly.relayout(this.canvas, ThemeSync.getThemeRelayout(this.hasSlider, this.hasPlayButton, this.is3d));
      this.syncMathOverlays();
    }
  }

  async function initDynamicPlots() {
    const wraps = Array.from(document.querySelectorAll(".dynamic-plot-wrap"));
    if (wraps.length === 0) return;

    const registry = new Map();
    const mathStrings = [];

    document.querySelectorAll("script.dynamic-plot-def").forEach((el) => {
      const def = JSON.parse(el.textContent);
      registry.set(def.id, def.kind === "function" ? FunctionBuilder.prepare(def) : FileBuilder.prepare(def));
      if (hasMathDelimiters(def.label)) mathStrings.push(def.label);
      if (hasMathDelimiters(def.paramLabel)) mathStrings.push(def.paramLabel);
    });

    wraps.forEach((wrap) => {
      const cfg = JSON.parse(wrap.dataset.plotConfig || "{}");
      if (hasMathDelimiters(cfg.xlabel)) mathStrings.push(cfg.xlabel);
      if (hasMathDelimiters(cfg.ylabel)) mathStrings.push(cfg.ylabel);
    });

    await Promise.all([loadPlotly(), MathRenderer.prepare(mathStrings)]);

    const controllers = wraps
      .filter((w) => !w.dataset.initialized)
      .map((w) => {
        w.dataset.initialized = "true";
        return new DynamicPlotController(w, registry);
      });

    if (controllers.length === 0) return;

    const detectDark = () =>
      document.body.classList.contains("quarto-dark") ||
      document.documentElement.getAttribute("data-bs-theme") === "dark";

    let lastDark = detectDark();
    const onThemeChange = () => {
      const isDark = detectDark();
      if (isDark === lastDark) return;
      lastDark = isDark;
      requestAnimationFrame(() => controllers.forEach((ctrl) => ctrl.syncTheme()));
    };

    const observer = new MutationObserver(onThemeChange);
    observer.observe(document.body, { attributes: true, attributeFilter: ["class", "data-bs-theme"] });
    observer.observe(document.documentElement, { attributes: true, attributeFilter: ["class", "data-bs-theme"] });
  }

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initDynamicPlots);
  } else {
    initDynamicPlots();
  }
})();