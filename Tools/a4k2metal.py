"""Chuyển shader Anime4K (định dạng hook của mpv) sang kernel Metal.

Chỉ hỗ trợ đúng dạng các tệp Upscale_CNN_x2 / 3DGraphics_*_Upscale_x2: vài lớp tích chập 3x3 (mat4 * go_k(dx, dy) + bias)
rồi một bước Depth-to-Space cộng phần dư vào ảnh gốc phóng song tuyến.
Dùng: python3 a4k2metal.py <tệp.glsl> <tiền tố> > ra.metal
"""
import re
import sys

src = open(sys.argv[1], encoding="utf-8").read()
prefix = sys.argv[2]

blocks = re.split(r"(?m)^//!DESC ", src)[1:]
out = []
names = []
for i, b in enumerate(blocks):
    desc = b.splitlines()[0]
    if "Depth-to-Space" in desc:
        out.append(f"""// {desc}
kernel void {prefix}_d2s(texture2d<float, access::sample> base [[texture(0)]], texture2d<float, access::read> last [[texture(1)]],
                        texture2d<float, access::write> dst [[texture(2)]], uint2 gid [[thread_position_in_grid]]) {{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    constexpr sampler lin(filter::linear, address::clamp_to_edge);
    uint2 lo = min(gid / 2, uint2(last.get_width() - 1, last.get_height() - 1));
    uint2 sub = gid % 2;
    float c = last.read(lo)[sub.y * 2 + sub.x];
    float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
    float4 m = base.sample(lin, uv);
    dst.write(float4(m.rgb + c, 1.0), gid);
}}""")
        names.append(f"{prefix}_d2s")
        continue
    relu = "max(" in b.split("vec4 hook()")[0]
    body = b.split("vec4 hook() {")[1].split("return result;")[0]
    terms = []
    for m in re.finditer(r"mat4\(([^)]*)\)\s*\*\s*go_(\d)\(([-0-9.]+),\s*([-0-9.]+)\)", body):
        nums = [x.strip() for x in m.group(1).split(",")]
        assert len(nums) == 16, desc
        cols = ", ".join("float4(" + ", ".join(nums[c * 4:(c + 1) * 4]) + ")" for c in range(4))
        terms.append((cols, int(m.group(2)), int(float(m.group(3))), int(float(m.group(4)))))
    bias = re.search(r"result \+= vec4\(([^)]*)\);", body).group(1)
    name = f"{prefix}_c{i}"
    names.append(name)
    lines = [f"// {desc}",
             f"kernel void {name}(texture2d<float, access::read> src [[texture(0)]], texture2d<float, access::write> dst [[texture(1)]],",
             "                   uint2 gid [[thread_position_in_grid]]) {",
             "    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;",
             "    int2 p = int2(gid), mx = int2(src.get_width() - 1, src.get_height() - 1);",
             "    float4 t[9];",
             "    for (int k = 0; k < 9; k++) t[k] = src.read(uint2(clamp(p + int2(k / 3 - 1, k % 3 - 1), int2(0), mx)));",
             "    float4 r = float4(" + bias + ");"]
    for cols, g, dx, dy in terms:
        k = (dx + 1) * 3 + (dy + 1)
        if not relu:
            v = f"t[{k}]"
        elif g == 0:
            v = f"max(t[{k}], 0.0)"
        else:
            v = f"max(-t[{k}], 0.0)"
        lines.append(f"    r += float4x4({cols}) * {v};")
    lines.append("    dst.write(r, gid);")
    lines.append("}")
    out.append("\n".join(lines))

print("\n\n".join(out))
print(f"// kernels: {' '.join(names)}", file=sys.stderr)
