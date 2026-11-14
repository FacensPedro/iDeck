/* d3d11on12.dll: Direct3D 11 on top of a Direct3D 12 device. Wine has no such layer,
 * so a program that imports it could not start at all. The one export answers
 * E_NOTIMPL, which callers treat as "no 11on12 here" and take their Direct3D 11 path. */
#define EXPORT __declspec(dllexport)
#define E_NOTIMPL ((long)0x80004001)

EXPORT long __stdcall D3D11On12CreateDevice(void *device, unsigned int flags, const int *levels, unsigned int level_count,
                                            void **queues, unsigned int queue_count, unsigned int node_mask,
                                            void **out_device, void **out_context, int *chosen_level)
{
    (void)device; (void)flags; (void)levels; (void)level_count; (void)queues; (void)queue_count; (void)node_mask;
    if (out_device) *out_device = 0;
    if (out_context) *out_context = 0;
    if (chosen_level) *chosen_level = 0;
    return E_NOTIMPL;
}
