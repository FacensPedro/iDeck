/* d3dcsx_42.dll / d3dcsx_43.dll: the D3DX 11 compute-shader helpers (prefix scan and
 * FFT). Wine ships no implementation for these versions, so a program importing one
 * could not start. Every creator answers E_NOTIMPL and returns no object. */
#define EXPORT __declspec(dllexport)
#define E_NOTIMPL ((long)0x80004001)

EXPORT long __stdcall D3DX11CreateScan(void *context, unsigned int max_elements, unsigned int max_scans, void **out)
{
    (void)context; (void)max_elements; (void)max_scans;
    if (out) *out = 0;
    return E_NOTIMPL;
}

EXPORT long __stdcall D3DX11CreateSegmentedScan(void *context, unsigned int max_elements, void **out)
{
    (void)context; (void)max_elements;
    if (out) *out = 0;
    return E_NOTIMPL;
}

EXPORT long __stdcall D3DX11CreateFFT(void *context, const void *desc, unsigned int flags, void *info, void **out)
{
    (void)context; (void)desc; (void)flags; (void)info;
    if (out) *out = 0;
    return E_NOTIMPL;
}

#define FFT1(name) EXPORT long __stdcall name(void *context, unsigned int x, unsigned int flags, void *info, void **out) \
    { (void)context; (void)x; (void)flags; (void)info; if (out) *out = 0; return E_NOTIMPL; }
#define FFT2(name) EXPORT long __stdcall name(void *context, unsigned int x, unsigned int y, unsigned int flags, void *info, void **out) \
    { (void)context; (void)x; (void)y; (void)flags; (void)info; if (out) *out = 0; return E_NOTIMPL; }
#define FFT3(name) EXPORT long __stdcall name(void *context, unsigned int x, unsigned int y, unsigned int z, unsigned int flags, void *info, void **out) \
    { (void)context; (void)x; (void)y; (void)z; (void)flags; (void)info; if (out) *out = 0; return E_NOTIMPL; }

FFT1(D3DX11CreateFFT1DReal)
FFT1(D3DX11CreateFFT1DComplex)
FFT2(D3DX11CreateFFT2DReal)
FFT2(D3DX11CreateFFT2DComplex)
FFT3(D3DX11CreateFFT3DReal)
FFT3(D3DX11CreateFFT3DComplex)
