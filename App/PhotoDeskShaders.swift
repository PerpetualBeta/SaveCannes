import AppKit
import Metal
import QuartzCore

// The desk's shaders, and the view that drives them.
//
// Compiled from this string at runtime rather than built into a .metallib: it costs
// milliseconds once per launch and keeps the build a single swiftc invocation with no
// Metal toolchain to install.
//
// Two things in here are worth not undoing:
//
//   Both of a print's edges — the paper against the desk, and the picture against the
//   border — are resolved from the screen-space derivative of the card's own coordinate,
//   so each is a pixel wide whatever size or angle the print landed at. The picture edge
//   must be a single coverage blend with NO branch: choosing paper on one side and the
//   picture on the other and *then* fading makes the colour being faded towards jump
//   across the boundary, so half the step survives and the edge reads as stepped however
//   carefully the fade is written.
//
//   The JPEG glitch is really JPEG — an 8x8 DCT quantised with the tables from Annex K
//   of the standard, scaled by libjpeg's own quality formula, with chroma carried at half
//   resolution, then inverted. Blockiness, ringing and colour bleeding across block
//   boundaries are a specific artefact, and an approximation of them just reads as blur.

let deskShaderSource = """

#include <metal_stdlib>
using namespace metal;

constexpr sampler smooth(filter::linear, address::clamp_to_edge);

// MARK: geometry

struct Vertex { float4 position [[position]]; float2 uv; float2 local; };

struct CardUniforms {
    float2 centre;        // pixels, from the top left of the view
    float2 halfSize;      // pixels
    float2 viewportHalf;  // pixels
    float2 apertureHalf;  // the image window, in card-local units
    float  cosR;
    float  sinR;
    float  spread;        // how far the shadow reaches past the paper
    float  landing;       // 0 as it falls, 1 once it is down
    float2 shadowOffset;  // pixels — only while it is still off the desk
    float2 lamp;          // unit vector towards the light, in view space
};

static float4 toClip(float2 local, constant CardUniforms &c, float grow, float2 offset) {
    float2 scaled = local * c.halfSize * grow;
    float2 turned = float2(scaled.x * c.cosR - scaled.y * c.sinR,
                           scaled.x * c.sinR + scaled.y * c.cosR);
    float2 pixel = turned + c.centre + offset;
    return float4(pixel.x / c.viewportHalf.x - 1, 1 - pixel.y / c.viewportHalf.y, 0, 1);
}

vertex Vertex fullQuad(uint id [[vertex_id]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 corner = corners[id];
    Vertex out;
    out.position = float4(corner, 0, 1);
    out.uv = float2((corner.x + 1) * 0.5, 1 - (corner.y + 1) * 0.5);
    out.local = corner;
    return out;
}

vertex Vertex cardVertex(uint id [[vertex_id]], constant CardUniforms &c [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 corner = corners[id];
    Vertex out;
    out.position = toClip(corner, c, 1.0, float2(0));
    out.local = corner;
    out.uv = float2((corner.x + 1) * 0.5, (corner.y + 1) * 0.5);
    return out;
}

vertex Vertex shadowVertex(uint id [[vertex_id]], constant CardUniforms &c [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 corner = corners[id];
    Vertex out;
    out.position = toClip(corner, c, 1.0 + c.spread, c.shadowOffset);
    out.local = corner;
    out.uv = float2((corner.x + 1) * 0.5, (corner.y + 1) * 0.5);
    return out;
}

// MARK: noise

static float hash12(float2 p) {
    float3 q = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    q += dot(q, q.yzx + 33.33);
    return fract((q.x + q.y) * q.z);
}

static float valueNoise(float2 p) {
    float2 cell = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float a = hash12(cell), b = hash12(cell + float2(1, 0));
    float c = hash12(cell + float2(0, 1)), d = hash12(cell + float2(1, 1));
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

// MARK: the desk

struct DeskUniforms { float2 size; float time; float pad; };

fragment float4 deskFragment(Vertex in [[stage_in]], constant DeskUniforms &d [[buffer(0)]]) {
    float2 p = in.uv * float2(d.size.x / d.size.y, 1.0);
    // Wood: grain stretched hard along one axis, with rings pulled through it.
    float grain = valueNoise(p * float2(5.0, 190.0)) * 0.5
                + valueNoise(p * float2(11.0, 420.0)) * 0.3
                + valueNoise(p * float2(3.0, 60.0)) * 0.2;
    float rings = sin((p.x * 7.0 + valueNoise(p * float2(2.2, 9.0)) * 2.4) * 6.2831);
    float wood = 0.5 + 0.28 * grain + 0.06 * rings;
    float3 dark = float3(0.055, 0.038, 0.028);
    float3 light = float3(0.155, 0.108, 0.074);
    float3 colour = mix(dark, light, wood);
    // A lamp somewhere up and to the left, which is what makes it a desk and not a
    // flat backdrop.
    float2 toLamp = in.uv - float2(0.32, 0.12);
    float fall = 1.0 - 0.85 * saturate(length(toLamp * float2(1.0, 1.25)) * 1.05);
    colour *= 0.35 + 0.9 * fall * fall;
    colour += (hash12(in.uv * d.size) - 0.5) * 0.006;   // break up the banding
    return float4(colour, 1);
}

// The desk and everything already lying on it, which is one texture however many
// prints have been and gone.
fragment float4 canvasFragment(Vertex in [[stage_in]], texture2d<float> canvas [[texture(0)]]) {
    return canvas.sample(smooth, in.uv);
}

// MARK: the shadow under a print

fragment float4 shadowFragment(Vertex in [[stage_in]], constant CardUniforms &c [[buffer(0)]]) {
    // Distance out from the paper's edge, in the enlarged quad's own units.
    float grow = 1.0 + c.spread;
    float2 edge = abs(in.local) * grow - 1.0;
    float outside = length(max(edge, 0.0)) + min(max(edge.x, edge.y), 0.0);
    float reach = c.spread * 1.05;
    float alpha = 1.0 - smoothstep(-reach * 0.15, reach, outside);
    // Deeper on the side turned away from the lamp, which is what a contact shadow
    // does and what stops a flat print looking pasted on.
    float2 away = normalize(in.local + float2(1e-6));
    float lit = 0.5 - 0.5 * dot(away, c.lamp);
    float strength = mix(0.30, 0.66, c.landing) * (0.55 + 0.75 * lit);
    return float4(0, 0, 0, alpha * alpha * strength);
}

// MARK: composing the living image, before it is put on the paper

struct ComposeUniforms {
    float2 imageSize;     // pixels of the composed target
    float2 shake;         // in image widths and heights
    float  overscan;
    float  shakeCos;
    float  shakeSin;
    float  focus;         // disparity of the plane held sharp
    float  maxCoc;        // gather pixels, for the breath's current opening
    float  gatherScale;   // composed pixels per gather pixel
    float  level;         // where in the focus stack the breath currently is
    float  pixelBlock;    // image pixels across, 0 for none
    float  staticAmount;
    float  seed;
    float  time;
    float  maskStrength;  // 1 holds a subject sharp, 0 lets the whole picture drift
    float  saturation;    // 1 while it is the living print, 0 once it is buried
    float  pad0;
    float  pad1;
    float  pad2;
};

static float circleOfConfusion(float disparity, float mask, float focus, float maxCoc) {
    float away = abs(disparity - focus) / max(focus, 1e-3);
    return maxCoc * min(away, 1.0) * (1.0 - mask);
}

fragment float4 composeFragment(Vertex in [[stage_in]],
                                texture2d<float> sharp        [[texture(0)]],
                                texture2d_array<float> stack  [[texture(1)]],
                                texture2d<float> depth        [[texture(2)]],
                                texture2d<float> mask         [[texture(3)]],
                                constant ComposeUniforms &u   [[buffer(0)]])
{
    // The hand that is not there. The paper does not move; this does — so the image
    // is drawn a little larger than its window and slides about inside it.
    float2 centred = in.uv - 0.5;
    float2 turned = float2(centred.x * u.shakeCos - centred.y * u.shakeSin,
                           centred.x * u.shakeSin + centred.y * u.shakeCos);
    float2 uv = turned / u.overscan + 0.5 + u.shake;

    if (u.pixelBlock > 1.0) {
        float2 grid = u.imageSize / u.pixelBlock;
        uv = (floor(uv * grid) + 0.5) / grid;
    }
    uv = clamp(uv, 0.0, 1.0);

    float disparity = depth.sample(smooth, uv).r;
    float subject = mask.sample(smooth, uv).r * u.maskStrength;
    float coc = circleOfConfusion(disparity, subject, u.focus, u.maxCoc);

    float3 crisp = sharp.sample(smooth, uv).rgb;
    // Two neighbouring levels of the stack, which between them are a focus drift.
    float slot = clamp(u.level, 0.0, float(%LEVELS% - 1));
    uint lower = uint(floor(slot)), upper = min(lower + 1u, uint(%LEVELS% - 1));
    float3 soft = mix(stack.sample(smooth, uv, lower).rgb,
                      stack.sample(smooth, uv, upper).rgb, fract(slot));
    float3 colour = mix(crisp, soft, saturate(coc * u.gatherScale));

    if (u.staticAmount > 0.0) {
        // Digital static: a fresh field every frame, in bands, so it crawls.
        float2 grain = floor(uv * u.imageSize / 1.5);
        float speck = hash12(grain + float2(u.time * 61.0, u.seed));
        float band = step(0.62, hash12(float2(floor(uv.y * u.imageSize.y / 3.0), u.time * 23.0)));
        colour += (speck - 0.5) * u.staticAmount * (0.45 + band);
    }
    // The life goes out of a print the moment something lands on top of it. Rec. 709,
    // so the grey it leaves behind is the luminance the colour actually had.
    if (u.saturation < 1.0) {
        float grey = dot(colour, float3(0.2126, 0.7152, 0.0722));
        colour = mix(float3(grey), colour, u.saturation);
    }
    return float4(saturate(colour), 1);
}

// MARK: JPEG, actually

struct JpegUniforms { float quality; float chroma; float pad0; float pad1; };

// Annex K of the standard: the tables everybody's encoder starts from.
constant float lumaTable[64] = {
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99
};
constant float chromaTable[64] = {
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99
};

/// libjpeg's own scaling of those tables by a quality number.
static float quantStep(uint index, float quality, bool isChroma) {
    float scale = quality < 50.0 ? 5000.0 / quality : 200.0 - 2.0 * quality;
    float base = isChroma ? chromaTable[index] : lumaTable[index];
    return clamp(floor((base * scale + 50.0) / 100.0), 1.0, 255.0);
}

static float3 toYCbCr(float3 rgb) {
    float y  =  0.299 * rgb.r + 0.587 * rgb.g + 0.114 * rgb.b;
    float cb = -0.168736 * rgb.r - 0.331264 * rgb.g + 0.5 * rgb.b;
    float cr =  0.5 * rgb.r - 0.418688 * rgb.g - 0.081312 * rgb.b;
    return float3(y, cb, cr);
}
static float3 toRGB(float3 ycc) {
    return float3(ycc.x + 1.402 * ycc.z,
                  ycc.x - 0.344136 * ycc.y - 0.714136 * ycc.z,
                  ycc.x + 1.772 * ycc.y);
}
static float basis(uint k) { return k == 0u ? 0.35355339059 : 0.5; }   // 1/sqrt(8), sqrt(2/8)

/// Forward: one thread per coefficient, stored where its own pixel sits, so the
/// coefficient image is exactly the size of the picture.
kernel void jpegForward(texture2d<float, access::read> source [[texture(0)]],
                        texture2d<float, access::write> coefficients [[texture(1)]],
                        constant JpegUniforms &j [[buffer(0)]],
                        uint2 gid [[thread_position_in_grid]])
{
    uint width = source.get_width(), height = source.get_height();
    if (gid.x >= width || gid.y >= height) return;
    uint2 block = (gid / 8u) * 8u;
    uint u = gid.x % 8u, v = gid.y % 8u;

    float3 sum = float3(0);
    for (uint y = 0; y < 8u; ++y) {
        for (uint x = 0; x < 8u; ++x) {
            uint2 at = uint2(min(block.x + x, width - 1u), min(block.y + y, height - 1u));
            // The chroma of a JPEG is carried at half resolution; reading it from
            // every other sample is what makes colour bleed across the blocks.
            uint2 chromaAt = uint2(min((block.x + (x & ~1u)), width - 1u),
                                   min((block.y + (y & ~1u)), height - 1u));
            float3 here = toYCbCr(source.read(at).rgb);
            float3 there = toYCbCr(source.read(chromaAt).rgb);
            float3 ycc = mix(here, float3(here.x, there.yz), j.chroma);
            // Samples run from -128 to 127 in the standard, which is what makes the
            // tables above mean what they say.
            ycc = ycc * 255.0 - float3(128.0, 0.0, 0.0);
            float weight = cos((2.0 * float(x) + 1.0) * float(u) * 3.14159265 / 16.0)
                         * cos((2.0 * float(y) + 1.0) * float(v) * 3.14159265 / 16.0);
            sum += ycc * weight;
        }
    }
    float3 coefficient = sum * basis(u) * basis(v);
    uint index = v * 8u + u;
    float3 step3 = float3(quantStep(index, j.quality, false),
                          quantStep(index, j.quality, true),
                          quantStep(index, j.quality, true));
    coefficient = round(coefficient / step3) * step3;
    coefficients.write(float4(coefficient, 1), gid);
}

kernel void jpegInverse(texture2d<float, access::read> coefficients [[texture(0)]],
                        texture2d<float, access::write> result [[texture(1)]],
                        uint2 gid [[thread_position_in_grid]])
{
    uint width = coefficients.get_width(), height = coefficients.get_height();
    if (gid.x >= width || gid.y >= height) return;
    uint2 block = (gid / 8u) * 8u;
    uint px = gid.x % 8u, py = gid.y % 8u;

    float3 sum = float3(0);
    for (uint v = 0; v < 8u; ++v) {
        for (uint u = 0; u < 8u; ++u) {
            uint2 at = uint2(min(block.x + u, width - 1u), min(block.y + v, height - 1u));
            float3 coefficient = coefficients.read(at).rgb;
            float weight = basis(u) * basis(v)
                         * cos((2.0 * float(px) + 1.0) * float(u) * 3.14159265 / 16.0)
                         * cos((2.0 * float(py) + 1.0) * float(v) * 3.14159265 / 16.0);
            sum += coefficient * weight;
        }
    }
    float3 ycc = (sum + float3(128.0, 0.0, 0.0)) / 255.0;
    result.write(float4(saturate(toRGB(ycc)), 1), gid);
}

// MARK: the print itself

fragment float4 cardFragment(Vertex in [[stage_in]],
                             texture2d<float> image [[texture(0)]],
                             constant CardUniforms &c [[buffer(0)]])
{
    float2 p = in.local;

    // How much of the card one pixel spans, taken from the screen-space derivative of
    // the card's own coordinate — so every edge below is measured in pixels and comes
    // out equally crisp whatever size or angle the print landed at.
    float2 perPixel = max(fwidth(p), 1e-6);

    // Paper: not white. Warm, slightly uneven, with the faintest fibre in it. The 0.82
    // is the tone the border has always had — it used to be applied as a fade that ran
    // across the whole border, which is why it needs saying here instead.
    float fibre = valueNoise(in.uv * 340.0) * 0.5 + valueNoise(in.uv * 90.0) * 0.5;
    float3 paper = float3(0.945, 0.933, 0.912) * 0.82 * (0.975 + 0.025 * fibre);
    // A machine print is cut, not torn: darken the last sliver at the outer edge.
    float2 rim = 1.0 - abs(p);
    float cutPixels = min(rim.x / perPixel.x, rim.y / perPixel.y);
    paper *= mix(0.72, 1.0, saturate(cutPixels / 2.5));

    // Where the picture meets the border, resolved exactly as the paper's outer edge
    // is: the fraction of this pixel the picture covers. Deliberately no branch — one
    // here makes the colour being blended towards jump across the boundary, so half
    // the step survives however carefully the rest is faded, and the edge reads as
    // stepped no matter what.
    float2 fromWindow = (c.apertureHalf - abs(p)) / perPixel;
    float covered = saturate(min(fromWindow.x, fromWindow.y) + 0.5);
    float2 uv = (p / c.apertureHalf + 1.0) * 0.5;
    float3 colour = mix(paper, image.sample(smooth, uv).rgb, covered);

    // The outer edge of the paper, resolved rather than stepped: the fraction of this
    // pixel the card actually covers.
    float coverage = saturate(cutPixels + 0.5);
    return float4(colour, coverage);
}

// MARK: building a print's focus stack

struct GatherUniforms { float focus; float maxCoc; int radius; int slice; };

fragment float4 downsampleFragment(Vertex in [[stage_in]], texture2d<float> sharp [[texture(0)]]) {
    return sharp.sample(smooth, in.uv);
}

kernel void defocus(texture2d<float> colour [[texture(0)]],
                    texture2d<float> depth  [[texture(1)]],
                    texture2d<float> mask   [[texture(2)]],
                    texture2d_array<float, access::write> result [[texture(3)]],
                    constant GatherUniforms &g [[buffer(0)]],
                    uint2 gid [[thread_position_in_grid]])
{
    uint width = result.get_width(), height = result.get_height();
    if (gid.x >= width || gid.y >= height) return;
    float2 size = float2(width, height);
    float2 uv = (float2(gid) + 0.5) / size;

    float here = depth.sample(smooth, uv).r;
    float cocHere = circleOfConfusion(here, mask.sample(smooth, uv).r, g.focus, g.maxCoc);

    float3 accumulated = float3(0);
    float total = 0;
    for (int dy = -g.radius; dy <= g.radius; ++dy) {
        for (int dx = -g.radius; dx <= g.radius; ++dx) {
            float distance = sqrt(float(dx * dx + dy * dy));
            if (distance > g.maxCoc * 0.5) continue;
            float2 there = (float2(gid) + float2(dx, dy) + 0.5) / size;
            float thereDepth = depth.sample(smooth, there).r;
            float coc = circleOfConfusion(thereDepth, mask.sample(smooth, there).r, g.focus, g.maxCoc);
            if (distance > coc * 0.5) continue;
            float weight = 1.0 / max(coc * coc, 1.0);
            if (thereDepth < here) weight *= saturate(cocHere);
            accumulated += colour.sample(smooth, there).rgb * weight;
            total += weight;
        }
    }
    float3 out = total > 0 ? accumulated / total : colour.sample(smooth, uv).rgb;
    result.write(float4(out, 1), gid, uint(g.slice));
}
"""
