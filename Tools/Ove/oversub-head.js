/* OverSub: linh vật đầu tròn 3D, kính mờ thấy lõi cam (three.js r159).
   Vỏ đầu là kính mờ có lỗ tròn phía trước, lõi cam bên trong là khuôn mặt. Độ dày kính trượt theo cảm xúc: ngủ thì
   mỏng và trong (gần logo), hào hứng thì dày lên, bẻ cong ánh sáng nhiều hơn nên lõi cam tràn rộng và ấm hơn.
   Đơn vị: đường kính đầu = 1. Màu mặt, mắt, má hồng và nhịp chớp mắt theo Sources/PhuDe/Mascot.swift. */
(function () {
  'use strict';

  // Đồng hồ thay được khi xuất khung hình cho app (chạy theo thời gian giả lập, không theo đồng hồ thật).
  var clock = function () { return performance.now() / 1000; };
  function now() { return clock(); }
  function rand(a, b) { return a + Math.random() * (b - a); }
  function clamp(x, a, b) { return Math.max(a, Math.min(b, x)); }
  function lerp(a, b, t) { return a + (b - a) * t; }
  function ease(k, dt) { return 1 - Math.exp(-k * dt); }
  function hex(h) { return [parseInt(h.slice(1, 3), 16), parseInt(h.slice(3, 5), 16), parseInt(h.slice(5, 7), 16)]; }
  function mix(a, b, t) { return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]; }
  function css(c, a) {
    return 'rgba(' + Math.round(c[0]) + ',' + Math.round(c[1]) + ',' + Math.round(c[2]) + ',' + (a == null ? 1 : a) + ')';
  }

  var FACE_R = 0.313;                         // bán kính lỗ mặt nhìn từ trước (tỉ lệ 388/620 của icon)
  var CORE_DEFAULT = { r: 0.345, z: 0.012 };  // lõi cam, mặt trước nhô ra sát mép lỗ; mép lõi nấp sau mép lỗ
  var EYE = { w: 0.106, h: 0.213, x: 0.098, y: 0.042 };
  var FACE = {
    asleepLight: [hex('#e3e3e3'), hex('#cccccc')],
    asleepDark: [hex('#4c4c4c'), hex('#363636')],
    idle: [hex('#ffbd91'), hex('#f78566')],
    live: [hex('#ff9e61'), hex('#f2543d')]
  };
  var CHEEK = hex('#ffb5a3');
  // Độ dày và chiết suất của kính ở hai đầu biên độ: mỏng hơn bản pha số 1 khi ngủ, dày như bản số 4 khi hào hứng.
  var GLASS = { thickness: [0.08, 0.36], ior: [1.3, 1.46] };
  var LIGHT = { exposure: 1.0, key: 1.4, hemi: 0.6, rim: 1.0, env: 1.3 };
  var MATS = {
    shell: { color: '#ffffff', roughness: 0.4, transmission: 1, thickness: 0.15, ior: 1.35, clearcoat: 1, clearcoatRoughness: 0.03, specularIntensity: 1 },
    core: { roughness: 0.2, clearcoat: 1, clearcoatRoughness: 0.05 },
    eye: { color: '#ffffff', roughness: 0.18, clearcoat: 1, clearcoatRoughness: 0.03 },
    mouth: { color: '#7d2116', roughness: 0.25, clearcoat: 1, clearcoatRoughness: 0.05 }
  };

  // Ánh xạ tông Khronos PBR Neutral (three r162 mới có sẵn): giữ đúng màu cam của app.
  var neutralReady = false;
  function useNeutral(T) {
    if (neutralReady) return;
    neutralReady = true;
    T.ShaderChunk.tonemapping_pars_fragment = T.ShaderChunk.tonemapping_pars_fragment.replace(
      'vec3 CustomToneMapping( vec3 color ) { return color; }',
      [
        'vec3 CustomToneMapping( vec3 color ) {',
        '  const float S = 0.76; const float D = 0.15;',
        '  color *= toneMappingExposure;',
        '  float x = min( color.r, min( color.g, color.b ) );',
        '  float o = x < 0.08 ? x - 6.25 * x * x : 0.04;',
        '  color -= o;',
        '  float peak = max( color.r, max( color.g, color.b ) );',
        '  if ( peak < S ) return color;',
        '  float d = 1.0 - S;',
        '  float np = 1.0 - d * d / ( peak + d - S );',
        '  color *= np / peak;',
        '  float g = 1.0 - 1.0 / ( D * ( peak - np ) + 1.0 );',
        '  return mix( color, vec3( np ), g );',
        '}'
      ].join('\n'));
  }

  function makeEnv(T, renderer) {
    var s = new T.Scene();
    var geo = new T.SphereGeometry(20, 48, 24);
    var p = geo.attributes.position, col = new Float32Array(p.count * 3);
    var lo = [0.3, 0.25, 0.23], mid = [0.66, 0.6, 0.56], hi = [0.95, 0.92, 0.9];
    for (var i = 0; i < p.count; i++) {
      var y = p.getY(i) / 20;
      var c = y < 0 ? mix(mid, lo, Math.pow(-y, 0.7)) : mix(mid, hi, Math.pow(y, 0.8));
      col[i * 3] = c[0]; col[i * 3 + 1] = c[1]; col[i * 3 + 2] = c[2];
    }
    geo.setAttribute('color', new T.BufferAttribute(col, 3));
    s.add(new T.Mesh(geo, new T.MeshBasicMaterial({ vertexColors: true, side: T.BackSide })));
    function box(w, h, x, y, z, k, c) {
      var m = new T.Mesh(new T.PlaneGeometry(w, h), new T.MeshBasicMaterial({ color: new T.Color(c).multiplyScalar(k), side: T.DoubleSide }));
      m.position.set(x, y, z);
      m.lookAt(0, 0, 0);
      s.add(m);
    }
    box(10, 7, -7, 8, 9, 3.2, '#fff6ee');
    box(5, 10, 10, 1, 6, 1.3, '#fff1e8');
    box(12, 3, 0, 10, -7, 1.8, '#ffffff');
    box(14, 4, 0, -9, 7, 0.5, '#ffd2b8');
    var pm = new T.PMREMGenerator(renderer);
    var rt = pm.fromScene(s, 0.03);
    pm.dispose();
    s.traverse(function (o) { if (o.geometry) o.geometry.dispose(); if (o.material) o.material.dispose(); });
    return rt;
  }

  function radialTexture(T) {
    var c = document.createElement('canvas');
    c.width = c.height = 128;
    var g = c.getContext('2d');
    var r = g.createRadialGradient(64, 64, 0, 64, 64, 64);
    r.addColorStop(0, 'rgba(255,255,255,1)');
    r.addColorStop(0.35, 'rgba(255,255,255,0.62)');
    r.addColorStop(0.68, 'rgba(255,255,255,0.18)');
    r.addColorStop(1, 'rgba(255,255,255,0)');
    g.fillStyle = r;
    g.fillRect(0, 0, 128, 128);
    var tex = new T.CanvasTexture(c);
    tex.colorSpace = T.SRGBColorSpace;
    return tex;
  }

  // Mặt cắt của vỏ đầu (quay quanh trục nhìn): mặt cầu từ gáy ra trước, cuộn tròn ở mép lỗ mặt, rồi vách trong lùi vào.
  function shellProfile(T, rho, wallEnd) {
    var Rh = 0.5, hole = FACE_R;
    rho = rho || 0.03;
    wallEnd = wallEnd == null ? 0.06 : wallEnd;
    var th1 = Math.asin((hole + rho) / (Rh - rho));
    var cr = (Rh - rho) * Math.sin(th1), cz = (Rh - rho) * Math.cos(th1);
    var pts = [];
    for (var i = 0; i <= 72; i++) {
      var ph = Math.PI - (Math.PI - th1) * i / 72;
      pts.push(new T.Vector2(Math.max(0, Rh * Math.sin(ph)), Rh * Math.cos(ph)));
    }
    for (var j = 1; j <= 24; j++) {
      var al = th1 - (th1 + Math.PI / 2) * j / 24;
      pts.push(new T.Vector2(cr + rho * Math.sin(al), cz + rho * Math.cos(al)));
    }
    pts.push(new T.Vector2(hole, wallEnd));
    pts.push(new T.Vector2(hole - 0.03, wallEnd - 0.03));
    return pts;
  }

  var RIPPLE_VS = 'varying vec2 vP; void main(){ vP = position.xy; gl_Position = projectionMatrix * modelViewMatrix * vec4(position,1.0); }';
  // Gợn sóng như giọt nước rơi trên mặt nước: mỗi đợt là một chùm sóng nhỏ loang ra và tắt dần. Mặt sóng được tô theo độ
  // dốc: sườn hướng về ánh sáng (trên trái) sáng lên, sườn kia sẫm nhẹ, nên trông như nước chứ không như nét vẽ.
  var RIPPLE_FS = [
    'uniform float uTime; uniform float uOn; uniform vec3 uColor; uniform float uDark; varying vec2 vP;',
    'void main(){',
    '  float d = length(vP);',
    '  vec2 dir = vP / max(d, 1e-4);',
    '  float slope = 0.0; float body = 0.0;',
    '  for (int i = 0; i < 2; i++) {',
    '    float p = fract(uTime / 3.0 + float(i) / 2.0);',
    '    float R = 0.47 + 0.5 * p;',
    '    float x = d - R;',
    '    float w = 0.05 + 0.04 * p;',
    '    float k = 6.2831 / (0.1 + 0.045 * p);',
    '    float A = pow(1.0 - p, 1.3) * smoothstep(0.0, 0.06, p);',
    '    float e = exp(-x * x / (w * w));',
    '    slope += A * e * (k * cos(k * x) - 2.0 * x / (w * w) * sin(k * x));',
    '    body += A * e;',
    '  }',
    '  float lit = -slope * dot(dir, normalize(vec2(-0.55, 0.83))) * 0.024;',
    '  float edge = smoothstep(0.44, 0.5, d);',
    '  float hi = clamp(lit, 0.0, 1.0) * (uDark > 0.5 ? 0.7 : 0.95);',
    '  float lo = clamp(-lit, 0.0, 1.0) * (uDark > 0.5 ? 0.6 : 0.4);',
    '  float tint = clamp(body, 0.0, 1.0) * 0.2;',
    '  vec3 shade = uDark > 0.5 ? vec3(0.0) : vec3(0.45, 0.2, 0.12);',
    '  float a = clamp(hi + lo + tint, 0.0, 1.0);',
    '  vec3 c = (vec3(1.0) * hi + shade * lo + uColor * tint) / max(hi + lo + tint, 1e-4);',
    '  gl_FragColor = vec4(c, a * uOn * edge);',
    '  #include <colorspace_fragment>',
    '}'
  ].join('\n');

  // ---------------------------------------------------------------- Cảnh dựng

  function Stage(canvas, o) {
    var T = window.THREE, self = this;
    o = o || {};
    var sh = o.shape || {};
    var CORE = this.core = { r: sh.coreR || CORE_DEFAULT.r, z: sh.coreZ == null ? CORE_DEFAULT.z : sh.coreZ };
    this.T = T;
    this.canvas = canvas;
    this.frac = o.frac || 0.6;
    this.backdrops = o.backdrop || { light: '#f6ebe2', dark: '#1d1816' };
    var r = this.renderer = new T.WebGLRenderer({ canvas: canvas, antialias: true, alpha: true, preserveDrawingBuffer: !!o.still });
    r.setClearColor(0x000000, 0);
    r.outputColorSpace = T.SRGBColorSpace;
    useNeutral(T);
    r.toneMapping = T.CustomToneMapping;
    r.toneMappingExposure = LIGHT.exposure;
    r.shadowMap.enabled = true;
    r.shadowMap.type = T.PCFShadowMap;

    var scene = this.scene = new T.Scene();
    this.envRT = makeEnv(T, r);
    scene.environment = this.envRT.texture;
    this.camera = new T.PerspectiveCamera(24, 1, 0.1, 40);

    scene.add(new T.HemisphereLight(0xfff4ec, 0xa08a7e, LIGHT.hemi));
    var key = new T.DirectionalLight(0xfff6ee, LIGHT.key);
    key.position.set(-1.5, 2.2, 3.0);
    key.castShadow = true;
    key.shadow.mapSize.set(512, 512);
    key.shadow.radius = 9;
    key.shadow.blurSamples = 16;
    key.shadow.camera.left = key.shadow.camera.bottom = -0.7;
    key.shadow.camera.right = key.shadow.camera.top = 0.7;
    key.shadow.camera.near = 1; key.shadow.camera.far = 7;
    key.shadow.bias = -0.0005; key.shadow.normalBias = 0.01;
    scene.add(key);
    var rim = new T.DirectionalLight(0xfff0e6, LIGHT.rim);
    rim.position.set(2.0, 1.2, -2.5);
    scene.add(rim);

    // Nền chỉ dùng cho lượt khúc xạ của kính: vẽ vào bộ đệm khúc xạ, không vẽ ra màn hình (khung vẫn trong suốt).
    var bd = this.backdrop = new T.Mesh(new T.PlaneGeometry(12, 12), new T.MeshBasicMaterial({ color: 0xffffff, toneMapped: false }));
    bd.position.z = -2;
    bd.onBeforeRender = function (rr) {
      var onScreen = rr.getRenderTarget() === null;
      bd.material.colorWrite = !onScreen;
      bd.material.depthWrite = !onScreen;
    };
    scene.add(bd);

    // Bóng đổ mềm, quầng cam và sóng loang phía sau: đứng yên, không xoay theo đầu.
    this.radial = radialTexture(T);
    this.shadow = new T.Mesh(new T.PlaneGeometry(1, 1), new T.MeshBasicMaterial({ map: this.radial, color: 0x000000, transparent: true, depthWrite: false }));
    this.shadow.position.set(0, -0.08, -0.7);
    this.glow = new T.Mesh(new T.PlaneGeometry(1, 1), new T.MeshBasicMaterial({ map: this.radial, color: 0xf7564c, transparent: true, depthWrite: false }));
    this.glow.position.set(0, -0.06, -0.68);
    this.ripple = new T.Mesh(new T.PlaneGeometry(2.2, 2.2), new T.ShaderMaterial({
      uniforms: { uTime: { value: 0 }, uOn: { value: 0 }, uDark: { value: 0 }, uColor: { value: new T.Color('#fb8132') } },
      vertexShader: RIPPLE_VS, fragmentShader: RIPPLE_FS, transparent: true, depthWrite: false
    }));
    this.ripple.position.z = -0.66;
    scene.add(this.shadow, this.glow, this.ripple);

    this.root = new T.Group();
    this.head = new T.Group();
    this.root.add(this.head);
    scene.add(this.root);

    this.faceCanvas = document.createElement('canvas');
    this.faceCanvas.width = this.faceCanvas.height = 512;
    this.faceTex = new T.CanvasTexture(this.faceCanvas);
    this.faceTex.colorSpace = T.SRGBColorSpace;
    this.faceTex.anisotropy = 4;
    this.faceKey = '';

    function mat(spec) {
      var p = { metalness: 0, envMapIntensity: LIGHT.env };
      for (var k in spec) p[k] = spec[k];
      return new T.MeshPhysicalMaterial(p);
    }

    // Vỏ đầu bằng kính mờ.
    var shellGeo = new T.LatheGeometry(shellProfile(T, sh.rho, sh.wallEnd), 160);
    shellGeo.rotateX(Math.PI / 2);
    this.shellMat = mat(MATS.shell);
    if (sh.roughness != null) this.shellMat.roughness = sh.roughness;
    this.head.add(new T.Mesh(shellGeo, this.shellMat));

    // Lõi cam: mặt trước là khuôn mặt, tô màu và má hồng bằng ảnh chiếu thẳng từ trước.
    var coreGeo = new T.SphereGeometry(CORE.r, 128, 96);
    var p = coreGeo.attributes.position, uv = coreGeo.attributes.uv, Rt = CORE.r;
    for (var i = 0; i < p.count; i++) {
      if (p.getZ(i) > -0.02) uv.setXY(i, p.getX(i) / (2 * Rt) + 0.5, p.getY(i) / (2 * Rt) + 0.5);
      else uv.setXY(i, 0.5, 0.3);
    }
    var coreSpec = {};
    for (var k in MATS.core) coreSpec[k] = MATS.core[k];
    coreSpec.map = this.faceTex;
    var core = new T.Mesh(coreGeo, mat(coreSpec));
    core.position.z = CORE.z;
    core.receiveShadow = true;
    this.head.add(core);

    // Mắt: viên thuốc dẹt nằm trên mặt cầu, kèm hai nét cong (vui: cong lên, ngủ: cong xuống) dùng chung chất liệu.
    this.eyeMat = mat(MATS.eye);
    var eyeGeo = new T.CapsuleGeometry(EYE.w / 2, EYE.h - EYE.w, 12, 28);
    var arcGeo = new T.TorusGeometry(0.042, 0.012, 12, 40, Math.PI);
    this.eyes = [-1, 1].map(function (sx) {
      var g = new T.Group();
      var pill = new T.Mesh(eyeGeo, self.eyeMat);
      pill.scale.z = 0.45;
      pill.castShadow = true;
      var up = new T.Mesh(arcGeo, self.eyeMat);
      up.position.set(0, -0.012, 0.006);
      var down = new T.Mesh(arcGeo, self.eyeMat);
      down.rotation.z = Math.PI;
      down.position.set(0, 0.006, 0.006);
      g.add(pill, up, down);
      g.userData = { sx: sx, pill: pill, up: up, down: down };
      self.head.add(g);
      return g;
    });

    // Miệng: hình bầu dục khi nói hay ngạc nhiên, nét cong khi cười.
    this.mouthMat = mat(MATS.mouth);
    this.mouth = new T.Mesh(new T.SphereGeometry(0.5, 32, 16), this.mouthMat);
    this.head.add(this.mouth);
    this.smileG = new T.Group();
    var smile = new T.Mesh(new T.TorusGeometry(0.05, 0.011, 12, 40, Math.PI), this.mouthMat);
    smile.rotation.z = Math.PI;
    smile.position.y = 0.022;
    this.smileG.add(smile);
    this.head.add(this.smileG);

    // Lông mày (giận, buồn), miệng mếu và nước mắt: chỉ hiện khi có biểu cảm cần tới.
    var browGeo = new T.CapsuleGeometry(0.011, 0.062, 6, 14);
    this.brows = [-1, 1].map(function (sx) {
      var g = new T.Group(), m = new T.Mesh(browGeo, self.mouthMat);
      m.rotation.z = Math.PI / 2;
      m.scale.z = 0.6;
      g.add(m);
      g.userData = { sx: sx };
      self.head.add(g);
      return g;
    });
    this.frownG = new T.Group();
    var frown = new T.Mesh(new T.TorusGeometry(0.045, 0.011, 12, 40, Math.PI), this.mouthMat);
    frown.position.y = -0.02;
    this.frownG.add(frown);
    this.head.add(this.frownG);
    this.tearMat = mat({ color: '#cfeaff', roughness: 0.05, transmission: 0.35, thickness: 0.03, ior: 1.33, clearcoat: 1, clearcoatRoughness: 0.02, envMapIntensity: 2.2 });
    var tearGeo = new T.SphereGeometry(0.023, 20, 14);
    this.tears = [0, 1, 2, 3].map(function (i) {
      var m = new T.Mesh(tearGeo, self.tearMat);
      m.userData = { sx: i < 2 ? -1 : 1, ph: (i % 2) * 0.5 };
      self.head.add(m);
      return m;
    });

    this.resize(o.width || canvas.clientWidth || 300, o.height || canvas.clientHeight || 300);
  }

  Stage.prototype.onCore = function (x, y, lift) {
    var CORE = this.core;
    return CORE.z + Math.sqrt(Math.max(0, CORE.r * CORE.r - x * x - y * y)) + (lift || 0);
  };

  Stage.prototype.paintFace = function (top, bot, blush) {
    var k = top.concat(bot).map(Math.round).join(',') + '|' + blush.toFixed(3);
    if (k === this.faceKey) return;
    this.faceKey = k;
    var N = 512, g = this.faceCanvas.getContext('2d'), R = this.core.r;
    function X(x) { return (0.5 + x / (2 * R)) * N; }
    function Y(y) { return (0.5 - y / (2 * R)) * N; }
    var lin = g.createLinearGradient(0, Y(FACE_R), 0, Y(-FACE_R));
    lin.addColorStop(0, css(top));
    lin.addColorStop(1, css(bot));
    g.fillStyle = lin;
    g.fillRect(0, 0, N, N);
    [-1, 1].forEach(function (sx) {
      g.save();
      g.translate(X(sx * 0.174), Y(-0.135));
      g.scale(1, 0.55);
      var rad = 0.1 / (2 * R) * N;
      var bl = g.createRadialGradient(0, 0, 0, 0, 0, rad);
      bl.addColorStop(0, css(CHEEK, clamp(0.95 * blush, 0, 1)));
      bl.addColorStop(0.5, css(CHEEK, clamp(0.6 * blush, 0, 1)));
      bl.addColorStop(1, css(CHEEK, 0));
      g.fillStyle = bl;
      g.beginPath();
      g.arc(0, 0, rad, 0, Math.PI * 2);
      g.fill();
      g.restore();
    });
    this.faceTex.needsUpdate = true;
  };

  Stage.prototype.resize = function (w, h) {
    if (!w || !h) return;
    this.renderer.setPixelRatio(Math.min(window.devicePixelRatio || 1, 2));
    this.renderer.setSize(w, h, false);
    var cam = this.camera;
    cam.aspect = w / h;
    cam.position.set(0, 0, 1 / (2 * this.frac * Math.tan(cam.fov * Math.PI / 360) * Math.min(1, w / h)));
    cam.lookAt(0, 0, 0);
    cam.updateProjectionMatrix();
    // Các tấm phía sau nằm xa hơn nên phóng lại cho đúng cỡ khi nhìn.
    var z = cam.position.z;
    [[this.shadow, 1.5, 1.4], [this.glow, 2.0, 2.0], [this.ripple, 1, 1]].forEach(function (e) {
      var f = (z - e[0].position.z) / z;
      e[0].scale.set(e[1] * f, e[2] * f, 1);
    });
  };

  // Vẽ một khung hình theo tư thế. Trường nào thiếu thì lấy giá trị mặc định, nên ảnh tĩnh chỉ cần vài trường.
  Stage.prototype.render = function (q) {
    var T = this.T, self = this, CORE = this.core;
    q = q || {};
    var awake = q.awake == null ? 1 : q.awake;
    var fc = q.top ? [q.top, q.bot] : FACE.live;
    this.paintFace(fc[0], fc[1], q.blush == null ? 0.9 : q.blush);

    this.root.rotation.set(q.orbitPitch || 0, q.orbitYaw || 0, 0, 'YXZ');
    this.head.rotation.set(q.pitch || 0, q.yaw || 0, q.roll || 0, 'YXZ');
    this.head.scale.setScalar(q.scale || 1);
    this.head.position.set(0, q.bob || 0, q.lift || 0);

    var dark = !!q.dark;
    var closed = dark ? [168, 162, 158] : [140, 134, 130];
    var ec = mix(closed, [255, 251, 248], awake);
    this.eyeMat.color.setRGB(ec[0] / 255, ec[1] / 255, ec[2] / 255, T.SRGBColorSpace);

    var ex = q.ex || 0, ey = q.ey || 0, es = q.eyeScale || 1;
    var happy = q.happy || 0, sleep = q.sleep == null ? 1 - awake : q.sleep;
    var open = q.open == null ? 1 : q.open;
    // Đổi dáng mắt qua một nhịp khép như chớp mắt: viên thuốc khép thành vạch ở nửa đầu, nét cong mở ra từ vạch ở nửa sau,
    // nên không có lúc hai hình chồng lên nhau.
    var shut = Math.max(happy, sleep);
    var pillK = clamp(1 - shut * 2, 0, 1);
    var upK = clamp(happy * 2 - 1, 0, 1), downK = clamp(sleep * 2 - 1, 0, 1);
    var pillY = Math.max(0.12, open * es * pillK);
    this.eyes.forEach(function (g) {
      var u = g.userData;
      var x = u.sx * EYE.x * (1 + 0.08 * (es - 1)) + ex, y = EYE.y + ey - 0.02 * downK + 0.012 * upK;
      g.position.set(x, y, self.onCore(x, y, -0.006));
      g.rotation.set(-Math.asin(y / CORE.r), Math.asin(x / CORE.r), 0);
      u.pill.visible = shut < 0.5;
      u.pill.scale.set(es, pillY, 0.45);
      u.pill.rotation.z = u.sx * (q.eyeTilt || 0);
      u.up.visible = happy >= 0.5 && happy >= sleep;
      u.up.scale.set(es, Math.max(0.05, upK) * es, 0.6);
      u.down.visible = sleep >= 0.5 && sleep > happy;
      u.down.scale.set(0.95, Math.max(0.05, downK) * 0.8, 0.6);
    });

    var ov = q.oval || 0, my = -0.13;
    this.mouth.visible = ov > 0.02;
    this.mouth.position.set(0, my, this.onCore(0, my, -0.002));
    this.mouth.rotation.set(-Math.asin(my / CORE.r), 0, 0);
    this.mouth.scale.set((q.ovalW || 0.085) * ov, (q.ovalH || 0.05) * ov, 0.014);
    // Miệng đổi dáng lần lượt: miệng tròn khép lại trước rồi nét cười hay nét mếu mới hiện, không chồng lên nhau.
    var gate = clamp((0.3 - ov) / 0.3, 0, 1);
    var sm = (q.smile || 0) * gate, sy = -0.112;
    this.smileG.visible = sm > 0.02;
    this.smileG.position.set(0, sy, this.onCore(0, sy, -0.004));
    this.smileG.rotation.set(-Math.asin(sy / CORE.r), 0, 0);
    this.smileG.scale.set(sm, sm, 0.6);

    var brow = q.brow || 0, bt = q.browTilt || 0;   // bt > 0: giận (đầu trong cụp xuống), bt < 0: buồn
    this.brows.forEach(function (g) {
      var x = g.userData.sx * 0.1 + ex * 0.5, y = 0.178 - 0.014 * Math.max(bt, 0) + 0.012 * Math.max(-bt, 0) + ey * 0.5;
      g.visible = brow > 0.02;
      g.position.set(x, y, self.onCore(x, y, -0.004));
      g.rotation.set(-Math.asin(y / CORE.r), Math.asin(x / CORE.r), g.userData.sx * 0.42 * bt);
      g.scale.setScalar(Math.max(0.0001, brow));
    });
    var fr = (q.frown || 0) * gate, fy = -0.135;
    this.frownG.visible = fr > 0.02;
    this.frownG.position.set(0, fy, this.onCore(0, fy, -0.004));
    this.frownG.rotation.set(-Math.asin(fy / CORE.r), 0, 0);
    this.frownG.scale.set(fr, fr, 0.6);
    var tw = q.tears || 0, tt = q.t || 0;
    this.tears.forEach(function (m) {
      var u = m.userData, p = (tt * 1.05 + u.ph) % 1;
      var x = u.sx * (EYE.x + 0.014) + ex, y = EYE.y - 0.1 + ey - p * 0.24;
      var k = tw * Math.min(1, p / 0.12) * (1 - Math.max(0, (p - 0.85) / 0.15));
      m.visible = k > 0.02;
      m.position.set(x, y, self.onCore(x, y, 0.006));
      m.scale.set(k, k * 1.35, k * 0.6);
    });

    var gl = q.glass == null ? 0.5 : q.glass;
    this.shellMat.thickness = lerp(GLASS.thickness[0], GLASS.thickness[1], gl);
    this.shellMat.ior = lerp(GLASS.ior[0], GLASS.ior[1], gl);

    this.backdrop.material.color.set(q.backdrop || (dark ? this.backdrops.dark : this.backdrops.light));
    this.shadow.material.opacity = dark ? 0.5 : 0.2;
    this.glow.material.opacity = (q.glow || 0) * (dark ? 0.5 : 0.38);
    this.ripple.visible = (q.ripple || 0) > 0.01;
    this.ripple.material.uniforms.uOn.value = q.ripple || 0;
    this.ripple.material.uniforms.uTime.value = q.t || 0;
    this.ripple.material.uniforms.uDark.value = dark ? 1 : 0;
    this.renderer.render(this.scene, this.camera);
  };

  Stage.prototype.dispose = function () {
    this.scene.traverse(function (o) { if (o.geometry) o.geometry.dispose(); if (o.material) o.material.dispose(); });
    this.faceTex.dispose();
    this.radial.dispose();
    this.envRT.dispose();
    this.renderer.dispose();
  };


  // ---------------------------------------------------------------- Cử động

  function Spring(x, k, z) { this.x = x; this.v = 0; this.k = k; this.c = 2 * Math.sqrt(k) * (z || 1); }
  Spring.prototype.to = function (target, dt) {
    var n = Math.max(1, Math.ceil(dt / 0.01)), h = dt / n;
    for (var i = 0; i < n; i++) {
      var a = this.k * (target - this.x) - this.c * this.v;
      this.v += a * h;
      this.x += this.v * h;
    }
    return this.x;
  };

  function blinkCurve(x) {
    if (x < 0 || x > 0.2) return 0;
    if (x < 0.07) { var u = x / 0.07; return 1 - (1 - u) * (1 - u); }
    if (x < 0.09) return 1;
    var v = (x - 0.09) / 0.11;
    return 1 - v * v;
  }
  function bounceCurve(x) {
    if (x < 0 || x > 1.0) return 1;
    if (x < 0.12) { var u = x / 0.12; return 1 + 0.07 * (1 - Math.pow(1 - u, 3)); }
    var y = x - 0.12;
    return 1 + 0.07 * Math.exp(-6 * y) * Math.cos(13 * y);
  }
  function mouthOpen(t) { return Math.abs(Math.sin(t * 8.6) * Math.cos(t * 3.1)); }
  // Bao biên độ của một biểu cảm: lên nhanh, giữ, rồi lắng dần ở cuối.
  function envelope(e, dur) { return clamp(e / 0.16, 0, 1) * clamp((dur - e) / 0.35, 0, 1); }

  var EXPR = { happy: 1.9, surprised: 1.5, nod: 1.3, look: 3.9, angry: 2.6, cry: 3.6, sad: 1.9, dizzy: 2.2, boop: 1.2, yawn: 1.7, wake: 1.5 };
  var FACE_ANGRY = [[255, 112, 84], [212, 42, 36]];
  var FACE_SAD = [[246, 196, 172], [224, 146, 126]];

  function Live(canvas, o) {
    o = o || {};
    this.canvas = canvas;
    this.stage = new Stage(canvas, { frac: o.frac, backdrop: o.backdrop, shape: o.shape });
    this.mood = o.mood || 'idle';
    this.dark = o.theme === 'dark';
    this.interactive = !!(o.interactive || o.follow);
    this.maxFps = o.fps || 0;
    this.still = !!o.still;   // xuất khung hình: bỏ nhún nhẹ và thở, app tự làm bằng Core Animation
    this.front = !!o.front;   // xuất khung hình: tư thế gốc nhìn thẳng
    this.onToggle = o.onToggle || null;
    this.busyUntil = 0;
    this.scrub = { dir: 0, flips: [], lastX: null, lastT: 0, peak: 0, len: 0 };
    this.s = {
      yaw: new Spring(0, 34, 0.7), pitch: new Spring(0, 34, 0.7), roll: new Spring(0, 26, 0.8),
      ex: new Spring(0, 240, 0.85), ey: new Spring(0, 240, 0.85),
      glass: new Spring(0.3, 22, 0.8), lift: new Spring(0, 50, 0.6)
    };
    var f = this.faceTarget();
    this.v = {
      top: f[0].slice(), bot: f[1].slice(), blush: 0.75, awake: this.mood === 'asleep' ? 0 : 1,
      happy: 0, smile: 0, oval: 0, es: 1, glow: 0, speak: 0,
      brow: 0, browTilt: 0, frown: 0, tears: 0, eyeTilt: 0, cryArc: 0, open: 1
    };
    this.blinkAt = -10; this.blink2At = -10; this.nextBlink = now() + rand(1, 2.5);
    this.look = { yaw: 0, pitch: 0 }; this.lookNext = now() + rand(2, 4); this.lookOn = false;
    this.glance = 0; this.glanceOn = false;
    this.bounceAt = -10; this.nextCue = now() + 3;
    this.expr = null;
    this.orbit = { yaw: 0, pitch: 0, vy: 0, vp: 0, drag: false, released: -10 };
    this.ptr = { x: 0, y: 0, on: false, over: false, at: 0 };
    this.down = null;
    this.clicks = [];
    this.spin = 0;
    this.overSince = 0;
    this.lastTgYaw = 0;
    this.bind();
    this.loop();
  }

  Live.prototype.faceTarget = function () {
    if (this.mood === 'asleep') return this.dark ? FACE.asleepDark : FACE.asleepLight;
    return this.mood === 'idle' ? FACE.idle : FACE.live;
  };

  Live.prototype.setMood = function (m) {
    if (m === this.mood) return;
    var was = this.mood;
    this.mood = m;
    // Tắt giọng đọc thì ngáp rồi ngủ; bật lại thì mở to mắt, nảy lên rồi cười.
    if (was !== 'asleep' && m === 'asleep') this.play('yawn');
    else if (was === 'asleep' && m !== 'asleep') this.play('wake');
    this.glanceOn = false;
    this.lookOn = false; this.look = { yaw: 0, pitch: 0 };
    this.nextBlink = now() + rand(0.6, 1.6);
    if (m === 'speaking') { this.bounceAt = now(); this.nextCue = now() + rand(3.5, 6); }
  };
  Live.prototype.setTheme = function (th) { this.dark = th === 'dark'; };
  Live.prototype.setInteractive = function (on) { this.interactive = !!on; };
  Live.prototype.setFollow = Live.prototype.setInteractive;
  Live.prototype.play = function (name, next) {
    if (!EXPR[name]) return;
    if (this.mood === 'asleep' && name !== 'yawn') return;
    var t = now();
    this.expr = { name: name, t0: t, dur: EXPR[name], next: next || null };
    if (name === 'happy' || name === 'surprised' || name === 'boop' || name === 'angry' || name === 'wake') this.bounceAt = t;
    if (name === 'look') this.blinkAt = t;
  };

  // Bấm: bật hoặc tắt giọng đọc như nút linh vật trong app. Đổi trạng thái ngay tại chỗ rồi báo cho trang. Trong lúc đang
  // ngáp hay đang tỉnh dậy thì bỏ qua cú bấm thêm, để bấm nhanh không làm bật tắt loạn.
  Live.prototype.onClick = function () {
    var t = now();
    if (t < this.busyUntil) return;
    this.busyUntil = t + 1.6;
    var next = this.mood === 'asleep' ? 'idle' : 'asleep';
    this.setMood(next);
    if (this.onToggle) this.onToggle(next);
  };

  // Rung chuột qua lại thật nhanh trên đầu: Ove bực rồi giận. Chỉ tính nhịp nào đi đủ xa (từ 14 px) và đủ nhanh (từ
  // 1100 px/giây), cần sáu nhịp như vậy trong một giây; xoa nhẹ để vuốt ve chậm hơn nhiều nên không bị tính.
  Live.prototype.onScrub = function (x, t) {
    var S = this.scrub;
    if (S.lastX == null || t - S.lastT > 0.25) { S.lastX = x; S.lastT = t; S.dir = 0; S.peak = 0; S.len = 0; return; }
    var dx = x - S.lastX, dt = Math.max(0.004, t - S.lastT);
    if (Math.abs(dx) < 2) return;
    S.lastX = x; S.lastT = t;
    var dir = dx > 0 ? 1 : -1;
    if (S.dir && dir !== S.dir) {
      if (S.peak > 1100 && S.len >= 14) S.flips.push(t);
      S.peak = 0; S.len = 0;
    }
    S.dir = dir;
    S.peak = Math.max(S.peak, Math.abs(dx) / dt);
    S.len += Math.abs(dx);
    S.flips = S.flips.filter(function (f) { return t - f < 1.0; });
    if (S.flips.length >= 6) {
      S.flips = [];
      if (!this.expr || this.expr.name !== 'angry') this.play('angry');
    }
  };

  Live.prototype.bind = function () {
    var self = this, c = this.canvas, lx = 0, ly = 0, lt = 0, O = this.orbit;
    this.onDown = function (e) {
      O.drag = true; lx = e.clientX; ly = e.clientY; lt = now();
      O.vy = O.vp = 0;
      self.down = { x: e.clientX, y: e.clientY, t: lt, moved: 0 };
      try { c.setPointerCapture(e.pointerId); } catch (err) { /* vẫn xoay được khi không bắt được con trỏ */ }
      e.preventDefault();
    };
    this.onMove = function (e) {
      var r = c.getBoundingClientRect();
      if (r.width) {
        var cx = r.left + r.width / 2, cy = r.top + r.height / 2;
        self.ptr.x = clamp((e.clientX - cx) / (r.width * 0.8), -1.2, 1.2);
        self.ptr.y = clamp((e.clientY - cy) / (r.height * 0.8), -1.2, 1.2);
        self.ptr.over = Math.hypot(e.clientX - cx, e.clientY - cy) < self.stage.frac * Math.min(r.width, r.height) / 2 * 1.05;
        self.ptr.on = true; self.ptr.at = now();
        if (self.ptr.over && self.interactive && self.mood !== 'asleep' && !O.drag) self.onScrub(e.clientX, now());
        else { self.scrub.lastX = null; self.scrub.dir = 0; }
      }
      if (self.down) self.down.moved = Math.max(self.down.moved, Math.hypot(e.clientX - self.down.x, e.clientY - self.down.y));
      if (!O.drag) return;
      var t = now(), dt = Math.max(0.008, t - lt);
      var dx = (e.clientX - lx) * 0.011, dy = (e.clientY - ly) * 0.011;
      O.yaw += dx; O.pitch = clamp(O.pitch + dy, -1.2, 1.2);
      O.vy = dx / dt; O.vp = dy / dt;
      self.spin += Math.abs(dx);
      lx = e.clientX; ly = e.clientY; lt = t;
    };
    this.onUp = function () {
      if (self.down) {
        var d = self.down;
        self.down = null;
        if (d.moved < 5 && now() - d.t < 0.4) self.onClick();
      }
      if (!O.drag) return;
      O.drag = false; O.released = now();
      if (now() - lt > 0.08) O.vy = O.vp = 0;
    };
    this.onLeave = function (e) { if (!e.relatedTarget) { self.ptr.on = false; self.ptr.over = false; } };
    c.addEventListener('pointerdown', this.onDown);
    window.addEventListener('pointermove', this.onMove);
    window.addEventListener('pointerup', this.onUp);
    window.addEventListener('pointercancel', this.onUp);
    document.addEventListener('pointerout', this.onLeave);
  };

  Live.prototype.loop = function () {
    var self = this;
    this.visible = true;
    this.last = now();
    // Giới hạn số khung mỗi giây nếu được đặt (màn hình 120 Hz mà vẽ đủ thì tốn gấp bốn lần 30 khung).
    var tick = function () {
      self.raf = requestAnimationFrame(tick);
      if (!self.visible) return;
      var t = now();
      if (self.maxFps && t - self.last < 1 / self.maxFps - 0.004) return;
      var dt = Math.min(0.05, t - self.last);
      self.last = t;
      self.frame(t, dt);
    };
    this.raf = requestAnimationFrame(tick);
    if (window.ResizeObserver) {
      this.ro = new ResizeObserver(function () { self.stage.resize(self.canvas.clientWidth, self.canvas.clientHeight); });
      this.ro.observe(this.canvas);
    }
    if (window.IntersectionObserver) {
      this.io = new IntersectionObserver(function (es) { self.visible = es[es.length - 1].isIntersecting; });
      this.io.observe(this.canvas);
    }
  };

  Live.prototype.frame = function (t, dt) {
    var m = this.mood, awake = m !== 'asleep', S = this.s, V = this.v, O = this.orbit;

    // Nhịp sống: chớp mắt, nhìn quanh khi chờ, liếc sang nút Phụ đề khi nghe, nảy nhẹ khi có câu mới lúc đọc.
    if (awake && t >= this.nextBlink) {
      this.nextBlink = t + rand(2.8, 6.2);
      if (m === 'listening' && Math.random() < 1 / 3) this.glanceOn = !this.glanceOn;
      else { this.blinkAt = t; this.blink2At = Math.random() < 0.2 ? t + 0.23 : -10; }
    }
    if (m === 'idle' && t >= this.lookNext) {
      this.lookOn = !this.lookOn;
      this.look = this.lookOn ? { yaw: rand(-0.35, 0.35), pitch: rand(-0.16, 0.12) } : { yaw: 0, pitch: 0 };
      this.lookNext = t + (this.lookOn ? rand(1.2, 2.2) : rand(3, 6));
    }
    if (m === 'speaking' && t >= this.nextCue) { this.bounceAt = t; this.nextCue = t + rand(3.5, 6.5); }
    this.glance += ((this.glanceOn && m === 'listening' ? 1 : 0) - this.glance) * ease(6, dt);

    var tg = {
      yaw: 0, pitch: 0, roll: 0, glass: 0.4, happy: 0, smile: 0, oval: 0, ovalW: 0.085, ovalH: 0.05, es: 1, lift: 0,
      blushAdd: 0, brow: 0, browTilt: 0, frown: 0, tears: 0, eyeTilt: 0, cryArc: 0, open: 1, angry: 0, sad: 0,
      exAdd: 0, eyAdd: 0, eyeOverride: null
    };
    if (m === 'asleep') { tg.pitch = 0.3; tg.roll = 0.08; tg.glass = 0; }
    else if (m === 'idle') { tg.yaw = this.look.yaw; tg.pitch = this.look.pitch; tg.glass = 0.3; }
    else if (m === 'listening') { tg.yaw = -0.26 - 0.22 * this.glance; tg.pitch = 0.03; tg.roll = -0.05; tg.glass = 0.58; }
    else {
      var mo = mouthOpen(t);
      tg.yaw = 0.05 * Math.sin(t * 0.9); tg.pitch = 0.035 * Math.sin(t * 4.3); tg.roll = 0.03 * Math.sin(t * 1.7);
      tg.glass = 0.62 + 0.38 * mo; tg.oval = 1; tg.ovalW = 0.085 - 0.015 * mo; tg.ovalH = 0.04 + 0.04 * mo;
    }

    // Tương tác bằng chuột: nhìn theo, được vuốt ve thì vui, bị bỏ đi thì buồn, xoay mạnh thì chóng mặt rồi khóc nhè.
    if (this.front) { tg.yaw = 0; tg.pitch = m === 'asleep' ? tg.pitch : 0; tg.roll = m === 'asleep' ? tg.roll : 0; }
    if (this.ptr.on && t - this.ptr.at > 4) { this.ptr.on = false; this.ptr.over = false; }
    var I = this.interactive && awake;
    if (I && this.ptr.on) {
      tg.yaw = clamp(this.ptr.x * 0.8, -0.75, 0.75);
      tg.pitch = clamp(this.ptr.y * 0.55, -0.45, 0.5);
    }
    var petting = false;
    if (I && this.ptr.over && !O.drag) {
      if (!this.overSince) this.overSince = t;
      petting = t - this.overSince > 0.5;
    } else if (this.overSince) {
      if (I && t - this.overSince > 1.6 && !this.expr) this.play('sad');
      this.overSince = 0;
    }
    this.spin *= Math.exp(-dt * 0.6);
    if (!O.drag) this.spin += Math.abs(O.vy) * dt * 0.5;
    if (I && this.spin > 10 && !(this.expr && (this.expr.name === 'dizzy' || this.expr.name === 'cry'))) {
      this.spin = 0;
      this.play('dizzy', 'cry');
    }

    var ex0 = this.expr;
    var yawning = !!(ex0 && ex0.name === 'yawn' && t - ex0.t0 < 1.1);
    var ex = this.expr;
    if (ex && t - ex.t0 > ex.dur) {
      var next = ex.next;
      ex = this.expr = null;
      if (next) { this.play(next); ex = this.expr; }
    }
    if (!ex && petting) {
      tg.happy = 1; tg.smile = 1; tg.blushAdd = 0.4; tg.roll += 0.1; tg.glass = 0.85;
    }
    if (ex && !awake && ex.name === 'yawn') {
      var ey0 = t - ex.t0, o = Math.sin(Math.PI * Math.min(ey0 / 1.2, 1));
      tg.oval = o; tg.ovalW = 0.07 + 0.02 * o; tg.ovalH = 0.04 + 0.07 * o;
      tg.pitch = lerp(tg.pitch, -0.12, o); tg.roll = lerp(tg.roll, 0.1, o); tg.cryArc = o; tg.glass = lerp(0.3, tg.glass, ey0 / 1.7);
    }
    if (ex && awake) {
      var e = t - ex.t0, env = envelope(e, ex.dur);
      if (ex.name === 'happy') {
        tg.happy = env; tg.smile = env; tg.oval *= 1 - env; tg.roll += 0.14 * env; tg.pitch -= 0.06 * env;
        tg.glass = lerp(tg.glass, 1, env); tg.blushAdd = 0.35 * env;
      } else if (ex.name === 'surprised') {
        tg.es = 1 + 0.2 * env; tg.oval = Math.max(tg.oval * (1 - env), env);
        tg.ovalW = lerp(tg.ovalW, 0.052, env); tg.ovalH = lerp(tg.ovalH, 0.07, env);
        tg.pitch -= 0.14 * env; tg.glass = lerp(tg.glass, 1, env); tg.lift = -0.05 * env;
      } else if (ex.name === 'boop') {
        var first = e < 0.42 ? 1 : 0;
        tg.es = 1 + 0.15 * first; tg.oval = first; tg.ovalW = 0.05; tg.ovalH = 0.06; tg.lift = -0.03 * first;
        tg.happy = (1 - first) * env; tg.smile = (1 - first) * env; tg.blushAdd = 0.3 * env; tg.glass = lerp(tg.glass, 0.9, env);
      } else if (ex.name === 'wake') {
        var pop = e < 0.45 ? 1 : 0;
        tg.es = 1 + 0.22 * pop; tg.lift = -0.04 * pop; tg.pitch -= 0.1 * pop;
        tg.happy = (1 - pop) * env; tg.smile = (1 - pop) * env; tg.blushAdd = 0.3 * env; tg.glass = lerp(tg.glass, 0.9, env);
      } else if (ex.name === 'nod') {
        tg.pitch += e < 1.1 ? 0.17 * Math.sin(e / 0.55 * Math.PI * 2) : 0;
      } else if (ex.name === 'look') {
        var path = [[-0.65, 0], [0.65, 0], [0, -0.42], [0, 0.42], [0, 0]];
        var k = Math.min(path.length - 1, Math.floor(e / 0.78));
        tg.yaw = path[k][0]; tg.pitch = path[k][1];
      } else if (ex.name === 'angry') {
        tg.brow = env; tg.browTilt = 1; tg.eyeTilt = 0.28 * env; tg.open = 1 - 0.25 * env; tg.frown = env;
        tg.oval *= 1 - env; tg.angry = env; tg.blushAdd = 0.3 * env; tg.glass = lerp(tg.glass, 1, env);
        tg.yaw = tg.yaw * (1 - env) + 0.09 * Math.sin(e * 32) * env * (e < 1.0 ? 1 : 0.25);
        tg.pitch = tg.pitch * (1 - env) + 0.07 * env;
      } else if (ex.name === 'cry') {
        tg.brow = env; tg.browTilt = -1; tg.cryArc = env; tg.tears = env; tg.sad = 0.6 * env; tg.blushAdd = 0.5 * env;
        tg.oval = env; tg.ovalW = 0.1 + 0.012 * Math.sin(e * 19); tg.ovalH = 0.058 + 0.018 * Math.sin(e * 13);
        tg.pitch = tg.pitch * (1 - env) + (0.06 + 0.035 * Math.sin(e * 15)) * env;
        tg.roll += 0.05 * Math.sin(e * 3) * env; tg.yaw *= 1 - env;
        tg.glass = lerp(tg.glass, 0.15, env);
      } else if (ex.name === 'sad') {
        tg.brow = env; tg.browTilt = -0.8; tg.frown = 0.8 * env; tg.open = 1 - 0.15 * env; tg.eyAdd = -0.012 * env;
        tg.pitch = tg.pitch * (1 - env) + 0.16 * env; tg.yaw *= 1 - env; tg.sad = env; tg.glass = lerp(tg.glass, 0.1, env);
      } else if (ex.name === 'dizzy') {
        tg.eyeOverride = [0.03 * Math.cos(e * 10) * env, 0.03 * Math.sin(e * 10) * env];
        tg.roll += 0.18 * Math.sin(e * 4.5) * env; tg.yaw = tg.yaw * (1 - env) + 0.22 * Math.sin(e * 3.2) * env;
        tg.open = 1 - 0.2 * env; tg.oval = 0.7 * env; tg.ovalW = 0.06; tg.ovalH = 0.03 + 0.012 * Math.sin(e * 9);
        tg.glass = lerp(tg.glass, 0.7, env);
      }
    }

    // Đang đọc thì miệng chỉ mấp máy nói: không cười, không mếu (mắt vẫn theo biểu cảm).
    if (m === 'speaking') { tg.smile = 0; tg.frown = 0; tg.oval = Math.max(tg.oval, 1); }

    // Quay đầu lớn thì chớp mắt một cái cho tự nhiên.
    if (awake && Math.abs(tg.yaw - this.lastTgYaw) > 0.3 && t - this.blinkAt > 0.6) this.blinkAt = t;
    this.lastTgYaw = tg.yaw;

    var yaw = S.yaw.to(tg.yaw, dt), pitch = S.pitch.to(tg.pitch, dt), roll = S.roll.to(tg.roll, dt);
    // Mắt đi trước, đầu theo sau.
    var exT = clamp((tg.yaw - yaw) * 0.1 + tg.yaw * 0.04, -0.04, 0.04) - (m === 'listening' && !I ? 0.012 : 0);
    var eyT = clamp(-(tg.pitch - pitch) * 0.1 - tg.pitch * 0.035, -0.035, 0.035) + tg.eyAdd;
    if (tg.eyeOverride) { exT = tg.eyeOverride[0]; eyT = tg.eyeOverride[1]; }
    var eX = S.ex.to(exT, dt), eY = S.ey.to(eyT, dt);
    var glass = S.glass.to(tg.glass, dt), lift = S.lift.to(tg.lift, dt);

    var k1 = ease(7, dt), k2 = ease(12, dt);
    var f = yawning ? FACE.idle : this.faceTarget();
    var top = f[0], bot = f[1];
    if (tg.angry > 0) { top = mix(top, FACE_ANGRY[0], tg.angry * 0.85); bot = mix(bot, FACE_ANGRY[1], tg.angry * 0.85); }
    if (tg.sad > 0) { top = mix(top, FACE_SAD[0], tg.sad * 0.6); bot = mix(bot, FACE_SAD[1], tg.sad * 0.6); }
    for (var i = 0; i < 3; i++) { V.top[i] += (top[i] - V.top[i]) * k1; V.bot[i] += (bot[i] - V.bot[i]) * k1; }
    var blushT = (!awake && !yawning ? 0.3 : m === 'speaking' ? 1 : m === 'listening' ? 0.9 : 0.75) + tg.blushAdd;
    V.blush += (blushT - V.blush) * k1;
    V.awake += ((awake || yawning ? 1 : 0) - V.awake) * k1;
    ['happy', 'smile', 'oval', 'brow', 'browTilt', 'frown', 'tears', 'eyeTilt', 'cryArc', 'open'].forEach(function (key) {
      V[key] += (tg[key] - V[key]) * k2;
    });
    V.es += (tg.es - V.es) * k2;
    V.speak += ((m === 'speaking' ? 1 : 0) - V.speak) * k1;
    V.glow += ((m === 'speaking' ? 0.55 : m === 'listening' ? 0.32 : awake ? 0.14 : 0) - V.glow) * k1;

    var blink = Math.max(blinkCurve(t - this.blinkAt), blinkCurve(t - this.blink2At));
    var breath = awake || this.still ? 1 : 1 + 0.012 * Math.sin(t * 1.7);
    var bob = awake && !this.still ? 0.006 * Math.sin(t * 1.3) : 0;

    // Kéo chuột để xoay cả linh vật; buông thì trôi theo quán tính rồi về lại góc nhìn thẳng.
    if (!O.drag) {
      if (Math.abs(O.vy) + Math.abs(O.vp) > 0.02) {
        O.yaw += O.vy * dt; O.pitch = clamp(O.pitch + O.vp * dt, -1.2, 1.2);
        var fr = Math.exp(-dt * 3.2);
        O.vy *= fr; O.vp *= fr;
      } else if (t - O.released > 1.4) {
        O.vy = O.vp = 0;
        var home = Math.round(O.yaw / (Math.PI * 2)) * Math.PI * 2, kk = ease(4, dt);
        O.yaw += (home - O.yaw) * kk; O.pitch += (0 - O.pitch) * kk;
      }
    }

    this.stage.render({
      t: t, dark: this.dark, awake: V.awake, top: V.top, bot: V.bot, blush: V.blush,
      orbitYaw: O.yaw, orbitPitch: O.pitch, yaw: yaw, pitch: pitch, roll: roll,
      ex: eX, ey: eY, open: V.open * (1 - 0.88 * blink), eyeScale: V.es, happy: V.happy,
      sleep: Math.max(1 - V.awake, V.cryArc), smile: V.smile, oval: V.oval, ovalW: tg.ovalW, ovalH: tg.ovalH,
      brow: V.brow, browTilt: V.browTilt, frown: V.frown, tears: V.tears, eyeTilt: V.eyeTilt,
      glass: glass, scale: bounceCurve(t - this.bounceAt) * breath, bob: bob, lift: lift,
      glow: V.glow, ripple: V.speak
    });
  };

  Live.prototype.dispose = function () {
    cancelAnimationFrame(this.raf);
    if (this.ro) this.ro.disconnect();
    if (this.io) this.io.disconnect();
    this.canvas.removeEventListener('pointerdown', this.onDown);
    window.removeEventListener('pointermove', this.onMove);
    window.removeEventListener('pointerup', this.onUp);
    window.removeEventListener('pointercancel', this.onUp);
    document.removeEventListener('pointerout', this.onLeave);
    this.stage.dispose();
  };

  window.OverSubHead = {
    Stage: Stage,
    setClock: function (fn) { clock = fn; },
    FACE: FACE,
    create: function (canvas, opts) { return new Live(canvas, opts); }
  };
})();
