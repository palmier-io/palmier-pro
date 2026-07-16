// Hand-authored equivalent of ThorVG's meson-generated config.h (docs/lottie-bake-v1.md §3 — this
// repo builds ThorVG via a static-lib .vcxproj, not meson). Mirrors meson_options.txt's own
// defaults for every option this vendored subset actually reaches; options gated behind
// unvendored files (svg/png/jpg/webp/sfnt loaders, gl/wg engines, lottie_exp, openmp) are left
// undefined rather than 0 — matches meson's own configuration_data, which only emits a #define
// for options explicitly set. Keep in sync by hand if the ThorVG pin bumps.
#pragma once

#define THORVG_VERSION_STRING "1.0.7"

#define THORVG_THREAD_SUPPORT 1
#define THORVG_CPU_ENGINE_SUPPORT 1
#define THORVG_PARTIAL_RENDER_SUPPORT 1
#define THORVG_LOTTIE_LOADER_SUPPORT 1
#define THORVG_FILE_IO_SUPPORT 1
#define WIN32_LEAN_AND_MEAN 1
