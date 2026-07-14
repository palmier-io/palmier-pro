#include "WicPngWriter.h"

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

bool WicPngWriter::WriteBgraToPng(const uint8_t* bgra, int32_t width, int32_t height, int32_t strideBytes,
    const std::string& utf8Path, std::string& outError)
{
    if (!bgra || width <= 0 || height <= 0)
    {
        outError = "invalid frame data for PNG encode";
        return false;
    }

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
        ComPtr<IWICStream> stream;
        hr = factory->CreateStream(&stream);
        if (FAILED(hr))
        {
            outError = HrError("IWICImagingFactory::CreateStream", hr);
            return false;
        }
        hr = stream->InitializeFromFilename(widePath.c_str(), GENERIC_WRITE);
        if (FAILED(hr))
        {
            outError = HrError("IWICStream::InitializeFromFilename", hr);
            return false;
        }

        ComPtr<IWICBitmapEncoder> encoder;
        hr = factory->CreateEncoder(GUID_ContainerFormatPng, nullptr, &encoder);
        if (FAILED(hr))
        {
            outError = HrError("IWICImagingFactory::CreateEncoder", hr);
            return false;
        }
        hr = encoder->Initialize(stream.Get(), WICBitmapEncoderNoCache);
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapEncoder::Initialize", hr);
            return false;
        }

        ComPtr<IWICBitmapFrameEncode> frame;
        hr = encoder->CreateNewFrame(&frame, nullptr);
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapEncoder::CreateNewFrame", hr);
            return false;
        }
        hr = frame->Initialize(nullptr);
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapFrameEncode::Initialize", hr);
            return false;
        }
        hr = frame->SetSize(static_cast<UINT>(width), static_cast<UINT>(height));
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapFrameEncode::SetSize", hr);
            return false;
        }

        WICPixelFormatGUID format = GUID_WICPixelFormat32bppBGRA;
        hr = frame->SetPixelFormat(&format);
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapFrameEncode::SetPixelFormat", hr);
            return false;
        }
        if (!IsEqualGUID(format, GUID_WICPixelFormat32bppBGRA))
        {
            outError = "PNG encoder would not accept 32bppBGRA";
            return false;
        }

        hr = frame->WritePixels(static_cast<UINT>(height), static_cast<UINT>(strideBytes),
            static_cast<UINT>(strideBytes) * static_cast<UINT>(height), const_cast<BYTE*>(bgra));
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapFrameEncode::WritePixels", hr);
            return false;
        }
        hr = frame->Commit();
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapFrameEncode::Commit", hr);
            return false;
        }
        hr = encoder->Commit();
        if (FAILED(hr))
        {
            outError = HrError("IWICBitmapEncoder::Commit", hr);
            return false;
        }
        return true;
    }();

    if (weInitializedCom)
    {
        CoUninitialize();
    }
    return ok;
}
