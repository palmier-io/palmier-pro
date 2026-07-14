#include "WicImageReader.h"

#include <windows.h>
#include <wincodec.h>
#include <wrl/client.h>

#include <sstream>

using Microsoft::WRL::ComPtr;

namespace
{
    std::wstring Utf8ToWide(const std::string& utf8)
    {
        if (utf8.empty())
        {
            return std::wstring();
        }
        int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
        std::wstring wide(static_cast<size_t>(len > 0 ? len - 1 : 0), L'\0');
        if (len > 0)
        {
            MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, wide.data(), len);
        }
        return wide;
    }

    std::string HrError(const char* what, HRESULT hr)
    {
        std::ostringstream oss;
        oss << what << " failed (hr=0x" << std::hex << static_cast<unsigned long>(hr) << ")";
        return oss.str();
    }
}

bool WicImageReader::ReadToBgra(const std::string& utf8Path, std::vector<uint8_t>& outBgra,
    int32_t& outWidth, int32_t& outHeight, std::string& outError)
{
    HRESULT comHr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
    bool weInitializedCom = (comHr == S_OK || comHr == S_FALSE);
    if (FAILED(comHr) && comHr != RPC_E_CHANGED_MODE)
    {
        outError = HrError("CoInitializeEx", comHr);
        return false;
    }

    bool ok = [&]() -> bool
    {
        ComPtr<IWICImagingFactory> factory;
        HRESULT hr = CoCreateInstance(CLSID_WICImagingFactory, nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(&factory));
        if (FAILED(hr))
        {
            outError = HrError("CoCreateInstance(WICImagingFactory)", hr);
            return false;
        }

        std::wstring widePath = Utf8ToWide(utf8Path);
        ComPtr<IWICBitmapDecoder> decoder;
        hr = factory->CreateDecoderFromFilename(widePath.c_str(), nullptr, GENERIC_READ,
            WICDecodeMetadataCacheOnDemand, &decoder);
        if (FAILED(hr))
        {
            outError = HrError("IWICImagingFactory::CreateDecoderFromFilename", hr);
            return false;
        }

        ComPtr<IWICBitmapFrameDecode> frame;
        hr = decoder->GetFrame(0, &frame);
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapDecoder::GetFrame", hr);
            return false;
        }

        ComPtr<IWICFormatConverter> converter;
        hr = factory->CreateFormatConverter(&converter);
        if (FAILED(hr))
        {
            outError = HrError("IWICImagingFactory::CreateFormatConverter", hr);
            return false;
        }
        // Straight (non-premultiplied) alpha — matches the decode-buffer convention
        // MediaSource's sws_scale path produces for video, so Compositor ingests both
        // through the same "straight-alpha BGRA8" path.
        hr = converter->Initialize(frame.Get(), GUID_WICPixelFormat32bppBGRA,
            WICBitmapDitherTypeNone, nullptr, 0.0, WICBitmapPaletteTypeCustom);
        if (FAILED(hr))
        {
            outError = HrError("IWICFormatConverter::Initialize", hr);
            return false;
        }

        UINT width = 0, height = 0;
        hr = converter->GetSize(&width, &height);
        if (FAILED(hr) || width == 0 || height == 0)
        {
            outError = "IWICFormatConverter::GetSize failed or returned an empty image";
            return false;
        }

        UINT stride = width * 4;
        outBgra.assign(static_cast<size_t>(stride) * height, 0);
        hr = converter->CopyPixels(nullptr, stride, static_cast<UINT>(outBgra.size()), outBgra.data());
        if (FAILED(hr))
        {
            outError = HrError("IWICFormatConverter::CopyPixels", hr);
            return false;
        }

        outWidth = static_cast<int32_t>(width);
        outHeight = static_cast<int32_t>(height);
        return true;
    }();

    if (weInitializedCom)
    {
        CoUninitialize();
    }
    return ok;
}
