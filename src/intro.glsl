// intro4k - every pass of the intro in one source.
//
// main.cpp compiles this file once per pass and prepends:
//   #version 430
//   the config.h values  : _XR _YR (resolution), _NS _TS _BS _BC _LS (volume sizes),
//                          _Q (step scale), _GS (god ray samples), _RS (render scale)
//                          _SR _AW _AB _AU _DU (sample rate, audio row width, block, warm-up, duration)
//                          _SD _SC (camera plan duration and count: a lightning strike on each cut)
//                          _PR (duration of the first camera plan, the prologue)
//                          _CM (the camera plans of cameras.txt, see planCamera())
//                          Debug only: for Release, minify.bat bakes them into a copy of this
//                          file (bake_config.ps1 -> baked/intro.glsl) before minifying
//   the pass id          : _P = 0 noise | 1 density | 2 bricks | 3 light | 4 render | 5 audio | 6 post
//   the stage glue       : _I = compute invocation id, or for the post pass the pixel position (xy)
//                          and 1 inside the picture, 0 in the FULLSCREEN black bars (z)
//                          _O = output color (post pass only)
//                          _C(position, forward) = Debug free camera override, empty in Release
// These short macros are only read through the readable constants below.
//
// World space is the unit box [0,1]^3: a world position is directly a volume uv.
// Write only // comments here: the fallback embedder (embed_shader.ps1) strips nothing else.

const vec2 Resolution = vec2(_XR, _YR);
const int NoiseSize = _NS;
const int DensitySize = _TS;
const int BrickSize = _BS;
const int BrickCount = _BC;
const int LightSize = _LS;
const float StepScale = _Q;
const int GodRaySamples = _GS;
const float RenderScale = float(_RS);
const vec2 RenderSize = Resolution * RenderScale;

const int PassNoise = 0;
const int PassDensity = 1;
const int PassBricks = 2;
const int PassLight = 3;
const int PassRender = 4;
const int PassAudio = 5;
const int PassPost = 6;

layout(location = 0) uniform int uniformSample;   // the clock, in samples of the soundtrack (main.cpp)
// Scene seconds: the clock minus Prologue (the first camera plan comes before the scene, see
// Prologue). main() sets it from uniformSample (the clock) with the same formula as soundtrack(), which
// the audio pass runs for each sample, so the whole timeline (storm, lightning, camera) drives the
// sound too. Every time of the scene below is in scene seconds; only the camera plans (planCamera(),
// the cuts) and the sound fade-in follow the clock.
float time;

// Same unit for the sampler (read, filtered) and the image (write) of each volume.
layout(binding = 0) uniform sampler3D noiseTexture;      // R    : tileable FBM, centered on 0.5
layout(binding = 1) uniform sampler3D densityTexture;    // R, G : cloud density, solid occupancy (the trees)
layout(binding = 2) uniform sampler3D brickTexture;      // R, G : brick contains cloud, solid
layout(binding = 3) uniform sampler3D lightTexture;      // R    : optical depth toward the light, G : sky visibility
layout(rg8, binding = 1) uniform image3D densityImage;
layout(r16f, binding = 0) uniform image3D noiseImage;
layout(rg8, binding = 2) uniform image3D brickImage;
layout(rg16f, binding = 3) uniform image3D lightImage;
layout(binding = 4) uniform sampler2D colorTexture;      // HDR render (with mipmaps when RENDER_SCALE > 1)
layout(rgba16f, binding = 4) uniform image2D colorImage;
layout(rg32f, binding = 5) uniform image2D audioImage;      // RG   : the soundtrack, left and right, AudioWidth samples per row

const float PI = 3.14159265;

// Key light: the moon, lighting the scene through the atmosphere (its color comes from the
// atmosphere transmittance); the sky it scatters gives the ambient light. Its illuminance is 1:
// the brightness is set by Exposure, ColorGrade gives the "day for night" look.
const vec3 MoonDirection = vec3(-0.86, 0.46, 0.18);   // ~normalized (length 1.0007), ~47 degrees up
const vec3 ColorGrade = vec3(0.8, 0.9, 1.0);    // cool moonlight (the teal and orange comes from grade())

const float CloudExtinction = 60.0;     // optical depth per unit of length at density 1
const float CloudScattering = 1.0;      // artistic boost of the in-scattered light
const float SkyVisibilityRange = 0.15;          // length of the sky visibility rays (light pass), box sizes
const int SkyVisibilitySamples = 4;
const float SkyVisibilityFloor = 0.25;          // sky light left in the densest cores
const float FormOffset = 3.0;                   // texels, for the outward direction of the storm density
const float FormStrength = 1.0;                 // 0 = no form shading
const vec3 CloudColor = vec3(0.62, 0.62, 0.66);         // single scattering albedo tint: storm grey
const float AirScattering = 0.03;       // god rays strength
const vec3 FloorAlbedo = vec3(0.37, 0.32, 0.26);         // matte ground, dusty
const float FloorVariation = 0.6;                        // large patches of lighter and darker ground (scale cue)
// Puddles: where the floor noise (at PuddleScale) passes PuddleEdge, lowered by PuddleRise as the
// storm builds (they spread with the rain); darker wet ground (PuddleDark) mirroring the storm and the
// cloud layer (Fresnel: strong at grazing angles). No grass in them (none on the rays ending in one).
const float PuddleScale = 1.5;
const float PuddleEdge = 1.0;
const float PuddleRise = 0.52;
const float PuddleDark = 0.6;
const float FloorShadowRadius = 0.5;    // cloud shadows on the floor up to this distance from the storm axis...
const float FloorShadowFade = 0.5;      // ...faded out over this distance
const float FloorDistantShadow = 0.6;  // beyond: the average moonlight transmittance of the cloud layer

// Height fog: dust and rain hiding the distance, densest at the ground
const float FogDensity = 0.7;           // optical depth per unit of length at the ground
const float FogHeight = 0.5;            // the density falls by e every FogHeight upward
const float ApocalypseFog = 1.8;        // the storm swallows the view: the fog x (1 + ApocalypseFog) at the end, and the vision limit as much closer
const float FogNear = 1.5;              // distance fog on top: none up to FogNear, opaque at FogFar...
const float FogFar = 8.0;               // ...where the cloud layer march also stops
const vec3 FogColor = vec3(0.03, 0.028, 0.026); // moonlit dust (before ColorGrade)

// Lightning: strikes at irregular times, each a burst of flickers lighting the clouds around a
// random point of the cloud deck near the storm, and the fog
const float FlashInterval = 3.0;        // seconds: at most one strike per interval, at a random moment in it
const float FlashProbability = 0.6;     // chance of a strike in an interval
const float LightningStart = 3.0;       // seconds: no strike before (the calm deck already flashes, before the storm builds)
const float ShotDuration = float(_SD);  // seconds per camera plan (config.h SHOT_DURATION): a strike hides each cut...
const float ShotCount = float(_SC);     // ...between two of the SHOT_COUNT plans
const float CutLead = 0.12;             // seconds: a cut strike pre-flashes this long before the cut, then flashes full on it
const float CutFlash = 0.4;             // brightness of the cut strikes, relative to the others
const float ThunderDelay = 0.3;         // seconds per box size between a strike and the listener (sound speed)
const float CameraShake = 0.02;          // the thunder shakes the camera: radians for a close strike...
const float CameraShakeDecay = 3.0;     // ...fading by e in 1 / CameraShakeDecay seconds
const vec3 FlashColor = vec3(2.0, 1.6, 1.08);    // warm: the strikes light the clouds cream and orange
const float FlashFalloff = 8.0;        // the light falls as 1 / (1 + FlashFalloff x distance²) around the strike
const float FlashFogGlow = 1.0;         // how much a strike lights the fog
const float GroundFlash = 1.0;          // light where the bolt hits the ground, relative to the strike point
const float Exposure = 4.0;              // for a projector (was 2.6, made for a monitor): the mid tones about 1.7x as bright on screen, ACES rolls the highlights off
const float Prologue = float(_PR);     // clock seconds before the scene (config.h PROLOGUE): the first camera plan (plan 0, key 0),
                                        // on the scene as it starts (calm deck, no strike yet)
const float Duration = float(_DU) - Prologue;   // scene seconds: the intro ends there
const float FadeIn = 5.0;               // clock seconds of fade from black at the start...
const float SoundFadeIn = 3.0;          // ...and of the sound fade-in: shorter, the wind comes before the picture
const float FadeOut = 5.0;              // seconds of fade to black before Duration...
const float SoundFadeOut = 2.0;         // ...the sound fades later: the storm still rumbles on the black screen
const float ApocalypseStart = 40.0;     // seconds: from there to the end everything grows noisier and darker

// Apocalypse: 0 until ApocalypseStart, 1 two seconds before the end (the sound and the strike shake)
float apocalypse()
{
	return smoothstep(ApocalypseStart, Duration - 2.0, time);
}

// The heartbeat break (see the sound): from BreakStart to BreakEnd (two camera cuts) the storm
// steps back. 1 during the break, easing in on its start and out on its end
const float BreakStart = 70.0;
const float BreakEnd = 80.0;
const float BreakSlow = 0.3;            // the scene's speed on the cut at BreakStart (see main())

float heartBreak()
{
	return smoothstep(BreakStart, BreakStart + 0.3, time) * (1.0 - smoothstep(BreakEnd - 0.1, BreakEnd + 0.1, time));
}

const float OpaqueOpticalDepth = 6.0;   // camera rays stop past this (transmittance < 0.25%). Light rays never stop
                                        // early: any cap gives every voxel of a dense core the same optical depth, so
                                        // the same shade (a flat, clamped looking patch)
const float CloudDiffusion = 0.2;           // thick clouds still let diffused light through, ~ 1 / (1 + CloudDiffusion x optical depth)
const float CloudDiffusionStrength = 0.06;
const float CameraStopOpticalDepth = 1e4;   // camera rays: a stop hides the background completely

float hash(float n)
{
	return fract(43758.55 * sin(12.9898 * n));
}

mat2 rotation(float angle)
{
	float s = sin(angle);
	float i_c = cos(angle);
	return mat2(i_c, s, -s, i_c);
}

// ---------------------------------------------------------------------------- noise (pass 0)
// Ref: https://www.shadertoy.com/view/3dVXDc

vec3 hashGradient(vec3 cell)
{
	const uvec3 primes = uvec3(1597334673U, 3812015801U, 2798796415U);
	uvec3 q = primes * uvec3(ivec3(cell));
	q = primes * (q.x ^ q.y ^ q.z);
	return vec3(q) / 0xffffffffU * 2.0 - 1.0;
}

// Quintic gradient noise, tileable with the given period (in cells).
float gradientNoise(vec3 position, float period)
{
	vec3 cell = floor(position);
	vec3 local = fract(position);
	vec3 blend = local * local * local * (local * (local * 6.0 - 15.0) + 10.0);

	float noise = 0.0;
	for (int corner = 0; corner < 8; corner++)
	{
		vec3 offset = vec3(corner & 1, (corner >> 1) & 1, corner >> 2);
		vec3 weight = mix(1.0 - blend, blend, offset);
		noise += dot(local - offset, hashGradient(mod(cell + offset, period))) * weight.x * weight.y * weight.z;
	}
	return noise;
}

float fbm(vec3 position)
{
	float noise = 0.0;
	float amplitude = 0.5;
	float frequency = 4.0;
	for (int octave = 0; 5 > octave; octave++)
	{
		noise += amplitude * gradientNoise(position * frequency, frequency);
		amplitude *= 0.5;
		frequency *= 2.0;
	}
	return noise;
}

// ---------------------------------------------------------------------------- scene

// ---- Storm (the clouds): a cloud layer whose base starts turning, a funnel descending from it
// and reaching the floor, then a debris whirl. Times in seconds.

const float CumulusStart = 10.0;            // the layer above the box starts turning and builds into the wall cloud (over 10 s)
const float TornadoFormationStart = 20.0;   // the funnel tip starts descending from the wall cloud
const float TornadoTouchdown = 35.0;        // the funnel reaches the floor
const float TornadoSpin = 2.5;              // radians per second (rigid: a radius dependent spin would wind the noise up)
const float TornadoRise = 0.15;             // upward scroll of the noise (inflow)
const float CloudLayerHeight = 0.86;        // middle of the cloud layer (+ CloudLayerHalfThickness stays in the box)
const float WallCloudHeight = 0.8;          // the lowered, rotating base of the layer the funnel hangs from
const float CloudLayerHalfThickness = 0.14; // bound of the layer density around CloudLayerHeight (shape + noise)
const int CloudLayerSamples = 24;           // samples of the layer outside the volume, per ray
const float CloudLayerCoverage = 0.45;      // fraction of the sky covered by the layer (gaps let the moonlight through)
const vec2 CloudLayerWind = vec2(0.2, 0.06);  // layer drift, box sizes per second (x, z)
const float CloudLayerChurn = 0.1;         // how fast the layer's shapes change while drifting

// Axis of the vortex at a height: snakes with height and time, anchored near the box center
vec2 tornadoAxis(float height)
{
	return vec2(0.5) + vec2(sin(height * 4.0 + time * 0.7), cos(height * 3.0 + time * 0.5)) * 0.04 * (height + 0.3);
}

// Funnel radius: narrow at the ground, widening toward the wall cloud
float tornadoRadius(float height)
{
	return 0.035 + 0.2 * height * height;
}

// 0 before the cumulus, 1 once the vortex has spun up and the wall cloud is down
float stormActivity(float at)
{
	return smoothstep(CumulusStart, CumulusStart + 10.0, at);
}

// 0 before the funnel starts descending, 1 at touchdown
float tornadoGrowth()
{
	return smoothstep(TornadoFormationStart, TornadoTouchdown, time);
}

// How much the clouds turn with the vortex: near its axis, once the formation has started
float swirlWeight(float radius)
{
	return smoothstep(0.28, 0.1, radius) * stormActivity(time);
}

// Position carried by the wind: the layer's pattern at a point came from upwind
vec3 windPosition(vec3 position)
{
	return vec3(position.x - time * CloudLayerWind.x, position.y, position.z - time * CloudLayerWind.y);
}

// The cloud layer covers the whole sky. Around the storm it lives in the volume (with the
// vortex); further away it is evaluated directly along the rays (cloud layer section).
// This weight splits it: 0 = in the volume, 1 = direct. The volume fades it out before the
// box faces.
float layerOutsideVolume(vec3 position)
{
	return smoothstep(0.28, 0.36, length(position.xz - 0.5));
}

// Noise coordinates turning with the vortex: (turns around the axis, radius, height).
// The angle is scaled by whole numbers of turns so the tileable noise has no seam.
vec3 tornadoCoordinates(vec3 position, out float radius)
{
	vec2 offset = position.xz - tornadoAxis(position.y);
	float turns = (atan(offset.y, offset.x) - time * TornadoSpin + position.y * 8.0) / (2.0 * PI);
	radius = length(offset);
	return vec3(turns * 4.0, radius * 3.0, 1.2 * position.y - time * TornadoRise);
}

// Noise coordinates of the rest of the layer: drifting with the wind, the shapes changing slowly
vec3 driftCoordinates(vec3 position)
{
	return vec3(0.7, 3.0, 0.7) * windPosition(position) + vec3(0.0, time * CloudLayerChurn, 0.0);
}

// Noise of the cloud layer (outside the vortex): large cells, a second octave at a
// non-integer ratio so the tiling does not show, and a slow regional variation of the coverage
float layerNoise(vec3 position)
{
	vec3 drift = driftCoordinates(position);
	return texture(noiseTexture, drift).r * 0.65 + texture(noiseTexture, drift * 2.37 + 0.3).r * 0.35
	     + (texture(noiseTexture, vec3(0.06 * windPosition(position).xz, 0.5)).r - 0.5) * 0.6;
}

// Layer density from its shape: a slab around CloudLayerHeight, roughened by the noise,
// with gaps where the noise is low
float layerDensity(vec3 position, float noise)
{
	return clamp((0.06 - abs(CloudLayerHeight - position.y)) / 0.03 * 0.4 + (noise - 1.0 + CloudLayerCoverage) * 3.0, 0.0, 1.0);
}

float storm(vec3 position)
{
	float radius;
	vec3 vortex = tornadoCoordinates(position, radius);
	float noise = mix(layerNoise(position), texture(noiseTexture, vortex).r * 0.6 + texture(noiseTexture, vortex * 2.0 + 0.3).r * 0.4, swirlWeight(radius));
	float height = position.y;

	// Shapes as signed fields (> 0 inside), combined then roughened by the noise.
	// Wall cloud: the layer base lowers around the vortex as it spins up
	float wallCloud = (0.1 * (1.0 - radius * 2.4) - abs(WallCloudHeight - height)) / 0.03 - 6.0 * (1.0 - swirlWeight(radius));

	// Funnel: its tip descends from the cloud base, tapered to a point, and reaches the floor at touchdown
	float tip = (1.0 - tornadoGrowth()) * WallCloudHeight;
	float funnel = (tornadoRadius(height) * smoothstep(tip, 0.12 + tip, height) - radius) / 0.03 - 100.0 * max(tip - height, 0.0) - (1.0 - stormActivity(time)) * 10.0;

	// Debris whirl, kicked up after touchdown
	float debris = ((0.08 + height * 0.8) - radius) / 0.04 - 18.0 * height - (1.0 - smoothstep(TornadoTouchdown - 1.0, TornadoTouchdown + 6.0, time)) * 10.0;

	float shape = max(wallCloud, max(funnel, debris));
	// Gentle ramp: with CloudExtinction = 60 a density of 0.2 is already opaque, so a steep one
	// shows the noise iso-contour as a hard cut-out silhouette
	float vortexDensity = clamp(shape * 0.25 + (noise - 0.5) * 2.0, 0.0, 1.0);

	// The part of the cloud layer that lives in the volume
	return max(layerDensity(position, noise) * (1.0 - layerOutsideVolume(position)), vortexDensity);
}

// ---- Trees: TreeCount dead trees standing on the plain around the storm, swaying in the wind as
// it builds, uprooted from touchdown on (the first, then the other two together, with the cut strike) and carried around the funnel,
// then the shrubs: small trees, closer to the storm, uprooted one by one after touchdown,
// tumbling. Solids in the density volume (its G channel, the solid occupancy): the camera rays
// stop on their surface (marchBricks()), shaded by solidLighting(), and the light rays count
// them opaque, so they cast shadows. A signed distance to a tree, its surface inflated by
// TreeInflate (so the branches are at least a texel or two thick), becomes an occupancy.
// Tree n (0, 1, 2 the trees, 3 to 7 the shrubs) has its own size, shape, place, uprooting time and flight.

const float TreeCount = 8.0;            // 3 trees, then 5 shrubs
const float TreeHeight = 0.20;          // box sizes, the first tree (the others are smaller)
const float TreeSway = 0.3;            // bend of the top in the wind, x its height
const float TreeUproot = 4.1;           // seconds between the uprootings: the first at touchdown, the other two together after it
const float ShrubUproot = -0.8;          // seconds between the uprootings of the shrubs, the first that long after touchdown
const float TreeInflate = 0.0007;        // box sizes
const vec3 TreeBark = vec3(0.07, 0.05, 0.04);   // albedo
const float SolidOpticalDepth = 6.0;    // a solid adds this to a light ray (finite: the light volume filters smoothly)

// When tree n is uprooted: the first at touchdown, the second and the third together, TreeUproot later,
// the shrubs one every ShrubUproot seconds
float treeUproot(float n)
{
	return TornadoTouchdown + (2.5 > n ? TreeUproot * min(n, 1.0) : ShrubUproot * (n - 2.0));
}

float treeHeight(float n)
{
	return (2.5 > n ? 1.0 - n * 0.15 : 0.25 + 0.1 * hash(n)) * TreeHeight;
}

// 0 standing, 1 carried by the storm
float treeLift(float n)
{
	return smoothstep(treeUproot(n), treeUproot(n) + 10.0, time);
}

// Where tree n is: its middle (the pivot), standing on the plain around the storm (the shrubs
// nearer, spread between the trees), then carried around the funnel, each on its own orbit (a
// shrub on a random one in the range of the trees': flight)
vec3 treePivot(float n)
{
	float lift = treeLift(n), flight = n < 2.5 ? n : 2.0 * hash(n);
	float orbit = n * 2.1 + 0.3 + step(2.5, n) * n * 1.6 + max(time - treeUproot(n), 0.0) * 3.2 * lift, orbitRadius = mix(n < 2.5 ? 0.33 : 0.27 - 0.1 * hash(9.0 + n), 0.24 + 0.05 * flight, lift);
	return vec3(0.5 + cos(orbit) * orbitRadius, treeHeight(n) * 0.5 + mix(0.0, 0.25 + 0.1 * flight + 0.05 * sin(time + n), lift), 0.5 + orbitRadius * sin(orbit));
}

// Tree n's own coordinates of a point (base at the origin, y up): swaying, or tumbling around its pivot
vec3 treeLocal(vec3 position, float n)
{
	float lift = treeLift(n), height = treeHeight(n);
	vec3 local = position - treePivot(n);
	local.xy *= rotation(time * (1.3 + 0.4 * n) * lift);
	local.yz *= rotation(time * (0.9 - 0.2 * n) * lift);
	local.y += height * 0.5;
	// Sway: the top bends with the gusts, more as the storm builds
	local.x -= height * TreeSway * pow(max(local.y, 0.0) / height, 2.0) * (0.5 + 0.5 * sin(time * 2.7 + 1.7 * n)) * stormActivity(time) * (1.0 - lift);
	return local;
}

// Distance to a tapered capsule from a to b (radii ra, rb)
float capsule(vec3 position, vec3 a, vec3 b, float rb, float ra)
{
	vec3 toA = position - a, ab = b - a;
	float h = clamp(dot(ab, toA) / dot(ab, ab), 0.0, 1.0);
	return length(toA - h * ab) - mix(ra, rb, h);
}

// Signed distance to tree n (its own coordinates): a trunk flaring at the root, TreeBranches
// branches of random angle, rise and length around the upper trunk, three twigs on each,
// alternating sides, the whole bent by a gnarl at two scales
const float TreeBranches = 8.0;

float treeDistance(vec3 position, float n)
{
	vec3 p = position / treeHeight(n);
	p += sin(p.yzx * 13.0 + 1.0 + n) * 0.025 + 0.008 * sin(p.zxy * 31.0);
	float d = capsule(p, vec3(0.0), vec3(0.03, 0.55, 0.0), 0.02, 0.045 + 0.04 * exp(-max(p.y, 0.0) * 30.0));
	for (float i = 0.0; i < TreeBranches; i++)
	{
		float seed = i + 40.0 + 17.0 * n;
		float angle = i * 2.4 + 0.8 * hash(seed);
		vec3 direction = normalize(vec3(cos(angle), 0.4 + 0.8 * hash(seed + 1.0), sin(angle)));
		vec3 a = vec3(0.025, 0.28 + 0.27 * i / TreeBranches, 0.0);
		vec3 b = a + direction * (0.35 + 0.2 * hash(seed + 2.0));
		d = min(d, capsule(p, a, b, 0.005, 0.018));
		for (float k = 1.0; k < 4.0; k++)
		{
			vec3 fork = mix(a, b, 0.15 + 0.25 * k);
			vec3 side = normalize(direction + vec3(-direction.z, 0.5, direction.x) * (mod(k + i, 2.0) * 2.0 - 1.0) * 1.1);
			d = min(d, capsule(p, fork, fork + (0.26 - k * 0.05) * side, 0.002, 0.007));
		}
	}
	return d * treeHeight(n) * 0.7;     // (0.7: the gnarl bends the distance)
}

// Solid occupancy of the trees at a point, the surface at 0.5: for a signed distance d (box
// units), clamp(0.5 - d x DensitySize x 0.25) gives a ~4 texel transition band, smooth enough for
// the normals, sharp enough for the edges. Each tree only inside its bounding sphere (the density
// pass runs for every texel), tested before its own coordinates: around the pivot, which the
// tumbling turns around, 0.75 x its height plus 0.3 for the sway of the top.
float treeSolid(vec3 position)
{
	float solid = 0.0;
	for (float n = 0.0; n < TreeCount; n++)
	{
		float height = treeHeight(n);
		if (length(position - treePivot(n)) < 1.05 * height)
		{
			vec3 local = treeLocal(position, n);
			solid = max(solid, clamp(0.5 - (DensitySize / 4) * (treeDistance(local, n) - TreeInflate), 0.0, 1.0));
		}
	}
	return solid;
}

// The scene, evaluated for every texel of the density volume each frame: (cloud density [0,1],
// solid occupancy of the trees and the shrubs [0,1]).
vec2 density(vec3 position)
{
	// The storm, faded out near the side faces of the box (it touches the floor, and the layer
	// stays under the top face: no fade there, it would not match the layer outside)
	float distanceToFace = min(min(position.x, position.z), 1.0 - max(position.x, position.z));
	return vec2(storm(position) * clamp(distanceToFace * 8.0, 0.0, 1.0), treeSolid(position));
}

// Detail erosion applied to each cloud sample, at a higher frequency than the density volume.
// It follows the same motion as the shapes (vortex or drift), so the detail does not slide.
float erodeCloud(vec3 position, float cloudDensity)
{
	float radius;
	vec3 vortex = tornadoCoordinates(position, radius);
	float detail = mix(texture(noiseTexture, driftCoordinates(position) * 7.0).r, texture(noiseTexture, vec3(3.0, 6.0, 5.0) * vortex).r, swirlWeight(radius));
	return max(cloudDensity - detail * 0.35, 0.0);
}

// ---------------------------------------------------------------------------- sky
// Night sky lit by the fixed moon. A fit (within 3%) of the single scattering of a Rayleigh +
// Mie + ozone atmosphere (Hillaire 2020 parameters, brute force in earlier versions): with the
// moon fixed, the sky only depends on the view direction.

const vec3 MoonLight = vec3(0.93, 0.84, 0.72);      // moon illuminance reaching the scene (atmosphere transmittance)
const vec3 SkyLight = vec3(0.0036, 0.0076, 0.017);  // zenith sky radiance, used as ambient light

float henyeyGreenstein(float g, float cosTheta)
{
	float k = 1.0 + g * g - g * 2.0 * cosTheta;
	return (1.0 - g * g) / (3 * 4.0 * k * sqrt(k));
}

// ---------------------------------------------------------------------------- lightning

// Strike state of the render pass, set at the start of main()
float flash = 0.0;              // intensity now, 0 between the flickers
vec3 flashPosition;             // where the strike leaves the cloud base...
vec3 boltBottom;                // ...and where its bolt hits the ground
float flashSeed;                // the strike flashing (its slot, or its cut + 500.5): the shape of its bolt
vec3 fogLight;                  // fog color, lit up by the strikes
vec4 sheet;                     // sheet lightning: where (xyz) and intensity now (w)

// Sheet lightning: dim flashes deep in the distant cloud layer, no bolt, no thunder, from the start
// (the calm deck already flickers far away). At most one per SheetInterval, at a random moment in it,
// SheetDistance to SheetDistance x 2 from the storm in a random direction, lighting the layer around
// it (marchCloudLayer()) over a wide area
const float SheetInterval = 1.2;
const float SheetProbability = 0.6;
const float SheetDistance = 4.0;
const vec3 SheetColor = vec3(1.0, 0.87, 0.7);
const float SheetFalloff = 0.5;             // the light falls as 1 / (1 + SheetFalloff x distance²)


// Smooth random in 0..1, one value per unit of x (gusts, rumbling, camera shake)
float valueNoise(float x)
{
	float cell = floor(x);
	return mix(hash(cell), hash(cell + 1.0), smoothstep(0.0, 1.0, x - cell));
}

// The strike of a time slot: 1 if the slot has one (0 otherwise), when it starts and where.
// Shared by the light (updateLightning) and the thunder (audio pass), so they always match.
// Strikes from LightningStart on, with the same chance all along.
float strike(float slot, out float start, out vec3 position)
{
	start = (slot + 0.8 * hash(slot)) * FlashInterval;
	position = vec3(0.5 + (hash(slot + 0.75) - 0.5) * 1.2, CloudLayerHeight - 0.08, 0.5 + (hash(slot + 0.125) - 0.5) * 1.2);
	return step(LightningStart, start) * step(hash(slot + 0.25), FlashProbability);
}

// The strike hiding camera cut n, at n x ShotDuration scene seconds (between plans n + 1 and n + 2,
// Prologue being plan 0): CutFlash for the cuts inside the intro (n = 0, at the end of the prologue,
// to ShotCount - 2), 0 otherwise. It starts CutLead before the cut, near the storm.
// Shared by the light and the thunder too.
float cutStrike(float cut, out float start, out vec3 position)
{
	start = ShotDuration * cut - CutLead;
	position = vec3(0.5 + (hash(cut + 3.5) - 0.5) * 0.8, CloudLayerHeight - 0.08, 0.5 + (hash(cut + 7.25) - 0.5) * 0.8);
	return step(0.0, cut) * CutFlash * step(cut, ShotCount - 2.0);
}

// Brightness of a strike age seconds after its start: a few flickers in the first 0.4 s, each decaying fast
float flicker(float slot, float age)
{
	return step(0.0, age) * step(0.5, fract(age * (6.0 + 6.0 * hash(slot + 0.5)))) * exp(-age * 6.0);
}

// Brightness of a cut strike age seconds after its start: a short pre-flash, then the full flash
// on the cut itself (the frame where the view changes), fading with a few flickers
float cutFlicker(float age)
{
	return (step(age, 0.04) * 0.5 + step(CutLead, age) * exp(-(age - CutLead) * 4.0) * (0.7 + 0.3 * step(0.5, fract(age * 8.0)))) * step(0.0, age);
}

void updateLightning()
{
	float slot = floor(time / FlashInterval), cut = floor((time + CutLead) / ShotDuration);
	float start;
	flash = strike(slot, start, flashPosition) * flicker(slot, time - start);
	flashSeed = slot;
	vec3 cutPosition;
	float cutLight = cutStrike(cut, start, cutPosition) * cutFlicker(time - start);
	if (flash < cutLight)
	{
		flash = cutLight;
		flashSeed = cut + 500.5;
		flashPosition = cutPosition;
	}
	boltBottom = vec3(flashPosition.x + (hash(flashSeed + 0.3) - 0.5) * 0.3, 0.0, flashPosition.z + (hash(flashSeed + 0.6) - 0.5) * 0.3);
	fogLight = FogColor * (1.0 + flash * FlashFogGlow);
	slot = floor(time / SheetInterval);
	float angle = hash(slot + 0.91) * 6.28, radius = (hash(slot + 0.77) + 1.0) * SheetDistance;
	sheet = vec4(0.5 + sin(angle) * radius, CloudLayerHeight, 0.5 + cos(angle) * radius, flicker(slot + 0.2, time - (slot + hash(slot + 0.55) * 0.6) * SheetInterval) * step(hash(slot + 0.33), SheetProbability));
}

// Light of the strike reaching a point (scattered inside the clouds, so no shadowing): from the
// strike point in the cloud base, and weaker from where its bolt hits the ground
vec3 flashLight(vec3 position)
{
	vec3 offset = position - flashPosition, ground = position - boltBottom;
	return flash * FlashColor * (1.0 / (1.0 + FlashFalloff * dot(offset, offset)) + GroundFlash / (1.0 + FlashFalloff * dot(ground, ground)));
}

// ---------------------------------------------------------------------------- fog

// Transmittance of the height fog along a ray: the density FogDensity x exp(-height / FogHeight)
// (both fogs thicken with the apocalypse, ApocalypseFog)
// integrated in closed form, times the distance fog (FogNear to FogFar: limits the vision, and
// hides the far cloud layer, where its samples spread too thin). Every element seen through it is mixed toward fogLight
// (its premultiplied color toward fogLight x its opacity): withFog().
float fogTransmittance(vec3 origin, vec3 direction, float distance)
{
	float decay = direction.y / FogHeight;
	if (abs(decay) < 1e-4)
	{
		decay = 1e-4;
	}
	float thick = 1.0 + apocalypse() * ApocalypseFog;
	return (1.0 - smoothstep(FogNear, FogFar, thick * distance)) * exp(-thick * FogDensity * exp(-origin.y / FogHeight) * (1.0 - exp(-decay * distance)) / decay);
}

vec3 withFog(float opacity, vec3 color, vec3 origin, vec3 direction, float distance)
{
	return mix(opacity * fogLight, color, fogTransmittance(origin, direction, distance));
}

// ---------------------------------------------------------------------------- lightning bolt
// The bolt of the strike flashing: a jagged channel from the cloud base (flashPosition) down to
// the ground (boltBottom), BoltSegments straight segments whose inner points are offset sideways
// at random, and a fork leaving it at a random point. Each strike has its own shape (flashSeed),
// kept through its flickers. Seen as light emitted along the camera ray, by the angle between the
// ray and the nearest point of each segment: a thin white-hot core and a wide glow (the bloom of
// the post pass spreads it further). Hidden by opaque cloud and dimmed by the fog in front.

const float BoltSegments = 24.0;
const float BoltJag = 0.04;                     // sideways offset of the channel points, box sizes...
const float BoltWander = 0.05;                  // ...on a slow meander
const vec3 BoltColor = vec3(0.85, 0.9, 1.0);    // the channel is blue-white (the light it casts is warm: FlashColor)
const float BoltBrightness = 60.0;
const float BoltCore = 0.0015;                  // radians: core thickness (~2 pixels at 1080p)
const float BoltGlow = 0.01;                    // radians: glow size...
const float BoltGlowStrength = 0.006;           // ...and strength relative to the core

// Point k (0 = a, BoltSegments = b) of a channel from a to b
vec3 boltPoint(float seed, float k, vec3 a, vec3 b)
{
	vec3 point = mix(a, b, k / BoltSegments);
	// sharp kinks at every point, on a slow meander
	point.xz += ((vec2(hash(seed + k * 0.37), hash(seed + k * 0.71)) - 0.5) * BoltJag + BoltWander * sin(k * vec2(0.5, 0.4) + vec2(7.0, 5.0) * seed)) * step(0.5, k) * step(k, BoltSegments - 0.5);
	return point;
}

// Nearest approach of a ray to the segment a-b: (angle seen from the ray origin, distance along the ray)
vec2 rayToSegment(vec3 direction, vec3 origin, vec3 a, vec3 b)
{
	vec3 ab = b - a, toA = a - origin;
	float t = dot(direction, toA), along = dot(direction, ab);
	float s = clamp((along * t - dot(toA, ab)) / max(dot(ab, ab) - along * along, 1e-6), 0.0, 1.0);
	t = max(t + s * along, 1e-3);
	return vec2(length(toA + s * ab - t * direction) / t, t);
}

// Light of the bolt along a camera ray, hidden past maxDistance (opaque cloud)
vec3 boltLight(vec3 origin, vec3 direction, float maxDistance)
{
	vec3 light = vec3(0.0);
	// The fork leaves the main channel at a random point, heading down and aside, dimming to its tip
	vec3 forkStart = boltPoint(flashSeed, floor(3.0 + 7.0 * hash(flashSeed + 0.9)), flashPosition, boltBottom);
	vec3 forkEnd = forkStart + vec3(hash(flashSeed + 1.3) - 0.5, -0.6 * hash(flashSeed + 1.5), hash(flashSeed + 1.7) - 0.5) * 0.5;
	for (float channel = 0.0; channel < 2.0; channel++)
	{
		vec3 a = channel > 0.5 ? forkStart : flashPosition, previous = a, b = channel > 0.5 ? forkEnd : boltBottom;
		for (float k = 1.0; k <= BoltSegments; k++)
		{
			vec3 next = boltPoint(flashSeed + channel * 0.123, k, a, b);
			vec2 nearest = rayToSegment(direction, origin, previous, next);
			float strength = step(nearest.y, maxDistance) * (channel > 0.5 ? (1.0 - k / BoltSegments) * 0.5 : 1.0) * fogTransmittance(origin, direction, nearest.y);
			light += strength * (exp(-nearest.x * nearest.x / (BoltCore * BoltCore)) + BoltGlowStrength / (1.0 + nearest.x * nearest.x / (BoltGlow * BoltGlow)));
			previous = next;
		}
	}
	return light * BoltColor * BoltBrightness * flash;
}

// ---------------------------------------------------------------------------- lighting

// The only light is the moon: MoonDirection, MoonLight (the light reaching the scene before
// shadowing). Shadow rays toward it stop at LightDistance, beyond the box.
const float LightDistance = 10.0;

// Light scattered toward the camera by a cloud sample: dual-lobe phase function and
// a few multiple-scattering octaves (same model as the RTX demo), plus the ambient light
// (sky light and lightning, times the sky visibility).
vec3 cloudScattering(vec3 rayDirection, float opticalDepth, vec3 ambient, float directForm)
{
	float octaveScale = 1.0;
	float cosTheta = dot(MoonDirection, rayDirection);
	float scattering = 0.0;
	for (int octave = 0; octave < 3; octave++)
	{
		float phase = henyeyGreenstein(0.7 * octaveScale, cosTheta) + henyeyGreenstein(-0.3 * octaveScale, cosTheta);
		scattering += exp(-opticalDepth * octaveScale) * phase * octaveScale;
		octaveScale *= 0.6;
	}
	// Diffusion through optically thick cloud: falls off as a power, not exponentially, so
	// the inside of a dense cloud keeps a gradient (thin parts are left to the octaves)
	scattering += (1.0 - exp(-opticalDepth * 0.5)) * CloudDiffusionStrength / (1.0 + opticalDepth * CloudDiffusion);
	return (scattering * MoonLight * CloudScattering * directForm + ambient) * CloudColor;
}

// Light of a tree surface toward the camera: normal from the occupancy gradient, the moon
// through the clouds (the light volume, looked up slightly outside the surface: inside a solid
// it is fully occluded), the sky light dimmed in creases (occupancy found along the normal), the
// strikes
vec3 solidLighting(vec3 position)
{
	vec2 i_texel = vec2(1.0 / DensitySize, 0.0);
	vec3 normal = normalize(vec3(
		texture(densityTexture, position - i_texel.xyy).g - texture(densityTexture, position + i_texel.xyy).g,
		texture(densityTexture, position - i_texel.yxy).g - texture(densityTexture, position + i_texel.yxy).g,
		texture(densityTexture, position - i_texel.yyx).g - texture(densityTexture, position + i_texel.yyx).g) + 1e-9);
	float occlusion = clamp(1.0 - texture(densityTexture, position + normal * 3.0 / DensitySize).g * 2.0 - texture(densityTexture, position + normal * 6.0 / DensitySize).g, 0.0, 1.0);
	return TreeBark * (MoonLight * max(exp(-texture(lightTexture, position + normal * 2.0 / LightSize).r), 0.2) * max(dot(normal, MoonDirection), 0.0)
		+ ((0.6 + 0.4 * normal.y) * SkyLight + flashLight(position)) * occlusion);
}

// Sky visibility of a point in the volume (light pass): average transmittance of short rays
// along the 6 axes, the sky above weighing more than the ground below. Without it, the dense
// core of the funnel, where no direct light reaches, is a flat constant ambient color.
float skyVisibility(vec3 position)
{
	float visibility = 0.0;
	for (int direction = 0; direction < 6; direction++)
	{
		vec3 axis = vec3(0.0);
		float opticalDepth = 0.0;
		axis[direction % 3] = direction < 3 ? 1.0 : -1.0;
		for (int i = 1; i <= SkyVisibilitySamples; i++)
		{
			// Average detail erosion subtracted, as on the light paths of the cloud layer
			opticalDepth += max(texture(densityTexture, position + axis * SkyVisibilityRange * i / SkyVisibilitySamples).r - 0.175, 0.0);
		}
		visibility += exp(-SkyVisibilityRange * opticalDepth / SkyVisibilitySamples * CloudExtinction) * (1.0 + axis.y * 0.6);
	}
	return visibility / 6.0;
}

// cloudDensity: the density at position (before erosion), for the form term
vec3 cloudLighting(vec3 rayDirection, vec3 position, float cloudDensity)
{
	vec2 light = texture(lightTexture, position).rg;
	// Storm only: the rest of the layer, also evaluated outside the volume, keeps the plain
	// lighting so both halves match
	float radius = length(position.xz - tornadoAxis(position.y));
	float storm = swirlWeight(radius);
	float visibility = 1.0;
	float directForm = 1.0;
	if (storm > 0.0)
	{
		// The light volume is too coarse for the funnel (a few voxels across): its shading
		// also uses the outward direction of the full resolution density, so its sides facing
		// the sky and the light are brighter than the ones facing the ground or away
		float offset = FormOffset / DensitySize;
		vec3 gradient = vec3(
			texture(densityTexture, position + vec3(offset, 0.0, 0.0)).r,
			texture(densityTexture, position + vec3(0.0, offset, 0.0)).r,
			texture(densityTexture, position + vec3(0.0, 0.0, offset)).r) - cloudDensity;
		float confidence = storm * clamp(length(gradient) * 4.0, 0.0, 1.0) * FormStrength;
		vec3 outward = -gradient / max(length(gradient), 1e-5);
		// (never below SkyVisibilityFloor: light scattered many times still reaches the core)
		visibility = mix(1.0, mix(SkyVisibilityFloor, 1.0, light.g), storm) * mix(1.0, 0.45 + 0.55 * (0.5 + 0.5 * outward.y), confidence);
		directForm = mix(1.0, 0.5 + 0.5 * dot(outward, MoonDirection), confidence);
	}
	return cloudScattering(rayDirection, light.r, (SkyLight + flashLight(position)) * visibility, directForm);
}

// ---------------------------------------------------------------------------- brick traversal

// Ray / unit box intersection: (entry, exit) distances, entry clamped to 0.
vec2 intersectBox(vec3 rayOrigin, vec3 rayDirection)
{
	vec3 toMin = -rayOrigin / rayDirection;
	vec3 toMax = (1.0 - rayOrigin) / rayDirection;
	vec3 near = min(toMin, toMax);
	vec3 far = max(toMin, toMax);
	return vec2(max(max(max(near.x, near.y), near.z), 0.0), min(min(far.x, far.y), far.z));
}

// Walks the brick grid front to back with a 3D DDA. Empty bricks are skipped; occupied
// ones are marched with a fixed step aligned on a global grid (no seams between bricks).
//   withShading = true  : camera ray, returns rgb = in-scattered + tree radiance
//   withShading = false : light / shadow ray, only the optical depth is needed
// Returns a = optical depth along the ray. hitDistance = where the ray stopped
// (tree hit or opaque cloud), left untouched otherwise.
vec4 marchBricks(vec3 rayOrigin, vec3 rayDirection, float maxDistance, bool withShading, bool withSolids, float jitter, inout float hitDistance)
{
	vec4 result = vec4(0.0);

	vec2 boxRange = intersectBox(rayOrigin, rayDirection);
	float brickEntry = boxRange.x;
	float rayEnd = min(boxRange.y, maxDistance);
	if (brickEntry >= rayEnd)
	{
		return result;
	}

	float stepLength = 1.0 / (DensitySize * StepScale);
	float sampleDistance = brickEntry + stepLength * jitter, previousSolid = 0.0;

	// DDA setup
	vec3 inverseDirection = 1.0 / rayDirection;
	vec3 distanceBetweenBricks = abs(inverseDirection) / BrickCount;
	ivec3 brick = clamp(ivec3((rayOrigin + rayDirection * brickEntry) * BrickCount), 0, BrickCount - 1);
	ivec3 brickStep = ivec3(sign(rayDirection));
	vec3 distanceToNextBrick = inverseDirection * ((brick + step(0.0, rayDirection)) / BrickCount - rayOrigin);

	for (int iteration = 0; iteration < 3 * BrickCount && brickEntry < rayEnd; iteration++)
	{
		vec2 brickContent = texelFetch(brickTexture, clamp(brick, 0, BrickCount - 1), 0).rg;
		float brickExit = min(min(min(distanceToNextBrick.x, distanceToNextBrick.y), distanceToNextBrick.z), rayEnd);
		if (brickContent.r + brickContent.g > 0.0)
		{
			for (; sampleDistance < brickExit; sampleDistance += stepLength)
			{
				vec3 position = rayOrigin + rayDirection * sampleDistance;
				vec2 content = texture(densityTexture, position).rg;
				float sampleDensity = content.r;

				if (withSolids)
				{
					// Tree: crossed the 0.5 iso-surface, refined linearly with the previous sample
					if (content.g > 0.5)
					{
						sampleDistance -= (content.g - 0.5) * stepLength / max(content.g - previousSolid, 0.01);
						if (withShading)
						{
							result.rgb += exp(-result.a) * solidLighting(rayOrigin + rayDirection * sampleDistance);
						}
						hitDistance = sampleDistance;
						result.a += withShading ? CameraStopOpticalDepth : SolidOpticalDepth;
						return result;
					}
					previousSolid = content.g;
				}
				else
				{
					sampleDensity = max(sampleDensity, content.g);
				}

				// Cloud: energy conserving in-scattering, front to back
				if (sampleDensity > 0.0)
				{
					float sampleOpticalDepth = erodeCloud(position, sampleDensity) * stepLength * CloudExtinction;
					if (withShading)
					{
						result.rgb += exp(-result.a) * (1.0 - exp(-sampleOpticalDepth)) * cloudLighting(rayDirection, position, sampleDensity);
					}
					result.a += sampleOpticalDepth;
					if (withShading && result.a > OpaqueOpticalDepth)
					{
						hitDistance = sampleDistance;
						result.a = CameraStopOpticalDepth;
						return result;
					}
				}
			}
		}
		else
		{
			// Skip the empty brick, staying on the global sample grid
			sampleDistance += stepLength * max(0.0, ceil((brickExit - sampleDistance) / stepLength));
			previousSolid = 0.0;
		}

		// Step into the neighbour brick across the closest face
		vec3 crossedAxis = step(distanceToNextBrick, min(distanceToNextBrick.yzx, distanceToNextBrick.zxy));
		distanceToNextBrick += distanceBetweenBricks * crossedAxis;
		brickEntry = brickExit;
		brick += brickStep * ivec3(crossedAxis);
	}
	return result;
}

// ---------------------------------------------------------------------------- cloud layer
// The cloud layer outside the volume, evaluated directly along the rays with the same density
// as in the volume, so they join seamlessly (layerOutsideVolume()). Its own shadowing is
// estimated from the thickness of layer above the sample toward the light.

// The whole layer (also where it lives in the volume): used for the light paths
float fullLayerDensity(vec3 position)
{
	return layerDensity(position, layerNoise(position));
}

float directLayerDensity(vec3 position)
{
	return layerOutsideVolume(position) * fullLayerDensity(position);
}

// For light paths: the average detail erosion (0.35 x noise of 0.5) instead of sampling it,
// so the light through the layer matches the eroded density in the volume
float lightPathLayerDensity(vec3 position)
{
	return max(fullLayerDensity(position) - 0.175, 0.0);
}

// Range of the ray inside the layer slab, clamped to [start, end]
vec2 layerRange(vec3 rayOrigin, vec3 rayDirection, float end, float start)
{
	vec2 slab = (vec2(CloudLayerHeight - CloudLayerHalfThickness, CloudLayerHeight + CloudLayerHalfThickness) - rayOrigin.y) / rayDirection.y;
	return vec2(max(min(slab.x, slab.y), start), min(max(slab.x, slab.y), min(end, FogFar)));
}

// Layer along a ray between two distances: rgb = in-scattered light, a = optical depth
vec4 marchCloudLayer(vec3 rayOrigin, vec3 rayDirection, float end, float start, float jitter)
{
	vec2 range = layerRange(rayOrigin, rayDirection, end, start);
	vec4 result = vec4(0.0);
	if (range.y <= range.x)
	{
		return result;
	}

	float stepLength = (range.y - range.x) / CloudLayerSamples;
	for (int i = 0; i < CloudLayerSamples; i++)
	{
		vec3 position = rayOrigin + rayDirection * (range.x + stepLength * (i + jitter));
		float sampleDensity = directLayerDensity(position);
		if (sampleDensity > 0.0)
		{
			// Same detail erosion as the layer samples in the volume
			sampleDensity = max(sampleDensity - texture(noiseTexture, driftCoordinates(position) * 7.0).r * 0.35, 0.0);
			float sampleOpticalDepth = sampleDensity * stepLength * CloudExtinction;
			// Light path: 3 samples of the layer toward the light, up to the top of the slab
			float lightLength = max(CloudLayerHeight + CloudLayerHalfThickness - position.y, 0.0) / MoonDirection.y / 3.0;
			float lightOpticalDepth = 0.0;
			for (int j = 0; j < 3; j++)
			{
				lightOpticalDepth += lightPathLayerDensity(position + MoonDirection * lightLength * (j + 0.5));
			}
			lightOpticalDepth *= lightLength * CloudExtinction;
			float opacity = 1.0 - exp(-sampleOpticalDepth);
			result.rgb += exp(-result.a) * withFog(opacity, cloudScattering(rayDirection, lightOpticalDepth, SkyLight + flashLight(position) + SheetColor * sheet.w / (1.0 + SheetFalloff * dot(position - sheet.xyz, position - sheet.xyz)), 1.0) * opacity, rayOrigin, rayDirection, range.x + stepLength * (i + jitter));
			result.a += sampleOpticalDepth;
		}
	}
	return result;
}

// Optical depth of the layer toward the light (shadows of the layer on everything)
float layerOpticalDepth(vec3 position)
{
	vec2 range = layerRange(position, MoonDirection, 1000.0, 0.0);
	float stepLength = (range.y - range.x) / 6.0;
	float opticalDepth = 0.0;
	for (int i = 0; i < 6 && stepLength > 0.0; i++)
	{
		vec3 samplePosition = position + MoonDirection * (range.x + stepLength * (i + 0.5));
		opticalDepth += max(directLayerDensity(samplePosition) - 0.175, 0.0);
	}
	return opticalDepth * max(stepLength, 0.0) * CloudExtinction;
}

// ---------------------------------------------------------------------------- floor
// Infinite matte ground at y = 0 (the bottom of the volume box), shadowed by the clouds and
// the cloud layer around the storm, lit by the lightning, hidden by the fog with distance. Further away
// the shadows fade to their average: the tornado's shadow stands out on calm ground, and the
// distant floor pixels skip both shadow marches.

vec3 floorColor(float jitter, vec3 position)
{
	float nearStorm = smoothstep(FloorShadowRadius + FloorShadowFade, FloorShadowRadius, length(position.xz - 0.5));
	float shadow = FloorDistantShadow;
	if (nearStorm > 0.0)
	{
		float unusedHitDistance;
		shadow = mix(shadow, exp(-marchBricks(position, MoonDirection, LightDistance, false, true, jitter, unusedHitDistance).a - layerOpticalDepth(position)), nearStorm);
	}

	float patches = texture(noiseTexture, vec3(position.xz * 0.4, 0.9)).r * 0.6 + texture(noiseTexture, vec3(position.xz * 2.3, 0.2)).r * 0.4;
	vec3 albedo = FloorAlbedo * (1.0 + 2.0 * (patches - 0.5) * FloorVariation);
	return albedo * (MoonLight * shadow * MoonDirection.y / PI + SkyLight + flashLight(position) * 0.2);
}

// ---------------------------------------------------------------------------- birds (renderPixel())
const float BirdCount = 24.0;
const float BirdStart = 0.0;           // scene seconds: the first takes off (touchdown at 35)
const float BirdSpeed = 0.3;           // box sizes per second
const float BirdSize = 0.01;           // half wingspan, box sizes

// ---------------------------------------------------------------------------- grass
// Short grass on the plain: a layer GrassHeight thick, marched in GrassSteps samples (at fixed
// heights, from its top down) along the camera rays that reach the floor. The plain is cut in
// cells of 1 / GrassDensity with a blade in each, at a random place and of a random height,
// tapering to its tip and bent by the gusts rolling over the plain, harder with the apocalypse,
// and toward the funnel as it comes down (the inflow, GrassPull), which leaves the ground bare
// under it (GrassBare).
// The first sample inside a blade stops the ray: the floor shading there, tinted GrassColor and
// darker toward the root. The layer thins with distance, gone at GrassFar (blades under a pixel).

const float GrassHeight = 0.02;          // box sizes
const float GrassDensity = 240.0;         // blades per box size, along x and z
const float GrassSteps = 16.0;
const float GrassFar = 3.0;               // box sizes from the camera
const float GrassBend = 4.5;              // cells the tips lean in a gust
const float GrassPull = 4.0;               // the inflow: the blades lean toward the funnel as it comes down, hardest ~0.14 from it
const float GrassBare = 0.4;               // the funnel scours the plain: no grass within 0.3 x this of the axis, full height from this
const vec3 GrassColor = vec3(2.82, 1.66, 1.15);  // x the floor albedo: dry grass

// Color factor of the floor on a ray reaching it (1 bare, GrassColor x the shade in a blade), and
// the distance to the blade hit
vec3 grass(vec3 origin, vec3 direction, inout float distance, float jitter)
{
	float height = smoothstep(GrassFar, 0.3 * GrassFar, distance) * GrassHeight * max(1.0 - tornadoGrowth(), smoothstep(0.3 * GrassBare, GrassBare, length(origin.xz + direction.xz * distance - 0.5)));
	for (float i = 0.0; i < GrassSteps; i++)
	{
		float y = height * (1.0 - (jitter + i) / GrassSteps), along = (y - origin.y) / direction.y;
		vec3 position = origin + direction * along;
		vec2 blade = position.xz * GrassDensity + (vec2(1.0, 0.3) + (0.5 - position.xz) * GrassPull * tornadoGrowth() / (dot(position.xz - 0.5, position.xz - 0.5) + 0.02)) * GrassBend * y * y / (GrassHeight * GrassHeight) * (0.6 + 0.4 * sin(dot(position.xz, vec2(9.0, 3.0)) - time * 3.0)) * (1.0 + 2.0 * apocalypse()), cell = floor(blade);
		float seed = hash(dot(cell, vec2(1.0, 157.0))), tip = height * (0.4 + 0.6 * seed);
		if (tip > y && length(fract(blade) - 0.3 - 0.4 * vec2(seed, hash(seed))) < 0.3 * (1.0 - y / tip))
		{
			distance = along;
			return GrassColor * (0.3 + 0.9 * y / tip);
		}
	}
	return vec3(1.0);
}

// ---------------------------------------------------------------------------- rain and dust
// Rain curtains hanging from the cloud base around the storm, and after touchdown, dust on the
// ground spiralling into the funnel. Thin, so they are not in the density volume (their empty
// bricks would no longer be skipped): marched on their own along the camera ray, inside the
// cylinder of radius RainRadius around the storm, with AirSamples samples for each. And low ground
// mist over the whole plain (out to FogFar): wind-blown banks hugging the floor, thicker here, gone
// there, so the plain reads in layers (near, middle, far); lit like the rain, the strikes too.

const float RainRadius = 0.45;          // rain falls around the storm out to this radius...
const float RainInner = 0.15;           // ...from this one (inside: the funnel)
const float RainTop = 0.8;              // the cloud base
const float RainDensity = 6.0;          // optical depth per unit of length in the curtains
const vec3 RainColor = vec3(0.45, 0.5, 0.55);   // albedo: grey, slightly blue
const float DustHeight = 0.06;          // the dust stays near the ground...
const float DustDensity = 30.0;         // ...dense
const vec3 DustColor = vec3(0.3, 0.45, 0.6);    // albedo: brown
const float InflowSpin = 1.2;           // turns of the dust spirals per second (the inflow)
const int AirSamples = 12;
const float MistDensity = 6.0;          // optical depth per unit of length at the ground, in a bank...
const float MistHeight = 0.07;          // ...falling by e every MistHeight upward...
const float MistTop = 0.2;              // ...marched up to this height
const float MistScale = 0.25;           // noise cells per box size: banks about a box size wide
const float MistWind = 0.02;            // noise cells per second: the banks drift with the wind, and slowly change shape
const vec3 MistColor = vec3(0.55, 0.57, 0.6);   // albedo: grey

// Light reaching rain or dust: the moon through the clouds (the light volume), the sky, the strikes
vec3 airLight(vec3 position)
{
	return MoonLight * exp(-texture(lightTexture, position).r) * 0.15 + SkyLight + flashLight(position);
}

// Falling rain around the camera, as loud as the rain of the soundtrack (none in the heartbeat
// break): StreakLayers cylinders around the camera, StreakStep apart, each a row of streaks along
// its arc (StreakColumns per box size of the nearest), StreakRows per box size of height (a random
// phase per column, each drop at a random place across its column: a regular column of drops read
// as rising at many frame rates, the wagon wheel effect), falling StreakFall rows per second, bright at the
// head, fading over 1 / StreakTail of the row. Hidden behind what the ray hit, lit like the
// curtains. Widened to a pixel on the far layers: no flicker.
// (Units folded by hand: the minifier keeps constant divisions.)
const float StreakLayers = 6.0;
const float StreakStep = 0.04;          // box sizes
const float StreakColumns = 10.0;       // StreakStep / spacing of the streaks (0.004 box)
const float StreakWidth = 0.02;         // of the spacing (0.00016 box)
const float StreakPixel = 4.0;          // 1 / (pixel size of the spacing at a distance of 1): ~RenderSize.y x spacing (1080 x 0.004)
const float StreakRows = 12.0;
const float StreakFall = 25.0;
const float StreakTail = 0.1;           // StreakBrightness x 1 / the length of the streaks (of a row)
const float StreakBrightness = 0.1;

// Density of the rain (part 0), the dust (part 1) or the ground mist (part 2) at a point
float airDensity(vec3 position, float part)
{
	if (part > 1.5)
	{
		return MistDensity * smoothstep(0.45, 0.7, texture(noiseTexture, vec3(MistScale * position.xz - vec2(time * MistWind, 0.0), position.y + time * 0.005)).r) * exp(-position.y / MistHeight);
	}
	vec2 offset = position.xz - 0.5;
	float turns = atan(offset.y, offset.x) / (2.0 * PI), radius = length(offset);
	float outer = smoothstep(RainRadius, RainRadius - 0.1, radius);
	if (part < 0.5)
	{
		// Curtains: shafts turning slowly with the storm, with fine vertical streaks falling fast,
		// heavier on one side (the forward flank), fading into the cloud base
		float shafts = texture(noiseTexture, vec3(turns * 8.0 - time * 0.03, radius * 3.0, position.y * 0.4 + time * 0.2)).r;
		float streaks = texture(noiseTexture, vec3(turns * 48.0, radius * 12.0, position.y * 0.6 + time * 1.5)).r;
		return RainDensity * smoothstep(0.45, 0.7, shafts) * (0.3 + streaks) * outer * smoothstep(RainInner, RainInner + 0.08, radius)
			* smoothstep(RainTop, RainTop - 0.3, position.y) * (0.3 + 0.7 * smoothstep(-0.3, 0.7, sin(turns * 2.0 * PI - 1.0))) * stormActivity(time);
	}
	// Dust: logarithmic spiral arms winding into the funnel, hugging the ground
	float arms = texture(noiseTexture, vec3((turns + 0.8 * log(radius)) * 6.0 - InflowSpin * time, radius * 4.0, 8.0 * position.y)).r;
	return smoothstep(0.45, 0.7, arms) * DustDensity * outer * smoothstep(0.03, 0.1, radius) * exp(-position.y / (DustHeight * 0.3))
		* smoothstep(TornadoTouchdown - 1.0, TornadoTouchdown + 6.0, time);
}

// Rain, dust and mist along a camera ray up to maxDistance, split at the storm axis: front = in front of
// it (drawn over the storm), back = behind it (drawn behind the storm). rgb = light, a = optical depth.
// The rain and the dust inside the cylinder around the storm, the mist out to FogFar.
void marchAir(vec3 origin, vec3 direction, float maxDistance, float jitter, out vec4 front, out vec4 back)
{
	vec4 air[2];
	air[0] = air[1] = vec4(0.0);
	vec2 toCenter = origin.xz - 0.5;
	float a = dot(direction.xz, direction.xz), b = dot(direction.xz, toCenter);
	float disc = b * b - a * (dot(toCenter, toCenter) - RainRadius * RainRadius);
	// Where the ray is in the cylinder (an empty range when it misses it)
	vec2 cylinder = disc > 0.0 ? (vec2(-1.0, 1.0) * sqrt(disc) - b) / a : vec2(0.0);
	for (float part = 0.0; part < 3.0; part++)
	{
		vec2 slab = (vec2(0.0, part > 1.5 ? MistTop : part > 0.5 ? DustHeight : RainTop) - origin.y) / direction.y, range = part > 1.5 ? vec2(0.0, FogFar) : cylinder;
		float start = max(max(range.x, min(slab.x, slab.y)), 0.0);
		float stepLength = (min(min(range.y, max(slab.x, slab.y)), maxDistance) - start) / AirSamples;
		for (int i = 0; i < AirSamples && stepLength > 0.0; i++)
		{
			float t = start + stepLength * (i + jitter);
			vec3 position = origin + direction * t;
			// (none right around the camera: close rain is streaks, not a veil)
			float opticalDepth = stepLength * airDensity(position, part) * smoothstep(0.1, 0.3, t);
			float opacity = 1.0 - exp(-opticalDepth);
			int side = int(t > -b / a);
			air[side].rgb += exp(-air[side].a) * withFog(opacity, opacity * airLight(position) * (part > 1.5 ? MistColor : part > 0.5 ? DustColor : RainColor), origin, direction, t);
			air[side].a += opticalDepth;
		}
	}
	back = air[1];
	front = air[0];
}

// ---------------------------------------------------------------------------- environment

// Light scattered by the air along the camera ray (god rays). Outside the box nothing
// casts shadows, so the light volume is only read inside it.
vec3 godRays(vec3 rayOrigin, vec3 rayDirection, float maxDistance, float jitter)
{
	float stepLength = min(maxDistance, 3.0) / GodRaySamples;
	vec3 scattering = vec3(0.0);
	for (int i = 0; i < GodRaySamples; i++)
	{
		vec3 position = rayOrigin + rayDirection * stepLength * (jitter + i);
		bool insideBox = min(min(position.x, position.y), position.z) > 0.0 && max(max(position.x, position.y), position.z) < 1.0;
		float opticalDepth = insideBox ? texture(lightTexture, position).r : 0.0;
		scattering += MoonLight * exp(-opticalDepth) * henyeyGreenstein(0.6, dot(rayDirection, MoonDirection));
	}
	vec3 godrays = scattering * stepLength * AirScattering * 6.0;
	return godrays * godrays;
}

// ---------------------------------------------------------------------------- logo

// Texts written by lightning, drawn by the post pass over the picture (in the render pass their loop
// slowed every frame, even skipped): the REBELS logo on the end of the fade, the credits and the
// title over the prologue (camera plan 0). Each is polylines in its own units (x right, y down from
// its top left corner; -1,-1 lifts the pen), all in LogoPoints one after another (a pen lift
// between them): the logo (96 x 113), the credits (the names, one per line: lowercase letters 12
// high, 13 apart, lines 26 apart), the title (capitals 20 high, 80 wide). The strokes of a text
// strike one after another over its stroke time, then crackle (a jagged offset re-drawn 25 times a
// second) until it fades out, over the second before its end.
const int LogoPoints[] = int[](96,70,88,70,82,58,84,58,80,49,86,46,90,42,94,36,96,28,96,21,94,13,90,6,83,2,75,0,0,0,0,54,4,54,4,74,0,74,0,85,22,85,22,49,56,49,58,54,55,54,64,71,67,71,75,85,96,85,92,76,96,76,96,70,-1,-1,74,27,73,30,69,31,22,31,22,22,27,22,27,17,69,17,73,19,74,22,74,27,-1,-1,4,14,4,50,-1,-1,0,113,0,94,9,94,14,96,15,100,14,103,9,104,0,104,-1,-1,8,104,15,113,-1,-1,34,94,19,94,19,113,34,113,-1,-1,19,103,33,103,-1,-1,36,103,46,103,50,101,50,97,47,94,36,94,36,113,46,113,50,112,52,108,50,104,46,103,-1,-1,70,94,55,94,55,113,70,113,-1,-1,55,103,69,103,-1,-1,73,94,73,113,84,113,-1,-1,96,96,92,94,87,94,84,96,84,99,89,101,94,103,96,106,94,111,88,113,81,111,-1,-1,9,7,7,6,2,6,0,8,0,16,2,18,7,18,9,17,-1,-1,13,0,13,18,-1,-1,21,6,13,13,-1,-1,16,11,22,18,-1,-1,3,27,3,42,5,44,9,44,-1,-1,0,32,8,32,-1,-1,13,38,22,38,22,34,20,32,15,32,13,34,13,42,15,44,22,44,-1,-1,28,32,33,32,35,34,35,42,33,44,28,44,26,42,26,34,28,32,-1,-1,9,59,7,58,2,58,0,60,0,62,2,64,7,64,9,66,9,68,7,70,2,70,0,69,-1,-1,13,52,13,70,-1,-1,21,58,13,65,-1,-1,16,63,22,70,-1,-1,27,58,33,58,35,60,35,70,-1,-1,35,63,28,63,26,65,26,68,28,70,35,70,-1,-1,0,0,4,20,8,6,12,20,16,0,-1,-1,22,0,22,20,-1,-1,36,0,36,20,-1,-1,22,10,36,10,-1,-1,42,0,42,20,-1,-1,61,2,59,0,50,0,48,2,48,8,50,10,59,10,61,12,61,18,59,20,50,20,48,18,-1,-1,67,20,67,0,77,0,80,3,80,7,77,10,67,10);
const float LogoStart = Duration - 7.4;     // scene seconds: in the last camera plan (from 80 s scene, 90 s clock), before the fade
const float CreditsStart = -13.5;           // scene seconds (6.5 s on the clock with a 20 s prologue), in the prologue...
const float CreditsEnd = -8.5;              // ...faded out at 11.5 s on the clock
const float TitleStart = -6.2;              // the title (13.8 s on the clock), then...
const float TitleEnd = -1.3;                // ...faded out 1.3 s before the cut strike ending the prologue (the pad's last chord rings on)
// Per text (logo, credits, title): its first point in LogoPoints, its point count, the top left
// corner (screen heights from the screen center), the scale (screen heights per unit), start,
// stroke time (seconds to strike all its strokes) and end (scene seconds)
const float TextCount[] = float[](104.0, 79.0, 38.0);
const float TextFirst[] = float[](0.0, 105.0, 185.0);
const vec2 TextCorner[] = vec2[](vec2(0.308, 0.224), vec2(-0.69, 0.18), vec2(0.32, 0.06));  // the logo and the title on the right, the credits on the left
const float TextScale[] = float[](0.004, 0.003, 0.004);   // the logo 0.45 screen high, the credits block 0.35, the title 0.48 wide
const float TextStart[] = float[](LogoStart, CreditsStart, TitleStart);
const float TextDraw[] = float[](3.0, 2.0, 1.5);
const float TextEnd[] = float[](Duration, CreditsEnd, TitleEnd);
const float LogoJag = 1.2;                  // units: sideways crackle of the strokes
const float LogoCore = 0.35;                // units: core thickness...
const float LogoGlow = 3.0;                 // ...glow size...
const float LogoGlowStrength = 0.03;        // ...and strength relative to the core
const float LogoBrightness = 2.5;

vec3 logoLight(vec2 screen)
{
	// Time barrier: nothing when no text is on screen (all the segments for each pixel would slow every frame)
	if ((time < LogoStart) && (CreditsStart > time || time > TitleEnd))
	{
		return vec3(0.0);
	}
	float light = 0.0;
	for (int i = 2; i < LogoPoints.length(); i += 2)
	{
		// The text of this segment: the pixel in its units, how many of its points are drawn
		float k = i / 2;
		int t = int(k >= TextFirst[1]) + int(k >= TextFirst[2]);
		float shown = (time - TextStart[t]) / TextDraw[t] * TextCount[t] + TextFirst[t];
		vec2 a = vec2(LogoPoints[i - 2], LogoPoints[i - 1]), ba = vec2(LogoPoints[i], LogoPoints[i + 1]) - a, pa = (screen - TextCorner[t]) / TextScale[t] * vec2(1.0, -1.0) - a;
		float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
		// Away from its ends, the stroke is offset sideways by the crackle
		float d = length(pa - h * ba - vec2(-ba.y, ba.x) / length(ba) * (valueNoise(h * length(ba) * 0.5 + k * 9.0 + floor(time * 25.0) * 3.7) - 0.5) * LogoJag * h * (1.0 - h) * 4.0);
		// A stroke striking is brighter, for a moment (abs: exp() must not overflow before it strikes, inf x 0 = NaN)
		light += step(0.0, min(a.x + ba.x, a.x)) * step(k, shown) * (1.0 + exp(-abs(k - shown) * 0.1) * 4.0) * (exp(-d * d / (LogoCore * LogoCore)) + LogoGlowStrength / (1.0 + d * d / (LogoGlow * LogoGlow)))
			* smoothstep(TextEnd[t], TextEnd[t] - 1.0, time);
	}
	return light * BoltColor * LogoBrightness * (0.8 + 0.2 * hash(floor(time * 30.0)));
}

// ---------------------------------------------------------------------------- render (pass 4)

// The camera: the plans of cameras.txt (the Debug camera tools), written as _CM by main.cpp in
// Debug and by bake_config.ps1 in Release. Per plan 10 values in hundredths: the start view
// (position x y z, yaw, pitch), then the end view (the start view again for a static plan).
// The camera pans linearly from one to the other over the plan, the last plan running until
// Duration (as the Debug playback does).
const int CameraPlans[] = int[](_CM);

void planCamera(out vec3 position, out vec3 forward)
{
	// Plan 0 is the prologue (scene time < 0), then plan n from (n - 1) x ShotDuration
	float plan = clamp(1.0 + floor(time / ShotDuration), 0.0, ShotCount - 1.0), start = plan > 0.0 ? (plan - 1.0) * ShotDuration : -Prologue;
	float f = clamp((time - start) / ((plan < ShotCount - 1.0 ? plan * ShotDuration : Duration) - start), 0.0, 1.0);
	int i = int(plan) * 10;
	position = mix(vec3(CameraPlans[i], CameraPlans[i + 1], CameraPlans[i + 2]), vec3(CameraPlans[i + 5], CameraPlans[i + 6], CameraPlans[i + 7]), f) * 0.01;
	vec2 angles = mix(vec2(CameraPlans[i + 3], CameraPlans[i + 4]), vec2(CameraPlans[i + 8], CameraPlans[i + 9]), f) * 0.01;
	forward = vec3(sin(angles.x) * cos(angles.y), sin(angles.y), cos(angles.x) * cos(angles.y));
}

// Linear HDR color of a pixel of the render target (RenderSize), exposure applied.
// Thunder heard at a point: each strike of this slot and the one before, and the cut strike, when
// its sound arrives there (delayed by the distance, at once on the cut for a cut strike), stronger
// when close, faint before the first cut, fading by e in 1 / decay seconds. Drives the camera shake
// and the strike color split (the sound has its own loop, see thunder()).
float thunderAt(vec3 listener, float decay)
{
	float slot = floor(time / FlashInterval), thunder = 0.0;
	for (float i = 0.0; i < 3.0; i++)
	{
		float start;
		vec3 position;
		float strength = 1.5 < i ? cutStrike(floor((time + CutLead) / ShotDuration), start, position) : strike(slot - i, start, position) * mix(0.1, 1.0, step(ShotDuration, start));
		float range = length(listener - position);
		float age = time - start - (1.5 < i ? CutLead : range * ThunderDelay);
		thunder += step(0.0, age) * strength * exp(-max(age, 0.0) * decay) / (0.5 + range);
	}
	return thunder;
}

// Camera shake of the thunder (an offset of the view direction), stronger with the apocalypse
vec3 thunderShake(vec3 camera)
{
	return thunderAt(camera, CameraShakeDecay) * (vec3(valueNoise(time * 23.0), valueNoise(time * 29.0 + 7.0), valueNoise(time * 31.0 + 13.0)) - 0.5) * CameraShake * (1.0 + apocalypse());
}

vec3 renderPixel(vec2 pixel)
{
	vec3 cameraPosition, forward;
	planCamera(cameraPosition, forward);
	_C(cameraPosition, forward);
	forward = normalize(thunderShake(cameraPosition) + forward);
	vec3 right = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
	vec3 up = cross(right, forward);
	const float focalLength = 1.5;
	vec2 screen = (pixel - RenderSize * 0.5) / RenderSize.y;
	vec3 rayDirection = normalize(mat3(right, up, forward) * vec3(screen, focalLength));

	// Interleaved gradient noise: breaks the banding of the fixed step marching
	float jitter = fract(52.98 * fract(dot(pixel, vec2(0.0671, 0.00584))));

	// Background: floor or sky
	vec3 background;
	float backgroundDistance = 1000.0, fogDistance;
	if (rayDirection.y < 0.0)
	{
		backgroundDistance = -cameraPosition.y / rayDirection.y;
		vec3 ground = cameraPosition + rayDirection * backgroundDistance, mirror = rayDirection * vec3(1.0, -1.0, 1.0), reflection = vec3(0.0);
		float puddle = smoothstep(PuddleEdge, PuddleEdge + 0.02, texture(noiseTexture, vec3(ground.xz * PuddleScale, 0.7)).r + PuddleRise * stormActivity(time)), unusedHitDistance;
		if (puddle > 0.0)
		{
			vec4 sky = marchBricks(ground, mirror, 1000.0, true, true, jitter, unusedHitDistance);
			reflection = puddle * pow(1.0 + rayDirection.y, 5.0) * (sky.rgb + exp(-sky.a) * marchCloudLayer(ground, mirror, 1000.0, 0.0, jitter).rgb);
		}
		vec3 blade = puddle > 0.5 ? vec3(1.0) : grass(cameraPosition, rayDirection, backgroundDistance, jitter);
		background = blade * (floorColor(jitter, cameraPosition + rayDirection * backgroundDistance) * (1.0 - PuddleDark * puddle) + reflection);
		fogDistance = backgroundDistance;
	}
	else
	{
		// The sky is fogged as if at the top of the box: fog through the far gaps of the layer
		fogDistance = max(1.0 - cameraPosition.y, 0.0) / max(rayDirection.y, 1e-4);
		background = vec3(0.0, 0.0, 0.0);
	}

	// Birds: BirdCount silhouettes take off from the grass around the storm from BirdStart on, one
	// every 0.25 s, and flee outward and upward, flapping. A dark V across the ray: the offset of
	// the bird from the ray, its wings rising and falling about its horizontal span
	for (float i = 0.0; i < BirdCount; i++)
	{
		float flight = BirdSpeed * (time - BirdStart - 0.25 * i);
		vec3 bird = vec3(0.5 + cos(i * 2.4) * (0.25 + flight), 0.6 * flight, 0.5 + sin(i * 2.4) * (0.25 + flight)) - cameraPosition;
		float along = dot(bird, rayDirection);
		bird -= along * rayDirection;
		if (along > 0.0 && along < backgroundDistance && abs(bird.y - 0.5 * sin(time * 15.0 + i) * length(bird.xz)) < BirdSize * 0.15 && length(bird.xz) < BirdSize)
		{
			background = vec3(0.0);
			backgroundDistance = fogDistance = along;
		}
	}

	bool withSolid = (time < 70.0) && (flash <= 0.1);

	float hitDistance = backgroundDistance;
	vec4 volume = marchBricks(cameraPosition, rayDirection, backgroundDistance, true, withSolid, jitter, hitDistance);

	// Cloud layer outside the volume: in front of the volume box, and behind it
	float boxEntry = intersectBox(cameraPosition, rayDirection).x;
	vec4 layerFront = marchCloudLayer(cameraPosition, rayDirection, min(boxEntry, backgroundDistance), 0.0, jitter);
	vec4 layerBehind = marchCloudLayer(cameraPosition, rayDirection, hitDistance, boxEntry, jitter);

	// Each element in its fog: the layer samples (in marchCloudLayer), the volume at the box entry, the background
	background = layerBehind.rgb + exp(-layerBehind.a) * withFog(1.0, background, cameraPosition, rayDirection, fogDistance);
	// The bolt, behind the cloud volume (its top is in the cloud base)
	if (flash > 0.0)
	{
		background += boltLight(cameraPosition, rayDirection, hitDistance);
	}
	volume.rgb = withFog(1.0 - exp(-volume.a), volume.rgb, cameraPosition, rayDirection, clamp(boxEntry, 0.0, backgroundDistance));
	// Rain and dust: the part in front of the storm axis over the storm, the rest behind it
	vec4 airFront, airBack;
	marchAir(cameraPosition, rayDirection, hitDistance, jitter, airFront, airBack);
	background = airBack.rgb + exp(-airBack.a) * background;
	vec3 color = layerFront.rgb + exp(-layerFront.a) * (airFront.rgb + exp(-airFront.a) * (volume.rgb + exp(-volume.a) * background)) + godRays(cameraPosition, rayDirection, hitDistance, jitter);
	// Rain streaks around the camera (see StreakLayers)
	float mu = 1.0 + max(0.0, time - LogoStart - 4.0) * 4.0;
	for (float i = 1.0; i <= StreakLayers; i++)
	{
		float arc = atan(rayDirection.z, rayDirection.x) * i * StreakColumns, along = StreakStep * i / length(rayDirection.xz), seed = hash(i + floor(arc));
		vec3 drop = cameraPosition + rayDirection * along;
		float fall = StreakRows * drop.y + time * StreakFall + 7.0 * seed;
		color += step(along, hitDistance) * stormActivity(time) * (1.0 + apocalypse()) * (1.0 - heartBreak()) * airLight(drop) * max(1.0 - abs(fract(arc) - hash(seed + floor(fall))) / (StreakWidth + along / StreakPixel), 0.0)
			* max(0.0, StreakBrightness - fract(fall) * StreakTail) * mu;
	}
	// The fade from black at the start and the fade-out lower the exposure: the dark parts go first,
	// the lit clouds and the strikes last
	return color * Exposure * ColorGrade * smoothstep(-Prologue, FadeIn - Prologue, time) * smoothstep(Duration, Duration - FadeOut, time);
}

// ---------------------------------------------------------------------------- sound (pass 5)

// The soundtrack, rendered once before the intro starts: the storm heard from the camera.
// main.cpp reads the texture back as 16-bit PCM (clamped to -1..1) and plays it, and the intro
// clock is the play position. Each invocation renders AudioBlock consecutive samples. The
// filters are sequential, so it first runs AudioWarmup samples from silence: their state has
// settled when the block starts, so the blocks join without clicks.
// Every layer follows the scene timeline through `time`: stormActivity(), tornadoGrowth(),
// the lightning strikes (strike(), flicker()) and the camera (planCamera()).
// Phases of audible tones never come from `time` (at 120 s a float has ~8 us of resolution):
// noise hashes the sample index, tones use whole periods of samples, envelopes small ages.

const float SampleRate = float(_SR);
const int AudioWidth = _AW;             // samples per texture row
const int AudioBlock = _AB;             // samples per invocation
const int AudioWarmup = _AU;            // samples run before the block, to settle the filters

const float WindGain = 0.5;
const float RoarGain = 0.4;
const float DebrisGain = 2.0;
const float DroneGain = 0.02;
const float SubGain = 0.35;
const float WallGain = 0.35;            // the apocalypse noise wall
const float MasterGain = 1.0;
const float CrackGain = 1.0;            // thunder parts
const float HighGain = 4.0;
const float LowGain = 12.0;
const float BoomGain = 0.5;
const float RainGain = 0.05;            // the rain curtains: a soft hiss, wide (its own noise in each ear), with the storm
const float DebrisRate = 0.004;         // chance of a hit per sample, at full debris
const float UprootCrackle = 5.0;        // the roots tearing when a tree is uprooted: debris knocks, this many times full debris...
const float UprootThud = 0.4;           // ...and the trunk snapping (a thump())

// Sine of a tone of about `frequency` Hz, from a whole number of samples per period: exact phase
// at any time. Left and right are detuned by `detune` for a slow beating across the stereo.
vec2 tone(int n, float frequency, float detune)
{
	uvec2 period = uvec2(SampleRate / (frequency * vec2(1.0 - detune, 1.0 + detune)));
	return sin(vec2(uint(n) % period) / period * 2.0 * PI);
}

// Moog ladder lowpass (raspberry-sampler filter_lowpass.h): four one-pole stages (bilinear) with
// resonance feedback and a cubic soft clip. Stereo, the state of filter s is filterState[s * 8 ...]:
// 4 stage outputs, then the 4 previous stage inputs. cutoff in Hz, resonance 0..1 (rings near 1).
vec2 filterState[104];

vec2 moog(int s, vec2 x, float cutoff, float resonance)
{
	float f = cutoff / (SampleRate * 0.5);
	s *= 8;
	float p = f * (1.8 - 0.8 * f);
	float t = 1.39 * (1.0 - p);
	float t2 = 12.0 + t * t;
	x -= resonance * (t2 + 6.0 * t) / (t2 - 6.0 * t) * filterState[s + 3];
	for (int stage = 0; stage < 4; stage++)
	{
		vec2 y = (x + filterState[s + 4 + stage]) * p - (p + p - 1.0) * filterState[s + stage];
		filterState[s + 4 + stage] = x;
		x = y;
		filterState[s + stage] = y;
	}
	x = clamp(x, -1.41, 1.41);
	x -= x * x * x / 6.0;
	filterState[s + 3] = x;
	return x;
}

// Wave folder (raspberry-sampler filter_distortion.h, threshold 1): identity in -1..1, folds back beyond
vec2 fold(vec2 x)
{
	return abs(mod(x - 1.0, 4.0) - 2.0) - 1.0;
}

// ---- Heartbeat break

// From BreakStart (on the camera cut at 70 s) to BreakEnd (on the next camera cut, 80 s) the storm steps back: its bed drops to 1 - BreakDuck,
// muffled (filter 11), the strikes to 30%, and a heartbeat takes over, speeding up from 60 to 100 bpm and growing
// louder. The cut strike at 70 s stays at full volume: the heartbeat starts on its blast. Breath
// seconds before BreakEnd everything stops dead, and the cut strike brings the whole storm back.
// The blast opening the break leaves the ears ringing: a high pure tone, not muffled (it is
// inside the head).
const float BreakDuck = 0.8;
const float BreakCutoff = 400.0;        // ...and it goes through a lowpass (Hz): the storm heard from inside your head
const float Breath = 0.45;              // seconds of silence before the cut ending the break: the heart misses its last beat
const float RingPitch = 5500.0;         // Hz: the ears ring after the blast that opens the break (the cut strike, close)...
const float RingGain = 0.02;
const float RingDecay = 0.6;            // ...rising out of the blast, then fading by e every 1 / RingDecay seconds
const float HeartGain = 0.7;


// Seconds since the last beat; rate: beats per second, from 1 to 1.67 (60 to 100 bpm) over the
// break. Shared by the sound and the picture (postProcess())
float heartAge(out float rate)
{
	float since = max(time - BreakStart, 0.0);
	rate = 1.0 + min(since / (BreakEnd - BreakStart), 1.0) * 0.6667;
	return fract(since + since * since * 0.6667 / (2.0 * (BreakEnd - BreakStart))) / rate;
}

// One thump of the heart, age seconds after it: a low tone falling from ~85 to 45 Hz, saturated so
// that small speakers still hear its harmonics
float thump(float age)
{
	float on = step(0.0, age);
	age = max(0.0, age);
	return tanh(sin(2.0 * PI * (age * 45.0 + 40.0 / 30.0 * (1.0 - exp(-age * 30.0)))) * 3.0) * on * exp(-age * 18.0);
}

// Lub-dub: the first beat lands on BreakStart, the dub follows at 30% of a beat, softer, louder and
// louder (0.6 to 1.2 over the break)
float heartbeat()
{
	float rate, age = heartAge(rate);
	// on at once on the cut (the first beat lands on it), off on the next cut
	return (thump(age) + thump(age - 0.3 / rate) * 0.6) * (0.6 + 0.9 * (rate - 1.0)) * step(BreakStart, time) * step(time, BreakEnd) * HeartGain;
}

// 0 during the silence before the end of the break, 1 elsewhere. Shared by the sound and the
// picture (the skipped beat does not throb either)
float breath()
{
	return max(step(BreakEnd, time), smoothstep(BreakEnd - Breath, BreakEnd - Breath - 0.05, time));
}

// ---- Logo crackle

// While a text is on screen (logoLight(): the credits, the title, the logo): sparse sparks through
// a bright band, a burst on each re-draw of their jag (25 a second, as the picture, each burst stronger or weaker),
// thicker while their strokes strike, stopping with the text. Played over the sound fades. Filter 9.
const float LogoCrackleGain = 0.25;

vec2 logoCrackle(int n)
{
	// The text on screen: in the prologue (scene time < 0) the credits then the title, the logo at the
	// end. Silent before it (the filter stays at rest) and after it
	int t = 0.0 > time ? 1 + int(time > TitleStart) : 0;
	if (time < TextStart[t] || time > TextEnd[t])
	{
		return vec2(0.0);
	}
	vec2 spark = hashGradient(vec3(n + 3, n, n)).xy;      // independent of noise, hits and rip
	float rate = exp(-6.0 * fract(time * 25.0)) * (0.01 + 0.03 * step(time, TextStart[t] + TextDraw[t])) * hash(floor(time * 25.0));
	return moog(9, sign(spark) * step(1.0 - rate, abs(spark)), 3500.0, 0.3) * LogoCrackleGain;
}

// ---- Thunder

// Every strike sounds different: its seed draws the length of the crack, the pitch and length of
// the boom, the length and pace of the rumble. The seed is the strike itself (slot or cut), so a
// strike keeps its sound however the window below slides.
const float CutRange = 1.0;            // box sizes: the farthest a cut strike sounds
const float EarlyThunder = 0.6;         // strikes in the first scene plan (scene time < ShotDuration): just above the wind, far away
const float ThunderGain = 0.22;          // heard from the camera plans, which come close to the storm
const float EchoCount = 3.0;            // mountain echoes of each strike...
const float EchoDelay = 0.42;           // ...one every EchoDelay seconds...
const float EchoSpread = 0.6;           // ...plus a random part up to EchoSpread seconds (the mountains of a strike)
const float EchoGain = 0.7;             // each echo this much weaker than the sound before
const float EchoCutoff = 2500.0;        // the echoes' crack is a duller slap (Hz)

// The strikes of this slot and the three before (the rumbles last several seconds) and the last two
// cut strikes, heard from the camera (the camera plans): delayed (the cut strikes land on the cut), attenuated by the
// distance, panned. A tearing crack crackling with the flickers of the light, a falling boom, then
// a rolling rumble that darkens as it fades (a brighter part fading fast, a deep part lasting).
// Filters 5 to 8.
vec2 thunder(int n, vec2 noise)
{
	vec3 forward, listener;
	vec2 rip = hashGradient(vec3(n, n, n + 2)).xy;     // impulses of the crackle, independent of noise and hits
	planCamera(listener, forward);
	vec3 right = normalize(cross(forward, vec3(0.0, 1.0, 0.0)));
	vec2 crack = vec2(0.0), slap = vec2(0.0), boom = vec2(0.0), low = vec2(0.0), high = vec2(0.0);
	float slotNow = floor(time / FlashInterval), cutNow = floor((time + CutLead) / ShotDuration);
	for (float i = 0.0; i < 6.0; i++)
	{
		bool isCut = i >= 4.0;
		float key = isCut ? cutNow + i - 5.0 : slotNow + i - 3.0;
		float start;
		vec3 position;
		float strength = isCut ? cutStrike(key, start, position) : strike(key, start, position);
		vec3 toStrike = position - listener;
		// A cut strike sounds 1.5 times as loud (its light is CutFlash). Before the first cut strike
		// the thunder is fainter (EarlyThunder): far away
		// and during the heartbeat break, 30%
		strength *= isCut ? 1.5 : mix(EarlyThunder, 1.0, step(ShotDuration, start)) * (1.0 - heartBreak() * 0.7);
		// A cut strike punctuates the cut: heard at most CutRange away, however far the new shot starts
		float range = isCut ? min(length(toStrike), CutRange) : length(toStrike);
		float near = exp(-range);

		// The draws of this strike, each in 0..1
		float seed = key + (isCut ? 500.5 : 0.0);
		vec4 draw = vec4(hash(seed + 0.11), hash(seed + 0.23), hash(seed + 0.37), hash(seed + 0.41));
		vec4 more = vec4(hash(seed + 0.53), hash(seed + 0.67), hash(seed + 0.79), hash(seed + 0.97));

		// The direct sound, then the echoes from the mountains around: each later (EchoDelay plus a
		// random part), weaker (EchoGain), from the left and the right in turn, its crack duller
		for (float echo = 0.0; echo <= EchoCount; echo++)
		{
			// Age of the sound: 0 on the cut for a cut strike (the frame where the view changes),
			// after the distance delay for a strike, then the delay of the echo
			float age = (isCut ? time - start - CutLead : time - start - ThunderDelay * range) - EchoDelay * echo - EchoSpread * step(1.0, echo) * hash(seed + echo * 0.17);
			float pan = echo > 0.0 ? sign(mod(echo + floor(2.0 * more.w), 2.0) - 0.5) * 0.8 : dot(right, normalize(toStrike));
			float light = isCut ? cutFlicker(age + CutLead) : flicker(key, age);
			vec2 level = step(0.0, age) * strength / (0.5 + range) * vec2(1.0 - pan, 1.0 + pan) * pow(EchoGain, echo);
			age = max(0.0, age);    // before the strike: level is 0, and exp(-age...) must not overflow (0 x inf = NaN)

			// Tearing crack: a burst, then impulses thinning out, denser on each flicker. Short and
			// dry, or long and ragged. The echoes go to the dull filter (slap).
			float tear = 4.0 + 10.0 * draw.x;
			vec2 tearing = (2.0 + 2.0 * draw.y) * level * near * (noise * exp(-age * (40.0 + 60.0 * draw.z)) + sign(rip) * step(1.0 - exp(-age * tear) * (0.15 + 0.3 * draw.y) * (0.3 + light), abs(rip)));
			slap += step(1.0, echo) * tearing;
			crack += step(echo, 0.0) * tearing;

			// Boom: a low tone falling from 70..130 Hz to 28..45 Hz, short or long
			float from = 70.0 + 60.0 * draw.w, fall = 2.0 + 4.0 * more.y, to = 28.0 + 17.0 * more.x;
			boom += (2.0 + 4.0 * more.z) * level * near * sin(2.0 * PI * (to * age + (from - to) / fall * (1.0 - exp(-age * fall)))) * exp(-age * (1.5 + 3.0 * more.w));

			// Rumble: swells at random moments and pace; the deep part lasts ~2 to 8 s (it has faded
			// to under 3% when the strike leaves the window, 9 s later at least)
			float rolls = 0.15 + 2.0 * pow(valueNoise(age * (1.0 + 3.0 * draw.z) + 13.0 * seed), 2.0 + 2.0 * more.w);
			high += level * rolls * smoothstep(0.0, 0.15, age) * exp(-age * (1.0 + 1.5 * draw.x));
			low += level * rolls * smoothstep(0.0, 0.3 + 0.8 * more.y, age) * exp(-age * (0.4 + 0.5 * more.x));
		}
	}

	return (moog(5, crack, 6000.0, 0.1) * CrackGain
		+ moog(8, slap, EchoCutoff, 0.1) * CrackGain
		+ moog(6, noise * high, 450.0, 0.2) * HighGain
		+ LowGain * moog(7, noise * low, 90.0, 0.3)
		+ BoomGain * boom) * ThunderGain;
}

// ---- Prologue pad

// A spooky pad over the prologue, its last chord dying out on the cut: four chords, one every PadLength / 4 seconds, each held 3/4 of
// that, all over a low G: G D A, G D Bb, G F Bb, G Eb Ab (Hz below). Each note is three voices,
// detuned and spread across the stereo, each a band-limited saw (PadHarmonics sines, no aliasing),
// with a slow tape-like wobble. A slow swell in, a long release into the next chord, through a dark
// lowpass that opens a little with each chord. Filter 10.
const float PadStart = -12.0;           // scene seconds (8 s on the clock with a 20 s prologue)
const float PadGain = 0.03;
const float PadAttack = 1.2;            // seconds
const float PadRelease = 1.8;           // seconds
const float PadLength = 4.0 * (-PadStart - PadRelease) / 3.75;   // the four chords (~2.7 s each): the last one, held and released in full, ends on the cut strike (scene time 0)
const float PadDetune = 0.004;          // relative, between the voices of a note (~7 cents)
const int PadHarmonics = 6;
const vec3 PadChords[4] = vec3[](vec3(392.0, 587.33, 880.0), vec3(392.0, 587.33, 932.33), vec3(392.0, 698.46, 932.33), vec3(392.0, 622.25, 830.61));

// Phase in cycles of a tone of frequency Hz at sample n, exact over the whole intro: the sample index
// is split into rows of AudioWidth (a float of n x frequency / SampleRate would jitter)
float phase(int n, float frequency)
{
	return fract(n / AudioWidth * fract(AudioWidth * frequency / SampleRate) + n % AudioWidth * frequency / SampleRate);
}

vec2 pad(int n)
{
	float clock = time - PadStart, chord = PadLength / 4.0;
	vec2 sound = vec2(0.0);
	float open = 0.0;
	for (int c = 0; 4 > c; c++)
	{
		float age = clock - c * chord;
		float level = smoothstep(0.0, PadAttack, age) * (1.0 - smoothstep(chord * 0.75, chord * 0.75 + PadRelease, age));
		open = max(open, level);
		if (level > 0.0)
		{
			for (int note = 0; note < 3; note++)
			for (int voice = -1; voice <= 1; voice++)
			{
				float frequency = PadChords[c][note] * (1.0 + PadDetune * voice);
				float p = phase(n, frequency) + 0.3 * sin(time * (0.7 + 0.3 * (note + voice)));   // the wobble
				float saw = 0.0;
				for (int k = 1; k <= PadHarmonics; k++)
				{
					saw += sin(2.0 * PI * k * p) / k;
				}
				sound += level * saw * (1.0 + voice * vec2(-0.7, 0.7));
			}
		}
	}
	// Muffled under the credits crackle; its last chord dies out on the cut strike (PadLength):
	// the cut gets the thunder and the wind to itself
	return moog(10, sound * PadGain, 250.0 + 550.0 * open, 0.3);
}

// Stereo sample n of the soundtrack, n >= -AudioWarmup. Sets `time`.
vec2 soundtrack(int n)
{
	time = n / SampleRate - Prologue;
	// Two white noises: the hash of the noise texture, on a cell made of the sample index (on all three
	// axes it mixes as well as a dedicated hash; vec3(n, 0, 0) alone would not), exact up to 2^24 samples
	vec2 noise = hashGradient(vec3(n)).xy;
	float storm = stormActivity(time);
	float growth = tornadoGrowth();
	float doom = apocalypse();
	// Wind: noise through a resonant lowpass whose cutoff follows the gusts. The resonance rises
	// with the storm: the wind starts to howl.
	float gust = 0.6 * valueNoise(time * 0.3) + 0.3 * valueNoise(time * 1.1) + 0.1 * valueNoise(time * 3.7);
	// The apocalypse darkens it (lower cutoff) and pushes it.
	vec2 sound = moog(0, noise, (200.0 + 900.0 * gust * (0.5 + storm)) * (1.0 - 0.5 * doom), 0.5 + 0.4 * storm) * (0.3 + 0.7 * gust) * (1.0 + doom) * WindGain;

	// Tornado: a folded low rumble, and a band pulsing with the rotation of the funnel (the
	// freight train). It grows with the funnel and doubles at touchdown. The apocalypse drives the
	// folder harder (grit), lowers the band and deepens its pulse, and makes it louder.
	float roar = growth * growth * (1.0 + smoothstep(TornadoTouchdown, TornadoTouchdown + 6.0, time) + 1.5 * doom);
	sound += (fold(moog(1, noise, 150.0, 0.3) * (6.0 + 14.0 * doom)) * 0.5 + moog(2, noise, (500.0 + 200.0 * gust) * (1.0 - 0.5 * doom), 0.6) * (0.6 + sin(time * TornadoSpin * 3.0) * (0.4 + 0.4 * doom))) * roar * RoarGain;

	// Debris: random knocks, more and more of them once the whirl is up (same ramp as its density).
	// The filter wanders: at a fixed cutoff the dense knocks would ring as one pitch.
	float debris = smoothstep(TornadoTouchdown - 1.0, TornadoTouchdown + 6.0, time) * (0.5 + valueNoise(time * 2.0)) * (1.0 + 2.0 * doom);
	// Each tree and shrub torn out (treeUproot()): its roots crackle, swelling in 0.3 s and dying
	// in ~2 s, and its trunk snaps: a shrub at half the first tree, the two big trees torn out
	// together at twice its level each (the big moment after touchdown)
	for (float t = 0.0; t < TreeCount; t++)
	{
		float age = time - treeUproot(t), size = t < 2.5 ? 1.0 + min(t, 1.0) : 0.5;
		debris += smoothstep(0.0, 0.3, age) * exp(-abs(age) * 1.5) * size * UprootCrackle;   // abs: no overflow long before (0 x inf = NaN)
		sound += thump(age - 0.2) * size * UprootThud;
	}
	vec2 hits = hashGradient(vec3(n, n, n + 1)).xy;      // independent of noise
	sound += moog(3, sign(hits) * step(1.0 - debris * DebrisRate, abs(hits)), 600.0 + 2000.0 * valueNoise(time * 4.0), 0.5) * DebrisGain;

	// Rain: the debris noise through a high lowpass, a hiss growing with the storm and the
	// apocalypse. Filter 12.
	sound += moog(12, hits, 5000.0, 0.0) * storm * (1.0 + doom) * RainGain;

	// Thunder of the lightning strikes and of the cut strikes (see thunder()), kept apart from the
	// bed: the heartbeat break ducks the bed only
	vec2 thunderSound = thunder(n, noise);


	// Drone: a dark A minor triad, swelling with the storm, and a sub drop on the cut ending the
	// prologue (scene time 0), again at touchdown, on the cut ending the heartbeat break and as the
	// logo appears (each has about died out before the next). The
	// apocalypse swells it and sours it: a low A, then the minor second and the tritone fade in.
	vec2 drone = tone(n, 65.4, 0.004) + tone(n, 55.0, 0.003) + tone(n, 82.4, 0.002);
	drone += doom * (1.5 * tone(n, 27.5, 0.002) + tone(n, 58.3, 0.005) + tone(n, 77.8, 0.006));
	sound += drone * (0.3 + storm) * (0.5 + valueNoise(time * 0.2)) * (1.0 + 3.0 * doom) * DroneGain;
	float age = time - step(TornadoTouchdown, time) * TornadoTouchdown - step(BreakEnd, time) * (BreakEnd - TornadoTouchdown) - step(LogoStart, time) * (LogoStart - BreakEnd);
	sound += sin(2.0 * PI * (age * 30.0 + 30.0 * (1.0 - exp(-age)))) * step(0.0, age) * exp(-0.4 * age) * SubGain;

	// Apocalypse wall: dark noise and a low tone sliding from 60 down to 30 Hz, folded harder and
	// harder into a distorted roar
	age = max(time - ApocalypseStart, 0.0);
	float slide = age * 60.0 - age * age * 30.0 / (2.0 * (Duration - ApocalypseStart));
	sound += fold((moog(4, noise, 120.0 + 200.0 * gust, 0.5) * 4.0 + 0.5 * sin(2.0 * PI * slide)) * (1.0 + 5.0 * doom)) * doom * WallGain;

	// The heartbeat break: the bed steps back, muffled, the ears ring, the heart takes over
	float hush = heartBreak();
	sound = mix(sound, moog(11, sound, BreakCutoff, 0.0), hush) * (1.0 - BreakDuck * hush) + thunderSound + heartbeat() + pad(n)
		+ sin(2.0 * PI * phase(n, RingPitch)) * smoothstep(BreakStart, BreakStart + 0.6, time) * exp((BreakStart - time) * RingDecay) * RingGain;

	// Fade in and out, the silence before the end of the break, the logo crackle over it, soft clip
	return tanh(sound * MasterGain * breath() * smoothstep(-Prologue, SoundFadeIn - Prologue, time) * smoothstep(Duration, Duration - SoundFadeOut, time) + logoCrackle(n));
}

// ---------------------------------------------------------------------------- post process (pass 6)

// Narkowicz 2015, "ACES Filmic Tone Mapping Curve"
vec3 tonemapACES(vec3 color)
{
	return clamp(color * (color * 2.51 + 0.03) / (color * (color * 2.43 + 0.59) + 0.14), 0.0, 1.0);
}

// Color grade of the tonemapped image (teal and orange): the shadows toward teal, the highlights
// toward warm (split toning), more saturation, then an S curve for contrast
const vec3 ShadowTint = vec3(0.6, 1.0, 1.15);
const vec3 HighlightTint = vec3(1.25, 1.0, 0.75);
const float GradeSaturation = 1.5;

vec3 grade(vec3 color)
{
	float luma = dot(color, vec3(0.21, 0.72, 0.07));
	color = mix(ShadowTint, HighlightTint, smoothstep(0.25, 0.85, luma)) * max(mix(vec3(luma), color, GradeSaturation), 0.0);
	color = pow(clamp(color, 0.0, 1.0), vec3(1.0 / 2.2));
	return color * color * (3.0 - 2.0 * color);
}

// Apocalypse strike color split: the thunder heard from the camera (thunderAt(), as for the camera
// shake) splits the colors of the picture toward the edges (red outward,
// blue inward), as strong as apocalypse(): mild around 50 s, violent toward the end.
const float BloomLevels = 7.0;          // mip levels below the screen level (main.cpp allocates them: COLOR_LEVELS)
const float BloomThreshold = 1.0;       // linear HDR (exposure applied): the strikes, the bolts, the lit clouds
const float BloomStrength = 0.3;       // per level
// Lens flare ghosts: with each bloom level, a ghost of what is brighter than FlareThreshold
// (the bolts, the flashes) mirrored through the screen center at its own scale (-0.2 to 1.6 of the
// distance), each of its own color, fading toward the edges; FlareStrength each. FlareLevel: the
// mip level they are read from (2: sharp mirrored bolts, 4: soft blobs, dimmer)
const float FlareStrength = 0.8;
const float FlareThreshold = 0.1;
const float FlareLevel = 7.0;
// Drops on the lens: the screen in cells, DropCells per screen height, each holding a drop at
// times: re-drawn every 1 / DropRate seconds (a random phase per cell) at a random place and size,
// there with a chance growing with the rain (as in the soundtrack, none in the heartbeat break:
// DropChance at full storm), appearing at once and fading out over its time. Lit by the blurred
// light around it (the flare's mip level): a soft disc, brighter at its rim.
const float DropCells = 4.0;
const float DropRate = 0.4;
const float DropChance = 0.1;
const float StrikeSplit = 0.035;        // color split, fraction of the distance to the center
const float StrikeSplitDecay = 1.5;     // fading by e in 1 / StrikeSplitDecay seconds

// Eye adaptation: after each strike the picture dims, AdaptDepth at most, as its thunder reaches
// the camera (thunderAt(), as the color split: close strikes dazzle more), recovering with it
const float AdaptDepth = 0.3;
// The heartbeat break: on each beat (lub, then the softer dub, but not in the silence before its
// end, breath()) the picture brightens HeartPulse and its colors split HeartSplit (as a strike
// does). Between the beats the eye loses focus: the picture blurs toward the mip level
// HeartBlurLevel below the screen, HeartBlur at most, snapping sharp on each beat.
const float HeartPulse = 0.25;
const float HeartSplit = 0.6;
const float HeartBlur = 0.8;
const float HeartBlurLevel = 3.0;
const float HeartKick = 0.03;           // ...the view punches in this much on each beat...
const float FlareBeat = 2.0;            // ...and the lens flare swells by this much

vec3 postProcess(vec2 pixel)
{
	vec3 camera, unused;
	planCamera(camera, unused);
	vec2 uv = pixel / Resolution;
	float thunder = min(thunderAt(camera, StrikeSplitDecay), 1.0);
	float rate, age = heartAge(rate), beat = heartBreak() * breath() * (exp(-age * 8.0) + 0.6 * step(0.3 / rate, age) * exp((0.3 / rate - age) * 8.0));
	// The heart kicks the view, and the rain on the lens bends it
	uv = 0.5 + (uv - 0.5) * (1.0 - beat * HeartKick);
	vec2 split = (uv - 0.5) * StrikeSplit * (apocalypse() * thunder + HeartSplit * beat);
	// With RENDER_SCALE > 1 the level of the screen size: a box downsample (supersampling).
	// RenderScale - 1 is log2(RenderScale) for RENDER_SCALE 1 or 2, and folds to 0 in Release
	float level = RenderScale - 1.0;
	vec3 color = vec3(textureLod(colorTexture, uv + split, level).r, textureLod(colorTexture, uv, level).g, textureLod(colorTexture, uv - split, level).b);
	color = mix(color, textureLod(colorTexture, uv, level + HeartBlurLevel).rgb, HeartBlur * heartBreak() * (1.0 - min(beat, 1.0)));
	// Bloom: what is brighter than BloomThreshold in the mip levels below the screen (wider and
	// wider blurs, BloomLevels of them; main.cpp generates them each frame) glows around it, and its
	// lens flare ghosts
	vec3 bloom = vec3(0,0,0);
	for (float i = 1.0; i <= BloomLevels; i++)
	{
		vec2 ghost = 0.5 + (i * 0.3 - 0.5) * (0.5 - uv);
		bloom += max(textureLod(colorTexture, uv, level + i).rgb - BloomThreshold, 0.0) * BloomStrength
			+ max(textureLod(colorTexture, ghost, level + FlareLevel).rgb - FlareThreshold, 0.0) * (0.5 + cos(i * 2.4 + vec3(0.0, 2.1, 4.2)) * 0.5) * FlareStrength * (1.0 + FlareBeat * beat) * smoothstep(0.6, 0.1, length(ghost - 0.5));
	}
	color += bloom;
	vec2 cell = pixel / Resolution.y * DropCells;
	float seed = hash(dot(floor(cell), vec2(1.0, 57.0)) + 0.5), cycle = time * DropRate + seed, drop = hash(seed + floor(cycle)), radius = length(fract(cell) - 0.3 - 0.4 * fract(drop * vec2(7.0, 13.0))) / (0.08 + 0.17 * fract(drop * 31.0));
	color += step(drop, stormActivity(time) * (1.0 + apocalypse()) * (1.0 - heartBreak()) * DropChance) * (1.0 - fract(cycle)) * smoothstep(1.0, 0.8, radius) * bloom;
	// The eye adapting after the strikes, the picture throbbing with the heart
	color *= (1.0 + HeartPulse * beat) * (1.0 - thunder * AdaptDepth);
	// The texts (logoLight()): the credits and the title over the prologue, the logo over the end of the fade
	color += logoLight((pixel - Resolution * 0.5) / Resolution.y);
	return grade(tonemapACES(color));
}

// ---------------------------------------------------------------------------- entry point

void main()
{
	ivec3 invocation = ivec3(_I);
	const int pass = _P;
	time = uniformSample / SampleRate - Prologue;
	// Slow motion in the heartbeat break, for the scene only (the sound and the post pass, with its
	// beats, keep the clock): BreakSlow x the speed on the cut at BreakStart, speeding up with the
	// heart (its rate rises linearly too) to 2 - BreakSlow on the cut at BreakEnd, back on time there
	float slow = clamp((time - BreakStart) / (BreakEnd - BreakStart), 0.0, 1.0);
	if (pass < PassAudio)
	{
		time += (BreakEnd - BreakStart) * (BreakSlow - 1.0) * (slow - slow * slow);
	}

	if (pass == PassNoise)
	{
		imageStore(noiseImage, invocation, vec4(fbm(vec3(invocation) / NoiseSize) + 0.5));
	}

	if (pass == PassDensity)
	{
		vec3 position = (invocation + 0.5) / DensitySize;
		imageStore(densityImage, invocation, vec4(density(position), 0.0, 0.0));
	}

	if (pass == PassBricks)
	{
		// One invocation per brick. Also reads one texel around it: filtering near a brick
		// face reaches into the neighbour texels.
		// One loop over the (BrickSize + 2)^3 texels: k gives x, y, z in -1..BrickSize
		const int span = BrickSize + 2;
		vec2 maxContent = vec2(0.0);
		for (int k = 0; k < span * span * span; k++)
		{
			ivec3 texel = clamp(BrickSize * invocation + ivec3(k % span, k / span % span, k / (span * span)) - 1, 0, DensitySize - 1);
			maxContent = max(texelFetch(densityTexture, texel, 0).rg, maxContent);
		}
		imageStore(brickImage, invocation, vec4(step(0.002, maxContent), 0.0, 0.0));
	}

	if (pass == PassLight)
	{
		// Optical depth from the voxel center to the light, and sky visibility
		float unusedHitDistance;
		vec3 position = (invocation + 0.5) / LightSize;
		float opticalDepth = marchBricks(position, MoonDirection, LightDistance, false, true, 0.5, unusedHitDistance).a + layerOpticalDepth(position);
		imageStore(lightImage, invocation, vec4(opticalDepth, skyVisibility(position), 0.0, 0.0));
	}

	if (pass == PassRender)
	{
		updateLightning();
		imageStore(colorImage, invocation.xy, vec4(renderPixel(invocation.xy + 0.5), 1.0));
	}

	if (pass == PassAudio)
	{
		// One invocation per block of AudioBlock samples, AudioWidth / AudioBlock blocks per row
		for (int i = 0; i < filterState.length(); i++)
		{
			filterState[i] = vec2(0.0);
		}
		int row = invocation.y;
		int first = invocation.x * AudioBlock;
		for (int i = -AudioWarmup; i < AudioBlock; i++)
		{
			vec2 stereo = soundtrack(row * AudioWidth + first + i);
			if (i >= 0)
			{
				imageStore(audioImage, ivec2(first + i, row), vec4(stereo, 0.0, 0.0));
			}
		}
	}

	if (pass == PassPost)
	{
		// _I.xy: the pixel center in the XRES x YRES picture (main.cpp glue, a fraction when the picture is scaled
		// to the screen), _I.z: 1 inside the picture, 0 in the black bars around it (FULLSCREEN)
		_O = vec4(postProcess(vec2(_I.xy)) * _I.z, 1.0);
	}
}
