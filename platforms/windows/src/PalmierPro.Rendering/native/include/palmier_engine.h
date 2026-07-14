#pragma once

// Flat C ABI for PalmierEngine.dll. Consumed via P/Invoke from PalmierPro.Rendering
// (src/PalmierPro.Rendering/NativeMethods.cs). Every entry point added from Stage A
// onward takes an explicit engine-session handle.

#ifdef PALMIERENGINE_EXPORTS
#define PALMIER_API extern "C" __declspec(dllexport)
#else
#define PALMIER_API extern "C" __declspec(dllimport)
#endif

PALMIER_API unsigned int PalmierEngine_GetVersion(void);
