(() => {
  if (window.__quartoDynamicPlotsInit) return;
  window.__quartoDynamicPlotsInit = true;

  const PLOTLY_CDN = "https://cdn.plot.ly/plotly-2.35.2.min.js";
  const PLAY_INTERVAL_MS = 300;
  const TRACE_COLORWAY = [
    "#1f77b4", "#ff7f0e", "#2ca02c", "#d62728", "#9467bd",
    "#8c564b", "#e377c2", "#7f7f7f", "#bcbd22", "#17becf"
  ];

  // Lazily loads the Plotly library from the CDN once per page
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

  // Checks whether a string contains LaTeX math delimiters
  const hasMathDelimiters = (str) =>
    typeof str === "string" && /(\$\$?[\s\S]+?\$\$?|\\\([\s\S]+?\\\)|\\\[[\s\S]+?\\\])/.test(str);

  // Strips LaTeX delimiters and commands to produce plain sizing and trace text
  const toSizingText = (str) => !str ? "" : String(str)
    .replace(/\\\(|\\\)|\\\[|\\\]|\$\$/g, "")
    .replace(/\$([^$]+)\$/g, "$1")
    .replace(/\\[a-zA-Z]+\{([^}]*)\}/g, "$1")
    .replace(/\\[a-zA-Z]+/g, "x")
    .replace(/[{}^_]/g, "");

  // Formats slider readout values using fixed or exponential notation
  const formatNumber = (val) => {
    if (!Number.isFinite(val)) return String(val);
    const abs = Math.abs(val);
    if (abs > 0 && (abs < 1e-3 || abs >= 1e4)) {
      return val.toExponential(2).replace(/e([+-])0+(\d)/, "e$1$2");
    }
    const s = val.toFixed(4).replace(/\.?0+$/, "");
    return s === "-0" ? "0" : s;
  };

  // Converts any CSS color string into a cached RGBA value with the given opacity
  const colorToRgba = (() => {
    const cache = new Map();
    const ctx = document.createElement("canvas").getContext("2d");
    return (color, opacity) => {
      const key = `${color}|${opacity}`;
      if (cache.has(key)) return cache.get(key);
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

  // Resolves a curve's explicit color or assigns one from the default colorway
  const resolveCurveColor = (spec) => spec.color || TRACE_COLORWAY[spec.colorIdx % TRACE_COLORWAY.length];

  // Applies a resolved color to line, marker, or surface trace properties
  function applyTraceColor(trace, color) {
    if (trace.type === "scatter" || trace.type === "scatter3d") {
      trace.line = { ...(trace.line || {}), color };
      trace.marker = { ...(trace.marker || {}), color };
    } else if (trace.type === "surface") {
      trace.colorscale = [[0, color], [1, color]];
    }
    return trace;
  }

  // Extracts curve IDs referenced by the lower and upper bounds of a shading rule
  const shadeCurveIds = (rule) =>
    [rule.fromKind === "curve" ? rule.from : null, rule.toKind === "curve" ? rule.to : null].filter(Boolean);

  // JavaScript parses native expressions after the filter checks their tokens and names.
  const MathCompiler = (() => {
    const math = Object.fromEntries(Object.getOwnPropertyNames(Math)
      .filter((name) => name !== "random" && ["number", "function"].includes(typeof Math[name]))
      .map((name) => [name, Math[name]]));
    Object.assign(math, { pi: Math.PI, e: Math.E, ln: Math.log });
    const mathNames = Object.keys(math);
    const mathScope = new Set(mathNames);
    const bindMath = `const { ${mathNames.join(", ")} } = $math;`;
    const token = /(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?|[A-Za-z_]\w*|\s+|[+\-*/(),]/y;

    function check(source, scope) {
      if (/\/\/|\/\*|\+\+|--/.test(source)) throw new Error(`Invalid operator in "${source}"`);

      token.lastIndex = 0;
      while (token.lastIndex < source.length) {
        const start = token.lastIndex;
        const match = token.exec(source);
        if (!match) throw new Error(`Invalid token at column ${start + 1} in "${source}"`);
        const [word] = match;
        if (/^[A-Za-z_]/.test(word) && !scope.has(word)) {
          throw new Error(`Unknown or disallowed name "${word}" in "${source}"`);
        }
      }
    }

    function compile(args, body) {
      const factory = new Function("$math", `"use strict";\n${bindMath}\nreturn (${args.join(", ")}) => {\n${body}\n};`);
      return factory(math);
    }

    function constants(source, context) {
      try {
        check(source, mathScope);
        const values = compile([], `return [${source}];`)();
        for (const value of values) {
          if (!Number.isFinite(value)) throw new Error("Expected finite numeric values");
        }
        return values;
      } catch (error) {
        throw new Error(`${context}: ${error.message}`);
      }
    }

    function compilePointEvaluator(def) {
      const isFile = def.kind === "file";
      const paramNames = (def.params || []).map((p) => p.name);
      const columns = isFile ? Array.from(def.rows[0], (_, i) => `c${i}`) : [];
      const inputs = [...paramNames, ...columns, ...(isFile ? ["c"] : [])];
      const scope = new Set(mathScope);
      for (const name of inputs) {
        if (scope.has(name)) throw new Error(`Duplicate or reserved input name "${name}"`);
        scope.add(name);
      }

      const lines = columns.map((name, i) => `const ${name} = $row[${i}];`);
      if (isFile) lines.push("const c = (index) => $row[$round(index)];");
      const helpers = new Set();
      for (const { name, expr } of def.vars || []) {
        if (scope.has(name) && !helpers.has(name)) throw new Error(`Helper "${name}" shadows an input or math name`);
        check(expr, scope);
        lines.push(`${helpers.has(name) ? "" : "let "}${name} = (${expr});`);
        scope.add(name);
        helpers.add(name);
      }

      const coordinates = def.dim === "3d" ? ["x", "y", "z"] : ["x", "y"];
      coordinates.forEach((axis, index) => {
        check(def[axis], scope);
        lines.push(`const $${axis} = ${def[axis]};`);
        lines.push(`$out[${index}] = $finite($${axis}) ? $${axis} : null;`);
      });

      const evaluate = compile(["$out", "$row", "$round", "$finite", ...paramNames], lines.join("\n"));
      return isFile
        ? (out, row, paramVals) => evaluate(out, row, Math.round, Number.isFinite, ...paramVals)
        : (out, paramVals) => evaluate(out, null, Math.round, Number.isFinite, ...paramVals);
    }

    return { constants, compilePointEvaluator };
  })();

  // Resolves constant expressions and validates the resulting numeric ranges once at startup.
  const PlotOptions = {
    range(values, context, scale) {
      if (values.length !== 2 || values[0] >= values[1]) {
        throw new Error(`${context} requires [min, max] with min < max`);
      }
      if (scale === "log" && values[0] <= 0) {
        throw new Error(`${context} requires positive bounds on a logarithmic axis`);
      }
      return values;
    },

    constant(source, context) {
      const values = MathCompiler.constants(source, context);
      if (values.length !== 1) throw new Error(`${context} requires one number`);
      return values[0];
    },

    parameter(param, defaultSteps) {
      const context = `Parameter "${param.name}"`;
      const values = param.integerRange
        ? param.integerRange.map((expr) => this.constant(expr, context))
        : MathCompiler.constants(param.domain, context);

      if (!param.integerRange && values.length === 2) {
        const [min, max] = this.range(values, context);
        return { ...param, kind: "range", min, max, steps: param.steps ?? defaultSteps };
      }
      if (param.steps !== undefined) throw new Error(`'steps' for ${context} requires a [min, max] range`);
      if (param.integerRange) {
        const [min, max] = this.range(values, context);
        if (!values.every(Number.isSafeInteger)) throw new Error(`${context} requires integer bounds`);
        return { ...param, kind: "list", values: Array.from({ length: max - min + 1 }, (_, i) => min + i) };
      }
      if (values.length < 3) throw new Error(`${context} requires a range or at least three values`);
      return { ...param, kind: "list", values };
    },

    canvas(config) {
      const resolved = { ...config };
      for (const axis of ["x", "y", "z"]) {
        const key = `${axis}range`;
        if (config[key] !== undefined) {
          resolved[key] = this.range(MathCompiler.constants(config[key], key), key, config[`${axis}scale`]);
        }
      }
      resolved.shade = (config.shade || []).map((rule) => ({
        ...rule,
        from: rule.fromKind === "const" ? this.constant(rule.from, "Shading lower bound") : rule.from,
        to: rule.toKind === "const" ? this.constant(rule.to, "Shading upper bound") : rule.to,
        xrange: rule.xrange === undefined ? undefined
          : this.range(MathCompiler.constants(rule.xrange, "Shading xrange"), "Shading xrange", config.xscale)
      }));
      return resolved;
    }
  };

  // Utilities for sampling linear or logarithmic domains and computing extents
  const Domain = {
    // Generates evenly spaced sample points along a linear or logarithmic interval
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

    // Samples a parameter from an explicit value list or continuous range
    sampleParam(param, count) {
      return param.kind === "list" ? param.values : this.sampleAxis([param.min, param.max], count);
    },

    // Samples the explicit horizontal domain over the portion visible on its axis.
    sampleX(param, count, scale, view) {
      let { min, max } = param;
      if (param.kind === "list") return this.sampleParam(param, count);
      if (view) {
        const lo = Math.max(min, view[0]);
        const hi = Math.min(max, view[1]);
        if (lo < hi) [min, max] = [lo, hi];
      }
      if (scale === "log") {
        if (max <= 0) return [];
        // When the domain includes zero, start one linear sample step inside the positive range.
        if (min <= 0) min = Math.max(Number.MIN_VALUE, max / count);
      }
      return this.sampleAxis([min, max], count, scale);
    },

    // Computes the finite [min, max] extent of a numeric array
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

  // Prepares curve specifications and evaluates coordinate traces
  const CurveEvaluator = {
    // Precomputes parameter indices, domain metadata, and the compiled evaluator
    prepare(def, defaultSteps) {
      const params = (def.params || []).map((param) => PlotOptions.parameter(param, defaultSteps));
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
        evalPoint: MathCompiler.compilePointEvaluator(def)
      };
    },

    // Populates a parameter vector with current slider values
    buildParamVector(spec, sliderEnv) {
      const vec = new Array(spec.params.length);
      for (const p of spec.sliderParams) vec[spec.paramIndexByName.get(p.name)] = sliderEnv[p.name];
      return vec;
    },

    // Evaluates a curve, data file, or 3D surface into a Plotly trace
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
        return { trace, xs, ys, zs };
      }

      if (spec.subtype === "surface") {
        const [p0, p1] = spec.domainParams;
        const idx0 = spec.paramIndexByName.get(p0.name);
        const idx1 = spec.paramIndexByName.get(p1.name);
        const uVals = Domain.sampleParam(p0, spec.points);
        const vVals = Domain.sampleParam(p1, spec.points);
        const X = new Array(vVals.length), Y = new Array(vVals.length), Z = new Array(vVals.length);
        const flatX = [], flatY = [], flatZ = [];

        for (let j = 0; j < vVals.length; j++) {
          paramVec[idx1] = vVals[j];
          const rowX = new Array(uVals.length), rowY = new Array(uVals.length), rowZ = new Array(uVals.length);
          for (let i = 0; i < uVals.length; i++) {
            paramVec[idx0] = uVals[i];
            spec.evalPoint(out, paramVec);
            rowX[i] = out[0]; rowY[i] = out[1]; rowZ[i] = out[2];
            flatX.push(out[0]); flatY.push(out[1]); flatZ.push(out[2]);
          }
          X[j] = rowX; Y[j] = rowY; Z[j] = rowZ;
        }
        return { trace: { type: "surface", name, x: X, y: Y, z: Z, showscale: false }, xs: flatX, ys: flatY, zs: flatZ };
      }

      const [p0] = spec.domainParams;
      const idx0 = spec.paramIndexByName.get(p0.name);
      const pVals = spec.isExplicitYX
        ? Domain.sampleX(p0, spec.points, scales.xscale, zoomXRange)
        : Domain.sampleParam(p0, spec.points);
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
      return { trace, xs, ys, zs };
    }
  };

  // Builds closed-polygon shading traces clipped to directional bounds
  const ShadeBuilder = {
    // Preserves gaps and sorts points by x within each uninterrupted segment.
    prepareSegments({ xs, ys }) {
      const paths = [];
      let path = null;
      for (let i = 0; i < xs.length; i++) {
        if (Number.isFinite(xs[i]) && Number.isFinite(ys[i])) {
          if (!path) {
            path = [];
            paths.push(path);
          }
          path.push([xs[i], ys[i]]);
        } else {
          path = null;
        }
      }
      return paths.map((points) => {
        if (points.some(([x], i) => i > 0 && x < points[i - 1][0])) {
          points.sort((a, b) => a[0] - b[0]);
        }
        return points;
      });
    },

    // Evaluates or linearly interpolates a curve's y-value at a given x
    sampleYAt(spec, pts, sliderEnv, x, cursor) {
      if (spec.isExplicitYX) {
        const paramVec = CurveEvaluator.buildParamVector(spec, sliderEnv);
        paramVec[spec.paramIndexByName.get("x")] = x;
        const out = [null, null];
        spec.evalPoint(out, paramVec);
        return out[1];
      }
      const eps = 1e-12 * Math.max(1, Math.abs(x));
      if (x < pts[0][0] - eps || x > pts[pts.length - 1][0] + eps) return null;
      if (x <= pts[0][0] + eps) return pts[0][1];
      if (x >= pts[pts.length - 1][0] - eps) return pts[pts.length - 1][1];

      let lo = cursor.idx;
      while (lo + 1 < pts.length - 1 && pts[lo + 1][0] <= x) lo++;
      cursor.idx = lo;
      const [x0, y0] = pts[lo], [x1, y1] = pts[lo + 1];
      return x1 === x0 ? y0 : y0 + ((x - x0) / (x1 - x0)) * (y1 - y0);
    },

    // Merges two sorted x-grids over [lo, hi] using a linear two-pointer scan
    mergeSortedGrid(aPts, bPts, lo, hi) {
      const eps = 1e-12 * Math.max(1, Math.abs(lo), Math.abs(hi));
      const xs = [lo];
      let ia = 0, ib = 0;
      while (ia < aPts.length && aPts[ia][0] <= lo + eps) ia++;
      while (ib < bPts.length && bPts[ib][0] <= lo + eps) ib++;

      while (ia < aPts.length || ib < bPts.length) {
        const xa = (ia < aPts.length && aPts[ia][0] < hi - eps) ? aPts[ia][0] : Infinity;
        const xb = (ib < bPts.length && bPts[ib][0] < hi - eps) ? bPts[ib][0] : Infinity;
        const xNext = Math.min(xa, xb);
        if (!Number.isFinite(xNext)) break;
        if (xa === xNext) ia++;
        if (xb === xNext) ib++;
        if (xNext - xs[xs.length - 1] > eps) xs.push(xNext);
      }
      if (hi - xs[xs.length - 1] > eps) xs.push(hi);
      return xs;
    },

    // Clips polygons to intervals where yLower(x) <= yUpper(x) and interpolates crossings
    clipDirectionalPolygons(xs, getYLower, getYUpper) {
      const outX = [], outY = [];
      let segX = [], segBot = [], segTop = [];
      let prev = null;

      const flush = () => {
        if (segX.length >= 2) {
          if (outX.length > 0) { outX.push(null); outY.push(null); }
          outX.push(...segX, ...segX.slice().reverse());
          outY.push(...segTop, ...segBot.slice().reverse());
        }
        segX = []; segBot = []; segTop = [];
      };

      for (const x of xs) {
        const yA = getYLower(x);
        const yB = getYUpper(x);
        if (!Number.isFinite(yA) || !Number.isFinite(yB)) {
          flush();
          prev = null;
          continue;
        }
        const d = yB - yA;
        if (prev !== null && ((prev.d < 0 && d > 0) || (prev.d > 0 && d < 0))) {
          const t = prev.d / (prev.d - d);
          const xc = prev.x + t * (x - prev.x);
          const yc = prev.yA + t * (yA - prev.yA);
          segX.push(xc); segBot.push(yc); segTop.push(yc);
          if (d < 0) flush();
        }
        if (d >= 0) {
          segX.push(x); segBot.push(yA); segTop.push(yB);
        } else {
          flush();
        }
        prev = { x, yA, d };
      }
      flush();
      return { x: outX, y: outY };
    },

    // Constructs a filled Plotly scatter trace for a shading rule.
    buildTrace(rule, evaluatedMap, sliderEnv, yBounds) {
      const src = rule.fromKind === "curve" ? evaluatedMap.get(rule.from) : null;
      const dst = rule.toKind === "curve" ? evaluatedMap.get(rule.to) : null;
      const color = rule.color || (src || dst).color;
      const baseTrace = {
        type: "scatter",
        name: toSizingText(rule.label || ""),
        mode: "lines",
        line: { width: 0 },
        fill: "toself",
        connectgaps: false,
        fillcolor: colorToRgba(color, rule.opacity),
        hoveron: "fills",
        hoverinfo: rule.label ? "name+x+y" : "skip",
        showlegend: false
      };

      if (src && dst && rule.from === rule.to) {
        return src.shadeSegments[0]?.length === src.xs.length
          ? { ...baseTrace, x: src.xs, y: src.ys }
          : { ...baseTrace, x: [], y: [] };
      }

      const grids = (curve) => curve
        ? curve.shadeSegments.filter((pts) => pts.length >= 2)
        : [[]];
      const constY = (kind, val) => (kind === "const" ? val : (val === "bottom" ? yBounds[0] : yBounds[1]));
      const yFromConst = src ? null : constY(rule.fromKind, rule.from);
      const yToConst = dst ? null : constY(rule.toKind, rule.to);

      const srcGrids = grids(src), dstGrids = grids(dst);
      const outX = [], outY = [];
      for (const a of srcGrids) {
        for (const b of dstGrids) {
          const lo = Math.max(a[0]?.[0] ?? -Infinity, b[0]?.[0] ?? -Infinity, rule.xrange?.[0] ?? -Infinity);
          const hi = Math.min(a.at(-1)?.[0] ?? Infinity, b.at(-1)?.[0] ?? Infinity, rule.xrange?.[1] ?? Infinity);
          if (lo >= hi) continue;

          const xs = this.mergeSortedGrid(a, b, lo, hi);
          const srcCursor = { idx: 0 }, dstCursor = { idx: 0 };
          const poly = this.clipDirectionalPolygons(
            xs,
            (x) => src ? this.sampleYAt(src.spec, a, sliderEnv, x, srcCursor) : yFromConst,
            (x) => dst ? this.sampleYAt(dst.spec, b, sliderEnv, x, dstCursor) : yToConst
          );
          if (poly.x.length === 0) continue;
          if (outX.length > 0) { outX.push(null); outY.push(null); }
          for (let i = 0; i < poly.x.length; i++) {
            outX.push(poly.x[i]);
            outY.push(poly.y[i]);
          }
        }
      }
      return { ...baseTrace, x: outX, y: outY };
    }
  };

  // Synchronizes Plotly axis ranges and colors with the active Bootstrap theme
  const ThemeSync = {
    // Converts linear axis bounds into Plotly's log10 representation when needed
    encodeRange(range, scale) {
      return scale === "log" ? [Math.log10(range[0]), Math.log10(range[1])] : range;
    },

    // Converts Plotly axis range values back into linear domain coordinates
    decodeRange(r0, r1, scale) {
      return scale === "log" ? [Math.pow(10, r0), Math.pow(10, r1)] : [r0, r1];
    },

    // Reads foreground, border, background, and grid colors from CSS custom properties
    getPalette() {
      const s = getComputedStyle(document.body);
      const textColor = s.getPropertyValue("--bs-body-color").trim() || "#212529";
      const borderColor = s.getPropertyValue("--bs-border-color").trim() || "#dee2e6";
      const bgColor = s.getPropertyValue("--bs-body-bg").trim() || "#ffffff";
      return { textColor, borderColor, bgColor, gridColor: `color-mix(in srgb, ${borderColor} 55%, transparent)` };
    },

    // Builds a themed Plotly axis configuration object
    buildAxisTheme(titleText, scale, range, p) {
      const axis = {
        type: scale, automargin: true, color: p.textColor, gridcolor: p.gridColor,
        linecolor: p.borderColor, zerolinecolor: p.borderColor, tickfont: { color: p.textColor }
      };
      if (titleText) axis.title = { text: toSizingText(titleText), font: { color: p.textColor }, standoff: 12 };
      if (range) {
        axis.range = this.encodeRange(range, scale);
        axis.autorange = false;
      }
      return axis;
    },

    // Builds a Plotly.relayout patch for light/dark theme transitions
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

  // Controller managing Plotly rendering, interactive sliders, shading, and math overlays
  class DynamicPlotController {
    constructor(wrapEl, cfg, registry) {
      this.wrapEl = wrapEl;
      this.cfg = cfg;
      this.specs = cfg.curves.map((id, colorIdx) => ({ ...registry.get(id), colorIdx }));
      this.specById = new Map(this.specs.map((s) => [s.id, s]));
      this.curveIdxById = new Map(this.specs.map((s, i) => [s.id, i]));
      this.shadeRules = cfg.shade || [];
      this.hasBoundShade = this.shadeRules.some((r) => r.fromKind === "bound" || r.toKind === "bound");
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

    // Returns the active axis scale configuration
    getScales() {
      return { xscale: this.cfg.xscale, yscale: this.cfg.yscale, zscale: this.cfg.zscale };
    }

    // Returns the active vertical axis bounds for bound-to-curve shading
    getYBounds() {
      return this.zoomYRange || this.cfg.yrange || this.homeYRange || [-1, 1];
    }

    // Checks whether a shading rule and all its referenced curves are visible
    isShadeActive(idx) {
      return Boolean(
        this.shadeVisible[idx] &&
        shadeCurveIds(this.shadeRules[idx]).every((id) => this.curveVisible[this.curveIdxById.get(id)])
      );
    }

    // Checks whether a hidden curve is still required by an active shading rule
    isCurveNeededByVisibleShade(curveId) {
      return this.shadeRules.some((r, i) => this.isShadeActive(i) && shadeCurveIds(r).includes(curveId));
    }

    // Shares compatible sliders and samples each slider's values once.
    collectSliders() {
      const seen = new Map();
      for (const spec of this.specs) {
        for (const p of spec.sliderParams) {
          const domain = JSON.stringify(p.kind === "range" ? [p.min, p.max, p.steps] : p.values);
          const slider = seen.get(p.name);
          if (slider) {
            if (slider.kind !== p.kind || slider.domain !== domain) {
              throw new Error(`Conflicting definitions for shared slider "${p.name}"`);
            }
            slider.play ||= Boolean(p.play);
          } else {
            seen.set(p.name, {
              name: p.name, label: p.label, kind: p.kind, domain,
              values: Domain.sampleParam(p, p.steps),
              play: Boolean(p.play), isPlaying: false, playRaf: null, playBtn: null,
              index: 0, inputEl: null, valueEl: null
            });
          }
        }
      }
      return Array.from(seen.values());
    }

    // Builds a map of current slider parameter values
    getSliderEnv() {
      const env = {};
      for (const s of this.sliders) env[s.name] = s.values[s.index];
      return env;
    }

    getXSampleRange() {
      return this.zoomXRange || (this.cfg.xscale === "log" ? this.cfg.xrange : null);
    }

    // Estimates the initial y-axis extent by sweeping one slider at a time.
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
        const scales = this.getScales();
        const baseEnv = this.getSliderEnv();
        const xRange = this.getXSampleRange();
        for (const s of this.sliders) {
          for (let i = 0; i < s.values.length; i++) {
            if (i === s.index) continue;
            const env = { ...baseEnv, [s.name]: s.values[i] };
            for (const spec of this.specs) {
              if (spec.sliderNames.has(s.name)) absorb(CurveEvaluator.evaluate(spec, env, scales, xRange).ys);
            }
          }
        }
      }
      return min <= max ? [min, max] : (positiveOnly ? [0.1, 10] : [-1, 1]);
    }

    // Extends the automatic y range as the user explores combinations of slider values.
    expandHomeYRange(evaluatedMap) {
      if (this.is3d || this.cfg.yrange || this.sliders.length === 0) return false;
      const previous = this.homeYRange;
      let [min, max] = previous;
      this.specs.forEach((spec, idx) => {
        if (!this.curveVisible[idx]) return;
        const entry = evaluatedMap.get(spec.id);
        const extent = entry && Domain.extent(entry.ys, this.cfg.yscale === "log");
        if (extent) {
          min = Math.min(min, extent[0]);
          max = Math.max(max, extent[1]);
        }
      });
      if (min === previous[0] && max === previous[1]) return false;
      this.homeYRange = [min, max];
      return !this.zoomYRange;
    }

    applyHomeYRange() {
      Plotly.relayout(this.canvas, {
        "yaxis.range": ThemeSync.encodeRange(this.cfg.yrange || this.homeYRange, this.cfg.yscale),
        "yaxis.autorange": false
      });
    }

    // Evaluates a curve trace and caches its uninterrupted segments for shading.
    evaluateCurveAt(idx, sliderEnv, scales) {
      const spec = this.specs[idx];
      const res = CurveEvaluator.evaluate(spec, sliderEnv, scales, this.getXSampleRange());
      const color = resolveCurveColor(spec);
      applyTraceColor(res.trace, color);
      const shadeSegments = this.shadeRules.length > 0 ? ShadeBuilder.prepareSegments(res) : [];
      const entry = { ...res, shadeSegments, spec, color };
      this.evalCache[idx] = entry;
      this.evalDirty[idx] = false;
      return entry;
    }

    // Evaluates all shading and curve traces for initial plot rendering
    evaluateAll() {
      const sliderEnv = this.getSliderEnv();
      const scales = this.getScales();
      const evaluatedMap = new Map();

      const curveTraces = this.specs.map((spec, idx) => {
        const entry = this.evaluateCurveAt(idx, sliderEnv, scales);
        entry.trace.visible = this.curveVisible[idx] ? true : "legendonly";
        evaluatedMap.set(spec.id, entry);
        return entry.trace;
      });

      if (!this.homeYRange && !this.is3d) this.homeYRange = this.computeHomeYRange(evaluatedMap);
      const yBounds = this.getYBounds();

      const shadeTraces = this.shadeRules.map((rule, idx) => {
        const trace = ShadeBuilder.buildTrace(rule, evaluatedMap, sliderEnv, yBounds);
        trace.visible = this.isShadeActive(idx) ? true : "legendonly";
        return trace;
      });

      return [...shadeTraces, ...curveTraces];
    }

    // Incrementally updates affected curves, shading polygons, and trace visibility
    restyleTraces({ sliderName = null, resampleZoom = false, syncVis = false } = {}) {
      if (!this.canvas || this.isUpdating) return;
      this.isUpdating = true;
      try {
        const sliderEnv = this.getSliderEnv();
        const scales = this.getScales();
        const shadeCount = this.shadeRules.length;
        const evaluatedMap = new Map();
        const indices = [], xs = [], ys = [], zs = [];

        this.specs.forEach((spec, idx) => {
          const needed = this.curveVisible[idx] || this.isCurveNeededByVisibleShade(spec.id);
          const stale = sliderName !== null
            ? spec.sliderNames.has(sliderName)
            : (resampleZoom ? spec.isExplicitYX : (this.evalDirty[idx] || !this.evalCache[idx]));

          if (stale) {
            if (needed) {
              const entry = this.evaluateCurveAt(idx, sliderEnv, scales);
              indices.push(shadeCount + idx);
              xs.push(entry.trace.x);
              ys.push(entry.trace.y);
              if (this.is3d) zs.push(entry.trace.z);
            } else {
              this.evalDirty[idx] = true;
            }
          }
          if (this.evalCache[idx]) evaluatedMap.set(spec.id, this.evalCache[idx]);
        });

        const expandedY = (sliderName !== null || syncVis) && this.expandHomeYRange(evaluatedMap);
        if (shadeCount > 0) {
          const yBounds = this.getYBounds();
          this.shadeRules.forEach((rule, idx) => {
            if (!this.isShadeActive(idx)) return;
            const stale = sliderName !== null
              ? (expandedY && (rule.fromKind === "bound" || rule.toKind === "bound")) ||
                shadeCurveIds(rule).some((id) => this.specById.get(id).sliderNames.has(sliderName))
              : true;
            if (stale) {
              const trace = ShadeBuilder.buildTrace(rule, evaluatedMap, sliderEnv, yBounds);
              indices.push(idx);
              xs.push(trace.x);
              ys.push(trace.y);
            }
          });
        }

        if (indices.length > 0) {
          Plotly.restyle(this.canvas, this.is3d ? { x: xs, y: ys, z: zs } : { x: xs, y: ys }, indices);
        }
        if (syncVis) {
          const vis = [
            ...this.shadeRules.map((_, i) => (this.isShadeActive(i) ? true : "legendonly")),
            ...this.curveVisible.map((v) => (v ? true : "legendonly"))
          ];
          Plotly.restyle(this.canvas, { visible: vis });
        }
        if (expandedY) this.applyHomeYRange();
      } finally {
        this.isUpdating = false;
      }
    }

    // Creates a toggleable legend checkbox item with a styled trace swatch
    buildLegendItem(entry) {
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
      return item;
    }

    // Builds the collapsible legend sidebar for curves and labeled shading regions
    buildSidebar(bodyEl) {
      if (this.cfg.legend === false) return;
      const items = [
        ...this.specs.map((spec, idx) => ({
          label: spec.rawLabel,
          color: resolveCurveColor(spec),
          mode: spec.mode,
          onToggle: (checked) => { this.curveVisible[idx] = checked; this.restyleTraces({ syncVis: true }); }
        })),
        ...this.shadeRules.flatMap((rule, idx) => !rule.label ? [] : [{
          label: rule.label,
          color: rule.color || resolveCurveColor(this.specById.get(shadeCurveIds(rule)[0])),
          mode: "area",
          onToggle: (checked) => { this.shadeVisible[idx] = checked; this.restyleTraces({ syncVis: true }); }
        }])
      ];
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
      for (const entry of items) sidebar.appendChild(this.buildLegendItem(entry));

      wrap.append(toggleBtn, sidebar);
      bodyEl.appendChild(wrap);
    }

    // Creates a slider control row with optional play/pause animation button
    buildSliderRow(s) {
      const row = document.createElement("div");
      row.className = "dynamic-plot-slider-row";

      if (s.play) {
        const playBtn = document.createElement("button");
        playBtn.type = "button";
        playBtn.className = "dynamic-plot-play-btn";
        playBtn.title = "Play / Pause";
        playBtn.textContent = "\u25B6";
        playBtn.addEventListener("click", () => (s.isPlaying ? this.stopPlay(s) : this.startPlay(s)));
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
      return row;
    }

    // Mounts interactive slider controls beneath the plot canvas
    buildControls() {
      if (this.sliders.length === 0) return;
      const controls = document.createElement("div");
      controls.className = "dynamic-plot-controls";
      const list = document.createElement("div");
      list.className = "dynamic-plot-sliders";
      for (const s of this.sliders) list.appendChild(this.buildSliderRow(s));
      controls.appendChild(list);
      this.stageEl.appendChild(controls);
    }

    // Updates a slider's active step index, readout text, and dependent traces
    setSliderIndex(slider, idx) {
      slider.index = idx;
      if (slider.inputEl) slider.inputEl.value = String(idx);
      if (slider.valueEl) slider.valueEl.textContent = formatNumber(slider.values[idx]);
      this.restyleTraces({ sliderName: slider.name });
    }

    // Starts animation playback across a slider's discrete steps
    startPlay(slider) {
      if (slider.isPlaying || slider.values.length < 2) return;
      slider.isPlaying = true;
      if (slider.playBtn) slider.playBtn.textContent = "\u275A\u275A";
      if (slider.index >= slider.values.length - 1) this.setSliderIndex(slider, 0);
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

    // Stops active animation playback for a slider
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

    // Constructs the initial 2D or 3D Plotly layout object
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

    // Positions a rendered HTML math label over a hidden SVG axis title
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

    // Re-renders LaTeX axis title overlays after layout or resize changes
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

    // Binds Plotly zoom/pan relayout handlers and a container resize observer
    attachEvents() {
      this.canvas.on("plotly_relayout", (ev) => {
        if (!this.is3d && !this.isUpdating && ev) {
          let changed = false;
          if (ev["xaxis.autorange"] || ev["yaxis.autorange"]) {
            this.zoomXRange = null;
            this.zoomYRange = null;
            if ((this.sliders.length > 0 || this.hasBoundShade) && this.canvas.layout?.yaxis) {
              this.applyHomeYRange();
            }
            changed = true;
          } else {
            if (ev["xaxis.range[0]"] !== undefined && ev["xaxis.range[1]"] !== undefined) {
              this.zoomXRange = ThemeSync.decodeRange(Number(ev["xaxis.range[0]"]), Number(ev["xaxis.range[1]"]), this.cfg.xscale);
              changed = true;
            }
            if (ev["yaxis.range[0]"] !== undefined && ev["yaxis.range[1]"] !== undefined) {
              this.zoomYRange = ThemeSync.decodeRange(Number(ev["yaxis.range[0]"]), Number(ev["yaxis.range[1]"]), this.cfg.yscale);
              changed = true;
            }
          }
          if (changed) this.restyleTraces({ resampleZoom: true });
        }
        this.syncMathOverlays();
      });

      this.canvas.on("plotly_restyle", () => this.syncMathOverlays());

      let raf = null;
      new ResizeObserver(() => {
        cancelAnimationFrame(raf);
        raf = requestAnimationFrame(() => {
          Plotly.Plots.resize(this.canvas);
          this.syncMathOverlays();
        });
      }).observe(this.stageEl);
    }

    // Builds the plot DOM structure, renders Plotly, and initializes listeners
    mount() {
      const traces = this.evaluateAll();
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

      Plotly.newPlot(this.canvas, traces, this.buildLayout(ThemeSync.getPalette()), {
        responsive: true,
        displaylogo: false
      });

      this.attachEvents();
      this.syncMathOverlays();
    }

    // Updates Plotly colors and math overlays when the document theme changes
    syncTheme() {
      if (!this.canvas?.layout) return;
      Plotly.relayout(this.canvas, ThemeSync.getThemeRelayout(this.is3d));
      this.syncMathOverlays();
    }
  }

  // Pre-renders math labels, loads Plotly, and mounts all dynamic plot controllers
  async function initDynamicPlots() {
    const wraps = Array.from(document.querySelectorAll(".dynamic-plot-wrap"));
    if (wraps.length === 0) return;

    const registry = new Map();
    const curveErrors = new Map();
    const mathStrings = [];
    const { defs, configs, sliderSteps } = JSON.parse(document.querySelector("script.dynamic-plot-data").textContent);

    defs.forEach((def) => {
      try {
        registry.set(def.id, CurveEvaluator.prepare(def, sliderSteps));
      } catch (error) {
        curveErrors.set(def.id, `Invalid expression: ${error.message}`);
        return;
      }
      if (hasMathDelimiters(def.label)) mathStrings.push(def.label);
      for (const p of def.params || []) {
        if (p.isSlider && hasMathDelimiters(p.label)) mathStrings.push(p.label);
      }
    });

    configs.forEach((cfg) => {
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
      .flatMap((w) => {
        w.dataset.initialized = "true";
        const cfg = configs[Number(w.dataset.plotIdx) - 1];
        const failedCurve = cfg.curves.find((id) => curveErrors.has(id));
        let errorMessage;
        if (failedCurve) {
          errorMessage = `Cannot plot curve "${failedCurve}": ${curveErrors.get(failedCurve)}`;
        } else {
          try {
            return [new DynamicPlotController(w, PlotOptions.canvas(cfg), registry)];
          } catch (error) {
            errorMessage = `Cannot render plot: ${error.message}`;
          }
        }

        const message = document.createElement("p");
        message.className = "alert alert-danger m-3";
        message.setAttribute("role", "alert");
        message.textContent = errorMessage;
        w.appendChild(message);
        return [];
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
