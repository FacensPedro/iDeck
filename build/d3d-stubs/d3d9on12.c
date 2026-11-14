/* d3d9on12.dll: Direct3D 9 on top of Direct3D 12. Not available: the creators answer
 * as Windows does when the layer cannot be made, and the caller uses d3d9 itself. */
#define EXPORT __declspec(dllexport)
#define D3DERR_NOTAVAILABLE ((long)0x8876086A)

EXPORT void *__stdcall Direct3DCreate9On12(unsigned int sdk_version, void *overrides, unsigned int count)
{
    (void)sdk_version; (void)overrides; (void)count;
    return 0;
}

EXPORT long __stdcall Direct3DCreate9On12Ex(unsigned int sdk_version, void *overrides, unsigned int count, void **out)
{
    (void)sdk_version; (void)overrides; (void)count;
    if (out) *out = 0;
    return D3DERR_NOTAVAILABLE;
}
