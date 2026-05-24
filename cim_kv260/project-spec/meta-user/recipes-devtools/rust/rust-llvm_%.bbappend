# Fix: libLLVMSupport.a compiled without -fPIC, then linked into libLTO.so fails with:
# "relocation R_X86_64_TPOFF32 can not be used when making a shared object; recompile with -fPIC"
EXTRA_OECMAKE:append:class-native = " -DCMAKE_POSITION_INDEPENDENT_CODE=ON"
