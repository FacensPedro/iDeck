/* A DLL entry point that does nothing: these modules keep no state. */
int __stdcall DllEntry(void *instance, unsigned long reason, void *reserved)
{
    (void)instance; (void)reason; (void)reserved;
    return 1;
}
