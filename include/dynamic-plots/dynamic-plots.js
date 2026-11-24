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

  const formatNumber = (val) => {
    if (!Number.isFinite(val)) return String(val);
    const abs = Math.abs(val);
    if (abs > 0 && (abs < 1e-3 || abs >= 1e4)) {
      return val.toExponential(2).replace(/e([+-])0+(\d)/, "e$1$2");
    }
    const s = val.toFixed(4).replace(/\.?0+$/, "");
    return s === "-0" ? "0" : s;
  };

  // Converts any CSS color string into rgba(r, g, b, opacity) for SVG polygon fills
  const colorToRgba = (() => {
    const cache = new Map();
    let ctx = null;
    return (color, opacity) => {
      const key = `${color}|${opacity}`;
      if (cache.has(key)) return cache.get(key);
      if (!ctx) ctx = document.createElement("canvas").getContext("2d");
      ctx.fillStyle = "#000000";
      ctx.fillStyle = color;
      const norm = ctx.fillStyle;
      let rgba = color;
      if (norm.startsWith("#")) {
        const n = parseInt(norm.slice(1), 16);
        rgba = `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${opacity})`;
      } else {
        const m = norm.match(/[\d.]+/g);
        if (m) rgba = `rgba(${m[0]}, ${m[1]}, ${m[2]}, ${opacity})`;
      }
      cache.set(key, rgba);
      return rgba;
    };
  })();

  function resolveCurveColor(spec) {
    return spec.color || TRACE_COLORWAY[spec.colorIdx % TRACE_COLORWAY.length];
  }

  function applyTraceColor(trace, color) {
    if (trace.type === "scatter" || trace.type === "scatter3d") {
      trace.line = { ...(trace.line || {}), color };
      trace.marker = { ...(trace.marker || {}), color };
    } else if (trace.type === "surface") {
      trace.colorscale = [[0, color], [1, color]];
    }
    return trace;
  }

  // Transpiles validated math expressions into JIT-compiled JS functions
  const MathCompiler = (() => {
    const CONSTS = { pi: Math.PI, e: Math.E };
    const FUNCS = {
      sin: Math.sin, cos: Math.cos, tan: Math.tan,
      asin: Math.asin, acos: Math.acos, atan: Math.atan, atan2: Math.atan2,
      sinh: Math.sinh, cosh: Math.cosh, tanh: Math.tanh,
      asinh: Math.asinh, acosh: Math.acosh, atanh: Math.atanh,
      exp: Math.exp, log: Math.log, ln: Math.log, log10: Math.log10, log2: Math.log2,
      sqrt: Math.sqrt, abs: Math.abs, sign: Math.sign,
      floor: Math.floor, ceil: Math.ceil, min: Math.min, max: Math.max, hypot: Math.hypot
    };
    const TOKEN_RE = /\s*(?:((?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?)|([a-zA-Z_]\w*)|([+\-*/^(),[\]]))/y;

    function toJsExpr(src) {
      const tokens = [];
      TOKEN_RE.lastIndex = 0;
      while (TOKEN_RE.lastIndex < src.length) {
        const m = TOKEN_RE.exec(src);
        if (!m) break;
        if (m[1] !== undefined) tokens.push({ t: "num", v: String(Number(m[1])) });
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
          const op = next().v;
          lhs = `${lhs} ${op} ${parseMul()}`;
        }
        return lhs;
      };

      const parseMul = () => {
        let lhs = parseUnary();
        while (true) {
          if (isOp(peek(), "*") || isOp(peek(), "/")) {
            const op = next().v;
            lhs = `${lhs} ${op} ${parseUnary()}`;
          } else if (peek() && (peek().t === "id" || peek().t === "num" || isOp(peek(), "("))) {
            lhs = `${lhs} * ${parseUnary()}`;
          } else {
            break;
          }
        }
        return lhs;
      };

      const parseUnary = () => {
        if (isOp(peek(), "+")) { next(); return parseUnary(); }
        if (isOp(peek(), "-")) { next(); return `-(${parseUnary()})`; }
        return parsePow();
      };

      const parsePow = () => {
        const base = parseAtom();
        if (isOp(peek(), "^")) {
          next();
          return `(${base} ** ${parseUnary()})`;
        }
        return base;
      };

      const parseAtom = () => {
        const tok = next();
        if (!tok) return "NaN";
        if (tok.t === "num") return tok.v;
        if (isOp(tok, "(")) {
          const inner = parseAdd();
          next(); // ')'
          return `(${inner})`;
        }
        const name = tok.v;
        if (name === "c" && isOp(peek(), "[")) {
          next(); // '['
          const idx = parseAdd();
          next(); // ']'
          return `($row ? $row[Math.round(${idx})] : NaN)`;
        }
        if (name in FUNCS) {
          next(); // '('
          const args = [];
          if (!isOp(peek(), ")")) {
            args.push(parseAdd());
            while (isOp(peek(), ",")) {
              next();
              args.push(parseAdd());
            }
          }
          next(); // ')'
          return `$F.${name}(${args.join(", ")})`;
        }
        if (name in CONSTS) return `$C.${name}`;
        return name;
      };

      return parseAdd();
    }

    return {
      // Compiles a single native evaluator writing [x, y, (z)] into $out
      compilePointEvaluator(def) {
        const isFile = def.kind === "file";
        const is3d = def.dim === "3d";
        const paramNames = (def.params || []).map((p) => p.name);
        const declared = new Set(paramNames);
        const lines = [];

        if (isFile) {
          const numCols = def.rows?.[0]?.length || 0;
          if (numCols > 0) {
            const colDecls = [];
            for (let c = 0; c < numCols; c++) {
              colDecls.push(`c${c} = $row[${c}]`);
              declared.add(`c${c}`);
            }
            lines.push(`const ${colDecls.join(", ")};`);
          }
        }

        for (const v of def.vars || []) {
          const exprJs = toJsExpr(v.expr);
          if (declared.has(v.name)) {
            lines.push(`${v.name} = ${exprJs};`);
          } else {
            declared.add(v.name);
            lines.push(`let ${v.name} = ${exprJs};`);
          }
        }

        lines.push(`const $x = ${toJsExpr(def.x)};`);
        lines.push(`const $y = ${toJsExpr(def.y)};`);
        lines.push(`$out[0] = Number.isFinite($x) ? $x : null;`);
        lines.push(`$out[1] = Number.isFinite($y) ? $y : null;`);
        if (is3d) {
          lines.push(`const $z = ${toJsExpr(def.z)};`);
          lines.push(`$out[2] = Number.isFinite($z) ? $z : null;`);
        }

        const args = isFile ? ["$F", "$C", "$out", "$row", ...paramNames] : ["$F", "$C", "$out", ...paramNames];
        const rawFn = new Function(...args, lines.join("\n"));

        return isFile
          ? (out, row, paramVals) => rawFn(FUNCS, CONSTS, out, row, ...paramVals)
          : (out, paramVals) => rawFn(FUNCS, CONSTS, out, ...paramVals);
      },

      // Compiles a fast scalar y(x) evaluator for explicit 2D functions
      compileScalarY(def) {
        const paramNames = (def.params || []).map((p) => p.name);
        const declared = new Set(paramNames);
        const lines = [];

        for (const v of def.vars || []) {
          const exprJs = toJsExpr(v.expr);
          if (declared.has(v.name)) {
            lines.push(`${v.name} = ${exprJs};`);
          } else {
            declared.add(v.name);
            lines.push(`let ${v.name} = ${exprJs};`);
          }
        }
        lines.push(`const $y = ${toJsExpr(def.y)};`);
        lines.push(`return Number.isFinite($y) ? $y : null;`);

        const rawFn = new Function("$F", "$C", ...paramNames, lines.join("\n"));
        return (paramVals) => rawFn(FUNCS, CONSTS, ...paramVals);
      }
    };
  })();

  // Domain sampling and numeric extent utilities
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

    sampleParam(param, count, scale = "linear") {
      return param.kind === "list" ? param.values : this.sampleAxis([param.min, param.max], count, scale);
    },

    extent(values, positiveOnly = false) {
      let min = Infinity, max = -Infinity;
      for (let i = 0; i < values.length; i++) {
        const v = values[i];
        if (v === null || !Number.isFinite(v) || (positiveOnly && v <= 0)) continue;
        if (v < min) min = v;
        if (v > max) max = v;
      }
      return min <= max ? [min, max] : null;
    }
  };

  // Compiles and evaluates unified curve/surface definitions
  const CurveEvaluator = {
    prepare(def) {
      const params = def.params || [];
      const domainParams = params.filter((p) => !p.isSlider);
      const sliderParams = params.filter((p) => p.isSlider);
      const paramIndexByName = new Map(params.map((p, idx) => [p.name, idx]));
      const isExplicitYX = def.kind === "function" && def.dim === "2d" && domainParams[0]?.name === "x" && def.x === "x";

      return {
        ...def,
        params,
        rawLabel: def.label,
        domainParams,
        sliderParams,
        sliderNames: new Set(sliderParams.map((p) => p.name)),
        paramIndexByName,
        isExplicitYX,
        evalPoint: MathCompiler.compilePointEvaluator(def),
        evalScalarY: isExplicitYX ? MathCompiler.compileScalarY(def) : null
      };
    },

    buildParamVector(spec, sliderEnv) {
      const vec = new Array(spec.params.length);
      for (const p of spec.sliderParams) {
        vec[spec.paramIndexByName.get(p.name)] = sliderEnv[p.name];
      }
      return vec;
    },

    evaluate(spec, sliderEnv, scales, zoomXRange = null) {
      const name = toSizingText(spec.rawLabel);
      const is3d = spec.dim === "3d";
      const paramVec = this.buildParamVector(spec, sliderEnv);
      const out = is3d ? [null, null, null] : [null, null];

      if (spec.kind === "file") {
        const n = spec.rows.length;
        const xs = new Array(n), ys = new Array(n), zs = is3d ? new Array(n) : null;
        for (let i = 0; i < n; i++) {
          spec.evalPoint(out, spec.rows[i], paramVec);
          xs[i] = out[0];
          ys[i] = out[1];
          if (is3d) zs[i] = out[2];
        }
        const trace = is3d
          ? { type: "scatter3d", name, x: xs, y: ys, z: zs, mode: spec.mode, marker: { size: 3.5 } }
          : { type: "scatter", name, x: xs, y: ys, mode: spec.mode, connectgaps: false, line: { shape: spec.smooth ? "spline" : "linear" } };
        return { trace, xs, ys, zs, uniformX: false };
      }

      if (spec.subtype === "surface") {
        const [p0, p1] = spec.domainParams;
        const idx0 = spec.paramIndexByName.get(p0.name);
        const idx1 = spec.paramIndexByName.get(p1.name);
        const uVals = Domain.sampleParam(p0, spec.points, scales.xscale);
        const vVals = Domain.sampleParam(p1, spec.points, scales.yscale);
        const X = new Array(vVals.length), Y = new Array(vVals.length), Z = new Array(vVals.length);
        const flatX = [], flatY = [], flatZ = [];

        for (let j = 0; j < vVals.length; j++) {
          paramVec[idx1] = vVals[j];
          const rowX = new Array(uVals.length), rowY = new Array(uVals.length), rowZ = new Array(uVals.length);
          for (let i = 0; i < uVals.length; i++) {
            paramVec[idx0] = uVals[i];
            spec.evalPoint(out, paramVec);
            rowX[i] = out[0];
            rowY[i] = out[1];
            rowZ[i] = out[2];
            flatX.push(out[0]);
            flatY.push(out[1]);
            flatZ.push(out[2]);
          }
          X[j] = rowX; Y[j] = rowY; Z[j] = rowZ;
        }
        return { trace: { type: "surface", name, x: X, y: Y, z: Z, showscale: false }, xs: flatX, ys: flatY, zs: flatZ, uniformX: false };
      }

      // 2D or 3D analytical curve (1 domain parameter)
      const [p0] = spec.domainParams;
      const idx0 = spec.paramIndexByName.get(p0.name);
      let sampleDomain = p0;
      if (!is3d && zoomXRange && p0.name === "x" && p0.kind === "range") {
        const lo = Math.max(p0.min, zoomXRange[0]);
        const hi = Math.min(p0.max, zoomXRange[1]);
        if (lo < hi) sampleDomain = { ...p0, min: lo, max: hi };
      }
      const pVals = Domain.sampleParam(sampleDomain, spec.points, p0.name === "x" ? scales.xscale : "linear");
      const n = pVals.length;
      const xs = new Array(n), ys = new Array(n), zs = is3d ? new Array(n) : null;

      for (let i = 0; i < n; i++) {
        paramVec[idx0] = pVals[i];
        spec.evalPoint(out, paramVec);
        xs[i] = out[0];
        ys[i] = out[1];
        if (is3d) zs[i] = out[2];
      }
      const trace = is3d
        ? { type: "scatter3d", name, x: xs, y: ys, z: zs, mode: spec.mode, line: { width: 4 }, marker: { size: 3 } }
        : { type: "scatter", name, x: xs, y: ys, mode: spec.mode, connectgaps: false, line: { shape: spec.smooth ? "spline" : "linear" } };
      return { trace, xs, ys, zs, uniformX: spec.isExplicitYX };
    }
  };

  // Builds closed-polygon shading traces between curves, constants, bounds, or closed interiors
  const ShadeBuilder = {
    prepareCurveData(evalRes) {
      const rawPts = [];
      let isSorted = true;
      let prevX = -Infinity;
      for (let i = 0; i < evalRes.xs.length; i++) {
        const x = evalRes.xs[i], y = evalRes.ys[i];
        if (x !== null && y !== null && Number.isFinite(x) && Number.isFinite(y)) {
          rawPts.push([x, y]);
          if (x < prevX) isSorted = false;
          prevX = x;
        }
      }
      const sortedPts = isSorted ? rawPts : rawPts.slice().sort((a, b) => a[0] - b[0]);
      return { rawPts, sortedPts };
    },

    // Evaluates y(x) directly for explicit functions, or linearly interpolates sorted points
    sampleYAt(evalData, sliderEnv, x, cursor = null) {
      const spec = evalData.spec;
      if (spec.isExplicitYX) {
        const paramVec = CurveEvaluator.buildParamVector(spec, sliderEnv);
        paramVec[spec.paramIndexByName.get("x")] = x;
        return spec.evalScalarY(paramVec);
      }
      const pts = evalData.sortedPts;
      if (pts.length === 0) return null;
      const eps = 1e-12 * Math.max(1, Math.abs(x));
      if (x < pts[0][0] - eps || x > pts[pts.length - 1][0] + eps) return null;
      if (x <= pts[0][0] + eps) return pts[0][1];
      if (x >= pts[pts.length - 1][0] - eps) return pts[pts.length - 1][1];

      let lo = cursor ? cursor.idx : 0;
      if (cursor) {
        while (lo + 1 < pts.length - 1 && pts[lo + 1][0] <= x) lo++;
        cursor.idx = lo;
      } else {
        let hi = pts.length - 1;
        while (hi - lo > 1) {
          const mid = (lo + hi) >> 1;
          if (pts[mid][0] <= x) lo = mid;
          else hi = mid;
        }
      }
      const [x0, y0] = pts[lo], [x1, y1] = pts[lo + 1];
      return x1 === x0 ? y0 : y0 + ((x - x0) / (x1 - x0)) * (y1 - y0);
    },

    buildTrace(rule, evaluatedMap, sliderEnv, yBounds) {
      const src = evaluatedMap.get(rule.from);
      const color = rule.color || src.color;
      const fillcolor = colorToRgba(color, rule.opacity);
      const baseTrace = {
        type: "scatter",
        name: toSizingText(rule.label || ""),
        mode: "none",
        fill: "toself",
        fillcolor,
        hoverinfo: rule.label ? "name+x+y" : "skip",
        showlegend: false
      };

      // Closed curve: f1 -> f1
      if (rule.toKind === "curve" && rule.from === rule.to) {
        return { ...baseTrace, x: src.rawPts.map((p) => p[0]), y: src.rawPts.map((p) => p[1]) };
      }

      if (src.sortedPts.length < 2) return { ...baseTrace, x: [], y: [] };

      let lo = src.sortedPts[0][0];
      let hi = src.sortedPts[src.sortedPts.length - 1][0];
      const dst = rule.toKind === "curve" ? evaluatedMap.get(rule.to) : null;

      if (dst) {
        if (dst.sortedPts.length < 2) return { ...baseTrace, x: [], y: [] };
        lo = Math.max(lo, dst.sortedPts[0][0]);
        hi = Math.min(hi, dst.sortedPts[dst.sortedPts.length - 1][0]);
      }
      if (rule.xrange) {
        lo = Math.max(lo, rule.xrange[0]);
        hi = Math.min(hi, rule.xrange[1]);
      }
      if (!Number.isFinite(lo) || !Number.isFinite(hi) || lo >= hi) {
        return { ...baseTrace, x: [], y: [] };
      }

      const yConst = rule.toKind === "const"
        ? rule.to
        : (rule.to === "bottom" ? yBounds[0] : yBounds[1]);

      // Fast path: two explicit functions evaluated on identical x-grids
      if (dst && src.uniformX && dst.uniformX && src.xs.length === dst.xs.length &&
          src.xs[0] === dst.xs[0] && src.xs[src.xs.length - 1] === dst.xs[dst.xs.length - 1]) {
        const validX = [], yTop = [], yBot = [];
        const eps = 1e-12 * Math.max(1, Math.abs(lo), Math.abs(hi));
        if (lo > src.xs[0] + eps) {
          const y1 = this.sampleYAt(src, sliderEnv, lo);
          const y2 = this.sampleYAt(dst, sliderEnv, lo);
          if (Number.isFinite(y1) && Number.isFinite(y2)) { validX.push(lo); yTop.push(y1); yBot.push(y2); }
        }
        for (let i = 0; i < src.xs.length; i++) {
          const x = src.xs[i], y1 = src.ys[i], y2 = dst.ys[i];
          if (x >= lo - eps && x <= hi + eps && Number.isFinite(y1) && Number.isFinite(y2)) {
            validX.push(x); yTop.push(y1); yBot.push(y2);
          }
        }
        if (hi < src.xs[src.xs.length - 1] - eps) {
          const y1 = this.sampleYAt(src, sliderEnv, hi);
          const y2 = this.sampleYAt(dst, sliderEnv, hi);
          if (Number.isFinite(y1) && Number.isFinite(y2)) { validX.push(hi); yTop.push(y1); yBot.push(y2); }
        }
        if (validX.length < 2) return { ...baseTrace, x: [], y: [] };
        return {
          ...baseTrace,
          x: [...validX, ...validX.slice().reverse()],
          y: [...yTop, ...yBot.slice().reverse()]
        };
      }

      // General path: merge sorted x-coordinates and sample in a single forward pass
      const rawXs = [lo, hi];
      for (const [x] of src.sortedPts) if (x > lo && x < hi) rawXs.push(x);
      if (dst) {
        for (const [x] of dst.sortedPts) if (x > lo && x < hi) rawXs.push(x);
      }
      rawXs.sort((a, b) => a - b);

      const eps = 1e-12 * Math.max(1, Math.abs(lo), Math.abs(hi));
      const xs = [];
      for (const x of rawXs) {
        if (xs.length === 0 || x - xs[xs.length - 1] > eps) xs.push(x);
      }
      if (xs.length < 2) return { ...baseTrace, x: [], y: [] };

      const srcCursor = { idx: 0 };
      const dstCursor = { idx: 0 };
      const validX = [], yTop = [], yBot = [];
      for (const x of xs) {
        const y1 = this.sampleYAt(src, sliderEnv, x, srcCursor);
        const y2 = dst ? this.sampleYAt(dst, sliderEnv, x, dstCursor) : yConst;
        if (Number.isFinite(y1) && Number.isFinite(y2)) {
          validX.push(x);
          yTop.push(y1);
          yBot.push(y2);
        }
      }
      if (validX.length < 2) return { ...baseTrace, x: [], y: [] };

      return {
        ...baseTrace,
        x: [...validX, ...validX.slice().reverse()],
        y: [...yTop, ...yBot.slice().reverse()]
      };
    }
  };

  // Synchronizes Plotly axis and font colors with active Bootstrap CSS variables
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

    getThemeRelayout(is3d) {
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
      return u;
    }
  };

  class DynamicPlotController {
    constructor(wrapEl, registry) {
      this.wrapEl = wrapEl;
      this.cfg = JSON.parse(wrapEl.dataset.plotConfig || "{}");
      this.specs = this.cfg.curves.map((id, colorIdx) => ({ ...registry.get(id), colorIdx }));
      this.specById = new Map(this.specs.map((s) => [s.id, s]));
      this.curveIdxById = new Map(this.specs.map((s, i) => [s.id, i]));
      this.shadeRules = this.cfg.shade || [];
      this.hasBoundShade = this.shadeRules.some((r) => r.toKind === "bound");
      this.is3d = this.specs[0].dim === "3d";
      this.sliders = this.collectSliders();
      this.curveVisible = this.specs.map(() => true);
      this.shadeVisible = this.shadeRules.map(() => true);
      this.evalCache = new Array(this.specs.length).fill(null);
      this.evalDirty = new Array(this.specs.length).fill(true);
      this.isUpdating = false;
      this.zoomXRange = null;
      this.zoomYRange = null;

      this.mount();
    }

    collectSliders() {
      const seen = new Map();
      for (const spec of this.specs) {
        for (const p of spec.sliderParams) {
          if (!seen.has(p.name)) {
            seen.set(p.name, {
              name: p.name,
              label: p.label,
              values: Domain.sampleParam(p, p.steps, "linear"),
              play: Boolean(p.play),
              isPlaying: false,
              playRaf: null,
              playBtn: null,
              index: 0,
              inputEl: null,
              valueEl: null
            });
          } else if (p.play) {
            seen.get(p.name).play = true;
          }
        }
      }
      return Array.from(seen.values());
    }

    getSliderEnv() {
      const env = {};
      for (const s of this.sliders) env[s.name] = s.values[s.index];
      return env;
    }

    // Computes global Y-bounds across slider states so animated sweeps never clip
    computeHomeYRange(initialMap) {
      if (this.cfg.yrange) return this.cfg.yrange;
      const positiveOnly = this.cfg.yscale === "log";
      let min = Infinity, max = -Infinity;

      const absorb = (ys) => {
        const ext = Domain.extent(ys, positiveOnly);
        if (ext) {
          if (ext[0] < min) min = ext[0];
          if (ext[1] > max) max = ext[1];
        }
      };

      for (const entry of initialMap.values()) absorb(entry.ys);

      if (this.sliders.length > 0) {
        const scales = { xscale: this.cfg.xscale, yscale: this.cfg.yscale, zscale: this.cfg.zscale };
        const baseEnv = this.getSliderEnv();
        for (const s of this.sliders) {
          for (let i = 0; i < s.values.length; i++) {
            if (i === s.index) continue;
            const env = { ...baseEnv, [s.name]: s.values[i] };
            for (const spec of this.specs) {
              if (spec.sliderNames.has(s.name)) {
                absorb(CurveEvaluator.evaluate(spec, env, scales, null).ys);
              }
            }
          }
        }
      }

      return min <= max ? [min, max] : [-1, 1];
    }

    evaluateCurveAt(idx, sliderEnv, scales) {
      const spec = this.specs[idx];
      const res = CurveEvaluator.evaluate(spec, sliderEnv, scales, this.zoomXRange);
      const color = resolveCurveColor(spec);
      applyTraceColor(res.trace, color);
      const pts = this.is3d ? { rawPts: [], sortedPts: [] } : ShadeBuilder.prepareCurveData(res);
      const entry = { ...res, ...pts, spec, color };
      this.evalCache[idx] = entry;
      this.evalDirty[idx] = false;
      return entry;
    }

    isCurveNeededByVisibleShade(curveId) {
      for (let i = 0; i < this.shadeRules.length; i++) {
        if (!this.shadeVisible[i]) continue;
        const r = this.shadeRules[i];
        if (r.from === curveId || (r.toKind === "curve" && r.to === curveId)) return true;
      }
      return false;
    }

    evaluateAll() {
      const sliderEnv = this.getSliderEnv();
      const scales = { xscale: this.cfg.xscale, yscale: this.cfg.yscale, zscale: this.cfg.zscale };
      const evaluatedMap = new Map();

      const curveTraces = this.specs.map((spec, idx) => {
        const entry = this.evaluateCurveAt(idx, sliderEnv, scales);
        entry.trace.visible = this.curveVisible[idx] ? true : "legendonly";
        evaluatedMap.set(spec.id, entry);
        return entry.trace;
      });

      if (!this.homeYRange && !this.is3d) {
        this.homeYRange = this.computeHomeYRange(evaluatedMap);
      }
      const yBounds = this.zoomYRange || this.cfg.yrange || this.homeYRange || [-1, 1];

      const shadeTraces = this.shadeRules.map((rule, idx) => {
        const trace = ShadeBuilder.buildTrace(rule, evaluatedMap, sliderEnv, yBounds);
        const srcVis = this.curveVisible[this.curveIdxById.get(rule.from)];
        const dstVis = rule.toKind === "curve" ? this.curveVisible[this.curveIdxById.get(rule.to)] : true;
        trace.visible = (this.shadeVisible[idx] && srcVis && dstVis) ? true : "legendonly";
        return trace;
      });

      return [...shadeTraces, ...curveTraces];
    }

    // Incrementally updates only traces affected by a slider change or zoom
    updateAffectedTraces(changedSliderName = null, syncMath = false) {
      if (!this.canvas || this.isUpdating) return;
      this.isUpdating = true;
      try {
        const sliderEnv = this.getSliderEnv();
        const scales = { xscale: this.cfg.xscale, yscale: this.cfg.yscale, zscale: this.cfg.zscale };
        const shadeCount = this.shadeRules.length;
        const traceIndices = [];
        const xs = [], ys = [], zs = [];
        const evaluatedMap = new Map();

        this.specs.forEach((spec, idx) => {
          const affected = changedSliderName === null
            ? (this.zoomXRange !== null || this.zoomYRange === null) && spec.isExplicitYX
            : spec.sliderNames.has(changedSliderName);

          if (affected) {
            const needed = this.curveVisible[idx] || this.isCurveNeededByVisibleShade(spec.id);
            if (needed) {
              const entry = this.evaluateCurveAt(idx, sliderEnv, scales);
              evaluatedMap.set(spec.id, entry);
              traceIndices.push(shadeCount + idx);
              xs.push(entry.trace.x);
              ys.push(entry.trace.y);
              if (this.is3d) zs.push(entry.trace.z);
            } else {
              this.evalDirty[idx] = true;
            }
          } else if (this.evalCache[idx]) {
            evaluatedMap.set(spec.id, this.evalCache[idx]);
          }
        });

        if (shadeCount > 0) {
          const yBounds = this.zoomYRange || this.cfg.yrange || this.homeYRange || [-1, 1];
          this.shadeRules.forEach((rule, idx) => {
            const srcSpec = this.specById.get(rule.from);
            const dstSpec = rule.toKind === "curve" ? this.specById.get(rule.to) : null;
            const affected = changedSliderName === null
              ? true
              : (srcSpec.sliderNames.has(changedSliderName) || Boolean(dstSpec?.sliderNames.has(changedSliderName)));

            if (affected && this.shadeVisible[idx]) {
              const trace = ShadeBuilder.buildTrace(rule, evaluatedMap, sliderEnv, yBounds);
              traceIndices.push(idx);
              xs.push(trace.x);
              ys.push(trace.y);
            }
          });
        }

        if (traceIndices.length > 0) {
          const payload = this.is3d ? { x: xs, y: ys, z: zs } : { x: xs, y: ys };
          Plotly.restyle(this.canvas, payload, traceIndices);
        }
      } finally {
        this.isUpdating = false;
      }
      if (syncMath) this.syncMathOverlays();
    }

    syncVisibility() {
      if (!this.canvas || this.isUpdating) return;
      this.isUpdating = true;
      try {
        const sliderEnv = this.getSliderEnv();
        const scales = { xscale: this.cfg.xscale, yscale: this.cfg.yscale, zscale: this.cfg.zscale };
        const shadeCount = this.shadeRules.length;
        const evaluatedMap = new Map();
        const dirtyIndices = [];
        const dirtyX = [], dirtyY = [], dirtyZ = [];

        this.specs.forEach((spec, idx) => {
          const needed = this.curveVisible[idx] || this.isCurveNeededByVisibleShade(spec.id);
          if (needed && (this.evalDirty[idx] || !this.evalCache[idx])) {
            const entry = this.evaluateCurveAt(idx, sliderEnv, scales);
            dirtyIndices.push(shadeCount + idx);
            dirtyX.push(entry.trace.x);
            dirtyY.push(entry.trace.y);
            if (this.is3d) dirtyZ.push(entry.trace.z);
          }
          if (this.evalCache[idx]) evaluatedMap.set(spec.id, this.evalCache[idx]);
        });

        if (dirtyIndices.length > 0) {
          Plotly.restyle(this.canvas, this.is3d ? { x: dirtyX, y: dirtyY, z: dirtyZ } : { x: dirtyX, y: dirtyY }, dirtyIndices);
        }

        const yBounds = this.zoomYRange || this.cfg.yrange || this.homeYRange || [-1, 1];
        const shadeIndices = [], shadeX = [], shadeY = [];
        const visList = [];

        this.shadeRules.forEach((rule, idx) => {
          const srcVis = this.curveVisible[this.curveIdxById.get(rule.from)];
          const dstVis = rule.toKind === "curve" ? this.curveVisible[this.curveIdxById.get(rule.to)] : true;
          const visible = Boolean(this.shadeVisible[idx] && srcVis && dstVis);
          visList.push(visible ? true : "legendonly");
          if (visible) {
            const trace = ShadeBuilder.buildTrace(rule, evaluatedMap, sliderEnv, yBounds);
            shadeIndices.push(idx);
            shadeX.push(trace.x);
            shadeY.push(trace.y);
          }
        });

        this.curveVisible.forEach((vis) => visList.push(vis ? true : "legendonly"));

        if (shadeIndices.length > 0) {
          Plotly.restyle(this.canvas, { x: shadeX, y: shadeY }, shadeIndices);
        }
        Plotly.restyle(this.canvas, { visible: visList });
      } finally {
        this.isUpdating = false;
      }
    }

    buildLegendItems() {
      const items = [];
      this.specs.forEach((spec, idx) => {
        items.push({
          label: spec.rawLabel,
          color: resolveCurveColor(spec),
          mode: spec.mode,
          onToggle: (checked) => {
            this.curveVisible[idx] = checked;
            this.syncVisibility();
          }
        });
      });
      this.shadeRules.forEach((rule, idx) => {
        if (!rule.label) return;
        const color = rule.color || resolveCurveColor(this.specById.get(rule.from));
        items.push({
          label: rule.label,
          color,
          mode: "area",
          onToggle: (checked) => {
            this.shadeVisible[idx] = checked;
            this.syncVisibility();
          }
        });
      });
      return items;
    }

    buildSidebar(bodyEl) {
      if (this.cfg.legend === false) return;
      const items = this.buildLegendItems();
      if (items.length === 0) return;

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

      for (const entry of items) {
        const item = document.createElement("label");
        item.className = "dynamic-plot-curve-toggle";

        const checkbox = document.createElement("input");
        checkbox.type = "checkbox";
        checkbox.className = "form-check-input dynamic-plot-curve-checkbox";
        checkbox.checked = true;
        checkbox.style.accentColor = entry.color;
        checkbox.addEventListener("change", () => {
          item.classList.toggle("is-hidden", !checkbox.checked);
          entry.onToggle(checkbox.checked);
        });

        const swatch = document.createElement("span");
        swatch.className = "dynamic-plot-swatch";
        swatch.dataset.mode = entry.mode;
        swatch.style.setProperty("--swatch-color", entry.color);

        const labelSpan = document.createElement("span");
        labelSpan.className = "dynamic-plot-curve-label";
        if (hasMathDelimiters(entry.label)) labelSpan.innerHTML = MathRenderer.get(entry.label);
        else labelSpan.textContent = entry.label;

        item.append(checkbox, swatch, labelSpan);
        sidebar.appendChild(item);
      }

      wrap.append(toggleBtn, sidebar);
      bodyEl.appendChild(wrap);
    }

    buildControls() {
      if (this.sliders.length === 0) return;

      const controls = document.createElement("div");
      controls.className = "dynamic-plot-controls";

      const list = document.createElement("div");
      list.className = "dynamic-plot-sliders";

      for (const s of this.sliders) {
        const row = document.createElement("div");
        row.className = "dynamic-plot-slider-row";

        if (s.play) {
          const playBtn = document.createElement("button");
          playBtn.type = "button";
          playBtn.className = "dynamic-plot-play-btn";
          playBtn.title = "Play / Pause";
          playBtn.textContent = "\u25B6";
          playBtn.addEventListener("click", () => {
            if (s.isPlaying) this.stopPlay(s);
            else this.startPlay(s);
          });
          s.playBtn = playBtn;
          row.appendChild(playBtn);
        }

        const main = document.createElement("div");
        main.className = "dynamic-plot-slider-main";

        const header = document.createElement("div");
        header.className = "dynamic-plot-slider-header";

        const nameSpan = document.createElement("span");
        nameSpan.className = "dynamic-plot-slider-label";
        if (hasMathDelimiters(s.label)) nameSpan.innerHTML = MathRenderer.get(s.label);
        else nameSpan.textContent = s.label;

        const sepSpan = document.createElement("span");
        sepSpan.textContent = ": ";

        const valSpan = document.createElement("span");
        valSpan.className = "dynamic-plot-slider-value";
        valSpan.textContent = formatNumber(s.values[0]);

        header.append(nameSpan, sepSpan, valSpan);

        const input = document.createElement("input");
        input.type = "range";
        input.className = "form-range dynamic-plot-slider-input";
        input.min = "0";
        input.max = String(s.values.length - 1);
        input.step = "1";
        input.value = "0";
        input.addEventListener("input", () => {
          this.stopPlay(s);
          this.setSliderIndex(s, Number(input.value));
        });

        s.inputEl = input;
        s.valueEl = valSpan;
        main.append(header, input);
        row.appendChild(main);
        list.appendChild(row);
      }

      controls.appendChild(list);
      this.stageEl.appendChild(controls);
    }

    setSliderIndex(slider, idx) {
      slider.index = idx;
      if (slider.inputEl) slider.inputEl.value = String(idx);
      if (slider.valueEl) slider.valueEl.textContent = formatNumber(slider.values[idx]);
      this.updateAffectedTraces(slider.name, false);
    }

    startPlay(slider) {
      if (slider.isPlaying || slider.values.length < 2) return;
      slider.isPlaying = true;
      if (slider.playBtn) slider.playBtn.textContent = "\u275A\u275A";
      if (slider.index >= slider.values.length - 1) {
        this.setSliderIndex(slider, 0);
      }
      let lastTick = performance.now();
      const step = (now) => {
        if (!slider.isPlaying || !this.wrapEl.isConnected) {
          this.stopPlay(slider);
          return;
        }
        if (now - lastTick >= PLAY_INTERVAL_MS) {
          lastTick = now;
          this.setSliderIndex(slider, (slider.index + 1) % slider.values.length);
        }
        slider.playRaf = requestAnimationFrame(step);
      };
      slider.playRaf = requestAnimationFrame(step);
    }

    stopPlay(slider) {
      if (slider.playRaf !== null) {
        cancelAnimationFrame(slider.playRaf);
        slider.playRaf = null;
      }
      if (slider.isPlaying) {
        slider.isPlaying = false;
        if (slider.playBtn) slider.playBtn.textContent = "\u25B6";
      }
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
        const lockY = this.sliders.length > 0 || this.hasBoundShade;
        const yRange = this.cfg.yrange || (lockY ? this.homeYRange : null);
        layout.dragmode = "pan";
        layout.xaxis = ThemeSync.buildAxisTheme(this.cfg.xlabel, this.cfg.xscale, this.cfg.xrange, palette);
        layout.yaxis = ThemeSync.buildAxisTheme(this.cfg.ylabel, this.cfg.yscale, yRange, palette);
      }
      return layout;
    }

    placeMathNode(svgEl, htmlContent, rotate = 0) {
      if (!svgEl || !this.stageEl) return;
      const stageRect = this.stageEl.getBoundingClientRect();
      const rect = svgEl.getBoundingClientRect();
      if (rect.width === 0 && rect.height === 0) return;

      svgEl.style.opacity = "0";
      const span = document.createElement("span");
      span.className = "dynamic-plot-math-label";
      span.innerHTML = htmlContent;
      span.style.fontSize = getComputedStyle(svgEl).fontSize || "12px";
      span.style.left = `${rect.left + rect.width / 2 - stageRect.left}px`;
      span.style.top = `${rect.top + rect.height / 2 - stageRect.top}px`;
      span.style.transform = rotate ? `translate(-50%, -50%) rotate(${rotate}deg)` : "translate(-50%, -50%)";
      this.mathLayer.appendChild(span);
    }

    syncMathOverlays() {
      if (!this.mathLayer || !this.canvas) return;
      this.mathLayer.innerHTML = "";

      if (hasMathDelimiters(this.cfg.xlabel)) {
        this.placeMathNode(this.canvas.querySelector("text.xtitle"), MathRenderer.get(this.cfg.xlabel));
      }
      if (hasMathDelimiters(this.cfg.ylabel)) {
        this.placeMathNode(this.canvas.querySelector("text.ytitle"), MathRenderer.get(this.cfg.ylabel), -90);
      }
    }

    attachEvents() {
      this.canvas.on("plotly_relayout", (ev) => {
        if (!this.is3d && !this.isUpdating && ev) {
          let needsRefresh = false;
          if (ev["xaxis.autorange"] || ev["yaxis.autorange"]) {
            this.zoomXRange = null;
            this.zoomYRange = null;
            if ((this.sliders.length > 0 || this.hasBoundShade) && this.canvas.layout?.yaxis) {
              const r = this.cfg.yrange || this.homeYRange;
              this.canvas.layout.yaxis.range = this.cfg.yscale === "log" ? [Math.log10(r[0]), Math.log10(r[1])] : r;
              this.canvas.layout.yaxis.autorange = false;
            }
            needsRefresh = true;
          } else {
            if (ev["xaxis.range[0]"] !== undefined && ev["xaxis.range[1]"] !== undefined) {
              const r0 = Number(ev["xaxis.range[0]"]), r1 = Number(ev["xaxis.range[1]"]);
              this.zoomXRange = this.cfg.xscale === "log" ? [Math.pow(10, r0), Math.pow(10, r1)] : [r0, r1];
              needsRefresh = true;
            }
            if (ev["yaxis.range[0]"] !== undefined && ev["yaxis.range[1]"] !== undefined) {
              const r0 = Number(ev["yaxis.range[0]"]), r1 = Number(ev["yaxis.range[1]"]);
              this.zoomYRange = this.cfg.yscale === "log" ? [Math.pow(10, r0), Math.pow(10, r1)] : [r0, r1];
              needsRefresh = true;
            }
          }
          if (needsRefresh) this.updateAffectedTraces(null, true);
        }
        this.syncMathOverlays();
      });

      this.canvas.on("plotly_restyle", () => this.syncMathOverlays());

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
      if (this.cfg.width) {
        this.wrapEl.style.width = `${this.cfg.width}px`;
        this.wrapEl.style.maxWidth = "100%";
      }

      const bodyEl = document.createElement("div");
      bodyEl.className = "dynamic-plot-body";

      this.stageEl = document.createElement("div");
      this.stageEl.className = "dynamic-plot-stage";

      this.canvas = document.createElement("div");
      this.canvas.className = "dynamic-plot-canvas";

      this.mathLayer = document.createElement("div");
      this.mathLayer.className = "dynamic-plot-math-layer";

      this.stageEl.append(this.canvas, this.mathLayer);
      this.buildControls();
      bodyEl.appendChild(this.stageEl);
      this.buildSidebar(bodyEl);
      this.wrapEl.appendChild(bodyEl);

      const initialTraces = this.evaluateAll();
      Plotly.newPlot(this.canvas, initialTraces, this.buildLayout(ThemeSync.getPalette()), {
        responsive: true,
        displaylogo: false
      });

      this.attachEvents();
      this.syncMathOverlays();
    }

    syncTheme() {
      if (!this.canvas?.layout) return;
      Plotly.relayout(this.canvas, ThemeSync.getThemeRelayout(this.is3d));
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
      registry.set(def.id, CurveEvaluator.prepare(def));
      if (hasMathDelimiters(def.label)) mathStrings.push(def.label);
      for (const p of def.params || []) {
        if (p.isSlider && hasMathDelimiters(p.label)) mathStrings.push(p.label);
      }
    });

    wraps.forEach((wrap) => {
      const cfg = JSON.parse(wrap.dataset.plotConfig || "{}");
      if (hasMathDelimiters(cfg.xlabel)) mathStrings.push(cfg.xlabel);
      if (hasMathDelimiters(cfg.ylabel)) mathStrings.push(cfg.ylabel);
      for (const rule of cfg.shade || []) {
        if (hasMathDelimiters(rule.label)) mathStrings.push(rule.label);
      }
    });

    await Promise.all([
      loadPlotly(),
      mathStrings.length > 0 ? MathRenderer.prepare(mathStrings) : Promise.resolve()
    ]);

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