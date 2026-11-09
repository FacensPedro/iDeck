## What's Changed
- Fixed "x64 Wine environment failed verification: aarch64-windows/d3d11.dll is not the expected architecture (machine 0x0000)". The 1.6.7 check read the PE machine with a function that recognizes only programs Wine may start (i386, x64, ARM64EC) and reported ARM64 libraries as 0x0000. The package check now reads each file's own machine field.
- Updated the application version to 1.6.8 (build 49).
