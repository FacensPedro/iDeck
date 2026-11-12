/* NTMARTA.dll: Windows' access-control provider. Wine implements these functions in
 * advapi32 itself and ships no ntmarta, so a program that loads it by name failed with
 * STATUS_DLL_NOT_FOUND. Each export forwards to advapi32's own function of the same
 * name; the provider-private Acc* entry points are left out, so GetProcAddress returns
 * NULL for them, as for any export a DLL does not have.
 *
 * Linker directives rather than a .def file: for i386 a .def forwarder gets a leading
 * underscore added to its target ("_advapi32.Name"), which no loader resolves. */
__asm__(".section .drectve\n.ascii \" -export:GetExplicitEntriesFromAclW=advapi32.GetExplicitEntriesFromAclW\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:GetNamedSecurityInfoW=advapi32.GetNamedSecurityInfoW\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:GetSecurityInfo=advapi32.GetSecurityInfo\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:SetEntriesInAclW=advapi32.SetEntriesInAclW\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:SetNamedSecurityInfoW=advapi32.SetNamedSecurityInfoW\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:SetSecurityInfo=advapi32.SetSecurityInfo\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:TreeResetNamedSecurityInfoW=advapi32.TreeResetNamedSecurityInfoW\"\n.text");
__asm__(".section .drectve\n.ascii \" -export:TreeSetNamedSecurityInfoW=advapi32.TreeSetNamedSecurityInfoW\"\n.text");
