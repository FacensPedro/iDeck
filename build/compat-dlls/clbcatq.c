/* CLBCATQ.dll: Windows' COM+ catalog. Wine ships none, so a program that loads it by
 * name failed with STATUS_DLL_NOT_FOUND. This one exports only the standard COM
 * server entry points, whose signatures are documented: it registers nothing and
 * provides no class, as a catalog with no COM+ applications would. */
#define CLASS_E_CLASSNOTAVAILABLE ((long)0x80040111)
#define S_OK 0
#define S_FALSE 1

long __stdcall DllGetClassObject(const void *clsid, const void *iid, void **object)
{
    (void)clsid; (void)iid;
    if (object) *object = 0;
    return CLASS_E_CLASSNOTAVAILABLE;
}

long __stdcall DllCanUnloadNow(void) { return S_FALSE; }
long __stdcall DllRegisterServer(void) { return S_OK; }
long __stdcall DllUnregisterServer(void) { return S_OK; }
