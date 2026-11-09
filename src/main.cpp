#define WIN32_LEAN_AND_MEAN
#define WIN32_EXTRA_LEAN
#include <windows.h>
#include <mmsystem.h>
#ifdef _DEBUG
#include <math.h>
#include <stdio.h>
#endif
#include <GL/gl.h>
#include "config.h"
#ifdef _DEBUG
// Debug renders at DEBUG_XRES x DEBUG_YRES: everything below (shader header, render target,
// dispatch, window) follows XRES and YRES. bake_config.ps1 reads config.h only: Release keeps XRES x YRES
#undef XRES
#undef YRES
#define XRES DEBUG_XRES
#define YRES DEBUG_YRES
#endif

#ifndef _DEBUG
#define SHADER_MINIFIER_IMPL
#include "shader.h"
#endif

#if FORCE_DISCRETE_GPU && defined(_DEBUG)
// Read by the NVIDIA / AMD drivers on hybrid laptops: run this exe on the discrete GPU.
// Release: not exported (Crinkler ignores dllexport, and its /EXPORT costs 76 bytes).
extern "C" __declspec(dllexport) DWORD NvOptimusEnablement = 1;
extern "C" __declspec(dllexport) int AmdPowerXpressRequestHighPerformance = 1;
#endif


#define GL_TEXTURE_3D        0x806F
#define GL_TEXTURE_WRAP_R    0x8072
#define GL_CLAMP_TO_EDGE     0x812F
#define GL_TEXTURE0          0x84C0
#define GL_RG                0x8227
#define GL_RG8               0x822B
#define GL_R16F              0x822D
#define GL_RG16F             0x822F
#define GL_RG32F             0x8230
#define GL_RGBA16F           0x881A
#define GL_READ_WRITE        0x88BA
#define GL_FRAGMENT_SHADER   0x8B30
#define GL_LINK_STATUS       0x8B82
#define GL_INFO_LOG_LENGTH   0x8B84
#define GL_COMPUTE_SHADER    0x91B9
#define GL_ALL_BARRIER_BITS  0xFFFFFFFF

// wglGetProcAddress names, '\0' separated (one string compresses better than a table)
static const char glNames[] =
	"glCreateShaderProgramv\0"
	"glUseProgram\0"
	"glUniform1i\0"
	"glDispatchCompute\0"
	"glMemoryBarrier\0"
	"glBindTextures\0"
	"glTexStorage3D\0"
	"glBindImageTextures\0"
	"glTexStorage2D\0"
	"glGenerateMipmap\0"
#ifdef _DEBUG
	"glUniform4f\0"
#elif FULLSCREEN
	"glUniform2i\0"
#endif
#ifdef _DEBUG
	"glActiveTexture\0"
	"glGetProgramiv\0"
	"glGetProgramInfoLog\0"
	"glDeleteProgram\0"
	"glGenQueries\0"
	"glQueryCounter\0"
	"glGetQueryObjectui64v\0"
#endif
	;

enum
{
	F_CreateShaderProgramv, F_UseProgram, F_Uniform1i, F_DispatchCompute, F_MemoryBarrier, F_BindTextures, F_TexStorage3D, F_BindImageTextures, F_TexStorage2D, F_GenerateMipmap,
#ifdef _DEBUG
	F_Uniform4f,
#elif FULLSCREEN
	F_Uniform2i,
#endif
#ifdef _DEBUG
	F_ActiveTexture, F_GetProgramiv, F_GetProgramInfoLog, F_DeleteProgram,
	F_GenQueries, F_QueryCounter, F_GetQueryObjectui64v,
#endif
	F_COUNT
};

static PROC glf[F_COUNT];

#define glCreateShaderProgramv ((GLuint (APIENTRY*)(GLenum, GLsizei, const char* const*))glf[F_CreateShaderProgramv])
#define glUseProgram           ((void (APIENTRY*)(GLuint))glf[F_UseProgram])
#define glUniform1i            ((void (APIENTRY*)(GLint, GLint))glf[F_Uniform1i])
#define glDispatchCompute      ((void (APIENTRY*)(GLuint, GLuint, GLuint))glf[F_DispatchCompute])
#define glMemoryBarrier        ((void (APIENTRY*)(GLbitfield))glf[F_MemoryBarrier])
#define glBindTextures         ((void (APIENTRY*)(GLuint, GLsizei, const GLuint*))glf[F_BindTextures])
#define glTexStorage3D         ((void (APIENTRY*)(GLenum, GLsizei, GLenum, GLsizei, GLsizei, GLsizei))glf[F_TexStorage3D])
#define glBindImageTextures    ((void (APIENTRY*)(GLuint, GLsizei, const GLuint*))glf[F_BindImageTextures])
#define glTexStorage2D         ((void (APIENTRY*)(GLenum, GLsizei, GLenum, GLsizei, GLsizei))glf[F_TexStorage2D])
#define glGenerateMipmap       ((void (APIENTRY*)(GLenum))glf[F_GenerateMipmap])
#ifdef _DEBUG
#define glUniform4f            ((void (APIENTRY*)(GLint, GLfloat, GLfloat, GLfloat, GLfloat))glf[F_Uniform4f])
#elif FULLSCREEN
#define glUniform2i            ((void (APIENTRY*)(GLint, GLint, GLint))glf[F_Uniform2i])
#endif
#ifdef _DEBUG
#define glActiveTexture        ((void (APIENTRY*)(GLenum))glf[F_ActiveTexture])
#define glGetProgramiv         ((void (APIENTRY*)(GLuint, GLenum, GLint*))glf[F_GetProgramiv])
#define glGetProgramInfoLog    ((void (APIENTRY*)(GLuint, GLsizei, GLsizei*, char*))glf[F_GetProgramInfoLog])
#define glDeleteProgram        ((void (APIENTRY*)(GLuint))glf[F_DeleteProgram])
#define glGenQueries           ((void (APIENTRY*)(GLsizei, GLuint*))glf[F_GenQueries])
#define glQueryCounter         ((void (APIENTRY*)(GLuint, GLenum))glf[F_QueryCounter])
#define glGetQueryObjectui64v  ((void (APIENTRY*)(GLuint, GLenum, unsigned __int64*))glf[F_GetQueryObjectui64v])
#define GL_QUERY_RESULT        0x8866
#define GL_TIMESTAMP           0x8E28

// GPU timer (Debug only): a timestamp before the passes and after each of density, bricks, light,
// render (with its mip levels) and post. The title shows each pass's time, averaged over ~10 frames.
static GLuint gpuQueries[6];
static float gpuMilliseconds[5];
#define GPU_MARK(i) glQueryCounter(gpuQueries[i], GL_TIMESTAMP)
#else
#define GPU_MARK(i)
#endif

// Prepended to intro.glsl: the config values (Debug only), then the pass id, then the stage glue.
// Release: minify.bat bakes the config values into the shader text (bake_config.ps1), so the
// version line goes with the pass id and no defines string is needed.
#define STR_(x) #x
#define STR(x) STR_(x)
#ifdef _DEBUG
static const char shaderHeader[] =
	"#version 430\n"
	"#define _XR " STR(XRES) ".\n"
	"#define _YR " STR(YRES) ".\n"
	"#define _NS " STR(NOISE_SIZE) "\n"
	"#define _TS " STR(TEXTURE_SIZE) "\n"
	"#define _BS " STR(BRICK_SIZE) "\n"
	"#define _BC " STR(BRICK_COUNT) "\n"
	"#define _LS " STR(LIGHT_SIZE) "\n"
	"#define _Q " STR(STEP_SCALE) "\n"
	"#define _GS " STR(GODRAY_SAMPLES) "\n"
	"#define _RS " STR(RENDER_SCALE) "\n"
	"#define _SR " STR(SAMPLE_RATE) "\n"
	"#define _AW " STR(AUDIO_WIDTH) "\n"
	"#define _AB " STR(AUDIO_BLOCK) "\n"
	"#define _AU " STR(AUDIO_WARMUP) "\n"
	"#define _DU " STR(DURATION) "\n"
	"#define _SD " STR(SHOT_DURATION) "\n"
	"#define _SC " STR(SHOT_COUNT) "\n"
	"#define _PR " STR(PROLOGUE) "\n";
#define PASS_HEADER(n) "#define _P " #n "\n"
static char planHeader[1024];   // "#define _CM ...": the camera plans of cameras.txt (PlanDefines())
static const char* const passDefines[7] =
{
	PASS_HEADER(0), PASS_HEADER(1), PASS_HEADER(2), PASS_HEADER(3), PASS_HEADER(4), PASS_HEADER(5), PASS_HEADER(6)
};
#else
// One header for every pass, its pass digit patched before each program: one string and no
// pointer table compress better than seven strings
static char passHeader[] = "#version 430\n#define _P 0\n";
#define PASS_DIGIT (sizeof(passHeader) - 3)
#endif

#ifdef _DEBUG
// _C(position, forward) overrides the scripted camera when the free camera is on (_CP.w > 0).
// Debug window can be resized: _V = viewport (x, y, w, h), pixels are mapped back to XRES x YRES.
static const char computeGlue[] =
	"layout(local_size_x=8,local_size_y=8)in;vec4 _O;layout(location=2)uniform vec4 _CP;layout(location=3)uniform vec4 _CF;\n"
	"#define _I gl_GlobalInvocationID\n"
	"#define _C(p,f) if(_CP.w>0.){p=_CP.xyz;f=_CF.xyz;}\n";
static const char fragmentGlue[] =
	"out vec4 _O;layout(location=1)uniform vec4 _V;\n"
	"#define _I vec3((gl_FragCoord.xy-_V.xy)*vec2(_XR,_YR)/_V.zw,1)\n"
	"#define _C(p,f)\n";
#else
// Release: no _C, bake_config.ps1 removes its call from the baked shader. The post pass gets in _I.xy
// the position of its pixel in the XRES x YRES picture (with sub-pixel fractions: the upscale filters),
// in _I.z 1 inside the picture, 0 in the black bars around it. With FULLSCREEN, _V is the screen size:
// the picture is the largest XRES:YRES rectangle that fits, centered (_W x _R, at (_V - _R) / 2). Done
// per pixel, so the host sets one uniform, and no viewport and no clear: _I.z draws the bars.
static const char computeGlue[] = "layout(local_size_x=8,local_size_y=8)in;vec4 _O;\n#define _I gl_GlobalInvocationID\n";
#if FULLSCREEN
static_assert(XRES * 9 == YRES * 16, "FULLSCREEN: the fragmentGlue fits a 16:9 picture to the screen");
static const char fragmentGlue[] =
	"out vec4 _O;layout(location=1)uniform ivec2 _V;\n"
	"#define _W min(_V.x,_V.y*16/9)\n"
	"#define _R ivec2(_W,_W*9/16)\n"
	"#define _J (gl_FragCoord.xy-(_V-_R)/2)\n"
	"#define _I vec3(_J*(" STR(XRES) "./_W),all(lessThan(abs(_J-_R*.5),_R*.5)))\n";
#else
static const char fragmentGlue[] = "out vec4 _O;\n#define _I vec3(gl_FragCoord.xy,1)\n";
#endif
#endif

// Passes 0-3 fill the volumes, 4 renders the HDR image (compute), 5 renders the soundtrack once
// (compute), 6 post-processes the image to the screen
#define PASS_COUNT 7
#define PASS_RENDER 4
#define PASS_AUDIO 5
#define PASS_POST 6
#define COLOR_LEVELS 8          // levels of the HDR target from the screen size: 1 + intro.glsl BloomLevels

// Volumes, indexed like the passes that fill them and like the GLSL bindings.
// Each volume is texture/image unit i and texture name i+1; pass i dispatches size^3 threads.
static const GLenum volumeFormat[4] = { GL_R16F, GL_RG8, GL_RG8, GL_RG16F };
static const int volumeSize[4] = { NOISE_SIZE, TEXTURE_SIZE, BRICK_COUNT, LIGHT_SIZE };
// Texture names 1..6 (the volumes, the render target, the soundtrack): texture units 0..4 and image
// units 0..5 are bound in one call each (glBindTextures, glBindImageTextures)
static const GLuint textureNames[6] = { 1, 2, 3, 4, 5, 6 };

static const PIXELFORMATDESCRIPTOR pfd =
{
	sizeof(PIXELFORMATDESCRIPTOR), 1, PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER, PFD_TYPE_RGBA, 32
};

static GLuint programs[PASS_COUNT];

// Soundtrack: 16-bit stereo PCM read back from the audio pass, played in one go by waveOut.
// The play position is the intro clock.
static short audioBuffer[AUDIO_SAMPLES * 2];
static WAVEFORMATEX waveFormat = { WAVE_FORMAT_PCM, 2, SAMPLE_RATE, SAMPLE_RATE * 4, 4, 16, 0 };
static WAVEHDR waveHeader = { (LPSTR)audioBuffer, AUDIO_SAMPLES * 4 };
static MMTIME waveTime = { TIME_SAMPLES };
static HWAVEOUT waveOut;

#ifdef _DEBUG
// Free camera (debug only), in box units / radians
static bool freeCamera = false;
static float cameraPosition[3] = { 0.5f, 0.4f, -0.8f };
static float cameraYaw = 0.0f, cameraPitch = 0.0f;
#endif

// sample: the clock, as a sample position of the soundtrack (the shader's uniformSample)
static void RunPass(int pass, int sample)
{
	glUseProgram(programs[pass]);
	glUniform1i(0, sample);
	int n = volumeSize[pass];
	glDispatchCompute(n / 8, n / 8, n);
	glMemoryBarrier(GL_ALL_BARRIER_BITS);
}

// Renders the soundtrack (audio pass) and reads it back. The float samples become 16-bit PCM in
// glGetTexImage, clamped to -1..1. glGetTexImage reads the 2D texture of the active unit: unit 0,
// where the setup binds the audio texture last (Debug activates unit 0 again).
static void RenderAudio()
{
	glUseProgram(programs[PASS_AUDIO]);
	glDispatchCompute(AUDIO_WIDTH / AUDIO_BLOCK / 8, AUDIO_ROWS / 8, 1);
	glMemoryBarrier(GL_ALL_BARRIER_BITS);
#ifdef _DEBUG
	glActiveTexture(GL_TEXTURE0);
#endif
	glGetTexImage(GL_TEXTURE_2D, 0, GL_RG, GL_SHORT, audioBuffer);
	// glGenerateMipmap works on the 2D texture of the active unit: the render target. Release stays
	// on unit 0 and binds it there; Debug uses unit 4, where it is bound.
#ifdef _DEBUG
	glActiveTexture(GL_TEXTURE0 + 4);
#else
	glBindTexture(GL_TEXTURE_2D, 5);
#endif
}

static void RenderFrame(HDC hDC, int sample)
{
	GPU_MARK(0);
	for (int pass = 1; pass < PASS_RENDER; ++pass)
	{
		RunPass(pass, sample);
		GPU_MARK(pass);
	}

	// Render the HDR image, then its mip levels: the bloom (and with supersampling, the screen size level)
	glUseProgram(programs[PASS_RENDER]);
	glUniform1i(0, sample);
#ifdef _DEBUG
	glUniform4f(2, cameraPosition[0], cameraPosition[1], cameraPosition[2], freeCamera ? 1.0f : 0.0f);
	glUniform4f(3, sinf(cameraYaw) * cosf(cameraPitch), sinf(cameraPitch), cosf(cameraYaw) * cosf(cameraPitch), 0.0f);
#endif
	glDispatchCompute(XRES * RENDER_SCALE / 8, YRES * RENDER_SCALE / 8, 1);
	glMemoryBarrier(GL_ALL_BARRIER_BITS);
	glGenerateMipmap(GL_TEXTURE_2D);
	GPU_MARK(4);

	// Post process to the screen (time: the apocalypse scanlines)
	glUseProgram(programs[PASS_POST]);
	glUniform1i(0, sample);
#ifdef _DEBUG
	// Largest 16:9 viewport that fits the client area, centered (black bars when maximized).
	RECT client;
	GetClientRect(WindowFromDC(hDC), &client);
	int width = client.right, height = client.bottom;
	int viewWidth = width * YRES < height * XRES ? width : height * XRES / YRES;
	int viewHeight = viewWidth * YRES / XRES;
	int x = (width - viewWidth) / 2, y = (height - viewHeight) / 2;
	glClear(GL_COLOR_BUFFER_BIT);
	glViewport(x, y, viewWidth, viewHeight);
	glUniform4f(1, (float)x, (float)y, (float)viewWidth, (float)viewHeight);
#endif
	glRects(-1, -1, 1, 1);
	GPU_MARK(5);
	SwapBuffers(hDC);
}

#ifdef _DEBUG

// Debug: intro.glsl is read from the working directory (the project dir when started
// from Visual Studio) and recompiled whenever it is saved. Errors go to the debugger
// output and the window title; the previous working programs are kept.
// Keys: SPACE pause, LEFT/RIGHT seek (hold SHIFT for x5), BACKSPACE restart, M mute the
// soundtrack, F5 save it to bin\intro4k.wav,
// L toggle the DEBUG_FRAME_RATE cap (config.h; the title shows the frame's own render time),
// arrows UP/DOWN + WASD/QE + left mouse drag: free camera (C: back to the scripted one),
// camera plans in cameras.txt: 0-9 go to plan n (SHIFT: its end), F6 / F7 save its start / end
// view, DELETE remove its end view (then its start view), T stop / play the plans (they play from
// the start, and cameras.txt is read again when it changes).

#define SHADER_FILE "intro.glsl"

static char shaderSource[1 << 17];
static char shaderLog[1 << 14];
static FILETIME shaderTime;

static bool LoadShaderFile()
{
	HANDLE file = CreateFileA(SHADER_FILE, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
	if (file == INVALID_HANDLE_VALUE)
	{
		return false;
	}
	DWORD size = 0;
	BOOL ok = ReadFile(file, shaderSource, sizeof(shaderSource) - 1, &size, NULL);
	CloseHandle(file);
	shaderSource[ok ? size : 0] = 0;
	return ok && size > 0;
}

static bool ShaderFileChanged()
{
	WIN32_FILE_ATTRIBUTE_DATA data;
	if (!GetFileAttributesExA(SHADER_FILE, GetFileExInfoStandard, &data) || CompareFileTime(&data.ftLastWriteTime, &shaderTime) == 0)
	{
		return false;
	}
	shaderTime = data.ftLastWriteTime;
	return true;
}

static bool CompilePrograms(const char* source)
{
	GLuint fresh[PASS_COUNT];
	bool success = true;
	shaderLog[0] = 0;

	for (int pass = 0; pass < PASS_COUNT; ++pass)
	{
		const char* strings[5] = { shaderHeader, planHeader, passDefines[pass], pass < PASS_POST ? computeGlue : fragmentGlue, source };
		fresh[pass] = glCreateShaderProgramv(pass < PASS_POST ? GL_COMPUTE_SHADER : GL_FRAGMENT_SHADER, 5, strings);

		GLint linked = 0;
		glGetProgramiv(fresh[pass], GL_LINK_STATUS, &linked);
		if (!linked)
		{
			int length = lstrlenA(shaderLog);
			wsprintfA(shaderLog + length, "---- pass %d ----\n", pass);
			length = lstrlenA(shaderLog);
			glGetProgramInfoLog(fresh[pass], sizeof(shaderLog) - length - 1, NULL, shaderLog + length);
			success = false;
		}
	}

	for (int pass = 0; pass < PASS_COUNT; ++pass)
	{
		GLuint unused = success ? programs[pass] : fresh[pass];
		if (unused)
		{
			glDeleteProgram(unused);
		}
		if (success)
		{
			programs[pass] = fresh[pass];
		}
	}

	if (!success)
	{
		OutputDebugStringA(shaderLog);
	}
	return success;
}

static bool KeyPressed(int key, bool* wasDown)
{
	bool down = (GetAsyncKeyState(key) & 0x8000) != 0;
	bool pressed = down && !*wasDown;
	*wasDown = down;
	return pressed;
}

// UP/DOWN or W/S: forward/back, A/D: strafe, Q/E: down/up, SHIFT: faster,
// left mouse drag in the window: look around, C: back to the scripted camera.
// Returns true when the user moved the camera or pressed C
static bool UpdateFreeCamera(HWND hWnd, float delta)
{
	static POINT previousCursor;
	POINT cursor;
	GetCursorPos(&cursor);

	bool moved = false;
	if (GetAsyncKeyState('C') & 0x8000)
	{
		freeCamera = false;
		moved = true;
	}

	float forward[3] = { sinf(cameraYaw) * cosf(cameraPitch), sinf(cameraPitch), cosf(cameraYaw) * cosf(cameraPitch) };
	float right[3] = { -forward[2], 0.0f, forward[0] };     // cross(forward, up), as in the shader
	float rightLength = sqrtf(right[0] * right[0] + right[2] * right[2]) + 1e-6f;
	float move[3] = { 0.0f, 0.0f, 0.0f };

	float axisForward = 0.0f, axisRight = 0.0f, axisUp = 0.0f;
	if ((GetAsyncKeyState(VK_UP) & 0x8000) || (GetAsyncKeyState('W') & 0x8000)) axisForward += 1.0f;
	if ((GetAsyncKeyState(VK_DOWN) & 0x8000) || (GetAsyncKeyState('S') & 0x8000)) axisForward -= 1.0f;
	if (GetAsyncKeyState('D') & 0x8000) axisRight += 1.0f;
	if (GetAsyncKeyState('A') & 0x8000) axisRight -= 1.0f;
	if (GetAsyncKeyState('E') & 0x8000) axisUp += 1.0f;
	if (GetAsyncKeyState('Q') & 0x8000) axisUp -= 1.0f;

	bool looking = false;
	if (GetAsyncKeyState(VK_LBUTTON) & 0x8000)
	{
		POINT local = cursor;
		RECT client;
		ScreenToClient(hWnd, &local);
		GetClientRect(hWnd, &client);
		looking = PtInRect(&client, local) != 0;
	}

	if (axisForward != 0.0f || axisRight != 0.0f || axisUp != 0.0f || looking)
	{
		freeCamera = true;
		moved = true;
	}

	if (looking)
	{
		cameraYaw -= (cursor.x - previousCursor.x) * 0.004f;
		cameraPitch -= (cursor.y - previousCursor.y) * 0.004f;
		cameraPitch = cameraPitch < -1.5f ? -1.5f : (cameraPitch > 1.5f ? 1.5f : cameraPitch);
	}
	previousCursor = cursor;

	float speed = delta * ((GetAsyncKeyState(VK_SHIFT) & 0x8000) ? 1.0f : 0.25f);
	for (int i = 0; i < 3; ++i)
	{
		move[i] = forward[i] * axisForward + right[i] / rightLength * axisRight;
	}
	move[1] += axisUp;
	for (int i = 0; i < 3; ++i)
	{
		cameraPosition[i] += move[i] * speed;
	}
	return moved;
}

// Camera plans: the intro is cut into SHOT_COUNT plans (config.h): plan 0, the prologue, lasts
// PROLOGUE seconds, the others SHOT_DURATION seconds (PlanStart()). A plan has a start view and optionally an end view: with
// both, the camera pans from one to the other over the whole plan, linearly (the cut lands on an
// already moving camera); with the start view only, the plan is static. cameras.txt (next to
// intro.glsl) holds them, one line per view: plan number, start or end, position and forward as
// GLSL vectors (ready for the camera script of renderPixel()), yaw and pitch of the free camera.
// It is read again before every change and rewritten in plan order: hand edits of the values
// are kept, other lines (comments) are not.
#define CAMERA_FILE "cameras.txt"
#define VIEW_FORMAT "plan %d %7s position=vec3(%f, %f, %f) forward=vec3(%f, %f, %f) yaw=%f pitch=%f"

struct CameraView
{
	bool set;
	float position[3], yaw, pitch;
};

static CameraView plans[SHOT_COUNT][2];        // [plan 0..SHOT_COUNT - 1][0 = start, 1 = end]

static void LoadPlans()
{
	ZeroMemory(plans, sizeof(plans));
	FILE* file = fopen(CAMERA_FILE, "r");
	if (!file)
	{
		return;
	}
	char line[256], kind[8];
	int plan;
	CameraView view;
	float forward[3];
	while (fgets(line, sizeof(line), file))
	{
		if (sscanf(line, VIEW_FORMAT, &plan, kind, &view.position[0], &view.position[1], &view.position[2],
			&forward[0], &forward[1], &forward[2], &view.yaw, &view.pitch) == 10 && plan >= 0 && plan < SHOT_COUNT)
		{
			view.set = true;
			plans[plan][lstrcmpA(kind, "end") == 0] = view;   // a later line of the same view wins
		}
	}
	fclose(file);
}

static bool SavePlans()
{
	FILE* file = fopen(CAMERA_FILE, "w");
	if (!file)
	{
		return false;
	}
	fprintf(file, "# intro4k camera plans (Debug build): %d plans of %d s (plan 0: %d s, the last one runs to the end). 0-9 go to a plan (SHIFT: its end), F6 / F7 save its\n"
	              "# start / end view (with an end view, the plan pans), DELETE removes its end view then its start view, T stops / plays.\n"
	              "# plan view position forward (box units, the box is [0,1]^3) yaw pitch (radians, free camera)\n", SHOT_COUNT, SHOT_DURATION, PROLOGUE);
	for (int plan = 0; plan < SHOT_COUNT; ++plan)
	{
		for (int end = 0; end < 2; ++end)
		{
			const CameraView& view = plans[plan][end];
			if (view.set)
			{
				fprintf(file, "plan %d %s position=vec3(%.4f, %.4f, %.4f) forward=vec3(%.4f, %.4f, %.4f) yaw=%.4f pitch=%.4f\n", plan, end ? "end" : "start",
					view.position[0], view.position[1], view.position[2], sinf(view.yaw) * cosf(view.pitch), sinf(view.pitch), cosf(view.yaw) * cosf(view.pitch),
					view.yaw, view.pitch);
			}
		}
	}
	fclose(file);
	return true;
}

// True when cameras.txt was written since the last call (a save, or a hand edit): the playback
// reads it again. True on the first call.
static bool PlansFileChanged()
{
	static FILETIME plansTime;
	WIN32_FILE_ATTRIBUTE_DATA data;
	if (!GetFileAttributesExA(CAMERA_FILE, GetFileExInfoStandard, &data) || CompareFileTime(&data.ftLastWriteTime, &plansTime) == 0)
	{
		return false;
	}
	plansTime = data.ftLastWriteTime;
	return true;
}

static void SetCamera(const CameraView& view)
{
	for (int i = 0; i < 3; ++i)
	{
		cameraPosition[i] = view.position[i];
	}
	cameraYaw = view.yaw;
	cameraPitch = view.pitch;
	freeCamera = true;
}

// Start time of a plan: plan 0 (the prologue) at 0, plan n at PROLOGUE + (n - 1) x SHOT_DURATION
static float PlanStart(int plan)
{
	return plan == 0 ? 0.0f : (float)(PROLOGUE + (plan - 1) * SHOT_DURATION);
}

static int PlanAt(float time)
{
	int plan = time < PROLOGUE ? 0 : 1 + (int)((time - PROLOGUE) / SHOT_DURATION);
	return plan > SHOT_COUNT - 1 ? SHOT_COUNT - 1 : plan;
}

// End time of a plan: the last one runs until DURATION (it pans over all of it)
static float PlanEnd(int plan)
{
	return plan == SHOT_COUNT - 1 ? (float)DURATION : PlanStart(plan + 1);
}

// The plans for the shader camera (planCamera() in intro.glsl): planHeader = "#define _CM" and per
// plan its start and end views (the start view for a static plan), x y z yaw pitch in hundredths.
// A plan without a view holds the last view of the plan before it; without any, a side view of
// the box. bake_config.ps1 writes the same values into the Release shader.
static void PlanDefines()
{
	static const CameraView defaultView = { true, { 0.5f, 0.15f, 2.0f }, 3.14f, 0.2f };
	const CameraView* last = &defaultView;
	char* out = planHeader + wsprintfA(planHeader, "#define _CM ");
	for (int plan = 0; plan < SHOT_COUNT; ++plan)
	{
		const CameraView* start = plans[plan][0].set ? &plans[plan][0] : last;
		const CameraView* end = plans[plan][1].set ? &plans[plan][1] : start;
		const CameraView* views[2] = { start, end };
		for (int v = 0; v < 2; ++v)
		{
			float values[5] = { views[v]->position[0], views[v]->position[1], views[v]->position[2], views[v]->yaw, views[v]->pitch };
			for (int i = 0; i < 5; ++i)
			{
				out += wsprintfA(out, plan + v + i > 0 ? ",%d" : "%d", (int)floorf(values[i] * 100.0f + 0.5f));
			}
		}
		last = end;
	}
	lstrcpyA(out, "\n");
}

// Playback: the camera of the plans at this time. False when the plan has no view yet (the
// scripted camera shows then).
static bool PlayPlans(float time)
{
	int plan = PlanAt(time);
	CameraView view = plans[plan][0];
	const CameraView& end = plans[plan][1];
	if (!view.set)
	{
		freeCamera = false;
		return false;
	}
	if (end.set)
	{
		float start = PlanStart(plan);
		float f = (time - start) / (PlanEnd(plan) - start);
		f = f < 0.0f ? 0.0f : (f > 1.0f ? 1.0f : f);
		for (int i = 0; i < 3; ++i)
		{
			view.position[i] += (end.position[i] - view.position[i]) * f;
		}
		view.yaw += (end.yaw - view.yaw) * f;
		view.pitch += (end.pitch - view.pitch) * f;
	}
	SetCamera(view);
	return true;
}

// Debug audio: the soundtrack plays from the current time and is the clock while it plays.
// Seeking or pausing stops it; it starts again from the new time. A new render (shader saved)
// restarts it too.
static bool audioPlaying = false;
static int audioStart;          // sample the playback started from
static float audioMilliseconds; // render + readback time of the last render
static int audioPeak, audioClipped;

static void StopAudio()
{
	if (audioPlaying)
	{
		waveOutReset(waveOut);
		audioPlaying = false;
	}
}

static void PlayAudio(float from)
{
	waveOutReset(waveOut);
	waveOutUnprepareHeader(waveOut, &waveHeader, sizeof(waveHeader));
	audioStart = (int)(from * SAMPLE_RATE);
	audioPlaying = waveOut && audioStart < AUDIO_SAMPLES;       // no device: the delta clock runs
	if (audioPlaying)
	{
		waveHeader.lpData = (LPSTR)(audioBuffer + audioStart * 2);
		waveHeader.dwBufferLength = (AUDIO_SAMPLES - audioStart) * 4;
		waveHeader.dwFlags = 0;
		waveOutPrepareHeader(waveOut, &waveHeader, sizeof(waveHeader));
		waveOutWrite(waveOut, &waveHeader, sizeof(waveHeader));
	}
}

// Renders the soundtrack, timed, and measures its peak and clipped samples (title bar)
static void RenderAudioTimed()
{
	LARGE_INTEGER frequency, start, end;
	QueryPerformanceFrequency(&frequency);
	StopAudio();    // the buffer is rewritten
	QueryPerformanceCounter(&start);
	RenderAudio();
	QueryPerformanceCounter(&end);
	audioMilliseconds = (float)(end.QuadPart - start.QuadPart) * 1000.0f / (float)frequency.QuadPart;
	audioPeak = 0;
	audioClipped = 0;
	for (int i = 0; i < AUDIO_SAMPLES * 2; ++i)
	{
		int value = audioBuffer[i] < 0 ? -audioBuffer[i] : audioBuffer[i];
		audioPeak = value > audioPeak ? value : audioPeak;
		audioClipped += value >= 32767;
	}
}

// F5: writes the soundtrack next to the exes, to check it in an audio editor
static bool SaveAudio()
{
	const DWORD dataSize = AUDIO_SAMPLES * 4;
	const DWORD header[11] =
	{
		0x46464952, 36 + dataSize, 0x45564157,          // "RIFF", size, "WAVE"
		0x20746D66, 16, WAVE_FORMAT_PCM | (2 << 16),    // "fmt ", 16 bytes: PCM, 2 channels
		SAMPLE_RATE, SAMPLE_RATE * 4, 4 | (16 << 16),   // rate, bytes per second, block size, 16 bits
		0x61746164, dataSize                            // "data", size
	};
	HANDLE file = CreateFileA("..\\bin\\intro4k.wav", GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
	if (file == INVALID_HANDLE_VALUE)
	{
		return false;
	}
	DWORD written;
	BOOL ok = WriteFile(file, header, sizeof(header), &written, NULL) && WriteFile(file, audioBuffer, dataSize, &written, NULL);
	CloseHandle(file);
	return ok != FALSE;
}

// Keeps the client area at XRES:YRES while the window is dragged by an edge or corner.
static LRESULT CALLBACK WindowProc(HWND hWnd, UINT message, WPARAM wParam, LPARAM lParam)
{
	if (message == WM_SIZING)
	{
		RECT frame = { 0, 0, 0, 0 };
		AdjustWindowRect(&frame, WS_OVERLAPPEDWINDOW, FALSE);
		int frameWidth = frame.right - frame.left, frameHeight = frame.bottom - frame.top;
		RECT* rect = (RECT*)lParam;
		if (wParam == WMSZ_TOP || wParam == WMSZ_BOTTOM)
		{
			rect->right = rect->left + (rect->bottom - rect->top - frameHeight) * XRES / YRES + frameWidth;
		}
		else
		{
			int height = (rect->right - rect->left - frameWidth) * YRES / XRES + frameHeight;
			if (wParam == WMSZ_TOPLEFT || wParam == WMSZ_TOPRIGHT)
			{
				rect->top = rect->bottom - height;
			}
			else
			{
				rect->bottom = rect->top + height;
			}
		}
		return TRUE;
	}
	return DefWindowProcA(hWnd, message, wParam, lParam);
}

int WINAPI WinMain(HINSTANCE, HINSTANCE, LPSTR, int)
{
	RECT rect = { 0, 0, XRES, YRES };
	AdjustWindowRect(&rect, WS_OVERLAPPEDWINDOW, FALSE);
	WNDCLASSA windowClass = {};
	windowClass.style = CS_OWNDC;
	windowClass.lpfnWndProc = WindowProc;
	windowClass.hInstance = GetModuleHandleA(NULL);
	windowClass.hCursor = LoadCursorA(NULL, (LPCSTR)IDC_ARROW);
	windowClass.lpszClassName = "intro4k";
	RegisterClassA(&windowClass);
	HWND hWnd = CreateWindowExA(0, "intro4k", "intro4k", WS_OVERLAPPEDWINDOW | WS_VISIBLE, CW_USEDEFAULT, CW_USEDEFAULT, rect.right - rect.left, rect.bottom - rect.top, NULL, NULL, NULL, NULL);
	HDC hDC = GetDC(hWnd);
	SetPixelFormat(hDC, ChoosePixelFormat(hDC, &pfd), &pfd);
	wglMakeCurrent(hDC, wglCreateContext(hDC));

#else

extern "C" int _fltused = 0;

extern "C" void entry()
{
	// Borderless window, no display mode change: over the whole screen (FULLSCREEN, the picture is
	// scaled to fit, see below), or XRES x YRES at the top left of the screen (one exe per
	// resolution). DPI aware, else with a Windows display scale (125%...) Windows would scale it.
	SetProcessDPIAware();
#if FULLSCREEN
	int screenWidth = GetSystemMetrics(SM_CXSCREEN), screenHeight = GetSystemMetrics(SM_CYSCREEN);
	HDC hDC = GetDC(CreateWindowExA(0, "edit", NULL, WS_POPUP | WS_VISIBLE, 0, 0, screenWidth, screenHeight, NULL, NULL, NULL, NULL));
#else
	HDC hDC = GetDC(CreateWindowExA(0, "edit", NULL, WS_POPUP | WS_VISIBLE, 0, 0, XRES, YRES, NULL, NULL, NULL, NULL));
#endif
	SetPixelFormat(hDC, ChoosePixelFormat(hDC, &pfd), &pfd);
	wglMakeCurrent(hDC, wglCreateContext(hDC));
	ShowCursor(FALSE);

#endif

	const char* name = glNames;
	for (int i = 0; i < F_COUNT; ++i)
	{
		glf[i] = wglGetProcAddress(name);
		while (*name++);
	}

	// Texture names are never generated: the compatibility profile accepts any unused name. Each
	// texture is set up on unit 0, then bound to its unit.
	for (int i = 0; i < 4; ++i)
	{
		int size = volumeSize[i];
		GLint wrap = i ? GL_CLAMP_TO_EDGE : GL_REPEAT;
		glBindTexture(GL_TEXTURE_3D, i + 1);
		glTexStorage3D(GL_TEXTURE_3D, 1, volumeFormat[i], size, size, size);
		glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_S, wrap);
		glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_T, wrap);
		glTexParameteri(GL_TEXTURE_3D, GL_TEXTURE_WRAP_R, wrap);
	}

	// HDR color target of the render pass: unit 4, texture name 5, with mip levels: with
	// supersampling the screen size level (RENDER_SCALE 2: level 1, a box downsample), then the
	// bloom levels below it (intro.glsl BloomLevels). glGenerateMipmap needs it on the active
	// unit: RenderAudio() binds it again (Debug: activates unit 4).
	glBindTexture(GL_TEXTURE_2D, 5);
	glTexStorage2D(GL_TEXTURE_2D, COLOR_LEVELS + RENDER_SCALE - 1, GL_RGBA16F, XRES * RENDER_SCALE, YRES * RENDER_SCALE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR_MIPMAP_LINEAR);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	// Texture units 0..4: the volumes and the render target, each on its own target
	glBindTextures(0, 5, textureNames);

	// Soundtrack of the audio pass: image unit 5, texture name 6, AUDIO_WIDTH stereo samples per
	// row. Bound last on unit 0 (2D): the texture glGetTexImage reads in RenderAudio().
	glBindTexture(GL_TEXTURE_2D, 6);
	glTexStorage2D(GL_TEXTURE_2D, 1, GL_RG32F, AUDIO_WIDTH, AUDIO_ROWS);
	// Image units 0..5: level 0 of each texture, all layers (the volumes), read-write, in the
	// texture's own format
	glBindImageTextures(0, 6, textureNames);
	waveOutOpen(&waveOut, WAVE_MAPPER, &waveFormat, 0, 0, CALLBACK_NULL);

#ifdef _DEBUG

	glGenQueries(6, gpuQueries);
	ShaderFileChanged();
	PlansFileChanged();
	LoadPlans();
	PlanDefines();
	if (!LoadShaderFile() || !CompilePrograms(shaderSource))
	{
		MessageBoxA(hWnd, shaderLog[0] ? shaderLog : "Cannot read " SHADER_FILE " (run from the src folder)", "intro4k", MB_OK);
		ExitProcess(1);
	}
	RunPass(0, 0);
	RenderAudioTimed();

	LARGE_INTEGER frequency, previous, now;
	QueryPerformanceFrequency(&frequency);
	QueryPerformanceCounter(&previous);

	float time = 0.0f;
	bool paused = false, spaceDown = false, backDown = false, compileError = false;
	bool muted = false, muteDown = false, saveDown = false, saved = false;
	bool startDown = false, endDown = false, deleteDown = false, previewDown = false, planDown[10] = {};
	bool previewing = true;     // the recorded plans play from the start (T stops them)
	int playbackShown = -1;     // PlayPlans() result in the title: other messages stay until it changes
	bool capped = DEBUG_FRAME_RATE > 0, capDown = false;
	const float frameSeconds = 1.0f / (DEBUG_FRAME_RATE > 0 ? DEBUG_FRAME_RATE : 1);
	char title[512], cameraStatus[64] = "";
	timeBeginPeriod(1);     // 1 ms Sleep() resolution, for the frame rate cap

	while (IsWindow(hWnd) && !(GetAsyncKeyState(VK_ESCAPE) & 0x8000))
	{
		MSG msg;
		while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE))
		{
			TranslateMessage(&msg);
			DispatchMessageA(&msg);
		}

		QueryPerformanceCounter(&now);
		float delta = (float)(now.QuadPart - previous.QuadPart) / (float)frequency.QuadPart;
		previous = now;

		bool foreground = GetForegroundWindow() == hWnd;
		bool seeking = false;
		if (foreground)
		{
			float seek = (GetAsyncKeyState(VK_SHIFT) & 0x8000) ? 10.0f : 2.0f;
			if (KeyPressed(VK_SPACE, &spaceDown)) paused = !paused;
			if (KeyPressed(VK_BACK, &backDown))
			{
				time = 0.0f;
				StopAudio();
			}
			if (GetAsyncKeyState(VK_RIGHT) & 0x8000)
			{
				time += delta * seek;
				seeking = true;
			}
			if (GetAsyncKeyState(VK_LEFT) & 0x8000)
			{
				time -= delta * seek;
				seeking = true;
			}
			if (time < 0.0f) time = 0.0f;
			if (KeyPressed('M', &muteDown))
			{
				muted = !muted;
				waveOutSetVolume(waveOut, muted ? 0 : 0xFFFFFFFF);
			}
			if (KeyPressed(VK_F5, &saveDown)) saved = SaveAudio();
			if (KeyPressed('L', &capDown)) capped = !capped && DEBUG_FRAME_RATE > 0;
			int plan = PlanAt(time);
			bool saveStart = KeyPressed(VK_F6, &startDown), saveEnd = KeyPressed(VK_F7, &endDown);
			if (saveStart || saveEnd)
			{
				LoadPlans();
				if (!freeCamera)
				{
					lstrcpyA(cameraStatus, "  [F6/F7: move the free camera first]");
				}
				else if (saveEnd && !plans[plan][0].set)
				{
					wsprintfA(cameraStatus, "  [plan %d: save its start view first (F6)]", plan);
				}
				else
				{
					CameraView& view = plans[plan][saveEnd];
					view.set = true;
					for (int i = 0; i < 3; ++i)
					{
						view.position[i] = cameraPosition[i];
					}
					view.yaw = cameraYaw;
					view.pitch = cameraPitch;
					wsprintfA(cameraStatus, SavePlans() ? "  [plan %d: %s view saved]" : "  [plan %d: cannot write " CAMERA_FILE "]", plan, saveEnd ? "end" : "start");
				}
			}
			if (KeyPressed(VK_DELETE, &deleteDown))
			{
				LoadPlans();
				int view = plans[plan][1].set ? 1 : 0;
				if (plans[plan][view].set)
				{
					plans[plan][view].set = false;
					SavePlans();
					wsprintfA(cameraStatus, "  [plan %d: %s view removed]", plan, view ? "end" : "start");
				}
			}
			if (KeyPressed('T', &previewDown))
			{
				LoadPlans();
				previewing = !previewing;
				playbackShown = -1;
				lstrcpyA(cameraStatus, "");
			}
			for (int number = 0; number < SHOT_COUNT; ++number)
			{
				if (KeyPressed('0' + number, &planDown[number]))
				{
					// The plan start, or with SHIFT just before its end; the soundtrack restarts there
					bool atEnd = (GetAsyncKeyState(VK_SHIFT) & 0x8000) != 0;
					LoadPlans();
					time = atEnd ? PlanEnd(number) - 0.05f : PlanStart(number);
					StopAudio();
					const CameraView& view = plans[number][atEnd && plans[number][1].set];
					if (view.set)
					{
						SetCamera(view);
					}
					wsprintfA(cameraStatus, view.set ? "  [plan %d %s]" : "  [plan %d %s: no view yet, F6 / F7]", number, atEnd ? "end" : "start");
				}
			}
			if (UpdateFreeCamera(hWnd, delta))
			{
				previewing = false;     // flying the camera or C stops the playback (T plays again)
			}
		}

		// The soundtrack is the clock while it plays; it restarts from the current time after a
		// seek, a pause or a new render. The delta clock runs once it has ended (or without device).
		if (seeking || paused)
		{
			StopAudio();
		}
		else if (!audioPlaying)
		{
			PlayAudio(time);
		}
		if (audioPlaying && (waveHeader.dwFlags & WHDR_DONE))
		{
			audioPlaying = false;
		}
		if (audioPlaying)
		{
			waveOutGetPosition(waveOut, &waveTime, sizeof(waveTime));
			time = (float)(audioStart + (int)waveTime.u.sample) / SAMPLE_RATE;
		}
		else if (!paused && !seeking)
		{
			time += delta;
		}

		if (ShaderFileChanged() && LoadShaderFile())
		{
			compileError = !CompilePrograms(shaderSource);
			if (!compileError)
			{
				RunPass(0, 0);
				RenderAudioTimed();
			}
		}

		// cameras.txt changed (a save, or a hand edit): the playback and the shader camera follow
		if (PlansFileChanged())
		{
			LoadPlans();
			PlanDefines();
			compileError = !CompilePrograms(shaderSource);
		}

		if (previewing)
		{
			int shown = PlayPlans(time);
			if (shown != playbackShown)
			{
				playbackShown = shown;
				lstrcpyA(cameraStatus, shown ? "  [plans, T = stop]" : "  [plans: no view here, scripted camera, T = stop]");
			}
		}
		RenderFrame(hDC, (int)(time * SAMPLE_RATE));

		// The frame's own cost: wait for the GPU, so the cap below does not hide it
		LARGE_INTEGER rendered;
		glFinish();
		QueryPerformanceCounter(&rendered);
		float renderSeconds = (float)(rendered.QuadPart - now.QuadPart) / (float)frequency.QuadPart;

		// GPU time of each pass (the frame is finished: the timestamps are ready), in tenths of ms
		unsigned __int64 stamps[6];
		int gpuTenths[5];
		for (int i = 0; i < 6; ++i)
		{
			glGetQueryObjectui64v(gpuQueries[i], GL_QUERY_RESULT, &stamps[i]);
		}
		for (int i = 0; i < 5; ++i)
		{
			gpuMilliseconds[i] += ((float)(stamps[i + 1] - stamps[i]) * 1e-6f - gpuMilliseconds[i]) * 0.1f;
			gpuTenths[i] = (int)(gpuMilliseconds[i] * 10.0f + 0.5f);
		}

		wsprintfA(title, "intro4k  t=%d.%02ds  plan %d  %dms (render %dms%s)  gpu ms: density %d.%d bricks %d.%d light %d.%d render %d.%d post %d.%d  audio %dms peak %d%%%s%s%s%s%s%s%s", (int)time, (int)(time * 100.0f) % 100, PlanAt(time),
			(int)(delta * 1000.0f), (int)(renderSeconds * 1000.0f), capped ? ", capped, L" : ", L = cap",
			gpuTenths[0] / 10, gpuTenths[0] % 10, gpuTenths[1] / 10, gpuTenths[1] % 10, gpuTenths[2] / 10, gpuTenths[2] % 10, gpuTenths[3] / 10, gpuTenths[3] % 10, gpuTenths[4] / 10, gpuTenths[4] % 10,
			(int)audioMilliseconds, audioPeak * 100 / 32767, audioClipped ? "  CLIPPING" : "", muted ? "  [muted, M]" : "", saved ? "  [saved bin\\intro4k.wav]" : "",
			paused ? "  [paused]" : "", freeCamera ? "  [free camera, C = scripted]" : "", cameraStatus, compileError ? "  SHADER ERROR (see debugger output)" : "");
		SetWindowTextA(hWnd, title);

		// Frame rate cap: sleep away the rest of the frame, the GPU idles meanwhile
		if (capped && renderSeconds < frameSeconds - 0.001f)
		{
			Sleep((DWORD)((frameSeconds - renderSeconds) * 1000.0f));
		}
	}

	ExitProcess(0);
	return 0;
}

#else

	for (int pass = 0; pass < PASS_COUNT; ++pass)
	{
		const char* strings[3] = { passHeader, pass < PASS_POST ? computeGlue : fragmentGlue, intro_glsl };
		programs[pass] = glCreateShaderProgramv(pass < PASS_POST ? GL_COMPUTE_SHADER : GL_FRAGMENT_SHADER, 3, strings);
		++passHeader[PASS_DIGIT];      // "_P 0" -> "_P 1"...
	}
#if FULLSCREEN
	// The post pass fits the XRES x YRES picture to the screen itself (fragmentGlue): it only needs
	// the screen size. The viewport is the whole window.
	glUseProgram(programs[PASS_POST]);
	glUniform2i(1, screenWidth, screenHeight);
#endif
	RunPass(0, 0);
	RenderAudio();
	waveOutPrepareHeader(waveOut, &waveHeader, sizeof(waveHeader));
	waveOutWrite(waveOut, &waveHeader, sizeof(waveHeader));

	// The play position is the clock: the shader gets it in samples
	do
	{
		PeekMessageA(NULL, NULL, 0, 0, PM_REMOVE);
		waveOutGetPosition(waveOut, &waveTime, sizeof(waveTime));
		RenderFrame(hDC, waveTime.u.sample);
	}
	while (!GetAsyncKeyState(VK_ESCAPE) && waveTime.u.sample < DURATION * SAMPLE_RATE);

	ExitProcess(0);
}

#endif
