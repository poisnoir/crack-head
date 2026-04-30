from cffi import FFI
import time

ffi = FFI()

ffi.cdef("""
    int RegisterService(char* name, char* serviceType, char* domain, int port);
    void StopService(int id);
    int Lookup(char* instanceName, char* serviceType, char* domain, int timeoutSeconds, char* out_result, int max_len);
""")


lib = ffi.dlopen("./register.so")

max_len = 256
out_buffer = ffi.new("char[]", max_len)

print("--- looking up ---")
status = lib.Lookup(b"print", b"_example1._spine._udp", b".local", 1, out_buffer, max_len)
if status == 0:
    # Convert the C string back to a Python string
    result = ffi.string(out_buffer).decode('utf-8')
    print(f"Found service at: {result}")
else:
    print("Lookup failed or timed out.")